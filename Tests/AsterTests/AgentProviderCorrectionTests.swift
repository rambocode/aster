// 标题弱证据识别出错时的纠正：hook 上报与前台进程 argv 都能改正 provider。

import AsterCore
import Foundation
import Testing

@testable import Aster

@MainActor
private func makeSession() throws -> (TerminalSession, AsterTerminalView, () -> Void) {
  let suiteName = "AgentProviderCorrectionTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  let preferences = AppPreferences(defaults: defaults)
  let session = TerminalSession(workingDirectory: "/tmp")
  // 默认读不到前台 argv，避免测试读到宿主进程树。
  session.foregroundCommandArgumentsOverride = { nil }
  let view = try #require(session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  return (session, view, {
    session.stop(immediately: true)
    defaults.removePersistentDomain(forName: suiteName)
  })
}

/// 模拟 Shell integration 报告前台命令开始。
@MainActor
private func startCommand(_ view: AsterTerminalView, _ command: String) {
  view.dataReceived(
    slice: Array("\u{1B}]133;A\u{07}\u{1B}]133;B\u{07}\(command)\u{1B}]133;C\u{07}".utf8)[...])
}

/// 轮询等待条件成立，最多 `timeout`。
@MainActor
private func waitUntil(
  _ timeout: Duration = .seconds(3), _ condition: @MainActor () -> Bool
) async throws {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while !condition(), ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
}

@Test("标题误判成 Claude 后，Codex hook 能纠正 provider")
@MainActor
func codexHookCorrectsTitleEvidenceClaude() async throws {
  let (session, view, cleanup) = try makeSession()
  defer { cleanup() }
  startCommand(view, "cx")
  try await waitUntil { session.hasRunningCommand }
  view.onObservedTitleUpdate?(0, "✳ Claude Code")
  try await waitUntil { session.activeAgentProvider != nil }
  #expect(session.activeAgentProvider == .claudeCode)

  session.receiveAgentTerminalDirective(
    AgentTerminalDirective(provider: .codex, signal: .processing, sessionID: "codex-1"))
  #expect(session.activeAgentProvider == .codex)
  #expect(session.activeAgentSessionID == "codex-1")
}

@Test("hook 已精确建立的 provider 不被其它 provider 的 hook 改写")
@MainActor
func exactProviderRejectsForeignHook() async throws {
  let (session, view, cleanup) = try makeSession()
  defer { cleanup() }
  startCommand(view, "cx")
  try await waitUntil { session.hasRunningCommand }
  session.receiveAgentTerminalDirective(
    AgentTerminalDirective(provider: .claudeCode, signal: .processing, sessionID: "claude-1"))
  session.receiveAgentTerminalDirective(
    AgentTerminalDirective(provider: .codex, signal: .processing, sessionID: "codex-1"))
  #expect(session.activeAgentProvider == .claudeCode)
  #expect(session.activeAgentSessionID == "claude-1")
}

@Test("首词识别不了时按前台进程 argv 识别，并纠正标题弱证据")
@MainActor
func foregroundArgvIdentifiesAndCorrectsProvider() async throws {
  let (session, view, cleanup) = try makeSession()
  defer { cleanup() }
  session.foregroundCommandArgumentsOverride = { ["node", "/opt/homebrew/bin/codex"] }
  startCommand(view, "cx")
  try await waitUntil { session.hasRunningCommand }
  // 标题先到，给出错误的弱证据；随后 argv 探测改正它。
  view.onObservedTitleUpdate?(0, "✳ Claude Code")
  try await waitUntil { session.activeAgentProvider == .codex }
  #expect(session.activeAgentProvider == .codex)

  // 改正后是精确识别：Codex 的盲文 spinner 标题不会再撤销它。
  view.onObservedTitleUpdate?(0, "⠙ tmp")
  try await Task.sleep(for: .milliseconds(50))
  #expect(session.activeAgentProvider == .codex)
}

@Test("Codex 的盲文 spinner 标题不会被识别成 Claude")
@MainActor
func codexSpinnerTitleIsNotClaude() async throws {
  let (session, view, cleanup) = try makeSession()
  defer { cleanup() }
  startCommand(view, "cx")
  try await waitUntil { session.hasRunningCommand }
  view.onObservedTitleUpdate?(0, "⠙ tmp")
  try await Task.sleep(for: .milliseconds(50))
  #expect(session.activeAgentProvider == nil)
}

@Test("KERN_PROCARGS2 解析：跳过可执行路径与填充，只取 argc 个参数")
func processArgumentsParseSkipsExecutablePath() {
  var buffer = withUnsafeBytes(of: Int32(2)) { Array($0) }
  buffer += Array("/usr/local/bin/node".utf8) + [0, 0, 0]
  buffer += Array("node".utf8) + [0] + Array("/opt/codex".utf8) + [0]
  buffer += Array("PATH=/bin".utf8) + [0]
  #expect(ProcessArgumentsReader.parse(buffer) == ["node", "/opt/codex"])
  #expect(ProcessArgumentsReader.parse([]) == nil)
}

@Test("读取本进程 argv 与 CommandLine 一致")
func processArgumentsReadsOwnProcess() {
  let arguments = ProcessArgumentsReader.arguments(of: getpid())
  #expect(arguments?.first == CommandLine.arguments.first)
  #expect(ProcessArgumentsReader.arguments(of: -1) == nil)
}
