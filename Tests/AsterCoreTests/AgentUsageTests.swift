import Foundation
import Testing

@testable import AsterCore

@Suite("AgentUsage")
struct AgentUsageTests {
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

  @Test("Claude 账号配额解析：/usage 响应的百分比与 ISO 8601 重置时间，凭据过期返回 nil")
  func claudeAccountQuotaParsing() throws {
    let response = #"""
      {"five_hour":{"utilization":18.0,"resets_at":"2026-09-06T06:59:59.860820+00:00"},
       "seven_day":{"utilization":11.0,"resets_at":"2026-09-07T10:59:59+00:00"},
       "seven_day_opus":null}
      """#.data(using: .utf8)!
    let windows = try #require(ClaudeAccountQuotaParser.windows(fromUsageResponse: response))
    #expect(windows.map(\.kind) == [.fiveHour, .weekly])
    #expect(windows.map(\.usedPercent) == [18, 11])
    #expect(windows[0].resetsAt.map { Int($0.timeIntervalSince1970) } == 1_788_677_999)
    #expect(windows[1].resetsAt.map { Int($0.timeIntervalSince1970) } == 1_788_778_799)
    #expect(ClaudeAccountQuotaParser.windows(fromUsageResponse: Data("{}".utf8)) == nil)
    #expect(ClaudeAccountQuotaParser.windows(fromUsageResponse: Data("nope".utf8)) == nil)

    // 模型级周配额只在 limits 数组里（顶层 seven_day_opus / seven_day_sonnet 已恒为 null）。
    let scopedResponse = #"""
      {"five_hour":{"utilization":23.0,"resets_at":"2026-09-06T06:59:59.627986+00:00"},
       "seven_day":{"utilization":12.0,"resets_at":"2026-09-07T10:59:59.628019+00:00"},
       "seven_day_opus":null,"seven_day_sonnet":null,
       "limits":[
         {"kind":"session","group":"session","percent":23,"resets_at":"2026-09-06T06:59:59.627986+00:00","scope":null,"is_active":true},
         {"kind":"weekly_all","group":"weekly","percent":12,"resets_at":"2026-09-07T10:59:59.628019+00:00","scope":null,"is_active":false},
         {"kind":"weekly_scoped","group":"weekly","percent":20,"resets_at":"2026-09-07T10:59:59.628223+00:00","scope":{"model":{"id":null,"display_name":"Fable"},"surface":null},"is_active":false}]}
      """#.data(using: .utf8)!
    let scoped = try #require(ClaudeAccountQuotaParser.windows(fromUsageResponse: scopedResponse))
    #expect(scoped.map(\.kind) == [.fiveHour, .weekly, .modelWeekly])
    #expect(scoped.map(\.usedPercent) == [23, 12, 20])
    #expect(scoped[2].displayLabel == "Fable")
    #expect(scoped[2].resetsAt.map { Int($0.timeIntervalSince1970) } == 1_788_778_799)
    #expect(scoped[0].displayLabel == "5h")

    // 没有 weekly_scoped、或 scope 缺模型名时不产出模型窗口。
    let noScope = #"""
      {"five_hour":{"utilization":1.0},
       "limits":[{"kind":"weekly_scoped","percent":20,"scope":{"model":{"display_name":""}}},
                 {"kind":"weekly_all","percent":12,"scope":null}]}
      """#.data(using: .utf8)!
    #expect(try #require(ClaudeAccountQuotaParser.windows(fromUsageResponse: noScope)).map(\.kind) == [.fiveHour])

    let now = Date(timeIntervalSince1970: 1_788_000_000)
    let valid = #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1788000001000}}"#.data(using: .utf8)!
    let expired = #"{"claudeAiOauth":{"accessToken":"tok","expiresAt":1787999999000}}"#.data(using: .utf8)!
    let flat = #"{"accessToken":"tok2"}"#.data(using: .utf8)!
    #expect(ClaudeAccountQuotaParser.accessToken(fromCredentials: valid, now: now) == "tok")
    #expect(ClaudeAccountQuotaParser.accessToken(fromCredentials: expired, now: now) == nil)
    #expect(ClaudeAccountQuotaParser.accessToken(fromCredentials: flat, now: now) == "tok2")
    #expect(ClaudeAccountQuotaParser.accessToken(fromCredentials: Data("{}".utf8), now: now) == nil)
  }

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
