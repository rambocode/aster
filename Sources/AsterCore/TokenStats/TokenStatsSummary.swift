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
  ///
  /// 排名、条形和占比全部按 total，和标题上那个数字是同一个量、同一种算法，
  /// 这样一行的条和上面的卡片说的才是一回事。total 相同时用 output 破平。
  public static func make(samples: [TokenSample], range: TokenStatsRange, today: Int)
    -> TokenStatsSummary
  {
    let earliest = range.dayCount.map { today - ($0 - 1) }
    var totals = TokenTotals()
    var byProvider: [AgentProvider: TokenTotals] = [:]
    var byProject: [String: TokenTotals] = [:]
    var everSeenProviders = Set<AgentProvider>()

    for sample in samples {
      // provider 行的「曾经有过数据」要看全部样本，不能只看当前区间，否则切区间时表格会少行。
      everSeenProviders.insert(sample.provider)
      if let earliest, sample.day < earliest { continue }
      totals += sample.totals
      byProvider[sample.provider, default: TokenTotals()] += sample.totals
      byProject[sample.project, default: TokenTotals()] += sample.totals
    }

    let denominator = Double(max(totals.total, 1))

    // 按 provider 目录顺序排；凡是有过数据的 provider 即使本区间为空也保留行，
    // 换区间只改数字不改布局。
    let providers = AgentProvider.allCases.filter(everSeenProviders.contains).map {
      ProviderRow(provider: $0, totals: byProvider[$0] ?? TokenTotals())
    }

    // 「其他」先拿出来单独放，它不参与排名，只在最后吸收掉超出上限的长尾。
    var pooled = byProject.removeValue(forKey: TokenProject.otherKey) ?? TokenTotals()
    let ranked = byProject.sorted {
      ($0.value.total, $0.value.output, $1.key) > ($1.value.total, $1.value.output, $0.key)
    }
    for (_, totals) in ranked.dropFirst(projectRowLimit) { pooled += totals }

    var projects = ranked.prefix(projectRowLimit).map { key, rowTotals in
      ProjectRow(
        key: key, name: TokenProject.displayName(forKey: key), totals: rowTotals,
        share: Double(rowTotals.total) / denominator)
    }
    projects = disambiguated(projects)
    if !pooled.isEmpty {
      projects.append(
        ProjectRow(
          key: TokenProject.otherKey,
          name: TokenProject.displayName(forKey: TokenProject.otherKey), totals: pooled,
          share: Double(pooled.total) / denominator))
    }

    return TokenStatsSummary(
      range: range, totals: totals, projects: projects, providers: providers)
  }

  /// 把重名的展示名扩宽一段路径。
  ///
  /// 真实仓库里路径最后一段撞名是常态（`src`、`web`、`app`），两行字一样数字不一样，
  /// 看起来像统计算错了，而不是两个不同目录。扩到两段后还撞的就保持两段，靠整行的完整路径提示。
  private static func disambiguated(_ rows: [ProjectRow]) -> [ProjectRow] {
    let counts = rows.reduce(into: [String: Int]()) { $0[$1.name, default: 0] += 1 }
    return rows.map { row in
      guard counts[row.name, default: 0] > 1 else { return row }
      var widened = row
      widened.name = TokenProject.displayName(forKey: row.key, components: 2)
      return widened
    }
  }

  /// 某个项目（nil = 全部）每天的总量，供热力图使用。
  public static func dailyTotals(samples: [TokenSample], project: String?) -> [Int: Int64] {
    var days: [Int: Int64] = [:]
    for sample in samples where project == nil || sample.project == project {
      days[sample.day, default: 0] += sample.totals.total
    }
    return days
  }
}
