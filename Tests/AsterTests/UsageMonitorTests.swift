import AppKit
import AsterCore
import Combine
import Testing

@testable import Aster

/// 假的会话数据源：状态栏红点只看 `status == .blocked` 的条数。
@MainActor
private final class StubSessionBoard: UsageSessionBoardDataSource {
  var entries: [UsageSessionEntry] = []
  private(set) var focused: [UUID] = []
  private let subject = PassthroughSubject<Void, Never>()

  func sessions() -> [UsageSessionEntry] { entries }
  var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
  func focus(paneID: UUID) { focused.append(paneID) }
  func emit() { subject.send(()) }
}

/// 假的状态栏条目：测试宿主里不碰真正的系统菜单栏。
@MainActor
private final class StubStatusItem: UsageStatusItemPresenting {
  var onClick: (() -> Void)?
  var buttonFrameInScreen: NSRect? = NSRect(x: 600, y: 900, width: 48, height: 22)
  private(set) var applied: [UsageStatusSummary] = []
  private(set) var isRemoved = false

  func apply(_ summary: UsageStatusSummary, accounts: [UsageAccountSnapshot]) {
    applied.append(summary)
  }

  func remove() { isRemoved = true }
}

/// 假的页面：只记录生命周期调用与视图是否真的被构建过。
@MainActor
private final class StubSection: UsageSectionController {
  private(set) var activateCount = 0
  private(set) var suspendCount = 0
  private(set) var didBuildView = false

  lazy var view: NSView = makeView()

  func activate() { activateCount += 1 }
  func suspend() { suspendCount += 1 }

  private func makeView() -> NSView {
    didBuildView = true
    return NSView()
  }
}

@MainActor
private func makeDefaults() throws -> UserDefaults {
  let suite = "UsageMonitorTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

/// 一个带 5 小时窗口与重置时间的账号，用来触发倒计时文字与档位徽标。
@MainActor
private func makeUsageAccount(
  id: String = "claudeCode:default",
  label: String = "Claude",
  plan: String? = nil,
  usedPercent: Double = 63
) throws -> UsageAccountSnapshot {
  let window = try #require(
    AgentUsageWindow(
      kind: .fiveHour, usedPercent: usedPercent, resetsAt: Date().addingTimeInterval(3_600)))
  return UsageAccountSnapshot(
    id: id, provider: .claudeCode, label: label, plan: plan, windows: [window], fetchedAt: Date())
}

/// 按 identifier 在视图树里找一个视图。
@MainActor
private func findUsageView(_ identifier: String, in root: NSView) -> NSView? {
  if root.identifier?.rawValue == identifier { return root }
  for child in root.subviews {
    if let match = findUsageView(identifier, in: child) { return match }
  }
  return nil
}

@MainActor
private func makeCoordinator(
  defaults: UserDefaults, sessions: StubSessionBoard, statusItem: StubStatusItem
) -> UsageMonitorCoordinator {
  UsageMonitorCoordinator(
    quotaStore: UsageQuotaStore(),
    sessions: sessions,
    tokenService: TokenStatsService(),
    defaults: defaults,
    statusItemFactory: { statusItem })
}

@Suite("UsageMonitor 状态栏与浮动窗")
@MainActor
struct UsageMonitorCoordinatorTests {
  @Test("开启后装上状态栏条目，关闭后完全拆除")
  func 开启与关闭() throws {
    let defaults = try makeDefaults()
    let sessions = StubSessionBoard()
    let item = StubStatusItem()
    let coordinator = makeCoordinator(defaults: defaults, sessions: sessions, statusItem: item)

    coordinator.setEnabled(true)
    #expect(coordinator.isStatusItemInstalled)
    #expect(!item.applied.isEmpty)
    #expect(coordinator.showPanel())
    #expect(coordinator.isPanelVisible)

    coordinator.setEnabled(false)
    #expect(!coordinator.isStatusItemInstalled)
    #expect(!coordinator.isPanelVisible)
    #expect(item.isRemoved)
  }

  @Test("重复开关幂等，不会重复装条目")
  func 开关幂等() throws {
    let defaults = try makeDefaults()
    let sessions = StubSessionBoard()
    let item = StubStatusItem()
    let coordinator = makeCoordinator(defaults: defaults, sessions: sessions, statusItem: item)

    coordinator.setEnabled(true)
    let afterFirst = item.applied.count
    coordinator.setEnabled(true)
    #expect(item.applied.count == afterFirst)
    coordinator.setEnabled(false)
    coordinator.setEnabled(false)
    #expect(!coordinator.isStatusItemInstalled)
  }

  @Test("功能未开启时不显示浮动窗")
  func 未开启不显示浮动窗() throws {
    let defaults = try makeDefaults()
    let coordinator = makeCoordinator(
      defaults: defaults, sessions: StubSessionBoard(), statusItem: StubStatusItem())
    #expect(coordinator.showPanel() == false)
    #expect(!coordinator.isPanelVisible)
  }

  @Test("会话变化会把等待输入的条数折进状态栏内容")
  func 会话变化刷新状态栏() throws {
    let defaults = try makeDefaults()
    let sessions = StubSessionBoard()
    let item = StubStatusItem()
    let coordinator = makeCoordinator(defaults: defaults, sessions: sessions, statusItem: item)
    coordinator.setEnabled(true)

    sessions.entries = [
      UsageSessionEntry(
        id: UUID(), provider: .claudeCode, status: .blocked, title: "等待输入",
        workingDirectory: nil, rootProcessIdentifier: nil)
    ]
    sessions.emit()
    #expect(item.applied.last?.needsAttention == true)

    sessions.entries = []
    sessions.emit()
    #expect(item.applied.last?.needsAttention == false)
    coordinator.setEnabled(false)
  }

  @Test("关闭功能后会话事件不再回调状态栏")
  func 关闭后不再订阅() throws {
    let defaults = try makeDefaults()
    let sessions = StubSessionBoard()
    let item = StubStatusItem()
    let coordinator = makeCoordinator(defaults: defaults, sessions: sessions, statusItem: item)
    coordinator.setEnabled(true)
    coordinator.setEnabled(false)
    let count = item.applied.count
    sessions.emit()
    #expect(item.applied.count == count)
  }
}

@Suite("UsageMonitor 浮动窗页面")
@MainActor
struct UsagePanelViewControllerTests {
  @Test("页面懒构建：没切到的页不建视图")
  func 页面懒构建() throws {
    let defaults = try makeDefaults()
    let quota = StubSection()
    let tokens = StubSection()
    let controller = UsagePanelViewController(
      sections: [.quota: quota, .tokens: tokens, .sessions: StubSection()], defaults: defaults)

    controller.setVisible(true)
    #expect(quota.didBuildView)
    #expect(!tokens.didBuildView)
    controller.setVisible(false)
  }

  @Test("切页时旧页挂起、新页激活")
  func 切页生命周期() throws {
    let defaults = try makeDefaults()
    let quota = StubSection()
    let tokens = StubSection()
    let controller = UsagePanelViewController(
      sections: [.quota: quota, .tokens: tokens, .sessions: StubSection()], defaults: defaults)

    controller.setVisible(true)
    #expect(quota.activateCount == 1)

    controller.select(.tokens)
    #expect(quota.suspendCount == 1)
    #expect(tokens.activateCount == 1)
    #expect(controller.selection == .tokens)

    controller.setVisible(false)
    #expect(tokens.suspendCount == 1)
    #expect(quota.suspendCount == 1)
  }

  @Test("选中页写回 defaults 并在下次恢复")
  func 选中页持久化() throws {
    let defaults = try makeDefaults()
    let first = UsagePanelViewController(
      sections: [.quota: StubSection(), .tokens: StubSection(), .sessions: StubSection()],
      defaults: defaults)
    first.setVisible(true)
    first.select(.sessions)
    first.setVisible(false)

    let restored = UsagePanelViewController(
      sections: [.quota: StubSection(), .tokens: StubSection(), .sessions: StubSection()],
      defaults: defaults)
    #expect(restored.selection == .sessions)
  }

  @Test("窗口隐藏时当前页不再持有可见状态")
  func 隐藏时挂起当前页() throws {
    let defaults = try makeDefaults()
    let quota = StubSection()
    let controller = UsagePanelViewController(
      sections: [.quota: quota, .tokens: StubSection(), .sessions: StubSection()],
      defaults: defaults)
    controller.setVisible(true)
    controller.setVisible(false)
    controller.setVisible(false)
    #expect(quota.suspendCount == 1)
  }
}

@Suite("UsageMonitor 配额页")
@MainActor
struct UsageQuotaSectionTests {
  @Test("有倒计时内容时排下一次刷新，挂起后取消")
  func 挂起取消倒计时() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    section.render([try makeUsageAccount()])
    #expect(section.hasScheduledTick)
    section.suspend()
    #expect(!section.hasScheduledTick)
  }

  @Test("没有配额数据时不排任何任务")
  func 空数据无任务() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    #expect(!section.hasScheduledTick)
    section.suspend()
  }

  @Test("没激活过的配额页不排任何任务")
  func 未激活无任务() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    #expect(!section.hasScheduledTick)
  }

  @Test("挂起后再收到快照也不会重新排任务")
  func 挂起后不复活() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    section.suspend()
    section.render([try makeUsageAccount()])
    #expect(!section.hasScheduledTick)
  }

  @Test("有订阅档位时显示徽标")
  func 档位徽标显示() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    section.render([try makeUsageAccount(plan: "Max 20x")])
    let badge = try #require(
      findUsageView("usage-quota-plan-claudeCode:default", in: section.view)
        as? UsagePlanBadgeView)
    #expect(!badge.isHidden)
    #expect(badge.text == "Max 20x")
    section.suspend()
  }

  @Test("没有订阅档位时隐藏徽标")
  func 档位缺失隐藏徽标() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    var account = try makeUsageAccount(plan: nil)
    section.render([account])
    let badge = try #require(
      findUsageView("usage-quota-plan-claudeCode:default", in: section.view)
        as? UsagePlanBadgeView)
    #expect(badge.isHidden)
    #expect(badge.text.isEmpty)

    // 纯空白与 nil 同样处理，不留一个空胶囊。
    account.plan = "   "
    section.render([account])
    #expect(badge.isHidden)
    section.suspend()
  }

  @Test("档位从无到有时原地出现，卡片实例不变")
  func 档位原地更新() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    // 同一份账号只改 plan：新建账号会带上新的 `resetsAt`，那属于结构变化。
    var account = try makeUsageAccount(plan: nil)
    section.render([account])
    let card = try #require(
      findUsageView("usage-quota-card-claudeCode:default", in: section.view))
    let badge = try #require(
      findUsageView("usage-quota-plan-claudeCode:default", in: section.view)
        as? UsagePlanBadgeView)
    #expect(badge.isHidden)

    account.plan = "Pro"
    section.render([account])
    #expect(!badge.isHidden)
    #expect(badge.text == "Pro")
    #expect(findUsageView("usage-quota-card-claudeCode:default", in: section.view) === card)
    section.suspend()
  }

  @Test("窗口结构变化仍然重建卡片")
  func 结构变化重建卡片() throws {
    let section = UsageQuotaSectionController(store: UsageQuotaStore())
    section.activate()
    var account = try makeUsageAccount(usedPercent: 10)
    section.render([account])
    let card = try #require(
      findUsageView("usage-quota-card-claudeCode:default", in: section.view))

    account.windows = [
      try #require(
        AgentUsageWindow(
          kind: .fiveHour, usedPercent: 80, resetsAt: account.windows[0].resetsAt))
    ]
    section.render([account])
    #expect(findUsageView("usage-quota-card-claudeCode:default", in: section.view) !== card)
    section.suspend()
  }
}

@Suite("UsageMonitor 状态栏 tooltip")
@MainActor
struct UsageStatusItemTooltipTests {
  @Test("账号名后带上订阅档位")
  func tooltip带档位() throws {
    let text = UsageStatusItemController.tooltip(for: [try makeUsageAccount(plan: "Max 20x")])
    #expect(text == "Claude（Max 20x）：5h 63%")
  }

  @Test("没有订阅档位时不带括号")
  func tooltip无档位() throws {
    let text = UsageStatusItemController.tooltip(for: [try makeUsageAccount(plan: nil)])
    #expect(text == "Claude：5h 63%")
  }

  @Test("多个账号一行一个")
  func tooltip多账号() throws {
    let text = UsageStatusItemController.tooltip(for: [
      try makeUsageAccount(plan: "Pro"),
      try makeUsageAccount(id: "codex:default", label: "Codex", plan: nil, usedPercent: 20),
    ])
    #expect(text == "Claude（Pro）：5h 63%\nCodex：5h 20%")
  }
}

@Suite("UsageMonitor 浮动窗定位")
@MainActor
struct UsagePanelFrameTests {
  /// 屏幕的可见区域：1080 高的屏幕去掉顶部 25pt 菜单栏。状态栏按钮在它的上方。
  private static let screen = NSRect(x: 0, y: 0, width: 1_920, height: 1_055)

  @Test("首次出现贴在状态栏按钮下方且不出屏")
  func 首次贴靠状态栏() {
    let anchor = NSRect(x: 1_880, y: 1_058, width: 48, height: 22)
    let frame = UsagePanelController.resolveFrame(
      saved: nil, anchor: anchor, screens: [Self.screen])
    #expect(frame.maxX <= Self.screen.maxX)
    #expect(frame.minX >= Self.screen.minX)
    #expect(frame.maxY <= anchor.minY)
    #expect(frame.size == UsagePanelController.defaultSize)
  }

  @Test("状态栏条目刚创建、锚点还没落到菜单栏时，退回右上角而不是左下角")
  func 未就位的锚点被忽略() {
    // 条目创建的那一拍，按钮窗口还在 (0,0)；照它定位会把浮动窗夹到屏幕左下角。
    let unplaced = NSRect(x: 0, y: 0, width: 48, height: 22)
    let frame = UsagePanelController.resolveFrame(
      saved: nil, anchor: unplaced, screens: [Self.screen])
    #expect(frame.maxX > Self.screen.maxX - 40)
    #expect(frame.maxY > Self.screen.maxY - 40)
  }

  @Test("保存的位置越界时夹回屏幕内")
  func 越界恢复() {
    let saved = NSRect(x: 1_900, y: -400, width: 380, height: 460)
    let frame = UsagePanelController.resolveFrame(
      saved: saved, anchor: nil, screens: [Self.screen])
    #expect(Self.screen.contains(frame))
  }

  @Test("保存的位置所在屏幕已消失时回到状态栏下方")
  func 屏幕消失回退锚点() {
    let saved = NSRect(x: 5_000, y: 5_000, width: 380, height: 460)
    let anchor = NSRect(x: 600, y: 1_058, width: 48, height: 22)
    let frame = UsagePanelController.resolveFrame(
      saved: saved, anchor: anchor, screens: [Self.screen])
    #expect(Self.screen.contains(frame))
    #expect(frame.maxY <= anchor.minY)
  }

  @Test("拖动后的位置写回 defaults，下次打开沿用")
  func 位置持久化() throws {
    let defaults = try makeDefaults()
    let controller = UsagePanelController(
      content: NSViewController(), defaults: defaults, anchor: { nil })
    controller.show()
    let moved = UsagePanelController.clamp(
      NSRect(x: 120, y: 140, width: 400, height: 480),
      to: NSScreen.main?.visibleFrame ?? Self.screen)
    controller.window.setFrame(moved, display: false)
    controller.hide()

    let saved = try #require(defaults.string(forKey: UsagePanelController.frameDefaultsKey))
    #expect(NSRectFromString(saved) == moved)

    let restored = UsagePanelController(
      content: NSViewController(), defaults: defaults, anchor: { nil })
    restored.show()
    #expect(restored.window.frame == moved)
    restored.hide()
  }
}

@Suite("UsageMonitor 状态栏条目")
@MainActor
struct UsageStatusItemTests {
  @Test("内容没变时不重绘")
  func 相同内容不重绘() {
    let controller = UsageStatusItemController()
    defer { controller.remove() }
    let summary = UsageStatusSummary(
      segments: [
        UsageStatusSummary.Segment(provider: .claudeCode, usedPercent: 63, severity: .normal)
      ],
      needsAttention: false)
    controller.apply(summary)
    controller.apply(summary)
    #expect(controller.renderCount == 1)

    let changed = UsageStatusSummary(
      segments: summary.segments, needsAttention: true)
    controller.apply(changed)
    #expect(controller.renderCount == 2)
  }
}
