// Token 页的数字格式与行视图：紧凑计数、占比文本、按 Agent 行、按项目行、区间 chip。
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

  /// 占比文本：`100%` / `42%` / `3.2%` / `<0.1%`。
  ///
  /// 纯数字格式，不进翻译表。10% 以上用整数是因为行里只放得下三四个字符，而小项目
  /// 全写成 `0%` 会让十几行看起来一模一样，所以 10% 以下保留一位小数。
  static func percent(_ share: Double) -> String {
    let value = min(max(share, 0), 1) * 100
    if value >= 99.95 { return "100%" }
    if value >= 10 { return String(format: "%.0f%%", value) }
    if value >= 0.1 { return String(format: "%.1f%%", value) }
    return value > 0 ? "<0.1%" : "0%"
  }

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

/// 卡片内的小节标题（「按 Agent」「按项目」）。
@MainActor
func makeUsageTokenSectionTitle(_ text: String) -> NSTextField {
  makeLabel(text, size: 11, weight: .semibold, color: AsterTheme.secondaryInk)
}

/// 行右端靠右对齐的数字列。占比列与数值列共用一套排版，两张卡的右边缘才对得齐。
@MainActor
private func makeTrailingNumber(
  _ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, minimumWidth: CGFloat
) -> NSTextField {
  let label = makeLabel(text, size: size, weight: weight, color: color, monospaced: true)
  label.alignment = .right
  label.setContentHuggingPriority(.required, for: .horizontal)
  label.setContentCompressionResistancePriority(.required, for: .horizontal)
  label.widthAnchor.constraint(greaterThanOrEqualToConstant: minimumWidth).isActive = true
  return label
}

/// 按 Agent 的一行：图标 + 名称（左），占比与数值靠右。
///
/// 这里**不画进度条**：provider 只有几行且名称自带辨识度，条形反而把右边的数字挤窄；
/// 需要排序感的是项目那张卡。
@MainActor
final class UsageTokenAgentRow: NSView {
  let percentLabel: NSTextField
  let valueLabel: NSTextField

  init(provider: AgentProvider, value: Int64, share: Double, tooltip: String?) {
    percentLabel = makeTrailingNumber(
      TokenNumberText.percent(share), size: 10, weight: .regular,
      color: AsterTheme.secondaryInk, minimumWidth: 40)
    valueLabel = makeTrailingNumber(
      TokenNumberText.compact(value), size: 11, weight: .semibold, color: AsterTheme.ink,
      minimumWidth: 54)
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("usage-token-agent-\(provider.rawValue)")
    translatesAutoresizingMaskIntoConstraints = false
    toolTip = tooltip

    let icon = NSImageView()
    icon.image = TabIconArtwork.image(named: TabRowButton.agentIconName(provider))
    icon.imageScaling = .scaleProportionallyUpOrDown
    icon.contentTintColor = AsterTheme.secondaryInk
    icon.translatesAutoresizingMaskIntoConstraints = false

    let name = makeLabel(provider.displayName, size: 11, color: AsterTheme.ink)
    name.setContentHuggingPriority(.defaultLow, for: .horizontal)
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let stack = NSStackView(views: [icon, name, percentLabel, valueLabel])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 6
    stack.distribution = .fill
    addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      icon.widthAnchor.constraint(equalToConstant: 15),
      icon.heightAnchor.constraint(equalToConstant: 15),
      heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

/// 按项目的一行：名称 + 占比条 + 占比 + 数值 + 展开箭头。整行可点击。
///
/// 条形填充用 `CALayer` 直接设 frame，不用 Auto Layout 的 multiplier：后者不可变，
/// 改比例得整条重建约束。
@MainActor
final class UsageTokenProjectRow: NSView {
  private static let trackHeight: CGFloat = 5

  let nameLabel: NSTextField
  let percentLabel: NSTextField
  let valueLabel: NSTextField
  /// 占比条。名称先截断、条先让宽，数值与占比不让——窄面板里数字是这一行的正事。
  let track = NSView()

  private let fill = CALayer()
  private let chevron = NSImageView()
  private let fraction: Double
  private let onClick: () -> Void
  private(set) var isExpanded = false

  init(
    key: String, name: String, value: Int64, share: Double, tooltip: String?,
    onClick: @escaping () -> Void
  ) {
    fraction = min(max(share, 0), 1)
    self.onClick = onClick
    nameLabel = makeLabel(name, size: 11, color: AsterTheme.secondaryInk)
    percentLabel = makeTrailingNumber(
      TokenNumberText.percent(share), size: 10, weight: .regular,
      color: AsterTheme.secondaryInk, minimumWidth: 40)
    valueLabel = makeTrailingNumber(
      TokenNumberText.compact(value), size: 11, weight: .semibold, color: AsterTheme.ink,
      minimumWidth: 54)
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("usage-token-project-\(key)")
    translatesAutoresizingMaskIntoConstraints = false
    toolTip = tooltip

    nameLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
    nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    track.identifier = NSUserInterfaceItemIdentifier("usage-token-share-track")
    track.wantsLayer = true
    track.layer?.cornerRadius = Self.trackHeight / 2
    track.layer?.masksToBounds = true
    track.layer?.addSublayer(fill)
    fill.cornerRadius = Self.trackHeight / 2
    track.translatesAutoresizingMaskIntoConstraints = false

    chevron.identifier = NSUserInterfaceItemIdentifier("usage-token-project-chevron")
    chevron.imageScaling = .scaleProportionallyUpOrDown
    chevron.contentTintColor = AsterTheme.tertiaryInk
    chevron.translatesAutoresizingMaskIntoConstraints = false

    let stack = NSStackView(views: [nameLabel, track, percentLabel, valueLabel, chevron])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 6
    stack.distribution = .fill
    addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    // 条宽只是「希望占行宽的四分之一」，不是硬约束：440pt 面板再窄下去时它得先让路，
    // 右边的占比和数值是必读信息，不能被挤没。
    let trackWidth = track.widthAnchor.constraint(equalTo: widthAnchor, multiplier: 0.26)
    trackWidth.priority = .defaultHigh
    NSLayoutConstraint.activate([
      track.heightAnchor.constraint(equalToConstant: Self.trackHeight),
      trackWidth,
      track.widthAnchor.constraint(greaterThanOrEqualToConstant: 24),
      nameLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 40),
      chevron.widthAnchor.constraint(equalToConstant: 10),
      chevron.heightAnchor.constraint(equalToConstant: 10),
      heightAnchor.constraint(greaterThanOrEqualToConstant: 20),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    applyExpansionStyle()
    applyColors()
  }

  required init?(coder: NSCoder) { nil }

  /// 切换展开态。只改样式，展开块由控制器插在本行下方。
  func setExpanded(_ expanded: Bool) {
    guard expanded != isExpanded else { return }
    isExpanded = expanded
    applyExpansionStyle()
    applyColors()
  }

  override func layout() {
    super.layout()
    let bounds = track.bounds
    fill.frame = CGRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  override func mouseDown(with event: NSEvent) { onClick() }

  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

  /// 展开态的行把名称加重并把箭头转向下，让「这一行现在被打开着」在视觉上立得住。
  private func applyExpansionStyle() {
    nameLabel.font = NSFont.systemFont(ofSize: 11, weight: isExpanded ? .semibold : .regular)
    nameLabel.textColor = isExpanded ? AsterTheme.ink : AsterTheme.secondaryInk
    let symbol = isExpanded ? "chevron.down" : "chevron.right"
    chevron.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
  }

  private func applyColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      // 轨道压到 12% 的 ink：磨砂面板下更淡的底会和卡片融掉，条和轨道就分不开了。
      track.layer?.backgroundColor = AsterTheme.ink.withAlphaComponent(0.12).cgColor
      fill.backgroundColor =
        isExpanded
        ? AsterTheme.accent.cgColor : AsterTheme.accent.withAlphaComponent(0.7).cgColor
    }
  }
}
