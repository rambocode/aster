import AppKit
import AsterCore
import Testing

@testable import Aster

// 「收起实时画面」：隐藏 Ghostty surface 让 renderer 停止出帧，Pane 改显示静态状态卡。

/// 两个真实终端的分屏工作区，窗口上屏以便 surface 创建并得到真实的遮挡状态。
@MainActor
private func makeLiveViewFixture() throws -> (
  model: AppModel,
  preferences: AppPreferences,
  workspace: WorkspaceViewController,
  window: NSWindow,
  first: PaneDescriptor,
  second: PaneDescriptor
) {
  let suite = "AsterLiveViewCollapseTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  let first = PaneDescriptor(kind: .terminal, workingDirectory: home)
  let second = PaneDescriptor(kind: .terminal, workingDirectory: home)
  let layout = PaneLayout.split(
    axis: .horizontal, first: .leaf(first), second: .leaf(second), ratio: 0.5)
  let tab = WorkspaceTabSnapshot(id: UUID(), title: "LiveView", layout: layout)
  defaults.set(
    try JSONEncoder().encode(WorkspaceSnapshot(selectedTabID: tab.id, tabs: [tab])),
    forKey: "aster.workspace.snapshot.v1")

  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let workspace = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_100, height: 700),
    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
    backing: .buffered, defer: false)
  window.isReleasedWhenClosed = false
  window.contentViewController = workspace
  window.contentView?.layoutSubtreeIfNeeded()
  return (model, preferences, workspace, window, first, second)
}

/// 轮询等待条件成立；主队列的延后可见性确认与工作区重建都需要让出几轮。
@MainActor
private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

/// 按 identifier 前缀在视图树里找状态卡。
@MainActor
private func findCollapsedCard(in root: NSView) -> TerminalPaneCollapsedCardView? {
  if let card = root as? TerminalPaneCollapsedCardView { return card }
  for child in root.subviews {
    if let match = findCollapsedCard(in: child) { return match }
  }
  return nil
}

/// 构造发往指定窗口的按键事件。
@MainActor
private func keyDown(_ characters: String, keyCode: UInt16, in window: NSWindow) throws -> NSEvent {
  try #require(
    NSEvent.keyEvent(
      with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, characters: characters,
      charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode))
}

@Test("状态卡展示随 Agent 状态变化：等待输入醒目，其余平静，无 Agent 时显示 Pane 标题")
@MainActor
func terminalLiveViewCardPresentationFollowsAgentState() {
  let waiting = TerminalPaneCollapsedCardPresentation(
    provider: .claudeCode, taskState: .awaitingInput, completionUnread: false, terminalTitle: "✳ x")
  #expect(waiting.title == "Claude Code")
  #expect(waiting.status == L("等待你确认或输入"))
  #expect(waiting.emphasis == .attention)

  let processing = TerminalPaneCollapsedCardPresentation(
    provider: .codex, taskState: .processing, completionUnread: false, terminalTitle: "a")
  #expect(processing.title == "Codex")
  #expect(processing.status == L("处理中"))
  #expect(processing.emphasis == .calm)

  let finished = TerminalPaneCollapsedCardPresentation(
    provider: .codex, taskState: .idle, completionUnread: true, terminalTitle: "a")
  #expect(finished.status == L("已完成"))
  let idle = TerminalPaneCollapsedCardPresentation(
    provider: .codex, taskState: .idle, completionUnread: false, terminalTitle: "a")
  #expect(idle.status == L("空闲"))

  // Agent 运行时标题 spinner 变化不应改变展示，否则去重失效、卡片随标题反复重绘。
  let spinnerA = TerminalPaneCollapsedCardPresentation(
    provider: .claudeCode, taskState: .processing, completionUnread: false, terminalTitle: "✳ a")
  let spinnerB = TerminalPaneCollapsedCardPresentation(
    provider: .claudeCode, taskState: .processing, completionUnread: false, terminalTitle: "✶ a")
  #expect(spinnerA == spinnerB)

  let shell = TerminalPaneCollapsedCardPresentation(
    provider: nil, taskState: .idle, completionUnread: false, terminalTitle: "  vim notes.md ")
  #expect(shell.title == "vim notes.md")
  #expect(shell.emphasis == .calm)
  let untitled = TerminalPaneCollapsedCardPresentation(
    provider: nil, taskState: .idle, completionUnread: false, terminalTitle: "")
  #expect(untitled.title == L("终端"))
}

@Test("收起实时画面隐藏 surface 并上报不可见，恢复后立即可见，终端尺寸不变")
@MainActor
func terminalLiveViewCollapseHidesSurfaceAndRestores() async throws {
  let fixture = try makeLiveViewFixture()
  fixture.window.makeKeyAndOrderFront(nil)
  defer { fixture.window.orderOut(nil) }
  let tab = try #require(fixture.model.selectedTab)
  let session = try #require(tab.runtime(for: fixture.first.id)?.terminalSession)
  let other = try #require(tab.runtime(for: fixture.second.id)?.terminalSession)
  defer { session.stop(immediately: true); other.stop(immediately: true) }
  let surface = try liveGhosttyView(for: session, preferences: fixture.preferences)
  let host = session.makeTerminalHost(preferences: fixture.preferences)
  #expect(await waitUntil { surface.surface != nil })
  // 刚 orderFront 的窗口要等一轮遮挡通知才得到 `.visible`，太早取值会把可见窗口当成不可见。
  // 无显示会话（锁屏、息屏的测试机）时等满超时仍不可见，surface 本来就上报不可见；此时只能
  // 验证收起一侧的不变量，恢复一侧按真实窗口状态比较。
  let windowVisible = await waitUntil { fixture.window.occlusionState.contains(.visible) }
  #expect(await waitUntil { surface.reportedSurfaceVisible == windowVisible })
  let sizeBefore = surface.frame.size

  #expect(fixture.model.canToggleLiveView(paneID: fixture.first.id))
  fixture.model.toggleLiveView(paneID: fixture.first.id)
  #expect(session.isLiveViewCollapsed)
  #expect(surface.isHidden)
  #expect(!surface.isSurfaceVisibleToUser)
  #expect(findCollapsedCard(in: host) != nil)
  #expect(await waitUntil { surface.reportedSurfaceVisible == false })
  #expect(surface.frame.size == sizeBefore, "收起不能改变终端网格尺寸，否则程序会收到 SIGWINCH")
  // 只收起被操作的那个 Pane。
  #expect(!other.isLiveViewCollapsed)

  // 工作区整树刷新（切标签、主题变化等）不会自动恢复。
  fixture.model.objectWillChange.send()
  try await Task.sleep(for: .milliseconds(80))
  #expect(session.isLiveViewCollapsed)
  #expect(surface.isHidden)

  // 状态卡随 Agent 事件更新，不需要恢复实时画面。
  let card = try #require(findCollapsedCard(in: host))
  session.receiveAgentTerminalDirective(
    AgentTerminalDirective(provider: .claudeCode, signal: .processing, sessionID: "collapse-1"))
  #expect(card.presentation?.title == "Claude Code")
  #expect(card.presentation?.status == L("处理中"))
  session.receiveAgentTerminalDirective(
    AgentTerminalDirective(provider: .claudeCode, signal: .awaitingInput, sessionID: "collapse-1"))
  #expect(card.presentation?.status == L("等待你确认或输入"))
  #expect(card.presentation?.emphasis == .attention)
  #expect(session.isLiveViewCollapsed, "等待输入不能自动恢复实时画面")

  // 点击状态卡上的恢复按钮。
  card.restoreButton.performClick(nil)
  #expect(!session.isLiveViewCollapsed)
  #expect(!surface.isHidden)
  #expect(findCollapsedCard(in: host) == nil)
  #expect(surface.isSurfaceVisibleToUser == windowVisible)
  #expect(surface.reportedSurfaceVisible == windowVisible, "恢复可见必须同步上报，renderer 立即补画")
}

@Test("切换标题随状态翻转；画中画占用的 Pane 不能收起但已收起的总能恢复")
@MainActor
func terminalLiveViewToggleTitleAndPictureInPictureGate() async throws {
  #expect(TerminalLiveViewMenu.title(collapsed: false) == L("收起实时画面"))
  #expect(TerminalLiveViewMenu.title(collapsed: true) == L("恢复实时画面"))
  // 「显示」菜单提供同一命令，默认快捷键 ⇧⌘B。
  let display = try #require(AsterAppDelegate().workspaceMenuItem().submenu)
  let menuItem = try #require(display.item(withTitle: L("收起实时画面")))
  #expect(menuItem.keyEquivalent == "b")
  #expect(menuItem.keyEquivalentModifierMask == [.command, .shift])

  let fixture = try makeLiveViewFixture()
  fixture.window.makeKeyAndOrderFront(nil)
  defer { fixture.window.orderOut(nil) }
  let tab = try #require(fixture.model.selectedTab)
  let session = try #require(tab.runtime(for: fixture.first.id)?.terminalSession)
  let other = try #require(tab.runtime(for: fixture.second.id)?.terminalSession)
  defer { session.stop(immediately: true); other.stop(immediately: true) }
  let surface = try liveGhosttyView(for: session, preferences: fixture.preferences)
  #expect(await waitUntil { surface.surface != nil })
  tab.setActivePane(fixture.first.id)

  // 右键菜单条目按状态给出标题，可用时带动作。
  let item = TerminalLiveViewMenu.makeContextMenuItem(model: fixture.model, paneID: fixture.first.id)
  #expect(item.title == L("收起实时画面"))
  #expect(item.action != nil)

  // 系统画中画采集中：surface 必须持续出帧，收起被禁用。
  surface.pictureInPictureFrames.start()
  #expect(!session.canCollapseLiveView)
  #expect(!fixture.model.canToggleLiveView(paneID: fixture.first.id))
  #expect(TerminalLiveViewMenu.makeContextMenuItem(
    model: fixture.model, paneID: fixture.first.id).action == nil)
  fixture.model.toggleLiveView(paneID: fixture.first.id)
  #expect(!session.isLiveViewCollapsed)
  surface.pictureInPictureFrames.stop()

  // 可交互小窗借走的 Pane 同样不能收起。
  fixture.model.setFloatingPane(fixture.first.id)
  #expect(!fixture.model.canToggleActivePaneLiveView)
  fixture.model.toggleActivePaneLiveView()
  #expect(!session.isLiveViewCollapsed)
  fixture.model.setFloatingPane(nil)
  try await Task.sleep(for: .milliseconds(80))

  // 收起后标题翻转为「恢复」，且即使之后被判定为不可收起也能恢复。
  fixture.model.toggleActivePaneLiveView()
  #expect(fixture.model.activePaneLiveViewCollapsed)
  #expect(TerminalLiveViewMenu.makeContextMenuItem(
    model: fixture.model, paneID: fixture.first.id).title == L("恢复实时画面"))
  fixture.model.setFloatingPane(fixture.first.id)
  #expect(fixture.model.canToggleLiveView(paneID: fixture.first.id))
  fixture.model.setFloatingPane(nil)
  fixture.model.toggleActivePaneLiveView()
  #expect(!fixture.model.activePaneLiveViewCollapsed)

  // 命令面板走同一条路由。
  let command = try #require(fixture.model.paletteCommands.first { $0.id == "live-view" })
  fixture.model.performPaletteCommand(command)
  #expect(fixture.model.activePaneLiveViewCollapsed)
  fixture.model.performPaletteCommand(command)
  #expect(!fixture.model.activePaneLiveViewCollapsed)
}

@Test("收起后的 Pane 聚焦时按键落在状态卡上，不写入终端；Return 恢复并把焦点还给终端")
@MainActor
func terminalLiveViewCollapsedPaneSwallowsKeyInput() async throws {
  let fixture = try makeLiveViewFixture()
  fixture.window.makeKeyAndOrderFront(nil)
  defer { fixture.window.orderOut(nil) }
  let window = fixture.window
  let tab = try #require(fixture.model.selectedTab)
  let session = try #require(tab.runtime(for: fixture.first.id)?.terminalSession)
  let other = try #require(tab.runtime(for: fixture.second.id)?.terminalSession)
  defer { session.stop(immediately: true); other.stop(immediately: true) }
  let surface = try liveGhosttyView(for: session, preferences: fixture.preferences)
  let otherSurface = try liveGhosttyView(for: other, preferences: fixture.preferences)
  #expect(await waitUntil { surface.surface != nil && otherSurface.surface != nil })
  var written: [[UInt8]] = []
  var otherWritten: [[UInt8]] = []
  observeTestPTYWrites(surface) { written.append($0) }
  observeTestPTYWrites(otherSurface) { otherWritten.append($0) }

  tab.setActivePane(fixture.first.id)
  #expect(session.focus())
  #expect(window.firstResponder === surface)

  // 收起时焦点从终端移到本 Pane 的状态卡，而不是 AppKit 挑选的下一个 key view。
  #expect(session.setLiveViewCollapsed(true))
  let card = try #require(findCollapsedCard(in: session.makeTerminalHost(preferences: fixture.preferences)))
  #expect(window.firstResponder === card)
  // 隐藏的 surface 拒绝成为 first responder；Pane 聚焦同样落在卡片上。
  #expect(!surface.acceptsFirstResponder)
  _ = window.makeFirstResponder(surface)
  #expect(window.firstResponder !== surface)
  #expect(session.focus())
  #expect(window.firstResponder === card)

  window.sendEvent(try keyDown("a", keyCode: 0, in: window))
  window.sendEvent(try keyDown("\u{8}", keyCode: 51, in: window))
  try await Task.sleep(for: .milliseconds(50))
  #expect(written.isEmpty, "收起的终端不能收到任何按键")
  #expect(otherWritten.isEmpty, "按键也不能漏到相邻 Pane")
  #expect(session.isLiveViewCollapsed)

  window.sendEvent(try keyDown("\r", keyCode: 36, in: window))
  #expect(!session.isLiveViewCollapsed)
  #expect(!surface.isHidden)
  #expect(window.firstResponder === surface)
  #expect(written.isEmpty, "触发恢复的 Return 不能转发给终端")

  // 对照：恢复后同样的按键确实会写进终端，证明上面的「没有写入」不是观察失效。
  window.sendEvent(try keyDown("a", keyCode: 0, in: window))
  #expect(await waitUntil { !written.isEmpty })
}
