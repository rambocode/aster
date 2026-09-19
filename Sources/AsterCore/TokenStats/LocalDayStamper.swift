// 把 transcript 里的 UTC 时间戳换算成本地日整数。移植自 jettoai/tally（MIT）的 LocalDayStamper。
import Foundation

/// ISO-8601 时间戳 → 本地日（自 1970-01-01 起的天数）。
///
/// 这条路径上既不用 `ISO8601DateFormatter` 也不用 `Calendar`：两者单次调用的开销都远高于这里的
/// 几次整数运算，而这段代码要对上百万条 usage 记录各跑一次。时区偏移只在 UTC 小时变化时向
/// Foundation 问一次——时区切换总是落在整点边界上所以结果精确，而 transcript 的行本来就按时间
/// 递增，命中率接近 100%。
public struct LocalDayStamper {
  private let zone: TimeZone
  private var cachedHour: Int64 = .min
  private var cachedOffset: Int64 = 0

  public init(zone: TimeZone = .current) { self.zone = zone }

  /// Unix 秒对应的本地日。
  public mutating func day(forEpochSeconds seconds: Int64) -> Int {
    let hour = Self.floorDiv(seconds, 3_600)
    if hour != cachedHour {
      cachedHour = hour
      cachedOffset = Int64(
        zone.secondsFromGMT(for: Date(timeIntervalSince1970: TimeInterval(seconds))))
    }
    return Int(Self.floorDiv(seconds + cachedOffset, 86_400))
  }

  /// 形如 `2026-07-17T11:52:33.310Z` 的 ISO 时间戳对应的本地日；形态不符时返回 nil。
  public mutating func day(fromISO scan: JSONScan, _ range: Range<Int>) -> Int? {
    guard let seconds = Self.epochSeconds(scan, range) else { return nil }
    return day(forEpochSeconds: seconds)
  }

  /// 今天的本地日整数，所有区间窗口都从这里往回数。
  public static func today(zone: TimeZone = .current, now: Date = Date()) -> Int {
    var stamper = LocalDayStamper(zone: zone)
    return stamper.day(forEpochSeconds: Int64(now.timeIntervalSince1970.rounded(.down)))
  }

  /// `"yyyy-MM-ddTHH:mm:ss…Z"` 字符串值（含引号）对应的 Unix 秒。
  ///
  /// 只读定宽前缀：小数秒和末尾的时区标记一律忽略，因为这里所有写入方都输出 UTC。
  public static func epochSeconds(_ scan: JSONScan, _ range: Range<Int>) -> Int64? {
    guard range.count >= 21 else { return nil }  // "yyyy-MM-ddTHH:mm:ssZ"
    let start = range.lowerBound + 1  // 跳过开引号
    func digits(_ offset: Int, _ count: Int) -> Int? {
      var value = 0
      for i in (start + offset)..<(start + offset + count) {
        let c = scan.bytes[i]
        guard c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") else { return nil }
        value = value * 10 + Int(c - UInt8(ascii: "0"))
      }
      return value
    }
    guard let year = digits(0, 4), let month = digits(5, 2), let day = digits(8, 2),
      let hour = digits(11, 2), let minute = digits(14, 2), let second = digits(17, 2),
      month >= 1, month <= 12, day >= 1, day <= 31
    else { return nil }
    return Int64(daysFromCivil(year, month, day)) * 86_400
      + Int64(hour) * 3_600 + Int64(minute) * 60 + Int64(second)
  }

  /// 先发格里高利历日期自 1970-01-01 起的天数（Howard Hinnant 的 `days_from_civil`）。
  public static func daysFromCivil(_ year: Int, _ month: Int, _ day: Int) -> Int {
    let y = year - (month <= 2 ? 1 : 0)
    let era = (y >= 0 ? y : y - 399) / 400
    let yoe = y - era * 400  // [0, 399]
    let doy = (153 * (month + (month > 2 ? -3 : 9)) + 2) / 5 + day - 1
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy  // [0, 146096]
    return era * 146_097 + doe - 719_468
  }

  /// 向下取整的整数除法。直接用 `/` 会向零取整，1970 年之前的时间戳会算到后一天。
  private static func floorDiv(_ value: Int64, _ divisor: Int64) -> Int64 {
    let quotient = value / divisor
    return (value % divisor < 0) ? quotient - 1 : quotient
  }
}
