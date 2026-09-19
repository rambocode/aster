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
    let start = windowStart(today: today)
    // 刻度只看画面上的这些天。一个项目曾经有过疯狂的一周然后归于平静，
    // 不该因为一个已经看不见的格子而让接下来一整年都停在 1 级。
    let bounds = thresholds(
      dailyTotals.filter { $0.key >= start && $0.key <= today && $0.value > 0 }.map(\.value))
    var cells: [Cell] = []
    cells.reserveCapacity(weekColumns * weekdays)
    for column in 0..<weekColumns {
      let monday = start + column * weekdays
      // 本周今天之后的日子不出格子：空格子的含义是「这天什么都没发生」，
      // 而下个周六还没轮到它。
      for row in 0..<weekdays where monday + row <= today {
        let day = monday + row
        let total = dailyTotals[day] ?? 0
        cells.append(
          Cell(
            day: day, column: column, row: row, total: total,
            level: level(for: total, thresholds: bounds)))
      }
    }
    return cells
  }

  /// 这个项目自己活跃日的 p25 / p50 / p75 分位数。
  ///
  /// 用分位数而不是线性刻度，是因为语料极度右偏：缓存读取让一个重 agent 日抵上百个普通日，
  /// 线性刻度画出来就是一年灰底上一个亮点。按项目各算各的，是因为项目之间差两三个数量级，
  /// 共用一套刻度会让所有小项目常年平铺在 1 级。
  public static func thresholds(_ values: [Int64]) -> [Int64] {
    guard !values.isEmpty else { return [0, 0, 0] }
    let sorted = values.sorted()
    return [0.25, 0.5, 0.75].map { quantile in
      let index = Int((Double(sorted.count - 1) * quantile).rounded())
      return sorted[min(max(index, 0), sorted.count - 1)]
    }
  }

  /// 某一天落在哪一级；没有任何用量时为 0。
  ///
  /// 每天用量都一样的项目会整体落在 1 级：每条分位线都压在那个唯一值上，这里没有依据说哪天更重。
  /// 这个结果是对的——平坦的一年**本来就是**平的，而 1 级仍然明显比空格子深。
  public static func level(for total: Int64, thresholds: [Int64]) -> Int {
    guard total > 0 else { return 0 }
    guard thresholds.count == 3 else { return levelOpacity.count }
    if total <= thresholds[0] { return 1 }
    if total <= thresholds[1] { return 2 }
    if total <= thresholds[2] { return 3 }
    return 4
  }

  /// 图下方说明文字里的数字：画出来的这个窗口内的 token 数，不是项目全部历史。
  /// 上面一行是区间总量、这里是一年，两个数字本来就不该相等，靠说明文字避免被当成 bug。
  public static func windowTotal(dailyTotals: [Int: Int64], today: Int) -> Int64 {
    let start = windowStart(today: today)
    return dailyTotals.reduce(Int64(0)) { sum, entry in
      (entry.key >= start && entry.key <= today) ? sum + entry.value : sum
    }
  }

  /// 日整数对应的时刻：该日历日的 UTC 零点。
  ///
  /// 调用方必须用 UTC 格式化它，因为这个整数本身**已经是**本地日历日；
  /// 再按本地时区读一遍，格林尼治以西的所有地方都会显示成前一天。
  public static func date(forDay day: Int) -> Date {
    Date(timeIntervalSince1970: TimeInterval(day) * 86_400)
  }
}
