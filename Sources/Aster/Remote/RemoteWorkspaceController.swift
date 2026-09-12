import AsterCore
import Combine
import Foundation

/// 一台机器上共享工作区的客户端投影与事务编排（P4.2 / P4.2a / P4.6）。
///
/// 分工：领域规则（快照解码、投影、受管子树映射、事务重试、画面兴趣状态机）全部在
/// AsterCore；这里只做三件 App 侧的事——
/// 1. 把投影结果落到现有标签栏 / 递归分屏 / 终端 Pane 界面上；
/// 2. 保存**本客户端**的本地资源关联，使混合布局在来源客户端复原、在其他客户端不出现；
/// 3. 按可见性驱动画面订阅，并在快照确认前挡住键盘输入。
@MainActor
final class RemoteWorkspaceController: ObservableObject {
  /// 事件消费结果。
  enum EventDisposition: Equatable {
    /// 顺序正确，已应用。
    case applied
    /// 重复或过期事件，安全丢弃。
    case duplicate
    /// 出现序号缺口：必须重新取快照，且在快照到达前不能把缓存标成最新。
    case gap
  }

  /// 最近一次成功投影的结果。nil 表示尚无快照。
  @Published private(set) var projection: ProjectedRemoteSession?
  /// 服务端权威 revision；事务必须原样带回去，不能自增猜测。
  @Published private(set) var revision: UInt64 = 0
  /// 是否正在等待重新同步（事件缺口或新连接之后）。
  @Published private(set) var needsResynchronization = true

  /// 本客户端的画面兴趣与焦点。焦点属于客户端，不跟随其它客户端。
  private(set) var interest: ClientSurfaceInterest
  /// 本客户端保留的本地资源关联（P4.2a）。它**只存在本地**，不进入任何提交载荷。
  private(set) var localAssociations: [UUID: LocalPaneAssociation] = [:]

  private let server: SessionServerReference
  private let transactions: WorkspaceTransactionClient
  /// 当前连接内已消费的最大事件序号。新连接必须重置它。
  private var lastSequence: UInt64?

  init(
    clientID: String,
    server: SessionServerReference,
    transactions: WorkspaceTransactionClient
  ) {
    self.interest = ClientSurfaceInterest(clientID: clientID)
    self.server = server
    self.transactions = transactions
  }

  // MARK: - 快照与事件

  /// 取一份完整快照并投影。
  ///
  /// 传输是阻塞的结构化调用，必须离开主线程：共享工作区的每一次快照都是一次 SSH
  /// 往返，在 MainActor 上同步等待会让整个界面随网络延迟卡住。
  @discardableResult
  func synchronize() async throws -> ProjectedRemoteSession {
    let client = transactions
    let snapshot = try await Task.detached(priority: .userInitiated) {
      try client.snapshot()
    }.value
    return try apply(snapshot: snapshot)
  }

  /// 应用一份已取回的快照。
  @discardableResult
  func apply(snapshot: RemoteSessionSnapshot) throws -> ProjectedRemoteSession {
    let projected = try RemoteWorkspaceProjection.project(snapshot: snapshot, server: server)
    projection = projected
    revision = projected.revision
    needsResynchronization = false
    return projected
  }

  /// 连接重建：订阅、闸门与事件游标全部作废，重新可见时必须再走「订阅 + 快照」。
  @discardableResult
  func connectionLost() -> [SurfaceInterestIntent] {
    lastSequence = nil
    needsResynchronization = true
    return interest.connectionLost()
  }

  /// 消费一条服务端事件。
  ///
  /// 只做顺序判定与失效标记，不在这里改布局：`workspace.changed / tab.changed /
  /// pane.changed / terminal.*` 的正文只是变更片段，权威结构仍以快照为准，
  /// 因此顺序正确时由调用方触发一次 `synchronize()`，缺口时同样重新取快照。
  func consume(eventSequence sequence: UInt64) -> EventDisposition {
    if needsResynchronization { return .gap }
    guard let last = lastSequence else {
      lastSequence = sequence
      return .applied
    }
    if sequence <= last { return .duplicate }
    if sequence == last + 1 {
      lastSequence = sequence
      return .applied
    }
    // 缺口：中间的事件永久丢失，缓存不能再被当作最新。
    needsResynchronization = true
    return .gap
  }

  // MARK: - P4.2a 混合布局

  /// 记录本客户端的本地资源关联。提交共享结构之前必须先调用它。
  func captureLocalAssociations(from layout: PaneLayout) {
    localAssociations.merge(ManagedSubtreeMapping.captureLocalAssociations(in: layout)) {
      _, new in new
    }
  }

  /// 生成可提交给服务端的受管终端子树。
  ///
  /// 返回类型是 `RemoteLayoutNode`——它在**类型层面**就没有 `resourcePath`，
  /// 因此本地文件路径不可能随提交泄漏到其它客户端。
  func submission(for layout: PaneLayout) -> ManagedSubtreeSubmission {
    ManagedSubtreeMapping.submission(for: layout)
  }

  /// 把一个远端标签的共享结构合并成本客户端要显示的布局。
  ///
  /// 来源客户端带着自己的 `localAssociations`，因此本地文件/编辑器/预览/Web Pane 的
  /// 关联被复原；其它客户端的 `localAssociations` 为空，只会看到纯终端结构。
  func displayLayout(for tab: ProjectedRemoteTab) -> PaneLayout {
    ManagedSubtreeMapping.merge(shared: tab.layout, localAssociations: localAssociations)
  }

  /// 远端工作区是否允许某个本机文件类动作（P3.7 / §4.2）。
  ///
  /// 恒为 false：入口必须禁用并显示原因，而不是点了之后失败。
  func allowsLocalAction(_ action: RemoteWorkspaceBoundary.LocalAction) -> Bool {
    RemoteWorkspaceBoundary.isAllowedOnRemotePane(action)
  }

  /// 被禁用的本机动作的原因文案。
  func disabledReason(
    _ action: RemoteWorkspaceBoundary.LocalAction, machineLabel: String
  ) -> String {
    RemoteWorkspaceBoundary.disabledReason(action, machineLabel: machineLabel)
  }

  // MARK: - P4.6 焦点与画面兴趣

  /// 设置本客户端焦点。不产生订阅命令：可见性与焦点是两件事。
  func focus(paneID: UUID?) {
    interest.focus(paneID: paneID)
  }

  /// 把可见终端集合更新为 `visible`，返回需要真实发出的订阅意图。
  ///
  /// 新可见的终端先 subscribe 再 requestSnapshot，不再可见的 unsubscribe——
  /// 「只是不画」不算取消订阅，服务端仍会为它推画面帧。
  func setVisibleTerminals(_ visible: Set<String>) -> [SurfaceInterestIntent] {
    var intents: [SurfaceInterestIntent] = []
    for terminalID in visible.subtracting(interest.visibleSurfaces).sorted() {
      intents += interest.becameVisible(terminalID: terminalID)
    }
    for terminalID in interest.visibleSurfaces.subtracting(visible).sorted() {
      intents += interest.becameHidden(terminalID: terminalID)
    }
    return intents
  }

  /// 整个客户端进入隐藏（窗口最小化、机器切走）：取消全部画面订阅。
  ///
  /// 结构与 Agent 事件不受影响——它们不是画面订阅，服务端会继续投递。
  func suspendAllSurfaces() -> [SurfaceInterestIntent] {
    setVisibleTerminals([])
  }

  /// 快照确认到达：放行该终端的交互。
  func confirmSnapshot(terminalID: String) {
    interest.confirmSnapshot(terminalID: terminalID)
  }

  /// 某个终端当前是否放行键盘输入。快照到达之前恒为 false。
  func allowsInput(terminalID: String) -> Bool {
    interest.allowsInteraction(terminalID: terminalID)
  }

  /// 尺寸更新判定：只有可见、持有写租约且闸门已开的控制器才能改尺寸。
  func resizeDecision(terminalID: String) -> SurfaceResizeDecision {
    interest.resizeDecision(terminalID: terminalID)
  }

  func acquireWriteLease(terminalID: String) { interest.acquireWriteLease(terminalID: terminalID) }
  func releaseWriteLease(terminalID: String) { interest.releaseWriteLease(terminalID: terminalID) }

  // MARK: - P4.2 结构事务

  /// 在当前 revision 上提交一次新建标签事务，冲突时取新快照后重试同一意图。
  ///
  /// 用「意图 + 重试」而不是「算好的新布局 + 重放」：冲突意味着服务端结构已经变了，
  /// 重放旧布局会覆盖竞争方刚提交的修改，重放意图才能得到正确结果。
  @discardableResult
  func createTab(
    workspaceID: String, title: String, terminal: RemoteTerminalSpec
  ) async throws -> RemoteTab {
    try await submit { client, expected in
      try client.withConflictRetry(expectedRevision: expected) { revision in
        try client.createTab(
          workspaceID: workspaceID, expectedRevision: revision, title: title, terminal: terminal)
      }
    }
  }

  /// 分屏事务。
  @discardableResult
  func splitPane(
    paneID: String, direction: SplitDirection, terminal: RemoteTerminalSpec
  ) async throws -> RemotePaneSplitResult {
    try await submit { client, expected in
      try client.withConflictRetry(expectedRevision: expected) { revision in
        try client.splitPane(
          paneID: paneID, direction: direction, expectedRevision: revision, terminal: terminal)
      }
    }
  }

  /// 关闭 Pane。这是**资源关闭**语义：会结束其远端进程。
  @discardableResult
  func closePane(paneID: String) async throws -> Bool {
    try await submit { client, expected in
      try client.withConflictRetry(expectedRevision: expected) { revision in
        try client.closePane(paneID: paneID, expectedRevision: revision)
      }
    }
  }

  /// 关闭标签。
  @discardableResult
  func closeTab(tabID: String) async throws -> Bool {
    try await submit { client, expected in
      try client.withConflictRetry(expectedRevision: expected) { revision in
        try client.closeTab(tabID: tabID, expectedRevision: revision)
      }
    }
  }

  /// 更新标签标题。
  @discardableResult
  func updateTab(tabID: String, title: String) async throws -> RemoteTab {
    try await submit { client, expected in
      try client.withConflictRetry(expectedRevision: expected) { revision in
        try client.updateTab(tabID: tabID, expectedRevision: revision, title: title)
      }
    }
  }

  /// 提交事务的公共外壳：离开主线程执行、成功后落回新 revision。
  private func submit<Value: Sendable>(
    _ body: @escaping @Sendable (WorkspaceTransactionClient, UInt64) throws ->
      WorkspaceTransactionResult<Value>
  ) async throws -> Value {
    let client = transactions
    let expected = revision
    let result = try await Task.detached(priority: .userInitiated) {
      try body(client, expected)
    }.value
    revision = result.revision
    // 结构已变：投影必须重新取快照，不能就地猜测新树。
    needsResynchronization = true
    return result.value
  }
}
