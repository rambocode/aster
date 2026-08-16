import AppKit
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

private extension NSView {
  /// 本文件的轻量视图树遍历，用于验证 Prompt Queue 的真实按钮接线而非仅测模型回调。
  var descendantViews: [NSView] { subviews + subviews.flatMap(\.descendantViews) }
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

  model.newTab(workingDirectory: "/tmp/empty", position: .automatic, hasContent: false)
  #expect(model.tabs.map(\.workingDirectory) == [
    "/tmp/group-0", "/tmp/group-1", "/tmp/empty", "/tmp/group-2", "/tmp/group-3",
  ])

  model.select(model.tabs[0])
  model.newTab(workingDirectory: "/tmp/content", position: .automatic, hasContent: true)
  #expect(model.tabs[1].workingDirectory == "/tmp/content")
}

@Test("新建标签继承当前选中标签的工作目录，工作区为空时回退 home")
@MainActor
func newTabInheritsSelectedTabWorkingDirectory() throws {
  let defaults = behaviorTestDefaults()
  let snapshot = WorkspaceTabSnapshot(
    id: UUID(),
    title: "aster",
    layout: .leaf(
      PaneDescriptor(
        kind: .editor,
        workingDirectory: "/tmp/project-aster",
        resourcePath: "/tmp/project-aster/note.md"
      ))
  )
  let workspace = WorkspaceSnapshot(
    selectedTabID: snapshot.id, tabs: [snapshot], dividerAfterTabIDs: [])
  defaults.set(try JSONEncoder().encode(workspace), forKey: "aster.workspace.snapshot.v1")
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()

  // ⌘T/侧栏「+」等无参入口：新标签落在当前标签的目录里，因此归入同一项目分组。
  model.newTab()
  #expect(model.tabs.count == 2)
  #expect(model.selectedTab?.workingDirectory == "/tmp/project-aster")

  // 没有可继承的标签（首个标签）时仍从 home 启动。
  let empty = AppModel(defaults: behaviorTestDefaults())
  empty.ensureInitialTab()
  #expect(
    empty.tabs.first?.workingDirectory
      == FileManager.default.homeDirectoryForCurrentUser.path)
}

@Test("查看会话历史按聚焦 Pane 的项目过滤，通用入口回到全部")
@MainActor
func presentAgentHistoryScopesToFocusedPaneProject() {
  let defaults = behaviorTestDefaults()
  let model = AppModel(defaults: defaults)
  let bound = AgentSessionHistory(
    metadata: AgentSessionMetadata(
      id: "claude-bound",
      configuration: AgentSessionConfiguration(provider: .claudeCode),
      projectDirectory: "/tmp/proj-a",
      title: "Bound",
      createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 1),
      transcriptFileURL: URL(fileURLWithPath: "/tmp/claude-bound.jsonl")
    ),
    transcript: .empty
  )
  model.replaceAgentHistoriesForTesting([bound])

  // 已绑定 session ID：项目取历史里的归属，而不是 Pane 当前 cwd。
  model.presentAgentHistory(
    scopedTo: FocusedAgentSessionContext(
      provider: .claudeCode,
      sessionID: "claude-bound",
      workingDirectory: "/tmp/pane-cwd",
      configuration: AgentSessionConfiguration(provider: .claudeCode)
    ))
  #expect(model.isAgentHistoryPresented)
  #expect(model.agentHistoryProjectScope == "/tmp/proj-a")

  // 尚无 session ID：退回 Pane 工作目录，且经过归一化（去尾部斜杠）。
  model.presentAgentHistory(
    scopedTo: FocusedAgentSessionContext(
      provider: .codex,
      sessionID: nil,
      workingDirectory: "/tmp/pane-cwd/",
      configuration: AgentSessionConfiguration(provider: .codex)
    ))
  #expect(model.agentHistoryProjectScope == "/tmp/pane-cwd")

  // 命令面板等无参入口必须清掉过滤范围，回到全部历史。
  model.presentAgentHistory()
  #expect(model.agentHistoryProjectScope == nil)
  #expect(model.isAgentHistoryPresented)
}

@Test("Agent Fork 落点创建指定分屏或新标签并继承活动目录")
@MainActor
func agentContinuationPlacementCreatesRequestedWorkspaceTarget() {
  let defaults = behaviorTestDefaults()
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer {
    for tab in model.tabs { tab.stop(immediately: true) }
  }
  let context = FocusedAgentSessionContext(
    provider: .codex,
    sessionID: "session-placement",
    workingDirectory: "/tmp/agent-project",
    configuration: .init(provider: .codex)
  )

  model.continueAgentSession(context, kind: .fork, placement: .newTab)
  #expect(model.tabs.count == 2)
  #expect(model.selectedTab?.workingDirectory == "/tmp/agent-project")

  model.continueAgentSession(context, kind: .fork, placement: .split(.left))
  #expect(model.selectedTab?.layout.allPanes.count == 2)
  #expect(model.selectedTab?.activeRuntime?.descriptor.workingDirectory == "/tmp/agent-project")
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

  model.newTab(workingDirectory: "/tmp/end", position: .end)

  #expect(model.dividerAfterTabIDs.contains(first.id))
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

@Test("Pane 与 Tab 共用最近关闭顺序且 Pane 以新运行态恢复")
@MainActor
func appModelRestoresClosedPaneFromUnifiedHistory() {
  let defaults = behaviorTestDefaults()
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  model.splitSelectedTab(.right)
  let restoredPaneID = model.selectedTab?.activePaneID

  model.closeActivePane()
  #expect(model.selectedTab?.layout.allPanes.count == 1)
  #expect(model.reopenLastClosedTab())

  #expect(model.selectedTab?.layout.allPanes.count == 2)
  #expect(model.selectedTab?.activePaneID == restoredPaneID)
  #expect(model.selectedTab?.activeSession?.statusIsRunning == false)
}

@Test("普通退出遵循启动偏好，连续异常恢复会绕过损坏快照")
@MainActor
func applicationSessionRecoveryDistinguishesCleanLaunchAndCrashLoop() throws {
  let snapshot = WorkspaceTabSnapshot(
    id: UUID(),
    title: "restored",
    layout: .leaf(
      PaneDescriptor(kind: .editor, workingDirectory: "/tmp", resourcePath: "/tmp/a.txt"))
  )

  let cleanDefaults = behaviorTestDefaults()
  cleanDefaults.set(
    try JSONEncoder().encode(WorkspaceSnapshot(selectedTabID: snapshot.id, tabs: [snapshot])),
    forKey: "aster.workspace.snapshot.v1"
  )
  let clean = AppModel(defaults: cleanDefaults)
  clean.beginApplicationSession(launchBehavior: .newWindow)
  clean.ensureInitialTab()
  #expect(clean.tabs.first?.title != "restored")

  let crashDefaults = behaviorTestDefaults()
  crashDefaults.set(
    try JSONEncoder().encode(WorkspaceSnapshot(selectedTabID: snapshot.id, tabs: [snapshot])),
    forKey: "aster.workspace.snapshot.v1"
  )
  crashDefaults.set(true, forKey: "aster.session.running.v1")
  crashDefaults.set(2, forKey: "aster.session.crash-count.v1")
  let crashLoop = AppModel(defaults: crashDefaults)
  crashLoop.beginApplicationSession(launchBehavior: .restoreLastSession)
  crashLoop.ensureInitialTab()
  #expect(crashLoop.tabs.first?.title != "restored")
}

@Test("CLI 新窗口与命令面板窗口动作通过显式 AppKit 路由且不污染当前标签")
@MainActor
func appModelRoutesWindowOnlyActionsWithoutLocalFallback() throws {
  let defaults = behaviorTestDefaults()
  let model = AppModel(defaults: defaults)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-window-route-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appendingPathComponent("notes.md")
  try "hello".write(to: file, atomically: true, encoding: .utf8)
  var requestedPane: PaneDescriptor?
  var emptyWindowRequests = 0
  var pinRequests = 0
  var pictureInPictureModes: [Bool] = []
  model.onRequestNewWindow = { descriptor in
    if let descriptor { requestedPane = descriptor } else { emptyWindowRequests += 1 }
    return true
  }
  model.onRequestToggleWindowPin = { pinRequests += 1 }
  model.onRequestPictureInPicture = { pictureInPictureModes.append($0) }
  var response: WorkflowCLIExecutionResponse?

  model.executeWorkflowCLI(
    .openTarget(.init(target: .localPath(file.path), mode: .edit, placement: .newWindow)),
    allowSendKeys: false,
    allowSensitiveSessions: false
  ) { response = $0 }

  #expect(response?.exitCode == 0)
  #expect(requestedPane?.kind == .editor)
  #expect(requestedPane?.resourcePath == file.path)
  #expect(model.tabs.isEmpty)

  for identifier in ["new-window", "pin-window", "picture-in-picture", "picture-in-picture-follow"] {
    let command = try #require(model.paletteCommands.first { $0.id == identifier })
    model.performPaletteCommand(command)
  }
  #expect(emptyWindowRequests == 1)
  #expect(pinRequests == 1)
  #expect(pictureInPictureModes == [false, true])
}

@Test("统一资源路由保持 placement 与 view edit 模式语义")
@MainActor
func appModelOpensResourcesThroughUnifiedPlacementRouter() throws {
  let defaults = behaviorTestDefaults()
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-resource-router-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer {
    model.tabs.forEach { $0.stop(immediately: true) }
    try? FileManager.default.removeItem(at: root)
  }
  let file = root.appendingPathComponent("notes.md")
  try Data("# Notes".utf8).write(to: file)

  #expect(model.openResource(file, mode: .view, placement: .split(.right)))
  #expect(model.selectedTab?.layout.allPanes.count == 2)
  #expect(model.selectedTab?.activeRuntime?.descriptor.kind == .preview)
  #expect(model.selectedTab?.activeRuntime?.isReadOnly == true)

  #expect(model.openResource(file, mode: .edit, placement: .newTab))
  #expect(model.tabs.count == 2)
  #expect(model.selectedTab?.activeRuntime?.descriptor.kind == .editor)
  #expect(model.selectedTab?.activeRuntime?.isReadOnly == false)

  #expect(model.openResource(file, mode: .automatic, placement: .currentPane))
  #expect(model.selectedTab?.activeRuntime?.descriptor.kind == .editor)
  let image = root.appendingPathComponent("preview.png")
  try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
  #expect(model.openResource(image, mode: .automatic, placement: .currentPane))
  #expect(model.selectedTab?.activeRuntime?.descriptor.kind == .preview)

  var newWindowPane: PaneDescriptor?
  model.onRequestNewWindow = { newWindowPane = $0; return true }
  #expect(model.openResource(file, mode: .view, placement: .newWindow))
  #expect(newWindowPane?.kind == .preview)

  #expect(model.openResource(root, mode: .edit, placement: .newTab))
  #expect(model.selectedTab?.activeRuntime?.descriptor.kind == .fileBrowser)
  #expect(model.selectedTab?.activeRuntime?.descriptor.resourcePath == root.path)
}

@Test("重命名资源会同步已打开文件及其目录后代 Pane")
@MainActor
func appModelRelocatesOpenResourcePathsAfterRename() throws {
  let model = AppModel(defaults: behaviorTestDefaults())
  model.ensureInitialTab()
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-relocate-\(UUID().uuidString)", isDirectory: true)
  let oldFolder = root.appendingPathComponent("Old", isDirectory: true)
  let newFolder = root.appendingPathComponent("New", isDirectory: true)
  try FileManager.default.createDirectory(at: oldFolder, withIntermediateDirectories: true)
  defer {
    model.tabs.forEach { $0.stop(immediately: true) }
    try? FileManager.default.removeItem(at: root)
  }
  let file = oldFolder.appendingPathComponent("note.txt")
  try Data("hello".utf8).write(to: file)
  #expect(model.openResource(file, mode: .edit, placement: .split(.right)))
  model.selectedTab?.activeRuntime?.updateDocument("unsaved")
  try FileManager.default.moveItem(at: oldFolder, to: newFolder)

  model.relocateOpenResources(from: oldFolder, to: newFolder)

  #expect(model.selectedTab?.activeRuntime?.descriptor.resourcePath == newFolder.appendingPathComponent("note.txt").path)
  #expect(model.selectedTab?.activeRuntime?.documentText == "unsaved")
  #expect(model.selectedTab?.activeRuntime?.isDirty == true)
  model.selectedTab?.activeRuntime?.saveDocument()
  #expect(try String(contentsOf: newFolder.appendingPathComponent("note.txt"), encoding: .utf8) == "unsaved")
}

@Test("文件 Send to Chat 只接受有界 UTF-8 普通文件并写入终端 Composer")
@MainActor
func appModelAddsSafeFileContextToComposer() throws {
  let model = AppModel(defaults: behaviorTestDefaults())
  model.ensureInitialTab()
  let paneID = try #require(model.selectedTab?.activePaneID)
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-file-chat-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  let file = root.appendingPathComponent("context.txt")
  try "TOKEN=secret-value\nhello".write(to: file, atomically: true, encoding: .utf8)

  model.sendFileToChat(file)

  let draft = model.composerState(for: paneID).draft
  #expect(model.isComposerPresented)
  #expect(draft.contains("source=\"file-selection\""))
  #expect(draft.contains(file.path))
  #expect(draft.contains("TOKEN=[REDACTED]"))
  #expect(!draft.contains("secret-value"))
}

@Test("编辑器入口打开当前 Pane 的停靠 Composer 输入区")
@MainActor
func appModelOpensComposerForTheActivePane() async throws {
  let defaults = behaviorTestDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  model.splitSelectedTab(.right)
  let activePaneID = try #require(model.selectedTab?.activePaneID)
  defer { model.tabs.forEach { $0.stop(immediately: true) } }

  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  defer { window.orderOut(nil) }

  model.toggleComposer()
  try await Task.sleep(for: .milliseconds(50))
  window.contentView?.layoutSubtreeIfNeeded()

  #expect(model.isComposerPresented)
  #expect(model.composerState(for: activePaneID).presentation == .docked)
  #expect(model.composerState(for: activePaneID).draft.isEmpty)
  #expect(model.selectedTab?.activePaneID == activePaneID)
  let composer = try #require(
    controller.view.descendantViews.first { $0.identifier?.rawValue == "agent-composer" })
  let input = try #require(
    controller.view.descendantViews.compactMap { $0 as? ComposerTextView }
      .first { $0.identifier?.rawValue == "agent-composer-input" })
  #expect(composer.frame.height == 174)
  #expect(input.isEditable)
  #expect(input.placeholder == "Type here...")
}

@Test("发送到聊天只发现运行中的 Claude 或 Codex，并且仅预填不回车")
@MainActor
func appModelPrefillsSelectedAgentChatWithoutSubmitting() async throws {
  let model = AppModel(defaults: behaviorTestDefaults())
  model.ensureInitialTab()
  let session = try #require(model.selectedTab?.activeSession)
  let preferences = AppPreferences(defaults: behaviorTestDefaults())
  let terminal = try #require(session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }

  terminal.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .idle))
  var requested: AgentChatPresentation?
  let cancellable = model.agentChatPresentationRequested.sink { requested = $0 }
  defer { cancellable.cancel() }

  model.presentAgentChat()

  let presentation = try #require(requested)
  #expect(presentation.destinations.count == 1)
  #expect(presentation.destinations[0].provider == .codex)

  var encoded: [UInt8] = []
  terminal.onEncodedInput = { encoded.append(contentsOf: $0) }
  #expect(
    model.prefillAgentChat(
      destination: presentation.destinations[0],
      comment: "__CHAT_PREFILL_DELIVERED__",
      selection: nil,
      transcript: nil
    )
  )
  #expect(encoded.contains(13) == false)
  // “发送到聊天”与 Prompt 队列一样必须按普通键入传输。强制 bracketed paste 在部分
  // Codex/Claude TUI 中会被忽略，表现为弹窗提示成功但目标输入框没有文字。
  #expect(String(decoding: encoded, as: UTF8.self).contains("\u{001B}[200~") == false)
  #expect(String(decoding: encoded, as: UTF8.self).contains("__CHAT_PREFILL_DELIVERED__"))

  // 仅观察编码回调不能证明真实终端收到字节。预填不回车时，运行中的 zsh 仍会回显普通
  // 输入；因此等待 grid 出现 marker，覆盖“弹窗显示成功但 PTY 没有收到内容”的回归。
  for _ in 0..<20 {
    if session.textSnapshot().lines.joined(separator: "\n").contains("__CHAT_PREFILL_DELIVERED__") {
      break
    }
    try await Task.sleep(for: .milliseconds(25))
  }
  #expect(session.textSnapshot().lines.joined(separator: "\n").contains("__CHAT_PREFILL_DELIVERED__"))
}

@Test("Prompt 队列在 Agent 执行期间只排队，手动发送仍可插队提交")
@MainActor
func appModelKeepsPromptQueuedWhileAgentIsProcessing() async throws {
  let model = AppModel(defaults: behaviorTestDefaults())
  model.ensureInitialTab()
  let paneID = try #require(model.selectedTab?.activePaneID)
  let session = try #require(model.selectedTab?.activeSession)
  let terminal = try #require(
    session.makeTerminalView(preferences: AppPreferences(defaults: behaviorTestDefaults()))
      as? AsterTerminalView
  )
  defer { session.stop(immediately: true) }

  var encoded: [UInt8] = []
  terminal.onEncodedInput = { encoded.append(contentsOf: $0) }
  terminal.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .processing))
  #expect(model.updatePromptQueueDraft("next task", paneID: paneID))
  #expect(model.enqueuePromptQueueDraft(paneID: paneID))
  #expect(encoded.isEmpty)
  let queuedItem = try #require(model.promptQueueItems(for: paneID).first)

  // 等待权限确认时同样不自动写入：屏幕上是选择器，回车会替用户批准一次工具调用。
  terminal.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .awaitingInput))
  #expect(session.agentTaskState == .awaitingInput)
  #expect(model.promptQueueItems(for: paneID).count == 1)
  #expect(encoded.isEmpty)

  #expect(model.sendPromptQueueItem(id: queuedItem.id, paneID: paneID))
  #expect(model.promptQueueItems(for: paneID).isEmpty)
  #expect(String(decoding: encoded, as: UTF8.self).contains("next task"))
  // Return 刻意与文本分批投递，先确认它没有混在同一批里，再等它单独抵达。
  #expect(encoded.contains(13) == false)
  try await Task.sleep(for: .milliseconds(250))
  #expect(encoded.contains(13))
}

@Test("Agent hook 报告 idle 后 Prompt 队列自动逐条派发")
@MainActor
func promptQueueAutoDispatchesWhenAgentHookReportsIdle() throws {
  let model = AppModel(defaults: behaviorTestDefaults())
  model.ensureInitialTab()
  let paneID = try #require(model.selectedTab?.activePaneID)
  let session = try #require(model.selectedTab?.activeSession)
  let terminal = try #require(
    session.makeTerminalView(preferences: AppPreferences(defaults: behaviorTestDefaults()))
      as? AsterTerminalView
  )
  defer { session.stop(immediately: true) }

  var encoded: [UInt8] = []
  terminal.onEncodedInput = { encoded.append(contentsOf: $0) }
  terminal.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .processing))
  for text in ["first task", "second task"] {
    #expect(model.updatePromptQueueDraft(text, paneID: paneID))
    #expect(model.enqueuePromptQueueDraft(paneID: paneID))
  }
  #expect(encoded.isEmpty)

  // Stop hook 到达即当前轮次结束，队首自动写入；但严格单 in-flight，第二条必须等
  // 这一条真正跑完，否则两条 prompt 会挤进同一轮对话。
  terminal.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .idle))
  #expect(String(decoding: encoded, as: UTF8.self).contains("first task"))
  #expect(String(decoding: encoded, as: UTF8.self).contains("second task") == false)
  #expect(model.promptQueueItems(for: paneID).map(\.text) == ["second task"])

  terminal.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .processing))
  #expect(String(decoding: encoded, as: UTF8.self).contains("second task") == false)
  terminal.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .idle))
  #expect(String(decoding: encoded, as: UTF8.self).contains("second task"))
  #expect(model.promptQueueItems(for: paneID).isEmpty)
}

@Test("Agent 空闲时入队立即派发，未安装 hook 的 Pane 保持手动")
@MainActor
func promptQueueDispatchesOnEnqueueOnlyWithAuthoritativeHook() throws {
  let model = AppModel(defaults: behaviorTestDefaults())
  model.ensureInitialTab()
  let paneID = try #require(model.selectedTab?.activePaneID)
  let session = try #require(model.selectedTab?.activeSession)
  let terminal = try #require(
    session.makeTerminalView(preferences: AppPreferences(defaults: behaviorTestDefaults()))
      as? AsterTerminalView
  )
  defer { session.stop(immediately: true) }

  var encoded: [UInt8] = []
  terminal.onEncodedInput = { encoded.append(contentsOf: $0) }

  // 没有 hook 的普通 CLI：输出探针推断的 idle 不足以证明可以写入，队列只排队。
  #expect(model.updatePromptQueueDraft("manual only", paneID: paneID))
  #expect(model.enqueuePromptQueueDraft(paneID: paneID))
  #expect(encoded.isEmpty)
  #expect(model.promptQueueItems(for: paneID).count == 1)
  model.removePromptQueueItem(id: try #require(model.promptQueueItems(for: paneID).first).id, paneID: paneID)

  // hook 已经把 Pane 标记为 idle 时不会再有状态变化事件，入队本身就是派发时机。
  terminal.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .idle))
  #expect(model.updatePromptQueueDraft("auto now", paneID: paneID))
  #expect(model.enqueuePromptQueueDraft(paneID: paneID))
  #expect(String(decoding: encoded, as: UTF8.self).contains("auto now"))
  #expect(model.promptQueueItems(for: paneID).isEmpty)
}

@Test("Prompt 队列卡片左侧发送按钮会写入当前 CLI 并回车")
@MainActor
func promptQueueCardSendButtonSubmitsToCurrentCLI() async throws {
  let defaults = behaviorTestDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let paneID = try #require(model.selectedTab?.activePaneID)
  let session = try #require(model.selectedTab?.activeSession)
  let terminal = try #require(session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }

  var encoded: [UInt8] = []
  terminal.onEncodedInput = { encoded.append(contentsOf: $0) }
  // Prompt Queue 是终端输入工作流，不依赖 Claude/Codex 的瞬时识别状态；普通 CLI
  // 也必须能打开列表并由左侧按钮完成粘贴加 Return。
  #expect(model.canPresentPromptQueue)
  #expect(model.updatePromptQueueDraft("printf '__PROMPT_QUEUE_DELIVERED__\\n'", paneID: paneID))
  #expect(model.enqueuePromptQueueDraft(paneID: paneID))

  let controller = WorkspaceViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()
  model.togglePromptQueue()
  controller.view.layoutSubtreeIfNeeded()

  let button = try #require(
    controller.view.descendantViews.compactMap { $0 as? NSButton }.first {
      $0.toolTip == "立即发送此命令"
    }
  )
  let buttonCenter = button.convert(
    NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: controller.view)
  let hitView = controller.view.hitTest(buttonCenter)
  #expect(hitView === button || hitView?.isDescendant(of: button) == true)

  button.performClick(nil)

  // 不以 `onEncodedInput` 代替 PTY 验收：必须等真实子进程回显 marker，才能证明按钮
  // 的文本和 Return 穿过 AppKit/SwiftTerm 并抵达当前 CLI。
  try await Task.sleep(for: .milliseconds(500))

  #expect(model.promptQueueItems(for: paneID).isEmpty)
  #expect(String(decoding: encoded, as: UTF8.self).contains("__PROMPT_QUEUE_DELIVERED__"))
  // 文本编码跟随目标是否协商 bracketed paste，因此不锁定具体字节；Return 必须仍然
  // 单独抵达，marker 回显则证明整条命令确实进了当前 CLI 而不是被 TUI 逐键吃掉。
  #expect(encoded.contains(13))
  #expect(session.textSnapshot().lines.joined(separator: "\n").contains("__PROMPT_QUEUE_DELIVERED__"))
}

@Test("Prompt 队列条按设计稿呈现队列行与输入行控件")
@MainActor
func promptQueueBarMatchesDesignLayout() throws {
  let defaults = behaviorTestDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let paneID = try #require(model.selectedTab?.activePaneID)
  let session = try #require(model.selectedTab?.activeSession)
  defer { session.stop(immediately: true) }
  #expect(model.updatePromptQueueDraft("设计稿如图", paneID: paneID))
  #expect(model.enqueuePromptQueueDraft(paneID: paneID))

  let controller = WorkspaceViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()
  model.togglePromptQueue()
  controller.view.layoutSubtreeIfNeeded()

  // 设计稿的五个可点控件都必须有 toolTip：图标本身没有文字标签，缺一个用户就无从
  // 判断该图标是发送、移除还是展开。
  let buttons = controller.view.descendantViews.compactMap { $0 as? NSButton }
  let toolTips = Set(buttons.compactMap(\.toolTip))
  for expected in [
    "立即发送此命令", "从队列移除", "关闭 Prompt 队列输入条", "展开/收起多行输入", "加入队列（Return）",
  ] {
    #expect(toolTips.contains(expected))
  }

  // 队列行与输入行同为 44pt 卡片；行高一旦漂移，底部条会额外吃掉终端网格的行数。
  let sendButton = try #require(buttons.first { $0.toolTip == "立即发送此命令" })
  let itemCard = try #require(sendButton.superview?.superview)
  #expect(itemCard.frame.height == 44)
  let enqueueButton = try #require(buttons.first { $0.toolTip == "加入队列（Return）" })
  let inputCard = try #require(enqueueButton.superview?.superview)
  #expect(inputCard.frame.height == 44)
}

@Test("Agent 状态变化不重建工作区，Files 保留当前目录")
@MainActor
func agentTaskStateChangeDoesNotRebuildWorkspaceLayout() async throws {
  let defaults = behaviorTestDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let session = try #require(model.selectedTab?.activeSession)
  let terminal = try #require(session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }

  // 先建立同一 Codex 会话的 idle 基线；后续 processing 是队列发送后真实会收到的 hook 状态。
  terminal.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .idle))
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()
  try await Task.sleep(for: .milliseconds(40))
  let originalLayout = try #require(controller.view.subviews.first)

  terminal.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .processing))
  try await Task.sleep(for: .milliseconds(40))

  #expect(controller.view.subviews.contains { $0 === originalLayout })
}

@Test("启用的 Agent 出现在命令面板且自定义前缀用于会话续接")
@MainActor
func appModelPublishesEnabledAgentLaunchCommands() throws {
  let model = AppModel(defaults: behaviorTestDefaults())
  model.enabledAgentProviders = [.codex, .claudeCode]
  model.agentLaunchCommands = [AgentProvider.codex.rawValue: ["env", "PROFILE=work", "codex"]]

  #expect(model.paletteCommands.contains { $0.id == "launch-agent:codex" })
  #expect(model.paletteCommands.contains { $0.id == "launch-agent:claudeCode" })
  #expect(!model.paletteCommands.contains { $0.id == "launch-agent:openCode" })
}

@Test("附加窗口恢复注册表只接受有界去重的 Aster UUID suite")
func additionalWindowRegistryRejectsForgedAndUnboundedDomains() {
  let valid = (0..<(AdditionalWorkspaceWindowRegistry.maximumWindows + 4)).map {
    _ in AdditionalWorkspaceWindowRegistry.prefix + UUID().uuidString
  }
  let result = AdditionalWorkspaceWindowRegistry.normalized(
    ["com.example.foreign", AdditionalWorkspaceWindowRegistry.prefix + "not-a-uuid"]
      + valid + [valid[0]]
  )

  #expect(result == Array(valid.prefix(AdditionalWorkspaceWindowRegistry.maximumWindows)))
}

@Test("跨窗口标签转移保持同一运行对象并让源工作区保持非空")
@MainActor
func appModelTransfersTabsWithoutRecreatingRuntime() throws {
  let source = AppModel(defaults: behaviorTestDefaults())
  let destination = AppModel(defaults: behaviorTestDefaults())
  source.ensureInitialTab()
  destination.ensureInitialTab()
  let tab = try #require(source.selectedTab)
  let runtime = try #require(tab.activeRuntime)

  let transferred = try #require(source.detachTabForTransfer(id: tab.id))
  destination.receiveTransferredTab(transferred)

  #expect(transferred === tab)
  #expect(destination.selectedTab === tab)
  #expect(destination.selectedTab?.activeRuntime === runtime)
  #expect(source.tabs.count == 1)
  #expect(source.tabs[0] !== tab)
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

@Test("Recipe 分屏从创建时就使用声明的工作目录")
@MainActor
func terminalTabSplitUsesRequestedWorkingDirectory() {
  let tab = TerminalTabItem(title: "Recipe", workingDirectory: "/tmp/first")

  tab.split(direction: .right, workingDirectory: "/tmp/second")

  let descriptor = tab.runtime(for: tab.activePaneID)?.descriptor
  #expect(descriptor?.workingDirectory == "/tmp/second")
  #expect(tab.layout.allPanes.last?.workingDirectory == "/tmp/second")
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

@Test("Prompt 队列条占据 Pane 底部空间且不覆盖终端内容")
@MainActor
func promptQueueBarReservesSpaceInsteadOfCoveringTerminal() throws {
  let defaults = behaviorTestDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let paneID = try #require(model.selectedTab?.activePaneID)
  let session = try #require(model.selectedTab?.activeSession)
  defer { session.stop(immediately: true) }
  #expect(model.updatePromptQueueDraft("等待中的一条", paneID: paneID))
  #expect(model.enqueuePromptQueueDraft(paneID: paneID))

  let controller = WorkspaceViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()
  controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
  model.togglePromptQueue()
  controller.view.layoutSubtreeIfNeeded()

  let host = try #require(
    controller.view.descendantViews.compactMap { $0 as? ActivePaneHostView }
      .first { $0.paneID == paneID }
  )
  let bar = try #require(
    controller.view.descendantViews.compactMap { $0 as? PromptQueueBarView }.first)
  let barFrameInHost = bar.convert(bar.bounds, to: host)
  // Pane 主体必须整体位于队列条上方：覆盖式布局会挡住最后几行输出，用户恰好看不到
  // 刚发出去那条命令的结果。
  let content = try #require(host.subviews.first { $0 !== bar && !($0 is PromptQueueBarView) })
  #expect(content.frame.minY >= barFrameInHost.maxY)
  #expect(barFrameInHost.maxY < host.bounds.maxY)
  // 队列行与输入行同宽是设计稿要求，两者都由队列条统一撑满可用宽度。
  let cards = bar.descendantViews.filter { $0.className.contains("PromptQueueItemView") }
  for card in cards {
    #expect(abs(card.frame.width - bar.bounds.width) < 1)
  }
}

@Test("Prompt 队列输入框展开按钮会真正放大输入区")
@MainActor
func promptQueueExpandButtonGrowsTheInputCard() throws {
  let defaults = behaviorTestDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let session = try #require(model.selectedTab?.activeSession)
  defer { session.stop(immediately: true) }

  let controller = WorkspaceViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()
  controller.view.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
  model.togglePromptQueue()
  controller.view.layoutSubtreeIfNeeded()

  let bar = try #require(
    controller.view.descendantViews.compactMap { $0 as? PromptQueueBarView }.first)
  let expand = try #require(
    controller.view.descendantViews.compactMap { $0 as? NSButton }
      .first { $0.toolTip == "展开/收起多行输入" }
  )
  let collapsedHeight = bar.frame.height

  expand.performClick(nil)
  controller.view.layoutSubtreeIfNeeded()
  #expect(bar.frame.height > collapsedHeight)

  expand.performClick(nil)
  controller.view.layoutSubtreeIfNeeded()
  #expect(abs(bar.frame.height - collapsedHeight) < 1)
}
