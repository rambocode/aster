// 一年活动热力图的纯数据模型：53 周 × 7 天，按分位数分 4 级。移植自 jettoai/tally（MIT）。
import Foundation

public enum TokenActivityHeatmap {
  /// 52 周再加 1–2 天，52 列会把最早的几天截掉。
  public static let weekColumns = 53
  public static let weekdays = 7
  /// 1–4 级对应的不透明度；0 级（无活动）由视图画成空格。
  public static let levelOpacity: [Double] = [0.25, 0.45, 0.7, 1.0]

  /// 一个格子。`level` 为 0（无活动）到 4。
  public struct Cell: Equatable, Sendable {
    public var day: Int
    public var column: Int
    public var row: Int
    public var total: Int64
    public var level: Int

    public init(day: Int, column: Int, row: Int, total: Int64, level: Int) {
      self.day = day
      self.column = column
      self.row = row
      self.total = total
      self.level = level
    }
  }

  /// 本地日对应的星期序号，周一 = 0。1970-01-01 是周四，所以加 3。
  public static func weekdayIndex(_ day: Int) -> Int { ((day + 3) % 7 + 7) % 7 }

  /// 窗口第一列的周一。
  public static func windowStart(today: Int) -> Int {
    today - weekdayIndex(today) - (weekColumns - 1) * weekdays
  }

  /// 生成格子（列优先）。未来的日子不出格子。
  ///
  /// 分级用窗口内活跃日的 p25 / p50 / p75，而不是线性刻度：缓存读取会让一个重度日
  /// 抵上百个普通日，线性刻度只会画出一片灰里一个亮点。
  public static func cells(dailyTotals: [Int: Int64], today: Int) -> [Cell] {
    // 骨架：由「token 内核」任务实现。
    []
  }
}
