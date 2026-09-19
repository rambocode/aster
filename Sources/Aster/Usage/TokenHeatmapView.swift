// Token 页的一年活动热力图：53 列 × 7 行自绘小方格，带月份刻度与周几行标签。
import AppKit
import AsterCore
import Foundation

/// 一年活动热力图。
///
/// 全部格子画在同一个视图里：一年有三百多格，每格一个子视图会让布局和事件分发都付出
/// 不成比例的代价，而它们的几何是规则网格，自绘加一次命中计算就够了。
@MainActor
final class TokenHeatmapView: NSView {
  /// 左侧行标签的文字与绘制矩形。自绘视图没有子视图可断言，测试从这里核对与格子的对齐。
  struct WeekdayLabel: Equatable {
    var row: Int
    var text: String
    var frame: NSRect
  }

  /// 顶部月份刻度的一格。同上，测试从这里核对退化后的数量与互不重叠。
  struct MonthLabel: Equatable {
    var column: Int
    var text: String
    var frame: NSRect
  }

  /// 宽度充裕时的方格边长与间距。
  static let idealCellSize: CGFloat = 9
  static let idealSpacing: CGFloat = 2
  /// 顶部月份刻度占的高度。
  static let monthScaleHeight: CGFloat = 13
  /// 左侧行标签占的宽度，含标签与网格之间的间隔。固定宽度：格子会随窗宽缩放，
  /// 标签字号不跟着缩，跟着缩就没法读了。
  static let weekdayScaleWidth: CGFloat = 24
  /// 画标签的行（`weekdayIndex` 里周一 = 0）。只标三行，七行会把左边糊成一片。
  private static let labeledRows = [0, 2, 4]
  /// 两个月份名之间留的空隙：宽松档读着舒服，紧凑档只保证不叠字。
  private static let monthLabelGap: CGFloat = 6
  private static let monthLabelTightGap: CGFloat = 2
  /// 宽松档取到这么多就收工；不够就换紧凑档再试。
  private static let monthLabelComfortableCount = 4
  /// 锚点月份的下限。连这几个都摆不下，整条月份行不画，高度也一起收掉。
  private static let monthLabelMinimumCount = 3

  /// 日期 tooltip 用 UTC 格式化：格子上的日整数**已经是**本地日历日，
  /// 再按本地时区读一遍，格林尼治以西的地方都会显示成前一天。
  private static let dayFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy-MM-dd"
    return formatter
  }()

  private static let monthFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.setLocalizedDateFormatFromTemplate("MMM")
    return formatter
  }()

  /// 顶部是否画月份刻度。关掉后网格贴着顶边。
  ///
  /// 打开也不一定画得出来：窄到连 `monthLabelMinimumCount` 个锚点月份都摆不下时，
  /// `monthLabels()` 返回空，那条行的高度会跟着收掉，不留一条空白。
  var showsMonthScale: Bool = true {
    didSet {
      guard showsMonthScale != oldValue else { return }
      invalidateIntrinsicContentSize()
      requestRedraw()
    }
  }

  /// 左侧是否画周一 / 周三 / 周五行标签。关掉后网格贴着左边缘。
  var showsWeekdayScale: Bool = true {
    didSet {
      guard showsWeekdayScale != oldValue else { return }
      invalidateIntrinsicContentSize()
      requestRedraw()
    }
  }

  /// 网格左侧留给行标签的宽度。
  var gridInset: CGFloat { showsWeekdayScale ? Self.weekdayScaleWidth : 0 }

  /// 刻度文字的排版属性。月份刻度与行标签共用，两处字号才不会走样。
  ///
  /// 用 `secondaryInk` 而不是更淡的 `tertiaryInk`：面板底是磨砂玻璃，透出来的桌面会把
  /// 9pt 的小字冲得几乎看不见。
  private static var scaleAttributes: [NSAttributedString.Key: Any] {
    [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: AsterTheme.secondaryInk]
  }

  /// 行标签文案。`L()` 只接受字面量，行号到文案的映射只能写在这里。
  private static func weekdayTitle(_ row: Int) -> String {
    switch row {
    case 0: L("周一")
    case 2: L("周三")
    default: L("周五")
    }
  }

  private(set) var cells: [TokenActivityHeatmap.Cell] = []
  /// 列行 → 格子，供悬停命中用；线性查找每次都要扫三百多项，而鼠标移动回调很密。
  private var index: [Int: TokenActivityHeatmap.Cell] = [:]
  /// 请求重绘的次数。测试用来确认相同数据不会再画一遍。
  private(set) var redrawRequestCount = 0
  private var trackingAreaForHover: NSTrackingArea?
  private var lastLaidOutWidth: CGFloat = 0

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    identifier = NSUserInterfaceItemIdentifier("usage-token-heatmap")
    translatesAutoresizingMaskIntoConstraints = false
  }

  required init?(coder: NSCoder) { nil }

  /// 网格从上往下数第 0 行是周一，用翻转坐标系省掉每次绘制的一次 y 轴换算。
  override var isFlipped: Bool { true }

  /// 换一批格子。数据没变就不重绘：切区间只影响上面的汇总，热力图窗口始终是过去一年。
  func apply(cells: [TokenActivityHeatmap.Cell]) {
    guard cells != self.cells else { return }
    self.cells = cells
    index = cells.reduce(into: [:]) { $0[Self.slot(column: $1.column, row: $1.row)] = $1 }
    invalidateIntrinsicContentSize()
    requestRedraw()
  }

  /// 高度由当前宽度算出来：方格会随宽度等比缩小，行高跟着变；月份行画不出来时也不占高度。
  override var intrinsicContentSize: NSSize {
    let metrics = self.metrics(for: bounds.width)
    let rows = CGFloat(TokenActivityHeatmap.weekdays)
    let grid = rows * (metrics.cell + metrics.spacing) - metrics.spacing
    return NSSize(width: NSView.noIntrinsicMetric, height: grid + topInset(metrics: metrics))
  }

  override func layout() {
    super.layout()
    // 宽度变了方格尺寸就变，高度约束必须跟着重算，否则窄窗里网格会被自身高度裁掉一行。
    guard bounds.width != lastLaidOutWidth else { return }
    lastLaidOutWidth = bounds.width
    invalidateIntrinsicContentSize()
    needsDisplay = true
    updateHoverTracking()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    requestRedraw()
  }

  // MARK: - 绘制

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    guard !cells.isEmpty else { return }
    let metrics = self.metrics(for: bounds.width)
    let radius = max(metrics.cell * 0.25, 0.5)
    // 月份行的高度要先定下来：它决定网格从哪里开始画，而它自己取决于摆不摆得下标签。
    let months = monthLabels(metrics: metrics)
    let top = months.isEmpty ? 0 : Self.monthScaleHeight
    let attributes = Self.scaleAttributes
    // 动态主题色必须在当前外观下解析，否则深浅模式会共用同一份 RGBA。
    effectiveAppearance.performAsCurrentDrawingAppearance {
      for label in months {
        (label.text as NSString).draw(at: label.frame.origin, withAttributes: attributes)
      }
      for label in weekdayLabels(metrics: metrics, topInset: top) {
        (label.text as NSString).draw(at: label.frame.origin, withAttributes: attributes)
      }
      for cell in cells {
        let rect = frame(forColumn: cell.column, row: cell.row, metrics: metrics, topInset: top)
        color(forLevel: cell.level).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      }
    }
  }

  // MARK: - 月份刻度

  /// 当前几何下的顶部月份标签。
  func monthLabels() -> [MonthLabel] {
    monthLabels(metrics: metrics(for: bounds.width))
  }

  /// 月份名画在该月第一个出现的列上，同一个月不重复标。
  ///
  /// 面板窄下来以后格子跟着缩小，相邻两个月只隔二十来点，而月份名字号是固定的——不做
  /// 间距检查就会叠成一团糊字。先按宽松间距贪心摆（从左往右取最早放得下的那个，对
  /// 「最多能摆几个互不重叠的标签」而言这已经是最优解）；摆不满就换紧凑间距再来一遍，
  /// 宁可挤一点也要留下几个锚点月份，让人看得出时间走向。连锚点下限都摆不下才整行不画。
  private func monthLabels(metrics: (cell: CGFloat, spacing: CGFloat)) -> [MonthLabel] {
    guard showsMonthScale, !cells.isEmpty else { return [] }
    let candidates = monthCandidates(metrics: metrics)
    let comfortable = packed(candidates, gap: Self.monthLabelGap)
    if comfortable.count >= Self.monthLabelComfortableCount { return comfortable }
    let tight = packed(candidates, gap: Self.monthLabelTightGap)
    return tight.count >= Self.monthLabelMinimumCount ? tight : []
  }

  /// 每个月第一次出现的列，连同它的标签文字与宽度。
  private func monthCandidates(metrics: (cell: CGFloat, spacing: CGFloat)) -> [MonthLabel] {
    let attributes = Self.scaleAttributes
    let calendar = Calendar(identifier: .gregorian)
    let utc = TimeZone(secondsFromGMT: 0) ?? .gmt
    var found: [MonthLabel] = []
    var lastMonth = -1
    for column in 0..<TokenActivityHeatmap.weekColumns {
      guard let cell = index[Self.slot(column: column, row: 0)] else { continue }
      let date = TokenActivityHeatmap.date(forDay: cell.day)
      let month = calendar.dateComponents(in: utc, from: date).month ?? -1
      guard month != lastMonth else { continue }
      lastMonth = month
      let text = Self.monthFormatter.string(from: date)
      let size = (text as NSString).size(withAttributes: attributes)
      let x = gridInset + CGFloat(column) * (metrics.cell + metrics.spacing)
      found.append(
        MonthLabel(column: column, text: text, frame: NSRect(origin: NSPoint(x: x, y: 0), size: size)))
    }
    return found
  }

  /// 从左往右贪心挑出互不重叠的标签。越过右边缘的整个丢掉，不留半个字贴着边。
  private func packed(_ candidates: [MonthLabel], gap: CGFloat) -> [MonthLabel] {
    var kept: [MonthLabel] = []
    var lastMaxX = -CGFloat.greatestFiniteMagnitude
    for label in candidates {
      guard label.frame.minX >= lastMaxX + gap, label.frame.maxX <= bounds.width else { continue }
      kept.append(label)
      lastMaxX = label.frame.maxX
    }
    return kept
  }

  // MARK: - 行标签

  /// 当前几何下的行标签。
  func weekdayLabels() -> [WeekdayLabel] {
    let metrics = self.metrics(for: bounds.width)
    return weekdayLabels(metrics: metrics, topInset: topInset(metrics: metrics))
  }

  private func weekdayLabels(metrics: (cell: CGFloat, spacing: CGFloat), topInset: CGFloat)
    -> [WeekdayLabel]
  {
    guard showsWeekdayScale else { return [] }
    let attributes = Self.scaleAttributes
    return Self.labeledRows.map { row in
      let text = Self.weekdayTitle(row)
      let size = (text as NSString).size(withAttributes: attributes)
      // 标签按所在行格子的中线居中：格子随窗宽缩小，标签字号不变，靠中线对齐才不会飘。
      let cell = frame(forColumn: 0, row: row, metrics: metrics, topInset: topInset)
      let origin = NSPoint(x: 0, y: cell.midY - size.height / 2)
      return WeekdayLabel(row: row, text: text, frame: NSRect(origin: origin, size: size))
    }
  }

  /// 0 级画成很淡的底色，1–4 级按分级不透明度叠主题强调色。
  ///
  /// 0 级的 12% 是磨砂背景定下来的：空格子撑着整张图的网格形状，再淡下去就会被透出来的
  /// 桌面吃掉，只剩零散几个亮点飘着。
  private func color(forLevel level: Int) -> NSColor {
    guard level > 0 else { return AsterTheme.ink.withAlphaComponent(0.12) }
    let opacity = TokenActivityHeatmap.levelOpacity[
      min(level, TokenActivityHeatmap.levelOpacity.count) - 1]
    return AsterTheme.accent.withAlphaComponent(opacity)
  }

  // MARK: - 几何

  /// 当前宽度下的方格与间距。
  ///
  /// 宽度不够时格子和间距一起等比缩小，而不是把右边的周截掉：热力图的意义就在于
  /// 「一整年」，少画几周会让最近的活动跑出画面。左侧行标签的固定宽度先扣掉。
  private func metrics(for width: CGFloat) -> (cell: CGFloat, spacing: CGFloat) {
    let columns = CGFloat(TokenActivityHeatmap.weekColumns)
    let needed = columns * (Self.idealCellSize + Self.idealSpacing) - Self.idealSpacing
    let available = width - gridInset
    guard available > 0, available < needed else { return (Self.idealCellSize, Self.idealSpacing) }
    let scale = available / needed
    return (Self.idealCellSize * scale, Self.idealSpacing * scale)
  }

  /// 网格上方留给月份行的高度。一个锚点月份都摆不下时为 0，不留空白条。
  ///
  /// `monthLabels` 要量每个月份名的文字宽度，不能放进逐格调用的 `frame(forColumn:…)` 里，
  /// 所以调用方一律先算一次再往下传。
  func topInset(metrics: (cell: CGFloat, spacing: CGFloat)) -> CGFloat {
    monthLabels(metrics: metrics).isEmpty ? 0 : Self.monthScaleHeight
  }

  /// 某个格子在视图坐标系里的矩形。测试用它核对刻度与格子的对齐。
  func cellFrame(column: Int, row: Int) -> NSRect {
    let metrics = self.metrics(for: bounds.width)
    return frame(
      forColumn: column, row: row, metrics: metrics, topInset: topInset(metrics: metrics))
  }

  private func frame(
    forColumn column: Int, row: Int, metrics: (cell: CGFloat, spacing: CGFloat), topInset: CGFloat
  ) -> NSRect {
    let step = metrics.cell + metrics.spacing
    return NSRect(
      x: gridInset + CGFloat(column) * step,
      y: topInset + CGFloat(row) * step,
      width: metrics.cell, height: metrics.cell)
  }

  private static func slot(column: Int, row: Int) -> Int {
    column * TokenActivityHeatmap.weekdays + row
  }

  // MARK: - 悬停

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    updateHoverTracking()
  }

  /// 整块视图只装一个 tracking area，落到哪一格靠命中计算得出。
  private func updateHoverTracking() {
    if let trackingAreaForHover { removeTrackingArea(trackingAreaForHover) }
    let area = NSTrackingArea(
      rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
      owner: self, userInfo: nil)
    addTrackingArea(area)
    trackingAreaForHover = area
  }

  override func mouseMoved(with event: NSEvent) {
    super.mouseMoved(with: event)
    let text = tooltipText(at: convert(event.locationInWindow, from: nil))
    guard text != toolTip else { return }
    toolTip = text
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    toolTip = nil
  }

  /// 视图坐标对应格子的说明文字；落在空隙或窗口外时为 nil。
  func tooltipText(at point: NSPoint) -> String? {
    let metrics = self.metrics(for: bounds.width)
    let step = metrics.cell + metrics.spacing
    guard step > 0 else { return nil }
    let top = topInset(metrics: metrics)
    let column = Int(floor((point.x - gridInset) / step))
    let row = Int(floor((point.y - top) / step))
    guard column >= 0, row >= 0, row < TokenActivityHeatmap.weekdays,
      let cell = index[Self.slot(column: column, row: row)]
    else { return nil }
    let day = Self.dayFormatter.string(from: TokenActivityHeatmap.date(forDay: cell.day))
    return L("\(day) · \(TokenNumberText.compact(cell.total)) token")
  }

  private func requestRedraw() {
    redrawRequestCount += 1
    needsDisplay = true
  }
}
