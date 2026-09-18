// Shell 被用户主动结束（exit / Ctrl+D）后自动关闭所在 Pane 的窗口层行为。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 使用独立 UserDefaults suite，避免污染 `.standard` 里的真实工作区快照。
@MainActor
private func makeExitWorkspace() throws -> (model: AppModel, tab: TerminalTabItem) {
  let suite = "AsterShellExitTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  return (model, tab)
}

/// 关闭动作延后一轮主队列执行；让出若干轮直到条件成立，避免依赖固定延时。
@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
  for _ in 0..<500 where !condition() {
    try? await Task.sleep(for: .milliseconds(10))
  }
}

@Test("后台 Pane 的 Shell 正常退出后只关闭该 Pane，焦点不动")
@MainActor
func shellExitClosesOnlyThatPane() async throws {
  let (model, tab) = try makeExitWorkspace()
  let firstPane = tab.activePaneID
  model.splitSelectedTab(.right)
  let secondPane = tab.activePaneID
  let session = try #require(tab.runtime(for: firstPane)?.terminalSession)

  session.simulateProcessExitForTesting(code: 0, uptime: 60)
  await waitUntil { tab.layout.allPanes.count == 1 }

  #expect(tab.layout.allPanes.map(\.id) == [secondPane])
  #expect(tab.activePaneID == secondPane)
  #expect(model.tabs.contains { $0 === tab })
}

@Test("最后一个 Pane 的 Shell 退出后关闭整个标签，工作区仍保留一个标签")
@MainActor
func shellExitInLastPaneClosesTab() async throws {
  let (model, tab) = try makeExitWorkspace()
  let session = try #require(tab.runtime(for: tab.activePaneID)?.terminalSession)

  session.simulateProcessExitForTesting(code: 0, uptime: 60)
  await waitUntil { !model.tabs.contains { $0 === tab } }

  #expect(!model.tabs.contains { $0 === tab })
  #expect(model.tabs.count == 1)
}

@Test("Shell 启动即非零退出时保留 Pane 与结束卡")
@MainActor
func abnormalShellExitKeepsPane() async throws {
  let (model, tab) = try makeExitWorkspace()
  let firstPane = tab.activePaneID
  model.splitSelectedTab(.right)
  let session = try #require(tab.runtime(for: firstPane)?.terminalSession)

  session.simulateProcessExitForTesting(code: 127, uptime: 0.2)
  // 让出足够多轮主队列：若错误地触发了关闭，此时 Pane 数会变成 1。
  for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(10)) }

  #expect(tab.layout.allPanes.count == 2)
  #expect(session.lifecycleState == .ended(.exited(code: 127)))
}

@Test("受管终端的远端进程退出后保留结束卡，不自动关闭 Pane")
@MainActor
func managedExitKeepsPane() async throws {
  let (model, tab) = try makeExitWorkspace()
  let firstPane = tab.activePaneID
  model.splitSelectedTab(.right)
  let session = try #require(tab.runtime(for: firstPane)?.terminalSession)

  session.simulateManagedExitForTesting(code: 0)
  for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(10)) }

  #expect(tab.layout.allPanes.count == 2)
}

@Test("真实 Ghostty Pane 里输入 exit 后该 Pane 关闭")
@MainActor
func typingExitInGhosttyPaneClosesIt() async throws {
  _ = NSApplication.shared
  let suite = "AsterShellExitTests.live.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let keptPane = tab.activePaneID
  model.splitSelectedTab(.right)
  let exitingPane = tab.activePaneID
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.contentViewController = controller
  window.makeKeyAndOrderFront(nil)
  defer { window.orderOut(nil) }
  window.layoutIfNeeded()

  // 等聚焦 Pane 的 Shell 真正起来，否则键入会落进还没就绪的 PTY。
  let session = try #require(tab.runtime(for: exitingPane)?.terminalSession)
  for _ in 0..<300 where session.lifecycleState != .running {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(session.lifecycleState == .running)
  // 不带参数的 exit 会沿用上一条命令的状态码（测试环境里常是非零），所以要等过
  // 非零退出码的最短运行时长；这段时间也足够 Shell 读完 rc 进入行编辑。
  let settle = TerminalProcessTermination.minimumUptimeForNonZeroAutoClose + 0.5
  try await Task.sleep(for: .milliseconds(Int(settle * 1_000)))
  session.send("exit")

  await waitUntil { tab.layout.allPanes.count == 1 }
  #expect(tab.layout.allPanes.map(\.id) == [keptPane])
  #expect(tab.activePaneID == keptPane)
}
