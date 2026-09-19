// 把控制桥已有的 Pane / Agent 投影转成会话看板的数据源。不另建第二份会话状态。
import AsterCore
import Combine
import Foundation

/// 会话看板与状态栏红点的数据源实现。
///
/// 真值仍在 `AsterControlBridge`（它已经观察了所有窗口的 Pane 与 Agent 状态）。这里只在
/// 功能开启期间订阅事件枢纽，把事件折成「列表变了」的信号；控制 socket 没起来（例如另一个
/// 实例占着）时桥不存在，看板为空，这是可接受的降级。
@MainActor
final class UsageSessionBoardAdapter: UsageSessionBoardDataSource {
  private let bridgeProvider: () -> AsterControlBridge?
  private let subject = PassthroughSubject<Void, Never>()
  private let subscriberID = UUID()
  private var isStarted = false
  private var lastEntries: [UsageSessionEntry] = []
  private var hasPendingEvaluation = false

  /// `bridgeProvider` 每次现取：控制服务晚于本对象启动，桥可能稍后才出现。
  init(bridgeProvider: @escaping () -> AsterControlBridge?) {
    self.bridgeProvider = bridgeProvider
  }

  var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }

  /// 功能开启：订阅 Pane 事件。可重复调用。
  func start() {
    guard !isStarted, let bridge = bridgeProvider() else { return }
    isStarted = true
    lastEntries = sessions()
    bridge.hub.subscribe(
      id: subscriberID,
      kinds: [.paneCreated, .paneClosed, .paneExited, .paneAgentStatusChanged, .paneUpdated]
    ) { [weak self] _ in
      self?.scheduleEvaluation()
    }
  }

  /// 功能关闭：退订，不留回调。可重复调用。
  func stop() {
    guard isStarted else { return }
    isStarted = false
    bridgeProvider()?.hub.unsubscribe(id: subscriberID)
    lastEntries = []
    hasPendingEvaluation = false
  }

  func sessions() -> [UsageSessionEntry] {
    guard let bridge = bridgeProvider() else { return [] }
    return bridge.allPanes().compactMap { record in
      guard let info = bridge.agentInfo(record),
        let provider = AgentProvider(rawValue: info.agent)
      else { return nil }
      return UsageSessionEntry(
        id: record.runtime.id, provider: provider, status: info.agentStatus, title: info.title,
        workingDirectory: info.cwd, rootProcessIdentifier: record.session?.processIdentifier)
    }
  }

  func focus(paneID: UUID) {
    guard let record = bridgeProvider()?.record(paneUUID: paneID) else { return }
    record.model.revealWorkspaceLocation(tabID: record.tab.id, paneID: record.runtime.id)
    record.model.onRequestWindowFocus?()
  }

  /// 一批事件只评估一次，并且只在列表真的变了才通知。
  ///
  /// `pane.updated` 会随终端标题变化频繁到达；不合并、不比较的话，看板会跟着标题刷新。
  private func scheduleEvaluation() {
    guard isStarted, !hasPendingEvaluation else { return }
    hasPendingEvaluation = true
    DispatchQueue.main.async { [weak self] in
      guard let self, self.isStarted else { return }
      self.hasPendingEvaluation = false
      let entries = self.sessions()
      guard entries != self.lastEntries else { return }
      self.lastEntries = entries
      self.subject.send()
    }
  }
}
