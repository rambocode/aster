import AppKit
import Testing

@testable import Aster

/// 工作区窗口的几何策略：窗口尺寸只有一个权威来源，不叠加 AppKit 的 frame autosave。
@MainActor
@Test func workspaceWindowsDoNotUseFrameAutosaveSoZoomSurvivesManualResize() throws {
  let suite = "WorkspaceWindowGeometryTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.general.closeWindowConfirmation = .never
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let delegate = AsterAppDelegate(model: model, preferences: preferences)
  let previousWindowsMenu = NSApp.windowsMenu
  defer {
    _ = delegate.applicationShouldTerminate(NSApp)
    NSApp.windowsMenu = previousWindowsMenu
  }
  let menu = delegate.makeMainMenu()
  let items = menu.items.flatMap { $0.submenu?.items ?? [] }
  // 按快捷键定位而不是按标题：菜单文案会随界面语言变化。
  let newWindow = try #require(
    items.first { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == [.command] })
  #expect(NSApp.sendAction(try #require(newWindow.action), to: newWindow.target, from: newWindow))
  let window = try #require(
    NSApp.windows.first { $0.contentViewController is WorkspaceViewController })

  // frame autosave 会成为窗口尺寸的第二份可写副本，并且和 zoom 抢同一份「保存的
  // frame」：用户手动拖过窗口大小后，双击标题栏放大会被判定为「已放大」而立刻缩回。
  #expect(window.frameAutosaveName.isEmpty)
  #expect(window.styleMask.contains(.resizable))
}
