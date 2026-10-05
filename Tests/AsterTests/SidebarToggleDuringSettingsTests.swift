import AppKit
import AsterCore
import Testing

@testable import Aster

// 设置窗口开着时，折叠 / 展开标签栏仍要立刻生效。

@MainActor
private func sidebarToggleViews(_ root: NSView) -> [NSView] {
  [root] + root.subviews.flatMap { sidebarToggleViews($0) }
}

@Test("设置窗口开着时折叠和展开标签栏立刻重建工作区")
@MainActor
func tabBarVisibilityRefreshesWhileSettingsArePresented() async throws {
  let suite = "SidebarToggleDuringSettings.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  preferences.tabBarLayout = .vertical
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 700),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentViewController = controller
  window.contentView?.layoutSubtreeIfNeeded()
  defer {
    for tab in model.tabs {
      for runtime in tab.runtimes.values { runtime.terminalSession?.stop(immediately: true) }
    }
    window.orderOut(nil)
  }
  /// 侧栏是否真的在视图树里；只看配置值发现不了「改了配置但没重建」。
  func sidebarIsMounted() -> Bool {
    sidebarToggleViews(controller.view).contains { $0.identifier?.rawValue == "workspace-sidebar" }
  }
  try await Task.sleep(for: .milliseconds(150))
  #expect(sidebarIsMounted())

  // 设置窗口展示期间普通配置的结构刷新会合并到关窗；标签栏显隐不能跟着被推迟。
  controller.setSettingsPresentationActive(true)
  preferences.configuration.appearance.showTabBar = false
  try await Task.sleep(for: .milliseconds(150))
  #expect(!sidebarIsMounted())

  preferences.configuration.appearance.showTabBar = true
  try await Task.sleep(for: .milliseconds(150))
  #expect(sidebarIsMounted())
  controller.setSettingsPresentationActive(false)
}
