// Codex 账号配额的权威来源：起一次 `codex app-server`，走 JSON-RPC 读服务端的实时额度。
import AsterCore
import Darwin
import Foundation

/// 通过 `codex app-server` 的 `account/rateLimits/read` 取账号级配额。
///
/// 为什么不能只靠 rollout 文件：rollout 记的是**本机某个会话最后一次响应**时的额度，别的
/// 设备、别的会话、以及之后的消耗都看不到。实测同一时刻 rollout 显示每周 84%，而 app-server
/// 返回 100%（已限流）——差一个「还能不能干活」的量级。所以 app-server 是权威值，
/// `CodexAccountQuotaReader` 只在这里拿不到数时兜底。
///
/// 全部是阻塞式子进程 IO，调用方必须放在 `Task.detached(priority: .utility)` 里。
enum CodexAppServerQuotaClient {
  /// 握手 + 一次请求的总超时。给得宽是因为 codex 首次启动要加载 Node 运行时。
  static let requestTimeout: TimeInterval = 15
  /// `account/rateLimits/read` 的 JSON-RPC id；stdout 上混着通知行，只认这个 id 的回应。
  static let rateLimitsRequestID = 2
  /// 窗口时长 ≥ 该分钟数算周窗口（Codex 的周窗口是 10080 分钟，5 小时窗口是 300）。
  static let weeklyWindowMinimumMinutes: Double = 1440
  /// stdout 缓冲上限；正常响应只有几 KB，超过说明对面在刷日志，直接放弃。
  static let maximumOutputBytes = 1 << 20

  /// 取一次账号配额与订阅档位。返回 nil 表示该走 rollout 兜底。
  nonisolated static func latestWindows(
    homeDirectory: URL, now: Date
  ) -> (windows: [AgentUsageWindow], plan: String?)? {
    let environment = ProcessInfo.processInfo.environment
    // 复用设置页定位 Agent CLI 的那套有界搜索：GUI 进程的 PATH 很贫瘠，直接 exec `codex`
    // 多半找不到；locator 已覆盖 PATH、~/.local/bin、npm/bun/volta、Homebrew 等目录。
    let locator = AgentExecutableLocator(
      homeDirectory: homeDirectory, environment: environment, fileManager: .default)
    guard let executable = locator.path(for: "codex") else { return nil }
    // codex 是 `#!/usr/bin/env node` 脚本，子进程自己还要找得到 node，所以把 locator 的
    // 搜索目录整体作为子进程 PATH，而不是沿用 GUI 那份。
    var childEnvironment = environment
    childEnvironment["PATH"] = locator.searchDirectories.map(\.path).joined(separator: ":")
    guard let data = readRateLimitsResponse(executable: executable, environment: childEnvironment),
      let windows = windows(fromRateLimitsResponse: data, now: now)
    else { return nil }
    return (windows, planType(fromRateLimitsResponse: data))
  }

  /// 从 `account/rateLimits/read` 的响应里解析账号级窗口。纯函数，可单测。
  ///
  /// **按 `windowDurationMins` 判窗口种类，不按 primary / secondary 的位置**：本机 pro 账号
  /// 只有 primary 且它就是每周窗口，按位置猜会把周配额当成 5 小时配额显示。
  nonisolated static func windows(fromRateLimitsResponse data: Data, now: Date)
    -> [AgentUsageWindow]?
  {
    guard let limits = rateLimits(from: data) else { return nil }
    var result: [AgentUsageWindow] = []
    var seen: Set<AgentUsageWindowKind> = []
    for slot in ["primary", "secondary"] {
      guard let window = limits[slot] as? [String: Any],
        let used = double(window["usedPercent"]),
        let minutes = double(window["windowDurationMins"])
      else { continue }
      let kind: AgentUsageWindowKind = minutes >= weeklyWindowMinimumMinutes ? .weekly : .fiveHour
      guard seen.insert(kind).inserted else { continue }
      // 服务端偶尔给 `resetsAt: 0` 表示「没有重置时刻」，按字面转成 1970 年会显示成已过期。
      let resetsAt = double(window["resetsAt"]).flatMap {
        $0 > 0 ? Date(timeIntervalSince1970: $0) : nil
      }
      guard let usage = AgentUsageWindow(kind: kind, usedPercent: used, resetsAt: resetsAt) else {
        continue
      }
      result.append(usage)
    }
    guard !result.isEmpty else { return nil }
    let order = AgentUsageWindowKind.allCases
    return result.sorted {
      (order.firstIndex(of: $0.kind) ?? 0) < (order.firstIndex(of: $1.kind) ?? 0)
    }
  }

  /// 订阅档位展示名，例如 `pro` → `Pro`、`business_starter` → `Business Starter`。拿不到返回 nil。
  nonisolated static func planType(fromRateLimitsResponse data: Data) -> String? {
    guard let limits = rateLimits(from: data) else { return nil }
    return UsagePlanName.normalized(limits["planType"] as? String)
  }

  /// 取响应里的 `result.rateLimits`。带 JSON-RPC `error` 的响应一律当失败。
  private nonisolated static func rateLimits(from data: Data) -> [String: Any]? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      !object.keys.contains("error"),
      let result = object["result"] as? [String: Any],
      let limits = result["rateLimits"] as? [String: Any]
    else { return nil }
    return limits
  }

  private nonisolated static func double(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
  }

  /// 客户端版本号，只用于 `initialize` 的 clientInfo；取不到时用占位值。
  private nonisolated static var clientVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
  }

  /// 起一次 `codex app-server`，握手后发请求，返回 id 匹配的那一行响应。
  ///
  /// 三条约束：stdout 必须与子进程并行消费（否则管道写满互锁）；stdout 上混着
  /// `remoteControl/status/changed` 之类的通知行，只能靠解析 id 挑出目标行；无论成功失败
  /// 都要收掉子进程，SIGTERM 之后再给宽限期强杀，绝不留孤儿 codex 进程。
  private nonisolated static func readRateLimitsResponse(
    executable: String, environment: [String: String]
  ) -> Data? {
    /// stdout 读端缓冲：`readabilityHandler` 在专用队列回调，必须加锁与主体隔离。
    final class OutputBox: @unchecked Sendable {
      let lock = NSLock()
      var pending = Data()
      var matched: Data?
      var overflowed = false
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["app-server"]
    process.environment = environment
    let input = Pipe()
    let output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    // app-server 会往 stderr 写启动日志，我们既不用也不想让它填满管道。
    process.standardError = FileHandle.nullDevice

    let box = OutputBox()
    let finished = DispatchSemaphore(value: 0)
    output.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      // 空数据代表 EOF：子进程已经退出，不用再等超时。
      guard !chunk.isEmpty else { finished.signal(); return }
      box.lock.lock()
      box.pending.append(chunk)
      if box.pending.count > maximumOutputBytes { box.overflowed = true }
      if box.matched == nil { box.matched = takeResponseLine(from: &box.pending) }
      let done = box.matched != nil || box.overflowed
      box.lock.unlock()
      if done { finished.signal() }
    }
    process.terminationHandler = { _ in finished.signal() }

    guard (try? process.run()) != nil else {
      output.fileHandleForReading.readabilityHandler = nil
      process.terminationHandler = nil
      return nil
    }

    for request in handshakeRequests {
      try? input.fileHandleForWriting.write(contentsOf: Data((request + "\n").utf8))
    }
    _ = finished.wait(timeout: .now() + requestTimeout)

    output.fileHandleForReading.readabilityHandler = nil
    process.terminationHandler = nil
    try? input.fileHandleForWriting.close()
    terminate(process)
    try? output.fileHandleForReading.close()

    box.lock.lock()
    defer { box.lock.unlock() }
    return box.overflowed ? nil : box.matched
  }

  /// 三条 JSON-RPC 报文：初始化、初始化完成通知、读配额。
  private nonisolated static var handshakeRequests: [String] {
    [
      #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"Aster","version":"\#(clientVersion)"}}}"#,
      #"{"jsonrpc":"2.0","method":"initialized","params":{}}"#,
      #"{"jsonrpc":"2.0","id":\#(rateLimitsRequestID),"method":"account/rateLimits/read","params":{}}"#,
    ]
  }

  /// 从缓冲里逐行取出并解析，返回第一条 id 等于 `rateLimitsRequestID` 的行；已消费的行从缓冲移除。
  private nonisolated static func takeResponseLine(from buffer: inout Data) -> Data? {
    var matched: Data?
    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = Data(buffer[buffer.startIndex..<newline])
      buffer.removeSubrange(buffer.startIndex...newline)
      guard matched == nil,
        let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
        (object["id"] as? NSNumber)?.intValue == rateLimitsRequestID
      else { continue }
      matched = line
    }
    return matched
  }

  /// 收掉子进程：先 SIGTERM，宽限期内没退出再 SIGKILL。
  private nonisolated static func terminate(_ process: Process) {
    guard process.isRunning else {
      process.waitUntilExit()
      return
    }
    process.terminate()
    let deadline = Date().addingTimeInterval(2)
    while process.isRunning, Date() < deadline { usleep(50_000) }
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    process.waitUntilExit()
  }
}
