import AppKit
import Testing

@testable import Aster
@testable import AsterCore
@testable import SwiftTerm

// Pane 顶条控件回归:多 Pane 时每个 Pane 有右上角关闭按钮,内容让出顶条空间;
// 点击关闭按钮关闭对应 Pane;单 Pane 不显示关闭按钮。

@MainActor
private func deepViews(_ root: NSView) -> [NSView] {
  [root] + root.subviews.flatMap { deepViews($0) }
}

@Test("多 Pane 时顶条有关闭按钮,点击关闭对应 Pane;单 Pane 无按钮")
@MainActor
func paneCloseButtonClosesItsPane() async throws {
  let suite = "PaneChromeProbe.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.contentView?.layoutSubtreeIfNeeded()
  let tab = try #require(model.selectedTab)
  defer {
    for runtime in tab.runtimes.values { runtime.terminalSession?.stop(immediately: true) }
    window.orderOut(nil)
  }
  try await Task.sleep(for: .milliseconds(120))

  // 单 Pane:无关闭按钮(最后一个 Pane 无处可关)。
  #expect(deepViews(controller.view).compactMap { $0 as? PaneCloseButton }.isEmpty)

  let firstPane = tab.activePaneID
  model.splitSelectedTab(.right)
  try await Task.sleep(for: .milliseconds(150))
  window.contentView?.layoutSubtreeIfNeeded()
  let secondPane = tab.activePaneID
  #expect(tab.layout.allPanes.count == 2)

  // 双 Pane:每个宿主都有一个关闭按钮;隐藏时不参与命中(不产生点击死区)。
  let hosts = deepViews(controller.view).compactMap { $0 as? ActivePaneHostView }
  #expect(hosts.count == 2)
  for host in hosts {
    let buttons = deepViews(host).compactMap { $0 as? PaneCloseButton }
    #expect(buttons.count == 1, "Pane \(host.paneID) 应有且仅有一个关闭按钮")
    if let button = buttons.first {
      #expect(button.hitTest(button.bounds.origin) == nil, "隐藏的关闭按钮不应参与命中")
    }
    // 内容让出顶条空间:终端不得侵入宿主顶部 14pt 的控件条。
    if let terminal = deepViews(host).compactMap({ $0 as? AsterTerminalView }).first {
      let frameInHost = host.convert(terminal.bounds, from: terminal)
      #expect(
        frameInHost.maxY <= host.bounds.height - 14 + 0.5,
        "终端侵入顶条: \(frameInHost) in \(host.bounds)")
    }
  }

  // 点击第二个 Pane 的关闭按钮 → 只剩第一个 Pane。
  let secondHost = try #require(hosts.first { $0.paneID == secondPane })
  let closeButton = try #require(
    deepViews(secondHost).compactMap { $0 as? PaneCloseButton }.first)
  closeButton.performClick(nil)
  try await Task.sleep(for: .milliseconds(150))
  #expect(tab.layout.allPanes.map(\.id) == [firstPane])
}

@Test("顶条控件只在指针进入感应带时显示，布局刷新会纠正卡住的显示状态")
@MainActor
func paneChromeRevealFollowsPointerAcrossLayoutPasses() async throws {
  let suite = "PaneChromeReveal.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.contentView?.layoutSubtreeIfNeeded()
  let tab = try #require(model.selectedTab)
  defer {
    for runtime in tab.runtimes.values { runtime.terminalSession?.stop(immediately: true) }
    window.orderOut(nil)
  }
  try await Task.sleep(for: .milliseconds(120))

  model.splitSelectedTab(.right)
  try await Task.sleep(for: .milliseconds(150))
  window.contentView?.layoutSubtreeIfNeeded()

  let hosts = deepViews(controller.view).compactMap { $0 as? ActivePaneHostView }
  #expect(hosts.count == 2)
  let host = try #require(hosts.first)
  let handle = try #require(deepViews(host).compactMap { $0 as? PaneDragHandleView }.first)
  let close = try #require(deepViews(host).compactMap { $0 as? PaneCloseButton }.first)

  // 默认不显示：没有指针在顶边时把手与关闭按钮都是全透明的。
  #expect(!host.chromeRevealed)
  #expect(handle.alphaValue < 0.01)
  #expect(close.alphaValue < 0.01)

  // 指针进入顶部感应带 → 淡入。
  host.updateChromeReveal(
    pointerInView: NSPoint(x: host.bounds.midX, y: host.bounds.height - 4))
  #expect(host.chromeRevealed)
  #expect(handle.isRevealed)
  #expect(close.isRevealed)

  // 关键回归：布局刷新会重建感应带，AppKit 不补发 exit 事件。此时指针早已不在顶边，
  // 顶条必须自己回到隐藏，而不是永久卡在显示状态。
  host.updateTrackingAreas()
  #expect(!host.chromeRevealed)
  #expect(!handle.isRevealed)
  #expect(!close.isRevealed)
}

// MARK: - 底部两槽（Prompt Queue 在上、用量条在最下）

@Test("host 底部两槽:用量条贴底,Prompt Queue 在其上,内容随槽增减回落")
@MainActor
func hostStacksStatusStripBelowBottomAccessory() throws {
  let host = ActivePaneHostView(paneID: UUID(), isActive: true, onExternalDrop: { _, _ in false }) {}
  host.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
  let content = NSView()
  host.installContent(content)
  let strip = NSView()
  let accessory = NSView()
  accessory.translatesAutoresizingMaskIntoConstraints = false
  let accessoryHeight = accessory.heightAnchor.constraint(equalToConstant: 44)
  accessoryHeight.isActive = true

  host.setStatusStrip(strip, height: 20)
  host.setBottomAccessory(accessory)
  host.layoutSubtreeIfNeeded()
  #expect(strip.frame.minY == 0)
  #expect(strip.frame.height == 20)
  #expect(strip.frame.width == 400)
  #expect(abs(accessory.frame.minY - 28) < 0.5)
  #expect(abs(content.frame.minY - (accessory.frame.maxY + 8)) < 0.5)

  host.setBottomAccessory(nil)
  host.layoutSubtreeIfNeeded()
  #expect(abs(content.frame.minY - 20) < 0.5)
  #expect(accessory.superview == nil)

  host.setStatusStrip(nil)
  host.layoutSubtreeIfNeeded()
  #expect(content.frame.minY == 0)
  #expect(content.frame.height == 300)
  #expect(strip.superview == nil)
}

@Test("每个有 Agent 用量的 Pane 都挂用量条,原地更新同一实例,关闭设置后移除")
@MainActor
func usageBarAppearsOnEveryAgentPaneAndUpdatesInPlace() async throws {
  let suite = "PaneUsageBarProbe.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.contentView?.layoutSubtreeIfNeeded()
  let tab = try #require(model.selectedTab)
  defer {
    for runtime in tab.runtimes.values { runtime.terminalSession?.stop(immediately: true) }
    window.orderOut(nil)
  }
  try await Task.sleep(for: .milliseconds(120))
  model.splitSelectedTab(.right)
  try await Task.sleep(for: .milliseconds(150))
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(tab.layout.allPanes.count == 2)

  func bars() -> [AgentUsageBarView] {
    deepViews(controller.view).compactMap { $0 as? AgentUsageBarView }
  }
  #expect(bars().isEmpty)

  let sessions = tab.layout.allPanes.compactMap { tab.runtime(for: $0.id)?.terminalSession }
  #expect(sessions.count == 2)
  let views = try sessions.map { session in
    try #require(session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  }
  // 非焦点 Pane 也显示：两个 session 各发一次。
  views[0].onAgentUsageDirective?(try #require(AgentUsageDirective(payload: "AgentUsage=1;Provider=claudeCode;FiveHour=42")))
  views[1].onAgentUsageDirective?(try #require(AgentUsageDirective(payload: "AgentUsage=1;Provider=codex;SevenDay=90;Session=5")))
  window.contentView?.layoutSubtreeIfNeeded()
  let initial = bars()
  #expect(initial.count == 2)
  let claudeBar = try #require(initial.first { $0.snapshot.provider == .claudeCode })
  #expect(claudeBar.frame.height == AgentUsageBarView.preferredHeight)

  // 原地更新：同一实例。
  views[0].onAgentUsageDirective?(try #require(AgentUsageDirective(payload: "AgentUsage=1;Provider=claudeCode;FiveHour=85")))
  #expect(bars().count == 2)
  #expect(bars().first { $0.snapshot.provider == .claudeCode } === claudeBar)
  #expect(claudeBar.snapshot.window(.fiveHour)?.usedPercent == 85)

  // 其中一个 Agent 结束：只移除它的条。
  views[1].onShellIntegrationEvent?(.commandFinished(exitStatus: 0))
  #expect(bars().count == 1)

  // 关闭设置：刷新后没有任何条。
  preferences.configuration.agents.usageBarEnabled = false
  try await Task.sleep(for: .milliseconds(200))
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(bars().isEmpty)
}
