import AsterCore
import Foundation
import Testing

@testable import Aster

@MainActor
private func behaviorTestDefaults() -> UserDefaults {
  let suite = "AsterBehaviorTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

@Test("自动新标签位置把空标签放在当前分组末尾，把内容标签放在当前标签后")
@MainActor
func appModelAppliesContextAwareNewTabPosition() throws {
  let defaults = behaviorTestDefaults()
  let snapshots = (0..<4).map { index in
    WorkspaceTabSnapshot(
      id: UUID(),
      title: "tab-\(index)",
      layout: .leaf(
        PaneDescriptor(
          kind: .editor,
          workingDirectory: "/tmp/group-\(index)",
          resourcePath: "/tmp/group-\(index)/note.md"
        )
      )
    )
  }
  let workspace = WorkspaceSnapshot(
    selectedTabID: snapshots[0].id,
    tabs: snapshots,
    dividerAfterTabIDs: [snapshots[1].id]
  )
  defaults.set(try JSONEncoder().encode(workspace), forKey: "aster.workspace.snapshot.v1")
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  var switchedToManualOrder = false
  model.onTabOrderBecameManual = { switchedToManualOrder = true }

  model.newTab(workingDirectory: "/tmp/empty", position: .automatic, hasContent: false)
  #expect(model.tabs.map(\.workingDirectory) == [
    "/tmp/group-0", "/tmp/group-1", "/tmp/empty", "/tmp/group-2", "/tmp/group-3",
  ])
  #expect(switchedToManualOrder)

  model.select(model.tabs[0])
  model.newTab(workingDirectory: "/tmp/content", position: .automatic, hasContent: true)
  #expect(model.tabs[1].workingDirectory == "/tmp/content")
}

@Test("末尾插入不会删除已有手动分隔线")
@MainActor
func endNewTabPositionPreservesTrailingDivider() throws {
  let defaults = behaviorTestDefaults()
  let first = WorkspaceTabSnapshot(
    id: UUID(), title: "first",
    layout: .leaf(
      PaneDescriptor(kind: .editor, workingDirectory: "/tmp/first", resourcePath: "/tmp/first.md")))
  defaults.set(
    try JSONEncoder().encode(
      WorkspaceSnapshot(
        selectedTabID: first.id,
        tabs: [first],
        dividerAfterTabIDs: [first.id]
      )),
    forKey: "aster.workspace.snapshot.v1"
  )
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  var switchedToManualOrder = false
  model.onTabOrderBecameManual = { switchedToManualOrder = true }

  model.newTab(workingDirectory: "/tmp/end", position: .end)

  #expect(model.dividerAfterTabIDs.contains(first.id))
  #expect(switchedToManualOrder)
}

@Test("最近关闭标签跨启动持久化并按关闭顺序恢复")
@MainActor
func appModelPersistsAndReopensClosedTabs() throws {
  let defaults = behaviorTestDefaults()
  let snapshots = (0..<2).map { index in
    WorkspaceTabSnapshot(
      id: UUID(),
      title: "closed-\(index)",
      layout: .leaf(
        PaneDescriptor(
          kind: .editor,
          workingDirectory: "/tmp/closed-\(index)",
          resourcePath: "/tmp/closed-\(index).md"
        )
      )
    )
  }
  defaults.set(
    try JSONEncoder().encode(
      WorkspaceSnapshot(selectedTabID: snapshots[1].id, tabs: snapshots)),
    forKey: "aster.workspace.snapshot.v1"
  )
  var model: AppModel? = AppModel(defaults: defaults)
  model?.ensureInitialTab()
  model?.closeSelectedTab()
  #expect(model?.tabs.map(\.title) == ["closed-0"])
  model = nil

  let restored = AppModel(defaults: defaults)
  restored.ensureInitialTab()
  #expect(restored.reopenLastClosedTab())
  #expect(restored.tabs.map(\.title) == ["closed-0", "closed-1"])
  #expect(restored.selectedTab?.title == "closed-1")
  #expect(!restored.reopenLastClosedTab())
}

@Test("标签标题覆盖与程序标题通道会进入工作区快照")
@MainActor
func terminalTabPersistsIndependentTitleState() {
  let tab = TerminalTabItem(title: "Shell", workingDirectory: "/tmp")

  tab.applyProgramTitle(code: 2, text: "project — vim")
  tab.applyProgramTitle(code: 1, text: "vim")
  tab.setTabTitleOverride(.prefix("prod: "))
  #expect(tab.title == "prod: vim")
  #expect(tab.windowTitle == "project — vim")

  let restored = TerminalTabItem(snapshot: tab.snapshot)
  #expect(restored.title == "prod: vim")
  #expect(restored.windowTitle == "project — vim")
  restored.applyProgramTitle(code: 1, text: "ssh")
  #expect(restored.title == "prod: ssh")
}

@Test("后台 Pane 标题不会覆盖活动 Pane，切换焦点后使用目标 Pane 的最新标题")
@MainActor
func terminalTabUsesFocusedPaneTitleChannel() throws {
  let tab = TerminalTabItem(title: "Shell", workingDirectory: "/tmp")
  let firstPane = tab.activePaneID
  tab.applyProgramTitle(paneID: firstPane, code: 0, text: "background")
  tab.split(direction: .right)
  let secondPane = tab.activePaneID
  #expect(tab.title == "tmp")

  tab.applyProgramTitle(paneID: secondPane, code: 0, text: "active")
  tab.applyProgramTitle(paneID: firstPane, code: 0, text: "background")
  #expect(tab.title == "active")

  tab.setActivePane(firstPane)
  #expect(tab.title == "background")
  #expect(tab.windowTitle == "background")
}

@Test("空固定名称恢复自动模式且目录回退会进入快照")
@MainActor
func emptyFixedTitleRestoresAutomaticDirectoryFallback() {
  let tab = TerminalTabItem(title: "old", workingDirectory: "/tmp/old")

  tab.setTabTitleOverride(.name(""))
  tab.layout = tab.layout.updatingPane(paneID: tab.activePaneID) { pane in
    var pane = pane
    pane.workingDirectory = "/tmp/new-folder"
    return pane
  }
  tab.updateTitleFallback("new-folder")

  #expect(tab.tabTitleOverride == .automatic)
  #expect(tab.title == "new-folder")
  #expect(TerminalTabItem(snapshot: tab.snapshot).title == "new-folder")
}

@Test("目录外部入口在自动策略下紧跟当前标签")
@MainActor
func directoryOpenUsesContentInsertionBranch() throws {
  let defaults = behaviorTestDefaults()
  let snapshots = (0..<2).map { index in
    WorkspaceTabSnapshot(
      id: UUID(), title: "existing-\(index)",
      layout: .leaf(
        PaneDescriptor(
          kind: .editor,
          workingDirectory: "/tmp/existing-\(index)",
          resourcePath: "/tmp/existing-\(index).md"
        )))
  }
  defaults.set(
    try JSONEncoder().encode(
      WorkspaceSnapshot(selectedTabID: snapshots[0].id, tabs: snapshots)),
    forKey: "aster.workspace.snapshot.v1"
  )
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-content-entry-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()

  model.handleOpenURL(directory)

  #expect(model.tabs[1].workingDirectory == directory.path)
}

@Test("真实 OSC 字节保留独立通道并参与 SwiftTerm 标题栈恢复")
@MainActor
func terminalSessionPreservesSwiftTermTitleState() async throws {
  let defaults = behaviorTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let session = TerminalSession(workingDirectory: "/tmp")
  var events: [(Int, String)] = []
  session.onTitleUpdate = { events.append(($0, $1)) }
  let terminalView = session.makeTerminalView(preferences: preferences)
  defer { session.stop(immediately: true) }

  // 通过真实 PTY 输出入口验证，而不是直接调用 Terminal.feed。macOS 版 SwiftTerm
  // 不转发图标标题回调，只有这个入口能覆盖 Aster 的补偿传播链。
  let output = Array(
    "\u{001B}]0;alpha\u{0007}\u{001B}[22;0t\u{001B}]0;beta\u{0007}\u{001B}[23;0t".utf8)
  terminalView.dataReceived(slice: output[...])
  try await Task.sleep(for: .milliseconds(50))

  #expect(session.terminalTitle == "alpha")
  #expect(session.terminalIconTitle == "alpha")
  #expect(events.contains { $0.0 == 2 && $0.1 == "alpha" })
  #expect(events.contains { $0.0 == 2 && $0.1 == "beta" })
  #expect(events.contains { $0.0 == 0 && $0.1 == "beta" })
  #expect(events.last { $0.0 == 2 }?.1 == "alpha")
  #expect(events.last { $0.0 == 1 }?.1 == "alpha")
}

@Test("链接检测开关实时同步到已打开终端")
@MainActor
func terminalSessionAppliesLinkDetectionPreference() {
  let defaults = behaviorTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.controls.linkDetectionEnabled = false
  let session = TerminalSession(workingDirectory: "/tmp")
  let terminalView = session.makeTerminalView(preferences: preferences)
  defer { session.stop(immediately: true) }

  if case .none = terminalView.linkReporting {
    // 关闭时不得让 SwiftTerm 继续进行隐式或 OSC 8 点击命中。
  } else {
    Issue.record("链接检测关闭后 linkReporting 应为 none")
  }

  preferences.configuration.controls.linkDetectionEnabled = true
  session.apply(preferences: preferences)
  if case .implicit = terminalView.linkReporting {
    // 开启后同时恢复 OSC 8 和普通文字目标检测。
  } else {
    Issue.record("链接检测开启后 linkReporting 应为 implicit")
  }
}

@Test("同一 PTY 分片中标题栈恢复后的 OSC 更新保持最后生效")
@MainActor
func terminalSessionPreservesTitleEventOrderWithinChunk() async throws {
  let defaults = behaviorTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let session = TerminalSession(workingDirectory: "/tmp")
  var events: [(Int, String)] = []
  session.onTitleUpdate = { events.append(($0, $1)) }
  let terminalView = session.makeTerminalView(preferences: preferences)
  defer { session.stop(immediately: true) }

  let output = Array(
    ("\u{001B}]0;alpha\u{0007}\u{001B}[22;0t"
      + "\u{001B}]0;beta\u{0007}\u{001B}[23;0t"
      + "\u{001B}]0;gamma\u{0007}").utf8)
  terminalView.dataReceived(slice: output[...])
  try await Task.sleep(for: .milliseconds(50))

  #expect(session.terminalTitle == "gamma")
  #expect(session.terminalIconTitle == "gamma")
  #expect(events.last?.0 == 0)
  #expect(events.last?.1 == "gamma")
}

@Test("远端 OSC 7 不会成为本机相对文件路径基准")
@MainActor
func terminalSessionRejectsRemoteWorkingDirectoryForLocalLinks() async {
  let session = TerminalSession(workingDirectory: "/tmp")
  let source = AsterTerminalView(frame: .zero)

  session.hostCurrentDirectoryUpdate(
    source: source,
    directory: "file://remote.example/home/remote-user"
  )
  await Task.yield()

  #expect(!session.currentWorkingDirectoryIsLocal)
  #expect(session.currentWorkingDirectory == "/tmp")
}

@Test("OSC 7 目录变化按设置自动学习并跨 AppModel 恢复")
@MainActor
func appModelRecordsFrequentFoldersFromTerminalDirectoryChanges() async throws {
  let defaults = behaviorTestDefaults()
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-frecency-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let model = AppModel(defaults: defaults)
  model.frecencyAutoRecord = true
  model.ensureInitialTab()
  let session = try #require(model.selectedTab?.activeSession)
  let preferences = AppPreferences(defaults: defaults)
  let terminalView = session.makeTerminalView(preferences: preferences)
  defer { session.stop(immediately: true) }

  session.hostCurrentDirectoryUpdate(source: terminalView, directory: directory.path)
  try await Task.sleep(for: .milliseconds(50))

  #expect(model.frequentFolderMatches(query: directory.lastPathComponent).first?.path == directory.path)
  let restored = AppModel(defaults: defaults)
  #expect(restored.frequentFolderMatches(query: directory.lastPathComponent).first?.path == directory.path)
}

@Test("关闭自动记录时 OSC 7 不写入 Frequent Folders")
@MainActor
func appModelHonorsDisabledFrequentFolderAutoRecord() async throws {
  let defaults = behaviorTestDefaults()
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-disabled-record-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let model = AppModel(defaults: defaults)
  model.frecencyAutoRecord = false
  model.ensureInitialTab()
  let session = try #require(model.selectedTab?.activeSession)
  let preferences = AppPreferences(defaults: defaults)
  let terminalView = session.makeTerminalView(preferences: preferences)
  defer { session.stop(immediately: true) }

  session.hostCurrentDirectoryUpdate(source: terminalView, directory: directory.path)
  try await Task.sleep(for: .milliseconds(50))

  #expect(model.frequentFolderMatches(query: directory.lastPathComponent).isEmpty)
}

@Test("新建同目录分屏不会被误算为目录访问")
@MainActor
func appModelDoesNotRecordInitialDirectoryPublisherValue() throws {
  let defaults = behaviorTestDefaults()
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-split-score-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let model = AppModel(defaults: defaults)
  model.newTab(workingDirectory: directory.path)
  #expect(model.learnFolder(directory.path))
  let scoreBeforeSplit = try #require(
    model.frequentFolderMatches(query: directory.lastPathComponent).first?.score)

  model.splitSelectedTab(.right)

  let scoreAfterSplit = try #require(
    model.frequentFolderMatches(query: directory.lastPathComponent).first?.score)
  #expect(scoreAfterSplit == scoreBeforeSplit)
}
