// 验证 Ctrl+Return 交给终端，而不是被 AppKit 当成弹出上下文菜单的快捷键。
import AppKit
import Testing

@testable import Aster

/// 构造一个 Return 键事件；control 为 true 时带 Control 修饰。
@MainActor
private func returnKeyEvent(control: Bool, window: NSWindow) -> NSEvent {
  NSEvent.keyEvent(
    with: .keyDown, location: .zero, modifierFlags: control ? [.control] : [],
    timestamp: 0, windowNumber: window.windowNumber, context: nil,
    characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
}

@Test("聚焦终端时 Ctrl+Return 由终端接管，不弹出系统上下文菜单")
@MainActor
func ghosttyClaimsControlReturnWhenFocused() {
  _ = NSApplication.shared
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
    styleMask: [.titled], backing: .buffered, defer: false)
  let view = GhosttySurfaceView(workingDirectory: "/tmp", environment: [:], configurationText: "")
  window.contentView?.addSubview(view)

  window.makeFirstResponder(view)
  #expect(view.performKeyEquivalent(with: returnKeyEvent(control: true, window: window)))
  // 普通 Return 仍走 keyDown，不能被当成快捷键吞掉。
  #expect(!view.performKeyEquivalent(with: returnKeyEvent(control: false, window: window)))

  // 焦点不在终端时不抢其他视图的按键。
  window.makeFirstResponder(nil)
  #expect(!view.performKeyEquivalent(with: returnKeyEvent(control: true, window: window)))
}
