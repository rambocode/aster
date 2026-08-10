import AppKit
import Testing

@testable import Aster
@testable import AsterCore

// 详情面板刷新屏障的交互回归：同目录分屏之间切换 Pane 后,屏障必须在新快照
// 提交后撤下,不得永久拦截 Git/Files 页的点击。

@MainActor
private func isolatedDefaults() -> UserDefaults {
  let suite = "DetailsPaneBarrierProbeTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

@MainActor
private func refreshOverlay(in root: NSView) -> NSView? {
  func scan(_ view: NSView) -> NSView? {
    if String(describing: type(of: view)).contains("DetailsPaneRefreshOverlay") { return view }
    for subview in view.subviews {
      if let found = scan(subview) { return found }
    }
    return nil
  }
  return scan(root)
}

/// 轮询等待屏障撤下;返回是否在时限内隐藏。
@MainActor
private func waitForOverlayHidden(_ overlay: NSView, timeout: TimeInterval) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if overlay.isHidden { return true }
    try? await Task.sleep(for: .milliseconds(50))
  }
  return overlay.isHidden
}

@Test("同目录分屏切换后 Git 页刷新屏障必须撤下")
@MainActor
func paneSwitchReleasesGitRefreshBarrier() async throws {
  let defaults = isolatedDefaults()
  // Git 页 + Inspector 展开是屏障最容易滞留的组合,直接作为初始状态。
  defaults.set(2, forKey: "aster.inspector.section.v1")
  defaults.set(true, forKey: "aster.inspector.presented.v1")
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  model.splitSelectedTab(.right)
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .resizable],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.layoutIfNeeded()
  defer {
    for tab in model.tabs {
      for runtime in tab.runtimes.values { runtime.terminalSession?.stop(immediately: true) }
    }
    window.orderOut(nil)
  }
  try await Task.sleep(for: .milliseconds(150))

  let overlay = try #require(refreshOverlay(in: controller.view), "Inspector 应已展示 Git 页屏障")
  #expect(await waitForOverlayHidden(overlay, timeout: 5), "首次 Git 快照后屏障应撤下")

  let tab = try #require(model.selectedTab)
  let otherPane = try #require(
    tab.layout.allPanes.map(\.id).first { $0 != tab.activePaneID }
  )
  tab.setActivePane(otherPane)
  let released = await waitForOverlayHidden(overlay, timeout: 5)
  #expect(released, "同目录 Pane 切换后屏障不得永久拦截点击")
}
