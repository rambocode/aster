// 系统状态栏图标上那一小段文字的纯逻辑。
import Foundation

/// 状态栏条目的展示内容。
public struct UsageStatusSummary: Equatable, Sendable {
  public enum Severity: String, Equatable, Sendable {
    case normal
    case warning
    case critical
  }

  /// 一个 provider 一段。
  public struct Segment: Equatable, Sendable {
    public var provider: AgentProvider
    /// 取该账号 5 小时窗口的已用百分比；没有 5 小时窗口时退到每周窗口。
    public var usedPercent: Double
    public var severity: Severity

    public init(provider: AgentProvider, usedPercent: Double, severity: Severity) {
      self.provider = provider
      self.usedPercent = usedPercent
      self.severity = severity
    }
  }

  /// 已用达到该百分比记为 warning（与 Pane 用量条的警戒线一致）。
  public static let warningThreshold: Double = 80
  /// 已用达到该百分比记为 critical。
  public static let criticalThreshold: Double = 95

  public var segments: [Segment]
  /// 是否有 Agent 正在等用户输入（状态栏红点）。
  public var needsAttention: Bool

  public init(segments: [Segment], needsAttention: Bool) {
    self.segments = segments
    self.needsAttention = needsAttention
  }

  /// 从账号快照折出状态栏内容。没有任何窗口的账号不出段。
  public static func make(accounts: [UsageAccountSnapshot], blockedAgents: Int) -> UsageStatusSummary {
    // 骨架：由「配额与开关」任务实现。
    UsageStatusSummary(segments: [], needsAttention: blockedAgents > 0)
  }
}
