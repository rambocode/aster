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
  /// ISO 8601（含小数秒）。两个窗口都缺失时返回 nil，让调用方保留上一份数据。
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
    return windows.isEmpty ? nil : windows
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
