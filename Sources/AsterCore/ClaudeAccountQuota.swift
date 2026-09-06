import Foundation

/// Claude 账号级配额的纯解析：从 Claude Code 的 OAuth 凭据 JSON 取 access token，从官方
/// `/api/oauth/usage` 响应取 5 小时 / 每周窗口。与 Claude Code 自己的 `/usage` 面板同源，
/// 所以数值完全一致，也不依赖 statusLine / hook 上报。网络与 Keychain 访问在 Aster 层。
public enum ClaudeAccountQuotaParser {
  public static let usageEndpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

  /// 凭据 JSON（Keychain 项 `Claude Code-credentials` 或 `~/.claude/.credentials.json`）形如
  /// `{"claudeAiOauth":{"accessToken":"…","expiresAt":<毫秒 epoch>}}`。已过期返回 nil，
  /// 不在这里刷新：续期由 Claude Code 自己完成，下次轮询会再读。
  public static func accessToken(fromCredentials data: Data, now: Date = Date()) -> String? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    let oauth = object["claudeAiOauth"] as? [String: Any] ?? object
    guard let token = oauth["accessToken"] as? String, !token.isEmpty, token.utf8.count <= 4_096 else {
      return nil
    }
    if let expires = oauth["expiresAt"] as? NSNumber,
      expires.doubleValue <= now.timeIntervalSince1970 * 1_000
    {
      return nil
    }
    return token
  }

  /// `five_hour` / `seven_day` 的 `utilization` 已是百分比（0–100），`resets_at` 是带时区的
  /// ISO 8601（含小数秒）。所有窗口都缺失时返回 nil，让调用方保留上一份数据。
  public static func windows(fromUsageResponse data: Data) -> [AgentUsageWindow]? {
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
    var windows: [AgentUsageWindow] = []
    let mapping: [(String, AgentUsageWindowKind)] = [("five_hour", .fiveHour), ("seven_day", .weekly)]
    for (key, kind) in mapping {
      guard let entry = object[key] as? [String: Any],
        let utilization = entry["utilization"] as? NSNumber
      else { continue }
      let resetsAt = (entry["resets_at"] as? String).flatMap(parseISO8601)
      if let window = AgentUsageWindow(kind: kind, usedPercent: utilization.doubleValue, resetsAt: resetsAt) {
        windows.append(window)
      }
    }
    if let scoped = modelWeeklyWindow(fromUsageObject: object) { windows.append(scoped) }
    return windows.isEmpty ? nil : windows
  }

  /// 模型级周配额（当前是 Fable）。服务端已把它从顶层 `seven_day_opus` / `seven_day_sonnet`
  /// 这类固定键迁到 `limits` 数组，那些旧键现在恒为 null；新数据只出现在
  /// `kind == "weekly_scoped"` 的条目里，模型名在 `scope.model.display_name`。
  /// 只取第一条：一个账号同一时刻只会有一个受限模型，取多条 UI 也放不下。
  static func modelWeeklyWindow(fromUsageObject object: [String: Any]) -> AgentUsageWindow? {
    guard let limits = object["limits"] as? [[String: Any]] else { return nil }
    for entry in limits {
      guard entry["kind"] as? String == "weekly_scoped",
        let percent = entry["percent"] as? NSNumber,
        let scope = entry["scope"] as? [String: Any],
        let model = scope["model"] as? [String: Any],
        let name = model["display_name"] as? String, !name.isEmpty, name.utf8.count <= 64
      else { continue }
      let resetsAt = (entry["resets_at"] as? String).flatMap(parseISO8601)
      return AgentUsageWindow(
        kind: .modelWeekly, usedPercent: percent.doubleValue, resetsAt: resetsAt,
        detail: "\(name) 的每周配额，与总周配额分开计算", label: name)
    }
    return nil
  }

  /// 服务端返回 `2026-09-06T06:59:59.860820+00:00`：六位小数秒，`ISO8601DateFormatter`
  /// 只认三位，所以先试带小数的格式，再退到无小数。
  static func parseISO8601(_ text: String) -> Date? {
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = withFraction.date(from: text) { return date }
    let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
    let plain = ISO8601DateFormatter()
    plain.formatOptions = [.withInternetDateTime]
    return plain.date(from: trimmed)
  }
}
