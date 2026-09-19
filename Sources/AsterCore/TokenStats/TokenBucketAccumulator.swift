// 单个文件内按（本地日，项目）聚合用量的累加器。移植自 jettoai/tally（MIT）。
import Foundation

/// 把一个文件里的逐条用量汇成（日，项目）格子。数据源解析完一个文件后调用 `buckets()` 出结果。
public struct TokenBucketAccumulator {
  private struct Key: Hashable {
    let day: Int
    let project: String
  }

  private var cells: [Key: TokenTotals] = [:]

  public init() {}

  public mutating func add(_ totals: TokenTotals, day: Int, project: String) {
    cells[Key(day: day, project: project), default: TokenTotals()] += totals
  }

  /// 排序输出：同一个没变的文件重扫一次要得到逐字节相同的缓存条目，否则缓存比对会一直判定「变了」。
  public func buckets() -> [TokenBucket] {
    cells.map { TokenBucket(day: $0.key.day, project: $0.key.project, totals: $0.value) }
      .sorted { ($0.day, $0.project) < ($1.day, $1.project) }
  }
}
