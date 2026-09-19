// AI 用量浮动窗「配额」页的账号模型。
import Foundation

/// 一个订阅账号当前的配额快照。
///
/// `==` 刻意不比较 `fetchedAt`：轮询常常带回同样的百分比，视图靠 Equatable 抑制重复重绘。
public struct UsageAccountSnapshot: Equatable, Sendable, Identifiable {
  /// 稳定标识，例如 `claudeCode:default`。
  public var id: String
  public var provider: AgentProvider
  /// 展示名，例如「Claude」「Codex」。
  public var label: String
  /// 订阅档位的展示名，例如「Max 20x」「Pro」「Plus」。各家叫法不同，原样展示；拿不到为 nil。
  public var plan: String?
  public var windows: [AgentUsageWindow]
  /// 这份数据的取得时刻；用于标注「X 前更新」。
  public var fetchedAt: Date?

  public init(
    id: String, provider: AgentProvider, label: String, plan: String? = nil,
    windows: [AgentUsageWindow], fetchedAt: Date?
  ) {
    self.id = id
    self.provider = provider
    self.label = label
    self.plan = plan
    self.windows = windows
    self.fetchedAt = fetchedAt
  }

  public static func == (lhs: UsageAccountSnapshot, rhs: UsageAccountSnapshot) -> Bool {
    lhs.id == rhs.id && lhs.provider == rhs.provider && lhs.label == rhs.label
      && lhs.plan == rhs.plan && lhs.windows == rhs.windows
  }
}
