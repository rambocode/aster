// Token 页的数字格式与行视图：紧凑计数、总量卡、占比行、区间 chip。
import AppKit
import AsterCore
import Foundation

/// token 计数的文本形式。
///
/// 标为 `@MainActor` 只因为里面缓存了一个 `NumberFormatter`（非 Sendable），
/// 这些函数本身是纯的，全部在渲染路径上调用。
@MainActor
enum TokenNumberText {
  private static let units = ["K", "M", "B", "T"]

  private static let groupedFormatter: NumberFormatter = {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    return formatter
  }()

  /// 紧凑计数：`999` / `1.2K` / `34.7M` / `3.4B`。
  ///
  /// 进位按**舍入后**的值判断：999_999 保留一位小数是 1000.0K，那显然该写成 1M，
  /// 直接用原值比较会把它留在 K 档。整数结果去掉 `.0`（1000 → `1K`）。
  static func compact(_ value: Int64) -> String {
    var scaled = Double(value.magnitude)
    var unit = -1
    while unit + 1 < units.count, oneDecimal(scaled) >= 1000 {
      scaled /= 1000
      unit += 1
    }
    let text: String
    if unit < 0 {
      text = "\(Int64(scaled.rounded()))"
    } else {
      let rounded = oneDecimal(scaled)
      text =
        rounded == rounded.rounded()
        ? "\(Int64(rounded))\(units[unit])" : String(format: "%.1f%@", rounded, units[unit])
    }
    return value < 0 ? "-" + text : text
  }

  /// 保留一位小数。
  private static func oneDecimal(_ value: Double) -> Double { (value * 10).rounded() / 10 }

  /// 带千分位的完整数字，只用在 tooltip 里——那里有空间给出精确值。
  static func grouped(_ value: Int64) -> String {
    groupedFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
  }

  /// 四列明细的一行文字，总量卡和各种 tooltip 共用同一套措辞。
  static func breakdown(_ totals: TokenTotals) -> String {
    L(
      "输入 \(grouped(totals.input)) · 缓存写入 \(grouped(totals.cacheWrite)) · 缓存读取 \(grouped(totals.cacheRead)) · 输出 \(grouped(totals.output))"
    )
  }
}

/// 区间 chip 的标题。`L()` 只接受字面量，映射写在视图层。
@MainActor
func usageTokenRangeTitle(_ range: TokenStatsRange) -> String {
  switch range {
  case .today: L("今天")
  case .sevenDays: L("7 天")
  case .thirtyDays: L("30 天")
  case .all: L("全部")
  }
}

/// Token 页的卡片底：淡底圆角，颜色随明暗外观刷新。
@MainActor
final class UsageTokenCardView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    identifier = NSUserInterfaceItemIdentifier("usage-token-card")
    wantsLayer = true
    layer?.cornerRadius = 8
    applyColors()
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  private func applyColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = AsterTheme.ink.withAlphaComponent(0.05).cgColor
      layer?.borderColor = AsterTheme.hairline.withAlphaComponent(0.5).cgColor
      layer?.borderWidth = 1
    }
  }
}

/// 总量卡：一个大数字加输入 / 缓存写入 / 缓存读取 / 输出四列。
@MainActor
func makeUsageTokenTotalsCard(_ totals: TokenTotals) -> NSView {
  let card = UsageTokenCardView()
  card.identifier = NSUserInterfaceItemIdentifier("usage-token-totals")
  card.toolTip = TokenNumberText.breakdown(totals)

  let caption = makeLabel(L("总量"), size: 10, color: AsterTheme.tertiaryInk)
  let headline = makeLabel(
    TokenNumberText.compact(totals.total), size: 26, weight: .semibold, monospaced: true)

  let columns = NSStackView(views: [
    makeUsageTokenColumn(L("输入"), totals.input),
    makeUsageTokenColumn(L("缓存写入"), totals.cacheWrite),
    makeUsageTokenColumn(L("缓存读取"), totals.cacheRead),
    makeUsageTokenColumn(L("输出"), totals.output),
  ])
  columns.orientation = .horizontal
  columns.alignment = .top
  columns.distribution = .fillEqually
  columns.spacing = 6

  let rows = NSStackView(views: [caption, headline, columns])
  rows.orientation = .vertical
  rows.alignment = .leading
  rows.spacing = 2
  rows.setCustomSpacing(8, after: headline)
  card.addSubview(rows)
  rows.pinEdges(to: card, insets: NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12))
  return card
}

/// 总量卡里的一列：上面是列名，下面是紧凑数字。
@MainActor
private func makeUsageTokenColumn(_ title: String, _ value: Int64) -> NSView {
  let name = makeLabel(title, size: 10, color: AsterTheme.tertiaryInk)
  let number = makeLabel(
    TokenNumberText.compact(value), size: 11, weight: .medium, color: AsterTheme.secondaryInk,
    monospaced: true)
  let stack = NSStackView(views: [name, number])
  stack.orientation = .vertical
  stack.alignment = .leading
  stack.spacing = 1
  return stack
}

/// 小节标题（「按 Agent」「按项目」）。
@MainActor
func makeUsageTokenSectionTitle(_ text: String) -> NSTextField {
  makeLabel(text, size: 11, weight: .semibold, color: AsterTheme.secondaryInk)
}

/// 排行里的一行：名称 + 占比条 + 紧凑数字。可点击（项目行用来展开热力图）。
///
/// 填充用 `CALayer` 直接设 frame，不用 Auto Layout 的 multiplier：后者不可变，
/// 改比例得整条重建约束。
@MainActor
final class UsageTokenShareRow: NSView {
  private static let trackHeight: CGFloat = 5

  private let track = NSView()
  private let fill = CALayer()
  private let fraction: Double
  private let onClick: (() -> Void)?
  /// 展开态的行把名称加重，让「这一行现在被打开着」在视觉上立得住。
  private let isHighlighted: Bool

  init(
    name: String, value: Int64, share: Double, tooltip: String? = nil,
    highlighted: Bool = false, onClick: (() -> Void)? = nil
  ) {
    fraction = min(max(share, 0), 1)
    self.onClick = onClick
    isHighlighted = highlighted
    super.init(frame: .zero)
    translatesAutoresizingMaskIntoConstraints = false
    toolTip = tooltip

    let label = makeLabel(
      name, size: 11, weight: highlighted ? .semibold : .regular,
      color: highlighted ? AsterTheme.ink : AsterTheme.secondaryInk)
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let number = makeLabel(
      TokenNumberText.compact(value), size: 10, weight: .medium, color: AsterTheme.secondaryInk,
      monospaced: true)
    number.alignment = .right
    number.setContentHuggingPriority(.required, for: .horizontal)

    track.wantsLayer = true
    track.layer?.cornerRadius = Self.trackHeight / 2
    track.layer?.masksToBounds = true
    track.layer?.addSublayer(fill)
    fill.cornerRadius = Self.trackHeight / 2
    track.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [label, track, number])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 6
    stack.distribution = .fill
    addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      track.heightAnchor.constraint(equalToConstant: Self.trackHeight),
      track.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.34),
      label.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
      number.widthAnchor.constraint(greaterThanOrEqualToConstant: 46),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    applyColors()
  }

  required init?(coder: NSCoder) { nil }

  override func layout() {
    super.layout()
    let bounds = track.bounds
    fill.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  override func mouseDown(with event: NSEvent) {
    guard let onClick else {
      super.mouseDown(with: event)
      return
    }
    onClick()
  }

  override func resetCursorRects() {
    guard onClick != nil else { return }
    addCursorRect(bounds, cursor: .pointingHand)
  }

  private func applyColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      track.layer?.backgroundColor = AsterTheme.hairline.cgColor
      fill.backgroundColor =
        isHighlighted
        ? AsterTheme.accent.cgColor : AsterTheme.accent.withAlphaComponent(0.7).cgColor
    }
  }
}

/// Token 页顶部的区间 chip 行。视觉与浮动窗页签一致（选中项淡底圆角）。
@MainActor
final class UsageTokenRangeBar: NSStackView {
  private var buttons: [TokenStatsRange: NSButton] = [:]
  private let onSelect: (TokenStatsRange) -> Void
  private(set) var selection: TokenStatsRange

  init(selection: TokenStatsRange, onSelect: @escaping (TokenStatsRange) -> Void) {
    self.selection = selection
    self.onSelect = onSelect
    super.init(frame: .zero)
    orientation = .horizontal
    alignment = .centerY
    spacing = 4
    for range in TokenStatsRange.allCases {
      let button = ActionButton(title: usageTokenRangeTitle(range), bezelStyle: .inline) {
        [weak self] in
        self?.handleClick(range)
      }
      button.isBordered = false
      button.identifier = NSUserInterfaceItemIdentifier("usage-token-range-\(range.rawValue)")
      buttons[range] = button
      addArrangedSubview(button)
    }
    applyStyle()
  }

  required init?(coder: NSCoder) { nil }

  /// 外部改选中态（恢复持久化）时只更新样式，不再回调。
  func select(_ range: TokenStatsRange) {
    guard selection != range else { return }
    selection = range
    applyStyle()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyStyle()
  }

  private func handleClick(_ range: TokenStatsRange) {
    guard selection != range else { return }
    selection = range
    applyStyle()
    onSelect(range)
  }

  private func applyStyle() {
    for (range, button) in buttons {
      let selected = range == selection
      button.attributedTitle = NSAttributedString(
        string: usageTokenRangeTitle(range),
        attributes: [
          .font: NSFont.systemFont(ofSize: 11, weight: selected ? .semibold : .regular),
          .foregroundColor: selected ? AsterTheme.ink : AsterTheme.secondaryInk,
        ])
      button.wantsLayer = true
      button.layer?.cornerRadius = 5
      button.effectiveAppearance.performAsCurrentDrawingAppearance {
        button.layer?.backgroundColor =
          selected ? AsterTheme.ink.withAlphaComponent(0.08).cgColor : NSColor.clear.cgColor
      }
    }
  }
}
