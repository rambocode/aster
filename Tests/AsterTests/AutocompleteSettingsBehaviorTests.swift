// 设置页「接受候选」「候选面板」两个下拉框：网页值往返，以及每个选项对应的按键行为。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

// MARK: - 设置页往返

@Test("接受候选与候选面板的每个选项写入后快照原样回传，网页选项列表都有对应值")
@MainActor
func autocompleteSettingsRoundTripEveryOption() throws {
  let suite = "AutocompleteSettings.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  controller.loadViewIfNeeded()
  let script = try String(
    contentsOf: repositoryRoot().appendingPathComponent("Resources/settings-ui/settings.js"),
    encoding: .utf8)

  for shortcut in AutocompleteShortcut.allCases {
    try controller.applySettingForTesting(key: "controls.autocompleteShortcut", value: shortcut.rawValue)
    #expect(preferences.configuration.controls.resolvedAutocompleteShortcut == shortcut)
    let values = try #require(controller.settingsSnapshotForTesting()["values"] as? [String: Any])
    // 快照值必须能匹配网页选项，否则下拉框会显示回第一项，看起来像「选择无效」。
    #expect(values["controls.autocompleteShortcut"] as? String == shortcut.rawValue)
    #expect(script.contains("[\"\(shortcut.rawValue)\""))
  }
  for panel in AutocompleteCandidatePanel.allCases {
    try controller.applySettingForTesting(key: "controls.autocompleteCandidatePanel", value: panel.rawValue)
    #expect(preferences.configuration.controls.resolvedAutocompleteCandidatePanel == panel)
    let values = try #require(controller.settingsSnapshotForTesting()["values"] as? [String: Any])
    #expect(values["controls.autocompleteCandidatePanel"] as? String == panel.rawValue)
    #expect(script.contains("[\"\(panel.rawValue)\""))
  }
}

// MARK: - 按键识别

@Test("Control-Space 与 Option-Esc 从真实键盘事件识别为对应意图")
func autocompleteKeyResolvesModifiedKeys() throws {
  let controlSpace = try #require(keyEvent(keyCode: 49, characters: " ", modifiers: .control))
  let optionEscape = try #require(keyEvent(keyCode: 53, characters: "\u{1B}", modifiers: .option))
  let plainSpace = try #require(keyEvent(keyCode: 49, characters: " ", modifiers: []))
  #expect(TerminalAutocompleteKey.resolve(controlSpace) == .controlSpace)
  #expect(TerminalAutocompleteKey.resolve(optionEscape) == .optionEscape)
  #expect(TerminalAutocompleteKey.resolve(plainSpace) == .other)
}

// MARK: - 接受候选

@Test("接受候选的每个选项只响应自己的按键")
@MainActor
func autocompleteShortcutAcceptsOnlyConfiguredKeys() async throws {
  let expectations: [(AutocompleteShortcut, accepted: [TerminalAutocompleteKey], ignored: [TerminalAutocompleteKey])] = [
    (.tab, [.tab], [.right, .controlSpace]),
    (.tabAndRightArrow, [.tab, .right], [.controlSpace]),
    (.controlSpace, [.controlSpace], [.tab, .right]),
    (.disabled, [], [.tab, .right, .controlSpace]),
  ]
  for (shortcut, accepted, ignored) in expectations {
    for key in ignored {
      let harness = try await AutocompleteHarness(line: "git chec") { $0.autocompleteShortcut = shortcut }
      defer { harness.cleanUp() }
      #expect(!harness.controller.handle(key), "\(shortcut) 不应响应 \(key)")
      #expect(harness.sent.value.isEmpty)
    }
    for key in accepted {
      let harness = try await AutocompleteHarness(line: "git chec") { $0.autocompleteShortcut = shortcut }
      defer { harness.cleanUp() }
      #expect(harness.controller.handle(key), "\(shortcut) 应响应 \(key)")
      #expect(String(decoding: harness.sent.value, as: UTF8.self) == "kout")
    }
  }
}

// MARK: - 候选面板

@Test("候选面板：自动模式输入即展开，关闭模式任何按键都不打开")
@MainActor
func autocompleteCandidatePanelAutomaticAndDisabled() async throws {
  let automatic = try await AutocompleteHarness(line: "git c") {
    $0.autocompleteCandidatePanel = .automatic
    $0.autocompleteInlineSuggestion = false
  }
  defer { automatic.cleanUp() }
  #expect(automatic.controller.panelVisible)

  let disabled = try await AutocompleteHarness(line: "git c") {
    $0.autocompleteCandidatePanel = .disabled
    $0.autocompleteInlineSuggestion = false
  }
  defer { disabled.cleanUp() }
  #expect(!disabled.controller.panelVisible)
  for key: TerminalAutocompleteKey in [.escape, .optionEscape, .functionFive] {
    _ = disabled.controller.handle(key)
    #expect(!disabled.controller.panelVisible)
  }
}

@Test("候选面板：Esc 模式只认 Esc，Option-Esc 模式只认 Option-Esc 或 F5")
@MainActor
func autocompleteCandidatePanelOpensOnlyWithConfiguredKey() async throws {
  let cases: [(AutocompleteCandidatePanel, opens: [TerminalAutocompleteKey], ignored: [TerminalAutocompleteKey])] = [
    (.escape, [.escape], [.optionEscape, .functionFive]),
    (.optionEscape, [.optionEscape, .functionFive], [.escape]),
  ]
  for (panel, opens, ignored) in cases {
    for key in ignored {
      let harness = try await AutocompleteHarness(line: "git c") {
        $0.autocompleteCandidatePanel = panel
        $0.autocompleteInlineSuggestion = false
      }
      defer { harness.cleanUp() }
      #expect(!harness.controller.panelVisible)
      _ = harness.controller.handle(key)
      #expect(!harness.controller.panelVisible, "\(panel) 不应被 \(key) 打开")
    }
    for key in opens {
      let harness = try await AutocompleteHarness(line: "git c") {
        $0.autocompleteCandidatePanel = panel
        $0.autocompleteInlineSuggestion = false
      }
      defer { harness.cleanUp() }
      #expect(harness.controller.handle(key))
      #expect(harness.controller.panelVisible, "\(panel) 应被 \(key) 打开")
    }
  }
}

// MARK: - 测试辅助

/// 可变字节缓冲，供输入回调闭包写入。
@MainActor
private final class SentBytes {
  var value: [UInt8] = []
}

/// 搭好「可靠 prompt + 已回显输入」的补全控制器，按需改写控制配置。
@MainActor
private struct AutocompleteHarness {
  let directory: URL
  let controller: TerminalAutocompleteController
  let view: AsterTerminalView
  let sent = SentBytes()

  init(line: String, configure: (inout ControlConfiguration) -> Void) async throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "aster-autocomplete-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let service = try AutocompleteService(
      baseDirectory: directory,
      bundledSpecURL: repositoryRoot().appendingPathComponent("Resources/autocomplete/fig-specs.json")
    )
    var controls = ControlConfiguration()
    configure(&controls)
    let snapshot = controls
    view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
    controller = TerminalAutocompleteController(
      service: service,
      sessionIdentifier: "session",
      controls: { snapshot },
      currentDirectory: { "/project" }
    )
    controller.attach(to: view)
    let sent = sent
    let controller = controller
    view.onEncodedInput = { sent.value.append(contentsOf: $0) }
    view.onAutocompleteOutput = { controller.receiveOutput($0) }

    controller.receive(.promptStart)
    controller.receive(.inputStart)
    controller.receiveInput(Array(line.utf8)[...])
    controller.refreshNow()
    // 只接受屏幕上可见的 ghost：先让 PTY 回显输入。
    view.dataReceived(slice: Array(line.utf8)[...])
    await Task.yield()
  }

  func cleanUp() {
    try? FileManager.default.removeItem(at: directory)
  }
}

/// 仓库根目录，用于读取打包前的资源文件。
private func repositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}

/// 构造一个不依赖窗口的键盘按下事件。
private func keyEvent(keyCode: UInt16, characters: String, modifiers: NSEvent.ModifierFlags) -> NSEvent? {
  NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
    windowNumber: 0, context: nil, characters: characters,
    charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)
}
