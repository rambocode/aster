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

@Test("终端视图接收有界 Alias 名称报告")
@MainActor
func terminalViewReceivesShellAliases() {
  let view = AsterTerminalView(frame: .zero)
  var reports: [[String]] = []
  view.onShellAliases = { reports.append($0) }
  view.installShellIntegrationHandler()

  view.dataReceived(slice: Array("\u{1B}]6973;Aliases=gs,gco\u{7}".utf8)[...])
  view.dataReceived(slice: Array("\u{1B}]6973;Aliases=bad name\u{7}".utf8)[...])

  #expect(reports == [["gco", "gs"]])
}

@Test("终端视图观察进度和三类通知且不覆盖 SwiftTerm 进度处理")
@MainActor
func terminalViewObservesProgressAndNotifications() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  var progress: [TerminalProgressState] = []
  var notifications: [TerminalNotification] = []
  var responses: [String] = []
  var badgeDirectives: [TerminalBadgeDirective] = []
  var visibleCursorLines: [String] = []
  view.onTerminalProgress = { progress.append($0) }
  view.onTerminalNotification = { notifications.append($0) }
  view.onTerminalProtocolResponse = { responses.append($0) }
  view.onTerminalBadgeDirective = { badgeDirectives.append($0) }
  view.onTerminalOutputActivity = { visibleCursorLines.append($0) }
  view.installActivityHandlers()

  let encodedBody = Data("Body".utf8).base64EncodedString()
  let output =
    "\u{1B}]9;4;1;35\u{7}"
    + "\u{1B}]9;Build done\u{7}"
    + "\u{1B}]777;notify;Deploy;Live\u{7}"
    + "\u{1B}]99;i=k:p=body:e=1;\(encodedBody)\u{1B}\\"
    + "\u{1B}]99;i=ping:p=?;\u{1B}\\"
    + "Password:\u{1B}]6974;Badge=awaiting-input\u{7}"
    + "\u{1B}]9;4;4;50\u{7}"
    + "\u{1B}]9;4;5;0;watch\u{7}"
  view.dataReceived(slice: Array(output.utf8)[...])

  #expect(progress == [.determinate(percent: 35), .finished(exitCode: 0, watched: true)])
  #expect(notifications.count == 3)
  #expect(notifications[0].body == "Build done")
  #expect(notifications[1].title == "Deploy")
  #expect(notifications[2].body == "Body")
  #expect(responses == ["\u{1B}]99;i=ping:p=?;ok\u{1B}\\"])
  #expect(badgeDirectives == [.set(.awaitingInput)])
  #expect(visibleCursorLines.last == "Password:")
  #expect(view.getTerminal().ignoresPausedProgressReports)
}

@Test("终端铃声严格服从 Shell Controlled 开关")
@MainActor
func terminalViewBellHonorsConfiguration() {
  let view = AsterTerminalView(frame: .zero)
  var bells = 0
  view.terminalBellHandler = { bells += 1 }

  view.terminalBellEnabled = false
  view.dataReceived(slice: [7][...])
  #expect(bells == 0)

  view.terminalBellEnabled = true
  view.dataReceived(slice: [7][...])
  #expect(bells == 1)
}

@Test("标题 Shell Controlled 关闭后丢弃 OSC 0/1/2 副作用")
@MainActor
func terminalViewTitleChangesRequirePrivilege() {
  let view = AsterTerminalView(frame: .zero)
  var updates: [(Int, String)] = []
  view.onObservedTitleUpdate = { updates.append(($0, $1)) }
  view.installTitleHandlers()

  view.titleShellControlled = false
  view.dataReceived(slice: Array("\u{1B}]2;blocked\u{7}".utf8)[...])
  #expect(updates.isEmpty)

  view.titleShellControlled = true
  view.dataReceived(slice: Array("\u{1B}]2;allowed\u{7}".utf8)[...])
  #expect(updates.count == 1)
  #expect(updates[0].0 == 2)
  #expect(updates[0].1 == "allowed")
}

@Test("可见目标枚举同时返回隐式路径与 OSC 8 来源")
@MainActor
func terminalEnumeratesVisibleHintTargets() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 80, rows: 4)
  let output =
    "README.md:12\r\n"
    + "\u{1B}]8;;https://example.test/docs\u{7}open docs\u{1B}]8;;\u{7}\r\n"
  view.dataReceived(slice: Array(output.utf8)[...])

  let links = view.getTerminal().visibleLinks()
  #expect(links.contains { $0.text == "README.md:12" && !$0.isExplicit })
  #expect(links.contains { $0.text == "https://example.test/docs" && $0.isExplicit })
  #expect(Set(links.map { "\($0.bufferRow):\($0.range.lowerBound):\($0.text)" }).count == links.count)
}

@Test("跨软换行的 OSC 8 链接只生成一个可见 Hint 目标")
@MainActor
func terminalDeduplicatesWrappedOSC8HintTargets() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 320, height: 160))
  view.resize(cols: 5, rows: 4)
  let url = "https://example.test/wrapped"
  let output = "\u{1B}]8;;\(url)\u{7}abcdefgh\u{1B}]8;;\u{7}"
  view.dataReceived(slice: Array(output.utf8)[...])

  let matches = view.getTerminal().visibleLinks().filter { $0.text == url }
  #expect(matches.count == 1)
  #expect(matches.first?.isExplicit == true)
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
