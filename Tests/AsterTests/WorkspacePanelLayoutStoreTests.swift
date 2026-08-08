import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

@MainActor
private func panelLayoutDefaults(_ name: String = "") -> UserDefaults {
  let suite = "WorkspacePanelLayoutStoreTests.\(name).\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

@Test("每个工作区窗口独立保存并恢复 Panel 宽度")
@MainActor
func workspacePanelLayoutStorePersistsPerWindow() {
  let firstDefaults = panelLayoutDefaults("first")
  let secondDefaults = panelLayoutDefaults("second")
  let first = WorkspacePanelLayoutStore(defaults: firstDefaults, legacySidebarWidth: 250)
  let second = WorkspacePanelLayoutStore(defaults: secondDefaults, legacySidebarWidth: 210)

  #expect(first.state.sidebarWidth == 250)
  #expect(first.state.inspectorWidth == 278)
  #expect(second.state.sidebarWidth == 210)

  first.setPreferredWidth(340, for: .sidebar)
  first.setPreferredWidth(420, for: .inspector)

  let restored = WorkspacePanelLayoutStore(defaults: firstDefaults, legacySidebarWidth: 180)
  #expect(restored.state == WorkspacePanelLayoutState(sidebarWidth: 340, inspectorWidth: 420))
  #expect(second.state == WorkspacePanelLayoutState(sidebarWidth: 210, inspectorWidth: 278))
}

@Test("Panel store 拒绝中栏写入并夹紧损坏或越界宽度")
@MainActor
func workspacePanelLayoutStoreClampsOnlyResizablePanels() {
  let defaults = panelLayoutDefaults()
  defaults.set(Data("not-json".utf8), forKey: WorkspacePanelLayoutStore.persistenceKey)
  let store = WorkspacePanelLayoutStore(defaults: defaults, legacySidebarWidth: 999)

  #expect(store.state == WorkspacePanelLayoutState(sidebarWidth: 360, inspectorWidth: 278))
  store.setPreferredWidth(20, for: .sidebar)
  store.setPreferredWidth(2_000, for: .inspector)
  store.setPreferredWidth(1, for: .content)
  #expect(store.state == WorkspacePanelLayoutState(sidebarWidth: 180, inspectorWidth: 480))
}

@Test("设置 binding 跟随最近工作区并双向同步 Panel 宽度")
@MainActor
func workspacePanelSettingsBindingFollowsTheMostRecentWindow() {
  let first = WorkspacePanelLayoutStore(
    defaults: panelLayoutDefaults("binding-first"),
    legacySidebarWidth: 220
  )
  let second = WorkspacePanelLayoutStore(
    defaults: panelLayoutDefaults("binding-second"),
    legacySidebarWidth: 260
  )
  let binding = WorkspacePanelSettingsBinding()

  #expect(binding.state == nil)
  binding.bind(first)
  #expect(binding.state == WorkspacePanelLayoutState.default)
  binding.setPreferredWidth(330, for: .sidebar)
  #expect(first.state.sidebarWidth == 330)

  first.setPreferredWidth(410, for: .inspector)
  #expect(binding.state?.inspectorWidth == 410)

  binding.bind(second)
  #expect(binding.state?.sidebarWidth == 260)
  binding.setPreferredWidth(440, for: .inspector)
  #expect(second.state.inspectorWidth == 440)
  #expect(first.state.inspectorWidth == 410)
}

@Test("外观设置为最近工作区提供左右 Panel 宽度滑杆")
@MainActor
func appearanceSettingsExposeBoundPanelWidthSliders() throws {
  let defaults = panelLayoutDefaults("settings")
  let preferences = AppPreferences(defaults: defaults)
  let store = WorkspacePanelLayoutStore(defaults: defaults, legacySidebarWidth: 230)
  store.setPreferredWidth(390, for: .inspector)
  let binding = WorkspacePanelSettingsBinding()
  binding.bind(store)
  let controller = SettingsViewController(
    preferences: preferences,
    panelLayoutBinding: binding
  )
  controller.loadViewIfNeeded()
  controller.showSection(.appearance)

  let sliders = controller.view.panelStoreDescendants.compactMap { $0 as? NSSlider }
  let sidebar = try #require(
    sliders.first { $0.identifier?.rawValue == "settings-panel-width-sidebar" }
  )
  let inspector = try #require(
    sliders.first { $0.identifier?.rawValue == "settings-panel-width-inspector" }
  )
  #expect(sidebar.doubleValue == 230)
  #expect(sidebar.minValue == 180)
  #expect(sidebar.maxValue == 360)
  #expect(inspector.doubleValue == 390)
  #expect(inspector.minValue == 240)
  #expect(inspector.maxValue == 480)

  sidebar.doubleValue = 310
  _ = sidebar.sendAction(sidebar.action, to: sidebar.target)
  #expect(store.state.sidebarWidth == 310)
}

extension NSView {
  fileprivate var panelStoreDescendants: [NSView] {
    subviews.flatMap { [$0] + $0.panelStoreDescendants }
  }
}
