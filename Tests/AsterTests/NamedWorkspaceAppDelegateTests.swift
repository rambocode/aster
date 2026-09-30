// 本地窗口注册表、窗口内工作区与 AppDelegate 的集成测试：真实窗口的关闭语义、重新打开与文件菜单入口。
import AppKit
import AsterCore
import Testing

@testable import Aster

@Test("AppDelegate：⌘N 窗口关窗即删 suite，改过名的旧窗口关窗保留并可重新打开")
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

  // 改过名的窗口：变为固定保留，关窗后保留条目，可从目录重新打开并挂上新窗口。
  #expect(NSApp.sendAction(try #require(newWindow.action), to: newWindow.target, from: newWindow))
  let renamed = try #require(directory.workspaces.first { $0.storage != .standard && $0.isOpen })
  try directory.rename(renamed.id, to: "demo")
  let pinned = try #require(directory.workspaces.first { $0.name == "demo" })
  #expect(pinned.isPinned)
  guard case .suite(let pinnedSuite) = pinned.storage else { return }
  createdSuites.append(pinnedSuite)
  let pinnedWindow = try #require(directory.window(for: pinned.id))
  // 注册表名不再写进窗口副标题，Dock 菜单只显示标签标题，不会多出「(demo)」。
  #expect(pinnedWindow.subtitle.isEmpty)
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

@Test("文件菜单提供新建、重命名、删除与上一个 / 下一个工作区，不再有「切换工作区…」")
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
  let rename = try #require(file.item(at: newWindowIndex + 2))
  let delete = try #require(file.item(at: newWindowIndex + 3))
  let next = try #require(file.item(at: newWindowIndex + 4))
  let previous = try #require(file.item(at: newWindowIndex + 5))
  #expect(newWorkspace.keyEquivalent == "n" && newWorkspace.keyEquivalentModifierMask == [.command, .shift])
  #expect(rename.title == L("重命名工作区…") && rename.keyEquivalent.isEmpty)
  #expect(delete.title == L("删除工作区…") && delete.keyEquivalent.isEmpty)
  #expect(next.title == L("下一个工作区"))
  #expect(next.keyEquivalent == "]" && next.keyEquivalentModifierMask == [.command, .control])
  #expect(previous.title == L("上一个工作区"))
  #expect(previous.keyEquivalent == "[" && previous.keyEquivalentModifierMask == [.command, .control])
  #expect([newWorkspace, rename, delete, next, previous].allSatisfy { $0.target === delegate })
  // 菜单栏不再提供「切换工作区…」，⌥⌘O 也随之空出。
  #expect(file.indexOfItem(withTitle: L("切换工作区…")) == -1)
  #expect(!file.items.contains { $0.keyEquivalent == "o" && $0.keyEquivalentModifierMask == [.command, .option] })
}

@Test("窗口内工作区：新建落在已有窗口里，不新开窗口也不登记注册表；菜单能循环切换，只剩一个时置灰")
@MainActor
func workspaceGroupMenuActionsOperateOnKeyWindow() async throws {
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
  func item(_ title: String) throws -> NSMenuItem { try #require(items.first { $0.title == title }) }

  // 测试宿主里 AppDelegate 不是 NSApp.delegate，走 ⌘N 菜单动作开窗，再从 AppDelegate 认领。
  let newWindow = try #require(
    items.first { $0.keyEquivalent == "n" && $0.keyEquivalentModifierMask == [.command] })
  #expect(NSApp.sendAction(try #require(newWindow.action), to: newWindow.target, from: newWindow))
  let window = try #require(delegate.workspaceWindows.first { $0.model !== model }?.window)
  let controller = try #require(window.contentViewController as? WorkspaceViewController)
  if case .suite(let suite)? = directory.workspaceID(for: window).flatMap(directory.workspace)?.storage {
    createdSuites.append(suite)
  }
  // 无界面测试宿主拿不到 key window：把菜单作用对象固定成这个窗口。
  delegate.keyWorkspaceViewControllerProvider = { controller }
  let windowCount = delegate.workspaceWindows.count
  let registryCount = directory.workspaces.count
  let windowModel = controller.model
  let first = try #require(windowModel.selectedWorkspaceGroup)

  // 只有一个工作区：上一个 / 下一个 / 删除置灰，重命名可用。
  #expect(!delegate.validateMenuItem(try item(L("下一个工作区"))))
  #expect(!delegate.validateMenuItem(try item(L("上一个工作区"))))
  #expect(!delegate.validateMenuItem(try item(L("删除工作区…"))))
  #expect(delegate.validateMenuItem(try item(L("重命名工作区…"))))

  let second = try await WorkspaceGroupNavigator.create(named: "notes", in: controller)
  #expect(delegate.workspaceWindows.count == windowCount)
  #expect(directory.workspaces.count == registryCount)
  #expect(windowModel.workspaceGroups.map(\.id) == [first.id, second.id])
  #expect(windowModel.selectedWorkspaceGroupID == second.id)
  #expect(windowModel.visibleTabs.count == 1)

  let next = try item(L("下一个工作区"))
  #expect(delegate.validateMenuItem(next))
  #expect(delegate.validateMenuItem(try item(L("删除工作区…"))))
  #expect(NSApp.sendAction(try #require(next.action), to: next.target, from: next))
  #expect(windowModel.selectedWorkspaceGroupID == first.id)
  let previous = try item(L("上一个工作区"))
  #expect(NSApp.sendAction(try #require(previous.action), to: previous.target, from: previous))
  #expect(windowModel.selectedWorkspaceGroupID == second.id)

  // 非法名称：不建工作区。
  await #expect(throws: NamedWorkspaceRegistryError.emptyName) {
    try await WorkspaceGroupNavigator.create(named: "  ", in: controller)
  }
  #expect(windowModel.workspaceGroups.count == 2)

  // 设置等非工作区窗口在前：四个工作区菜单项全部置灰。
  delegate.keyWorkspaceViewControllerProvider = { nil }
  for title in [L("重命名工作区…"), L("删除工作区…"), L("下一个工作区"), L("上一个工作区")] {
    #expect(!delegate.validateMenuItem(try item(title)), "\(title) 应置灰")
  }
}
