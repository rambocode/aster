import AsterCore
import Foundation

/// App 侧受管终端编排。
///
/// 职责边界（`docs/developer/remote-work.md` §3.1）：本类型只做机器配置解析、连接
/// 编排和会话投影；服务协议细节留在 `AsterCore` 的会话客户端里，`TerminalSession`
/// 只看到“引用 + 桥命令”。
///
/// P2 退出门槛要求默认终端策略保持不变，所以受管模式必须显式开启：需要同时提供
/// 运行时二进制路径与私有状态父目录，缺一即保持关闭，不做任何隐式回退。
@MainActor
final class ManagedTerminalCoordinator {
  /// 进程级共享实例。测试用独立配置替换它，避免污染用户默认终端策略。
  static var shared = ManagedTerminalCoordinator()

  /// 运行时二进制路径的环境变量；专用测试配置用它指定本次验收使用的产物。
  static let binaryEnvironmentKey = "ASTER_SESSION_BINARY"
  /// 私有状态父目录的环境变量；必须已存在且只对当前用户开放。
  static let stateDirectoryEnvironmentKey = "ASTER_SESSION_STATE_DIR"
  /// 命名会话名；缺省为 default。
  static let sessionNameEnvironmentKey = "ASTER_SESSION_NAME"

  private let client: any ManagedSessionClient
  private let environment: [String: String]
  /// 本协调器绑定的机器配置 ID（P4.2）。
  ///
  /// 默认是 Local，因此 `shared` 与 P2/P3 完全同义；远端协调器由注册表按机器传入，
  /// 使它产出的 `ManagedTerminalReference` 天然带正确的机器身份，跨机器对账不会串。
  let machineProfileID: UUID
  private var lifecycle = ManagedTerminalLifecycleTracker()
  /// 最近一次成功握手的服务身份；用于识别冷重启。
  private(set) var serverIdentity: SessionServerIdentity?
  private(set) var connectionState: SessionConnectionState = .disconnected
  /// 最近一次连接失败原因，用于界面显示明确错误而不是静默回退。
  private(set) var lastError: String?

  /// 远端 SSH target 的环境变量；设置后受管终端走 SSH 传输而不是本机传输。
  static let remoteTargetEnvironmentKey = "ASTER_REMOTE_SSH_TARGET"

  init(
    client: (any ManagedSessionClient)? = nil,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    machineProfileID: UUID = MachineProfile.localProfileID
  ) {
    self.client = client ?? Self.makeClient(environment: environment)
    self.environment = environment
    self.machineProfileID = machineProfileID
  }

  /// 依据环境选择传输实现。
  ///
  /// target 解析失败时**不回退到本机传输**：那会让用户以为连上了远端，实际在本机
  /// 建进程。这里保留本机客户端只是为了让协调器仍能构造，真正的拒绝发生在
  /// `remoteTransport` 为 nil 时——此时 `endpoint` 也不会被使用。
  private static func makeClient(environment: [String: String]) -> any ManagedSessionClient {
    guard let raw = environment[remoteTargetEnvironmentKey], !raw.isEmpty,
      let target = try? RemoteSSHTarget.parse(raw)
    else { return LocalManagedSessionClient() }
    let policy = RemoteSSHPolicy.fromEnvironment(environment)
    // 私有临时配置只在 manage_ssh_config 开启时创建；关闭时直接用用户 OpenSSH 配置。
    let managed =
      policy.manageSSHConfig
      ? try? RemoteSSHConfigurationManager.makePrivateConfiguration(policy: policy) : nil
    return RemoteManagedSessionClient(
      transport: RemoteSessionTransport(
        target: target, policy: policy, managedConfiguration: managed))
  }

  /// 当前是否为远端受管模式。界面据此禁用本机文件类操作（P3.7）。
  var isRemote: Bool { client is RemoteManagedSessionClient }

  /// 远端机器显示名；本机模式返回 nil。
  var remoteMachineLabel: String? {
    (client as? RemoteManagedSessionClient)?.transport.target.rawText
  }

  /// 当前服务缺失的可选能力提示（P3.7）。没有缺失或未握手时返回 nil。
  var unavailableCapabilityMessage: String? {
    guard let identity = serverIdentity else { return nil }
    guard
      case .compatible(let missing) = RemoteCompatibilityCheck.evaluate(
        protocolMajor: RemoteProtocolContract.clientProtocolMajor,
        capabilities: identity.capabilities)
    else { return nil }
    return RemoteCompatibilityCheck.unavailableActionMessage(missingOptional: missing)
  }

  /// 受管模式是否可用。缺少显式配置时返回 nil，调用方保持既有本地终端行为。
  var endpoint: ManagedSessionEndpoint? {
    guard let binary = environment[Self.binaryEnvironmentKey], !binary.isEmpty,
      let stateParent = environment[Self.stateDirectoryEnvironmentKey], !stateParent.isEmpty
    else { return nil }
    return ManagedSessionEndpoint(
      machineProfileID: machineProfileID,
      binaryPath: binary,
      stateParentPath: stateParent,
      sessionName: environment[Self.sessionNameEnvironmentKey] ?? "default"
    )
  }

  var isEnabled: Bool { endpoint != nil }

  /// 该机器的布局事务客户端（P4.2）。受管模式未开启时返回 nil。
  ///
  /// 事务与受管终端必须共用同一条传输：拆成两个客户端很容易在本机/SSH 之间配错，
  /// 结果是结构提交到一台机器、终端创建在另一台。
  var transactionClient: WorkspaceTransactionClient? {
    guard let endpoint else { return nil }
    return WorkspaceTransactionClient(client: client, endpoint: endpoint)
  }

  /// 异步连接。把阻塞的服务查询挪出主线程。
  ///
  /// P3 起同一个协调器要驱动 SSH 传输，每次调用都是一次网络往返；在 MainActor 上
  /// 同步等待会卡住整个界面。本机实现也走同一条异步路径，避免两条传输出现两套时序。
  @discardableResult
  func connectAsync() async -> SessionServerIdentity? {
    guard let endpoint else {
      connectionState = .disabled
      return nil
    }
    connectionState = .connecting
    let client = self.client
    let outcome = await Task.detached(priority: .userInitiated) { () -> Result<SessionServerIdentity, any Error> in
      do {
        _ = try client.ensureServer(endpoint)
        return .success(try client.serverStatus(endpoint))
      } catch {
        return .failure(error)
      }
    }.value
    switch outcome {
    case .success(let identity):
      serverIdentity = identity
      connectionState = .online
      lastError = nil
      return identity
    case .failure(let error):
      connectionState = .attention
      lastError = String(describing: error)
      return nil
    }
  }

  /// 异步创建受管终端。失败向上抛出，调用方必须显示明确错误。
  func createTerminalAsync(workingDirectory: String, argv: [String]) async throws
    -> ManagedTerminalStatus
  {
    guard let endpoint else { throw ManagedSessionError.runtimeUnavailable("managed mode disabled") }
    if serverIdentity == nil { _ = await connectAsync() }
    guard connectionState == .online else {
      throw ManagedSessionError.runtimeUnavailable(lastError ?? "server unavailable")
    }
    let client = self.client
    return try await Task.detached(priority: .userInitiated) {
      try client.createTerminal(endpoint, workingDirectory: workingDirectory, argv: argv)
    }.value
  }

  /// 异步对账持久化引用与服务端实测状态。
  func reconcileAsync(
    references: [ManagedTerminalReference],
    persistedServerEpoch: String?
  ) async -> [ManagedTerminalReference: ManagedTerminalResolution] {
    guard let endpoint else {
      return Dictionary(
        uniqueKeysWithValues: references.map {
          ($0, ManagedTerminalResolution.unreachable($0, reason: "managed mode disabled"))
        })
    }
    let identity = await connectAsync()
    let client = self.client
    let live = await Task.detached(priority: .userInitiated) {
      (try? client.listTerminals(endpoint)) ?? []
    }.value
    return ManagedTerminalReconciler.reconcile(
      references: references,
      liveTerminals: live,
      currentServer: identity?.reference,
      currentServerEpoch: identity?.serverEpoch,
      persistedServerEpoch: persistedServerEpoch,
      unreachableReason: identity == nil ? (lastError ?? "server unavailable") : nil
    )
  }

  /// 连接（必要时启动）本地默认后台服务。Local 允许首次使用时自动启动或附加。
  ///
  /// 同步版本保留给必须在返回前完成的关闭路径（`stop()`/`terminate`）；
  /// 交互路径一律用 `connectAsync()`。
  @discardableResult
  func connect() -> SessionServerIdentity? {
    guard let endpoint else {
      connectionState = .disabled
      return nil
    }
    connectionState = .connecting
    do {
      _ = try client.ensureServer(endpoint)
      let identity = try client.serverStatus(endpoint)
      serverIdentity = identity
      connectionState = .online
      lastError = nil
      return identity
    } catch {
      connectionState = .attention
      lastError = String(describing: error)
      return nil
    }
  }

  /// 创建一个受管终端并返回稳定引用。失败向上抛出，调用方必须显示明确错误，
  /// 不允许静默回退成未经标识的新本地 Shell。
  func createTerminal(workingDirectory: String, argv: [String]) throws -> ManagedTerminalStatus {
    guard let endpoint else { throw ManagedSessionError.runtimeUnavailable("managed mode disabled") }
    if serverIdentity == nil { _ = connect() }
    guard connectionState == .online else {
      throw ManagedSessionError.runtimeUnavailable(lastError ?? "server unavailable")
    }
    let status = try client.createTerminal(
      endpoint, workingDirectory: workingDirectory, argv: argv)
    return status
  }

  /// 查询该会话全部受管终端的真实状态。
  func liveTerminals() throws -> [ManagedTerminalStatus] {
    guard let endpoint else { throw ManagedSessionError.runtimeUnavailable("managed mode disabled") }
    return try client.listTerminals(endpoint)
  }

  /// 重开 App 后对账持久化引用与服务端实测状态。
  func reconcile(
    references: [ManagedTerminalReference],
    persistedServerEpoch: String?
  ) -> [ManagedTerminalReference: ManagedTerminalResolution] {
    guard endpoint != nil else {
      return Dictionary(
        uniqueKeysWithValues: references.map {
          ($0, ManagedTerminalResolution.unreachable($0, reason: "managed mode disabled"))
        })
    }
    let identity = connect()
    let live = (try? liveTerminals()) ?? []
    return ManagedTerminalReconciler.reconcile(
      references: references,
      liveTerminals: live,
      currentServer: identity?.reference,
      currentServerEpoch: identity?.serverEpoch,
      persistedServerEpoch: persistedServerEpoch,
      unreachableReason: identity == nil ? (lastError ?? "server unavailable") : nil
    )
  }

  /// 结束受管终端：这是资源关闭语义，会结束远端进程。
  @discardableResult
  func terminate(_ reference: ManagedTerminalReference) -> ManagedTerminalStatus? {
    guard let endpoint else { return nil }
    guard let status = try? client.terminateTerminal(endpoint, terminalID: reference.terminalID)
    else { return nil }
    // 真实结束由服务端上报；这里进入去重器，保证只写一次结束事件。
    _ = lifecycle.handle(.serverReportedEnd(status))
    return status
  }

  /// 分离：只释放本客户端资源，服务端进程与布局保留，不写结束事件。
  func detach(_ reference: ManagedTerminalReference) {
    _ = lifecycle.handle(.clientDetached(reference))
  }

  /// 服务端上报的真实结束是否应写入录制层；重复上报返回 false。
  func shouldRecordEnd(for status: ManagedTerminalStatus) -> Bool {
    if case .recordEnded = lifecycle.handle(.serverReportedEnd(status)) { return true }
    return false
  }

  /// 生成 Ghostty surface 的桥命令文本。
  ///
  /// surface 的子进程是桥而不是任务本身，关闭 surface 只结束桥，受管进程继续运行。
  func bridgeCommandText(for reference: ManagedTerminalReference, readOnly: Bool = false) -> String?
  {
    guard let endpoint else { return nil }
    let arguments = client.bridgeArguments(
      endpoint, terminalID: reference.terminalID, readOnly: readOnly)
    // 桥的可执行文件由传输实现决定：本机是 aster-session 本身，SSH 是 /usr/bin/ssh。
    return GhosttyConfiguration.launchCommand(
      shell: client.bridgeExecutablePath(endpoint), arguments: arguments)
  }
}
