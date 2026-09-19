import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 控制器注入闭包共享的可变状态。测试用例直接改这里的字段，无需重建控制器，
/// 时钟与剪贴板因此都可以确定性地控制——不碰真实 `NSPasteboard`，也不等墙钟。
@MainActor
private final class ClipboardSuggestionState {
  var controls = ControlConfiguration()
  var clipboard: String?
  var consumedCount = 0
  var elapsed = Duration.zero
}

@MainActor
private struct ClipboardSuggestionFixture {
  let directory: URL
  let view: AsterTerminalView
  let controller: TerminalAutocompleteController
  let state: ClipboardSuggestionState
  /// 已经写进 PTY 的字节。剪贴板建议的核心不变量之一是这里绝不出现换行。
  let sent: SentBytes

  @MainActor final class SentBytes {
    var bytes: [UInt8] = []
    var text: String { String(decoding: bytes, as: UTF8.self) }
  }

  init() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "aster-clipboard-suggestion-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let repositoryRoot = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let service = try AutocompleteService(
      baseDirectory: directory,
      bundledSpecURL: repositoryRoot.appendingPathComponent("Resources/autocomplete/fig-specs.json")
    )
    let state = ClipboardSuggestionState()
    let base = ContinuousClock.now
    let sent = SentBytes()
    self.state = state
    self.sent = sent
    view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
    controller = TerminalAutocompleteController(
      service: service,
      sessionIdentifier: "session",
      controls: { state.controls },
      currentDirectory: { "/project" },
      now: { base.advanced(by: state.elapsed) }
    )
    controller.clipboardSuggestionProvider = { state.clipboard }
    controller.onClipboardSuggestionConsumed = { state.consumedCount += 1 }
    controller.attach(to: view)
    view.onEncodedInput = { sent.bytes.append(contentsOf: $0) }
  }

  /// 走到「新提示符已就绪、输入行为空」的状态并算一轮候选。
  func openPrompt() {
    controller.receive(.promptStart)
    controller.receive(.inputStart)
    controller.refreshNow()
  }

  /// 让 ghost 越过防误触延迟并重画，使它真正「解除保险」。
  func advancePastArmDelay() {
    state.elapsed = .milliseconds(400)
    controller.refreshNow()
  }

  func cleanUp() {
    try? FileManager.default.removeItem(at: directory)
  }
}

@Test("空提示符上把剪贴板内容画成 ghost，回车只写入文本不发换行")
@MainActor
func clipboardSuggestionAcceptedByEnterWithoutExecuting() throws {
  let fixture = try ClipboardSuggestionFixture()
  defer { fixture.cleanUp() }
  fixture.state.clipboard = "brew install ripgrep"
  fixture.openPrompt()

  #expect(fixture.controller.currentResult.candidates.first?.kind == .clipboard)
  #expect(fixture.controller.currentResult.ghostText == "brew install ripgrep")

  fixture.advancePastArmDelay()
  #expect(fixture.controller.handle(.enter))
  #expect(fixture.sent.text == "brew install ripgrep")
  // 核心不变量：接受剪贴板建议绝不能把命令送出去执行。
  #expect(!fixture.sent.bytes.contains(0x0A))
  #expect(!fixture.sent.bytes.contains(0x0D))
  #expect(fixture.state.consumedCount == 1)
  #expect(fixture.controller.lastSubmittedCommand == nil)
}

@Test("ghost 刚出现时的回车照常交给 Shell，不会误粘贴")
@MainActor
func clipboardSuggestionIgnoresEnterBeforeArmDelay() throws {
  let fixture = try ClipboardSuggestionFixture()
  defer { fixture.cleanUp() }
  fixture.state.clipboard = "rm -rf build"
  fixture.openPrompt()

  // 用户在空提示符上连按回车是最高频的无意识操作；ghost 刚画出来的那一下必须放行，
  // 否则「粘贴 + 执行」只需要两次抖动。
  #expect(!fixture.controller.handle(.enter))
  #expect(fixture.sent.bytes.isEmpty)
  #expect(fixture.state.consumedCount == 0)
}

@Test("带修饰键、长按重复或输入法组字中的回车不被剪贴板建议吞掉")
@MainActor
func clipboardSuggestionIgnoresNonPlainEnter() throws {
  let fixture = try ClipboardSuggestionFixture()
  defer { fixture.cleanUp() }
  fixture.state.clipboard = "git push"
  fixture.openPrompt()
  fixture.advancePastArmDelay()

  #expect(!fixture.controller.handle(.enter, plainKeyPress: false))
  #expect(fixture.sent.bytes.isEmpty)
  #expect(fixture.state.consumedCount == 0)
}

@Test("输入行已有内容时不提示剪贴板")
@MainActor
func clipboardSuggestionSkipsNonEmptyLine() throws {
  let fixture = try ClipboardSuggestionFixture()
  defer { fixture.cleanUp() }
  fixture.state.clipboard = "brew install ripgrep"
  fixture.openPrompt()
  fixture.controller.receiveInput(Array("gi".utf8)[...])
  fixture.controller.refreshNow()

  #expect(fixture.controller.currentResult.candidates.first?.kind != .clipboard)
  // 用户开始打字就是表态「我不要这份内容」，退格回空行时不该又冒出来。
  #expect(fixture.state.consumedCount == 1)
}

@Test("Esc 把剪贴板建议标记为已忽略")
@MainActor
func clipboardSuggestionDismissedByEscape() throws {
  let fixture = try ClipboardSuggestionFixture()
  defer { fixture.cleanUp() }
  fixture.state.clipboard = "git status"
  fixture.openPrompt()

  #expect(fixture.controller.handle(.escape))
  #expect(fixture.state.consumedCount == 1)
}

@Test("关闭开关后不再提示剪贴板内容")
@MainActor
func clipboardSuggestionRespectsSetting() throws {
  let fixture = try ClipboardSuggestionFixture()
  defer { fixture.cleanUp() }
  fixture.state.controls.clipboardSuggestion = false
  fixture.state.clipboard = "brew install ripgrep"
  fixture.openPrompt()

  #expect(fixture.controller.currentResult.candidates.first?.kind != .clipboard)
  fixture.advancePastArmDelay()
  #expect(!fixture.controller.handle(.enter))
  #expect(fixture.sent.bytes.isEmpty)
}

@Test("剪贴板里是一段话时不提示")
@MainActor
func clipboardSuggestionSkipsProseText() throws {
  let fixture = try ClipboardSuggestionFixture()
  defer { fixture.cleanUp() }
  // 首词结构合法但本机不认得这条命令，说明它是一段文字而不是一条命令。
  fixture.state.clipboard = "Please review this pull request"
  fixture.openPrompt()

  #expect(fixture.controller.currentResult.candidates.first?.kind != .clipboard)
}

@Test("本机不认识的工具带上选项时照样提示")
@MainActor
func clipboardSuggestionAllowsUnknownToolWithFlags() throws {
  let fixture = try ClipboardSuggestionFixture()
  defer { fixture.cleanUp() }
  // 规格库、PATH 都不认识 zzz-unknown-tool，但 `--fix` 这种写法在一句话里不会出现。
  fixture.state.clipboard = "zzz-unknown-tool run --fix"
  fixture.openPrompt()

  #expect(fixture.controller.currentResult.candidates.first?.kind == .clipboard)
}

@Test("多行剪贴板内容不进入候选")
@MainActor
func clipboardSuggestionSkipsMultilineText() throws {
  let fixture = try ClipboardSuggestionFixture()
  defer { fixture.cleanUp() }
  fixture.state.clipboard = "cd /tmp\nrm -rf *"
  fixture.openPrompt()

  #expect(fixture.controller.currentResult.candidates.first?.kind != .clipboard)
}
