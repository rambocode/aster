import AsterCore
import Darwin
import Foundation

// 阻塞式 POSIX Unix socket 客户端：一条连接、NDJSON 一问一答（或订阅流）。
// 刻意不用 Network.framework / DispatchSource：CLI 进程生命周期极短，同步 poll 最简单，
// 也不引入运行循环与 Sendable 约束。

/// CLI 进程的退出码约定；stderr 文案与之配套，供 skill / 脚本按码分支。
enum AsterCLIExitCode {
  static let success: Int32 = 0
  /// 服务端返回 error 信封（stderr 打印 `{"code","message"}` JSON）。
  static let serverError: Int32 = 1
  /// 参数错误 / 本地前置条件不满足。
  static let usage: Int32 = 2
  /// 连不上 App（含拉起后仍不可达）；沿用旧 sh 脚本的 EX_UNAVAILABLE。
  static let unavailable: Int32 = 69
}

/// 客户端侧错误；`exitCode` 决定进程退出码，`message` 打到 stderr。
struct ControlClientError: Error, CustomStringConvertible {
  let message: String
  let exitCode: Int32

  var description: String { message }

  static func unavailable(_ message: String) -> ControlClientError {
    ControlClientError(message: message, exitCode: AsterCLIExitCode.unavailable)
  }

  static func usage(_ message: String) -> ControlClientError {
    ControlClientError(message: message, exitCode: AsterCLIExitCode.usage)
  }
}

/// 与 Aster 控制 socket 对话的客户端。
struct ControlClient {
  /// 单行响应上限：读屏结果最多 10_000 行，4 MiB 足够，同时防止异常服务端把 CLI 撑爆。
  static let maximumResponseBytes = 4 * 1_024 * 1_024
  /// 默认单次请求超时；wait 类方法按 `timeout_ms` 另算。
  static let defaultTimeout: TimeInterval = 30
  /// 拉起 App 后重连的次数与间隔（50 × 100ms = 5s，与旧 sh 脚本一致）。
  static let launchAttempts = 50
  static let launchRetryInterval: UInt32 = 100_000

  let socketPath: String
  let environment: [String: String]

  /// 解析 socket 路径：`--socket` > `ASTER_SOCKET_PATH` > 默认路径。
  /// 显式 `--socket` 必须已存在、是 socket 且属主为当前 uid：它跳过了环境变量注入这层信任，
  /// 不能让用户被诱导连到别人放置的伪 socket。
  static func resolveSocketPath(explicit: String?, environment: [String: String]) throws -> String {
    if let explicit {
      var info = stat()
      guard lstat(explicit, &info) == 0 else {
        throw ControlClientError.usage("aster: --socket path does not exist: \(explicit)")
      }
      guard (info.st_mode & S_IFMT) == S_IFSOCK else {
        throw ControlClientError.usage("aster: --socket path is not a socket: \(explicit)")
      }
      guard info.st_uid == getuid() else {
        throw ControlClientError.usage("aster: --socket path is not owned by current user")
      }
      return explicit
    }
    if let fromEnvironment = environment["ASTER_SOCKET_PATH"], !fromEnvironment.isEmpty {
      return fromEnvironment
    }
    // 与 server 共用同一实现：含 ASTER_CONTROL_SOCKET_PATH 覆盖与超长 HOME 时的 $TMPDIR 回退，
    // 两边各写一份迟早会分叉。
    return AsterControlSocketLocation.defaultPath(environment: environment)
  }

  // MARK: - 请求

  /// 发送一条请求并等待对应响应；服务端 error 以 `AsterControlError` 抛出。
  func call(
    _ method: AsterControlMethod, params: JSONValue?, timeout: TimeInterval = defaultTimeout
  ) throws -> JSONValue {
    let connection = try connectOrLaunch()
    defer { connection.close() }
    try connection.send(AsterControlRequest(id: .number(1), method: method.rawValue, params: params))
    let response = try connection.receiveResponse(timeout: timeout)
    if let error = response.error { throw error }
    return response.result ?? .null
  }

  /// 订阅模式：先拿到订阅确认（回调一次 result），随后持续把每条事件交给 `onEvent`，
  /// 直到服务端关闭连接。Ctrl-C 由默认信号处理直接终止进程即可。
  func stream(
    _ method: AsterControlMethod, params: JSONValue?, onResult: (JSONValue) throws -> Void,
    onEvent: (AsterControlEvent) throws -> Void
  ) throws {
    let connection = try connectOrLaunch()
    defer { connection.close() }
    try connection.send(AsterControlRequest(id: .number(1), method: method.rawValue, params: params))
    let response = try connection.receiveResponse(timeout: Self.defaultTimeout)
    if let error = response.error { throw error }
    try onResult(response.result ?? .null)
    while let line = try connection.receiveLine(timeout: nil) {
      // 推送信封没有 id、带 `event`；其它行（如服务端主动回的错误）按响应处理。
      if let event = try? JSONDecoder().decode(AsterControlEvent.self, from: line) {
        try onEvent(event)
      } else if let response = try? JSONDecoder().decode(AsterControlResponse.self, from: line),
        let error = response.error
      {
        throw error
      }
    }
  }

  // MARK: - 连接与拉起

  /// 连接失败时拉起 App 并重试；拉起后 5 秒内仍连不上则以 69 退出。
  private func connectOrLaunch() throws -> SocketConnection {
    if let connection = try? SocketConnection.connect(path: socketPath) { return connection }
    // 测试或 CI 里不允许弹起 GUI；也避免在不存在 bundle 的开发环境误开无关应用。
    if environment["ASTER_CLI_NO_LAUNCH"] != "1" {
      launchApp()
      for _ in 0..<Self.launchAttempts {
        usleep(Self.launchRetryInterval)
        if let connection = try? SocketConnection.connect(path: socketPath) { return connection }
      }
    }
    throw ControlClientError.unavailable(
      "aster: cannot connect to Aster at \(socketPath); launch Aster once and retry")
  }

  /// 用 `open -gj` 后台、不抢焦点地拉起 App。bundle 由可执行文件位置推导
  /// （`Aster.app/Contents/MacOS/aster-cli` 上溯三层）；不在 .app 里（swift build 产物）
  /// 时退回按应用名打开，行为与旧 sh 脚本一致。
  private func launchApp() {
    var arguments = ["-gj"]
    if let bundle = AsterCLILocations.appBundleURL {
      arguments.append(bundle.path)
    } else {
      arguments.append(contentsOf: ["-a", "Aster"])
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    process.arguments = arguments
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
  }
}

/// 一条已连接的 Unix socket；负责 NDJSON 分帧与带超时的阻塞读。
final class SocketConnection {
  private let descriptor: Int32
  private var framing = NDJSONFraming(maximumLineBytes: ControlClient.maximumResponseBytes)
  /// 已切好但尚未被消费的行（一次 read 可能带回多行）。
  private var pending: [Data] = []

  private init(descriptor: Int32) { self.descriptor = descriptor }

  /// 连接到路径；任何阶段失败都抛 unavailable。
  static func connect(path: String) throws -> SocketConnection {
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    // sun_path 是定长数组（macOS 104 字节，含结尾 NUL），过长路径无法表达。
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    let bytes = Array(path.utf8)
    guard bytes.count < capacity else {
      throw ControlClientError.unavailable("aster: socket path too long: \(path)")
    }
    withUnsafeMutableBytes(of: &address.sun_path) { raw in
      raw.copyBytes(from: bytes)
      raw[bytes.count] = 0
    }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      throw ControlClientError.unavailable("aster: cannot create socket")
    }
    let length = socklen_t(MemoryLayout<sockaddr_un>.size)
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, length) }
    }
    guard result == 0 else {
      Darwin.close(descriptor)
      throw ControlClientError.unavailable("aster: cannot connect to \(path)")
    }
    return SocketConnection(descriptor: descriptor)
  }

  func close() { Darwin.close(descriptor) }

  /// 编码并写出一行请求；短写循环补齐。
  func send(_ request: AsterControlRequest) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.withoutEscapingSlashes]
    let frame = NDJSONFraming.frame(try encoder.encode(request))
    var offset = 0
    try frame.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
      while offset < raw.count {
        let written = write(descriptor, raw.baseAddress! + offset, raw.count - offset)
        guard written > 0 else {
          throw ControlClientError.unavailable("aster: connection closed while sending request")
        }
        offset += written
      }
    }
  }

  /// 读一行并按响应信封解码。
  func receiveResponse(timeout: TimeInterval?) throws -> AsterControlResponse {
    guard let line = try receiveLine(timeout: timeout) else {
      throw ControlClientError.unavailable("aster: connection closed before response")
    }
    do {
      return try JSONDecoder().decode(AsterControlResponse.self, from: line)
    } catch {
      throw ControlClientError.unavailable("aster: malformed response from Aster")
    }
  }

  /// 读下一行；EOF 返回 nil；timeout 为 nil 表示无限等待。
  func receiveLine(timeout: TimeInterval?) throws -> Data? {
    if !pending.isEmpty { return pending.removeFirst() }
    let deadline = timeout.map { Date().addingTimeInterval($0) }
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    while true {
      var descriptorSet = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
      let remaining: Int32
      if let deadline {
        let milliseconds = Int32(max(0, deadline.timeIntervalSinceNow * 1_000))
        guard milliseconds > 0 else {
          throw ControlClientError.unavailable("aster: timed out waiting for Aster response")
        }
        remaining = milliseconds
      } else {
        remaining = -1
      }
      let ready = poll(&descriptorSet, 1, remaining)
      if ready < 0 {
        if errno == EINTR { continue }
        throw ControlClientError.unavailable("aster: socket poll failed")
      }
      if ready == 0 {
        throw ControlClientError.unavailable("aster: timed out waiting for Aster response")
      }
      let count = read(descriptor, &buffer, buffer.count)
      if count < 0 {
        if errno == EINTR { continue }
        throw ControlClientError.unavailable("aster: socket read failed")
      }
      if count == 0 {
        // EOF：残留的半行直接丢弃，服务端不会发不带换行的响应。
        return nil
      }
      let lines: [Data]
      do {
        lines = try framing.append(Data(buffer[0..<count]))
      } catch {
        throw ControlClientError.unavailable("aster: response exceeds \(ControlClient.maximumResponseBytes) bytes")
      }
      if !lines.isEmpty {
        pending.append(contentsOf: lines.dropFirst())
        return lines[0]
      }
    }
  }
}

/// 可执行文件位置推导：.app bundle、SKILL.md、Info.plist。打包与开发构建两种布局。
enum AsterCLILocations {
  /// 解析符号链接后的可执行文件真实路径（`/usr/local/bin/aster` 通常是指向 bundle 的 symlink）。
  static let executableURL: URL = {
    let raw = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    return raw.resolvingSymlinksInPath()
  }()

  /// `X.app/Contents/MacOS/aster-cli` → `X.app`；不符合布局返回 nil。
  static var appBundleURL: URL? {
    let candidate = executableURL
      .deletingLastPathComponent()  // MacOS
      .deletingLastPathComponent()  // Contents
      .deletingLastPathComponent()  // X.app
    guard candidate.pathExtension == "app",
      FileManager.default.fileExists(atPath: candidate.appendingPathComponent("Contents/Info.plist").path)
    else { return nil }
    return candidate
  }

  /// 开发构建（`.build/debug/aster-cli`）：从可执行文件向上找含 `Package.swift` 的仓库根。
  static var repositoryRootURL: URL? {
    var directory = executableURL.deletingLastPathComponent()
    for _ in 0..<8 {
      if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Package.swift").path) {
        return directory
      }
      let parent = directory.deletingLastPathComponent()
      if parent.path == directory.path { break }
      directory = parent
    }
    return nil
  }

  /// SKILL.md：打包优先 `Contents/Resources/skills/aster/SKILL.md`，开发回退仓库 `Resources/skills/aster/SKILL.md`。
  static var skillURL: URL? {
    let relative = "skills/aster/SKILL.md"
    var candidates: [URL] = []
    if let bundle = appBundleURL {
      candidates.append(bundle.appendingPathComponent("Contents/Resources/" + relative))
    }
    if let root = repositoryRootURL {
      candidates.append(root.appendingPathComponent("Resources/" + relative))
    }
    candidates.append(
      URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/" + relative))
    return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// 版本号来源：Info.plist 的 CFBundleShortVersionString（打包或仓库 Resources/Info.plist）。
  /// 仓库没有编译期版本常量，所以运行时读同一份真值，避免两处维护。
  static var appVersion: String? {
    var candidates: [URL] = []
    if let bundle = appBundleURL {
      candidates.append(bundle.appendingPathComponent("Contents/Info.plist"))
    }
    if let root = repositoryRootURL {
      candidates.append(root.appendingPathComponent("Resources/Info.plist"))
    }
    for url in candidates {
      if let data = try? Data(contentsOf: url),
        let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
        let version = plist["CFBundleShortVersionString"] as? String
      {
        return version
      }
    }
    return nil
  }
}
