// Token 页的一年活动热力图：53 列 × 7 行自绘小方格，悬停出当日用量 tooltip。
import AppKit
import AsterCore
import Foundation

/// 一年活动热力图。
///
/// 全部格子画在同一个视图里：一年有三百多格，每格一个子视图会让布局和事件分发都付出
/// 不成比例的代价，而它们的几何是规则网格，自绘加一次命中计算就够了。
@MainActor
final class TokenHeatmapView: NSView {
  /// 宽度充裕时的方格边长与间距。
  static let idealCellSize: CGFloat = 9
  static let idealSpacing: CGFloat = 2
  /// 顶部月份刻度占的高度。
  static let monthScaleHeight: CGFloat = 13

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

  /// 顶部是否画月份刻度。展开在项目行下方的小图不画，避免把行撑高。
  var showsMonthScale: Bool = true {
    didSet { if showsMonthScale != oldValue { requestRedraw() } }
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

  /// 高度由当前宽度算出来：方格会随宽度等比缩小，行高跟着变。
  override var intrinsicContentSize: NSSize {
    let metrics = self.metrics(for: bounds.width)
    let rows = CGFloat(TokenActivityHeatmap.weekdays)
    let grid = rows * (metrics.cell + metrics.spacing) - metrics.spacing
    return NSSize(
      width: NSView.noIntrinsicMetric, height: grid + (showsMonthScale ? Self.monthScaleHeight : 0))
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
    // 动态主题色必须在当前外观下解析，否则深浅模式会共用同一份 RGBA。
    effectiveAppearance.performAsCurrentDrawingAppearance {
      if showsMonthScale { drawMonthScale(metrics: metrics) }
      for cell in cells {
        let rect = frame(forColumn: cell.column, row: cell.row, metrics: metrics)
        color(forLevel: cell.level).setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
      }
    }
  }

  /// 月份名画在该月第一个出现的列上；同一个月不重复标。
  private func drawMonthScale(metrics: (cell: CGFloat, spacing: CGFloat)) {
    let attributes: [NSAttributedString.Key: Any] = [
      .font: NSFont.systemFont(ofSize: 9),
      .foregroundColor: AsterTheme.tertiaryInk,
    ]
    var lastMonth = -1
    for column in 0..<TokenActivityHeatmap.weekColumns {
      guard let cell = index[Self.slot(column: column, row: 0)] else { continue }
      let date = TokenActivityHeatmap.date(forDay: cell.day)
      let month = Calendar(identifier: .gregorian).dateComponents(
        in: TimeZone(secondsFromGMT: 0) ?? .gmt, from: date
      ).month ?? -1
      guard month != lastMonth else { continue }
      lastMonth = month
      let x = CGFloat(column) * (metrics.cell + metrics.spacing)
      Self.monthFormatter.string(from: date).draw(
        at: NSPoint(x: x, y: 0), withAttributes: attributes)
    }
  }

  /// 0 级画成几乎看不见的底色，1–4 级按分级不透明度叠主题强调色。
  private func color(forLevel level: Int) -> NSColor {
    guard level > 0 else { return AsterTheme.ink.withAlphaComponent(0.06) }
    let opacity = TokenActivityHeatmap.levelOpacity[
      min(level, TokenActivityHeatmap.levelOpacity.count) - 1]
    return AsterTheme.accent.withAlphaComponent(opacity)
  }

  // MARK: - 几何

  /// 当前宽度下的方格与间距。
  ///
  /// 宽度不够时整体等比缩小，而不是把右边的周截掉：热力图的意义就在于「一整年」，
  /// 少画几周会让最近的活动跑出画面。
  private func metrics(for width: CGFloat) -> (cell: CGFloat, spacing: CGFloat) {
    let columns = CGFloat(TokenActivityHeatmap.weekColumns)
    let needed = columns * (Self.idealCellSize + Self.idealSpacing) - Self.idealSpacing
    guard width > 0, width < needed else { return (Self.idealCellSize, Self.idealSpacing) }
    let scale = width / needed
    return (Self.idealCellSize * scale, Self.idealSpacing * scale)
  }

  private func frame(forColumn column: Int, row: Int, metrics: (cell: CGFloat, spacing: CGFloat))
    -> NSRect
  {
    let step = metrics.cell + metrics.spacing
    return NSRect(
      x: CGFloat(column) * step,
      y: (showsMonthScale ? Self.monthScaleHeight : 0) + CGFloat(row) * step,
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
    let top = showsMonthScale ? Self.monthScaleHeight : 0
    let column = Int(floor(point.x / step))
    let row = Int(floor((point.y - top) / step))
    guard row >= 0, row < TokenActivityHeatmap.weekdays,
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
