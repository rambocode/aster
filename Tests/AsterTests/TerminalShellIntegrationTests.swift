import AppKit
import AsterCore
import Testing

@testable import Aster
@testable import SwiftTerm

@Test("终端视图把 OSC 133 标记组成命令记录并发布运行状态")
@MainActor
func terminalViewTracksShellIntegrationMarkers() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 20, rows: 4)
  var snapshots: [ShellCommandTimeline] = []
  view.onShellIntegrationStateChange = { snapshots.append($0) }
  view.installShellIntegrationHandler()

  let output =
    "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}echo one\r\n"
    + "\u{1B}]133;C\u{7}one\r\n\u{1B}]133;D;0\u{7}"
  view.dataReceived(slice: Array(output.utf8)[...])

  #expect(view.shellCommandTimeline.integrationDetected)
  #expect(view.shellCommandTimeline.marks.count == 1)
  #expect(view.shellCommandTimeline.marks[0].exitStatus == 0)
  #expect(view.shellCommandTimeline.marks[0].promptStart.column == 0)
  #expect(view.shellCommandTimeline.marks[0].inputStart.column == 2)
  #expect(snapshots.contains { $0.isCommandRunning })
  #expect(snapshots.last?.isCommandRunning == false)
}

@Test("非法 OSC 133 payload 不改变命令时间线")
@MainActor
func terminalViewRejectsMalformedShellMarkers() {
  let view = AsterTerminalView(frame: .zero)
  view.installShellIntegrationHandler()

  view.dataReceived(slice: Array("\u{1B}]133;C;token=secret\u{7}".utf8)[...])

  #expect(!view.shellCommandTimeline.integrationDetected)
  #expect(view.shellCommandTimeline.marks.isEmpty)
}

@Test("命令导航按 OSC 133 提示符锚点向前和向后滚动")
@MainActor
func terminalViewNavigatesCommandMarks() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 20, rows: 3)
  view.installShellIntegrationHandler()
  for index in 0..<4 {
    let output =
      "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}echo \(index)\r\n"
      + "\u{1B}]133;C\u{7}\(index)\r\nextra\r\n\u{1B}]133;D;0\u{7}"
    view.dataReceived(slice: Array(output.utf8)[...])
  }
  let bottom = view.getTerminal().buffer.yDisp

  view.scrollToPreviousCommand(nil)
  let latest = view.getTerminal().buffer.yDisp
  view.scrollToPreviousCommand(nil)
  let previous = view.getTerminal().buffer.yDisp
  view.scrollToNextCommand(nil)
  let forward = view.getTerminal().buffer.yDisp

  #expect(latest <= bottom)
  #expect(previous < latest)
  #expect(forward == latest)
}

@Test("当前提示符内的 ASCII 选区可转换为光标移动和退格")
@MainActor
func terminalViewDeletesSafePromptSelection() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 20, rows: 3)
  view.installShellIntegrationHandler()
  view.dataReceived(slice: Array("\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}abcdef".utf8)[...])
  view.setSelection(
    start: Position(col: 3, row: 0),
    end: Position(col: 6, row: 0)
  )
  var sent: [UInt8] = []
  view.onEncodedInput = { sent.append(contentsOf: $0) }

  let deleted = view.deletePromptSelectionIfSafe()

  #expect(deleted)
  #expect(String(decoding: sent.prefix(4), as: UTF8.self) == "\u{1B}[2D")
  #expect(Array(sent.suffix(3)) == [127, 127, 127])
  #expect(!view.selectionActive)
}

@Test("提示符外、命令运行中和非 ASCII 选区保持无损")
@MainActor
func terminalViewPreservesUnsafePromptSelections() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 20, rows: 3)
  view.installShellIntegrationHandler()
  view.dataReceived(slice: Array("\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}abc".utf8)[...])
  view.setSelection(start: Position(col: 0, row: 0), end: Position(col: 2, row: 0))
  var sent: [UInt8] = []
  view.onEncodedInput = { sent.append(contentsOf: $0) }

  #expect(!view.deletePromptSelectionIfSafe())
  #expect(sent.isEmpty)
  #expect(view.selectionActive)

  view.dataReceived(slice: Array("\u{1B}]133;C\u{7}".utf8)[...])
  view.setSelection(start: Position(col: 3, row: 0), end: Position(col: 5, row: 0))
  #expect(!view.deletePromptSelectionIfSafe())
  #expect(sent.isEmpty)
}

@Test("Backspace 键优先删除当前提示符内的安全选区")
@MainActor
func backspaceDeletesSafePromptSelection() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 20, rows: 3)
  view.installShellIntegrationHandler()
  view.dataReceived(slice: Array("\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}abcdef".utf8)[...])
  view.setSelection(start: Position(col: 3, row: 0), end: Position(col: 6, row: 0))
  var sent: [UInt8] = []
  view.onEncodedInput = { sent.append(contentsOf: $0) }
  let event = try #require(
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "\u{7F}",
      charactersIgnoringModifiers: "\u{7F}",
      isARepeat: false,
      keyCode: 51
    )
  )

  view.keyDown(with: event)

  #expect(String(decoding: sent.prefix(4), as: UTF8.self) == "\u{1B}[2D")
  #expect(Array(sent.suffix(3)) == [127, 127, 127])
  #expect(!view.selectionActive)
}
