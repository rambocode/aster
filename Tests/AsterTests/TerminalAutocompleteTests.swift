import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("可靠 prompt 生成 inline 候选，Tab 只发送尚未输入的后缀")
@MainActor
func terminalAutocompleteAcceptsOnlyCandidateSuffix() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = TerminalAutocompleteController(
    service: fixture.service,
    sessionIdentifier: "session",
    controls: { fixture.controls.value },
    currentDirectory: { "/project" }
  )
  controller.attach(to: view)
  var sent: [UInt8] = []
  view.onEncodedInput = { sent.append(contentsOf: $0) }
  view.onAutocompleteInput = { controller.receiveInput($0) }
  view.onAutocompleteOutput = { controller.receiveOutput($0) }

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  // Tab 只接受可见 ghost；必须先让 PTY 回显本次输入，ghost 才会真正显示。
  view.dataReceived(slice: Array("git ch".utf8)[...])
  await Task.yield()

  #expect(controller.currentResult.candidates.prefix(2).map(\.insertText) == ["checkout", "cherry-pick"])
  #expect(controller.currentResult.ghostText == "eckout")
  #expect(controller.handle(.tab))
  #expect(String(decoding: sent, as: UTF8.self) == "eckout")
  #expect(controller.lastSubmittedCommand == nil)
}

@Test("Shell 端 autosuggestion 占据行尾时 Tab 放行给 Shell，不接受不可见候选")
@MainActor
func terminalAutocompleteRefusesInvisibleGhostWhenShellSuggestionOwnsLine() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = TerminalAutocompleteController(
    service: fixture.service,
    sessionIdentifier: "session",
    controls: { fixture.controls.value },
    currentDirectory: { "/project" }
  )
  controller.attach(to: view)
  var sent: [UInt8] = []
  view.onEncodedInput = { sent.append(contentsOf: $0) }
  view.onAutocompleteOutput = { controller.receiveOutput($0) }

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  // zsh-autosuggestions 等插件把自己的灰色建议画进网格，可见行不再以本地输入结尾，
  // 回显校验因此一直不通过，Aster ghost 保持隐藏。此时吞掉 Tab 会插入用户从未
  // 见过的候选文本；必须返回 false，让 Shell 自己的补全接管。
  view.dataReceived(slice: Array("git checkout -b feature".utf8)[...])
  await Task.yield()

  #expect(controller.currentResult.ghostText != nil)
  #expect(!controller.handle(.tab))
  #expect(sent.isEmpty)
}

@Test("Shell 尚未回显本次输入时不显示 inline suggestion")
@MainActor
func terminalAutocompleteWaitsForEchoBeforeShowingInlineSuggestion() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = TerminalAutocompleteController(
    service: fixture.service,
    sessionIdentifier: "session",
    controls: { fixture.controls.value },
    currentDirectory: { "/project" }
  )
  controller.attach(to: view)
  view.onAutocompleteOutput = { controller.receiveOutput($0) }

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()

  let overlay = try #require(
    view.subviews.first {
      String(describing: type(of: $0)).contains("TerminalAutocompleteOverlayView")
    }
  )
  let ghost = try #require(overlay.subviews.compactMap { $0 as? NSTextField }.first)
  // 本地 tracker 比 PTY 回显更早拿到输入。此窗口期若显示 ghost，它会锚定在旧光标上，
  // 与 Shell 随后绘制的 `git ch` 发生重叠。
  #expect(ghost.isHidden)

  // 终端可能在输入回显之前送达状态控制序列或其他输出；这不能被误判成当前输入
  // 已经出现在网格中，否则 ghost 会锚定旧光标并覆盖随后回显的字符。
  view.dataReceived(slice: Array("\u{1B}[?25l".utf8)[...])
  await Task.yield()

  #expect(ghost.isHidden)

  view.dataReceived(slice: Array("git ch".utf8)[...])
  await Task.yield()

  #expect(ghost.stringValue == "eckout")
  #expect(!ghost.isHidden)
  #expect(ghost.frame.minX >= view.caretFrame.maxX - 0.5)
}

@Test("后续输入会立即隐藏上一轮 inline suggestion")
@MainActor
func terminalAutocompleteHidesStaleGhostBeforeDebouncedRefresh() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = TerminalAutocompleteController(
    service: fixture.service,
    sessionIdentifier: "session",
    controls: { fixture.controls.value },
    currentDirectory: { "/project" }
  )
  controller.attach(to: view)
  view.onAutocompleteOutput = { controller.receiveOutput($0) }

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  view.dataReceived(slice: Array("git ch".utf8)[...])
  await Task.yield()

  let overlay = try #require(
    view.subviews.first {
      String(describing: type(of: $0)).contains("TerminalAutocompleteOverlayView")
    }
  )
  let ghost = try #require(overlay.subviews.compactMap { $0 as? NSTextField }.first)
  #expect(!ghost.isHidden)

  // 输入 tracker 会立刻收到下一个字符，而候选重算有 150ms debounce；旧后缀若继续
  // 留在屏幕上，就会与 Shell 随后的新回显重叠。
  controller.receiveInput(Array("e".utf8)[...])

  #expect(ghost.isHidden)
}

@Test("Escape 先关闭 inline suggestion，再按一次打开候选面板")
@MainActor
func terminalAutocompleteEscapeSeparatesInlineAndPanelActions() async throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let controller = TerminalAutocompleteController(
    service: fixture.service,
    sessionIdentifier: "session",
    controls: { fixture.controls.value },
    currentDirectory: { "/project" }
  )
  controller.attach(to: view)
  view.onAutocompleteOutput = { controller.receiveOutput($0) }

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  // 第一次 Escape 关闭的是“可见”的 inline suggestion；先回显输入让 ghost 显示。
  view.dataReceived(slice: Array("git ch".utf8)[...])
  await Task.yield()

  #expect(controller.handle(.escape))
  #expect(!controller.panelVisible)
  #expect(controller.handle(.escape))
  #expect(controller.panelVisible)
  #expect(controller.handle(.down))
  #expect(controller.selectedIndex == 1)
  #expect(controller.handle(.escape))
  #expect(!controller.panelVisible)
}

@Test("Shell 历史键使当前 prompt 不可靠并立即停用候选")
@MainActor
func terminalAutocompleteHidesAfterUnreconstructableInput() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let controller = TerminalAutocompleteController(
    service: fixture.service,
    sessionIdentifier: "session",
    controls: { fixture.controls.value },
    currentDirectory: { "/project" }
  )
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  #expect(!controller.currentResult.candidates.isEmpty)

  controller.receiveInput([0x1B, 0x5B, 0x41][...])
  controller.refreshNow()

  #expect(controller.currentResult.candidates.isEmpty)
  #expect(!controller.panelVisible)
}

@Test("光标不在行尾时隐藏补全并保留 Right Arrow 的 Shell 编辑语义")
@MainActor
func terminalAutocompleteHidesWhileEditingMiddleOfLine() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let controller = TerminalAutocompleteController(
    service: fixture.service,
    sessionIdentifier: "session",
    controls: { fixture.controls.value },
    currentDirectory: { "/project" }
  )
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()
  #expect(controller.currentResult.ghostText == "eckout")

  controller.receiveInput([0x1B, 0x5B, 0x44][...])
  controller.refreshNow()

  #expect(controller.currentResult.candidates.isEmpty)
  #expect(!controller.handle(.right))
}

@Test("OSC 133 命令生命周期把脱敏成功命令写入学习服务")
@MainActor
func terminalAutocompleteLearnsOnlyCompletedCommands() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let controller = TerminalAutocompleteController(
    service: fixture.service,
    sessionIdentifier: "session",
    controls: { fixture.controls.value },
    currentDirectory: { "/project" }
  )

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("curl --token private https://example.test\n".utf8)[...])
  controller.receive(.commandStart)
  controller.receiveOutput(Array("done\n".utf8)[...])
  controller.receive(.commandFinished(exitStatus: 0))
  controller.receive(.promptStart)
  controller.receive(.inputStart)
  // 空 prompt 不再产生候选，必须先敲一个前缀才能看到学习到的命令。
  controller.receiveInput(Array("curl".utf8)[...])
  controller.refreshNow()

  #expect(
    controller.currentResult.candidates.contains {
      $0.insertText == "curl https://example.test" && $0.kind == .learnedCommand
    }
  )
  #expect(!controller.currentResult.candidates.contains { $0.insertText.contains("private") })
}

@Test("Ghostty commandStart 先到时仍接收排队中的回车并发布完整命令")
@MainActor
func terminalAutocompleteAcceptsQueuedSubmitAfterCommandStart() throws {
  let fixture = try makeTerminalAutocompleteFixture()
  defer { try? FileManager.default.removeItem(at: fixture.directory) }
  let controller = TerminalAutocompleteController(
    service: fixture.service,
    sessionIdentifier: "session",
    controls: { fixture.controls.value },
    currentDirectory: { "/project" }
  )
  var submitted: [String] = []
  controller.onCommandSubmitted = { submitted.append($0) }

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("ssh root@ubuntu@orb".utf8)[...])
  // Ghostty 的 OSC observer 与 PTY write 原来走两条主线程队列；快速命令会让 C
  // marker 抢在最后一个回车 callback 前到达。
  controller.receive(.commandStart)
  controller.receiveInput([0x0D][...])

  #expect(submitted == ["ssh root@ubuntu@orb"])
  #expect(controller.lastSubmittedCommand == "ssh root@ubuntu@orb")
}

private final class MutableAutocompleteControls {
  var value = ControlConfiguration()
}

@MainActor
private func makeTerminalAutocompleteFixture() throws -> (
  directory: URL, service: AutocompleteService, controls: MutableAutocompleteControls
) {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-terminal-autocomplete-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
  let service = try AutocompleteService(
    baseDirectory: directory,
    bundledSpecURL: repositoryRoot.appendingPathComponent("Resources/autocomplete/fig-specs.json")
  )
  return (directory, service, MutableAutocompleteControls())
}
