import Foundation
import SQLite3
import Testing

@testable import Aster
@testable import AsterCore

// Cursor 配额客户端：响应解析、档位名映射与本地凭据读取。除冒烟用例外都不联网。

/// 造一条 `GetCurrentPeriodUsage` 响应。默认值取自真机实测（金额单位是美分）。
///
/// `billingCycleEnd` 默认写成 JSON **字符串**：服务端把 int64 这样序列化，按数字取会漏掉。
private func usageResponse(
  planUsage: String = #"""
    {"totalSpend":2476,"includedSpend":2000,"bonusSpend":476,"limit":2000,\#
    "autoPercentUsed":4.491111111111111,"apiPercentUsed":10.11111111111111,\#
    "totalPercentUsed":5.002020202020202}
    """#,
  billingCycleEnd: String = #""1791535981000""#,
  extra: String = ""
) -> Data {
  Data(
    #"""
    {"billingCycleStart":"1788943981000","billingCycleEnd":\#(billingCycleEnd),\#
    "planUsage":\#(planUsage),"spendLimitUsage":{"limitType":"user"},"enabled":true\#(extra)}
    """#.utf8)
}

/// 执行一条建表 / 插入语句，失败即让用例失败。
private func execute(_ database: OpaquePointer, _ sql: String) {
  #expect(sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK)
}

/// 在临时目录里造一个 Cursor 形状的 `state.vscdb`，返回可传给客户端的 home 目录。
///
/// `createItemTable` 为 false 时只建一张别的表：用来验证「库在但表缺失」也要静默返回 nil。
private func makeCursorHome(
  token: String?, membership: String?, createItemTable: Bool = true, createDatabase: Bool = true
) throws -> URL {
  let home = FileManager.default.temporaryDirectory
    .appendingPathComponent("cursor-quota-\(UUID().uuidString)", isDirectory: true)
  let directory = home.appendingPathComponent(
    "Library/Application Support/Cursor/User/globalStorage", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  guard createDatabase else { return home }

  let path = directory.appendingPathComponent("state.vscdb").path
  var handle: OpaquePointer?
  #expect(
    sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK)
  let database = try #require(handle)
  defer { sqlite3_close_v2(database) }
  guard createItemTable else {
    execute(database, "CREATE TABLE SomethingElse (a TEXT)")
    return home
  }
  execute(database, "CREATE TABLE ItemTable (key TEXT PRIMARY KEY, value BLOB)")
  if let token {
    execute(database, "INSERT INTO ItemTable VALUES ('cursorAuth/accessToken', '\(token)')")
  }
  if let membership {
    execute(
      database,
      "INSERT INTO ItemTable VALUES ('cursorAuth/stripeMembershipType', '\(membership)')")
  }
  return home
}

@Suite("CursorQuota 配额客户端")
struct CursorQuotaClientTests {
  private let now = Date(timeIntervalSince1970: 1_790_000_000)

  // MARK: - 响应解析

  @Test("完整响应解析出一个计费周期窗口")
  func parsesBillingCycleWindow() throws {
    let windows = try #require(
      CursorAccountQuotaClient.windows(fromUsageResponse: usageResponse(), now: now))
    #expect(windows.count == 1)
    #expect(windows[0].kind == .billingCycle)
    #expect(abs(windows[0].usedPercent - 5.002_020_202_020_202) < 0.000_001)
    #expect(windows[0].resetsAt == Date(timeIntervalSince1970: 1_791_535_981))
    // 只讲金额、不带分母：进度条的分母不是 limit，写成「/ $20.00」会被读成超额扣费。
    #expect(windows[0].detail == "已用 $24.76（含赠送 $4.76）")
  }

  // billingCycleEnd 是毫秒。当成秒用会把 2026 年算到 58749 年，当成 1970 年则会被上层
  // 显示成「已重置」；两个方向都要钉住。
  @Test("毫秒时间戳没有被当成秒")
  func treatsBillingCycleEndAsMilliseconds() throws {
    let windows = try #require(
      CursorAccountQuotaClient.windows(fromUsageResponse: usageResponse(), now: now))
    let resetsAt = try #require(windows[0].resetsAt)
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    #expect(calendar.component(.year, from: resetsAt) == 2026)
  }

  @Test("billingCycleEnd 是数字时同样能解析，缺失或为 0 时不带重置时刻")
  func acceptsNumericBillingCycleEnd() throws {
    let numeric = try #require(
      CursorAccountQuotaClient.windows(
        fromUsageResponse: usageResponse(billingCycleEnd: "1791535981000"), now: now))
    #expect(numeric[0].resetsAt == Date(timeIntervalSince1970: 1_791_535_981))

    let zero = try #require(
      CursorAccountQuotaClient.windows(
        fromUsageResponse: usageResponse(billingCycleEnd: "0"), now: now))
    #expect(zero[0].resetsAt == nil)

    let missing = try #require(
      CursorAccountQuotaClient.windows(
        fromUsageResponse: usageResponse(billingCycleEnd: "null"), now: now))
    #expect(missing[0].resetsAt == nil)
  }

  @Test("缺 planUsage 或缺 totalPercentUsed 时返回 nil")
  func rejectsMissingPlanUsage() {
    #expect(
      CursorAccountQuotaClient.windows(
        fromUsageResponse: usageResponse(planUsage: "null"), now: now) == nil)
    #expect(
      CursorAccountQuotaClient.windows(
        fromUsageResponse: usageResponse(planUsage: #"{"totalSpend":2476,"limit":2000}"#),
        now: now) == nil)
    #expect(CursorAccountQuotaClient.windows(fromUsageResponse: Data("not json".utf8), now: now) == nil)
    #expect(CursorAccountQuotaClient.windows(fromUsageResponse: Data(), now: now) == nil)
  }

  // 私有接口换形状时最可能的表现就是数值变成字符串；那说明整条响应不可信，不能显示。
  @Test("totalPercentUsed 是字符串、布尔或非有限数时返回 nil")
  func rejectsNonNumericPercent() {
    #expect(
      CursorAccountQuotaClient.windows(
        fromUsageResponse: usageResponse(planUsage: #"{"totalPercentUsed":"5.0"}"#), now: now)
        == nil)
    // JSON 的 true 也会桥成 NSNumber，不挡住就会显示成 1%。
    #expect(
      CursorAccountQuotaClient.windows(
        fromUsageResponse: usageResponse(planUsage: #"{"totalPercentUsed":true}"#), now: now)
        == nil)
    // 1e400 超出 Double 范围：JSONSerialization 直接拒绝整条 JSON，同样不能拿到窗口。
    #expect(
      CursorAccountQuotaClient.windows(
        fromUsageResponse: usageResponse(planUsage: #"{"totalPercentUsed":1e400}"#), now: now)
        == nil)
  }

  @Test("未授权响应返回 nil")
  func rejectsUnauthenticatedResponses() {
    #expect(
      CursorAccountQuotaClient.windows(
        fromUsageResponse: usageResponse(extra: #","error":"not_authenticated""#), now: now)
        == nil)
    #expect(
      CursorAccountQuotaClient.windows(
        fromUsageResponse: usageResponse(extra: #","shouldLogout":true"#), now: now) == nil)
    // shouldLogout 为 false 时是正常响应，不能误杀。
    #expect(
      CursorAccountQuotaClient.windows(
        fromUsageResponse: usageResponse(extra: #","shouldLogout":false"#), now: now) != nil)
  }

  // MARK: - 金额说明

  @Test("金额按美分格式化，没有赠送额时不带括号")
  func formatsSpendDetail() {
    #expect(CursorAccountQuotaClient.moneyText(cents: 2476) == "$24.76")
    #expect(CursorAccountQuotaClient.moneyText(cents: 0) == "$0.00")
    #expect(CursorAccountQuotaClient.moneyText(cents: -1) == nil)
    #expect(CursorAccountQuotaClient.moneyText(cents: .nan) == nil)
    #expect(
      CursorAccountQuotaClient.spendDetail(totalSpendCents: 2476, bonusSpendCents: 476)
        == "已用 $24.76（含赠送 $4.76）")
    #expect(
      CursorAccountQuotaClient.spendDetail(totalSpendCents: 2000, bonusSpendCents: 0)
        == "已用 $20.00")
    #expect(
      CursorAccountQuotaClient.spendDetail(totalSpendCents: 2000, bonusSpendCents: nil)
        == "已用 $20.00")
    // totalSpend 缺失就整条说明都不显示，而不是显示半句。
    #expect(CursorAccountQuotaClient.spendDetail(totalSpendCents: nil, bonusSpendCents: 476) == nil)
  }

  // MARK: - 档位名

  @Test("订阅档位按下划线分段首字母大写")
  func mapsPlanNames() {
    #expect(CursorAccountQuotaClient.planName(fromMembershipType: "pro") == "Pro")
    #expect(CursorAccountQuotaClient.planName(fromMembershipType: "free") == "Free")
    #expect(CursorAccountQuotaClient.planName(fromMembershipType: "pro_plus") == "Pro Plus")
    #expect(CursorAccountQuotaClient.planName(fromMembershipType: "ultra") == "Ultra")
    #expect(CursorAccountQuotaClient.planName(fromMembershipType: "") == nil)
    #expect(CursorAccountQuotaClient.planName(fromMembershipType: nil) == nil)
  }

  // MARK: - 凭据读取

  @Test("从 state.vscdb 读出 token 与订阅档位")
  func readsCredentialsFromDatabase() throws {
    let home = try makeCursorHome(token: "header.payload.signature", membership: "pro")
    defer { try? FileManager.default.removeItem(at: home) }
    let credentials = try #require(CursorAccountQuotaClient.credentials(homeDirectory: home))
    #expect(credentials.token == "header.payload.signature")
    #expect(credentials.membershipType == "pro")
  }

  @Test("只有 token 没有档位时仍然可用")
  func readsCredentialsWithoutMembership() throws {
    let home = try makeCursorHome(token: "jwt", membership: nil)
    defer { try? FileManager.default.removeItem(at: home) }
    let credentials = try #require(CursorAccountQuotaClient.credentials(homeDirectory: home))
    #expect(credentials.token == "jwt")
    #expect(credentials.membershipType == nil)
  }

  @Test("库不存在、表缺失或没有 token 键时静默返回 nil")
  func returnsNilForUnusableDatabase() throws {
    let missing = try makeCursorHome(token: nil, membership: nil, createDatabase: false)
    defer { try? FileManager.default.removeItem(at: missing) }
    #expect(CursorAccountQuotaClient.credentials(homeDirectory: missing) == nil)

    let noTable = try makeCursorHome(token: nil, membership: nil, createItemTable: false)
    defer { try? FileManager.default.removeItem(at: noTable) }
    #expect(CursorAccountQuotaClient.credentials(homeDirectory: noTable) == nil)

    let noToken = try makeCursorHome(token: nil, membership: "pro")
    defer { try? FileManager.default.removeItem(at: noToken) }
    #expect(CursorAccountQuotaClient.credentials(homeDirectory: noToken) == nil)
  }

  // MARK: - 端到端（注入 fetch）

  @Test("latest 串起凭据、取数与解析")
  func latestCombinesCredentialsAndUsage() throws {
    let home = try makeCursorHome(token: "jwt", membership: "pro")
    defer { try? FileManager.default.removeItem(at: home) }
    let result = try #require(
      CursorAccountQuotaClient.latest(homeDirectory: home, now: now) { token in
        token == "jwt" ? usageResponse() : nil
      })
    #expect(result.plan == "Pro")
    #expect(result.fetchedAt == now)
    #expect(result.windows.map(\.kind) == [.billingCycle])
  }

  @Test("取数失败或凭据缺失时 latest 返回 nil")
  func latestReturnsNilOnFailure() throws {
    let home = try makeCursorHome(token: "jwt", membership: "pro")
    defer { try? FileManager.default.removeItem(at: home) }
    #expect(CursorAccountQuotaClient.latest(homeDirectory: home, now: now) { _ in nil } == nil)

    let empty = try makeCursorHome(token: nil, membership: nil, createDatabase: false)
    defer { try? FileManager.default.removeItem(at: empty) }
    #expect(
      CursorAccountQuotaClient.latest(homeDirectory: empty, now: now) { _ in usageResponse() }
        == nil)
  }

  // 真机冒烟：真读本机 Cursor 的凭据并打一次私有接口。默认不跑（要装了 Cursor 并登录过），
  // 只在显式设 ASTER_CURSOR_SMOKE=1 时执行。只打印用量，绝不打印 token 或任何身份字段。
  @Test(
    "真机冒烟，实际取一次 Cursor 配额",
    .enabled(if: ProcessInfo.processInfo.environment["ASTER_CURSOR_SMOKE"] == "1"))
  func liveSmoke() throws {
    let result = try #require(
      CursorAccountQuotaClient.latest(
        homeDirectory: FileManager.default.homeDirectoryForCurrentUser, now: Date()))
    for window in result.windows {
      print(
        "SMOKE cursor kind=\(window.kind) used=\(window.usedPercent)"
          + " resetsAt=\(String(describing: window.resetsAt)) detail=\(String(describing: window.detail))")
    }
    print("SMOKE cursor plan=\(String(describing: result.plan))")
    #expect(!result.windows.isEmpty)
  }
}
