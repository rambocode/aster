// Token 页的卡片容器与总量卡：圆角淡底、细分隔线、标签在上数值在下的四等分列。
import AppKit
import AsterCore
import Foundation

/// Token 页的内容卡：外观走三页共用的 `UsageCardStyle`，内部是一列撑满宽度的行。
///
/// 行宽统一由 `insertRow` 约束成卡片内容宽度——`NSStackView` 的 `.leading` 对齐只保证
/// 左边对齐，不会把行拉开，靠右的数字列会全部挤到名称后面。
@MainActor
final class UsageTokenCardView: NSView {
  /// 卡片内边距。四边同值，取自共用样式。
  static let insets = NSEdgeInsets(
    top: UsageCardStyle.contentInset, left: UsageCardStyle.contentInset,
    bottom: UsageCardStyle.contentInset, right: UsageCardStyle.contentInset)

  /// 卡内行容器。展开块靠 `insertRow(_:at:)` 原地插进来，不重建整张卡。
  let rows = NSStackView()

  init(insets: NSEdgeInsets = UsageTokenCardView.insets, spacing: CGFloat = 7) {
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("usage-token-card")
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = spacing
    addSubview(rows)
    rows.pinEdges(to: self, insets: insets)
    UsageCardStyle.apply(to: self)
  }

  required init?(coder: NSCoder) { nil }

  /// 追加一行。
  func addRow(_ view: NSView) { insertRow(view, at: rows.arrangedSubviews.count) }

  /// 在指定位置插入一行并撑满卡片内容宽度。
  func insertRow(_ view: NSView, at index: Int) {
    rows.insertArrangedSubview(view, at: index)
    view.translatesAutoresizingMaskIntoConstraints = false
    view.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
  }

  /// 移除一行。必须同时从父视图摘掉，否则 `removeArrangedSubview` 留下的视图会继续挡住点击。
  func removeRow(_ view: NSView) {
    rows.removeArrangedSubview(view)
    view.removeFromSuperview()
  }

  /// 动态色转 `cgColor` 停在解析那一刻的值，亮暗切换后必须重来一次。
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    UsageCardStyle.apply(to: self)
  }
}

/// 卡片内的 1pt 分隔线。磨砂背景下用全强度 `hairline`，半强度的线会断续。
@MainActor
final class UsageTokenSeparator: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    identifier = NSUserInterfaceItemIdentifier("usage-token-separator")
    wantsLayer = true
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: 1).isActive = true
    applyColors()
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  private func applyColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = AsterTheme.hairline.cgColor
    }
  }
}

/// 总量卡里的一列：小字标签在上，数值在下。
///
/// 顺序和 Tally 一致（标签在上）。`NSStackView` 默认坐标系原点在左下，所以第一个
/// arranged subview 画在上方、`frame.minY` 反而更大——测试断言这层关系时要留意。
@MainActor
final class UsageTokenTotalsColumn: NSStackView {
  let titleLabel: NSTextField
  let valueLabel: NSTextField

  init(key: String, title: String, value: Int64) {
    titleLabel = makeLabel(title, size: 10, color: AsterTheme.secondaryInk)
    valueLabel = makeLabel(
      TokenNumberText.compact(value), size: 15, weight: .semibold, monospaced: true)
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("usage-token-total-\(key)")
    titleLabel.identifier = NSUserInterfaceItemIdentifier("usage-token-total-\(key)-label")
    valueLabel.identifier = NSUserInterfaceItemIdentifier("usage-token-total-\(key)-value")
    orientation = .vertical
    alignment = .leading
    spacing = 2
    // 四列是 `fillEqually`，440pt 宽的面板下每列只剩九十来点。两个标签都必须肯让步，
    // 否则窄面板里等分宽度容不下文字，等分约束会被判成冲突。
    for label in [titleLabel, valueLabel] {
      label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      label.setContentHuggingPriority(.defaultLow, for: .horizontal)
    }
    addArrangedSubview(titleLabel)
    addArrangedSubview(valueLabel)
  }

  required init?(coder: NSCoder) { nil }
}

/// 总量卡：小字「总量」+ 超大总数 + 细分隔线 + 四等分列。
@MainActor
func makeUsageTokenTotalsCard(_ totals: TokenTotals) -> UsageTokenCardView {
  let card = UsageTokenCardView(spacing: 2)
  card.identifier = NSUserInterfaceItemIdentifier("usage-token-totals")
  card.toolTip = TokenNumberText.breakdown(totals)

  let caption = makeLabel(L("总量"), size: 11, color: AsterTheme.secondaryInk)
  let headline = makeLabel(
    TokenNumberText.compact(totals.total), size: 34, weight: .semibold, monospaced: true)
  headline.identifier = NSUserInterfaceItemIdentifier("usage-token-totals-headline")
  let separator = UsageTokenSeparator()

  let columns = NSStackView(views: [
    UsageTokenTotalsColumn(key: "input", title: L("输入"), value: totals.input),
    UsageTokenTotalsColumn(key: "cache-write", title: L("缓存写入"), value: totals.cacheWrite),
    UsageTokenTotalsColumn(key: "cache-read", title: L("缓存读取"), value: totals.cacheRead),
    UsageTokenTotalsColumn(key: "output", title: L("输出"), value: totals.output),
  ])
  columns.identifier = NSUserInterfaceItemIdentifier("usage-token-total-columns")
  columns.orientation = .horizontal
  columns.alignment = .top
  columns.distribution = .fillEqually
  columns.spacing = 8

  card.addRow(caption)
  card.addRow(headline)
  card.addRow(separator)
  card.addRow(columns)
  card.rows.setCustomSpacing(10, after: headline)
  card.rows.setCustomSpacing(10, after: separator)
  return card
}
