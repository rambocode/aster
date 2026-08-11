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
  #expect(
    menu.items.filter { !$0.isSeparatorItem }.map(\.title) == [
      "Vi Mode", "Mark Mode", "打开链接（Hint Mode）",
      "Composer", "Agent 历史",
      "只读模式", "显示/隐藏 Vi 按键提示",
    ])
  let vi = try #require(menu.item(withTitle: "Vi Mode"))
  #expect(vi.keyEquivalent == " ")
  #expect(vi.keyEquivalentModifierMask == [.control, .shift])
  let hints = try #require(menu.item(withTitle: "显示/隐藏 Vi 按键提示"))
  #expect(hints.keyEquivalent == "/")
  #expect(hints.keyEquivalentModifierMask == [.command])
}
