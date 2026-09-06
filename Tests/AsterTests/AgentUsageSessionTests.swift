import AppKit
import Combine
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// Agent 用量条的数据链路：OSC 6974 AgentUsage → TerminalSession.agentUsage；Codex 走 rollout 文件监听。

@Test("用量 directive 发布到 session，命令结束后清空")
@MainActor
func sessionPublishesUsageFromDirectiveAndClearsOnCommandFinished() throws {
  let (suiteName, defaults) = try agentUsageDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  let session = TerminalSession(workingDirectory: "/tmp")
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  defer { session.stop(immediately: true) }

  var published: [AgentUsageSnapshot?] = []
  let subscription = session.$agentUsage.dropFirst().sink { published.append($0) }
  defer { subscription.cancel() }

  let directive = try #require(AgentUsageDirective(
    payload: "AgentUsage=1;Provider=claudeCode;FiveHour=42:1788748005;SevenDay=13;Session=57"))
  terminalView.onAgentUsageDirective?(directive)
  #expect(session.agentUsage?.window(.fiveHour)?.usedPercent == 42)
  // wrapper 命令让 commandStart 认不出 claude 时，用量 directive 建立 provider 身份。
  #expect(session.activeAgentProvider == .claudeCode)

  // 同值不重复发布；lifecycle idle 不清用量。
  terminalView.onAgentUsageDirective?(directive)
  terminalView.onAgentTerminalDirective?(AgentTerminalDirective(provider: .claudeCode, signal: .idle))
  #expect(published.count == 1)
  #expect(session.agentUsage != nil)

  // 外来 provider 的用量被拒绝。
  terminalView.onAgentUsageDirective?(
    try #require(AgentUsageDirective(payload: "AgentUsage=1;Provider=codex;Session=1")))
  #expect(session.agentUsage?.provider == .claudeCode)

  terminalView.onShellIntegrationEvent?(.commandFinished(exitStatus: 0))
  #expect(session.agentUsage == nil)
  #expect(published.last == .some(nil))
}

@Test("用量变化不触发 TerminalTabItem 的 objectWillChange")
@MainActor
func usageChangesDoNotTriggerTabObjectWillChange() throws {
  let (suiteName, defaults) = try agentUsageDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  defer {
    for runtime in tab.runtimes.values { runtime.terminalSession?.stop(immediately: true) }
  }

  var tabChanges = 0
  let subscription = tab.objectWillChange.sink { _ in tabChanges += 1 }
  defer { subscription.cancel() }
  terminalView.onAgentUsageDirective?(
    try #require(AgentUsageDirective(payload: "AgentUsage=1;Provider=claudeCode;FiveHour=10")))
  terminalView.onAgentUsageDirective?(
    try #require(AgentUsageDirective(payload: "AgentUsage=1;Provider=claudeCode;FiveHour=11")))
  #expect(session.agentUsage?.window(.fiveHour)?.usedPercent == 11)
  #expect(tabChanges == 0)
}

@Test("Codex 绑定 session 后读取 rollout 尾部，追加时更新，provider 结束后停止")
@MainActor
func codexMonitorReadsRolloutTailAfterAppend() async throws {
  let (suiteName, defaults) = try agentUsageDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-usage-home-\(UUID().uuidString)", isDirectory: true)
  let day = home.appendingPathComponent(".codex/sessions/2026/09/06", isDirectory: true)
  try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: home) }
  let sessionID = "01a04237-0000-4000-8000-000000000001"
  let rollout = day.appendingPathComponent("rollout-2026-09-06T10-00-00-\(sessionID).jsonl")
  try #"{"type":"session_meta","payload":{"id":"\#(sessionID)"}}"#.appending("\n")
    .write(to: rollout, atomically: true, encoding: .utf8)

  let session = TerminalSession(workingDirectory: "/tmp")
  session.agentUsageHomeDirectory = home
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  defer { session.stop(immediately: true) }
  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .idle, sessionID: sessionID))
  #expect(session.activeAgentSessionID == sessionID)

  let line = #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":400,"reasoning_output_tokens":0},"model_context_window":1000},"rate_limits":{"primary":{"used_percent":52,"window_minutes":10080,"resets_at":1788748005},"secondary":null}}}"#
  // 等定位任务先跑完（目录枚举在后台），再追加，验证监听而不是首读。
  try await Task.sleep(for: .milliseconds(400))
  let handle = try FileHandle(forWritingTo: rollout)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data((line + "\n").utf8))
  try handle.close()

  var observed: AgentUsageSnapshot?
  for _ in 0..<40 where observed == nil {
    try await Task.sleep(for: .milliseconds(100))
    observed = session.agentUsage
  }
  let snapshot = try #require(observed)
  #expect(snapshot.provider == .codex)
  #expect(snapshot.window(.weekly)?.usedPercent == 52)
  #expect(snapshot.window(.session)?.usedPercent == 40)
  #expect(snapshot.window(.fiveHour) == nil)

  terminalView.onShellIntegrationEvent?(.commandFinished(exitStatus: 0))
  #expect(session.agentUsage == nil)
  let monitor = Mirror(reflecting: session).children.first { $0.label == "codexUsageMonitor" }?.value
  #expect(monitor.map { Mirror(reflecting: $0).displayStyle == .optional && String(describing: $0) == "nil" } ?? true)
}

private func agentUsageDefaults() throws -> (String, UserDefaults) {
  let suiteName = "AgentUsageSessionTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  return (suiteName, defaults)
}
