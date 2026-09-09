import Foundation

/// SSH stdio 传输、私有临时配置与失败分类。
///
/// 设计约束（`docs/developer/remote-work.md` §4.1 第 4 条、§5）：
/// - 后台连接一律非交互（`BatchMode=yes`），不代答主机密钥、不代答口令，
///   因此不会出现无限等待的提示；需要交互时由调用方进入 attention。
/// - 私有临时 SSH 配置**先包含**用户配置：OpenSSH 取首次出现的值，用户设置优先。
/// - 日志脱敏：只保留分类与目标，不写入 stderr 里可能出现的路径与提示原文。

/// SSH 失败分类。attention 文案与重试策略都以它为准。
public enum RemoteSSHFailureKind: String, Equatable, Sendable {
  /// 认证被拒绝或需要交互（口令、passphrase 未加载、agent 无可用密钥）。
  case authenticationRequired
  /// 主机密钥未知；后台**不自动接受**，必须由用户显式处理。
  case hostKeyUnknown
  /// 主机密钥与 known_hosts 不符。
  case hostKeyChanged
  /// 无法连通（DNS、路由、拒绝连接）。
  case hostUnreachable
  /// 连接或命令超时。
  case timeout
  /// 连接成功但远端命令不存在（127）。
  case remoteCommandMissing
  /// 调用方取消。
  case cancelled
  /// 其它 SSH 层失败。
  case transportFailure

  /// 是否需要用户到设置里显式处理（进入 attention 而不是自动退避重连）。
  public var requiresExplicitSetup: Bool {
    switch self {
    case .authenticationRequired, .hostKeyUnknown, .hostKeyChanged, .remoteCommandMissing: true
    case .hostUnreachable, .timeout, .cancelled, .transportFailure: false
    }
  }
}

/// SSH 层错误。`detail` 已脱敏，可安全写入日志与界面。
public struct RemoteSSHError: Error, Equatable, Sendable {
  public var kind: RemoteSSHFailureKind
  public var target: String
  public var detail: String
  public var exitStatus: Int32?

  public init(kind: RemoteSSHFailureKind, target: String, detail: String, exitStatus: Int32? = nil) {
    self.kind = kind
    self.target = target
    self.detail = detail
    self.exitStatus = exitStatus
  }
}

/// 一次 SSH 调用的结果。stdout 只承载协议输出，stderr 只承载诊断。
public struct RemoteSSHResult: Equatable, Sendable {
  public var exitStatus: Int32
  public var standardOutput: String
  public var standardError: String

  public init(exitStatus: Int32, standardOutput: String, standardError: String) {
    self.exitStatus = exitStatus
    self.standardOutput = standardOutput
    self.standardError = standardError
  }
}

/// stderr 分类与脱敏。纯函数，便于用固定样例做定向测试。
public enum RemoteSSHDiagnostics {
  /// 由 stderr 与退出码判定失败类型。
  ///
  /// 顺序有意义：主机密钥问题必须优先于泛化的“认证失败”，否则
  /// `Host key verification failed` 会被 permission-denied 分支吞掉。
  public static func classify(standardError: String, exitStatus: Int32) -> RemoteSSHFailureKind {
    let text = standardError.lowercased()
    if text.contains("host key verification failed") || text.contains("no matching host key") {
      return .hostKeyUnknown
    }
    if text.contains("host identification has changed")
      || text.contains("remote host identification has changed")
    {
      return .hostKeyChanged
    }
    if text.contains("permission denied") || text.contains("no supported authentication")
      || text.contains("too many authentication failures")
      || text.contains("host key verification")
    {
      return .authenticationRequired
    }
    if text.contains("operation timed out") || text.contains("connection timed out")
      || text.contains("timed out")
    {
      return .timeout
    }
    if text.contains("could not resolve hostname") || text.contains("connection refused")
      || text.contains("no route to host") || text.contains("network is unreachable")
      || text.contains("connection closed by remote host")
    {
      return .hostUnreachable
    }
    if exitStatus == 127 { return .remoteCommandMissing }
    return .transportFailure
  }

  /// 允许出现在诊断里的 stderr 行前缀。其余行整行丢弃，避免把用户配置内容、
  /// 密钥路径或提示原文写进日志和界面。
  private static let safeMarkers: [String] = [
    "permission denied", "host key verification failed", "remote host identification has changed",
    "could not resolve hostname", "connection refused", "no route to host",
    "network is unreachable", "connection timed out", "operation timed out",
    "connection closed by remote host", "no supported authentication",
    "too many authentication failures", "command not found",
  ]

  /// 生成脱敏诊断文本：只保留白名单标记本身，不保留原始行。
  public static func redact(_ standardError: String) -> String {
    let lowered = standardError.lowercased()
    let hits = safeMarkers.filter { lowered.contains($0) }
    if hits.isEmpty { return "" }
    return hits.joined(separator: "; ")
  }
}

/// 私有临时 SSH 配置与 ControlMaster 复用。
///
/// 仅在 `manage_ssh_config` 开启时创建；关闭时调用方完全不传 `-F`，也不注入任何
/// ControlMaster 选项，用户自己的连接复用不受影响。
public struct RemoteSSHManagedConfiguration: Equatable, Sendable {
  /// 0700 私有目录。
  public var directoryPath: String
  /// 传给 `-F` 的配置文件路径。
  public var configurationPath: String
  /// 本次连接专用的 control socket 模板。
  public var controlPath: String

  public init(directoryPath: String, configurationPath: String, controlPath: String) {
    self.directoryPath = directoryPath
    self.configurationPath = configurationPath
    self.controlPath = controlPath
  }
}

/// SSH 连接策略。属于客户端连接设置，不进入凭据存储。
public struct RemoteSSHPolicy: Equatable, Sendable {
  /// 是否由 Aster 管理私有临时 SSH 配置与 control socket。默认开启。
  public var manageSSHConfig: Bool
  /// 连接超时（秒）。
  public var connectTimeout: Int
  /// 握手超时（秒）。
  public var handshakeTimeout: Int
  /// 保活间隔（秒）；只在私有配置里补充，用户已设置时用户优先。
  public var keepAliveInterval: Int
  /// 保活失败次数上限。
  public var keepAliveCountMax: Int

  public init(
    manageSSHConfig: Bool = true,
    connectTimeout: Int = 10,
    handshakeTimeout: Int = 5,
    keepAliveInterval: Int = 15,
    keepAliveCountMax: Int = 3
  ) {
    self.manageSSHConfig = manageSSHConfig
    self.connectTimeout = connectTimeout
    self.handshakeTimeout = handshakeTimeout
    self.keepAliveInterval = keepAliveInterval
    self.keepAliveCountMax = keepAliveCountMax
  }

  /// 环境变量开关：`ASTER_REMOTE_MANAGE_SSH_CONFIG=0` 关闭私有配置管理。
  public static let manageSSHConfigEnvironmentKey = "ASTER_REMOTE_MANAGE_SSH_CONFIG"
  /// 环境变量开关：`ASTER_REMOTE_BINARY` 指定本地自定义服务产物。
  public static let customBinaryEnvironmentKey = "ASTER_REMOTE_BINARY"

  /// 从环境读取策略。缺省即默认策略。
  public static func fromEnvironment(_ environment: [String: String]) -> RemoteSSHPolicy {
    var policy = RemoteSSHPolicy()
    if let raw = environment[manageSSHConfigEnvironmentKey] {
      policy.manageSSHConfig = !(raw == "0" || raw.lowercased() == "false" || raw.lowercased() == "no")
    }
    return policy
  }
}

/// 私有临时 SSH 配置的生成与清理。
public enum RemoteSSHConfigurationManager {
  /// 生成配置文本。
  ///
  /// `Include` 放在最前：OpenSSH 对同一关键字取**首次出现**的值，所以用户配置里
  /// 已设置的 ServerAlive*/ControlMaster 覆盖下面的补充值，符合“用户配置优先”。
  /// 未设置时才落到 `Host *` 段补的保活与私有 control socket。
  public static func configurationText(
    userConfigurationPath: String?,
    controlPath: String,
    policy: RemoteSSHPolicy
  ) -> String {
    var lines: [String] = [
      "# Aster 远程工作模式私有临时配置。先包含用户配置，用户已设置的值优先。"
    ]
    if let userConfigurationPath, !userConfigurationPath.isEmpty {
      lines.append("Include \(userConfigurationPath)")
    }
    lines += [
      "",
      "Host *",
      "  ServerAliveInterval \(policy.keepAliveInterval)",
      "  ServerAliveCountMax \(policy.keepAliveCountMax)",
      "  ControlMaster auto",
      "  ControlPath \(controlPath)",
      "  ControlPersist 60",
      "",
    ]
    return lines.joined(separator: "\n")
  }

  /// 创建 0700 私有目录并写入配置。
  ///
  /// control socket 路径必须短于 `sockaddr_un` 的 104 字节上限，因此私有目录直接
  /// 放在 `/tmp` 下并使用短前缀；`%C` 是 OpenSSH 的连接哈希，保证同目录下不同目标
  /// 互不冲突。
  public static func makePrivateConfiguration(
    userConfigurationPath: String? = nil,
    policy: RemoteSSHPolicy = RemoteSSHPolicy(),
    fileManager: FileManager = .default
  ) throws -> RemoteSSHManagedConfiguration {
    let suffix = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(10)
    let directory = "/tmp/aster-ssh-\(suffix)"
    try fileManager.createDirectory(
      atPath: directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700]
    )
    let controlPath = "\(directory)/c-%C"
    let configurationPath = "\(directory)/config"
    let resolvedUserConfig =
      userConfigurationPath
      ?? defaultUserConfigurationPath(fileManager: fileManager)
    let text = configurationText(
      userConfigurationPath: resolvedUserConfig, controlPath: controlPath, policy: policy)
    guard
      fileManager.createFile(
        atPath: configurationPath,
        contents: Data(text.utf8),
        attributes: [.posixPermissions: 0o600])
    else {
      try? fileManager.removeItem(atPath: directory)
      throw RemoteSSHError(
        kind: .transportFailure, target: "", detail: "无法写入私有 SSH 配置")
    }
    return RemoteSSHManagedConfiguration(
      directoryPath: directory, configurationPath: configurationPath, controlPath: controlPath)
  }

  /// 只有真实存在的用户配置才 Include；文件缺失时 OpenSSH 会报错，所以必须先判断。
  public static func defaultUserConfigurationPath(fileManager: FileManager = .default) -> String? {
    let path = (NSHomeDirectory() as NSString).appendingPathComponent(".ssh/config")
    return fileManager.fileExists(atPath: path) ? path : nil
  }

  /// 清理本次连接的资源：先请求 ControlMaster 退出，再删除私有目录。
  ///
  /// 只作用于本次生成的私有 control socket，不触碰用户自己的复用连接。
  public static func cleanUp(
    _ configuration: RemoteSSHManagedConfiguration,
    target: RemoteSSHTarget,
    runner: RemoteSSHRunning = RemoteSSHProcessRunner(),
    fileManager: FileManager = .default
  ) {
    let invocation = RemoteSSHInvocation(
      target: target,
      configurationFile: configuration.configurationPath,
      options: [],
      remoteCommand: [],
      connectTimeout: 5
    )
    var argv = ["-O", "exit"]
    argv += invocation.arguments()
    _ = try? runner.run(arguments: argv, timeout: 5)
    try? fileManager.removeItem(atPath: configuration.directoryPath)
  }
}

/// SSH 进程执行接口。测试用替身注入，生产用真实 `/usr/bin/ssh`。
public protocol RemoteSSHRunning: Sendable {
  /// 执行一次 `ssh`，返回退出码与两路输出。超时按 `timeout` 失败。
  func run(arguments: [String], timeout: TimeInterval) throws -> RemoteSSHResult
}

/// 真实 SSH 执行器：直接 exec `/usr/bin/ssh`，argv 由调用方给出，不经过 Shell。
public struct RemoteSSHProcessRunner: RemoteSSHRunning {
  public init() {}

  public func run(arguments: [String], timeout: TimeInterval) throws -> RemoteSSHResult {
    guard FileManager.default.isExecutableFile(atPath: RemoteSSHInvocation.executablePath) else {
      throw RemoteSSHError(
        kind: .transportFailure, target: "", detail: "缺少 \(RemoteSSHInvocation.executablePath)")
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: RemoteSSHInvocation.executablePath)
    process.arguments = arguments
    // 固定工具搜索路径与 locale，保证 stderr 关键字稳定可分类；保留 HOME/SSH_AUTH_SOCK
    // 以便使用用户的 known_hosts、密钥和 ssh-agent。
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["LC_ALL"] = "C"
    process.environment = environment

    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    // stdin 必须是 /dev/null：即使某个选项组合仍想提示，也会立刻失败而不是无限等待。
    process.standardInput = FileHandle.nullDevice

    do { try process.run() } catch {
      throw RemoteSSHError(
        kind: .transportFailure, target: "", detail: "无法启动 ssh")
    }

    let buffer = RemoteSSHOutputBuffer()
    out.fileHandleForReading.readabilityHandler = { buffer.appendOutput($0.availableData) }
    err.fileHandleForReading.readabilityHandler = { buffer.appendDiagnostics($0.availableData) }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline { usleep(20_000) }
    if process.isRunning {
      process.terminate()
      _ = waitForExit(process, seconds: 1)
      out.fileHandleForReading.readabilityHandler = nil
      err.fileHandleForReading.readabilityHandler = nil
      throw RemoteSSHError(kind: .timeout, target: "", detail: "ssh 超时")
    }
    process.waitUntilExit()
    buffer.appendOutput(out.fileHandleForReading.availableData)
    buffer.appendDiagnostics(err.fileHandleForReading.availableData)
    out.fileHandleForReading.readabilityHandler = nil
    err.fileHandleForReading.readabilityHandler = nil

    return RemoteSSHResult(
      exitStatus: process.terminationStatus,
      standardOutput: buffer.outputText,
      standardError: buffer.diagnosticsText
    )
  }

  /// 有界等待子进程退出，避免终止后仍然阻塞主流程。
  private func waitForExit(_ process: Process, seconds: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while process.isRunning && Date() < deadline { usleep(20_000) }
    return !process.isRunning
  }
}

/// 子进程管道输出的线程安全缓冲；readability handler 在任意队列回调，必须自带锁。
private final class RemoteSSHOutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var output = Data()
  private var diagnostics = Data()

  func appendOutput(_ chunk: Data) {
    guard !chunk.isEmpty else { return }
    lock.lock()
    output.append(chunk)
    lock.unlock()
  }

  func appendDiagnostics(_ chunk: Data) {
    guard !chunk.isEmpty else { return }
    lock.lock()
    diagnostics.append(chunk)
    lock.unlock()
  }

  var outputText: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: output, as: UTF8.self)
  }

  var diagnosticsText: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: diagnostics, as: UTF8.self)
  }
}
