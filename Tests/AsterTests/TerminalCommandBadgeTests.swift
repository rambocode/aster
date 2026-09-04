import AppKit
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 回归：失败命令留下的 `.finished(exitCode: 1)` 曾经跨命令残留，导致下一条成功命令
/// 的完成状态被 commandFinished 里的「OSC 9;4;5 已报完成」guard 提前 return 掉。
/// 结果是侧栏/标签栏拿着旧的 error 进度状态、却渲染最新的退出码 0，显示红色的 "0"。
@Test("失败命令后的成功命令刷新进度状态且不再残留 error 徽章")
@MainActor
func successfulCommandClearsPreviousFailureBadge() throws {
  let suiteName = "TerminalCommandBadgeTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let preferences = AppPreferences(defaults: defaults)
  let session = TerminalSession(workingDirectory: "/tmp")
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  defer { session.stop(immediately: true) }

  // 整个用例保持同步：dataReceived 同步解析 OSC，其间不 await，真实 PTY 输出无法插队。
  let failing =
    "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}false\r\n"
    + "\u{1B}]133;C\u{7}\u{1B}]133;D;1\u{7}"
  terminalView.dataReceived(slice: Array(failing.utf8)[...])

  #expect(session.progressState == .finished(exitCode: 1, watched: false))
  #expect(session.progressState.reportsError)
  #expect(session.lastCommandExitStatus == 1)

  let succeeding =
    "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}true\r\n"
    + "\u{1B}]133;C\u{7}\u{1B}]133;D;0\u{7}"
  terminalView.dataReceived(slice: Array(succeeding.utf8)[...])

  #expect(session.progressState == .finished(exitCode: 0, watched: false))
  #expect(!session.progressState.reportsError)
  #expect(session.lastCommandExitStatus == 0)
}
