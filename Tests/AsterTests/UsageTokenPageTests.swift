// Token 页的数字格式、区间切换、展开行与热力图行为。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 只产出一条固定 bucket 的假数据源，用来让页面真的走一遍取数路径。
private struct StubTokenSource: TokenUsageSource {
  let provider: AgentProvider = .claudeCode

  func discoverFiles(homeDirectory: URL) -> [TokenSourceFile] {
    [TokenSourceFile(path: "/fixture/stub.jsonl", size: 1, modified: 1)]
  }

  func buckets(of file: TokenSourceFile, context: TokenScanContext) -> [TokenBucket] {
    [TokenBucket(day: 20_000, project: "/fixture/p", totals: TokenTotals(input: 7))]
  }
}

@MainActor
private func makeDefaults() throws -> UserDefaults {
  let suite = "UsageTokenPageTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

@MainActor
private func makeController(defaults: UserDefaults) -> UsageTokenSectionController {
  UsageTokenSectionController(
    service: TokenStatsService(
      homeDirectory: URL(fileURLWithPath: "/fixture/home"), cacheURL: nil,
      sources: [StubTokenSource()], timeZone: .current),
    defaults: defaults)
}

private func sample(day: Int, project: String, total: Int64) -> TokenSample {
  TokenSample(
    day: day, project: project, provider: .claudeCode, totals: TokenTotals(input: total))
}

/// 递归收集视图树里的 identifier，用来断言某个子视图是否出现在页面上。
@MainActor
private func identifiers(in view: NSView) -> [String] {
  var found: [String] = []
  if let identifier = view.identifier?.rawValue { found.append(identifier) }
  for subview in view.subviews { found.append(contentsOf: identifiers(in: subview)) }
  return found
}

@MainActor
@Suite("UsageTokenPage Token 页")
struct UsageTokenPageTests {
  @Test("紧凑数字格式按档进位")
  func compactNumberFormat() {
    #expect(TokenNumberText.compact(0) == "0")
    #expect(TokenNumberText.compact(999) == "999")
    #expect(TokenNumberText.compact(1_000) == "1K")
    #expect(TokenNumberText.compact(1_234) == "1.2K")
    #expect(TokenNumberText.compact(34_700_000) == "34.7M")
    #expect(TokenNumberText.compact(3_400_000_000) == "3.4B")
    // 保留一位小数后又满一千的要继续进位，否则会写成 1000.0K。
    #expect(TokenNumberText.compact(999_999) == "1M")
  }

  @Test("切换区间会改变汇总并持久化选择")
  func rangeSelectionUpdatesSummaryAndPersists() throws {
    let defaults = try makeDefaults()
    let controller = makeController(defaults: defaults)
    let today = LocalDayStamper.today()
    controller.apply(samples: [
      sample(day: today, project: "/a", total: 100),
      sample(day: today - 10, project: "/a", total: 900),
    ])

    let weekly = try #require(controller.summary)
    #expect(weekly.range == .sevenDays)
    #expect(weekly.totals.total == 100)

    controller.selectRange(.all)
    let all = try #require(controller.summary)
    #expect(all.range == .all)
    #expect(all.totals.total == 1_000)
    #expect(defaults.string(forKey: UsageTokenSectionController.rangeDefaultsKey) == "all")
  }

  @Test("恢复持久化的区间选择")
  func restoresPersistedRange() throws {
    let defaults = try makeDefaults()
    defaults.set(TokenStatsRange.thirtyDays.rawValue, forKey: UsageTokenSectionController.rangeDefaultsKey)
    #expect(makeController(defaults: defaults).range == .thirtyDays)
  }

  @Test("挂起后没有在途扫描，迟到的结果不落到界面上")
  func suspendCancelsLoadAndDropsLateResults() async throws {
    let defaults = try makeDefaults()
    let controller = makeController(defaults: defaults)
    controller.activate()
    #expect(controller.hasInFlightLoad)

    controller.suspend()
    #expect(controller.hasInFlightLoad == false)

    // 扫描本身仍会跑完（服务要把半成品缓存收尾），但 generation 已经变了，结果必须被丢弃。
    try await Task.sleep(for: .milliseconds(300))
    #expect(controller.summary == nil)
  }

  @Test("点击项目行展开热力图，再点收起")
  func projectRowTogglesHeatmap() throws {
    let defaults = try makeDefaults()
    let controller = makeController(defaults: defaults)
    let today = LocalDayStamper.today()
    controller.apply(samples: [
      sample(day: today, project: "/a", total: 100),
      sample(day: today, project: "/b", total: 50),
    ])
    #expect(controller.expandedProject == nil)
    #expect(!identifiers(in: controller.view).contains("usage-token-project-heatmap"))

    controller.toggleProject("/a")
    #expect(controller.expandedProject == "/a")
    let expanded = identifiers(in: controller.view).filter { $0 == "usage-token-project-heatmap" }
    #expect(expanded.count == 1)

    controller.toggleProject("/b")
    #expect(controller.expandedProject == "/b")
    #expect(
      identifiers(in: controller.view).filter { $0 == "usage-token-project-heatmap" }.count == 1)

    controller.toggleProject("/b")
    #expect(controller.expandedProject == nil)
    #expect(!identifiers(in: controller.view).contains("usage-token-project-heatmap"))
  }

  @Test("热力图收到相同数据不再请求重绘")
  func heatmapSkipsRedrawForIdenticalCells() {
    let view = TokenHeatmapView()
    let today = LocalDayStamper.today()
    let cells = TokenActivityHeatmap.cells(dailyTotals: [today: 10], today: today)
    view.apply(cells: cells)
    let baseline = view.redrawRequestCount
    #expect(baseline > 0)

    view.apply(cells: cells)
    #expect(view.redrawRequestCount == baseline)

    view.apply(cells: TokenActivityHeatmap.cells(dailyTotals: [today: 20], today: today))
    #expect(view.redrawRequestCount > baseline)
  }

  @Test("热力图悬停给出当天日期与用量")
  func heatmapTooltipDescribesCell() throws {
    let view = TokenHeatmapView()
    view.showsMonthScale = false
    view.frame = NSRect(x: 0, y: 0, width: 581, height: 80)
    let today = LocalDayStamper.today()
    view.apply(cells: TokenActivityHeatmap.cells(dailyTotals: [today: 1_200_000], today: today))

    // 今天固定落在最后一列，行号就是它的星期序号。
    let step = TokenHeatmapView.idealCellSize + TokenHeatmapView.idealSpacing
    let column = CGFloat(TokenActivityHeatmap.weekColumns - 1)
    let row = CGFloat(TokenActivityHeatmap.weekdayIndex(today))
    let point = NSPoint(x: column * step + 2, y: row * step + 2)

    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    let expected = formatter.string(from: TokenActivityHeatmap.date(forDay: today))

    let text = try #require(view.tooltipText(at: point))
    #expect(text.contains(expected))
    #expect(text.contains("1.2M"))
    #expect(view.tooltipText(at: NSPoint(x: -10, y: -10)) == nil)
  }
}
