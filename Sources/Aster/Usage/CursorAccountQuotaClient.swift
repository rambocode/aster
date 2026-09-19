// Cursor 订阅配额：从 Cursor IDE 的本地 SQLite 取 JWT，再调它的 Dashboard 接口读当期用量。
import AsterCore
import Foundation
import os
import SQLite3

/// 一次 Cursor 配额查询的结果。
struct CursorQuotaResult: Sendable {
  let windows: [AgentUsageWindow]
  /// 订阅档位展示名（`Pro`）；读不到时为 nil，卡片不显示档位徽标。
  let plan: String?
  let fetchedAt: Date
}

/// 读取 Cursor 的计费周期配额。
///
/// 数据分两段：凭据在 Cursor IDE 自己的 `state.vscdb` 里（`cursorAuth/accessToken` 是原始
/// JWT，`cursorAuth/stripeMembershipType` 是订阅档位），用量要向 `api2.cursor.sh` 现取。
///
/// **这是 Cursor 的私有接口，随时可能改字段或直接消失。** 所以每一条失败路径都静默返回
/// nil，让用量卡片自己消失：不抛错、不弹窗、不重试（轮询与节流都在上层）。token 只在内存
/// 里活到用完，不落盘、不进日志、不进诊断属性。
///
/// 全部是阻塞式 IO（SQLite 查询 + 同步等 HTTP），调用方必须放在
/// `Task.detached(priority: .utility)` 里执行。
enum CursorAccountQuotaClient {
  /// 注入点：入参是 JWT，返回响应体。默认实现是 `liveFetch`。
  typealias Fetcher = @Sendable (String) -> Data?

  /// 单次请求的总超时。非核心功能，宁可这一轮没数据也不能久等。
  static let requestTimeout: TimeInterval = 15
  /// 响应体大小上限；正常响应只有几 KB，超过说明拿到的不是这个接口的数据。
  static let maximumResponseBytes = 1 << 20
  /// 单个凭据值的长度上限；实测 JWT 411 字节，超过说明读到的不是我们要的键。
  static let maximumCredentialBytes = 8 * 1024
  /// 金额上限（美分），纯粹防御异常数据把 UI 撑爆。
  static let maximumCents: Double = 100_000_000

  static let accessTokenKey = "cursorAuth/accessToken"
  static let membershipTypeKey = "cursorAuth/stripeMembershipType"
  /// Cursor IDE 的 globalStorage 数据库，相对用户主目录。
  static let databaseRelativePath = "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
  static let usageEndpoint = URL(
    string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")

  // MARK: - 对外入口

  /// 取一次当期配额。任何一步失败都返回 nil。
  nonisolated static func latest(
    homeDirectory: URL, now: Date, fetch: Fetcher = liveFetch
  ) -> CursorQuotaResult? {
    guard let credentials = credentials(homeDirectory: homeDirectory),
      let data = fetch(credentials.token),
      let windows = windows(fromUsageResponse: data, now: now)
    else { return nil }
    return CursorQuotaResult(
      windows: windows, plan: planName(fromMembershipType: credentials.membershipType),
      fetchedAt: now)
  }

  /// 从 Cursor IDE 的数据库读 JWT 与订阅档位。库不存在、打不开或没有这两个键时返回 nil。
  nonisolated static func credentials(homeDirectory: URL)
    -> (token: String, membershipType: String?)?
  {
    let path = homeDirectory.appendingPathComponent(databaseRelativePath).path
    guard let rows = credentialRows(databasePath: path),
      let token = rows[accessTokenKey]?.trimmingCharacters(in: .whitespacesAndNewlines),
      !token.isEmpty
    else { return nil }
    return (token, rows[membershipTypeKey])
  }

  // MARK: - 响应解析

  /// 把 `GetCurrentPeriodUsage` 的响应解析成一个 `.billingCycle` 窗口。纯函数，可单测。
  ///
  /// 只取 `planUsage.totalPercentUsed`：它就是 Cursor 自己界面上那句「You've used N% of
  /// your included total usage」的口径，`autoPercentUsed` / `apiPercentUsed` 是它的两个分项。
  nonisolated static func windows(fromUsageResponse data: Data, now: Date) -> [AgentUsageWindow]? {
    guard data.count <= maximumResponseBytes,
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      !isUnauthenticated(object),
      let plan = object["planUsage"] as? [String: Any],
      // 百分比只认真正的 JSON 数字：字符串化的数值说明拿到的是另一种响应形状，宁可不显示。
      let percent = number(plan["totalPercentUsed"]), percent.isFinite
    else { return nil }
    let detail = spendDetail(
      totalSpendCents: number(plan["totalSpend"]), bonusSpendCents: number(plan["bonusSpend"]))
    guard
      let window = AgentUsageWindow(
        kind: .billingCycle, usedPercent: percent,
        resetsAt: date(fromEpochMilliseconds: object["billingCycleEnd"]), detail: detail)
    else { return nil }
    return [window]
  }

  /// 订阅档位展示名：`pro` → `Pro`、`pro_plus` → `Pro Plus`。空串与 nil 返回 nil。
  nonisolated static func planName(fromMembershipType raw: String?) -> String? {
    UsagePlanName.normalized(raw)
  }

  /// tooltip 里的金额说明，例如 `已用 $24.76（含赠送 $4.76）`。字段缺失时返回 nil。
  ///
  /// **刻意不带分母。** 实测进度条用的 `totalPercentUsed` 分母不是 `limit`（本机是 $495，
  /// 接口根本不给），而 `limit` 只是套餐内额度、`totalSpend == includedSpend + bonusSpend`
  /// 会超过它。写成「已用 $24.76 / $20.00」配 5% 的进度条，会被读成超额扣费。
  nonisolated static func spendDetail(totalSpendCents: Double?, bonusSpendCents: Double?)
    -> String?
  {
    guard let spent = totalSpendCents.flatMap({ moneyText(cents: $0) }) else { return nil }
    guard let bonus = bonusSpendCents, bonus > 0, let bonusText = moneyText(cents: bonus) else {
      return L("已用 \(spent)")
    }
    return L("已用 \(spent)（含赠送 \(bonusText)）")
  }

  /// 美分转展示金额：`2476` → `$24.76`。非有限、负数或异常大的值返回 nil。
  nonisolated static func moneyText(cents: Double) -> String? {
    guard cents.isFinite, cents >= 0, cents <= maximumCents else { return nil }
    // 不用 NumberFormatter：Cursor 按美元计费，且这里要的是与语言环境无关的固定写法。
    return String(format: "$%.2f", cents / 100)
  }

  /// 未登录 / token 失效的两种表达；命中时整条响应都不可信。
  private nonisolated static func isUnauthenticated(_ object: [String: Any]) -> Bool {
    if let error = object["error"] as? String, !error.isEmpty { return true }
    return (object["shouldLogout"] as? NSNumber)?.boolValue == true
  }

  /// 只接受真正的 JSON 数字。
  ///
  /// 要单独挡掉布尔：JSON 的 `true` 也会桥成 `NSNumber`，直接取 `doubleValue` 会把
  /// `"totalPercentUsed": true` 显示成 1%。
  private nonisolated static func number(_ value: Any?) -> Double? {
    guard let raw = value as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID() else {
      return nil
    }
    return raw.doubleValue
  }

  /// 毫秒时间戳转 `Date`。
  ///
  /// 两处容易踩：一是这是**毫秒**，当秒用会把 2026 年算成 58749 年；二是服务端把 int64
  /// 序列化成 JSON **字符串**（实测 `"1791535981000"`），只按数字取会永远拿不到重置时刻。
  private nonisolated static func date(fromEpochMilliseconds value: Any?) -> Date? {
    let milliseconds: Double?
    switch value {
    case let raw as NSNumber: milliseconds = raw.doubleValue
    case let raw as String: milliseconds = Double(raw)
    default: milliseconds = nil
    }
    guard let milliseconds, milliseconds.isFinite, milliseconds > 0 else { return nil }
    return Date(timeIntervalSince1970: milliseconds / 1000)
  }

  // MARK: - 凭据读取

  private nonisolated static let credentialQuery = """
    SELECT key, value FROM ItemTable \
    WHERE key IN ('\(accessTokenKey)', '\(membershipTypeKey)')
    """

  /// 读出两个凭据键。打不开、表不存在或查询中断都返回 nil。
  ///
  /// 先用共享的只读连接：它不带 `immutable`，能正常参与 WAL，读得到 Cursor 刚写入的新
  /// token。只有它开不起来（例如所在目录不可写、建不出 `-shm`）才退到 `immutable=1` 的
  /// URI —— immutable 会跳过 `-wal` 读到过期快照，只当最后手段用。
  private nonisolated static func credentialRows(databasePath: String) -> [String: String]? {
    if let database = ReadOnlySQLiteDatabase(path: databasePath) {
      defer { database.close() }
      var rows: [String: String] = [:]
      if database.forEachRow(credentialQuery, { collect($0, into: &rows) }) { return rows }
    }
    return immutableCredentialRows(databasePath: databasePath)
  }

  /// `immutable=1` 兜底路径：自己开连接，因为共享封装刻意不支持 URI 文件名。
  private nonisolated static func immutableCredentialRows(databasePath: String)
    -> [String: String]?
  {
    var handle: OpaquePointer?
    let uri = "file:\(uriEscaped(databasePath))?mode=ro&immutable=1"
    guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK,
      let opened = handle
    else {
      if let handle { sqlite3_close_v2(handle) }
      return nil
    }
    defer { sqlite3_close_v2(opened) }
    var statement: OpaquePointer?
    guard sqlite3_prepare_v2(opened, credentialQuery, -1, &statement, nil) == SQLITE_OK,
      let prepared = statement
    else {
      if let statement { sqlite3_finalize(statement) }
      return nil
    }
    defer { sqlite3_finalize(prepared) }
    var rows: [String: String] = [:]
    while true {
      switch sqlite3_step(prepared) {
      case SQLITE_ROW: collect(prepared, into: &rows)
      case SQLITE_DONE: return rows
      default: return nil
      }
    }
  }

  /// 取一行的 key / value；超长的值直接丢弃。value 在库里是 BLOB，按文本读即可。
  private nonisolated static func collect(_ statement: OpaquePointer, into rows: inout [String: String]) {
    guard let key = ReadOnlySQLiteDatabase.text(statement, 0),
      let value = ReadOnlySQLiteDatabase.text(statement, 1),
      value.utf8.count <= maximumCredentialBytes
    else { return }
    rows[key] = value
  }

  /// SQLite 的 URI 文件名里 `%` 是转义引导符、`?` 起查询串、`#` 起片段。
  /// 用户目录里出现这些字符时不转义就会打开错误的路径（或干脆打不开）。
  private nonisolated static func uriEscaped(_ path: String) -> String {
    path
      .replacingOccurrences(of: "%", with: "%25")
      .replacingOccurrences(of: "?", with: "%3f")
      .replacingOccurrences(of: "#", with: "%23")
  }

  // MARK: - 网络

  /// 真实取数：POST 空对象，只有 200 才返回数据。
  ///
  /// 刻意不重试：401 / 403 说明凭据已失效，重试只会多打一次私有接口；其余失败交给上层
  /// 的下一轮轮询。这里用信号量把异步 API 折成同步，因为整条链路跑在后台任务上。
  nonisolated static let liveFetch: Fetcher = { token in
    guard let endpoint = usageEndpoint else { return nil }
    var request = URLRequest(url: endpoint, timeoutInterval: requestTimeout)
    request.httpMethod = "POST"
    request.httpBody = Data("{}".utf8)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")

    let box = OSAllocatedUnfairLock<Data?>(initialState: nil)
    let finished = DispatchSemaphore(value: 0)
    let task = URLSession.shared.dataTask(with: request) { data, response, _ in
      defer { finished.signal() }
      guard let http = response as? HTTPURLResponse, http.statusCode == 200, let data else {
        return
      }
      box.withLock { $0 = data }
    }
    task.resume()
    // 超时兜底：URLRequest 的 timeoutInterval 只管「两段数据之间」的间隔，整体卡住时
    // 回调可能迟迟不来，所以这里再压一道总时限，超了就取消任务。
    if finished.wait(timeout: .now() + requestTimeout) == .timedOut {
      task.cancel()
      return nil
    }
    return box.withLock { $0 }
  }
}
