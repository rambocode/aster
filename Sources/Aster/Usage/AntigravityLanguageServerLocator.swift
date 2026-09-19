// Antigravity 本地 language server 的定位：从进程列表挑出候选进程，再用 lsof 读它们的监听端口。
import Darwin
import Foundation
import os

/// 找出 Antigravity 本地 language server 的监听端点。
///
/// 为什么要找进程：Antigravity 的配额没有任何离线缓存文件，只能实时问这个随本机 App / CLI
/// 一起启动的本地服务，而它的端口是随机分配的。为了让「没装 / 没启动」这条最常见的路径几乎
/// 不花钱，整个定位过程最多一次 `ps` 加一次 `lsof`：不扫端口、不重试、不起线程池。
///
/// 全部是阻塞式子进程 IO，调用方必须放在 `Task.detached(priority: .utility)` 里。
enum AntigravityLanguageServerLocator {
  /// 单个外部命令的超时。`ps` / `lsof` 正常都在几十毫秒内返回，卡住就当作不可用。
  static let commandTimeout: TimeInterval = 2
  /// 最多跟进几个候选进程。IDE 与 CLI 可能同时在跑，再多就是噪声。
  static let maximumCandidates = 4
  /// 最多返回几个待探活的端点，避免一个进程监听一堆端口时把探活次数放大。
  static let maximumEndpoints = 6
  /// 命令行单个参数的长度上限；超过说明拿到的不是我们要找的 token 或路径。
  static let maximumArgumentBytes = 512

  /// 候选进程：pid 加上命令行里带的 CSRF token 与端口提示。
  struct ProcessCandidate: Equatable {
    let processIdentifier: Int32
    /// CLI 起的实例可能完全不带 token，此时为 nil，请求就不发 CSRF 头。
    let csrfToken: String?
    /// `--extension_server_port` 给出的端口提示；只用来给 lsof 的结果排序，不单独探活。
    let hintedPort: Int?
  }

  /// 跑一次 `ps` 加一次 `lsof`，返回按优先级排好的待探活端点。找不到时返回空数组（静默）。
  static func candidateEndpoints() -> [AntigravityServerEndpoint] {
    guard let processList = run("/bin/ps", ["-ax", "-o", "pid=,command="], maximumBytes: 4 << 20)
    else { return [] }
    let candidates = candidates(fromProcessList: processList)
    guard !candidates.isEmpty else { return [] }
    // 一次性把所有候选 pid 交给 lsof：`-Fpn` 的字段输出能把端口按 pid 分组，
    // 这样既保住了「端口 → token」的对应关系，又只付一次进程启动的代价。
    let pidList = candidates.map { String($0.processIdentifier) }.joined(separator: ",")
    guard
      let listening = run(
        "/usr/sbin/lsof",
        ["-nP", "-iTCP", "-sTCP:LISTEN", "-a", "-p", pidList, "-Fpn"],
        maximumBytes: 2 << 20, acceptedTerminationStatuses: [0, 1])
    else { return [] }
    return endpoints(candidates: candidates, ports: ports(fromListeningOutput: listening))
  }

  // MARK: - 纯解析

  /// 从 `ps -ax -o pid=,command=` 的输出里挑出属于 Antigravity 的 language server 进程。
  static func candidates(fromProcessList text: String) -> [ProcessCandidate] {
    var result: [ProcessCandidate] = []
    for line in text.split(separator: "\n") {
      guard result.count < maximumCandidates else { break }
      let fields = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
      guard fields.count == 2, let pid = Int32(fields[0]), pid > 0 else { continue }
      let command = fields[1]
      let arguments = command.split(separator: " ", omittingEmptySubsequences: true)
      guard let executable = arguments.first, isLanguageServerName(executable),
        belongsToAntigravity(command: command, arguments: arguments)
      else { continue }
      // `--extension_server_csrf_token` 是新版本真正校验的那个，优先于旧的 `--csrf_token`。
      let token =
        value(of: "--extension_server_csrf_token", in: arguments)
        ?? value(of: "--csrf_token", in: arguments)
      let hinted = value(of: "--extension_server_port", in: arguments).flatMap(Int.init)
      result.append(
        ProcessCandidate(
          processIdentifier: pid, csrfToken: token,
          hintedPort: hinted.flatMap { isValidPort($0) ? $0 : nil }))
    }
    return result
  }

  /// 解析 `lsof -Fpn` 的字段输出，得到 pid 到监听端口的映射（保持出现顺序，去重）。
  static func ports(fromListeningOutput text: String) -> [Int32: [Int]] {
    var result: [Int32: [Int]] = [:]
    var current: Int32?
    for line in text.split(separator: "\n") {
      guard let marker = line.first else { continue }
      let value = line.dropFirst()
      switch marker {
      case "p":
        current = Int32(value)
      case "n":
        // 只认回环与通配地址：language server 不会把配额接口暴露到外网地址上。
        guard let pid = current, let port = loopbackPort(from: value) else { continue }
        var ports = result[pid] ?? []
        if !ports.contains(port) { ports.append(port) }
        result[pid] = ports
      default:
        continue
      }
    }
    return result
  }

  /// 把候选进程与其端口合并成待探活的端点列表。
  ///
  /// `--extension_server_port` 提示到的端口排在同一进程的其它端口前面：它是服务自己公布的
  /// 地址，命中率最高，这样通常第一次探活就能成功。
  static func endpoints(candidates: [ProcessCandidate], ports: [Int32: [Int]])
    -> [AntigravityServerEndpoint]
  {
    var result: [AntigravityServerEndpoint] = []
    var seen: Set<Int> = []
    for candidate in candidates {
      var candidatePorts = ports[candidate.processIdentifier] ?? []
      if let hinted = candidate.hintedPort, let index = candidatePorts.firstIndex(of: hinted) {
        candidatePorts.remove(at: index)
        candidatePorts.insert(hinted, at: 0)
      }
      for port in candidatePorts where seen.insert(port).inserted {
        guard result.count < maximumEndpoints else { return result }
        result.append(AntigravityServerEndpoint(port: port, csrfToken: candidate.csrfToken))
      }
    }
    return result
  }

  // MARK: - 命令行字段

  /// 可执行文件名是否属于 language server 家族（`language_server_macos_arm` 等变体）。
  private static func isLanguageServerName(_ executable: Substring) -> Bool {
    let name = (executable.split(separator: "/").last ?? executable).lowercased()
    return name.hasPrefix("language_server") || name.hasPrefix("language-server")
  }

  /// 这条 language server 是否属于 Antigravity。同名进程在别的 Codeium 系产品里也有，
  /// 所以必须靠数据目录、App bundle 或 CLI 路径其中之一把它认出来。
  private static func belongsToAntigravity(command: Substring, arguments: [Substring]) -> Bool {
    if let dataDirectory = value(of: "--app_data_dir", in: arguments),
      dataDirectory.lowercased().contains("antigravity")
    {
      return true
    }
    let lowered = command.lowercased()
    return lowered.contains("/antigravity/") || lowered.contains("antigravity.app/")
      || lowered.contains("antigravity-cli") || lowered.contains("antigravity_cli")
  }

  /// 取 `--flag value` 或 `--flag=value` 形式的参数值。
  private static func value(of flag: String, in arguments: [Substring]) -> String? {
    var index = arguments.startIndex
    while index < arguments.endIndex {
      let argument = arguments[index]
      if argument == flag {
        let next = arguments.index(after: index)
        guard next < arguments.endIndex else { return nil }
        let candidate = arguments[next]
        return candidate.hasPrefix("--") ? nil : sanitized(candidate)
      }
      if argument.hasPrefix(flag + "=") {
        return sanitized(argument.dropFirst(flag.count + 1))
      }
      index = arguments.index(after: index)
    }
    return nil
  }

  private static func sanitized(_ value: Substring) -> String? {
    guard !value.isEmpty, value.utf8.count <= maximumArgumentBytes else { return nil }
    return String(value)
  }

  /// 从 `127.0.0.1:52345` / `*:52345` / `[::1]:52345` 里取端口，非回环地址返回 nil。
  private static func loopbackPort(from address: Substring) -> Int? {
    guard let separator = address.lastIndex(of: ":") else { return nil }
    let host = address[address.startIndex..<separator]
    guard host == "127.0.0.1" || host == "*" || host == "[::1]" || host == "localhost" else {
      return nil
    }
    guard let port = Int(address[address.index(after: separator)...]), isValidPort(port) else {
      return nil
    }
    return port
  }

  private static func isValidPort(_ port: Int) -> Bool { port > 0 && port < 65_536 }

  // MARK: - 子进程

  /// 跑一个固定路径的只读命令，返回有界输出；启动失败、超时、超限或异常退出一律返回 nil。
  ///
  /// 输出必须与子进程并行消费，否则 `ps` 那种几百 KB 的输出会填满管道并与等待互锁。
  /// 超时后先 SIGTERM 再 SIGKILL 保底，绝不留下孤儿进程。
  private static func run(
    _ executable: String, _ arguments: [String], maximumBytes: Int,
    acceptedTerminationStatuses: Set<Int32> = [0]
  ) -> String? {
    guard FileManager.default.isExecutableFile(atPath: executable) else { return nil }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LC_ALL": "C"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    let collected = OSAllocatedUnfairLock<(data: Data, exceeded: Bool)>(
      initialState: (Data(), false))
    let finished = DispatchSemaphore(value: 0)
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      let exceeded = collected.withLock { state -> Bool in
        if state.data.count + chunk.count > maximumBytes { state.exceeded = true }
        if state.data.count < maximumBytes {
          state.data.append(chunk.prefix(maximumBytes - state.data.count))
        }
        return state.exceeded
      }
      if exceeded, process.isRunning { process.terminate() }
    }
    process.terminationHandler = { _ in finished.signal() }
    do {
      try process.run()
    } catch {
      pipe.fileHandleForReading.readabilityHandler = nil
      process.terminationHandler = nil
      return nil
    }

    var timedOut = false
    if finished.wait(timeout: .now() + commandTimeout) == .timedOut {
      timedOut = true
      process.terminate()
      if finished.wait(timeout: .now() + 0.25) == .timedOut, process.processIdentifier > 0 {
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        _ = finished.wait(timeout: .now() + 0.25)
      }
    }
    pipe.fileHandleForReading.readabilityHandler = nil
    process.terminationHandler = nil
    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
    try? pipe.fileHandleForReading.close()
    let state = collected.withLock { state -> (data: Data, exceeded: Bool) in
      if state.data.count < maximumBytes {
        state.data.append(tail.prefix(maximumBytes - state.data.count))
      }
      return state
    }
    guard !timedOut, !state.exceeded,
      acceptedTerminationStatuses.contains(process.terminationStatus)
    else { return nil }
    return String(data: state.data, encoding: .utf8)
  }
}
