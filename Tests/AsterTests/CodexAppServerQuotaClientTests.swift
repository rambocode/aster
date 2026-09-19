import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// `codex app-server` 的 `account/rateLimits/read` 响应解析。全部是纯函数，不起子进程。

/// 造一条 JSON-RPC 响应。`primary` / `secondary` 直接给 JSON 片段，方便测缺字段与 null。
private func rateLimitsResponse(primary: String, secondary: String = "null", planType: String = "\"pro\"") -> Data {
  Data(
    #"""
    {"id":2,"result":{"ordinaryUsageAllowed":false,"rateLimits":{"limitId":"codex","primary":\#(primary),"secondary":\#(secondary),"planType":\#(planType)}}}
    """#.utf8)
}

// 真机实测：本账号只有 primary，且它就是每周窗口（10080 分钟）。按 primary/secondary 的位置
// 猜种类会把「周配额 100%」显示成「5 小时配额 100%」，所以必须按时长判。
@Test("CodexAppServer: 只有 primary 且时长 10080 分钟时归为周窗口")
func codexAppServerMapsSolePrimaryWeeklyWindow() throws {
  let now = Date(timeIntervalSince1970: 1_789_800_000)
  let data = rateLimitsResponse(
    primary: #"{"usedPercent":100,"windowDurationMins":10080,"resetsAt":1789806350}"#)
  let windows = try #require(CodexAppServerQuotaClient.windows(fromRateLimitsResponse: data, now: now))
  #expect(windows.map(\.kind) == [.weekly])
  #expect(windows[0].usedPercent == 100)
  #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_789_806_350))
  #expect(CodexAppServerQuotaClient.planType(fromRateLimitsResponse: data) == "Pro")
}

@Test("CodexAppServer: primary 300 分钟 + secondary 10080 分钟分别归为 5 小时与每周")
func codexAppServerMapsBothWindowsByDuration() throws {
  let now = Date(timeIntervalSince1970: 1_789_800_000)
  let data = rateLimitsResponse(
    primary: #"{"usedPercent":7.5,"windowDurationMins":300,"resetsAt":1789806350}"#,
    secondary: #"{"usedPercent":52,"windowDurationMins":10080,"resetsAt":1789906350}"#)
  let windows = try #require(CodexAppServerQuotaClient.windows(fromRateLimitsResponse: data, now: now))
  #expect(windows.map(\.kind) == [.fiveHour, .weekly])
  #expect(windows.map(\.usedPercent) == [7.5, 52])

  // 位置对调结果必须一致：种类只由时长决定。
  let swapped = rateLimitsResponse(
    primary: #"{"usedPercent":52,"windowDurationMins":10080,"resetsAt":1789906350}"#,
    secondary: #"{"usedPercent":7.5,"windowDurationMins":300,"resetsAt":1789806350}"#)
  let swappedWindows = try #require(
    CodexAppServerQuotaClient.windows(fromRateLimitsResponse: swapped, now: now))
  #expect(swappedWindows.map(\.kind) == [.fiveHour, .weekly])
  #expect(swappedWindows.map(\.usedPercent) == [7.5, 52])
}

@Test("CodexAppServer: 字段缺失或类型不对的窗口被跳过，一个都没有返回 nil")
func codexAppServerSkipsMalformedWindows() throws {
  let now = Date(timeIntervalSince1970: 1_789_800_000)
  // primary 缺 windowDurationMins，secondary 完整：只剩一个窗口。
  let partial = rateLimitsResponse(
    primary: #"{"usedPercent":10}"#,
    secondary: #"{"usedPercent":52,"windowDurationMins":10080,"resetsAt":1789906350}"#)
  let windows = try #require(
    CodexAppServerQuotaClient.windows(fromRateLimitsResponse: partial, now: now))
  #expect(windows.map(\.kind) == [.weekly])

  // usedPercent 是字符串：整条跳过。两个槽位都不可用时返回 nil。
  let broken = rateLimitsResponse(
    primary: #"{"usedPercent":"100","windowDurationMins":10080}"#, secondary: "null")
  #expect(CodexAppServerQuotaClient.windows(fromRateLimitsResponse: broken, now: now) == nil)
  #expect(
    CodexAppServerQuotaClient.windows(
      fromRateLimitsResponse: rateLimitsResponse(primary: "null"), now: now) == nil)
}

// resetsAt 为 0 表示「没有重置时刻」，按字面转成 1970 年会被上层当成已过期。
@Test("CodexAppServer: resetsAt 为 0 或缺失时不带重置时间")
func codexAppServerIgnoresZeroResetsAt() throws {
  let now = Date(timeIntervalSince1970: 1_789_800_000)
  let data = rateLimitsResponse(
    primary: #"{"usedPercent":33,"windowDurationMins":10080,"resetsAt":0}"#)
  let windows = try #require(CodexAppServerQuotaClient.windows(fromRateLimitsResponse: data, now: now))
  #expect(windows[0].resetsAt == nil)

  let missing = rateLimitsResponse(primary: #"{"usedPercent":33,"windowDurationMins":300}"#)
  let missingWindows = try #require(
    CodexAppServerQuotaClient.windows(fromRateLimitsResponse: missing, now: now))
  #expect(missingWindows[0].kind == .fiveHour)
  #expect(missingWindows[0].resetsAt == nil)
}

// codex 太旧不认识这个方法时会回 JSON-RPC error；必须当失败走 rollout 兜底，而不是显示空数据。
@Test("CodexAppServer: error 响应、非法 JSON 与缺 rateLimits 一律返回 nil")
func codexAppServerRejectsErrorAndGarbage() throws {
  let now = Date(timeIntervalSince1970: 1_789_800_000)
  let error = Data(
    #"{"id":2,"error":{"code":-32601,"message":"Method not found"},"result":{"rateLimits":{"primary":{"usedPercent":1,"windowDurationMins":300}}}}"#
      .utf8)
  #expect(CodexAppServerQuotaClient.windows(fromRateLimitsResponse: error, now: now) == nil)
  #expect(CodexAppServerQuotaClient.planType(fromRateLimitsResponse: error) == nil)

  #expect(CodexAppServerQuotaClient.windows(fromRateLimitsResponse: Data("not json".utf8), now: now) == nil)
  #expect(CodexAppServerQuotaClient.windows(fromRateLimitsResponse: Data(), now: now) == nil)
  #expect(
    CodexAppServerQuotaClient.windows(
      fromRateLimitsResponse: Data(#"{"id":2,"result":{}}"#.utf8), now: now) == nil)
}

// 真机冒烟：真的起一次 `codex app-server`。默认不跑（要装了 codex、登录过、还得花几秒起
// Node），只在显式设 ASTER_CODEX_SMOKE=1 时执行，所以它不进常规测试套件。
@Test(
  "CodexAppServer: 真机冒烟，实际起 app-server 取一次配额",
  .enabled(if: ProcessInfo.processInfo.environment["ASTER_CODEX_SMOKE"] == "1"))
func codexAppServerLiveSmoke() throws {
  let result = try #require(
    CodexAppServerQuotaClient.latestWindows(
      homeDirectory: FileManager.default.homeDirectoryForCurrentUser, now: Date()))
  for window in result.windows {
    print("SMOKE window kind=\(window.kind) used=\(window.usedPercent) resetsAt=\(String(describing: window.resetsAt))")
  }
  print("SMOKE plan=\(String(describing: result.plan))")
  #expect(!result.windows.isEmpty)
}

@Test("CodexAppServer: planType 按下划线分段大写")
func codexAppServerPlanTypeSegments() throws {
  let window = #"{"usedPercent":1,"windowDurationMins":300}"#
  #expect(
    CodexAppServerQuotaClient.planType(
      fromRateLimitsResponse: rateLimitsResponse(primary: window, planType: "\"plus\"")) == "Plus")
  #expect(
    CodexAppServerQuotaClient.planType(
      fromRateLimitsResponse: rateLimitsResponse(primary: window, planType: "\"business_starter\""))
      == "Business Starter")
}

@Test("CodexAppServer: planType 缺失或为空时不显示档位")
func codexAppServerPlanTypeFallsBackToNil() throws {
  #expect(
    CodexAppServerQuotaClient.planType(
      fromRateLimitsResponse: rateLimitsResponse(
        primary: #"{"usedPercent":1,"windowDurationMins":300}"#, planType: "null")) == nil)
  #expect(
    CodexAppServerQuotaClient.planType(
      fromRateLimitsResponse: rateLimitsResponse(
        primary: #"{"usedPercent":1,"windowDurationMins":300}"#, planType: "\"\"")) == nil)
}
