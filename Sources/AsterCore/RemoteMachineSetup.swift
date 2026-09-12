import Foundation

/// 远端机器设置事务（P3.5/P3.6/P3.7）。
///
/// 固定顺序：target 前置校验 → SSH 认证 → 平台/二进制探测 → 兼容性判定 →
/// （需要时的显式安装事务）→ 目标命名会话准备 → **最后**才产出可保存的机器配置。
/// 任何一步取消或失败都不产出配置，调用方也就无从保存（§4.1 第 2 条）。

/// 设置流程的阶段标识。attention 文案与证据都按它定位失败位置。
public enum RemoteSetupStage: String, Equatable, Sendable {
  case targetValidation
  case authentication
  case platformProbe
  case compatibility
  case installation
  case sessionPreparation
}

/// 设置失败原因。全部可直接展示，且不含凭据。
public struct RemoteSetupFailure: Error, Equatable, Sendable {
  public var stage: RemoteSetupStage
  /// 是否需要用户到显式设置入口处理（对应 attention 而不是自动退避重连）。
  public var requiresExplicitSetup: Bool
  /// 已脱敏的说明文本。
  public var message: String
  /// SSH 层分类；非 SSH 失败为 nil。
  public var sshKind: RemoteSSHFailureKind?

  public init(
    stage: RemoteSetupStage,
    requiresExplicitSetup: Bool,
    message: String,
    sshKind: RemoteSSHFailureKind? = nil
  ) {
    self.stage = stage
    self.requiresExplicitSetup = requiresExplicitSetup
    self.message = message
    self.sshKind = sshKind
  }
}

/// 设置结果。只有 `.ready` 携带可保存的机器配置。
public enum RemoteSetupOutcome: Equatable, Sendable {
  /// 连接、握手、会话准备全部成功；`profile` 此时才允许写入配置目录。
  case ready(profile: MachineProfile, identity: SessionServerIdentity, report: RemoteProbeReport)
  /// 远端没有兼容二进制，需要用户在显式安装事务里确认后才继续。
  /// 此时**不产出配置**，取消即什么也不留下。
  case installationRequired(report: RemoteProbeReport, reason: String)
  /// 运行中服务与客户端协议主版本不兼容。必须显式处理，后台不得停止它。
  case incompatibleServerRunning(report: RemoteProbeReport, reason: String)
}

/// 单步动作接口，便于把真实 SSH 换成测试替身。
public protocol RemoteSetupExecuting: Sendable {
  /// 仅验证认证是否可用（远端执行 `true`），不做其它副作用。
  func verifyAuthentication() throws
  /// 执行远端探测脚本并返回 stdout。
  func probe(explicitPath: String?) throws -> String
  /// 确保命名会话服务已运行；已存在时不重启、不替换。
  /// `stateParentPath` 是本次设置确定的远端私有状态父目录，实现负责保证它存在且只有本人可访问。
  func ensureSession(binaryPath: String, stateParentPath: String) throws -> SessionServerIdentity
}

/// 基于 SSH 的真实执行器。
public struct RemoteSSHSetupExecutor: RemoteSetupExecuting {
  public var transport: RemoteSessionTransport
  public var runner: any RemoteSSHRunning
  public var endpointTemplate: ManagedSessionEndpoint

  public init(
    transport: RemoteSessionTransport,
    endpointTemplate: ManagedSessionEndpoint,
    runner: any RemoteSSHRunning = RemoteSSHProcessRunner()
  ) {
    self.transport = transport
    self.endpointTemplate = endpointTemplate
    self.runner = runner
  }

  public func verifyAuthentication() throws {
    let result = try runner.run(
      arguments: transport.sshArguments(remoteCommand: ["/usr/bin/true"]),
      timeout: TimeInterval(transport.policy.connectTimeout + 2))
    guard result.exitStatus == 0 else {
      throw RemoteSSHError(
        kind: RemoteSSHDiagnostics.classify(
          standardError: result.standardError, exitStatus: result.exitStatus),
        target: transport.target.rawText,
        detail: RemoteSSHDiagnostics.redact(result.standardError),
        exitStatus: result.exitStatus)
    }
  }

  public func probe(explicitPath: String?) throws -> String {
    let result = try runner.run(
      arguments: transport.sshArguments(
        remoteCommand: RemoteHostProbe.probeCommand(explicitPath: explicitPath)),
      timeout: TimeInterval(transport.policy.connectTimeout + 8))
    // 探测脚本本身对缺失候选是容错的，非零退出说明是 SSH 或远端 Shell 层失败。
    guard result.exitStatus == 0 else {
      throw RemoteSSHError(
        kind: RemoteSSHDiagnostics.classify(
          standardError: result.standardError, exitStatus: result.exitStatus),
        target: transport.target.rawText,
        detail: RemoteSSHDiagnostics.redact(result.standardError),
        exitStatus: result.exitStatus)
    }
    return result.standardOutput
  }

  public func ensureSession(binaryPath: String, stateParentPath: String) throws
    -> SessionServerIdentity
  {
    try prepareStateParent(stateParentPath)
    var endpoint = endpointTemplate
    endpoint.binaryPath = binaryPath
    endpoint.stateParentPath = stateParentPath
    let client = RemoteManagedSessionClient(transport: transport, runner: runner)
    _ = try client.ensureServer(endpoint)
    return try client.serverStatus(endpoint)
  }

  /// 在远端创建状态父目录并收紧为 0700。
  ///
  /// `aster-session` 只接受「已存在且 group/other 无任何权限」的父目录（否则报
  /// UnsafeStateParent），而默认目录在新机器上不存在，所以必须由设置事务先建好。
  /// 路径作为 `$1` 传给 sh，不做二次 Shell 拼接，含空格等字符也安全。
  private func prepareStateParent(_ path: String) throws {
    let result = try runner.run(
      arguments: transport.sshArguments(
        remoteCommand: ["/bin/sh", "-c", "mkdir -p \"$1\" && chmod 700 \"$1\"", "sh", path]),
      timeout: TimeInterval(transport.policy.connectTimeout + 5))
    guard result.exitStatus == 0 else {
      throw ManagedSessionError.runtimeUnavailable(
        "无法在远端准备状态目录 \(path)：\(RemoteSSHDiagnostics.redact(result.standardError))")
    }
  }
}

/// 设置事务编排。
public struct RemoteMachineSetup: Sendable {
  public var executor: any RemoteSetupExecuting
  /// `ASTER_REMOTE_BINARY` 指定的本地自定义产物；只影响候选发现顺序与安装事务。
  public var explicitRemoteBinaryPath: String?
  /// `ASTER_SESSION_STATE_DIR` 指定的远端状态父目录；nil 时按远端 `$HOME` 推导默认值。
  public var explicitStateParentPath: String?

  public init(
    executor: any RemoteSetupExecuting,
    explicitRemoteBinaryPath: String? = nil,
    explicitStateParentPath: String? = nil
  ) {
    self.executor = executor
    self.explicitRemoteBinaryPath = explicitRemoteBinaryPath
    self.explicitStateParentPath = explicitStateParentPath
  }

  /// 本次设置使用的状态父目录：显式指定优先，否则 `<远端 $HOME>/.local/state/aster`。
  /// 远端没报出 `$HOME` 又没有显式指定时无法推导，返回 nil 由调用方报错。
  func resolveStateParentPath(homeDirectory: String) -> String? {
    if let explicit = explicitStateParentPath, !explicit.isEmpty { return explicit }
    return RemoteHostProbe.privateStateParentPath(homeDirectory: homeDirectory)
  }

  /// 执行完整设置。
  ///
  /// - Parameters:
  ///   - rawTarget: 用户输入的原始 target 文本。
  ///   - label: 机器显示名。
  ///   - sessionName: 该配置绑定的命名会话。
  ///   - profileID: 复用已有配置 ID 时传入，新增时留空。
  public func run(
    rawTarget: String,
    label: String,
    sessionName: String,
    profileID: UUID = UUID()
  ) throws -> RemoteSetupOutcome {
    // 1. target 前置校验：非法输入在**建立连接之前**就被拒绝。
    let target: RemoteSSHTarget
    do { target = try RemoteSSHTarget.parse(rawTarget) } catch let error as RemoteSSHTargetError {
      throw RemoteSetupFailure(
        stage: .targetValidation,
        requiresExplicitSetup: true,
        message: Self.describe(error))
    }

    // 2. 认证。后台非交互，失败直接分类，不弹等待提示。
    do { try executor.verifyAuthentication() } catch let error as RemoteSSHError {
      throw RemoteSetupFailure(
        stage: .authentication,
        requiresExplicitSetup: error.kind.requiresExplicitSetup,
        message: Self.authenticationMessage(error, target: target),
        sshKind: error.kind)
    }

    // 3. 平台与候选二进制探测。
    let output: String
    do { output = try executor.probe(explicitPath: explicitRemoteBinaryPath) } catch
      let error as RemoteSSHError
    {
      throw RemoteSetupFailure(
        stage: .platformProbe,
        requiresExplicitSetup: error.kind.requiresExplicitSetup,
        message: "远端探测失败（\(error.kind.rawValue)）：\(target.rawText)",
        sshKind: error.kind)
    }
    guard
      var report = RemoteHostProbe.parse(output, explicitPath: explicitRemoteBinaryPath)
    else {
      throw RemoteSetupFailure(
        stage: .platformProbe,
        requiresExplicitSetup: true,
        message: "远端探测输出不可识别，未获得平台与二进制信息。")
    }

    // 4. 兼容性判定。这里只对**发行版本**做判断，能力集合要等真正握手才有值，
    //    所以先按协议主版本筛掉明确不兼容的候选，再用握手结果做最终判定。
    let usable = report.candidates.filter {
      $0.protocolMajor == RemoteProtocolContract.clientProtocolMajor
    }
    guard let candidate = usable.first else {
      let incompatible = report.candidates.first { $0.protocolMajor != nil }
      if let incompatible, let major = incompatible.protocolMajor {
        return .incompatibleServerRunning(
          report: report,
          reason:
            "远端 \(incompatible.path) 的协议主版本 \(major) 与客户端 \(RemoteProtocolContract.clientProtocolMajor) 不兼容，需要显式替换；后台不会停止它。"
        )
      }
      return .installationRequired(
        report: report,
        reason: "远端 \(report.platform.os)/\(report.platform.architecture) 上没有可用的 aster-session，需要显式安装。"
      )
    }

    // 5. 准备目标命名会话。只有到这一步成功才谈得上保存配置。
    //    状态目录按远端 $HOME 推导（或取显式覆盖），由执行器负责创建并收紧权限。
    guard let stateParentPath = resolveStateParentPath(homeDirectory: report.platform.homeDirectory)
    else {
      throw RemoteSetupFailure(
        stage: .sessionPreparation,
        requiresExplicitSetup: true,
        message: "远端未报告 $HOME，无法推导状态目录；请设置 ASTER_SESSION_STATE_DIR 后重试。")
    }
    let identity: SessionServerIdentity
    do {
      identity = try executor.ensureSession(
        binaryPath: candidate.path, stateParentPath: stateParentPath)
    } catch {
      throw RemoteSetupFailure(
        stage: .sessionPreparation,
        requiresExplicitSetup: true,
        message: "命名会话 \(sessionName) 准备失败：\(Self.describe(error))")
    }

    switch RemoteCompatibilityCheck.evaluate(
      protocolMajor: candidate.protocolMajor, capabilities: identity.capabilities)
    {
    case .compatible:
      break
    case .incompatibleMajor(let remote, let client):
      return .incompatibleServerRunning(
        report: report,
        reason: "运行中服务协议主版本 \(remote) 与客户端 \(client) 不兼容，需要显式替换；后台不会停止它。")
    case .missingRequiredCapability(let missing):
      throw RemoteSetupFailure(
        stage: .compatibility,
        requiresExplicitSetup: true,
        message: "远端服务缺少必需能力：\(missing.joined(separator: "、"))。")
    case .unknown(let reason):
      throw RemoteSetupFailure(
        stage: .compatibility, requiresExplicitSetup: true, message: reason)
    }

    // 把握手拿到的真实能力写回候选，让证据记录的是实测值而不是探测猜测。
    if let index = report.candidates.firstIndex(where: { $0.path == candidate.path }) {
      report.candidates[index].capabilities = identity.capabilities
    }
    report.runningServer = identity
    report.runningCompatibility = RemoteCompatibilityCheck.evaluate(
      protocolMajor: candidate.protocolMajor, capabilities: identity.capabilities)

    // 运行时位置随配置一起保存：后台连接与受管终端直接用它，不再依赖启动环境变量。
    let profile = MachineProfile(
      id: profileID,
      label: label,
      sshTarget: target.rawText,
      sessionName: sessionName,
      enabled: true,
      remoteBinaryPath: candidate.path,
      stateParentPath: stateParentPath
    )
    return .ready(profile: profile, identity: identity, report: report)
  }

  /// target 校验失败的中文说明。全部发生在连接之前。
  static func describe(_ error: RemoteSSHTargetError) -> String {
    switch error {
    case .empty: "SSH target 不能为空。"
    case .optionLike(let text): "SSH target «\(text)» 以 - 开头，会被当成 ssh 选项，已在连接前拒绝。"
    case .unsupportedCharacter(let character):
      "SSH target 含不允许的字符 «\(character)»（Shell 元字符与空白一律拒绝），已在连接前拒绝。"
    case .invalidURI(let text): "ssh:// URI 结构非法：\(text)"
    case .invalidPort(let text): "端口非法：\(text)，必须是 1–65535。"
    case .missingHost: "SSH target 缺少主机段。"
    }
  }

  static func describe(_ error: any Error) -> String {
    if let failure = error as? RemoteSetupFailure { return failure.message }
    if let ssh = error as? RemoteSSHError { return "ssh \(ssh.kind.rawValue)" }
    if let managed = error as? ManagedSessionError {
      switch managed {
      case .runtimeUnavailable(let text): return text
      case .serviceError(let code, let message): return "\(code)\(message.map { "：\($0)" } ?? "")"
      case .malformedReply(let text): return "回复格式非法：\(text)"
      case .commandFailed(let status, let output): return "命令失败（\(status)）：\(output)"
      case .launchFailed(let text): return "启动失败：\(text)"
      }
    }
    return String(describing: error)
  }

  /// 认证失败文案：给出精确目标与修复入口，不含凭据、不承诺自动重试。
  static func authenticationMessage(_ error: RemoteSSHError, target: RemoteSSHTarget) -> String {
    switch error.kind {
    case .authenticationRequired:
      "无法以非交互方式认证 \(target.rawText)。请在终端手动 ssh 一次完成认证，或把密钥加入 ssh-agent 后重试。"
    case .hostKeyUnknown:
      "\(target.rawText) 的主机密钥不在 known_hosts 中。Aster 不会自动接受主机密钥，请先手动 ssh 一次确认指纹。"
    case .hostKeyChanged:
      "\(target.rawText) 的主机密钥与 known_hosts 记录不符，连接已终止。请先确认是否为预期变更。"
    case .hostUnreachable: "无法连通 \(target.rawText)。"
    case .timeout: "连接 \(target.rawText) 超时。"
    case .remoteCommandMissing: "\(target.rawText) 上找不到要执行的命令。"
    case .cancelled: "连接已取消。"
    case .transportFailure: "连接 \(target.rawText) 失败。"
    }
  }
}

/// 远端工作区里被禁用的本机能力（P3.7）。
///
/// 规则来自设计草案 §1 与 §4.2：远端 Pane 明确禁用本机文件类操作并显示原因；
/// 普通手动 SSH Pane 不受影响，也不会被自动迁移或安装。
public enum RemoteWorkspaceBoundary {
  /// 受远端边界限制的本机动作。
  public enum LocalAction: String, CaseIterable, Sendable {
    case openFilePane
    case openLocalPath
    case revealInFinder
    case localPathCompletion
    case dragInLocalFile
  }

  /// 远端受管 Pane 是否允许该本机动作。全部禁用，不做例外。
  public static func isAllowedOnRemotePane(_ action: LocalAction) -> Bool { false }

  /// 禁用原因文案。必须说明「资源在执行机器上」，避免用户以为是权限故障。
  public static func disabledReason(_ action: LocalAction, machineLabel: String) -> String {
    switch action {
    case .openFilePane:
      "文件 Pane 只能打开本机文件。\(machineLabel) 上的文件请在该机器的终端里操作；远端文件服务尚未提供。"
    case .openLocalPath, .dragInLocalFile:
      "该路径属于本机，不会在 \(machineLabel) 上打开。远端 Pane 不访问本机文件。"
    case .revealInFinder:
      "无法在访达中显示：该资源在 \(machineLabel) 上，不是本机路径。"
    case .localPathCompletion:
      "路径补全已禁用：补全会读取本机目录，可能与 \(machineLabel) 上的同名目录混淆。"
    }
  }
}
