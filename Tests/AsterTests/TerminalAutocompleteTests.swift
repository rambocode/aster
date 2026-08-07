import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("可靠 prompt 生成 inline 候选，Tab 只发送尚未输入的后缀")
@MainActor
func terminalAutocompleteAcceptsOnlyCandidateSuffix() throws {
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

  controller.receive(.promptStart)
  controller.receive(.inputStart)
  controller.receiveInput(Array("git ch".utf8)[...])
  controller.refreshNow()

  #expect(controller.currentResult.candidates.prefix(2).map(\.insertText) == ["checkout", "cherry-pick"])
  #expect(controller.currentResult.ghostText == "eckout")
  #expect(controller.handle(.tab))
  #expect(String(decoding: sent, as: UTF8.self) == "eckout")
  #expect(controller.lastSubmittedCommand == nil)
}

@Test("Escape 先关闭 inline suggestion，再按一次打开候选面板")
@MainActor
func terminalAutocompleteEscapeSeparatesInlineAndPanelActions() throws {
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
  controller.refreshNow()

  #expect(
    controller.currentResult.candidates.contains {
      $0.insertText == "curl https://example.test" && $0.kind == .learnedCommand
    }
  )
  #expect(!controller.currentResult.candidates.contains { $0.insertText.contains("private") })
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
