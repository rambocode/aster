// 各家订阅档位标识 → 展示名的统一规范化。
import Foundation

/// 把服务端给的套餐标识折成能直接显示的短名，例如 `default_claude_max_20x` → `Max 20x`、
/// `pro` → `Pro`。
///
/// 各家叫法不统一（Claude 是 `rateLimitTier` / `subscriptionType`，Codex 是 `planType`），
/// 但形状一样：小写下划线分段。所以只做「去前缀 + 分段 + 首字母大写」，不做任何别名映射——
/// 出现没见过的档位时原样显示，好过显示成错的或干脆不显示。
public enum UsagePlanName {
  /// 允许的原始长度上限；超过说明拿到的不是档位标识。
  static let maximumRawBytes = 64
  /// 允许的分段数上限，同样是防御外部数据。
  static let maximumSegments = 6

  /// 规范化。`strippingPrefixes` 按顺序逐个尝试剥掉（可连续剥多个）。
  /// 空串、超长、剥完为空时返回 nil。
  public static func normalized(_ raw: String?, strippingPrefixes: [String] = []) -> String? {
    guard var value = raw?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
      !value.isEmpty, value.utf8.count <= maximumRawBytes
    else { return nil }
    // 前缀可能叠着来（`default_claude_max_20x`），所以循环剥到不再匹配为止。
    var strippedSomething = true
    while strippedSomething {
      strippedSomething = false
      for prefix in strippingPrefixes where value.hasPrefix(prefix) && value.count > prefix.count {
        value.removeFirst(prefix.count)
        strippedSomething = true
      }
    }
    let segments = value.split(separator: "_", omittingEmptySubsequences: true)
    guard !segments.isEmpty, segments.count <= maximumSegments else { return nil }
    // 首字母大写而不是整体 capitalized：`20x` 要保持原样，`capitalized` 会把它变成 `20X`。
    return segments.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
  }
}
