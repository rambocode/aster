import AppKit
import AsterCore
import SwiftTerm
import Testing

@testable import Aster

@Test("Read-only 拦截所有用户发送但保留终端协议响应")
@MainActor
func readOnlyGatesUserInputWithoutBlockingProtocolResponses() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  var userBytes: [[UInt8]] = []
  var protocolBytes: [[UInt8]] = []
  var rejected = 0
  view.onEncodedInput = { userBytes.append(Array($0)) }
  view.onTerminalProtocolOutput = { protocolBytes.append(Array($0)) }
  view.onInputRejected = { rejected += 1 }
  var confirmationCount = 0
  view.onConfirmPaste = { _ in confirmationCount += 1; return true }

  view.toggleReadOnly(nil)
  #expect(view.isReadOnly)
  view.send(data: Array("blocked".utf8)[...])
  view.send(source: view.getTerminal(), data: Array("response".utf8)[...])

  #expect(userBytes.isEmpty)
  #expect(rejected == 1)
  #expect(protocolBytes == [Array("response".utf8)])
  #expect(!view.pasteText("first\nsecond"))
  #expect(confirmationCount == 0)
  #expect(rejected == 2)

  view.toggleReadOnly(nil)
  view.send(data: Array("allowed".utf8)[...])
  #expect(userBytes == [Array("allowed".utf8)])
}

@Test("Read-only 仍允许选择和复制，并阻止编辑器运行态改写")
@MainActor
func readOnlyPreservesCopyAndLocksEditorInput() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 20, rows: 2)
  view.dataReceived(slice: Array("copy me".utf8)[...])
  view.setSelection(start: Position(col: 0, row: 0), end: Position(col: 7, row: 0))
  view.toggleReadOnly(nil)

  // 持续输出不得清除 Read-only 中用于复制的既有选区。
  view.dataReceived(slice: Array("\r\nmore output".utf8)[...])
  #expect(view.selectionActive)
  #expect(view.getSelection() == "copy me")

  NSPasteboard.general.clearContents()
  view.copy(view)
  #expect(NSPasteboard.general.string(forType: .string) == "copy me")

  let runtime = WorkspacePaneRuntime(
    descriptor: PaneDescriptor(kind: .editor, workingDirectory: "/tmp")
  )
  runtime.updateDocument("before")
  runtime.toggleReadOnly()
  runtime.updateDocument("blocked")
  #expect(runtime.isReadOnly)
  #expect(runtime.documentText == "before")
}

@Test("Read-only 在发送门禁前保留滚动位置与选区")
@MainActor
func readOnlyRejectsInputBeforeSwiftTermSideEffects() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 20, rows: 2)
  view.dataReceived(slice: Array("first\r\nsecond\r\nthird".utf8)[...])
  view.scroll(toPosition: 0)
  view.setSelection(start: Position(col: 0, row: 0), end: Position(col: 5, row: 0))
  let viewport = view.getTerminal().buffer.yDisp
  let selection = view.getSelection()
  view.toggleReadOnly(nil)

  view.send(data: Array("blocked".utf8)[...])

  #expect(view.getTerminal().buffer.yDisp == viewport)
  #expect(view.selectionActive)
  #expect(view.getSelection() == selection)
}

@Test("Read-only 把 TUI 鼠标手势留在本地选择而不发送报告")
@MainActor
func readOnlySuppressesTerminalMouseReports() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 20, rows: 2)
  view.dataReceived(slice: Array("select locally".utf8)[...])
  view.dataReceived(slice: Array("\u{1B}[?1000h".utf8)[...])
  view.allowMouseReporting = true
  var userBytes: [UInt8] = []
  view.onEncodedInput = { userBytes.append(contentsOf: $0) }
  view.toggleReadOnly(nil)

  view.mouseDown(with: try mouseEvent(.leftMouseDown, at: NSPoint(x: 2, y: 2)))
  view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: 80, y: 20)))
  view.mouseUp(with: try mouseEvent(.leftMouseUp, at: NSPoint(x: 80, y: 20)))

  #expect(userBytes.isEmpty)
  #expect(view.selectionActive)
}

@Test("Codex 输入框保留常用 Control 行编辑按键")
@MainActor
func codexInputPreservesCommonControlEditingKeys() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  var encoded: [UInt8] = []
  view.onEncodedInput = { encoded.append(contentsOf: $0) }
  let keys: [(characters: String, ignoring: String, keyCode: UInt16)] = [
    ("\u{01}", "a", 0),
    ("\u{05}", "e", 14),
    ("\u{0B}", "k", 40),
    ("\u{15}", "u", 32),
    ("\u{17}", "w", 13),
  ]

  for key in keys {
    view.keyDown(with: try keyEvent(
      key.characters,
      ignoringModifiers: key.ignoring,
      modifiers: [.control],
      keyCode: key.keyCode
    ))
  }

  #expect(encoded == [0x01, 0x05, 0x0B, 0x15, 0x17])
}

@Test("Vi Mode 消费按键、支持计数移动并且不写入 PTY")
@MainActor
func viModeRoutesKeysLocally() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 20, rows: 4)
  view.dataReceived(slice: Array("alpha beta\r\nsecond".utf8)[...])
  var userBytes: [[UInt8]] = []
  view.onEncodedInput = { userBytes.append(Array($0)) }

  view.enterViMode(nil)
  #expect(view.navigationMode == .vi(.vi))
  let initial = try #require(view.viCursor)
  view.keyDown(with: try keyEvent("3"))
  view.keyDown(with: try keyEvent("h"))
  #expect(view.viCursor?.column == max(0, initial.column - 3))
  #expect(userBytes.isEmpty)

  view.keyDown(with: try keyEvent("q"))
  #expect(view.navigationMode == .normal)
}

@Test("Vi Mode 检查滚动历史时新输出不会抢走当前视口")
@MainActor
func viModeFreezesViewportUntilExit() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 20, rows: 2)
  view.dataReceived(slice: Array("one\r\ntwo\r\nthree".utf8)[...])
  let initialViewport = view.getTerminal().buffer.yDisp

  view.enterViMode(nil)
  view.dataReceived(slice: Array("\r\nfour".utf8)[...])
  #expect(view.getTerminal().buffer.yDisp == initialViewport)

  view.keyDown(with: try keyEvent("q"))
  view.dataReceived(slice: Array("\r\nfive".utf8)[...])
  #expect(view.getTerminal().buffer.yDisp > initialViewport)
}

@Test("Hint Mode 打开目标并用 Shift 最终键复制规范化值")
@MainActor
func hintModeOpensAndCopiesVisibleTargets() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 80, rows: 4)
  view.dataReceived(slice: Array("README.md:12\r\n".utf8)[...])
  var opened: [(String, DetectedTargetSource)] = []
  view.onRequestOpenTarget = { opened.append(($0, $1)) }
  view.onResolveHintCopyTarget = { _, _ in "/tmp/project/README.md" }

  view.openHintMode(nil)
  #expect(view.navigationMode == .hint)
  #expect(view.hintTargetCount == 1)
  view.keyDown(with: try keyEvent("a"))
  #expect(opened.count == 1)
  #expect(opened[0].0 == "README.md:12")
  #expect(opened[0].1 == .plainText)

  NSPasteboard.general.clearContents()
  view.openHintMode(nil)
  view.keyDown(with: try keyEvent("A", ignoringModifiers: "a", modifiers: [.shift]))
  #expect(NSPasteboard.general.string(forType: .string) == "/tmp/project/README.md")
  #expect(opened.count == 1)
  #expect(view.navigationMode == .normal)
}

@Test("Hint Mode 在终端重排后取消过期目标")
@MainActor
func hintModeExitsWhenTerminalResizes() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 80, rows: 4)
  view.dataReceived(slice: Array("README.md:12".utf8)[...])
  view.openHintMode(nil)
  #expect(view.navigationMode == .hint)

  view.resize(cols: 40, rows: 4)

  #expect(view.navigationMode == .normal)
  #expect(view.hintTargetCount == 0)
}

@MainActor
private func keyEvent(
  _ characters: String,
  ignoringModifiers: String? = nil,
  modifiers: NSEvent.ModifierFlags = [],
  keyCode: UInt16 = 0
) throws -> NSEvent {
  try #require(
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: ignoringModifiers ?? characters,
      isARepeat: false,
      keyCode: keyCode
    ))
}

@MainActor
private func mouseEvent(_ type: NSEvent.EventType, at point: NSPoint) throws -> NSEvent {
  try #require(
    NSEvent.mouseEvent(
      with: type,
      location: point,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ))
}

@Test("Shell 菜单公开 Pane 与 Agent 动作并保留 Vi 默认快捷键")
@MainActor
func shellMenuPublishesPaneModeActions() throws {
  let menu = try #require(AsterAppDelegate().shellModeMenuItem().submenu)
  // 「把终端选区发送到 Chat」在 50c6f90 移入终端右键菜单,不再出现在 Shell 菜单。
  // 顶部标签命名/清屏/工作目录动作与底部 Git、通知与权限对齐 Otty 的 Shell 菜单。
  #expect(
    menu.items.filter { !$0.isSeparatorItem }.map(\.title) == [
      "重命名标签页…", "设置标签页前缀…", "清屏",
      "拷贝路径", "在访达中显示", "打开方式",
      "Vi Mode", "Mark Mode", "打开链接（Hint Mode）",
      "只读模式", "Composer", "Agent 历史",
      "Git", "通知与权限…", "显示/隐藏 Vi 按键提示",
    ])
  let vi = try #require(menu.item(withTitle: "Vi Mode"))
  #expect(vi.keyEquivalent == " ")
  #expect(vi.keyEquivalentModifierMask == [.control, .shift])
  let hints = try #require(menu.item(withTitle: "显示/隐藏 Vi 按键提示"))
  #expect(hints.keyEquivalent == "/")
  #expect(hints.keyEquivalentModifierMask == [.command])
}

@Test("Shell 菜单按聚焦 Pane 动态显示对应 Agent 会话动作")
@MainActor
func shellMenuFollowsFocusedPaneAgentSession() throws {
  let suiteName = "ShellAgentMenuTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  let delegate = AsterAppDelegate(model: model, preferences: preferences)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  defer { tab.stop(immediately: true) }

  let codexPaneID = tab.activePaneID
  let codexSession = try #require(tab.activeSession)
  let codexView = try #require(
    codexSession.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  codexView.onAgentTerminalDirective?(
    AgentTerminalDirective(
      provider: .codex,
      signal: .processing,
      sessionID: "codex-session"
    )
  )

  tab.split(direction: .right)
  let claudePaneID = tab.activePaneID
  let claudeSession = try #require(tab.activeSession)
  let claudeView = try #require(
    claudeSession.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  claudeView.onAgentTerminalDirective?(
    AgentTerminalDirective(
      provider: .claudeCode,
      signal: .awaitingInput,
      sessionID: "claude-session"
    )
  )

  let menu = try #require(delegate.shellModeMenuItem().submenu)
  delegate.menuNeedsUpdate(menu)
  #expect(menu.item(withTitle: "Claude") != nil)
  #expect(menu.item(withTitle: "Codex") == nil)
  let claudeMenu = try #require(menu.item(withTitle: "Claude")?.submenu)
  #expect(
    claudeMenu.items.filter { !$0.isSeparatorItem }.map(\.title) == [
      "拷贝会话 ID", "查看会话历史",
      "Fork 到 向右拆分", "Fork 到 向左拆分",
      "Fork 到 向下拆分", "Fork 到 向上拆分",
      "Fork 到 新建标签页", "Fork 到 新建窗口",
    ]
  )
  #expect(claudeMenu.items.filter { !$0.isSeparatorItem }.allSatisfy { $0.isEnabled })

  tab.setActivePane(codexPaneID)
  delegate.menuNeedsUpdate(menu)
  let codexMenu = try #require(menu.item(withTitle: "Codex")?.submenu)
  #expect(menu.item(withTitle: "Claude") == nil)

  // 菜单展开后即使焦点被程序化切换，已显示条目也必须继续操作捕获的 Codex 会话。
  tab.setActivePane(claudePaneID)
  NSPasteboard.general.clearContents()
  codexMenu.performActionForItem(
    at: try #require(codexMenu.items.firstIndex { $0.title == "拷贝会话 ID" }))
  #expect(NSPasteboard.general.string(forType: .string) == "codex-session")

  tab.setActivePane(codexPaneID)
  let paneCount = tab.layout.allPanes.count
  codexMenu.performActionForItem(
    at: try #require(codexMenu.items.firstIndex { $0.title == "Fork 到 向下拆分" }))
  #expect(tab.layout.allPanes.count == paneCount + 1)
  let plainPaneID = tab.activePaneID
  #expect(plainPaneID != codexPaneID)
  #expect(plainPaneID != claudePaneID)
  delegate.menuNeedsUpdate(menu)
  #expect(menu.item(withTitle: "Codex") == nil)
  #expect(menu.item(withTitle: "Claude") == nil)
}

@Test("Agent Fork 菜单始终操作展开菜单时捕获的工作区")
@MainActor
func shellAgentForkRoutesToCapturedWorkspace() throws {
  let sourceSuiteName = "ShellAgentMenuSourceTests.\(UUID().uuidString)"
  let sourceDefaults = try #require(UserDefaults(suiteName: sourceSuiteName))
  sourceDefaults.removePersistentDomain(forName: sourceSuiteName)
  defer { sourceDefaults.removePersistentDomain(forName: sourceSuiteName) }
  let sourceModel = AppModel(defaults: sourceDefaults)
  sourceModel.ensureInitialTab()
  let sourceTab = try #require(sourceModel.selectedTab)
  defer { sourceModel.tabs.forEach { $0.stop(immediately: true) } }

  let otherSuiteName = "ShellAgentMenuOtherTests.\(UUID().uuidString)"
  let otherDefaults = try #require(UserDefaults(suiteName: otherSuiteName))
  otherDefaults.removePersistentDomain(forName: otherSuiteName)
  defer { otherDefaults.removePersistentDomain(forName: otherSuiteName) }
  let otherPreferences = AppPreferences(defaults: otherDefaults)
  let otherModel = AppModel(defaults: otherDefaults)
  otherModel.ensureInitialTab()
  let otherTab = try #require(otherModel.selectedTab)
  defer { otherModel.tabs.forEach { $0.stop(immediately: true) } }
  let delegate = AsterAppDelegate(model: otherModel, preferences: otherPreferences)

  // AppKit 在菜单跟踪期间可能把 key window 切给设置页或另一个工作区。这里让 delegate
  // 的当前模型保持为 B，但让菜单明确来自 A，验证动作不在点击瞬间重新解析全局状态。
  let context = FocusedAgentSessionContext(
    provider: .codex,
    sessionID: "captured-codex-session",
    workingDirectory: "/tmp/captured-agent-project",
    configuration: .init(provider: .codex)
  )
  let codexItem = delegate.activeAgentMenuItem(context, workspaceModel: sourceModel)
  let codexMenu = try #require(codexItem.submenu)

  let sourcePaneCount = sourceTab.layout.allPanes.count
  let otherPaneCount = otherTab.layout.allPanes.count
  let forkIndex = try #require(
    codexMenu.items.firstIndex { $0.title == "Fork 到 向下拆分" }
  )
  let forkItem = codexMenu.items[forkIndex]
  let actionContext = try #require(forkItem.representedObject as? AgentMenuActionContext)
  #expect(actionContext.workspaceModel === sourceModel)
  #expect(forkItem.target === delegate)
  let action = try #require(forkItem.action)
  #expect(NSApplication.shared.sendAction(action, to: forkItem.target, from: forkItem))

  #expect(sourceTab.layout.allPanes.count == sourcePaneCount + 1)
  #expect(otherTab.layout.allPanes.count == otherPaneCount)

  let sourceTabCount = sourceModel.tabs.count
  let otherTabCount = otherModel.tabs.count
  let newTabItem = try #require(codexMenu.item(withTitle: "Fork 到 新建标签页"))
  let newTabAction = try #require(newTabItem.action)
  #expect(NSApplication.shared.sendAction(newTabAction, to: newTabItem.target, from: newTabItem))
  #expect(sourceModel.tabs.count == sourceTabCount + 1)
  #expect(otherModel.tabs.count == otherTabCount)
}

@Test("Agent 尚未报告会话 ID 时 Shell 菜单保留身份并禁用危险动作")
@MainActor
func shellAgentMenuDisablesSessionActionsUntilLifecycleLinksSession() throws {
  let suiteName = "ShellAgentMenuPendingTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  let delegate = AsterAppDelegate(model: model, preferences: preferences)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  defer { tab.stop(immediately: true) }
  let session = try #require(tab.activeSession)
  let view = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  view.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .processing)
  )

  let menu = try #require(delegate.shellModeMenuItem().submenu)
  delegate.menuNeedsUpdate(menu)
  let agentMenu = try #require(menu.item(withTitle: "Codex")?.submenu)
  #expect(agentMenu.item(withTitle: "查看会话历史")?.isEnabled == true)
  #expect(agentMenu.item(withTitle: "拷贝会话 ID")?.isEnabled == false)
  #expect(agentMenu.item(withTitle: "Fork 到 新建窗口")?.isEnabled == false)
}
