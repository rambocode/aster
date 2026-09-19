import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// Antigravity 本地 language server 的响应解析与进程定位。全部用手写夹具，不依赖本机跑着服务。

/// 夹具基准时刻；`resetTime` 的可信区间以它为中心，所以所有夹具时间都围绕它取值。
private let referenceNow = Date(timeIntervalSince1970: 1_789_800_000)

@Suite("AntigravityQuota 配额解析")
struct AntigravityQuotaSummaryTests {
  /// 造一个 bucket 数组外壳；`shell` 决定顶层用哪种包装。
  private func summary(shell: String, groups: String) -> Data {
    switch shell {
    case "response": Data(#"{"code":"ok","response":{"groups":\#(groups)}}"#.utf8)
    case "summary": Data(#"{"code":"ok","summary":{"groups":\#(groups)}}"#.utf8)
    default: Data(#"{"code":"ok","groups":\#(groups)}"#.utf8)
    }
  }

  private let singleGroup = #"""
    [{"displayName":"Antigravity","buckets":[
      {"bucketId":"gemini-3-pro","displayName":"Gemini 3 Pro","remainingFraction":0.75,
       "resetTime":"2026-09-19T08:25:50Z"}]}]
    """#

  // 三种顶层壳子来自不同 agy 版本，必须都认；否则升级一次卡片就消失。
  @Test("Antigravity: response / summary / 顶层三种壳子都能解析")
  func parsesAllTopLevelShells() throws {
    for shell in ["response", "summary", "flat"] {
      let parsed = try #require(
        AntigravityQuotaClient.windows(
          fromQuotaSummary: summary(shell: shell, groups: singleGroup), now: referenceNow))
      #expect(parsed.windows.count == 1)
      #expect(parsed.windows[0].kind == .modelWeekly)
      #expect(parsed.windows[0].displayLabel == "Gemini 3 Pro")
    }
  }

  // remainingFraction 是**剩余**比例，面板要的是已用：0.75 剩余 == 25% 已用。
  @Test("Antigravity: remainingFraction 反算已用百分比")
  func convertsRemainingFractionToUsedPercent() throws {
    let parsed = try #require(
      AntigravityQuotaClient.windows(
        fromQuotaSummary: summary(shell: "response", groups: singleGroup), now: referenceNow))
    #expect(parsed.windows[0].usedPercent == 25)
    #expect(AntigravityQuotaClient.usedPercent(remainingFraction: 1) == 0)
    #expect(AntigravityQuotaClient.usedPercent(remainingFraction: 0) == 100)
    // 脏数据先夹紧到 0…1，否则会算出负百分比或超过 100。
    #expect(AntigravityQuotaClient.usedPercent(remainingFraction: 1.4) == 0)
    #expect(AntigravityQuotaClient.usedPercent(remainingFraction: -0.2) == 100)
  }

  // 新版本把 remainingFraction 包进了 oneof（`remaining`），两种形状都得认。
  @Test("Antigravity: remainingFraction 直接给或嵌在 remaining 里都能取到")
  func readsRemainingFractionFromBothShapes() throws {
    let nested = #"""
      [{"displayName":"Antigravity","buckets":[
        {"bucketId":"a","remaining":{"remainingFraction":0.4}}]}]
      """#
    let parsed = try #require(
      AntigravityQuotaClient.windows(
        fromQuotaSummary: summary(shell: "response", groups: nested), now: referenceNow))
    #expect(parsed.windows[0].usedPercent == 60)
    // 没有 displayName 时退到 bucketId。
    #expect(parsed.windows[0].displayLabel == "a")
  }

  @Test("Antigravity: disabled 的 bucket 被跳过")
  func skipsDisabledBuckets() throws {
    let groups = #"""
      [{"displayName":"Antigravity","buckets":[
        {"bucketId":"off","displayName":"Off","disabled":true,"remainingFraction":0.9},
        {"bucketId":"on","displayName":"On","disabled":false,"remainingFraction":0.9}]}]
      """#
    let parsed = try #require(
      AntigravityQuotaClient.windows(
        fromQuotaSummary: summary(shell: "response", groups: groups), now: referenceNow))
    #expect(parsed.windows.map(\.displayLabel) == ["On"])
  }

  @Test("Antigravity: resetTime 支持 ISO 字符串与 epoch 秒")
  func parsesBothResetTimeShapes() throws {
    let groups = #"""
      [{"displayName":"Antigravity","buckets":[
        {"bucketId":"iso","remainingFraction":0.5,"resetTime":"2026-09-19T08:25:50Z"},
        {"bucketId":"epoch","remainingFraction":0.5,"resetTime":1789900000},
        {"bucketId":"fraction","remainingFraction":0.5,"resetTime":"2026-09-19T08:25:50.123456Z"},
        {"bucketId":"bogus","remainingFraction":0.5,"resetTime":0}]}]
      """#
    let parsed = try #require(
      AntigravityQuotaClient.windows(
        fromQuotaSummary: summary(shell: "response", groups: groups), now: referenceNow))
    let byLabel = Dictionary(uniqueKeysWithValues: parsed.windows.map { ($0.displayLabel, $0) })
    #expect(byLabel["iso"]?.resetsAt == Date(timeIntervalSince1970: 1_789_806_350))
    #expect(byLabel["epoch"]?.resetsAt == Date(timeIntervalSince1970: 1_789_900_000))
    // 六位小数秒：只要求秒级一致，不比较服务端带来的亚秒残余。
    let fraction = try #require(byLabel["fraction"]?.resetsAt)
    #expect(abs(fraction.timeIntervalSince1970 - 1_789_806_350) < 1)
    // resetTime 为 0 落在可信区间外，按「没有重置时刻」处理而不是显示 1970 年。
    #expect(byLabel["bogus"]?.resetsAt == nil)
  }

  // 面板一张卡片放不下更多，必须保证「已用最多」的那几条可见。
  @Test("Antigravity: 超过 4 条时按已用降序截断")
  func truncatesToFourWindowsByUsage() throws {
    let buckets = [0.9, 0.1, 0.5, 0.3, 0.7, 0.2].enumerated().map { index, remaining in
      #"{"bucketId":"b\#(index)","remainingFraction":\#(remaining)}"#
    }.joined(separator: ",")
    let parsed = try #require(
      AntigravityQuotaClient.windows(
        fromQuotaSummary: summary(
          shell: "response", groups: #"[{"displayName":"G","buckets":[\#(buckets)]}]"#),
        now: referenceNow))
    #expect(parsed.windows.count == 4)
    #expect(parsed.windows.map(\.displayLabel) == ["b1", "b5", "b3", "b2"])
    #expect(parsed.windows.map(\.usedPercent) == [90, 80, 70, 50])
  }

  // agy ≥ 1.2.2 对没带 CSRF token 的请求回 401；卡片消失即可，不能报错。
  @Test("Antigravity: 401、空 groups 与垃圾 JSON 一律返回 nil")
  func rejectsUnauthenticatedAndGarbage() {
    let unauthenticated = Data(#"{"code":"unauthenticated","message":"missing CSRF token"}"#.utf8)
    #expect(AntigravityQuotaClient.windows(fromQuotaSummary: unauthenticated, now: referenceNow) == nil)
    #expect(
      AntigravityQuotaClient.windows(
        fromQuotaSummary: summary(shell: "response", groups: "[]"), now: referenceNow) == nil)
    // 有 group 但 bucket 全都缺 remainingFraction，等于没有可显示的数据。
    #expect(
      AntigravityQuotaClient.windows(
        fromQuotaSummary: summary(
          shell: "response", groups: #"[{"displayName":"G","buckets":[{"bucketId":"a"}]}]"#),
        now: referenceNow) == nil)
    #expect(AntigravityQuotaClient.windows(fromQuotaSummary: Data("not json".utf8), now: referenceNow) == nil)
    #expect(AntigravityQuotaClient.windows(fromQuotaSummary: Data(), now: referenceNow) == nil)
  }
}

@Suite("AntigravityQuota 身份与模型配额")
struct AntigravityQuotaUserStatusTests {
  private func userStatus(tier: String = "null", planInfo: String = "null") -> Data {
    Data(
      #"""
      {"code":"ok","response":{"userStatus":{
        "userTier":\#(tier),
        "planStatus":{"planInfo":\#(planInfo)},
        "cascadeModelConfigData":{"clientModelConfigs":[
          {"label":"Gemini 3 Pro","modelOrAlias":{"model":"MODEL_GEMINI_3_PRO"},
           "quotaInfo":{"remainingFraction":0.2,"resetTime":"2026-09-20T10:26:40Z"}},
          {"modelOrAlias":{"model":"MODEL_FAST"},"quotaInfo":{"remainingFraction":0.95}}]}}}}
      """#.utf8)
  }

  @Test("Antigravity: GetUserStatus 的 clientModelConfigs 映射成模型周窗口")
  func mapsClientModelConfigs() throws {
    let parsed = try #require(
      AntigravityQuotaClient.windows(fromUserStatus: userStatus(), now: referenceNow))
    #expect(parsed.windows.map(\.displayLabel) == ["Gemini 3 Pro", "MODEL_FAST"])
    // 二进制浮点反算会留下尾数，按显示精度比较。
    #expect(parsed.windows.map { ($0.usedPercent * 100).rounded() / 100 } == [80, 5])
    #expect(parsed.windows[0].resetsAt == Date(timeIntervalSince1970: 1_789_900_000))
    #expect(parsed.windows.allSatisfy { $0.kind == .modelWeekly })
  }

  // userTier 是服务端权威枚举，必须压过 planInfo 里的展示名。
  @Test("Antigravity: 档位优先取 userTier.name，再退到 planInfo")
  func prefersUserTierOverPlanInfo() throws {
    let both = try #require(
      AntigravityQuotaClient.windows(
        fromUserStatus: userStatus(
          tier: #"{"name":"TIER_PRO"}"#, planInfo: #"{"planName":"legacy_plan"}"#),
        now: referenceNow))
    #expect(both.plan == "Pro")

    let planOnly = try #require(
      AntigravityQuotaClient.windows(
        fromUserStatus: userStatus(planInfo: #"{"planDisplayName":"Antigravity Ultra"}"#),
        now: referenceNow))
    // 带空格的一律当成品展示名原样用，不走枚举的分段大写。
    #expect(planOnly.plan == "Antigravity Ultra")

    let enumStyle = try #require(
      AntigravityQuotaClient.windows(
        fromUserStatus: userStatus(planInfo: #"{"planName":"business_starter"}"#),
        now: referenceNow))
    #expect(enumStyle.plan == "Business Starter")

    let none = try #require(
      AntigravityQuotaClient.windows(fromUserStatus: userStatus(), now: referenceNow))
    #expect(none.plan == nil)
  }

  // GetCommandModelConfigs 用同一个解析器，但顶层没有 userStatus 也没有身份字段。
  @Test("Antigravity: GetCommandModelConfigs 的扁平结构也能解析，plan 为空")
  func parsesCommandModelConfigs() throws {
    let data = Data(
      #"""
      {"clientModelConfigs":[{"label":"Fast","quotaInfo":{"remaining":{"remainingFraction":0.25}}}]}
      """#.utf8)
    let parsed = try #require(
      AntigravityQuotaClient.windows(fromUserStatus: data, now: referenceNow))
    #expect(parsed.windows.map(\.displayLabel) == ["Fast"])
    #expect(parsed.windows[0].usedPercent == 75)
    #expect(parsed.plan == nil)
  }

  @Test("Antigravity: 缺配额字段与垃圾 JSON 返回 nil")
  func rejectsMissingQuota() {
    let noQuota = Data(#"{"clientModelConfigs":[{"label":"Fast"}]}"#.utf8)
    #expect(AntigravityQuotaClient.windows(fromUserStatus: noQuota, now: referenceNow) == nil)
    #expect(AntigravityQuotaClient.windows(fromUserStatus: Data("[".utf8), now: referenceNow) == nil)
  }

  // latest 的降级链：配额汇总 404 时必须自动落到 GetUserStatus。
  @Test("Antigravity: latest 在配额汇总失败时退到 GetUserStatus")
  func latestFallsBackToUserStatus() throws {
    let endpoint = AntigravityServerEndpoint(port: 51_234, csrfToken: "secret")
    let result = try #require(
      AntigravityQuotaClient.latest(now: referenceNow, endpoint: endpoint) { _, method, _ in
        method == AntigravityQuotaClient.Method.userStatus ? self.userStatus() : nil
      })
    #expect(result.fetchedAt == referenceNow)
    #expect(result.windows.count == 2)
    // 没有端点时一次请求都不发。
    let withoutEndpoint = AntigravityQuotaClient.latest(
      now: referenceNow, endpoint: nil, fetch: { _, _, _ in Data() })
    #expect(withoutEndpoint == nil)
  }
}

@Suite("AntigravityQuota 服务定位")
struct AntigravityLanguageServerLocatorTests {
  private let processList = """
      501 /Applications/Antigravity.app/Contents/Resources/app/bin/language_server_macos_arm --app_data_dir antigravity --csrf_token abc123 --extension_server_port 52346
      777 /usr/local/bin/language_server --app_data_dir windsurf --csrf_token zzz
      888 /Users/mike/.antigravity-cli/bin/language_server
      999 /bin/zsh -l
    """

  @Test("Antigravity: 只认 Antigravity 名下的 language server 进程")
  func picksOnlyAntigravityProcesses() {
    let candidates = AntigravityLanguageServerLocator.candidates(fromProcessList: processList)
    #expect(candidates.map(\.processIdentifier) == [501, 888])
    #expect(candidates[0].csrfToken == "abc123")
    #expect(candidates[0].hintedPort == 52_346)
    // CLI 起的实例不带 token，允许为空。
    #expect(candidates[1].csrfToken == nil)
  }

  @Test("Antigravity: extension_server_csrf_token 优先于 csrf_token")
  func prefersExtensionServerToken() {
    let line = "  42 /opt/antigravity/language_server --csrf_token old --extension_server_csrf_token=new"
    let candidates = AntigravityLanguageServerLocator.candidates(fromProcessList: line)
    #expect(candidates.map(\.csrfToken) == ["new"])
  }

  @Test("Antigravity: lsof 字段输出按 pid 分组取回环端口")
  func parsesListeningPorts() {
    let output = """
      p501
      f7
      n127.0.0.1:52345
      n*:52346
      n10.0.0.2:8080
      p888
      n[::1]:60001
      """
    let ports = AntigravityLanguageServerLocator.ports(fromListeningOutput: output)
    #expect(ports[501] == [52_345, 52_346])
    #expect(ports[888] == [60_001])
  }

  @Test("Antigravity: 端点合并时命令行提示的端口排在最前且去重")
  func ordersHintedPortFirst() {
    let candidates = AntigravityLanguageServerLocator.candidates(fromProcessList: processList)
    let endpoints = AntigravityLanguageServerLocator.endpoints(
      candidates: candidates, ports: [501: [52_345, 52_346], 888: [52_346, 60_001]])
    #expect(endpoints.map(\.port) == [52_346, 52_345, 60_001])
    #expect(endpoints[0].csrfToken == "abc123")
    #expect(endpoints[2].csrfToken == nil)
  }
}

@Suite("AntigravityQuota 真机冒烟")
struct AntigravityQuotaSmokeTests {
  // 真的去找本机的 language server 并取一次配额。默认不跑——要求 Antigravity.app 或 agy CLI
  // 正在运行，且会真的发本地请求。只在显式设 ASTER_AGY_SMOKE=1 时执行。
  @Test(
    "Antigravity: 真机冒烟，定位本地 language server 并取一次配额",
    .enabled(if: ProcessInfo.processInfo.environment["ASTER_AGY_SMOKE"] == "1"))
  func locatesAndFetches() {
    guard let endpoint = AntigravityQuotaClient.locateServer() else {
      print("SMOKE antigravity: 未找到本地 language server")
      return
    }
    // 只报告端口与「有没有 token」，token 本身绝不打印。
    print("SMOKE antigravity: port=\(endpoint.port) hasToken=\(endpoint.csrfToken != nil)")
    guard let result = AntigravityQuotaClient.latest(now: Date(), endpoint: endpoint) else {
      print("SMOKE antigravity: 端点可达但取不到配额")
      return
    }
    print("SMOKE antigravity plan=\(String(describing: result.plan))")
    for window in result.windows {
      print("SMOKE antigravity window label=\(window.displayLabel) used=\(window.usedPercent)")
    }
  }
}
