// 进程表的合并与排序：把两份按不同维度截断的远端列表拼成一张可本地排序的表。

import Foundation

/// 进程表的排序列。
public enum RemoteProcessSortColumn: String, Equatable, Sendable {
  case cpu
  case memory
}

/// 排序方向。
public enum RemoteProcessSortOrder: String, Equatable, Sendable {
  case descending
  case ascending

  public var toggled: RemoteProcessSortOrder { self == .descending ? .ascending : .descending }
}

/// 进程表的排序状态。
public struct RemoteProcessSort: Equatable, Sendable {
  public var column: RemoteProcessSortColumn
  public var order: RemoteProcessSortOrder

  public init(column: RemoteProcessSortColumn = .cpu, order: RemoteProcessSortOrder = .descending) {
    self.column = column
    self.order = order
  }

  /// 点击表头：同一列切换升降序，换列则回到降序——占用率表格里用户想看的几乎总是「最高的那些」。
  public func selecting(_ column: RemoteProcessSortColumn) -> RemoteProcessSort {
    column == self.column
      ? RemoteProcessSort(column: column, order: order.toggled)
      : RemoteProcessSort(column: column, order: .descending)
  }
}

public enum RemoteProcessTable {
  /// 一页最多显示多少行。
  public static let maximumRows = 20

  /// 合并两份远端列表并按指定列排序。
  ///
  /// 远端脚本分别按 CPU 与内存各取前 N 行，两份都截断过：只用其中一份做本地排序，
  /// 会漏掉「内存很高但 CPU 为 0」这类进程（它根本不在 CPU 榜里）。按 PID 去重合并后
  /// 两个维度的头部都在候选集里，本地怎么排都不会凭空少一行。
  ///
  /// 同 PID 以 `byCPU` 的那份为准：两份来自同一次 `ps` 采样，字段本就相同，固定取一边
  /// 只是为了结果稳定。
  public static func merged(
    byCPU: [RemoteProcessSample],
    byMemory: [RemoteProcessSample],
    sort: RemoteProcessSort,
    limit: Int = maximumRows
  ) -> [RemoteProcessSample] {
    var seen: Set<Int32> = []
    var candidates: [RemoteProcessSample] = []
    for sample in byCPU + byMemory where seen.insert(sample.pid).inserted {
      candidates.append(sample)
    }

    let ascending = sort.order == .ascending
    candidates.sort { lhs, rhs in
      let left = value(of: lhs, column: sort.column)
      let right = value(of: rhs, column: sort.column)
      // 同值时按 PID 兜底，避免每次刷新行顺序抖动。
      if left == right { return lhs.pid < rhs.pid }
      return ascending ? left < right : left > right
    }
    return Array(candidates.prefix(max(0, limit)))
  }

  private static func value(of sample: RemoteProcessSample, column: RemoteProcessSortColumn)
    -> Double
  {
    switch column {
    case .cpu: sample.cpuPercent
    case .memory: Double(sample.residentKiB)
    }
  }
}
