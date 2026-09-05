import AppKit
import Testing

@testable import Aster
@testable import AsterCore

@Test("Ghostty 以真实光标拆分输入与行尾，历史行不能冒充当前输入")
@MainActor
func ghosttyAutocompleteValidatesCursorRowAndSuffix() async throws {
  _ = NSApplication.shared
  let suite = "AsterTests.autocomplete.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.contentViewController = controller
  window.makeKeyAndOrderFront(nil)
  defer { window.orderOut(nil) }
  window.layoutIfNeeded()
  func descendants(_ view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants)
  }
  var terminal: GhosttySurfaceView?
  for _ in 0..<200 {
    terminal = descendants(controller.view).compactMap { $0 as? GhosttySurfaceView }
      .first { $0.surface != nil && $0.isProcessRunning }
    if terminal != nil { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  let view = try #require(terminal)
  // 在独立测试终端里生成确定的行与光标，sleep 期间 Shell 不会重画 prompt。
  #expect(view.typeText("printf '\\033[2J\\033[Hgit ch'; sleep 2; printf 'eckout\\033[6D'; sleep 2; printf '\\033[K'; sleep 2\n"))
  func waitFor(_ predicate: () -> Bool) async throws -> Bool {
    for _ in 0..<180 {
      if predicate() { return true }
      try await Task.sleep(for: .milliseconds(20))
    }
    return false
  }
  #expect(try await waitFor { view.visiblePromptEnds(with: "git ch") })
  #expect(!view.visiblePromptEnds(with: "wrong input"))
  let caret = view.autocompleteCaretFrame
  #expect(caret.height > 0)
  #expect(caret.width == 0)
  #expect(caret.minX < view.textCursorFrameInViewCoordinates.minX)
  #expect(try await waitFor { view.readText(includeScrollback: false)?.contains("git checkout") == true })
  #expect(!view.visiblePromptEnds(with: "git ch"))
  #expect(!view.visiblePromptEnds(with: "git checkout"), "行尾文本不能冒充光标前的输入")
  #expect(try await waitFor { view.visiblePromptEnds(with: "git ch") })
}

@Test("Ghostty 输入不能越过已排队的 prompt 标记，否则命令前缀会被清空")
@MainActor
func ghosttyAutocompletePreservesInputAndOSCOrder() async throws {
  let view = GhosttySurfaceView(workingDirectory: "/tmp", environment: [:], configurationText: "")
  var events: [String] = []
  let tracker = PromptInputTracker()
  view.onOSC = { _, payload, _ in
    let marker = String(decoding: payload, as: UTF8.self)
    events.append(marker)
    if marker == "A" { tracker.beginPrompt() }
  }
  view.onPTYWrite = { bytes in
    events.append("input")
    _ = tracker.receive(Array(bytes))
  }
  view.enqueueOSC(code: 133, payload: Array("A".utf8), point: .init())
  view.enqueueOSC(code: 133, payload: Array("B".utf8), point: .init())
  view.enqueuePTYWrite(Array("git ch".utf8))
  for _ in 0..<100 where events.count < 3 {
    try await Task.sleep(for: .milliseconds(10))
  }
  #expect(events == ["A", "B", "input"])
  #expect(tracker.line == "git ch")
}
