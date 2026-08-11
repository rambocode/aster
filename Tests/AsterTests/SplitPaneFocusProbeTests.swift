import AppKit
import Testing

@testable import Aster
@testable import AsterCore
@testable import SwiftTerm

// 拆分焦点回归:正在旧 Pane 输入时新建分屏,键盘输入必须跟随视觉焦点落到新 Pane。

/// 构造一个最小键盘事件,驱动终端视图的 keyDown 编码路径。
@MainActor
private func keyEvent(_ character: String) throws -> NSEvent {
  try #require(
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: character,
      charactersIgnoringModifiers: character,
      isARepeat: false,
      keyCode: 0
    ))
}

@Test("旧 Pane 正在输入时拆分,新 Pane 必须接管键盘输入")
@MainActor
func newlySplitPaneTakesOverKeyboardInput() async throws {
  let suite = "SplitFocusProbe.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)

  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.contentView?.layoutSubtreeIfNeeded()
  let tab = try #require(model.selectedTab)
  defer {
    for runtime in tab.runtimes.values { runtime.terminalSession?.stop(immediately: true) }
    window.orderOut(nil)
  }
  // refresh() 用 main.async 延后交接焦点,等一轮主循环。
  try await Task.sleep(for: .milliseconds(150))

  // 前置:键盘焦点在原 Pane 的终端上(用户正在输入)。
  let firstPane = tab.activePaneID
  let firstSession = try #require(tab.runtime(for: firstPane)?.terminalSession)
  let firstTerminal = try #require(
    firstSession.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  #expect(window.firstResponder === firstTerminal)

  // 动作:拆分出新 Pane(模型会把 activePaneID 切到新 Pane)。
  model.splitSelectedTab(.right)
  try await Task.sleep(for: .milliseconds(200))

  let newPane = tab.activePaneID
  #expect(newPane != firstPane, "拆分后活动 Pane 应是新建的那个")
  let newSession = try #require(tab.runtime(for: newPane)?.terminalSession)
  let newTerminal = try #require(
    newSession.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )

  // 症状断言 1:first responder 必须是新 Pane 的终端,而不是旧 Pane。
  #expect(
    window.firstResponder === newTerminal,
    "拆分后键盘焦点应在新 Pane,实际: \(String(describing: window.firstResponder))"
  )

  // 症状断言 2:按键必须编码进新 Pane 的发送路径,且不进旧 Pane。
  var newEncoded: [[UInt8]] = []
  var oldEncoded: [[UInt8]] = []
  newTerminal.onEncodedInput = { newEncoded.append(Array($0)) }
  firstTerminal.onEncodedInput = { oldEncoded.append(Array($0)) }
  (window.firstResponder as? AsterTerminalView)?.keyDown(with: try keyEvent("z"))
  #expect(newEncoded == [Array("z".utf8)], "按键应写入新 Pane 的 PTY")
  #expect(oldEncoded.isEmpty, "按键不得写入旧 Pane 的 PTY")
}
