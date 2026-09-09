import Foundation

/// 受管会话客户端接口与本地后台实现。
///
/// 设计约束（`docs/developer/remote-work.md` §3.1/§3.2）：调用方只看到会话动作，
/// 不接触服务协议帧；`aster-session` 的结构化输出是本实现唯一的传输面。解码逻辑
/// 与进程调用分开，保证在不启动服务的情况下也能对回复格式做定向测试。

/// 一个可连接的后台会话实例的定位信息。
///
/// `stateParent` 必须已存在且只对当前用户开放（服务端会再次校验），`sessionName`
/// 决定命名会话；两者共同决定 socket 路径，不通过 PID 或显示名定位服务。
public struct ManagedSessionEndpoint: Equatable, Sendable {
  public var machineProfileID: UUID
  public var binaryPath: String
  public var stateParentPath: String
  public var sessionName: String

  public init(
    machineProfileID: UUID = MachineProfile.localProfileID,
    binaryPath: String,
    stateParentPath: String,
    sessionName: String = "default"
  ) {
    self.machineProfileID = machineProfileID
    self.binaryPath = binaryPath
    self.stateParentPath = stateParentPath
    self.sessionName = sessionName
  }
}

/// 会话客户端错误。失败必须显式暴露，不允许静默回退成未标识的本地 Shell。
public enum ManagedSessionError: Error, Equatable, Sendable {
  /// 运行时可执行文件缺失或不可执行。
  case runtimeUnavailable(String)
  /// 进程启动失败（fork/exec 层面）。
  case launchFailed(String)
  /// 服务端返回结构化 error 回复。
  case serviceError(code: String, message: String?)
  /// 回复不是合法的协议信封。
  case malformedReply(String)
  /// 命令以非零码退出且没有可解析的错误信封。
  case commandFailed(status: Int32, output: String)
}

/// 受管会话客户端接口。App 与 CLI 使用同一套动作语义。
public protocol ManagedSessionClient: Sendable {
  /// 确保命名会话的后台服务已运行；已存在时不重启、不替换。
  func ensureServer(_ endpoint: ManagedSessionEndpoint) throws -> SessionServerReference
  /// 只读查询服务实例身份与 epoch；服务不存在时抛错，不隐式启动。
  func serverStatus(_ endpoint: ManagedSessionEndpoint) throws -> SessionServerIdentity
  /// 在服务端创建受管终端；返回的 terminalID 与该进程生命周期绑定。
  func createTerminal(
    _ endpoint: ManagedSessionEndpoint,
    workingDirectory: String,
    argv: [String]
  ) throws -> ManagedTerminalStatus
  /// 列出该会话全部受管终端的真实状态。
  func listTerminals(_ endpoint: ManagedSessionEndpoint) throws -> [ManagedTerminalStatus]
  /// 结束指定受管终端并等待进程回收。
  func terminateTerminal(
    _ endpoint: ManagedSessionEndpoint,
    terminalID: String
  ) throws -> ManagedTerminalStatus
  /// 生成显示桥 argv：Ghostty surface 以此为子进程附加到受管终端。
  func bridgeArguments(
    _ endpoint: ManagedSessionEndpoint,
    terminalID: String,
    readOnly: Bool
  ) -> [String]
}

/// 服务实例身份。`serverEpoch` 每次启动重新生成，用于识别冷重启。
public struct SessionServerIdentity: Equatable, Sendable {
  public var reference: SessionServerReference
  public var serverEpoch: String
  public var capabilities: [String]
  public var version: String

  public init(
    reference: SessionServerReference,
    serverEpoch: String,
    capabilities: [String],
    version: String
  ) {
    self.reference = reference
    self.serverEpoch = serverEpoch
    self.capabilities = capabilities
    self.version = version
  }
}

/// `aster-session` 结构化输出的纯解码层，不触碰进程或文件系统。
public enum ManagedSessionReplyDecoder {
  /// 解析协议信封的 `target` 段，得到稳定服务身份。
  public static func serverIdentity(
    machineProfileID: UUID,
    from json: [String: Any]
  ) throws -> SessionServerIdentity {
    guard let target = json["target"] as? [String: Any],
      let serverID = target["serverID"] as? String,
      let serverEpoch = target["serverEpoch"] as? String,
      let sessionID = target["sessionID"] as? String
    else { throw ManagedSessionError.malformedReply("missing target identity") }
    let result = json["result"] as? [String: Any] ?? [:]
    return SessionServerIdentity(
      reference: SessionServerReference(
        machineProfileID: machineProfileID,
        serverID: serverID,
        sessionID: sessionID
      ),
      serverEpoch: serverEpoch,
      capabilities: (result["capabilities"] as? [String]) ?? [],
      version: (result["version"] as? String) ?? ""
    )
  }

  /// 解析单个终端描述。`state` 未知时按 `unavailable` 处理，不臆测仍在运行。
  public static func terminal(
    _ raw: [String: Any],
    server: SessionServerReference,
    serverEpoch: String?
  ) throws -> ManagedTerminalStatus {
    guard let terminalID = raw["terminalID"] as? String, !terminalID.isEmpty else {
      throw ManagedSessionError.malformedReply("missing terminalID")
    }
    let stateText = (raw["state"] as? String) ?? ""
    // `terminating` 表示仍在结束和清理，不能当作已退出。
    let state: ManagedTerminalState =
      switch stateText {
      case "running", "terminating": .running
      case "exited": .exited
      default: .unavailable
      }
    var exitCode: Int32?
    if let value = raw["exitCode"] as? NSNumber { exitCode = value.int32Value }
    if let exit = raw["exit"] as? [String: Any], let value = exit["code"] as? NSNumber {
      exitCode = value.int32Value
    }
    return ManagedTerminalStatus(
      reference: ManagedTerminalReference(server: server, terminalID: terminalID),
      state: state,
      pid: (raw["pid"] as? NSNumber)?.int32Value,
      cwd: raw["cwd"] as? String,
      exitCode: exitCode,
      serverEpoch: serverEpoch
    )
  }

  /// 把一行 JSON 输出解析成信封；`error` 类型转成 `serviceError`。
  public static func envelope(_ text: String) throws -> [String: Any] {
    let line = text.split(separator: "\n").last.map(String.init) ?? text
    guard let data = line.data(using: .utf8),
      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { throw ManagedSessionError.malformedReply(String(line.prefix(256))) }
    if let type = json["type"] as? String, type == "error" || type == "client_error" {
      let error = json["error"] as? [String: Any]
      let code = (error?["code"] as? String) ?? (json["code"] as? String) ?? "unknown"
      throw ManagedSessionError.serviceError(code: code, message: error?["message"] as? String)
    }
    return json
  }
}

/// 本地后台实现：通过 `aster-session` 可执行文件与同机命名会话服务通信。
///
/// 每个动作都是短命进程调用，不持有长连接；显示桥另由 Ghostty surface 的子进程承担，
/// 因此桥的生命周期与受管进程生命周期天然分离。
public struct LocalManagedSessionClient: ManagedSessionClient {
  /// 单次控制命令的最大等待时间；超时按结果未知处理，不重复创建资源。
  public var timeout: TimeInterval

  public init(timeout: TimeInterval = 15) { self.timeout = timeout }

  public func ensureServer(_ endpoint: ManagedSessionEndpoint) throws -> SessionServerReference {
    let output = try run(endpoint, ["server", "start", endpoint.stateParentPath, endpoint.sessionName])
    let json = try ManagedSessionReplyDecoder.envelope(output)
    // server start 的信封把已校验状态嵌在 status 字段里；直接启动与 already_running
    // 两条路径都必须走同一份已验证身份，不能用启动进程的 PID 代替身份。
    guard let status = json["status"] as? [String: Any] else {
      throw ManagedSessionError.malformedReply("missing verified status")
    }
    return try ManagedSessionReplyDecoder.serverIdentity(
      machineProfileID: endpoint.machineProfileID,
      from: status
    ).reference
  }

  public func serverStatus(_ endpoint: ManagedSessionEndpoint) throws -> SessionServerIdentity {
    let output = try run(
      endpoint, ["server", "status", endpoint.stateParentPath, endpoint.sessionName])
    return try ManagedSessionReplyDecoder.serverIdentity(
      machineProfileID: endpoint.machineProfileID,
      from: try ManagedSessionReplyDecoder.envelope(output)
    )
  }

  public func createTerminal(
    _ endpoint: ManagedSessionEndpoint,
    workingDirectory: String,
    argv: [String]
  ) throws -> ManagedTerminalStatus {
    guard !argv.isEmpty else { throw ManagedSessionError.malformedReply("empty argv") }
    let output = try run(
      endpoint,
      ["terminal", "create", endpoint.stateParentPath, endpoint.sessionName, workingDirectory]
        + argv
    )
    let json = try ManagedSessionReplyDecoder.envelope(output)
    let identity = try ManagedSessionReplyDecoder.serverIdentity(
      machineProfileID: endpoint.machineProfileID, from: json)
    guard let result = json["result"] as? [String: Any] else {
      throw ManagedSessionError.malformedReply("missing result")
    }
    return try ManagedSessionReplyDecoder.terminal(
      result, server: identity.reference, serverEpoch: identity.serverEpoch)
  }

  public func listTerminals(_ endpoint: ManagedSessionEndpoint) throws -> [ManagedTerminalStatus] {
    let output = try run(
      endpoint, ["terminal", "list", endpoint.stateParentPath, endpoint.sessionName])
    let json = try ManagedSessionReplyDecoder.envelope(output)
    let identity = try ManagedSessionReplyDecoder.serverIdentity(
      machineProfileID: endpoint.machineProfileID, from: json)
    let result = json["result"] as? [String: Any] ?? [:]
    let raw = result["terminals"] as? [[String: Any]] ?? []
    return try raw.map {
      try ManagedSessionReplyDecoder.terminal(
        $0, server: identity.reference, serverEpoch: identity.serverEpoch)
    }
  }

  public func terminateTerminal(
    _ endpoint: ManagedSessionEndpoint,
    terminalID: String
  ) throws -> ManagedTerminalStatus {
    let output = try run(
      endpoint,
      ["terminal", "terminate", endpoint.stateParentPath, endpoint.sessionName, terminalID])
    let json = try ManagedSessionReplyDecoder.envelope(output)
    let identity = try ManagedSessionReplyDecoder.serverIdentity(
      machineProfileID: endpoint.machineProfileID, from: json)
    let result = json["result"] as? [String: Any] ?? ["terminalID": terminalID]
    return try ManagedSessionReplyDecoder.terminal(
      result, server: identity.reference, serverEpoch: identity.serverEpoch)
  }

  public func bridgeArguments(
    _ endpoint: ManagedSessionEndpoint,
    terminalID: String,
    readOnly: Bool
  ) -> [String] {
    [
      "terminal", readOnly ? "observe" : "attach", endpoint.stateParentPath,
      endpoint.sessionName, terminalID,
    ]
  }

  /// 执行一次结构化命令并返回 stdout；超时会终止子进程并按结果未知报错。
  ///
  /// stdout 只承载协议输出，诊断在 stderr；两者分开读取避免互相污染，也避免管道
  /// 写满导致子进程阻塞。
  private func run(_ endpoint: ManagedSessionEndpoint, _ arguments: [String]) throws -> String {
    guard FileManager.default.isExecutableFile(atPath: endpoint.binaryPath) else {
      throw ManagedSessionError.runtimeUnavailable(endpoint.binaryPath)
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: endpoint.binaryPath)
    process.arguments = arguments
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch {
      throw ManagedSessionError.launchFailed(String(describing: error))
    }

    let buffer = ManagedSessionOutputBuffer()
    out.fileHandleForReading.readabilityHandler = { handle in
      buffer.appendOutput(handle.availableData)
    }
    err.fileHandleForReading.readabilityHandler = { handle in
      buffer.appendDiagnostics(handle.availableData)
    }

    let deadline = Date().addingTimeInterval(timeout)
    while process.isRunning && Date() < deadline {
      usleep(20_000)
    }
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
      out.fileHandleForReading.readabilityHandler = nil
      err.fileHandleForReading.readabilityHandler = nil
      throw ManagedSessionError.commandFailed(status: -1, output: "timeout")
    }
    process.waitUntilExit()
    // 结束后再清理 handler，并补读管道里的残余数据。
    buffer.appendOutput(out.fileHandleForReading.availableData)
    buffer.appendDiagnostics(err.fileHandleForReading.availableData)
    out.fileHandleForReading.readabilityHandler = nil
    err.fileHandleForReading.readabilityHandler = nil

    let text = buffer.outputText
    let diagnostics = buffer.diagnosticsText

    if process.terminationStatus != 0 && text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      throw ManagedSessionError.commandFailed(
        status: process.terminationStatus, output: String(diagnostics.prefix(512)))
    }
    return text
  }
}

/// 子进程管道输出的线程安全缓冲。readability handler 在任意队列回调，必须自带锁。
private final class ManagedSessionOutputBuffer: @unchecked Sendable {
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
