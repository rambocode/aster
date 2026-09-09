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
  private var lifecycle = ManagedTerminalLifecycleTracker()
  /// 最近一次成功握手的服务身份；用于识别冷重启。
  private(set) var serverIdentity: SessionServerIdentity?
  private(set) var connectionState: SessionConnectionState = .disconnected
  /// 最近一次连接失败原因，用于界面显示明确错误而不是静默回退。
  private(set) var lastError: String?

  init(
    client: any ManagedSessionClient = LocalManagedSessionClient(),
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.client = client
    self.environment = environment
  }

  /// 受管模式是否可用。缺少显式配置时返回 nil，调用方保持既有本地终端行为。
  var endpoint: ManagedSessionEndpoint? {
    guard let binary = environment[Self.binaryEnvironmentKey], !binary.isEmpty,
      let stateParent = environment[Self.stateDirectoryEnvironmentKey], !stateParent.isEmpty
    else { return nil }
    return ManagedSessionEndpoint(
      binaryPath: binary,
      stateParentPath: stateParent,
      sessionName: environment[Self.sessionNameEnvironmentKey] ?? "default"
    )
  }

  var isEnabled: Bool { endpoint != nil }

  /// 连接（必要时启动）本地默认后台服务。Local 允许首次使用时自动启动或附加。
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
    return GhosttyConfiguration.launchCommand(
      shell: endpoint.binaryPath, arguments: arguments)
  }
}
