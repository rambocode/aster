// Token 页的数字格式、卡片布局、区间切换、展开行与热力图行为。
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

/// 递归收集某个类型的全部子视图。行视图是自定义类型，按类型找比按 identifier 找更直接。
@MainActor
private func descendants<T: NSView>(ofType type: T.Type, in view: NSView) -> [T] {
  var found: [T] = []
  if let match = view as? T { found.append(match) }
  for subview in view.subviews { found.append(contentsOf: descendants(ofType: type, in: subview)) }
  return found
}

/// 把页面放进固定尺寸并算好布局，之后才能拿 frame 断言几何关系。
/// 默认用浮动窗的默认尺寸 440×600。
@MainActor
private func layout(_ view: NSView, width: CGFloat = 440, height: CGFloat = 600) {
  view.frame = NSRect(x: 0, y: 0, width: width, height: height)
  view.layoutSubtreeIfNeeded()
}

/// 视图树里最靠右的边缘（换算到 `root` 坐标系）。用来确认窄面板下内容没有横向溢出。
@MainActor
private func maxRight(in root: NSView, from view: NSView? = nil) -> CGFloat {
  let current = view ?? root
  var edge = root.convert(current.bounds, from: current).maxX
  for subview in current.subviews { edge = max(edge, maxRight(in: root, from: subview)) }
  return edge
}

/// 标签是否完整显示（没被截断）。
@MainActor
private func fitsWithoutTruncation(_ label: NSTextField) -> Bool {
  label.frame.width + 0.5 >= label.intrinsicContentSize.width
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
    #expect(TokenNumberText.compact(1_000_000) == "1M")
    #expect(TokenNumberText.compact(1_050_000) == "1.1M")
    #expect(TokenNumberText.compact(34_700_000) == "34.7M")
    #expect(TokenNumberText.compact(1_000_000_000) == "1B")
    #expect(TokenNumberText.compact(3_400_000_000) == "3.4B")
    // 保留一位小数后又满一千的要继续进位，否则会写成 1000.0K。
    #expect(TokenNumberText.compact(999_999) == "1M")
  }

  @Test("占比文本在小数值上保留一位小数")
  func percentFormat() {
    #expect(TokenNumberText.percent(1) == "100%")
    #expect(TokenNumberText.percent(0.4237) == "42%")
    #expect(TokenNumberText.percent(0.032) == "3.2%")
    #expect(TokenNumberText.percent(0.0003) == "<0.1%")
    #expect(TokenNumberText.percent(0) == "0%")
  }

  @Test("总量卡四列是标签在上、数值在下")
  func totalsColumnsPutLabelAboveValue() throws {
    let defaults = try makeDefaults()
    let controller = makeController(defaults: defaults)
    controller.apply(samples: [
      sample(day: LocalDayStamper.today(), project: "/a", total: 100)
    ])
    layout(controller.view)

    let columns = descendants(ofType: UsageTokenTotalsColumn.self, in: controller.view)
    #expect(
      columns.compactMap { $0.identifier?.rawValue } == [
        "usage-token-total-input", "usage-token-total-cache-write",
        "usage-token-total-cache-read", "usage-token-total-output",
      ])
    for column in columns {
      // 层级顺序：标签是第一个 arranged subview，数值是第二个。
      #expect(column.arrangedSubviews.first === column.titleLabel)
      #expect(column.arrangedSubviews.last === column.valueLabel)
      // 几何：AppKit 默认坐标系原点在左下，画在上面的那个 y 更大。
      #expect(column.titleLabel.frame.minY > column.valueLabel.frame.minY)
    }
  }

  @Test("按 Agent 行不画进度条，按项目行才有")
  func agentRowsHaveNoProgressTrack() throws {
    let defaults = try makeDefaults()
    let controller = makeController(defaults: defaults)
    controller.apply(samples: [
      sample(day: LocalDayStamper.today(), project: "/a", total: 100)
    ])

    let agentRows = descendants(ofType: UsageTokenAgentRow.self, in: controller.view)
    #expect(agentRows.count == 1)
    for row in agentRows {
      #expect(!identifiers(in: row).contains("usage-token-share-track"))
    }

    let projectRows = descendants(ofType: UsageTokenProjectRow.self, in: controller.view)
    #expect(projectRows.count == 1)
    for row in projectRows {
      #expect(identifiers(in: row).contains("usage-token-share-track"))
    }
  }

  @Test("区间切换用统一分段控件，identifier 保持 usage-token-range-<id>")
  func rangeUsesSharedSegmentedControl() throws {
    let defaults = try makeDefaults()
    let controller = makeController(defaults: defaults)
    controller.apply(samples: [
      sample(day: LocalDayStamper.today(), project: "/a", total: 100)
    ])

    let control = try #require(
      descendants(ofType: UsageSegmentedControl.self, in: controller.view).first)
    #expect(control.identifier?.rawValue == "usage-token-range-track")
    #expect(control.selection == TokenStatsRange.sevenDays.rawValue)

    let found = identifiers(in: controller.view)
    for range in TokenStatsRange.allCases {
      #expect(found.contains("usage-token-range-\(range.rawValue)"))
    }

    // 代码侧切区间要把分段控件一起带过去，胶囊不能留在旧格上。
    controller.selectRange(.all)
    #expect(control.selection == TokenStatsRange.all.rawValue)
  }

  @Test("卡片外观走共用的 UsageCardStyle，不自带一套常量")
  func cardsFollowSharedStyle() throws {
    let defaults = try makeDefaults()
    let controller = makeController(defaults: defaults)
    controller.apply(samples: [
      sample(day: LocalDayStamper.today(), project: "/a", total: 100)
    ])
    layout(controller.view)

    let cards = descendants(ofType: UsageTokenCardView.self, in: controller.view)
    #expect(cards.count == 4)
    for card in cards {
      #expect(card.layer?.cornerRadius == UsageCardStyle.cornerRadius)
      #expect(card.layer?.borderWidth == UsageCardStyle.borderWidth)
      // 磨砂背景下卡片要自带一层压得住的板子，否则内容会被透出来的桌面冲淡。
      #expect((card.layer?.backgroundColor?.alpha ?? 0) >= UsageCardStyle.fillAlpha)
      #expect(card.rows.frame.minX == UsageCardStyle.contentInset)
    }
  }

  @Test("440pt 宽的面板下不横向溢出，占比与数值不被截断")
  func fitsDefaultPanelWidth() throws {
    let defaults = try makeDefaults()
    let controller = makeController(defaults: defaults)
    let today = LocalDayStamper.today()
    controller.apply(samples: [
      sample(day: today, project: "/Users/mike/source/project/a-very-long-project-name", total: 987_654_321),
      sample(day: today, project: "/b", total: 1_234),
    ])

    // 默认 440 与最小 380 两档都要站得住。
    for width in [CGFloat(440), CGFloat(380)] {
      layout(controller.view, width: width, height: 600)
      #expect(maxRight(in: controller.view) <= width + 0.5)

      for row in descendants(ofType: UsageTokenProjectRow.self, in: controller.view) {
        #expect(fitsWithoutTruncation(row.percentLabel))
        #expect(fitsWithoutTruncation(row.valueLabel))
        #expect(row.track.frame.width >= 24)
      }
      for row in descendants(ofType: UsageTokenAgentRow.self, in: controller.view) {
        #expect(fitsWithoutTruncation(row.percentLabel))
        #expect(fitsWithoutTruncation(row.valueLabel))
      }
      // 总量卡四列等分后仍要放得下数值。
      for column in descendants(ofType: UsageTokenTotalsColumn.self, in: controller.view) {
        #expect(fitsWithoutTruncation(column.valueLabel))
      }
      // 热力图整年 53 列都在视图里，不靠截掉右边的周来省宽度。
      for view in descendants(ofType: TokenHeatmapView.self, in: controller.view) {
        let last = view.cellFrame(column: TokenActivityHeatmap.weekColumns - 1, row: 0)
        #expect(last.maxX <= view.frame.width + 0.5)
        #expect(view.cellFrame(column: 0, row: 0).minX >= view.gridInset)
      }
    }
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
    defaults.set(
      TokenStatsRange.thirtyDays.rawValue, forKey: UsageTokenSectionController.rangeDefaultsKey)
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

  @Test("点击项目行展开热力图，再点收起，同一时刻只展开一行")
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
    #expect(
      identifiers(in: controller.view).filter { $0 == "usage-token-project-heatmap" }.count == 1)

    controller.toggleProject("/b")
    #expect(controller.expandedProject == "/b")
    #expect(
      identifiers(in: controller.view).filter { $0 == "usage-token-project-heatmap" }.count == 1)

    controller.toggleProject("/b")
    #expect(controller.expandedProject == nil)
    #expect(!identifiers(in: controller.view).contains("usage-token-project-heatmap"))
  }

  @Test("展开块插在被展开的那一行正下方")
  func expansionSitsRightBelowItsRow() throws {
    let defaults = try makeDefaults()
    let controller = makeController(defaults: defaults)
    let today = LocalDayStamper.today()
    controller.apply(samples: [
      sample(day: today, project: "/a", total: 100),
      sample(day: today, project: "/b", total: 50),
    ])
    controller.toggleProject("/b")

    let card = try #require(
      descendants(ofType: UsageTokenCardView.self, in: controller.view)
        .first { $0.identifier?.rawValue == "usage-token-projects" })
    let arranged = card.rows.arrangedSubviews
    let rowIndex = try #require(
      arranged.firstIndex { $0.identifier?.rawValue == "usage-token-project-/b" })
    #expect(arranged[rowIndex + 1].identifier?.rawValue == "usage-token-project-expansion")
    #expect(
      descendants(ofType: UsageTokenProjectRow.self, in: controller.view).filter(\.isExpanded)
        .count == 1)
  }

  @Test("切换区间后展开的项目仍然展开")
  func expansionSurvivesRangeChange() throws {
    let defaults = try makeDefaults()
    let controller = makeController(defaults: defaults)
    let today = LocalDayStamper.today()
    controller.apply(samples: [
      sample(day: today, project: "/a", total: 100),
      sample(day: today - 20, project: "/a", total: 900),
    ])
    controller.toggleProject("/a")
    controller.selectRange(.all)

    #expect(controller.expandedProject == "/a")
    #expect(
      identifiers(in: controller.view).filter { $0 == "usage-token-project-heatmap" }.count == 1)
  }

  @Test("热力图左侧有周一 / 周三 / 周五三个行标签且对齐到对应行")
  func heatmapDrawsWeekdayLabels() {
    let view = TokenHeatmapView()
    view.frame = NSRect(x: 0, y: 0, width: 520, height: 120)
    let today = LocalDayStamper.today()
    view.apply(cells: TokenActivityHeatmap.cells(dailyTotals: [today: 10], today: today))

    let labels = view.weekdayLabels()
    #expect(labels.map(\.row) == [0, 2, 4])
    #expect(labels.map(\.text) == [L("周一"), L("周三"), L("周五")])
    for label in labels {
      let cell = view.cellFrame(column: 0, row: label.row)
      // 标签占固定宽度的左栏，竖直中线对齐到该行的格子。
      #expect(abs(label.frame.midY - cell.midY) < 1.5)
      #expect(label.frame.maxX <= view.gridInset)
      #expect(cell.minX >= view.gridInset)
    }

    view.showsWeekdayScale = false
    #expect(view.weekdayLabels().isEmpty)
    #expect(view.gridInset == 0)
    #expect(view.cellFrame(column: 0, row: 0).minX == 0)
  }

  @Test("展开的项目热力图与底部热力图同宽，440pt 下都画得出月份刻度")
  func projectHeatmapKeepsMonthScale() throws {
    let defaults = try makeDefaults()
    let controller = makeController(defaults: defaults)
    let today = LocalDayStamper.today()
    controller.apply(samples: [
      sample(day: today, project: "/a", total: 100),
      sample(day: today - 200, project: "/a", total: 4_000),
    ])
    controller.toggleProject("/a")
    layout(controller.view)

    let heatmaps = descendants(ofType: TokenHeatmapView.self, in: controller.view)
    #expect(heatmaps.count == 2)
    // 两张图走同一套布局，可用宽度也一样：内嵌那张不该因为「更窄」而少画东西。
    #expect(Set(heatmaps.map(\.frame.width)).count == 1)
    for view in heatmaps {
      #expect(view.monthLabels().count >= 4)
      #expect(view.cellFrame(column: 0, row: 0).minY == TokenHeatmapView.monthScaleHeight)
    }
  }

  @Test("窄到摆不满月份时退化成锚点月份，互不重叠")
  func monthScaleDegradesToAnchors() {
    let view = TokenHeatmapView()
    let today = LocalDayStamper.today()
    view.apply(cells: TokenActivityHeatmap.cells(dailyTotals: [today: 10], today: today))

    // 110pt：宽松间距摆不满，必须退化到紧凑间距，锚点月份不能一个不剩。
    view.frame = NSRect(x: 0, y: 0, width: 110, height: 120)
    let months = view.monthLabels()
    #expect(months.count >= 3)
    for (left, right) in zip(months, months.dropFirst()) {
      #expect(!left.frame.intersects(right.frame))
      #expect(left.frame.minX < right.frame.minX)
    }
    #expect(months.allSatisfy { $0.frame.maxX <= view.frame.width })
    // 画得出月份就得给那行留高度。
    #expect(view.cellFrame(column: 0, row: 0).minY == TokenHeatmapView.monthScaleHeight)
  }

  @Test("极窄时整条月份行不画，高度一起收掉")
  func monthScaleCollapsesWhenTooNarrow() throws {
    let view = TokenHeatmapView()
    let today = LocalDayStamper.today()
    view.apply(cells: TokenActivityHeatmap.cells(dailyTotals: [today: 10], today: today))

    view.frame = NSRect(x: 0, y: 0, width: 56, height: 120)
    #expect(view.monthLabels().isEmpty)
    // 网格顶到 0，不留一条空白；行标签也跟着一起上移。
    #expect(view.cellFrame(column: 0, row: 0).minY == 0)
    let first = try #require(view.weekdayLabels().first)
    #expect(abs(first.frame.midY - view.cellFrame(column: 0, row: 0).midY) < 1.5)
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
    view.showsWeekdayScale = false
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
