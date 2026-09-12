import Foundation

/// SSH 传输的受管会话客户端。
///
/// 它与 `LocalManagedSessionClient` 实现同一个 `ManagedSessionClient` 接口，
/// 只替换传输面：动作语义、参数形状（`ManagedSessionCommand`）与回复解码
/// （`ManagedSessionReplyDecoder`）全部复用，避免两条传输各自漂移。
///
/// 边界（`docs/developer/remote-work.md` §4.1）：
/// - 本地不经过 Shell：argv 直接交给 `/usr/bin/ssh`，target 以 `--` 隔离。
/// - 远端命令逐参数做 POSIX 单引号转义，因为 OpenSSH 必然把远端命令交给登录 Shell。
/// - 后台连接非交互；认证失败、主机密钥未知都直接失败并归类，不弹无限等待提示。

/// 远端连接所需的全部非凭据信息。凭据由 OpenSSH（密钥、agent、known_hosts）负责，
/// 本类型不保存也不传递任何密码或私钥。
public struct RemoteSessionTransport: Sendable {
  /// 已通过前置校验的 SSH target。
  public var target: RemoteSSHTarget
  /// 连接策略（超时、保活、是否管理 SSH 配置）。
  public var policy: RemoteSSHPolicy
  /// 私有临时配置；`manageSSHConfig=false` 时为 nil，直接用用户 OpenSSH 配置。
  public var managedConfiguration: RemoteSSHManagedConfiguration?
  /// 额外的 `-o key=value`。只用于验收场景注入确定的失败条件，生产路径为空。
  public var extraOptions: [String]

  public init(
    target: RemoteSSHTarget,
    policy: RemoteSSHPolicy = RemoteSSHPolicy(),
    managedConfiguration: RemoteSSHManagedConfiguration? = nil,
    extraOptions: [String] = []
  ) {
    self.target = target
    self.policy = policy
    self.managedConfiguration = managedConfiguration
    self.extraOptions = extraOptions
  }

  /// 生成一次远端调用的完整 ssh argv。
  ///
  /// - Parameter multiplexed: 是否允许走 ControlMaster 复用连接。短命控制命令用
  ///   复用省掉握手；**长命流（显示桥、事件订阅）必须传 false**，理由见下。
  public func sshArguments(remoteCommand: [String], multiplexed: Bool = true) -> [String] {
    RemoteSSHInvocation(
      target: target,
      // 只有开启 SSH 配置管理时才注入 `-F`；关闭时完全使用用户配置。
      configurationFile: policy.manageSSHConfig ? managedConfiguration?.configurationPath : nil,
      // `ControlPath=none` 是唯一能真正退出复用的写法：只写 `ControlMaster=no`
      // 时 OpenSSH 仍会去连已存在的 control socket。命令行 `-o` 覆盖配置文件里的
      // `ControlMaster auto`，用户自己的复用连接不受影响（那是另一个 ControlPath）。
      options: multiplexed ? extraOptions : extraOptions + ["ControlPath=none"],
      remoteCommand: remoteCommand,
      connectTimeout: policy.connectTimeout
    ).arguments()
  }
}

/// SSH 传输实现。每个动作是一次短命 ssh 调用；ControlMaster 负责连接复用。
public struct RemoteManagedSessionClient: ManagedSessionClient {
  /// 传输参数（target、策略、私有配置）。
  public var transport: RemoteSessionTransport
  /// SSH 执行器；测试注入替身。
  public var runner: any RemoteSSHRunning
  /// 单次控制命令的最大等待时间；超时按结果未知处理，不重复创建资源。
  public var timeout: TimeInterval

  public init(
    transport: RemoteSessionTransport,
    runner: any RemoteSSHRunning = RemoteSSHProcessRunner(),
    timeout: TimeInterval = 20
  ) {
    self.transport = transport
    self.runner = runner
    self.timeout = timeout
  }

  public func ensureServer(_ endpoint: ManagedSessionEndpoint) throws -> SessionServerReference {
    let output = try run(endpoint, ManagedSessionCommand.serverStart(endpoint))
    let json = try ManagedSessionReplyDecoder.envelope(output)
    guard let status = json["status"] as? [String: Any] else {
      throw ManagedSessionError.malformedReply("missing verified status")
    }
    return try ManagedSessionReplyDecoder.serverIdentity(
      machineProfileID: endpoint.machineProfileID, from: status
    ).reference
  }

  public func serverStatus(_ endpoint: ManagedSessionEndpoint) throws -> SessionServerIdentity {
    let output = try run(endpoint, ManagedSessionCommand.serverStatus(endpoint))
    return try ManagedSessionReplyDecoder.serverIdentity(
      machineProfileID: endpoint.machineProfileID,
      from: try ManagedSessionReplyDecoder.envelope(output)
    )
  }

  /// 请求服务排空并退出。成功返回时服务进程已退出。
  public func stopServer(_ endpoint: ManagedSessionEndpoint) throws {
    _ = try run(endpoint, ManagedSessionCommand.serverStop(endpoint))
  }

  public func createTerminal(
    _ endpoint: ManagedSessionEndpoint,
    workingDirectory: String,
    argv: [String]
  ) throws -> ManagedTerminalStatus {
    guard !argv.isEmpty else { throw ManagedSessionError.malformedReply("empty argv") }
    let output = try run(
      endpoint,
      ManagedSessionCommand.terminalCreate(
        endpoint, workingDirectory: workingDirectory, argv: argv))
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
    let output = try run(endpoint, ManagedSessionCommand.terminalList(endpoint))
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
      endpoint, ManagedSessionCommand.terminalTerminate(endpoint, terminalID: terminalID))
    let json = try ManagedSessionReplyDecoder.envelope(output)
    let identity = try ManagedSessionReplyDecoder.serverIdentity(
      machineProfileID: endpoint.machineProfileID, from: json)
    let result = json["result"] as? [String: Any] ?? ["terminalID": terminalID]
    return try ManagedSessionReplyDecoder.terminal(
      result, server: identity.reference, serverEpoch: identity.serverEpoch)
  }

  /// 显示桥 argv：本地执行的是 `ssh`，远端命令是 `terminal attach/observe`。
  ///
  /// 桥必须要求分配 TTY（`-tt`），否则远端 attach 无法进入 raw 模式；同时
  /// 显式关闭 `RequestTTY` 之外的交互，让桥退出后本地终端可正常恢复。
  ///
  /// **桥不复用 ControlMaster**（`multiplexed: false`）。复用时会话通道挂在后台
  /// master 上：本机桥进程被杀死后，master 不会立刻关闭该通道，远端
  /// `terminal attach` 会一直活着、每 5 秒续租写租约，直到 `ControlPersist` 到期
  /// 才退出（OrbStack 实测 62 秒）。这期间重新附加必被 `lease_busy retry=never`
  /// 拒绝，画面停在错误文本上。独立连接时本机进程一死 TCP 就断，远端 2 秒内退出
  /// 并释放租约（实测）。
  public func bridgeArguments(
    _ endpoint: ManagedSessionEndpoint,
    terminalID: String,
    readOnly: Bool
  ) -> [String] {
    var argv = ["-tt"]
    argv += transport.sshArguments(
      remoteCommand: [endpoint.binaryPath]
        + ManagedSessionCommand.bridge(endpoint, terminalID: terminalID, readOnly: readOnly),
      multiplexed: false)
    return argv
  }

  public func bridgeExecutablePath(_ endpoint: ManagedSessionEndpoint) -> String {
    RemoteSSHInvocation.executablePath
  }

  /// 事件订阅经同一条 ssh 转发。
  ///
  /// 与显示桥的区别是**不加 `-tt`**：订阅只需要一条干净的 stdout 字节流，分配 TTY
  /// 会让远端进程改走终端语义（行编辑、信号归属），破坏 JSON Lines 的逐行边界。
  ///
  /// 与桥相同的是**不复用 ControlMaster**：订阅同样是长命流，复用时本机进程结束
  /// 后远端订阅进程会滞留到 `ControlPersist` 到期，白占服务端连接与事件序号。
  public func eventSubscribeInvocation(_ endpoint: ManagedSessionEndpoint)
    -> ManagedSessionInvocation
  {
    ManagedSessionInvocation(
      executablePath: RemoteSSHInvocation.executablePath,
      arguments: transport.sshArguments(
        remoteCommand: [endpoint.binaryPath] + ManagedSessionCommand.eventSubscribe(endpoint),
        multiplexed: false))
  }

  /// 执行一次远端结构化命令并返回 stdout。
  ///
  /// SSH 层失败与服务层失败必须分开：前者转成 `ManagedSessionError.runtimeUnavailable`
  /// 并携带已脱敏的分类（认证失败要能被上层映射成 attention），后者仍由
  /// `ManagedSessionReplyDecoder.envelope` 抛 `serviceError`。
  private func run(_ endpoint: ManagedSessionEndpoint, _ arguments: [String]) throws -> String {
    try executeStructured(binaryPath: endpoint.binaryPath, arguments: arguments)
  }

  /// 共用传输原语：会话作用域与注册表作用域动作走同一条 ssh 转发与同一套错误分类。
  public func executeStructured(binaryPath: String, arguments: [String]) throws -> String {
    let remoteCommand = [binaryPath] + arguments
    let result: RemoteSSHResult
    do {
      result = try runner.run(
        arguments: transport.sshArguments(remoteCommand: remoteCommand), timeout: timeout)
    } catch let error as RemoteSSHError {
      throw ManagedSessionError.runtimeUnavailable(
        "ssh \(error.kind.rawValue): \(transport.target.rawText)")
    }
    if result.exitStatus != 0,
      result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      let kind = RemoteSSHDiagnostics.classify(
        standardError: result.standardError, exitStatus: result.exitStatus)
      let detail = RemoteSSHDiagnostics.redact(result.standardError)
      throw ManagedSessionError.runtimeUnavailable(
        "ssh \(kind.rawValue): \(transport.target.rawText)\(detail.isEmpty ? "" : " (\(detail))")")
    }
    return result.standardOutput
  }

  // MARK: - Agent 状态查询（P5）

  /// 列出该会话中所有 Agent 的当前状态。
  public func agentList(
    _ endpoint: ManagedSessionEndpoint
  ) throws -> [RemoteAgentInfo] {
    let output = try run(endpoint, ManagedSessionCommand.agentList(endpoint))
    let json = try ManagedSessionReplyDecoder.envelope(output)
    let result = json["result"] as? [String: Any] ?? [:]
    let raw = result["agents"] as? [[String: Any]] ?? []
    return raw.compactMap { ManagedSessionReplyDecoder.agentInfo($0) }
  }

  /// 上报指定终端的 Agent 状态变更，返回是否成功。
  public func agentReport(
    _ endpoint: ManagedSessionEndpoint,
    terminalID: String
  ) throws -> Bool {
    let output = try run(
      endpoint, ManagedSessionCommand.agentReport(endpoint, terminalID: terminalID))
    let json = try ManagedSessionReplyDecoder.envelope(output)
    return (json["result"] as? [String: Any])?["ok"] as? Bool ?? false
  }

  /// 获取 Agent 详情与诊断文本。
  public func agentExplain(
    _ endpoint: ManagedSessionEndpoint,
    terminalID: String
  ) throws -> (RemoteAgentInfo, String) {
    let output = try run(
      endpoint, ManagedSessionCommand.agentExplain(endpoint, terminalID: terminalID))
    let json = try ManagedSessionReplyDecoder.envelope(output)
    let result = json["result"] as? [String: Any] ?? [:]
    guard let agentJSON = result["agent"] as? [String: Any],
      let info = ManagedSessionReplyDecoder.agentInfo(agentJSON)
    else {
      throw ManagedSessionError.malformedReply("missing agent in explain result")
    }
    let explanation = result["explanation"] as? String ?? ""
    return (info, explanation)
  }

  /// 确认 Agent 完成通知（标记已读），返回是否成功。
  public func agentAcknowledge(
    _ endpoint: ManagedSessionEndpoint,
    terminalID: String
  ) throws -> Bool {
    let output = try run(
      endpoint, ManagedSessionCommand.agentAcknowledge(endpoint, terminalID: terminalID))
    let json = try ManagedSessionReplyDecoder.envelope(output)
    return (json["result"] as? [String: Any])?["ok"] as? Bool ?? false
  }

  // MARK: - 图片上传（P7）

  /// 通过 SSH 管道传输图片数据到远端 `aster-session upload`。
  ///
  /// 与 `executeStructured` 的区别是 stdin 不是 /dev/null，而是管道写入图片数据。
  /// 上传超时比控制命令更长（图片可达 20 MiB），用独立的超时值。
  public func uploadImage(
    _ endpoint: ManagedSessionEndpoint,
    terminalID: String,
    contentType: String,
    data: Data
  ) throws -> String {
    let remoteCommand = [endpoint.binaryPath]
      + ManagedSessionCommand.upload(
        endpoint, terminalID: terminalID, contentType: contentType)
    let sshArgs = transport.sshArguments(remoteCommand: remoteCommand)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: RemoteSSHInvocation.executablePath)
    process.arguments = sshArgs
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["LC_ALL"] = "C"
    process.environment = environment

    // stdin 管道传入图片数据
    let stdinPipe = Pipe()
    process.standardInput = stdinPipe
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err

    do { try process.run() } catch {
      throw ManagedSessionError.launchFailed("ssh upload: \(error)")
    }

    // 异步写入 stdin 避免管道阻塞
    let writeHandle = stdinPipe.fileHandleForWriting
    DispatchQueue.global(qos: .userInitiated).async {
      writeHandle.write(data)
      try? writeHandle.close()
    }

    let buffer = UploadOutputBuffer()
    out.fileHandleForReading.readabilityHandler = { buffer.appendOutput($0.availableData) }
    err.fileHandleForReading.readabilityHandler = { buffer.appendDiagnostics($0.availableData) }

    // 上传超时比控制命令长
    let uploadTimeout = max(timeout, 60)
    let deadline = Date().addingTimeInterval(uploadTimeout)
    while process.isRunning && Date() < deadline { usleep(20_000) }
    if process.isRunning {
      process.terminate()
      process.waitUntilExit()
      out.fileHandleForReading.readabilityHandler = nil
      err.fileHandleForReading.readabilityHandler = nil
      throw ManagedSessionError.commandFailed(status: -1, output: "ssh upload timeout")
    }
    process.waitUntilExit()
    buffer.appendOutput(out.fileHandleForReading.availableData)
    buffer.appendDiagnostics(err.fileHandleForReading.availableData)
    out.fileHandleForReading.readabilityHandler = nil
    err.fileHandleForReading.readabilityHandler = nil

    if process.terminationStatus != 0,
       buffer.outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    {
      let kind = RemoteSSHDiagnostics.classify(
        standardError: buffer.diagnosticsText, exitStatus: process.terminationStatus)
      let detail = RemoteSSHDiagnostics.redact(buffer.diagnosticsText)
      throw ManagedSessionError.runtimeUnavailable(
        "ssh upload \(kind.rawValue): \(transport.target.rawText)"
        + (detail.isEmpty ? "" : " (\(detail))"))
    }

    return try ManagedSessionUploadDecoder.path(from: buffer.outputText)
  }
}


/// 上传子进程的线程安全输出缓冲。readabilityHandler 在任意队列回调。
private final class UploadOutputBuffer: @unchecked Sendable {
  private let lock = NSLock()
  private var output = Data()
  private var diagnostics = Data()

  /// 追加 stdout 数据。
  func appendOutput(_ chunk: Data) {
    guard !chunk.isEmpty else { return }
    lock.lock()
    output.append(chunk)
    lock.unlock()
  }

  /// 追加 stderr 数据。
  func appendDiagnostics(_ chunk: Data) {
    guard !chunk.isEmpty else { return }
    lock.lock()
    diagnostics.append(chunk)
    lock.unlock()
  }

  /// stdout 文本。
  var outputText: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: output, as: UTF8.self)
  }

  /// stderr 文本。
  var diagnosticsText: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: diagnostics, as: UTF8.self)
  }
}
