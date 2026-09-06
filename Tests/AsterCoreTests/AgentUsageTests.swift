import Foundation
import Testing

@testable import AsterCore

@Suite("AgentUsage")
struct AgentUsageTests {
  @Test("用量 directive 解析三个窗口并把 epoch 转成 Date")
  func agentUsageDirectiveParsesAllThreeWindows() throws {
    let directive = try #require(AgentUsageDirective(
      payload: "AgentUsage=1;Provider=claudeCode;FiveHour=42:1788748005;SevenDay=13:1788900000;Session=57"))
    #expect(directive.provider == .claudeCode)
    let snapshot = directive.snapshot()
    #expect(snapshot.windows.map(\.kind) == [.fiveHour, .weekly, .session])
    #expect(snapshot.window(.fiveHour)?.usedPercent == 42)
    #expect(snapshot.window(.fiveHour)?.resetsAt == Date(timeIntervalSince1970: 1_788_748_005))
    #expect(snapshot.window(.weekly)?.usedPercent == 13)
    #expect(snapshot.window(.session)?.usedPercent == 57)
    #expect(snapshot.window(.session)?.resetsAt == nil)
  }

  @Test("用量 directive 接受部分窗口与缺省 epoch")
  func agentUsageDirectiveAcceptsPartialWindowsAndMissingReset() throws {
    let sessionOnly = try #require(AgentUsageDirective(payload: "AgentUsage=1;Provider=codex;Session=57"))
    #expect(sessionOnly.windows.map(\.kind) == [.session])
    let noEpoch = try #require(AgentUsageDirective(payload: "Provider=claudeCode;FiveHour=42;AgentUsage=1"))
    #expect(noEpoch.windows.first?.resetsAt == nil)
    #expect(noEpoch.windows.first?.usedPercent == 42)
    // 超 100 保留（spend_limit 可超限），但钳制在上限内。
    let over = try #require(AgentUsageDirective(payload: "AgentUsage=1;Provider=claudeCode;FiveHour=120"))
    #expect(over.windows.first?.usedPercent == 120)
  }

  @Test("用量 directive 拒绝未知键、重复键、坏值与超限载荷")
  func agentUsageDirectiveRejectsUnknownKeysDuplicatesAndBadValues() {
    let rejected = [
      "AgentUsage=1;Provider=claudeCode;Prompt=x;FiveHour=1",
      "AgentUsage=1;Provider=claudeCode;FiveHour=1;FiveHour=2",
      "AgentUsage=1;Provider=claudeCode;FiveHour=abc",
      "AgentUsage=1;Provider=claudeCode;FiveHour=42:notanumber",
      "AgentUsage=1;Provider=claudeCode;FiveHour=1234",
      "AgentUsage=1;Provider=claudeCode;FiveHour=42:1234567890123",
      "AgentUsage=2;Provider=claudeCode;FiveHour=1",
      "AgentUsage=1;Provider=unknown;FiveHour=1",
      "AgentUsage=1;Provider=claudeCode",
      "AgentUsage=1;Provider=claudeCode;FiveHour=",
      "AgentUsage=1;Provider=claudeCode;FiveHour=4２",
      "AgentUsage=1;Provider=claudeCode;FiveHour=1;" + String(repeating: "x", count: 300),
    ]
    for payload in rejected {
      #expect(AgentUsageDirective(payload: payload) == nil, "\(payload)")
    }
  }

  @Test("用量 directive 与 lifecycle directive 互斥，接收顺序无关")
  func agentUsageDirectiveIsNotMistakenForLifecycleDirective() {
    let usage = "AgentUsage=1;Provider=claudeCode;FiveHour=42"
    let lifecycle = "AgentState=idle;Provider=claudeCode"
    #expect(AgentTerminalDirective(payload: usage) == nil)
    #expect(AgentUsageDirective(payload: lifecycle) == nil)
    #expect(AgentUsageDirective(payload: usage) != nil)
    #expect(AgentTerminalDirective(payload: lifecycle) != nil)
  }

  @Test("快照按 kind 排序去重，且相等比较忽略 updatedAt")
  func agentUsageSnapshotSortsWindowsByKindAndIgnoresTimestamp() throws {
    let session = try #require(AgentUsageWindow(kind: .session, usedPercent: 10))
    let weekly = try #require(AgentUsageWindow(kind: .weekly, usedPercent: 20))
    let weeklyDuplicate = try #require(AgentUsageWindow(kind: .weekly, usedPercent: 99))
    let a = AgentUsageSnapshot(provider: .codex, windows: [session, weekly, weeklyDuplicate], updatedAt: Date(timeIntervalSince1970: 1))
    let b = AgentUsageSnapshot(provider: .codex, windows: [weekly, session], updatedAt: Date(timeIntervalSince1970: 2))
    #expect(a.windows.map(\.kind) == [.weekly, .session])
    #expect(a.window(.weekly)?.usedPercent == 20)
    #expect(a == b)
    #expect(AgentUsageWindow(kind: .session, usedPercent: .nan) == nil)
    #expect(AgentUsageWindow(kind: .session, usedPercent: -5)?.usedPercent == 0)
  }

  // MARK: - Codex rollout

  private static func tokenCountLine(
    primary: String = "null", secondary: String = "null",
    total: Int = 529_527, reasoning: Int = 100_000, contextWindow: Int = 828_400
  ) -> String {
    """
    {"timestamp":"2026-09-06T02:58:54.072Z","ordinal":65235,"type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":0,"total_tokens":2},"last_token_usage":{"input_tokens":1,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":1,"reasoning_output_tokens":\(reasoning),"total_tokens":\(total)},"model_context_window":\(contextWindow)},"rate_limits":{"limit_id":"codex","limit_name":null,"primary":\(primary),"secondary":\(secondary),"credits":{"has_credits":false,"unlimited":false,"balance":"0"},"individual_limit":null,"spend_control_reached":null,"plan_type":"pro","rate_limit_reached_type":null}}}
    """
  }

  private static let weeklyPrimary = #"{"used_percent":52.0,"window_minutes":10080,"resets_at":1788748005}"#
  private static let fiveHourWindow = #"{"used_percent":7.5,"window_minutes":300,"resets_at":1788700000}"#

  @Test("Codex rollout 解析最后一条 token_count：primary=周窗口且 secondary=null")
  func codexRolloutParserReadsLastTokenCountWithWeeklyPrimaryAndNullSecondary() throws {
    let lines = [
      #"{"type":"session_meta","payload":{"id":"abc"}}"#,
      Self.tokenCountLine(primary: #"{"used_percent":2.0,"window_minutes":10080,"resets_at":1}"#),
      #"{"type":"response_item","payload":{"type":"reasoning"}}"#,
      Self.tokenCountLine(primary: Self.weeklyPrimary),
      #"{"type":"event_msg","payload":{"type":"item_completed"}}"#,
    ]
    let snapshot = try #require(CodexRolloutUsageParser.parse(tail: Data((lines.joined(separator: "\n") + "\n").utf8)))
    #expect(snapshot.provider == .codex)
    #expect(snapshot.windows.map(\.kind) == [.weekly, .session])
    #expect(snapshot.window(.weekly)?.usedPercent == 52)
    #expect(snapshot.window(.weekly)?.resetsAt == Date(timeIntervalSince1970: 1_788_748_005))
    // (529527 - 100000) / 828400 ≈ 51.85%
    let session = try #require(snapshot.window(.session))
    #expect(abs(session.usedPercent - 51.85) < 0.05)
    #expect(session.detail == "429527 / 828400 tokens")
  }

  @Test("Codex rollout 按 window_minutes 归类，与槽位无关")
  func codexRolloutParserMapsWindowMinutesRegardlessOfSlot() throws {
    let a = try #require(CodexRolloutUsageParser.parse(
      tail: Data(Self.tokenCountLine(primary: Self.fiveHourWindow, secondary: Self.weeklyPrimary).utf8)))
    let b = try #require(CodexRolloutUsageParser.parse(
      tail: Data(Self.tokenCountLine(primary: Self.weeklyPrimary, secondary: Self.fiveHourWindow).utf8)))
    #expect(a.windows.map(\.kind) == [.fiveHour, .weekly, .session])
    #expect(a.windows.map(\.kind) == b.windows.map(\.kind))
    #expect(a.window(.fiveHour)?.usedPercent == 7.5)
    // 未知窗口长度忽略。
    let unknown = try #require(CodexRolloutUsageParser.parse(
      tail: Data(Self.tokenCountLine(primary: #"{"used_percent":1,"window_minutes":60}"#).utf8)))
    #expect(unknown.windows.map(\.kind) == [.session])
  }

  @Test("Codex rollout 跳过不完整尾行与坏 JSON，上下文窗口为 0 时不产出会话占比")
  func codexRolloutParserSkipsTruncatedTrailingLineAndMalformedJSON() throws {
    let good = Self.tokenCountLine(primary: Self.weeklyPrimary)
    let tail = "garbage{\n" + good + "\n" + #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":1},"model_context_window":100}},"rate_li"#
    let snapshot = try #require(CodexRolloutUsageParser.parse(tail: Data(tail.utf8)))
    #expect(snapshot.window(.weekly)?.usedPercent == 52)
    #expect(CodexRolloutUsageParser.parse(tail: Data("nothing here\n".utf8)) == nil)
    #expect(CodexRolloutUsageParser.parse(tail: Data()) == nil)
    let zero = CodexRolloutUsageParser.parse(tail: Data(Self.tokenCountLine(contextWindow: 0).utf8))
    #expect(zero == nil)
  }

  @Test("Planner 只对 Claude 且 statusLine 未接管时追加步骤，且该步骤不要求重启")
  func agentSetupPlannerAddsStatusLineStepOnlyForClaudeWhenNotManaged() {
    let claude = AgentSetupPlanner.plan(
      for: .claudeCode,
      evidence: AgentSetupEvidence(
        executableAvailable: true, managedIntegrationInstalled: true, managedStatusLineInstalled: false))
    #expect(claude.steps == [
      .manageStatusLine(
        path: AgentProvider.claudeStatusLineSettingsPath,
        sideFile: AgentProvider.claudeStatusLineSideFilePath)
    ])
    #expect(!claude.requiresAgentRestart)

    let fresh = AgentSetupPlanner.plan(
      for: .claudeCode,
      evidence: AgentSetupEvidence(
        executableAvailable: true, managedIntegrationInstalled: false, managedStatusLineInstalled: false))
    #expect(fresh.steps.count == 2)
    #expect(fresh.requiresAgentRestart)

    let notApplicable = AgentSetupPlanner.plan(
      for: .claudeCode,
      evidence: AgentSetupEvidence(executableAvailable: true, managedIntegrationInstalled: true))
    #expect(notApplicable.steps.isEmpty)
    let codex = AgentSetupPlanner.plan(
      for: .codex,
      evidence: AgentSetupEvidence(
        executableAvailable: true, managedIntegrationInstalled: true, requiredFeatureEnabled: true,
        managedStatusLineInstalled: false))
    #expect(codex.steps.isEmpty)
  }

  @Test("用量条配置缺键时默认开启")
  func agentConfigurationUsageBarDefaultsToEnabled() throws {
    // 旧配置文件没有 usageBarEnabled 键：解码后应视为开启。
    let legacy = Data("""
      {"enabledAgents":["claude"],"badgeProcessing":true,"badgeTaskComplete":true,"badgeAwaitingInput":true,\
      "notifyTaskComplete":true,"notifyAwaitingInput":true,"preventSleepWhileProcessing":false,"resumeSessions":true}
      """.utf8)
    let decoded = try JSONDecoder().decode(AgentConfiguration.self, from: legacy)
    #expect(decoded.usageBarEnabled == nil)
    #expect(decoded.resolvedUsageBarEnabled)
    #expect(AgentConfiguration().resolvedUsageBarEnabled)
    var disabled = decoded
    disabled.usageBarEnabled = false
    #expect(!disabled.resolvedUsageBarEnabled)
  }
}
