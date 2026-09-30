// 本地命名工作区目录测试：迁移、旧键镜像、保留与不保留两种关闭语义、重新打开与通知。
import AppKit
import AsterCore
import Testing

@testable import Aster

/// 独立 UserDefaults suite，测试结束时删除（命名工作区的两个测试文件共用）。
@MainActor
final class NamedWorkspaceTestDefaults {
  let name = "NamedWorkspaceDirectoryTests.\(UUID().uuidString)"
  let defaults: UserDefaults

  init() throws {
    defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
  }

  func tearDown() { defaults.removePersistentDomain(forName: name) }
}

/// 记录开窗请求的假宿主，用来验证目录把哪些操作交给了 AppDelegate。
@MainActor
private final class RecordingHost: NamedWorkspaceWindowHost {
  var opened: [UUID] = []

  func openWindow(for workspace: NamedWorkspace) -> Bool {
    opened.append(workspace.id)
    return true
  }
}

/// 不显示的离屏窗口，只用作映射身份。
@MainActor
private func makeWindow() -> NSWindow {
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled],
    backing: .buffered, defer: true)
  window.isReleasedWhenClosed = false
  return window
}

/// 读取 suite 当前是否还有数据（用于判断 suite 是否被删除）。
private func suiteHasData(_ name: String) -> Bool {
  UserDefaults(suiteName: name)?.object(forKey: "probe") != nil
}

@Test("首次加载从旧 suite 列表迁移，保存后写入注册表并镜像旧键")
@MainActor
func namedWorkspaceDirectoryMigratesLegacySuites() throws {
  let isolated = try NamedWorkspaceTestDefaults()
  defer { isolated.tearDown() }
  let a = NamedWorkspaceRegistry.makeSuiteName()
  let b = NamedWorkspaceRegistry.makeSuiteName()
  isolated.defaults.set([a, "com.example.foreign", b], forKey: NamedWorkspaceDirectory.legacySuitesKey)

  let directory = NamedWorkspaceDirectory(defaults: isolated.defaults)
  let restored = directory.prepareForLaunchRestore()

  #expect(restored == [a, b])
  #expect(directory.workspaces.count == 3)
  let main = try #require(directory.workspaces.first { $0.storage == .standard })
  #expect(main.name == L("主工作区") && main.isPinned)
  #expect(isolated.defaults.data(forKey: NamedWorkspaceRegistry.defaultsKey) != nil)
  #expect(isolated.defaults.stringArray(forKey: NamedWorkspaceDirectory.legacySuitesKey) == [a, b])

  // 注册表已存在：再次加载不重新迁移，条目 ID 保持不变。
  let reloaded = NamedWorkspaceDirectory(defaults: isolated.defaults)
  #expect(Set(reloaded.workspaces.map(\.id)) == Set(directory.workspaces.map(\.id)))
}

@Test("不保留的工作区关窗后删除条目、要求删 suite，并从旧键移除")
@MainActor
func namedWorkspaceDirectoryTransientCloseDropsEntry() throws {
  let isolated = try NamedWorkspaceTestDefaults()
  defer { isolated.tearDown() }
  let directory = NamedWorkspaceDirectory(defaults: isolated.defaults)
  let suiteName = NamedWorkspaceRegistry.makeSuiteName()
  let window = makeWindow()

  let id = try directory.beginOpening(suiteName: suiteName, name: nil, isPinned: false)
  directory.attach(window, to: id)
  #expect(directory.workspaceID(for: window) == id)
  // 注册表名不写进窗口副标题（Dock 菜单会显示成「标题 (名字)」）。
  #expect(window.subtitle.isEmpty)
  #expect(isolated.defaults.stringArray(forKey: NamedWorkspaceDirectory.legacySuitesKey) == [suiteName])

  #expect(directory.windowWillClose(window))
  #expect(directory.workspace(id) == nil)
  #expect(directory.workspaceID(for: window) == nil)
  #expect(isolated.defaults.stringArray(forKey: NamedWorkspaceDirectory.legacySuitesKey) == [])
}

@Test("固定保留的工作区关窗后保留条目与 suite，可重新打开，关闭后才能删除")
@MainActor
func namedWorkspaceDirectoryPinnedCloseKeepsSnapshot() throws {
  let isolated = try NamedWorkspaceTestDefaults()
  defer { isolated.tearDown() }
  let directory = NamedWorkspaceDirectory(defaults: isolated.defaults)
  let host = RecordingHost()
  directory.host = host
  let suiteName = NamedWorkspaceRegistry.makeSuiteName()
  let suite = try #require(UserDefaults(suiteName: suiteName))
  defer { suite.removePersistentDomain(forName: suiteName) }
  suite.set("snapshot", forKey: "probe")
  let window = makeWindow()

  let id = try directory.beginOpening(suiteName: suiteName, name: "api", isPinned: true)
  directory.attach(window, to: id)
  #expect(window.subtitle.isEmpty)
  #expect(throws: NamedWorkspaceDirectoryError.workspaceIsOpen) { try directory.remove(id) }

  #expect(!directory.windowWillClose(window))
  let closed = try #require(directory.workspace(id))
  #expect(!closed.isOpen && closed.isPinned)
  #expect(isolated.defaults.stringArray(forKey: NamedWorkspaceDirectory.legacySuitesKey) == [])
  #expect(suiteHasData(suiteName))

  // 没有窗口：交给宿主重新开窗。
  #expect(directory.open(id))
  #expect(host.opened == [id])

  // 删除已关闭的工作区时一并删掉它的 suite。
  try directory.remove(id)
  #expect(directory.workspace(id) == nil)
  #expect(!suiteHasData(suiteName))
}

@Test("已打开的工作区再次打开时置前现有窗口，不再开新窗口")
@MainActor
func namedWorkspaceDirectoryOpenFocusesExistingWindow() throws {
  let directory = NamedWorkspaceDirectory(defaults: nil)
  let host = RecordingHost()
  directory.host = host
  let window = makeWindow()
  defer { window.orderOut(nil) }
  let id = try directory.beginOpening(
    suiteName: NamedWorkspaceRegistry.makeSuiteName(), name: "w", isPinned: false)
  directory.attach(window, to: id)

  #expect(directory.open(id))
  #expect(host.opened.isEmpty)
}

@Test("主窗口关闭只标记为关闭，重新打开走宿主的主窗口重建路径")
@MainActor
func namedWorkspaceDirectoryMainWindowCloseAndReopen() throws {
  let directory = NamedWorkspaceDirectory(defaults: nil)
  let host = RecordingHost()
  directory.host = host
  let window = makeWindow()
  directory.attachMainWindow(window)
  let main = try #require(directory.workspaces.first { $0.storage == .standard })
  #expect(directory.workspaceID(for: window) == main.id)

  #expect(!directory.windowWillClose(window))
  #expect(directory.workspace(main.id)?.isOpen == false)
  #expect(directory.open(main.id))
  #expect(host.opened == [main.id])
  #expect(throws: NamedWorkspaceDirectoryError.registry(.cannotRemoveStandard)) {
    try directory.remove(main.id)
  }
}

@Test("重命名后固定保留、不写窗口副标题；成为 key window 时排到最前")
@MainActor
func namedWorkspaceDirectoryRenameAndRecency() throws {
  var clock = Date(timeIntervalSince1970: 1_000)
  let directory = NamedWorkspaceDirectory(defaults: nil, now: { clock })
  let first = makeWindow()
  let second = makeWindow()
  let firstID = try directory.beginOpening(
    suiteName: NamedWorkspaceRegistry.makeSuiteName(), name: "one", isPinned: false)
  directory.attach(first, to: firstID)
  clock += 10
  let secondID = try directory.beginOpening(
    suiteName: NamedWorkspaceRegistry.makeSuiteName(), name: "two", isPinned: false)
  directory.attach(second, to: secondID)
  #expect(directory.workspaces.first?.id == secondID)

  clock += 10
  directory.windowDidBecomeKey(first)
  #expect(directory.workspaces.first?.id == firstID)

  try directory.rename(firstID, to: " renamed ")
  #expect(directory.workspace(firstID)?.name == "renamed")
  #expect(first.subtitle.isEmpty)
  #expect(directory.workspace(firstID)?.isPinned == true)
  #expect(throws: NamedWorkspaceDirectoryError.registry(.emptyName)) {
    try directory.rename(firstID, to: "  ")
  }
}

/// 以 selector 方式计数的通知观察者，避免在 @Sendable 闭包里修改捕获变量。
@MainActor
private final class ChangeCounter: NSObject {
  var count = 0
  @objc func changed(_ notification: Notification) { count += 1 }
}

@Test("变化通知：保存注册表时发出")
@MainActor
func namedWorkspaceDirectoryPostsChangeNotification() throws {
  let directory = NamedWorkspaceDirectory(defaults: nil)
  let counter = ChangeCounter()
  NotificationCenter.default.addObserver(
    counter, selector: #selector(ChangeCounter.changed(_:)),
    name: NamedWorkspaceDirectory.didChangeNotification, object: directory)
  defer { NotificationCenter.default.removeObserver(counter) }
  _ = try directory.beginOpening(
    suiteName: NamedWorkspaceRegistry.makeSuiteName(), name: "n", isPinned: false)
  directory.save()
  #expect(counter.count == 1)
}
