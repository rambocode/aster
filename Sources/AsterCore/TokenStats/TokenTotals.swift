// Token 统计的基础计量单位。移植自 jettoai/tally（MIT）的 TokenStats 模块。
import Foundation

/// 四列 token 计数。所有 provider 统一到同一口径：`input` 不含缓存命中，
/// `output` 含 reasoning / thinking。
public struct TokenTotals: Codable, Equatable, Sendable {
  public var input: Int64
  public var cacheWrite: Int64
  public var cacheRead: Int64
  public var output: Int64

  public init(input: Int64 = 0, cacheWrite: Int64 = 0, cacheRead: Int64 = 0, output: Int64 = 0) {
    self.input = input
    self.cacheWrite = cacheWrite
    self.cacheRead = cacheRead
    self.output = output
  }

  /// 四列之和。
  public var total: Int64 { input + cacheWrite + cacheRead + output }

  /// 四列全为零。
  public var isEmpty: Bool { input == 0 && cacheWrite == 0 && cacheRead == 0 && output == 0 }

  /// 逐列相加。
  public static func + (lhs: TokenTotals, rhs: TokenTotals) -> TokenTotals {
    TokenTotals(
      input: lhs.input + rhs.input, cacheWrite: lhs.cacheWrite + rhs.cacheWrite,
      cacheRead: lhs.cacheRead + rhs.cacheRead, output: lhs.output + rhs.output)
  }

  /// 逐列累加。
  public static func += (lhs: inout TokenTotals, rhs: TokenTotals) { lhs = lhs + rhs }

  /// 把每一列抬到 `other` 的对应列（只升不降），返回本次新增的差额。
  ///
  /// Claude 的一个 assistant turn 会写成多行，每行重复「截至此行」的 usage；
  /// 直接求和会多算约一倍，只取首行又会漏掉流式输出，所以按列取历史最大值增量计。
  public mutating func raise(to other: TokenTotals) -> TokenTotals {
    let added = TokenTotals(
      input: max(0, other.input - input), cacheWrite: max(0, other.cacheWrite - cacheWrite),
      cacheRead: max(0, other.cacheRead - cacheRead), output: max(0, other.output - output))
    self += added
    return added
  }
}

/// 缓存粒度：一个文件里某一天、某个项目的用量。
public struct TokenBucket: Codable, Equatable, Sendable {
  /// 本地日，自 1970-01-01 起的天数（整数比较即可做区间过滤）。
  public var day: Int
  /// 项目键：归一后的项目根绝对路径；无法归属时为 `TokenProject.otherKey`。
  public var project: String
  public var totals: TokenTotals

  public init(day: Int, project: String, totals: TokenTotals) {
    self.day = day
    self.project = project
    self.totals = totals
  }
}

/// 合并后的样本：在 bucket 基础上带 provider。
public struct TokenSample: Equatable, Sendable {
  public var day: Int
  public var project: String
  public var provider: AgentProvider
  public var totals: TokenTotals

  public init(day: Int, project: String, provider: AgentProvider, totals: TokenTotals) {
    self.day = day
    self.project = project
    self.provider = provider
    self.totals = totals
  }
}

/// 项目键的约定。
public enum TokenProject {
  /// 无法归属到任何项目的用量（例如 droid 没有 cwd）。保留成可见的「其他」行，
  /// 保证明细加总等于总数。
  public static let otherKey = ""

  /// 项目行的展示名：默认取路径最后一段，因为完整路径在行里太宽，前面的目录对每个项目又都一样。
  /// 最后一段重名时把 `components` 加大（`.../web/src` 和 `.../api/src` 是两个项目，
  /// 不能画成两行一模一样的字）。
  public static func displayName(forKey key: String, components: Int = 1) -> String {
    guard key != otherKey else { return L("其他") }
    let parts = key.split(separator: "/")
    guard !parts.isEmpty else { return key }
    return parts.suffix(max(1, components)).joined(separator: "/")
  }
}
