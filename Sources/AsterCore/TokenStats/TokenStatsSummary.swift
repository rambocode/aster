// Token 页的汇总模型：区间过滤、按项目与按 provider 排行。移植自 jettoai/tally（MIT）。
import Foundation

/// Token 页的时间区间。
public enum TokenStatsRange: String, CaseIterable, Codable, Equatable, Sendable {
  case today
  case sevenDays
  case thirtyDays
  case all

  /// 区间覆盖的天数；`all` 为 nil。
  public var dayCount: Int? {
    switch self {
    case .today: 1
    case .sevenDays: 7
    case .thirtyDays: 30
    case .all: nil
    }
  }
}

/// 某个区间的汇总。
public struct TokenStatsSummary: Equatable, Sendable {
  /// 项目行。`key` 是项目键；`name` 是展示名（重名时自动扩成两段路径）。
  public struct ProjectRow: Equatable, Sendable {
    public var key: String
    public var name: String
    public var totals: TokenTotals
    /// 占区间总量的比例，0...1。
    public var share: Double

    public init(key: String, name: String, totals: TokenTotals, share: Double) {
      self.key = key
      self.name = name
      self.totals = totals
      self.share = share
    }
  }

  /// provider 行。曾经有过数据的 provider 即使当前区间为空也保留，换区间只变数字不变布局。
  public struct ProviderRow: Equatable, Sendable {
    public var provider: AgentProvider
    public var totals: TokenTotals

    public init(provider: AgentProvider, totals: TokenTotals) {
      self.provider = provider
      self.totals = totals
    }
  }

  /// 单独成行的项目数上限，其余并入「其他」。
  public static let projectRowLimit = 15

  public var range: TokenStatsRange
  public var totals: TokenTotals
  public var projects: [ProjectRow]
  public var providers: [ProviderRow]

  public init(
    range: TokenStatsRange, totals: TokenTotals, projects: [ProjectRow], providers: [ProviderRow]
  ) {
    self.range = range
    self.totals = totals
    self.projects = projects
    self.providers = providers
  }

  /// 从样本生成汇总。`today` 是本地日整数。
  public static func make(samples: [TokenSample], range: TokenStatsRange, today: Int) -> TokenStatsSummary {
    // 骨架：由「token 内核」任务实现。
    TokenStatsSummary(range: range, totals: TokenTotals(), projects: [], providers: [])
  }

  /// 某个项目（nil = 全部）每天的总量，供热力图使用。
  public static func dailyTotals(samples: [TokenSample], project: String?) -> [Int: Int64] {
    // 骨架：由「token 内核」任务实现。
    [:]
  }
}
