import AppKit
import AsterCore
import Foundation

/// 远端机器的结构变更出口（P4.2）。
///
/// `AppModel` 只认这个协议：活动机器是远端时，新建标签 / 分屏 / 关闭 / 改标题被拦下来
/// 交给它，翻译成带 `expectedRevision` 的服务端事务。
@MainActor
protocol RemoteStructureHandling: AnyObject {
  func createTab(workingDirectory: String?)
  func splitPane(tabID: UUID, paneID: UUID, direction: SplitDirection)
  func closeTab(tabID: UUID)
  func closePane(tabID: UUID, paneID: UUID)
  func renameTab(tabID: UUID, title: String)
}

/// 本进程的共享工作区客户端标识（P4.2）。
///
/// 仓库里没有现成的进程级客户端 ID：`AsterControlConnection.clientID` 是「每条控制连接
/// 一个」的短命 ID，不能拿来标识客户端本身——焦点、画面兴趣、写租约都以客户端为单位，
/// 换一条控制连接就换 ID 会把自己已持有的租约丢掉。
/// 形状必须是小写 UUID：`SessionOperationRequest.validID` 只接受这一种。
enum RemoteClientIdentity {
  /// 进程启动后首次读取时生成，进程存活期间不变；刻意不落盘——跨进程复用同一个 ID 会
  /// 让服务端把上一次运行残留的画面订阅与写租约算到本次运行头上。
  private static let value = UUID().uuidString.lowercased()

  static func clientID() -> String { value }
}

/// 一台远端机器的工作区投影状态。
///
/// 单独成型而不是塞进字典：远端 tabID（字符串）与本地标签身份（UUID）必须成对保存，
/// 拆成两张平行表很容易在刷新时对错标签，把 A 标签的布局盖到 B 标签上。
@MainActor
final class RemoteMachineWorkspace {
  let machineProfileID: UUID
  let controller: RemoteWorkspaceController
  /// 远端 tabID → 本地标签实例。刷新时据此复用实例，避免整树重建 Ghostty surface。
  var tabsByRemoteID: [String: TerminalTabItem] = [:]
  /// 最近一次投影里第一个工作区的 ID；新建标签事务需要它。
  var workspaceID: String?
  /// 该机器最近一次刷新的错误；界面显示明确原因而不是空标签栏。
  var lastError: String?
  /// 空会话的首个工作区是否已经请求过。失败后不自动重试，避免「刷新 → 建 → 失败 → 刷新」循环。
  var initialWorkspaceRequested = false
  /// 最近一次已请求过冷恢复的失效终端集合。同一批失效终端只请求一次 `session.restore`：
  /// 恢复失败、或服务端已恢复过却仍失效时不再自旋，窗格保持明确的错误卡等待用户重试。
  var restoreAttemptedForStale: Set<String> = []

  init(machineProfileID: UUID, controller: RemoteWorkspaceController) {
    self.machineProfileID = machineProfileID
    self.controller = controller
  }
}

/// 把远端服务快照投影渲染成 `AppModel` 的标签 / 递归分屏（P4.2 / P4.6 / P4.2a）。
///
/// 分工：领域规则全部在 `RemoteWorkspaceController` 与 AsterCore；这里只做三件事——
/// 1. 把投影结果对齐成 `TerminalTabItem` 集合并装载进 `AppModel`；
/// 2. 按可见性真实发出/取消画面订阅（显示桥 = 画面订阅），并在快照确认前挡住键盘；
/// 3. 把界面上的结构动作翻译成服务端事务。
@MainActor
final class RemoteWorkspaceCoordinator: RemoteStructureHandling {
  /// 宿主模型。
  ///
  /// 必须用 `weak` 而不是 `unowned`：刷新、事件流回调和结构事务都是异步的，在途 Task
  /// 会通过 `[weak self]` 把协调器续命到窗口销毁之后。那时模型可能已经释放，`unowned`
  /// 会直接崩溃（实测 "Attempted to read an unowned reference but object was already
  /// destroyed"）。模型不在了就说明这个窗口的界面已经没有了，依赖模型的动作应当安静
  /// 放弃，而不是让 App 崩掉。
  private weak var model: AppModel?
  /// 本客户端 ID。焦点属于客户端：切换机器不改变其它客户端的焦点，重连也不抢焦点。
  private let clientID: String
  private var workspaces: [UUID: RemoteMachineWorkspace] = [:]
  /// 每台机器一条事件订阅（P4.2 事件流）。
  ///
  /// 刻意与画面订阅分开保存：切走机器只取消画面订阅，事件订阅必须继续跑，否则
  /// 后台机器的结构变更要等到下次显式切回才被发现（`docs/developer/remote-work.md` §4.2）。
  private var subscriptions: [UUID: SessionEventStreamClient] = [:]
  /// 刷新完成后的界面回调（侧栏/标签栏重画）。
  var onDidRefresh: (() -> Void)?
  /// 最近一次失败原因，供界面显示。
  private(set) var lastError: String?
  /// 协调器是否已经整体收尾（窗口关闭 / App 退出 / 验收收尾）。
  ///
  /// 停订阅只是**不再收新事件**，队列里仍可能排着在途的 MainActor 任务：事件刷新、
  /// 事务收尾、连接结束回调。这些任务如果在窗口已经拆掉之后才执行，就会去动早已释放的
  /// Ghostty 画面——实测下一次主线程跑事件循环时会崩在 CoreAnimation 提交里
  /// （`os_unfair_lock is corrupt`）。所以收尾之后一律让它们变成空操作。
  private var isStopped = false

  /// 「重新启动 Shell」对受管失败窗格的转发观察者（见 `retryStalePanes`）。
  /// `nonisolated(unsafe)`：只在 init 写入、deinit 读取，两处都不会与主线程并发。
  nonisolated(unsafe) private var managedRetryObserver: (any NSObjectProtocol)?

  init(model: AppModel, clientID: String = RemoteClientIdentity.clientID()) {
    self.model = model
    self.clientID = clientID
    // 受管终端失败的窗格点「重新启动 Shell」时，重启本地 surface 只会再次渲染同一错误；
    // 真正能救回它的是重新对账 + 冷恢复，这件事只有协调器能做。
    managedRetryObserver = NotificationCenter.default.addObserver(
      forName: TerminalSession.managedRetryRequested, object: nil, queue: .main
    ) { [weak self] _ in
      Task { @MainActor [weak self] in await self?.retryStalePanes() }
    }
  }

  deinit {
    // 窗口销毁：订阅子进程必须跟着结束，否则会留下孤儿 ssh/aster-session。
    for client in subscriptions.values { client.stop() }
    if let managedRetryObserver { NotificationCenter.default.removeObserver(managedRetryObserver) }
  }

  /// 停止全部事件订阅并让协调器整体失效（窗口关闭、App 退出、验收收尾）。
  ///
  /// 不影响远端任何资源：事件订阅只是一条**只读**控制连接，结束它既不结束远端终端
  /// 进程，也不动写租约与画面订阅之外的任何状态。
  func stopAllEventSubscriptions() {
    isStopped = true
    for machineProfileID in subscriptions.keys {
      stopEventSubscription(forMachine: machineProfileID)
    }
    // 模型强持有本协调器（`remoteStructureHandler`）。窗口没了还留着这个引用，协调器
    // 就会比窗口活得久，在途回调仍然会去动已经拆掉的界面。这里主动断开这条持有。
    if model?.remoteStructureHandler === self { model?.remoteStructureHandler = nil }
  }

  // MARK: - 机器切换

  /// 切换到某台机器并渲染它的标签集合。
  ///
  /// 顺序是硬性的：先把切走的机器的画面订阅真实取消，再切标签集合，最后才取新机器的
  /// 完整快照。反过来会在快照到达前把上一台机器的画面继续拉过来，也会让键盘输入落进
  /// 一个尚未确认结构的会话里。
  func activate(machineProfileID: UUID) async {
    guard beginActivation(machineProfileID: machineProfileID) else { return }
    await refresh(machineProfileID: machineProfileID)
  }

  /// 机器切换的**同步前半程**：取消旧机器画面订阅 → 换标签集合 → 关闸。
  ///
  /// 单独暴露而不是全塞进 `activate`：「重新可见但完整快照尚未确认」这个中间态只在
  /// 这一段之后、`refresh` 之前成立，验收必须能在这个状态上断言 `allowsInput == false`。
  /// 返回 false 表示不需要（或不该）再取远端快照。
  @discardableResult
  func beginActivation(machineProfileID: UUID) -> Bool {
    // 模型已释放（窗口销毁）或协调器已收尾时直接放弃，不再改任何界面状态。
    guard !isStopped, let model else { return false }
    let previous = model.activeMachineID
    if previous != machineProfileID { suspendSurfaces(forMachine: previous) }
    guard model.switchMachine(to: machineProfileID) else { return false }

    guard machineProfileID != MachineProfile.localProfileID else {
      // Local 完全走 P2/P3 的既有路径，一个字节都不改。
      model.remoteStructureHandler = nil
      onDidRefresh?()
      return false
    }
    model.remoteStructureHandler = self
    // 快照到达之前先关闸门：这台机器可能是重新可见，缓存里的 Pane 不能立即接受输入。
    closeInputGates(forMachine: machineProfileID)
    onDidRefresh?()
    return true
  }

  /// 取一次完整快照并把投影结果装载成该机器的标签集合。
  @discardableResult
  func refresh(machineProfileID: UUID) async -> Bool {
    guard !isStopped, machineProfileID != MachineProfile.localProfileID else { return false }
    guard let workspace = await ensureWorkspace(machineProfileID: machineProfileID) else {
      lastError = "机器未配置远端运行时，无法读取共享工作区。"
      onDidRefresh?()
      return false
    }
    do {
      var projection = try await workspace.controller.synchronize()
      let restoreError = await restoreStalePanesIfNeeded(&projection, workspace: workspace)
      guard !isStopped else { return false }
      apply(projection: projection, to: workspace)
      // 冷恢复失败不掩盖快照本身：结构照常显示，失效窗格保持错误卡，原因进入 lastError。
      lastError = restoreError
      workspace.lastError = restoreError
      onDidRefresh?()
      ensureInitialWorkspace(projection: projection, workspace: workspace)
      return restoreError == nil
    } catch {
      let message = RemoteSetupDescription.text(for: error)
      lastError = message
      workspace.lastError = message
      onDidRefresh?()
      return false
    }
  }

  /// `session.restore` 的初始终端尺寸。只是新进程的起始值：显示桥附加后会按真实画面
  /// 重新调整，因此不需要从某个 Pane 里去猜。
  static let restoreGeometry = (rows: 40, columns: 120)

  /// 快照里有窗格引用了已不存在的终端（服务端冷重启 / 二进制替换后的典型状态）时，
  /// 请求一次 `session.restore`（P6.4）并重新取快照，把 `projection` 换成恢复后的结构。
  ///
  /// 返回恢复失败的原因；nil 表示无需恢复或已成功。恢复只按「失效终端集合」去重：
  /// 集合不变就不再请求，否则恢复失败会变成「刷新 → 恢复 → 失败 → 事件 → 刷新」的循环。
  private func restoreStalePanesIfNeeded(
    _ projection: inout ProjectedRemoteSession, workspace: RemoteMachineWorkspace
  ) async -> String? {
    let stale = RemoteWorkspaceController.staleTerminalIDs(in: projection)
    guard !stale.isEmpty else {
      workspace.restoreAttemptedForStale = []
      return nil
    }
    guard workspace.restoreAttemptedForStale != stale else { return nil }
    workspace.restoreAttemptedForStale = stale
    do {
      let result = try await workspace.controller.restoreStalePanes(
        rows: Self.restoreGeometry.rows, columns: Self.restoreGeometry.columns)
      guard !isStopped else { return nil }
      // 服务端只回映射表，权威结构仍以快照为准；`alreadyRestored` 同样要重取快照——
      // 说明另一个客户端刚恢复过，本地缓存的引用已经过期。
      projection = try await workspace.controller.synchronize()
      let failed = result.entries.filter { $0.path == "failed" }
      guard failed.isEmpty else {
        return "远端有 \(failed.count) 个终端恢复失败：\(failed.first?.failureReason ?? "未知原因")"
      }
      return nil
    } catch {
      return "远端终端冷恢复失败：\(RemoteSetupDescription.text(for: error))"
    }
  }

  /// 用户对受管失败窗格点了「重新启动 Shell」：清掉去重记录后重新刷新活动机器，
  /// 让 `restoreStalePanesIfNeeded` 再请求一次冷恢复。
  func retryStalePanes() async {
    guard !isStopped, let model else { return }
    let machineProfileID = model.activeMachineID
    guard let workspace = workspaces[machineProfileID] else { return }
    workspace.restoreAttemptedForStale = []
    await refresh(machineProfileID: machineProfileID)
  }

  /// 消费一条服务端事件（`workspace.changed` / `tab.changed` / `pane.changed` / `terminal.*`）。
  ///
  /// 正文只是变更片段，权威结构仍以快照为准，因此顺序正确与序号缺口都重新取快照；
  /// 只有重复/过期事件被安全丢弃。
  func handleEvent(sequence: UInt64, machineProfileID: UUID) async {
    guard !isStopped, let workspace = workspaces[machineProfileID] else { return }
    switch workspace.controller.consume(eventSequence: sequence) {
    case .duplicate:
      return
    case .applied, .gap:
      await refresh(machineProfileID: machineProfileID)
    }
  }

  // MARK: - 远端 Agent 事件桥接（P5.5）

  /// 跨机器 Agent 状态聚合器。
  let agentAggregator = RemoteAgentStateAggregator()
  /// 通知服务注入点；测试替换为替身。
  var agentNotificationPoster: (any TerminalNotificationPosting)?

  /// 处理服务端 agent.changed 事件：解码 → 桥接到 TerminalSession → 聚合 → 通知。
  ///
  /// 远端 agent 状态由服务端权威决定。本地屏幕检测对远端 Pane 不与服务端竞争——
  /// 每 provider 一个固定权威（见 P5.2 RemoteAgentStateAuthority）。
  func handleAgentEvent(_ event: RemoteSessionEvent, machineProfileID: UUID) {
    guard !isStopped else { return }
    // 事件去重：(serverID, epoch, eventID)
    let dedupKey = RemoteAgentEventKey(
      serverID: event.target.serverID,
      epoch: event.target.serverEpoch,
      eventID: event.eventID)
    guard !agentAggregator.checkAndRecordEvent(dedupKey) else { return }

    // 解码 agent 信息
    guard let body = event.decodedBody(),
      let agentJSON = body["agent"] as? [String: Any] ?? Optional(body),
      let info = decodeAgentInfo(agentJSON)
    else { return }

    // 桥接到对应的 TerminalSession
    if let session = session(forTerminalID: info.terminalID, machineProfileID: machineProfileID) {
      session.applyRemoteAgentState(info)
    }

    // 聚合并通知
    _ = agentAggregator.aggregate(machineID: machineProfileID, agents: [info])
    postAgentNotificationIfNeeded(info: info, machineProfileID: machineProfileID)
  }

  /// 解码 JSON 字典为 RemoteAgentInfo。容错：字段缺失时取默认值。
  private func decodeAgentInfo(_ json: [String: Any]) -> RemoteAgentInfo? {
    guard let terminalID = json["terminalID"] as? String,
      let providerRaw = json["provider"] as? String,
      let provider = AgentProvider(rawValue: providerRaw),
      let stateRaw = json["state"] as? String,
      let state = RemoteAgentStatus(rawValue: stateRaw)
    else { return nil }
    let sourceRaw = json["source"] as? String ?? "heuristic"
    let source = RemoteAgentAuthority(rawValue: sourceRaw) ?? .heuristic
    return RemoteAgentInfo(
      terminalID: terminalID,
      provider: provider,
      state: state,
      name: json["name"] as? String,
      nativeSession: json["nativeSession"] as? String,
      source: source,
      unread: json["unread"] as? Bool ?? false)
  }

  /// 按 terminalID 找到对应的 TerminalSession（跨所有标签页搜索）。
  private func session(forTerminalID terminalID: String, machineProfileID: UUID)
    -> TerminalSession?
  {
    guard let model else { return nil }
    for tab in model.tabs(forMachine: machineProfileID) {
      for pane in tab.layout.allPanes
      where pane.managedTerminal?.terminalID == terminalID {
        return tab.runtime(for: pane.id)?.terminalSession
      }
    }
    return nil
  }

  /// 远端 Agent 通知使用的默认 Shell 配置。远端 Agent 事件不与本地 Pane 的偏好绑定——
  /// 它们可能发生在后台机器上，没有对应的前台标签。
  private static let agentNotificationShellConfig = ShellConfiguration.agentNotificationDefault

  /// 根据 Agent 状态决定是否发送 macOS 通知。
  ///
  /// 规则：blocked 发"等待输入"，done+unread 发"已完成"；stale(unknown) 不通知完成；
  /// 重复事件由 agentAggregator.checkAndRecordEvent 在入口处拦截，不会到这里。
  private func postAgentNotificationIfNeeded(info: RemoteAgentInfo, machineProfileID: UUID) {
    let poster = agentNotificationPoster ?? TerminalNotificationService.shared
    let machineName = machineLabel(for: machineProfileID)
    let providerName = info.provider.displayName

    switch info.state {
    case .blocked:
      let notification = TerminalNotification(
        identifier: "agent.\(machineProfileID).\(info.terminalID).blocked",
        title: "\(providerName) 等待输入",
        body: "\(machineName) 上的 \(providerName) 需要你的确认。",
        urgency: .normal)
      poster.post(
        notification, category: .commandFinish,
        configuration: Self.agentNotificationShellConfig,
        sourceTabIsFocused: false)
    case .done where info.unread:
      let notification = TerminalNotification(
        identifier: "agent.\(machineProfileID).\(info.terminalID).done",
        title: "\(providerName) 已完成",
        body: "\(machineName) 上的 \(providerName) 任务已完成。",
        urgency: .normal)
      poster.post(
        notification, category: .commandFinish,
        configuration: Self.agentNotificationShellConfig,
        sourceTabIsFocused: false)
    default:
      break
    }
  }

  /// 取机器显示标签。远端机器用 SSH target，本机用 "Local"。
  private func machineLabel(for machineProfileID: UUID) -> String {
    ManagedTerminalCoordinatorRegistry.coordinator(forMachine: machineProfileID)
      .remoteMachineLabel ?? "远端机器"
  }

  /// 机器断线时标记其所有 Agent 为 stale（不伪造完成）。
  private func staleAgentsForMachine(_ machineProfileID: UUID) {
    agentAggregator.staleAllForMachine(machineID: machineProfileID)
    // 清除该机器所有 session 的远端权威标记
    guard let model else { return }
    for tab in model.tabs(forMachine: machineProfileID) {
      for pane in tab.layout.allPanes where pane.managedTerminal != nil {
        tab.runtime(for: pane.id)?.terminalSession?.clearRemoteAgentState()
      }
    }
  }

  /// 连接中断：订阅、闸门与事件游标全部作废。
  func connectionLost(machineProfileID: UUID) {
    stopEventSubscription(forMachine: machineProfileID)
    staleAgentsForMachine(machineProfileID)
    guard !isStopped, let workspace = workspaces[machineProfileID] else { return }
    apply(intents: workspace.controller.connectionLost(), to: workspace)
    closeInputGates(forMachine: machineProfileID)
  }

  // MARK: - P4.2 事件流

  /// 该机器当前是否持有一条事件订阅。验收据此断言订阅确实是活的。
  func hasEventSubscription(forMachine machineProfileID: UUID) -> Bool {
    subscriptions[machineProfileID] != nil
  }

  /// 为一台机器启动事件订阅。
  ///
  /// 订阅是纯被动的：它既不切换活动机器，也不移动焦点——收到事件只会让这台机器
  /// 重新取一次快照。目标身份取自刚完成的真实握手，事件身份不符时解码器会报 stale
  /// 而不是投递，避免把另一个服务实例的结构盖到本地。
  private func startEventSubscription(
    forMachine machineProfileID: UUID,
    transactions: WorkspaceTransactionClient,
    identity: SessionServerIdentity
  ) {
    guard !isStopped, subscriptions[machineProfileID] == nil else { return }
    let expected = RemoteSessionEventTarget(
      serverID: identity.reference.serverID,
      serverEpoch: identity.serverEpoch,
      sessionID: identity.reference.sessionID)
    let source = ProcessSessionEventLineSource(
      invocation: transactions.client.eventSubscribeInvocation(transactions.endpoint))
    // 回调发生在订阅进程的读队列上，全部跳回 MainActor 再碰模型。
    let callbacks = SessionEventStreamClient.Callbacks(
      onSubscribed: { subscription in
        Task { @MainActor [weak self] in
          await self?.eventStreamSubscribed(subscription, machineProfileID: machineProfileID)
        }
      },
      onEvent: { event in
        Task { @MainActor [weak self] in
          if event.kind == .agentChanged {
            self?.handleAgentEvent(event, machineProfileID: machineProfileID)
          } else {
            await self?.handleEvent(sequence: event.sequence, machineProfileID: machineProfileID)
          }
        }
      },
      onResynchronize: { _ in
        // 缺口 / 身份不符 / 未知事件：本地缓存不可信，只能重新取快照。
        Task { @MainActor [weak self] in
          self?.invalidateProjection(forMachine: machineProfileID)
          await self?.refresh(machineProfileID: machineProfileID)
        }
      },
      onConnectionLost: { termination in
        // 主动停止是本客户端自己发起的：界面收尾已经在停止点做完了。再排一个
        // `connectionLost` 只会在窗口拆掉之后重入界面去动已释放的画面。
        // 只有**意外**结束（进程退出 / 启动失败）才需要作废本地缓存并关闸。
        guard termination != .stopped else { return }
        Task { @MainActor [weak self] in self?.connectionLost(machineProfileID: machineProfileID) }
      })
    let client = SessionEventStreamClient(
      source: source, expectedTarget: expected, callbacks: callbacks)
    subscriptions[machineProfileID] = client
    client.start()
  }

  /// 停止并丢弃一台机器的事件订阅。幂等。
  private func stopEventSubscription(forMachine machineProfileID: UUID) {
    guard let client = subscriptions.removeValue(forKey: machineProfileID) else { return }
    client.stop()
  }

  /// 收到基线握手：只有基线 revision 与本地不一致才补一次快照，避免每次订阅都多跑一趟。
  ///
  /// 初始 synchronize 尚未完成时 controller.revision 为 0，几乎任何非零订阅
  /// revision 都会被误判为"不一致"而触发第二次 refresh。这个竞态会在首次 refresh
  /// 完成前重建画面兴趣集合，导致显示桥被拆掉又重建。用 projection == nil 守护：
  /// 首次 apply 设置投影之前不补快照，让初始 refresh 独占首轮同步。
  private func eventStreamSubscribed(
    _ subscription: RemoteSessionSubscription, machineProfileID: UUID
  ) async {
    guard !isStopped, let workspace = workspaces[machineProfileID] else { return }
    // 初始 synchronize 尚未完成（projection 为 nil）时跳过：让首次 refresh 独占。
    guard workspace.controller.projection != nil else { return }
    guard subscription.revision != workspace.controller.revision else { return }
    await refresh(machineProfileID: machineProfileID)
  }

  /// 把该机器的投影标记为不可信，使下一次 `handleEvent` 走缺口分支。
  private func invalidateProjection(forMachine machineProfileID: UUID) {
    workspaces[machineProfileID]?.controller.connectionLost()
  }

  // MARK: - 投影渲染

  /// 把投影结果对齐成标签集合。
  ///
  /// 复用既有 `TerminalTabItem` 实例（按远端 tabID 匹配）而不是重建：重建会连同 Ghostty
  /// surface 一起换掉，等于每来一次快照就把用户的终端画面清空一次。
  private func apply(projection: ProjectedRemoteSession, to workspace: RemoteMachineWorkspace) {
    workspace.workspaceID = projection.workspaces.first?.workspaceID
    var aligned: [TerminalTabItem] = []
    var byRemoteID: [String: TerminalTabItem] = [:]
    var visibleTerminals: Set<String> = []

    for remoteWorkspace in projection.workspaces {
      for tab in remoteWorkspace.tabs {
        // 来源客户端的本地资源关联在这里被复原；其它客户端 `localAssociations` 为空，
        // 因此渲染出来的结构里不会出现来源客户端的 resourcePath（P4.2a）。
        let layout = workspace.controller.displayLayout(for: tab)
        let item: TerminalTabItem
        if let existing = workspace.tabsByRemoteID[tab.tabID] {
          existing.applyRemoteLayout(layout, title: tab.title)
          item = existing
        } else {
          item = TerminalTabItem(
            title: tab.title, workingDirectory: remoteWorkspace.cwd, layout: layout)
          item.remoteTabID = tab.tabID
        }
        aligned.append(item)
        byRemoteID[tab.tabID] = item
        for pane in layout.allPanes {
          if let terminalID = pane.managedTerminal?.terminalID { visibleTerminals.insert(terminalID) }
        }
      }
    }

    // 服务端已经删掉的标签：按分离语义拆本地运行态，绝不 terminate 远端进程。
    for (remoteID, item) in workspace.tabsByRemoteID where byRemoteID[remoteID] == nil {
      item.stop(disposition: .detached)
    }
    workspace.tabsByRemoteID = byRemoteID
    guard let model else { return }
    model.setTabs(aligned, forMachine: workspace.machineProfileID)

    // 只有当前活动机器才是「可见」的；后台机器保持零画面订阅，仍接收结构与 Agent 事件。
    let visible = workspace.machineProfileID == model.activeMachineID ? visibleTerminals : []
    apply(intents: workspace.controller.setVisibleTerminals(visible), to: workspace)
    applyInputGates(for: workspace)
  }

  // MARK: - P4.6 画面兴趣与交互闸门

  /// 执行画面兴趣意图。
  ///
  /// 本架构里「画面订阅」就是 Ghostty surface 的显示桥子进程：取消订阅 = 拆桥（分离，
  /// 不写结束事件、不动远端进程），重新订阅 = 重建桥。
  /// `requestSnapshot` 由调用方刚取回的完整快照满足，随即确认放行交互。
  private func apply(intents: [SurfaceInterestIntent], to workspace: RemoteMachineWorkspace) {
    for intent in intents {
      switch intent {
      case .subscribe(let terminalID):
        session(forTerminal: terminalID, in: workspace)?.reattachManagedTerminal()
      case .unsubscribe(let terminalID):
        session(forTerminal: terminalID, in: workspace)?.detachManagedTerminal()
      case .requestSnapshot(let terminalID):
        workspace.controller.confirmSnapshot(terminalID: terminalID)
      }
    }
  }

  /// 把闸门状态落到真实键盘输入上：快照确认之前该 Pane 不接受按键。
  private func applyInputGates(for workspace: RemoteMachineWorkspace) {
    guard let model else { return }
    for tab in model.tabs(forMachine: workspace.machineProfileID) {
      for pane in tab.layout.allPanes {
        guard let terminalID = pane.managedTerminal?.terminalID,
          let session = tab.runtime(for: pane.id)?.terminalSession
        else { continue }
        session.setManagedInputGate(open: workspace.controller.allowsInput(terminalID: terminalID))
      }
    }
  }

  /// 该机器全部 Pane 关闸。用于「刚切回、快照尚未到达」。
  private func closeInputGates(forMachine machineProfileID: UUID) {
    guard let model else { return }
    for tab in model.tabs(forMachine: machineProfileID) {
      for pane in tab.layout.allPanes where pane.managedTerminal != nil {
        tab.runtime(for: pane.id)?.terminalSession?.setManagedInputGate(open: false)
      }
    }
  }

  /// 机器被切走：真实取消它全部画面订阅，后台仍接收结构与 Agent 事件。
  private func suspendSurfaces(forMachine machineProfileID: UUID) {
    guard machineProfileID != MachineProfile.localProfileID,
      let workspace = workspaces[machineProfileID]
    else { return }
    apply(intents: workspace.controller.suspendAllSurfaces(), to: workspace)
    closeInputGates(forMachine: machineProfileID)
  }

  private func session(forTerminal terminalID: String, in workspace: RemoteMachineWorkspace)
    -> TerminalSession?
  {
    guard let model else { return nil }
    for tab in model.tabs(forMachine: workspace.machineProfileID) {
      for pane in tab.layout.allPanes
      where pane.managedTerminal?.terminalID == terminalID {
        return tab.runtime(for: pane.id)?.terminalSession
      }
    }
    return nil
  }

  // MARK: - 结构事务

  func createTab(workingDirectory: String?) {
    guard let model, let workspace = workspaces[model.activeMachineID] else { return }
    // 服务端还没有任何工作区（全新会话、或工作区已被全部关闭）时，「新建标签」就是
    // 新建第一个工作区：`tab create` 必须挂在已有 workspace 上，否则只能静默失败，
    // 用户看到的就是"点了没反应"。
    guard let workspaceID = workspace.workspaceID else {
      let spec = initialTerminalSpec(workingDirectory: workingDirectory, in: workspace)
      submit(workspace) { controller in
        _ = try await controller.createWorkspace(title: spec.title, terminal: spec.terminal)
      }
      return
    }
    let cwd = workingDirectory ?? remoteFallbackDirectory(workspace)
    submit(workspace) { controller in
      _ = try await controller.createTab(
        workspaceID: workspaceID, title: TerminalTabItem.displayName(forDirectory: cwd),
        terminal: self.terminalSpec(cwd: cwd))
    }
  }

  /// 空会话在成为活动机器时自动建第一个工作区与 Shell，与本地「工作区永不为空」一致；
  /// 否则用户只看到一片空白。只对活动机器做：后台机器不凭空在远端创建进程。
  /// 请求失败时 `lastError` 已显示原因，不自动重试。
  private func ensureInitialWorkspace(
    projection: ProjectedRemoteSession, workspace: RemoteMachineWorkspace
  ) {
    guard !projection.workspaces.isEmpty else {
      guard let model, model.activeMachineID == workspace.machineProfileID,
        !workspace.initialWorkspaceRequested
      else { return }
      workspace.initialWorkspaceRequested = true
      createTab(workingDirectory: nil)
      return
    }
    workspace.initialWorkspaceRequested = false
  }

  /// 首个工作区的终端规格。没有任何服务端 cwd 可用时把落脚点交给远端 Shell 自己
  /// `cd "$HOME"`（cwd 先用 POSIX 保证存在的 `/`），标题按 `~` 显示而不是 `/`。
  private func initialTerminalSpec(workingDirectory: String?, in workspace: RemoteMachineWorkspace)
    -> (title: String, terminal: RemoteTerminalSpec)
  {
    if let cwd = workingDirectory ?? workspace.controller.projection?.workspaces.first?.cwd {
      return (TerminalTabItem.displayName(forDirectory: cwd), terminalSpec(cwd: cwd))
    }
    return (
      "~",
      RemoteTerminalSpec(
        cwd: ManagedTerminalLaunchSpec.remoteRootDirectory,
        argv: ManagedTerminalLaunchSpec.remoteArgv(landsInHome: true))
    )
  }

  func splitPane(tabID: UUID, paneID: UUID, direction: SplitDirection) {
    guard let model, let workspace = workspaces[model.activeMachineID] else { return }
    let cwd = workingDirectory(ofPane: paneID, in: workspace) ?? remoteFallbackDirectory(workspace)
    let remotePaneID = paneID.uuidString.lowercased()
    submit(workspace) { controller in
      _ = try await controller.splitPane(
        paneID: remotePaneID, direction: direction, terminal: self.terminalSpec(cwd: cwd))
    }
  }

  func closeTab(tabID: UUID) {
    guard let model, let workspace = workspaces[model.activeMachineID],
      let remoteTabID = model.tabs.first(where: { $0.id == tabID })?.remoteTabID
    else { return }
    submit(workspace) { controller in _ = try await controller.closeTab(tabID: remoteTabID) }
  }

  func closePane(tabID: UUID, paneID: UUID) {
    guard let model, let workspace = workspaces[model.activeMachineID] else { return }
    let remotePaneID = paneID.uuidString.lowercased()
    submit(workspace) { controller in _ = try await controller.closePane(paneID: remotePaneID) }
  }

  func renameTab(tabID: UUID, title: String) {
    guard let model, let workspace = workspaces[model.activeMachineID],
      let remoteTabID = model.tabs.first(where: { $0.id == tabID })?.remoteTabID
    else { return }
    submit(workspace) { controller in
      _ = try await controller.updateTab(tabID: remoteTabID, title: title)
    }
  }

  /// 事务提交的公共外壳：成功后必须重新取快照。
  ///
  /// 事务只回一个新 revision 与被改对象，不回整棵树；就地猜测新结构会与服务端分叉，
  /// 因此这里一律以「重新取快照」作为唯一的结构来源。
  private func submit(
    _ workspace: RemoteMachineWorkspace,
    _ body: @escaping (RemoteWorkspaceController) async throws -> Void
  ) {
    Task { @MainActor [weak self] in
      // 收尾之后不再提交任何事务：窗口都没了，改共享结构不再是用户意图。
      guard let self, !self.isStopped else { return }
      do {
        try await body(workspace.controller)
      } catch {
        // 失败也要重新取快照（服务端可能已部分变更），但取完快照后必须把事务错误
        // 放回去：refresh 成功会清掉 lastError，否则用户看到的就是"点了没反应"。
        let message = RemoteSetupDescription.text(for: error)
        await self.refresh(machineProfileID: workspace.machineProfileID)
        self.lastError = message
        workspace.lastError = message
        self.onDidRefresh?()
        return
      }
      await self.refresh(machineProfileID: workspace.machineProfileID)
    }
  }

  /// 新建远端终端的规格。规则与理由集中在 `ManagedTerminalLaunchSpec`，这里不再自行拼装：
  /// 两条路径各拼一份，正是 §6.9 那个「本机 `$SHELL` 被发到远端」缺陷的成因。
  private func terminalSpec(cwd: String) -> RemoteTerminalSpec {
    ManagedTerminalLaunchSpec.remoteSpec(cwd: cwd)
  }

  /// 远端 Pane 的工作目录来自服务端上报，绝不读取本机同路径补全。
  private func workingDirectory(ofPane paneID: UUID, in workspace: RemoteMachineWorkspace)
    -> String?
  {
    guard let model else { return nil }
    for tab in model.tabs(forMachine: workspace.machineProfileID) {
      if let pane = tab.layout.allPanes.first(where: { $0.id == paneID }) {
        return pane.workingDirectory
      }
    }
    return nil
  }

  /// 新建标签时的回退目录：取最近一次投影里工作区自身的 cwd，仍然是服务端数据。
  private func remoteFallbackDirectory(_ workspace: RemoteMachineWorkspace) -> String {
    workspace.controller.projection?.workspaces.first?.cwd ?? "/"
  }

  // MARK: - 构造

  /// 按机器取（必要时建）投影控制器。
  ///
  /// 服务引用必须来自一次真实握手：`SessionServerReference` 里的 serverID/sessionID 是
  /// 资源身份的一部分，凭配置猜出来的引用会让全部受管终端引用对不上。
  ///
  /// 握手走 `connectAsync()`：远端握手是一次 SSH 往返，在 MainActor 上同步等待会让
  /// 整个界面随网络延迟卡住。
  private func ensureWorkspace(machineProfileID: UUID) async -> RemoteMachineWorkspace? {
    if let existing = workspaces[machineProfileID] { return existing }
    guard !isStopped else { return nil }
    let coordinator = ManagedTerminalCoordinatorRegistry.coordinator(forMachine: machineProfileID)
    guard coordinator.machineProfileID == machineProfileID,
      let transactions = coordinator.transactionClient,
      let identity = await coordinator.connectAsync()
    else { return nil }
    let controller = RemoteWorkspaceController(
      clientID: clientID, server: identity.reference, transactions: transactions)
    let workspace = RemoteMachineWorkspace(
      machineProfileID: machineProfileID, controller: controller)
    workspaces[machineProfileID] = workspace
    // 机器在线即订阅：这条流独立于画面订阅，切走机器时不会被取消。
    startEventSubscription(
      forMachine: machineProfileID, transactions: transactions, identity: identity)
    return workspace
  }

  /// 测试注入入口：直接登记一台机器的投影控制器，不走真实握手。
  func register(controller: RemoteWorkspaceController, forMachine machineProfileID: UUID) {
    workspaces[machineProfileID] = RemoteMachineWorkspace(
      machineProfileID: machineProfileID, controller: controller)
  }

  /// 某台机器当前的投影控制器；验收用例据此断言 revision 与结构。
  func controller(forMachine machineProfileID: UUID) -> RemoteWorkspaceController? {
    workspaces[machineProfileID]?.controller
  }
}
