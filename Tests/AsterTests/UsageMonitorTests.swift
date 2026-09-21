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

/// 假的页面：记录生命周期调用、收到的展示口径、刷新次数与视图是否真的被构建过。
@MainActor
private final class StubSection: UsageSectionController {
  private(set) var activateCount = 0
  private(set) var suspendCount = 0
  private(set) var didBuildView = false
  /// 按顺序记录每一次收到的展示口径，用来验证广播的时机而不只是最终值。
  private(set) var receivedModes: [UsageDisplayMode] = []
  private(set) var refreshCount = 0

  lazy var view: NSView = makeView()

  func activate() { activateCount += 1 }
  func suspend() { suspendCount += 1 }
  func apply(displayMode: UsageDisplayMode) { receivedModes.append(displayMode) }
  /// 刻意不用默认实现（它会转成 `activate()`），否则分不清刷新和激活。
  func refreshRequested() { refreshCount += 1 }

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

@Suite("UsageMonitor 浮动窗外壳")
@MainActor
struct UsagePanelChromeTests {
  /// 三页全是假实现的容器，外加各页的引用，省掉每个用例重复搭台。
  @MainActor
  private struct Rig {
    let controller: UsagePanelViewController
    let quota: StubSection
    let tokens: StubSection
    let sessions: StubSection
  }

  private static func makeRig(defaults: UserDefaults) -> Rig {
    let quota = StubSection()
    let tokens = StubSection()
    let sessions = StubSection()
    return Rig(
      controller: UsagePanelViewController(
        sections: [.quota: quota, .tokens: tokens, .sessions: sessions], defaults: defaults),
      quota: quota, tokens: tokens, sessions: sessions)
  }

  @Test("切换口径会广播到全部已构建的页")
  func 口径广播到已构建的页() throws {
    let defaults = try makeDefaults()
    let rig = Self.makeRig(defaults: defaults)
    rig.controller.setVisible(true)
    rig.controller.select(.tokens)

    rig.controller.select(displayMode: .remaining)
    #expect(rig.quota.receivedModes == [.used, .remaining])
    #expect(rig.tokens.receivedModes == [.used, .remaining])
    // 没切到过的页不该因为一个展示参数被提前唤醒。
    #expect(rig.sessions.receivedModes.isEmpty)
    #expect(!rig.sessions.didBuildView)
    rig.controller.setVisible(false)
  }

  @Test("懒构建的新页在构建后立刻拿到当前口径")
  func 新页补发当前口径() throws {
    let defaults = try makeDefaults()
    let rig = Self.makeRig(defaults: defaults)
    rig.controller.setVisible(true)
    rig.controller.select(displayMode: .remaining)
    #expect(rig.sessions.receivedModes.isEmpty)

    rig.controller.select(.sessions)
    #expect(rig.sessions.receivedModes == [.remaining])
    rig.controller.setVisible(false)
  }

  @Test("底栏切换口径写回 defaults 并在下次恢复")
  func 口径持久化() throws {
    let defaults = try makeDefaults()
    let first = Self.makeRig(defaults: defaults).controller
    first.setVisible(true)
    let chip = try #require(
      findUsageView("usage-panel-mode-remaining", in: first.view) as? NSButton)
    chip.performClick(nil)
    #expect(first.displayMode == .remaining)
    first.setVisible(false)

    let restored = Self.makeRig(defaults: defaults).controller
    #expect(restored.displayMode == .remaining)
  }

  @Test("表头刷新按钮只作用在当前页")
  func 刷新按钮打到当前页() throws {
    let defaults = try makeDefaults()
    let rig = Self.makeRig(defaults: defaults)
    rig.controller.setVisible(true)
    rig.controller.select(.tokens)

    let button = try #require(
      findUsageView("usage-panel-refresh", in: rig.controller.view) as? NSButton)
    button.performClick(nil)
    #expect(rig.tokens.refreshCount == 1)
    #expect(rig.quota.refreshCount == 0)
    rig.controller.setVisible(false)
  }

  @Test("面板收起后表头不再排自续刷新")
  func 收起取消表头刷新() throws {
    let defaults = try makeDefaults()
    let rig = Self.makeRig(defaults: defaults)
    #expect(!rig.controller.hasScheduledHeaderTick)

    rig.controller.setVisible(true)
    #expect(rig.controller.hasScheduledHeaderTick)

    rig.controller.setVisible(false)
    #expect(!rig.controller.hasScheduledHeaderTick)
  }

  @Test("从没取到过数据时表头显示「尚未取数」")
  func 表头无数据文案() throws {
    let defaults = try makeDefaults()
    let rig = Self.makeRig(defaults: defaults)
    rig.controller.setVisible(true)
    #expect(rig.controller.headerStatusText == L("尚未取数"))
    rig.controller.setVisible(false)
  }

  /// 磨砂的三个关键参数很容易在后续重构里被无意改回默认值，每一条都会让面板变成一块灰板
  /// 或者干脆不透明，而这些都不会让任何别的用例失败。
  @Test("根视图是磨砂玻璃，窗体透明")
  func 磨砂透明窗体() throws {
    let defaults = try makeDefaults()
    let rig = Self.makeRig(defaults: defaults)
    rig.controller.setVisible(true)

    let root = try #require(rig.controller.view as? NSVisualEffectView)
    #expect(root.state == .active)
    #expect(root.blendingMode == .behindWindow)
    rig.controller.setVisible(false)

    let panel = UsagePanelController(
      content: rig.controller, defaults: defaults, anchor: { nil })
    #expect(!panel.window.isOpaque)
    #expect(panel.window.hasShadow)
    #expect(panel.window.backgroundColor == .clear)
  }

  /// 蒙版要夹在磨砂与内容之间。顺序错了对比度就白补，`hitTest` 忘了放行则整块面板点不动，
  /// 两种都不会让别的用例失败。
  @Test("主题蒙版夹在磨砂与内容之间，且不拦鼠标")
  func 蒙版层级与命中() throws {
    let defaults = try makeDefaults()
    let rig = Self.makeRig(defaults: defaults)
    rig.controller.setVisible(true)

    let root = try #require(rig.controller.view as? UsagePanelRootView)
    let scrim = root.scrimView
    #expect(scrim.hitTest(NSPoint(x: 10, y: 10)) == nil)

    let scrimIndex = try #require(root.subviews.firstIndex(of: scrim))
    let headerIndex = try #require(
      root.subviews.firstIndex { $0.identifier?.rawValue == "usage-panel-header" })
    let footerIndex = try #require(
      root.subviews.firstIndex { $0.identifier?.rawValue == "usage-panel-footer" })
    #expect(scrimIndex < headerIndex)
    #expect(scrimIndex < footerIndex)
    rig.controller.setVisible(false)
  }
}

@Suite("UsageMonitor 分段控件")
@MainActor
struct UsageSegmentedControlTests {
  /// 记录每一次回调的值。
  @MainActor
  private final class Recorder {
    private(set) var values: [String] = []
    func record(_ value: String) { values.append(value) }
  }

  private static func makeControl(
    ids: [String], selected: String, recorder: Recorder
  ) -> UsageSegmentedControl {
    UsageSegmentedControl(
      items: ids.map { UsageSegmentedControl.Item(id: $0, title: $0) },
      selected: selected,
      identifierPrefix: "seg",
      onSelect: { [weak recorder] value in recorder?.record(value) })
  }

  @Test("点别的格才回调，重复点选中的那格不回调")
  func 点击回调() throws {
    let recorder = Recorder()
    let control = Self.makeControl(ids: ["a", "b"], selected: "a", recorder: recorder)

    let segmentA = try #require(findUsageView("seg-a", in: control) as? NSButton)
    let segmentB = try #require(findUsageView("seg-b", in: control) as? NSButton)
    segmentA.performClick(nil)
    #expect(recorder.values.isEmpty)

    segmentB.performClick(nil)
    #expect(recorder.values == ["b"])
    #expect(control.selection == "b")
  }

  @Test("外部 select 只改样式，不回调")
  func 外部选中不回调() throws {
    let recorder = Recorder()
    let control = Self.makeControl(ids: ["a", "b"], selected: "a", recorder: recorder)
    control.select("b")
    control.select("b")
    #expect(control.selection == "b")
    #expect(recorder.values.isEmpty)
  }

  @Test("setItems 换项后，旧选中项不在新集合里就退回第一格")
  func 换项退回第一格() throws {
    let recorder = Recorder()
    let control = Self.makeControl(ids: ["a", "b"], selected: "b", recorder: recorder)

    control.setItems(
      ["x", "y"].map { UsageSegmentedControl.Item(id: $0, title: $0) }, selected: "b")
    #expect(control.selection == "x")
    #expect(findUsageView("seg-b", in: control) == nil)
    #expect(findUsageView("seg-y", in: control) != nil)
    #expect(recorder.values.isEmpty)
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

@Suite("UsageMonitor 浮动窗定位与自动收起")
@MainActor
struct UsagePanelFrameTests {
  /// 屏幕的可见区域：1080 高的屏幕去掉顶部 25pt 菜单栏。状态栏按钮在它的上方。
  private static let screen = NSRect(x: 0, y: 0, width: 1_920, height: 1_055)
  private static let size = UsagePanelController.defaultSize

  @Test("每次展开都贴在状态栏按钮下方且不出屏")
  func 贴靠状态栏() {
    let anchor = NSRect(x: 1_880, y: 1_058, width: 48, height: 22)
    let frame = UsagePanelController.resolveFrame(
      size: Self.size, anchor: anchor, screens: [Self.screen])
    #expect(frame.maxX <= Self.screen.maxX)
    #expect(frame.minX >= Self.screen.minX)
    #expect(frame.maxY <= anchor.minY)
    #expect(frame.size == Self.size)
  }

  @Test("状态栏条目刚创建、锚点还没落到菜单栏时，退回程序所在屏幕的右上角")
  func 未就位的锚点被忽略() {
    // 条目创建的那一拍，按钮窗口还在 (0,0)；照它定位会把浮动窗夹到屏幕左下角。
    let unplaced = NSRect(x: 0, y: 0, width: 48, height: 22)
    let second = NSRect(x: 1_920, y: 0, width: 1_440, height: 855)
    let frame = UsagePanelController.resolveFrame(
      size: Self.size, anchor: unplaced, screens: [Self.screen, second],
      preferred: second)
    #expect(second.contains(frame))
    #expect(frame.maxX > second.maxX - 40)
    #expect(frame.maxY > second.maxY - 40)
  }

  @Test("锚点所在屏幕换了，面板跟着换屏")
  func 跟随锚点所在屏幕() {
    let second = NSRect(x: 1_920, y: 0, width: 1_440, height: 855)
    let anchor = NSRect(x: 3_300, y: 858, width: 48, height: 22)
    let frame = UsagePanelController.resolveFrame(
      size: Self.size, anchor: anchor, screens: [Self.screen, second])
    #expect(second.contains(frame))
    #expect(frame.maxY <= anchor.minY)
  }

  @Test("尺寸超过屏幕时夹回可见区域")
  func 越界夹回() {
    let oversized = NSSize(width: 3_000, height: 2_000)
    let frame = UsagePanelController.resolveFrame(
      size: oversized, anchor: nil, screens: [Self.screen])
    #expect(Self.screen.contains(frame))
  }

  @Test("调过的尺寸写回 defaults，下次展开沿用尺寸但位置回到锚点下方")
  func 尺寸记忆() throws {
    let defaults = try makeDefaults()
    let visible = NSScreen.main?.visibleFrame ?? Self.screen
    let anchor = NSRect(x: visible.midX, y: visible.maxY + 3, width: 48, height: 22)
    let controller = UsagePanelController(
      content: NSViewController(), defaults: defaults, anchor: { anchor })
    controller.show()
    #expect(controller.isVisible)
    // 展开动画只改高度，宽度与顶边从第一帧起就是最终值。
    #expect(controller.window.frame.maxY <= anchor.minY)

    let resized = NSRect(x: 100, y: 100, width: 500, height: 520)
    controller.window.setFrame(resized, display: false)
    controller.windowDidEndLiveResize(
      Notification(name: NSWindow.didEndLiveResizeNotification, object: controller.window))
    controller.hide(animated: false)
    #expect(!controller.isVisible)
    let stored = NSSizeFromString(
      try #require(defaults.string(forKey: UsagePanelController.sizeDefaultsKey)))
    #expect(stored == resized.size)

    let restored = UsagePanelController(
      content: NSViewController(), defaults: defaults, anchor: { anchor })
    restored.show()
    #expect(restored.window.frame.width == resized.width)
    #expect(restored.window.frame.maxY <= anchor.minY)
    restored.hide(animated: false)
  }

  @Test("0.6.9 记的整块 frame 只迁移尺寸，不再复用位置")
  func 旧位置键只迁尺寸() throws {
    let defaults = try makeDefaults()
    let legacy = NSRect(x: 40, y: 60, width: 460, height: 540)
    defaults.set(NSStringFromRect(legacy), forKey: UsagePanelController.legacyFrameDefaultsKey)
    let visible = NSScreen.main?.visibleFrame ?? Self.screen
    let anchor = NSRect(x: visible.midX, y: visible.maxY + 3, width: 48, height: 22)
    let controller = UsagePanelController(
      content: NSViewController(), defaults: defaults, anchor: { anchor })
    controller.show()
    #expect(controller.window.frame.width == legacy.width)
    #expect(controller.window.frame.minY != legacy.minY)
    controller.hide(animated: false)
  }

  // MARK: - 自动收起

  private static let panelFrame = NSRect(x: 800, y: 400, width: 440, height: 600)
  private static let anchorFrame = NSRect(x: 980, y: 1_058, width: 48, height: 22)
  private static let now = Date(timeIntervalSince1970: 1_700_000_000)

  @Test("指针在面板内：记下「进入过」，不收起")
  func 指针在面板内() {
    let decision = UsagePanelController.evaluateAutoHide(
      pointer: NSPoint(x: 1_000, y: 700), panelFrame: Self.panelFrame, anchor: Self.anchorFrame,
      hasEntered: false, isInteracting: false, leftAt: nil, now: Self.now)
    #expect(decision.hasEntered)
    #expect(decision.leftAt == nil)
    #expect(!decision.shouldHide)
  }

  @Test("指针离开超过宽限时间才收起")
  func 离开后延迟收起() {
    let outside = NSPoint(x: 200, y: 200)
    let left = UsagePanelController.evaluateAutoHide(
      pointer: outside, panelFrame: Self.panelFrame, anchor: Self.anchorFrame,
      hasEntered: true, isInteracting: false, leftAt: nil, now: Self.now)
    #expect(!left.shouldHide)
    #expect(left.leftAt == Self.now)

    let soon = UsagePanelController.evaluateAutoHide(
      pointer: outside, panelFrame: Self.panelFrame, anchor: Self.anchorFrame,
      hasEntered: true, isInteracting: false, leftAt: left.leftAt,
      now: Self.now.addingTimeInterval(UsagePanelController.autoHideDelay / 2))
    #expect(!soon.shouldHide)

    let late = UsagePanelController.evaluateAutoHide(
      pointer: outside, panelFrame: Self.panelFrame, anchor: Self.anchorFrame,
      hasEntered: true, isInteracting: false, leftAt: left.leftAt,
      now: Self.now.addingTimeInterval(UsagePanelController.autoHideDelay + 0.1))
    #expect(late.shouldHide)
  }

  @Test("指针短暂划出后回到面板，计时清零")
  func 划出后回来不收起() {
    let left = UsagePanelController.evaluateAutoHide(
      pointer: NSPoint(x: 200, y: 200), panelFrame: Self.panelFrame, anchor: Self.anchorFrame,
      hasEntered: true, isInteracting: false, leftAt: nil, now: Self.now)
    let back = UsagePanelController.evaluateAutoHide(
      pointer: NSPoint(x: 1_000, y: 700), panelFrame: Self.panelFrame, anchor: Self.anchorFrame,
      hasEntered: true, isInteracting: false, leftAt: left.leftAt,
      now: Self.now.addingTimeInterval(0.3))
    #expect(back.leftAt == nil)
    #expect(!back.shouldHide)
  }

  @Test("指针从没进过面板时不自动收起（菜单命令打开的情形）")
  func 没进过面板不收起() {
    let decision = UsagePanelController.evaluateAutoHide(
      pointer: NSPoint(x: 200, y: 200), panelFrame: Self.panelFrame, anchor: Self.anchorFrame,
      hasEntered: false, isInteracting: false, leftAt: nil,
      now: Self.now.addingTimeInterval(10))
    #expect(!decision.hasEntered)
    #expect(!decision.shouldHide)
  }

  @Test("指针停在状态栏图标上、或正在拖尺寸时不收起")
  func 锚点与交互中不收起() {
    let onAnchor = UsagePanelController.evaluateAutoHide(
      pointer: NSPoint(x: Self.anchorFrame.midX, y: Self.anchorFrame.midY),
      panelFrame: Self.panelFrame, anchor: Self.anchorFrame,
      hasEntered: true, isInteracting: false, leftAt: Self.now.addingTimeInterval(-10),
      now: Self.now)
    #expect(!onAnchor.shouldHide)
    #expect(onAnchor.leftAt == nil)

    let busy = UsagePanelController.evaluateAutoHide(
      pointer: NSPoint(x: 200, y: 200), panelFrame: Self.panelFrame, anchor: Self.anchorFrame,
      hasEntered: true, isInteracting: true, leftAt: Self.now.addingTimeInterval(-10),
      now: Self.now)
    #expect(!busy.shouldHide)
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
