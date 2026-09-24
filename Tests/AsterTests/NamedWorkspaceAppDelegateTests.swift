// 本地命名工作区与 AppDelegate 的集成测试：真实窗口的关闭语义、重新打开与文件菜单入口。
import AppKit
import AsterCore
import Testing

@testable import Aster

@Test("AppDelegate：⌘N 窗口关窗即删 suite，⌘⇧N 工作区关窗保留并可重新打开")
@MainActor
func namedWorkspaceWindowsFollowCloseSemanticsInAppDelegate() throws {
  let isolated = try NamedWorkspaceTestDefaults()
  defer { isolated.tearDown() }
  let preferences = AppPreferences(defaults: isolated.defaults)
  preferences.configuration.general.closeWindowConfirmation = .never
  let model = AppModel(defaults: isolated.defaults)
  model.ensureInitialTab()
  let directory = NamedWorkspaceDirectory(defaults: isolated.defaults)
  let delegate = AsterAppDelegate(
    model: model, preferences: preferences, workspaceDirectory: directory)
  let previousWindowsMenu = NSApp.windowsMenu
  var createdSuites: [String] = []
  defer {
    _ = delegate.applicationShouldTerminate(NSApp)
    for window in NSApp.windows where directory.workspaceID(for: window) != nil { window.close() }
    for name in createdSuites { UserDefaults.standard.removePersistentDomain(forName: name) }
    NSApp.windowsMenu = previousWindowsMenu
  }
  let items = delegate.makeMainMenu().items.flatMap { $0.submenu?.items ?? [] }

  // 普通新窗口：注册为不保留，关窗后条目与 suite 都删除。
  let newWindow = try #require(
    items.first { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == [.command] })
  #expect(NSApp.sendAction(try #require(newWindow.action), to: newWindow.target, from: newWindow))
  let transient = try #require(directory.workspaces.first { $0.storage != .standard })
  guard case .suite(let transientSuite) = transient.storage else { return }
  createdSuites.append(transientSuite)
  #expect(!transient.isPinned)
  let transientWindow = try #require(directory.window(for: transient.id))
  transientWindow.close()
  #expect(directory.workspace(transient.id) == nil)

  // 命名工作区：固定保留，关窗后保留条目，可从目录重新打开并挂上新窗口。
  #expect(delegate.createNamedWorkspaceWindow(name: "demo"))
  let pinned = try #require(directory.workspaces.first { $0.name == "demo" })
  guard case .suite(let pinnedSuite) = pinned.storage else { return }
  createdSuites.append(pinnedSuite)
  let pinnedWindow = try #require(directory.window(for: pinned.id))
  #expect(pinnedWindow.subtitle == "demo")
  pinnedWindow.close()
  #expect(directory.workspace(pinned.id)?.isOpen == false)
  #expect(
    isolated.defaults.stringArray(forKey: NamedWorkspaceDirectory.legacySuitesKey) == [])

  #expect(directory.open(pinned.id))
  #expect(directory.workspace(pinned.id)?.isOpen == true)
  let reopened = try #require(directory.window(for: pinned.id))
  #expect(reopened !== pinnedWindow)
  #expect(
    isolated.defaults.stringArray(forKey: NamedWorkspaceDirectory.legacySuitesKey) == [pinnedSuite])
}

@Test("文件菜单提供新建、切换、重命名工作区；切换直接选中「工作区」过滤器")
@MainActor
func namedWorkspaceMenuEntries() throws {
  let isolated = try NamedWorkspaceTestDefaults()
  defer { isolated.tearDown() }
  let preferences = AppPreferences(defaults: isolated.defaults)
  preferences.configuration.general.closeWindowConfirmation = .never
  let model = AppModel(defaults: isolated.defaults)
  model.ensureInitialTab()
  let delegate = AsterAppDelegate(model: model, preferences: preferences)
  let previousWindowsMenu = NSApp.windowsMenu
  defer {
    _ = delegate.applicationShouldTerminate(NSApp)
    for window in NSApp.windows
    where (window.contentViewController as? WorkspaceViewController)?.model === model {
      window.close()
    }
    NSApp.windowsMenu = previousWindowsMenu
  }
  let file = try #require(delegate.makeMainMenu().items[1].submenu)
  let newWindowIndex = file.indexOfItem(withTitle: L("新建窗口"))
  let newWorkspace = try #require(file.item(at: newWindowIndex + 1))
  let switcher = try #require(file.item(at: newWindowIndex + 2))
  let rename = try #require(file.item(at: newWindowIndex + 3))
  #expect(newWorkspace.keyEquivalent == "n" && newWorkspace.keyEquivalentModifierMask == [.command, .shift])
  #expect(switcher.keyEquivalent == "o" && switcher.keyEquivalentModifierMask == [.command, .option])
  #expect(rename.title == L("重命名工作区…") && rename.keyEquivalent.isEmpty)
  #expect([newWorkspace, switcher, rename].allSatisfy { $0.target === delegate })

  #expect(NSApp.sendAction(try #require(switcher.action), to: switcher.target, from: switcher))
  let active =
    (NSApp.keyWindow?.contentViewController as? WorkspaceViewController)?.model ?? model
  #expect(active.openQuicklyInitialFilter == .workspace)
}
