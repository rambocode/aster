import AppKit
import Testing

@testable import Aster
@testable import AsterCore
@testable import SwiftTerm

// 恢复(重启应用重载快照)后的分屏输入回归:首个 Pane 必须能接收键盘输入。

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

@Test("快照恢复的分屏工作区中第一个 Pane 可以输入")
@MainActor
func restoredSplitWorkspaceFirstPaneAcceptsInput() async throws {
  let suite = "RestoredInputProbe.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)

  // 走真实恢复路径:把分屏布局写入快照,让 AppModel 从 defaults 重建。
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  let layout = PaneLayout.split(
    axis: .horizontal,
    first: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: home)),
    second: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: home)),
    ratio: 0.5
  )
  let tabSnapshot = WorkspaceTabSnapshot(id: UUID(), title: "restored", layout: layout)
  let snapshot = WorkspaceSnapshot(selectedTabID: tabSnapshot.id, tabs: [tabSnapshot])
  defaults.set(try JSONEncoder().encode(snapshot), forKey: "aster.workspace.snapshot.v1")

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
  // refresh() 用 main.async 延后交接焦点;真实恢复后也要等一轮主循环。
  try await Task.sleep(for: .milliseconds(120))

  let paneIDs = tab.layout.allPanes.map(\.id)
  #expect(paneIDs.count == 2)
  let firstPane = try #require(paneIDs.first)
  #expect(tab.activePaneID == firstPane)

  let firstSession = try #require(tab.runtime(for: firstPane)?.terminalSession)
  let firstTerminal = try #require(
    firstSession.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )

  // 1) 恢复完成后键盘焦点应落在活动(第一个)Pane 的终端上。
  #expect(window.firstResponder === firstTerminal)

  // 2) 按键必须编码进 PTY 发送路径。
  var encoded: [[UInt8]] = []
  firstTerminal.onEncodedInput = { encoded.append(Array($0)) }
  firstTerminal.keyDown(with: try keyEvent("a"))
  #expect(encoded == [Array("a".utf8)])

  // 3) 焦点切到第二个 Pane 再回到第一个,输入仍然可用。
  let secondPane = try #require(paneIDs.last)
  tab.setActivePane(secondPane)
  try await Task.sleep(for: .milliseconds(60))
  tab.setActivePane(firstPane)
  try await Task.sleep(for: .milliseconds(60))
  #expect(window.firstResponder === firstTerminal)
  encoded.removeAll()
  firstTerminal.keyDown(with: try keyEvent("b"))
  #expect(encoded == [Array("b".utf8)])

  // 4) 键盘焦点丢到别处(浮层关闭、恢复时序等)后,点击「已经是活动态」的 Pane
  //    也必须重新交接焦点——activePaneID 不变不发事件,不能因此没有任何自愈手段。
  window.makeFirstResponder(window.contentView)
  #expect(window.firstResponder !== firstTerminal)
  controller.routePaneClick(firstPane, in: tab)
  #expect(window.firstResponder === firstTerminal)
}

/// 等待条件成立;超时返回 false。
@MainActor
private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(50))
  }
  return condition()
}

@Test("恢复后 shell 退出的 Pane 显示结束卡,重启后恢复输入")
@MainActor
func restoredPaneRecoversInputAfterShellExit() async throws {
  let suite = "RestoredExitProbe.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  let layout = PaneLayout.split(
    axis: .horizontal,
    first: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: home)),
    second: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: home)),
    ratio: 0.5
  )
  let tabSnapshot = WorkspaceTabSnapshot(id: UUID(), title: "restored", layout: layout)
  let snapshot = WorkspaceSnapshot(selectedTabID: tabSnapshot.id, tabs: [tabSnapshot])
  defaults.set(try JSONEncoder().encode(snapshot), forKey: "aster.workspace.snapshot.v1")

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
  try await Task.sleep(for: .milliseconds(150))

  let firstPane = try #require(tab.layout.allPanes.map(\.id).first)
  let session = try #require(tab.runtime(for: firstPane)?.terminalSession)
  #expect(await waitUntil(timeout: 5) { session.isRunning })

  // 模拟恢复后 shell 很快退出(崩溃、环境错误等)。
  session.typeText("exit\r")
  #expect(await waitUntil(timeout: 8) { !session.isRunning })
  try await Task.sleep(for: .milliseconds(200))

  // 退出必须可见:Pane 上要出现结束卡,不能停留在“看起来还活着”的最后一帧。
  let overlayVisible = controller.view.descendantViews.contains {
    $0.identifier?.rawValue.hasPrefix("terminal-ended-overlay-") == true
  }
  #expect(overlayVisible, "shell 退出后 Pane 必须显示结束卡")

  // 经同一 Session 重启后,视图绑定和键盘输入都必须恢复。
  #expect(session.restart())
  #expect(await waitUntil(timeout: 5) { session.isRunning })
  try await Task.sleep(for: .milliseconds(200))
  controller.routePaneClick(firstPane, in: tab)
  let terminal = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  #expect(terminal.window === window, "重启后的终端视图必须挂回窗口")
  #expect(window.firstResponder === terminal)
  var encoded: [[UInt8]] = []
  terminal.onEncodedInput = { encoded.append(Array($0)) }
  terminal.keyDown(with: try keyEvent("x"))
  #expect(encoded == [Array("x".utf8)])
}

extension NSView {
  fileprivate var descendantViews: [NSView] {
    subviews.flatMap { [$0] + $0.descendantViews }
  }
}
