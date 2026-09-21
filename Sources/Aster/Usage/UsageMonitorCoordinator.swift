// AI 用量监控的总开关：状态栏条目、浮动窗与配额订阅的唯一持有者。
import AppKit
import AsterCore
import Combine
import Foundation

/// 系统状态栏条目的抽象。
///
/// 协调器只依赖这个协议：测试宿主里创建真正的 `NSStatusItem` 既慢又会污染用户菜单栏，
/// 实现通过工厂闭包注入，测试换成假实现即可。
@MainActor
protocol UsageStatusItemPresenting: AnyObject {
  /// 点击状态栏图标。
  var onClick: (() -> Void)? { get set }
  /// 按钮在屏幕坐标系里的位置；浮动窗首次出现要贴在它正下方。
  var buttonFrameInScreen: NSRect? { get }
  /// 刷新图标内容。实现内部做相等判断，值没变不重绘。
  func apply(_ summary: UsageStatusSummary, accounts: [UsageAccountSnapshot])
  /// 从系统状态栏摘除；摘除后该实例不再可用。
  func remove()
}

/// AI 用量监控的生命周期协调器。
///
/// 功能关着时必须是「零对象、零任务」：`setEnabled(false)` 之后不留状态栏条目、
/// 不留浮动窗、不留订阅，配额轮询也停掉。两个方向都幂等，重复调用不会叠加副作用。
/// 注意：协调器不在 `deinit` 里清理（`deinit` 不在主线程隔离上），
/// 宿主释放它之前必须先 `setEnabled(false)`。
@MainActor
final class UsageMonitorCoordinator {
  private let quotaStore: UsageQuotaStore
  private let sessions: UsageSessionBoardDataSource
  private let tokenService: TokenStatsService
  private let defaults: UserDefaults
  private let makeStatusItem: @MainActor () -> UsageStatusItemPresenting

  private var statusItem: UsageStatusItemPresenting?
  private var panel: UsagePanelController?
  private var content: UsagePanelViewController?
  private var subscriptions: Set<AnyCancellable> = []
  private var isEnabled = false

  /// - Parameter statusItemFactory: 测试注入点；nil 时使用真正的 `NSStatusBar` 条目。
  init(
    quotaStore: UsageQuotaStore,
    sessions: UsageSessionBoardDataSource,
    tokenService: TokenStatsService,
    defaults: UserDefaults = .standard,
    statusBar: NSStatusBar = .system,
    statusItemFactory: (@MainActor () -> UsageStatusItemPresenting)? = nil
  ) {
    self.quotaStore = quotaStore
    self.sessions = sessions
    self.tokenService = tokenService
    self.defaults = defaults
    self.makeStatusItem = statusItemFactory ?? { UsageStatusItemController(statusBar: statusBar) }
  }

  // MARK: - 测试与接线 seam

  /// 状态栏图标是否已装上。
  var isStatusItemInstalled: Bool { statusItem != nil }
  /// 浮动窗当前是否可见。
  var isPanelVisible: Bool { panel?.isVisible == true }

  // MARK: - 开关

  /// 打开或关闭整个功能。幂等。
  func setEnabled(_ enabled: Bool) {
    guard enabled != isEnabled else { return }
    isEnabled = enabled
    if enabled {
      install()
    } else {
      teardown()
    }
  }

  /// 菜单命令与命令面板的入口：开着就收起，关着就弹出。
  func togglePanel() {
    if isPanelVisible {
      panel?.hide()
    } else {
      showPanel()
    }
  }

  /// 弹出浮动窗。功能没开启时什么都不做并返回 false。
  @discardableResult
  func showPanel() -> Bool {
    guard isEnabled else { return false }
    ensurePanel().show()
    return true
  }

  // MARK: - 安装与拆除

  private func install() {
    let item = makeStatusItem()
    item.onClick = { [weak self] in self?.togglePanel() }
    statusItem = item
    quotaStore.start()
    // `@Published` 订阅时会立刻带回当前值，首帧不需要额外补一次刷新。
    quotaStore.$accounts
      .sink { [weak self] accounts in self?.refreshStatusItem(accounts: accounts) }
      .store(in: &subscriptions)
    sessions.changes
      .sink { [weak self] _ in self?.refreshStatusItem() }
      .store(in: &subscriptions)
    refreshStatusItem()
  }

  /// 顺序有讲究：先收起浮动窗让当前页走到 `suspend()`，再释放窗口与订阅，
  /// 否则页面里的在途任务会失去被取消的机会。
  private func teardown() {
    panel?.hide(animated: false)
    panel = nil
    content = nil
    subscriptions.removeAll()
    statusItem?.remove()
    statusItem = nil
    quotaStore.stop()
  }

  /// 把账号快照与「等待输入」的会话数折成状态栏内容。
  private func refreshStatusItem(accounts: [UsageAccountSnapshot]? = nil) {
    guard let statusItem else { return }
    let snapshots = accounts ?? quotaStore.accounts
    let blocked = sessions.sessions().filter { $0.status == .blocked }.count
    let summary = UsageStatusSummary.make(accounts: snapshots, blockedAgents: blocked)
    statusItem.apply(summary, accounts: snapshots)
  }

  /// 浮动窗按需构建：功能开着但从没打开过窗口时，不该有任何视图存在。
  private func ensurePanel() -> UsagePanelController {
    if let panel { return panel }
    let content = UsagePanelViewController(
      quotaStore: quotaStore, sessions: sessions, tokenService: tokenService, defaults: defaults)
    let controller = UsagePanelController(
      content: content,
      defaults: defaults,
      anchor: { [weak self] in self?.statusItem?.buttonFrameInScreen })
    controller.onVisibilityChanged = { [weak content] visible in content?.setVisible(visible) }
    self.content = content
    panel = controller
    return controller
  }
}
