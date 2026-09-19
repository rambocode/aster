// 汇总的区间过滤、排行与「其他」归并，以及热力图的排版与分级。
import Foundation
import Testing

@testable import AsterCore

private let today = 20_000

private func sample(
  day: Int = today, project: String, provider: AgentProvider = .claudeCode, total: Int64
) -> TokenSample {
  TokenSample(
    day: day, project: project, provider: provider, totals: TokenTotals(input: total))
}

@Suite("TokenStats 汇总")
struct TokenStatsSummaryTests {
  @Test("区间按本地日整数过滤，today 只含当天")
  func rangeFiltersByDay() {
    let samples = [
      sample(day: today, project: "/p/a", total: 100),
      sample(day: today - 3, project: "/p/a", total: 20),
      sample(day: today - 10, project: "/p/a", total: 5),
    ]
    func total(_ range: TokenStatsRange) -> Int64 {
      TokenStatsSummary.make(samples: samples, range: range, today: today).totals.total
    }
    #expect(total(.today) == 100)
    #expect(total(.sevenDays) == 120)  // earliest = today - 6
    #expect(total(.thirtyDays) == 125)
    #expect(total(.all) == 125)
  }

  @Test("项目按 total 降序排列，占比之和为 1")
  func projectsRankByTotal() {
    let samples = [
      sample(project: "/p/small", total: 10),
      sample(project: "/p/big", total: 100),
      sample(project: "/p/mid", total: 50),
    ]
    let summary = TokenStatsSummary.make(samples: samples, range: .all, today: today)
    #expect(summary.projects.map(\.key) == ["/p/big", "/p/mid", "/p/small"])
    #expect(summary.projects.map(\.name) == ["big", "mid", "small"])
    #expect(abs(summary.projects.reduce(0) { $0 + $1.share } - 1) < 0.000_1)
  }

  @Test("超过上限的项目并入「其他」，未归属的用量也在同一行")
  func tailProjectsArePooled() {
    var samples: [TokenSample] = []
    // 17 个项目，总量依次递减；前 15 个单独成行，后 2 个并入「其他」。
    for index in 0..<17 {
      samples.append(sample(project: "/p/\(index)", total: Int64(1_000 - index)))
    }
    samples.append(sample(project: TokenProject.otherKey, total: 7))

    let summary = TokenStatsSummary.make(samples: samples, range: .all, today: today)
    #expect(summary.projects.count == TokenStatsSummary.projectRowLimit + 1)
    let last = summary.projects.last
    #expect(last?.key == TokenProject.otherKey)
    #expect(last?.name == "其他")
    // 7（未归属）+ 985 + 984（被挤出榜单的两个项目）。先解包再比较：
    // `#expect` 里「可选链 == 算术表达式」这种写法会被宏改写错，得到永远为假的断言。
    let pooledTotal = last?.totals.total ?? 0
    #expect(pooledTotal == 1_976)
    // 明细加总必须等于总数。
    #expect(summary.projects.reduce(Int64(0)) { $0 + $1.totals.total } == summary.totals.total)
  }

  @Test("最后一段重名的项目自动扩成两段路径")
  func duplicateNamesAreWidened() {
    let samples = [
      sample(project: "/x/web/src", total: 100),
      sample(project: "/y/api/src", total: 50),
      sample(project: "/z/lib", total: 10),
    ]
    let summary = TokenStatsSummary.make(samples: samples, range: .all, today: today)
    #expect(summary.projects.map(\.name) == ["web/src", "api/src", "lib"])
  }

  @Test("曾经有过数据的 provider 在空区间仍然保留行，顺序跟随目录")
  func providersKeepTheirRowInEmptyRanges() {
    let samples = [
      sample(day: today, project: "/p/a", provider: .claudeCode, total: 100),
      sample(day: today - 10, project: "/p/a", provider: .codex, total: 40),
    ]
    let summary = TokenStatsSummary.make(samples: samples, range: .today, today: today)
    #expect(summary.providers.map(\.provider) == [.claudeCode, .codex])
    #expect(summary.providers.first?.totals.total == 100)
    // 换区间只该改数字，不该改布局。
    #expect(summary.providers.last?.totals.isEmpty == true)
  }

  @Test("没有任何样本时汇总为空而不是崩溃")
  func emptySamplesProduceEmptySummary() {
    let summary = TokenStatsSummary.make(samples: [], range: .all, today: today)
    #expect(summary.totals.isEmpty)
    #expect(summary.projects.isEmpty)
    #expect(summary.providers.isEmpty)
  }

  @Test("每日总量可按项目过滤，nil 表示全部")
  func dailyTotalsFilterByProject() {
    let samples = [
      sample(day: today, project: "/p/a", total: 10),
      sample(day: today, project: "/p/b", total: 5),
      sample(day: today - 1, project: "/p/a", total: 7),
    ]
    #expect(
      TokenStatsSummary.dailyTotals(samples: samples, project: nil)
        == [today: 15, today - 1: 7])
    #expect(
      TokenStatsSummary.dailyTotals(samples: samples, project: "/p/a")
        == [today: 10, today - 1: 7])
    #expect(TokenStatsSummary.dailyTotals(samples: samples, project: "/p/none").isEmpty)
  }
}

@Suite("TokenStats 活动热力图")
struct TokenStatsHeatmapTests {
  @Test("周一为第 0 行，1970-01-01 落在周四")
  func weekdayIndexIsMondayFirst() {
    #expect(TokenActivityHeatmap.weekdayIndex(0) == 3)  // 1970-01-01 是周四
    #expect(TokenActivityHeatmap.weekdayIndex(4) == 0)  // 1970-01-05 是周一
    #expect(TokenActivityHeatmap.weekdayIndex(10) == 6)
    // 纪元之前的日子不能向前索引成负数。
    #expect(TokenActivityHeatmap.weekdayIndex(-1) == 2)
  }

  @Test("窗口第一列永远从周一开始")
  func windowStartsOnMonday() {
    for offset in 0..<14 {
      let day = today + offset
      #expect(TokenActivityHeatmap.weekdayIndex(TokenActivityHeatmap.windowStart(today: day)) == 0)
    }
  }

  @Test("本周今天之后的日子不出格子")
  func futureDaysAreOmitted() {
    let cells = TokenActivityHeatmap.cells(dailyTotals: [:], today: today)
    let weekday = TokenActivityHeatmap.weekdayIndex(today)
    let expected = TokenActivityHeatmap.weekColumns * TokenActivityHeatmap.weekdays - (6 - weekday)
    #expect(cells.count == expected)
    #expect(cells.map(\.day).max() == today)
    #expect(cells.allSatisfy { $0.level == 0 })
    // 列优先：同一列的行号连续。
    #expect(cells.first?.column == 0)
    #expect(cells.first?.row == 0)
  }

  @Test("窗口之外的日子既不出格子也不计入窗口总量")
  func daysOutsideWindowAreIgnored() {
    let start = TokenActivityHeatmap.windowStart(today: today)
    let totals = [start - 1: Int64(999), start: Int64(10), today: Int64(20)]
    let cells = TokenActivityHeatmap.cells(dailyTotals: totals, today: today)
    #expect(cells.contains { $0.day == start && $0.total == 10 })
    #expect(!cells.contains { $0.day == start - 1 })
    #expect(TokenActivityHeatmap.windowTotal(dailyTotals: totals, today: today) == 30)
  }

  @Test("分级按活跃日的 p25 / p50 / p75 切，四级都够得着")
  func levelsFollowQuartiles() {
    let values: [Int64] = [1, 2, 3, 4, 5, 6, 7, 8]
    let bounds = TokenActivityHeatmap.thresholds(values)
    #expect(bounds == [3, 5, 6])
    #expect(TokenActivityHeatmap.level(for: 0, thresholds: bounds) == 0)
    #expect(TokenActivityHeatmap.level(for: 1, thresholds: bounds) == 1)
    #expect(TokenActivityHeatmap.level(for: 3, thresholds: bounds) == 1)
    #expect(TokenActivityHeatmap.level(for: 4, thresholds: bounds) == 2)
    #expect(TokenActivityHeatmap.level(for: 6, thresholds: bounds) == 3)
    #expect(TokenActivityHeatmap.level(for: 8, thresholds: bounds) == 4)
  }

  @Test("每天用量相同的项目整体落在 1 级")
  func flatHistoryStaysAtLevelOne() {
    let bounds = TokenActivityHeatmap.thresholds([100, 100, 100])
    #expect(bounds == [100, 100, 100])
    #expect(TokenActivityHeatmap.level(for: 100, thresholds: bounds) == 1)
    #expect(TokenActivityHeatmap.thresholds([]) == [0, 0, 0])
  }

  @Test("分级只看窗口内的活跃日，窗口外的高峰不压低当前刻度")
  func scaleIgnoresDaysOutsideWindow() {
    let start = TokenActivityHeatmap.windowStart(today: today)
    var totals: [Int: Int64] = [start - 30: 1_000_000]
    for offset in 0..<8 { totals[today - offset] = Int64(offset + 1) }
    let cells = TokenActivityHeatmap.cells(dailyTotals: totals, today: today)
    // 如果把窗口外那个百万级的日子算进刻度，窗口内所有天都会压到 1 级。
    #expect(cells.contains { $0.day == today - 7 && $0.level == 4 })
  }

  @Test("日整数对应该日历日的 UTC 零点")
  func dayIntegerMapsToUTCMidnight() {
    let date = TokenActivityHeatmap.date(forDay: LocalDayStamper.daysFromCivil(2026, 7, 17))
    let formatter = ISO8601DateFormatter()
    formatter.timeZone = TimeZone(identifier: "UTC")
    #expect(formatter.string(from: date) == "2026-07-17T00:00:00Z")
  }
}
