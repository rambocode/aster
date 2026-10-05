import AppKit
import AsterCore
import Testing

@testable import Aster

// Pane 顶条的「收起 / 恢复实时画面」按钮：Agent TUI 接管右键时仍可用的收起入口。

@MainActor
private func liveViewDeepViews(_ root: NSView) -> [NSView] {
  [root] + root.subviews.flatMap { liveViewDeepViews($0) }
}

/// 轮询等待条件成立；surface 创建与工作区重建都需要让出几轮主队列。
@MainActor
private func liveViewWaitUntil(
  timeout: Duration = .seconds(3), _ condition: () -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

@Test("单 Pane 也有实时画面按钮：悬停顶边淡入，点击收起再恢复，且不挤占终端高度")
@MainActor
func paneLiveViewButtonTogglesSinglePane() async throws {
  let suite = "PaneLiveViewButton.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 700),
    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentViewController = controller
  window.makeKeyAndOrderFront(nil)
  window.contentView?.layoutSubtreeIfNeeded()
  let tab = try #require(model.selectedTab)
  defer {
    for runtime in tab.runtimes.values { runtime.terminalSession?.stop(immediately: true) }
    window.orderOut(nil)
  }
  let session = try #require(tab.activeSession)
  #expect(await liveViewWaitUntil { session.canCollapseLiveView })

  let host = try #require(
    liveViewDeepViews(controller.view).compactMap { $0 as? ActivePaneHostView }.first)
  let button = try #require(
    liveViewDeepViews(host).compactMap { $0 as? PaneLiveViewButton }.first)

  // 单 Pane 没有其它顶条控件：内容不下移，终端仍占满宿主高度。
  let content = try #require(host.subviews.first { !($0 is PaneLiveViewButton) })
  #expect(abs(content.frame.maxY - host.bounds.height) < 0.5)

  // 隐藏时全透明且不参与命中，终端右上角没有点击死区。
  #expect(button.alphaValue < 0.01)
  #expect(button.hitTest(button.frame.origin) == nil)

  // 指针进入顶边感应带 → 淡入并按真值显示「收起」。
  host.updateChromeReveal(
    pointerInView: NSPoint(x: host.bounds.midX, y: host.bounds.height - 4))
  #expect(button.isRevealed)
  #expect(button.isEnabled)
  #expect(button.toolTip?.hasPrefix(L("收起实时画面")) == true)

  button.performClick(nil)
  #expect(session.isLiveViewCollapsed)
  #expect(button.toolTip?.hasPrefix(L("恢复实时画面")) == true)

  button.performClick(nil)
  #expect(!session.isLiveViewCollapsed)
  #expect(button.toolTip?.hasPrefix(L("收起实时画面")) == true)

  // 状态在别处被改掉（快捷键 / 菜单）时，下一次淡入前重新取真值。
  host.updateChromeReveal(pointerInView: nil)
  model.toggleActivePaneLiveView()
  #expect(session.isLiveViewCollapsed)
  host.updateChromeReveal(
    pointerInView: NSPoint(x: host.bounds.midX, y: host.bounds.height - 4))
  #expect(button.toolTip?.hasPrefix(L("恢复实时画面")) == true)
  model.toggleActivePaneLiveView()
}

@Test("分屏时实时画面按钮排在缩放按钮左侧；画中画占用的 Pane 按钮置灰")
@MainActor
func paneLiveViewButtonSitsLeftOfZoomAndDisablesForFloatingPane() async throws {
  let suite = "PaneLiveViewButtonSplit.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
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

  let hosts = liveViewDeepViews(controller.view).compactMap { $0 as? ActivePaneHostView }
  #expect(hosts.count == 2)
  for host in hosts {
    let button = try #require(
      liveViewDeepViews(host).compactMap { $0 as? PaneLiveViewButton }.first)
    let zoom = try #require(liveViewDeepViews(host).compactMap { $0 as? PaneZoomButton }.first)
    #expect(button.frame.maxX <= zoom.frame.minX)
    #expect(abs(button.frame.midY - zoom.frame.midY) < 0.5)
  }

  // 可交互小窗借走的 Pane 不能收起：按钮淡入时置灰。
  let host = try #require(hosts.first)
  let button = try #require(
    liveViewDeepViews(host).compactMap { $0 as? PaneLiveViewButton }.first)
  model.setFloatingPane(host.paneID)
  button.refreshState()
  #expect(!button.isEnabled)
  model.setFloatingPane(nil)
}
