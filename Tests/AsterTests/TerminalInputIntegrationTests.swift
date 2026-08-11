import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("终端输出与用户输入都会触发安全输入即时采样")
@MainActor
func terminalIOTriggersSecureInputSampling() {
  let view = AsterTerminalView(frame: .zero)
  var samples = 0
  view.onTerminalIO = { samples += 1 }

  view.dataReceived(slice: Array("prompt".utf8)[...])
  #expect(samples == 1)

  view.send(source: view, data: Array("x".utf8)[...])
  #expect(samples == 2)
}

@Test("VT100 application keypad 仅在允许时发送 SS3 序列")
@MainActor
func vt100ApplicationKeypadRespectsControlSetting() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.dataReceived(slice: Array("\u{1B}=".utf8)[...]) // DECKPAM
  view.vtKeypadApplicationModeAllowed = true
  var encoded: [UInt8] = []
  view.onEncodedInput = { encoded.append(contentsOf: $0) }
  let keypadOne = try #require(NSEvent.keyEvent(
    with: .keyDown,
    location: .zero,
    modifierFlags: [.numericPad],
    timestamp: 0,
    windowNumber: 0,
    context: nil,
    characters: "1",
    charactersIgnoringModifiers: "1",
    isARepeat: false,
    keyCode: 83
  ))

  view.keyDown(with: keypadOne)

  #expect(encoded == [0x1B, 0x4F, 0x71])
}

@Test("左右 Option 的 Meta 范围按物理键状态生效")
@MainActor
func physicalOptionMetaScopeUsesConfiguredSide() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.optionAsMetaKey = true
  view.optionAsMetaKeyCodes = [58]
  var encoded: [UInt8] = []
  view.onEncodedInput = { encoded.append(contentsOf: $0) }
  let leftOptionDown = try #require(NSEvent.keyEvent(
    with: .flagsChanged, location: .zero, modifierFlags: [.option], timestamp: 0,
    windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
    isARepeat: false, keyCode: 58
  ))
  let optionX = try #require(NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: [.option], timestamp: 0,
    windowNumber: 0, context: nil, characters: "≈", charactersIgnoringModifiers: "x",
    isARepeat: false, keyCode: 7
  ))

  view.flagsChanged(with: leftOptionDown)
  view.keyDown(with: optionX)

  #expect(encoded == [0x1B, 0x78])
}

@Test("原生编辑菜单动作只在普通终端屏幕启用")
@MainActor
func naturalEditingMenuValidationPreservesAlternateScreen() {
  let view = AsterTerminalView(frame: .zero)
  let item = NSMenuItem(
    title: "移到行首",
    action: #selector(AsterTerminalView.movePromptToBeginningOfLine(_:)),
    keyEquivalent: ""
  )

  #expect(view.responds(to: item.action!))
  #expect(view.validateUserInterfaceItem(item))

  view.getTerminal().feed(byteArray: Array("\u{1B}[?1049h".utf8))
  #expect(view.getTerminal().isCurrentBufferAlternate)
  #expect(!view.validateUserInterfaceItem(item))
}

@Test("显示与编辑菜单公开 Otty 字号、全屏和插入命令")
@MainActor
func nativeMenusExposeOttyDisplayAndInsertionCommands() throws {
  let delegate = AsterAppDelegate()
  let display = try #require(delegate.workspaceMenuItem().submenu)
  let edit = try #require(delegate.editMenuItem().submenu)

  let increase = try #require(display.item(withTitle: "增大字号"))
  let decrease = try #require(display.item(withTitle: "减小字号"))
  let reset = try #require(display.item(withTitle: "重置字号"))
  let fullScreen = try #require(display.item(withTitle: "进入全屏幕"))
  #expect(increase.keyEquivalent == "=")
  #expect(increase.keyEquivalentModifierMask == .command)
  #expect(decrease.keyEquivalent == "-")
  #expect(decrease.keyEquivalentModifierMask == .command)
  #expect(reset.keyEquivalent == "0")
  #expect(reset.keyEquivalentModifierMask == .command)
  #expect(fullScreen.keyEquivalent == "f")
  #expect(fullScreen.keyEquivalentModifierMask == .function)

  let insert = try #require(edit.item(withTitle: "插入")?.submenu)
  #expect(insert.items.map(\.title) == ["文件路径…", "截屏"])
  #expect(
    edit.items.contains {
      $0.identifier == NSMenuItem.importFromDeviceIdentifier && $0.title == "Insert from iPhone"
    })
  let editor = try #require(edit.item(withTitle: "编辑器"))
  #expect(editor.keyEquivalent == "e")
  #expect(editor.keyEquivalentModifierMask == [.command, .shift])
  #expect(editor.image != nil)
  // Otty 的 ⇧⌘E 是 Composer，不是文件选择器；文件编辑仍经 File/路径入口创建 Pane。
  #expect(NSStringFromSelector(try #require(editor.action)) == "toggleComposer:")
  let promptQueue = try #require(edit.item(withTitle: "Prompt 队列…"))
  #expect(promptQueue.keyEquivalent == "m")
  #expect(promptQueue.keyEquivalentModifierMask == [.command, .shift])
  #expect(promptQueue.image != nil)
  #expect(edit.item(withTitle: "发送到聊天…")?.image != nil)
  #expect(edit.item(withTitle: "安全键盘输入") != nil)
}

@Test("字号菜单命令按 1pt 调整、夹紧并可恢复默认值")
@MainActor
func fontSizeMenuPolicyUsesSharedPreferences() {
  let suiteName = "AsterTests.FontMenu.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)

  preferences.fontSize = 31.5
  preferences.adjustFontSize(by: 1)
  #expect(preferences.fontSize == 32)
  preferences.fontSize = 9
  preferences.adjustFontSize(by: -1)
  #expect(preferences.fontSize == 9)
  preferences.fontSize = 21
  preferences.resetFontSize()
  #expect(preferences.fontSize == AsterConfiguration.default.appearance.fontSize)
}

@Test("手机导入文件使用受支持后缀和私有权限")
@MainActor
func continuityImportStoreWritesPrivateBoundedFile() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "AsterTests.Continuity.\(UUID().uuidString)", isDirectory: true
  )
  defer { try? FileManager.default.removeItem(at: root) }
  let payload = Data([0x89, 0x50, 0x4E, 0x47])

  let file = try TerminalImportedFileStore.save(payload, type: .png, baseDirectory: root)
  let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
  let permissions = try #require(attributes[.posixPermissions] as? NSNumber)

  #expect(file.pathExtension == "png")
  #expect(try Data(contentsOf: file) == payload)
  #expect(permissions.intValue & 0o777 == 0o600)
  #expect(throws: TerminalImportError.unsupportedType) {
    try TerminalImportedFileStore.save(
      payload,
      type: .init("public.untrusted-data"),
      baseDirectory: root
    )
  }
}

@Test("文件与手机路径会预填到 Codex 输入框且不自动提交")
@MainActor
func importedPathsPrefillCodexInputWithoutSubmitting() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  // Codex TUI 使用 bracketed paste 接收整段输入；该模式能抓住误走逐键输入或普通
  // Shell 粘贴入口的回归，同时 Return 必须始终由用户自己确认。
  view.dataReceived(slice: Array("\u{001B}[?2004h".utf8)[...])
  var encoded: [UInt8] = []
  view.onEncodedInput = { encoded.append(contentsOf: $0) }
  let paths = [
    URL(fileURLWithPath: "/tmp/a file.png"),
    URL(fileURLWithPath: "/tmp/from-phone.heic"),
  ]

  #expect(view.insertPathsIntoCurrentInput(paths))

  let text = String(decoding: encoded, as: UTF8.self)
  #expect(text.hasPrefix("\u{001B}[200~"))
  #expect(text.hasSuffix("\u{001B}[201~"))
  #expect(text.contains(ShellPasteEscaper.escape(paths[0].path)))
  #expect(text.contains(ShellPasteEscaper.escape(paths[1].path)))
  #expect(!encoded.contains(13))
}

@Test("Continuity Camera 使用 AppKit 标准 pasteboard responder selector")
@MainActor
func continuityCameraUsesStandardPasteboardResponderSelector() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))

  // `Insert from iPhone` 由 AppKit 固定发送 `readSelectionFromPasteboard:`。仅提供
  // Swift 自动推导的 `readSelectionFrom:` 时，菜单可以出现并完成拍摄，但结果不会
  // 到达终端 responder，用户看到的就是 Codex 输入框没有任何变化。
  #expect(view.responds(to: NSSelectorFromString("readSelectionFromPasteboard:")))
}
