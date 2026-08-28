import AppKit
import Testing

@testable import Aster
@testable import AsterCore
@testable import SwiftTerm

// 覆盖「TUI 持续输出」场景的回归回路：上滚视口保持、标题风暴不重建工作区、
// running spinner 不被重复重建、快照不随标题逐次落盘。
// 工作区级测试必须是 async 并用 Task.sleep 挂起：标题链路经 MainActor Task 转发，
// 同步测试体内 RunLoop.run 无法让这些任务获得执行机会。

/// 构造带 12 行历史的独立终端视图（无 PTY），复用 TerminalScrollTests 的做法。
@MainActor
private func populatedStreamingView() -> AsterTerminalView {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 20, rows: 4)
  for index in 0..<12 {
    view.dataReceived(slice: Array("line-\(index)\r\n".utf8)[...])
  }
  return view
}

/// 独立 defaults suite，避免污染 .standard；与 AppKitMigrationTests 保持一致。
@MainActor
private func isolatedDefaults() -> UserDefaults {
  let suite = "TerminalOutputStormTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

/// 装配完整工作区窗口的测试夹具，统一负责 PTY 清理。
@MainActor
private struct WorkspaceFixture {
  let model: AppModel
  let preferences: AppPreferences
  let controller: WorkspaceViewController
  let window: NSWindow
  let defaults: UserDefaults

  init() {
    defaults = isolatedDefaults()
    model = AppModel(defaults: defaults)
    preferences = AppPreferences(defaults: defaults)
    model.ensureInitialTab()
    controller = WorkspaceViewController(model: model, preferences: preferences)
    window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
      styleMask: [.titled, .resizable],
      backing: .buffered,
      defer: false
    )
    window.contentViewController = controller
    window.layoutIfNeeded()
  }

  var terminal: AsterTerminalView? {
    controller.view.descendantViews.compactMap { $0 as? AsterTerminalView }.first
  }

  func tearDown() {
    for tab in model.tabs {
      for runtime in tab.runtimes.values {
        runtime.terminalSession?.stop(immediately: true)
      }
    }
    window.orderOut(nil)
  }
}

@Test("持续输出期间保持用户上滚的视口")
@MainActor
func streamingOutputPreservesUserScrollPosition() {
  let view = populatedStreamingView()
  let buffer = view.getTerminal().displayBuffer
  view.pageUp()
  let held = buffer.yDisp
  #expect(held < max(0, buffer.lines.count - buffer.rows))

  // 模拟 TUI/命令持续输出：视口必须停在用户正在查看的位置，不被拉回底部。
  for index in 0..<20 {
    view.dataReceived(slice: Array("stream-\(index)\r\n".utf8)[...])
  }
  #expect(buffer.yDisp == held)
}

@Test("视口在底部时新输出继续跟随最新内容")
@MainActor
func streamingOutputFollowsBottomWhenNotScrolledUp() {
  let view = populatedStreamingView()
  let buffer = view.getTerminal().displayBuffer
  view.scrollToBottom()

  for index in 0..<20 {
    view.dataReceived(slice: Array("tail-\(index)\r\n".utf8)[...])
  }
  #expect(buffer.yDisp == max(0, buffer.lines.count - buffer.rows))
}

@Test("高频 OSC 标题更新不重建工作区视图树")
@MainActor
func titleStormDoesNotRebuildWorkspace() async throws {
  let fixture = WorkspaceFixture()
  defer { fixture.tearDown() }
  try await Task.sleep(for: .milliseconds(80))

  let root = try #require(fixture.controller.view.subviews.first)
  let terminal = try #require(fixture.terminal)
  fixture.window.makeFirstResponder(terminal)

  // Agent CLI（Claude Code / codex）每秒多次经 OSC 0/2 更新标题；工作区不能因此整树重建，
  // 否则其他 Pane 的输入、IME 组合与滚动都会被打断。
  for index in 0..<8 {
    terminal.dataReceived(slice: Array("\u{1B}]0;job-\(index)\u{07}".utf8)[...])
    try await Task.sleep(for: .milliseconds(20))
  }

  #expect(fixture.controller.view.subviews.first === root)
  #expect(fixture.window.firstResponder === terminal)
}

@Test("单个 Pane 的命令开始/结束不重建工作区，其余 Pane 保持独立")
@MainActor
func commandLifecycleDoesNotRebuildWorkspace() async throws {
  let fixture = WorkspaceFixture()
  defer { fixture.tearDown() }
  fixture.model.splitSelectedTab(.right)
  try await Task.sleep(for: .milliseconds(80))

  let root = try #require(fixture.controller.view.subviews.first)
  let terminals = fixture.controller.view.descendantViews.compactMap { $0 as? AsterTerminalView }
  #expect(terminals.count == 2)
  let first = try #require(terminals.first)

  // 一个 Pane 里跑命令：OSC 133 C/D 会翻转 hasRunningCommand。徽章、Dock 与详情
  // 面板各有专用通道,不允许借 objectWillChange 重建整个工作区——那会让其余
  // Pane 的终端视图被重新安放,表现为“别的 Pane 也在刷新”。
  for index in 0..<6 {
    first.dataReceived(
      slice: Array("\u{1B}]133;A\u{07}\u{1B}]133;B\u{07}cmd-\(index)\u{1B}]133;C\u{07}".utf8)[...])
    try await Task.sleep(for: .milliseconds(15))
    first.dataReceived(slice: Array("out\r\n\u{1B}]133;D;0\u{07}".utf8)[...])
    try await Task.sleep(for: .milliseconds(15))
  }

  #expect(fixture.controller.view.subviews.first === root)
  let terminalsAfter = fixture.controller.view.descendantViews.compactMap {
    $0 as? AsterTerminalView
  }
  #expect(terminalsAfter.count == 2)
  #expect(terminalsAfter.allSatisfy { after in terminals.contains { $0 === after } })
}

@Test("标题风暴期间快照不逐次落盘")
@MainActor
func titleStormDoesNotPersistSnapshotPerUpdate() async throws {
  let fixture = WorkspaceFixture()
  defer { fixture.tearDown() }
  try await Task.sleep(for: .milliseconds(80))
  let terminal = try #require(fixture.terminal)

  let snapshotKey = "aster.workspace.snapshot.v1"
  var writeIterations = 0
  var lastSnapshot = fixture.defaults.data(forKey: snapshotKey)
  for index in 0..<8 {
    terminal.dataReceived(slice: Array("\u{1B}]0;spin-\(index)\u{07}".utf8)[...])
    try await Task.sleep(for: .milliseconds(20))
    let current = fixture.defaults.data(forKey: snapshotKey)
    if current != lastSnapshot {
      writeIterations += 1
      lastSnapshot = current
    }
  }
  // 允许合并后的一次延迟写入，但绝不能每次标题变化都同步编码整个工作区快照。
  #expect(writeIterations <= 2)
}

@Test("running 徽章重复刷新时复用同一个 spinner")
@MainActor
func activityBadgeRefreshReusesSpinner() async throws {
  let fixture = WorkspaceFixture()
  defer { fixture.tearDown() }
  try await Task.sleep(for: .milliseconds(80))

  let terminal = try #require(fixture.terminal)
  // OSC 9;4;3（indeterminate）把活动 Pane 置为 running，驱动侧栏 spinner。
  terminal.dataReceived(slice: Array("\u{1B}]9;4;3\u{07}".utf8)[...])
  try await Task.sleep(for: .milliseconds(80))

  let rows = fixture.controller.view.descendantViews.compactMap { $0 as? TabRowButton }
  let spinnerRow = try #require(
    rows.first { row in
      row.refreshActivityBadge()
      return row.descendantViews.contains { $0 is TabActivitySpinnerView }
    },
    "侧栏必须存在带 running spinner 的标签行"
  )
  let first = try #require(
    spinnerRow.descendantViews.compactMap { $0 as? TabActivitySpinnerView }.first
  )
  spinnerRow.refreshActivityBadge()
  let second = try #require(
    spinnerRow.descendantViews.compactMap { $0 as? TabActivitySpinnerView }.first
  )
  // 状态未变化时必须复用同一 spinner；重建会不断重启动画，看起来像“转得飞快”。
  #expect(first === second)
}

extension NSView {
  /// 递归子视图；供本文件内的结构断言使用。
  fileprivate var descendantViews: [NSView] {
    subviews.flatMap { [$0] + $0.descendantViews }
  }
}
