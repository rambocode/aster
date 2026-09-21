// AI 用量浮动窗「配额」页的卡片视图：账号卡、订阅档位徽标、两行窗口条与时长文字。
import AppKit
import AsterCore
import Foundation

// MARK: - 账号卡片

/// 一个账号的配额卡片：卡头（provider 图标 + 账号名 + 档位徽标）、若干两行窗口条、卡底数据时刻。
///
/// 窗口结构由 `init` 固定；`plan` 与 `fetchedAt` 走 `apply(_:)` 原地更新，展示口径走
/// `apply(displayMode:)`，倒计时文字走 `refresh(now:)`——三者都不动视图结构。
@MainActor
final class UsageQuotaCardView: NSView {
  /// 数据比这更旧才值得标出来，与用量条 tooltip 的口径一致。
  private static let staleThreshold: TimeInterval = 120
  private static let iconSize: CGFloat = 16
  /// 卡片内边距走三页共用的真值（`UsageCardStyle`），配额卡不自己定一套。
  private static var contentInsets: NSEdgeInsets {
    let inset = UsageCardStyle.contentInset
    return NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset)
  }

  private let iconView = NSImageView()
  private let titleLabel: NSTextField
  private let planBadge: UsagePlanBadgeView
  private let windowRows: [UsageQuotaWindowRow]
  private let stampLabel = makeLabel("", size: 10, color: AsterTheme.tertiaryInk)
  private var fetchedAt: Date?

  /// 是否有随时间变化的内容。全是静态数据的卡片不需要页面排 tick。
  var needsTick: Bool { fetchedAt != nil || windowRows.contains(where: \.hasCountdown) }

  /// 按窗口种类取一行，测试与调试用。
  func row(kind: AgentUsageWindowKind) -> UsageQuotaWindowRow? {
    windowRows.first { $0.windowKind == kind }
  }

  init(account: UsageAccountSnapshot, displayMode: UsageDisplayMode) {
    titleLabel = makeLabel(account.label, size: 15, weight: .semibold)
    planBadge = UsagePlanBadgeView(accountID: account.id)
    windowRows = account.windows.map {
      UsageQuotaWindowRow(window: $0, accountID: account.id, displayMode: displayMode)
    }
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("usage-quota-card-\(account.id)")
    wantsLayer = true

    iconView.identifier = NSUserInterfaceItemIdentifier("usage-quota-icon-\(account.id)")
    iconView.image = TabIconArtwork.image(named: TabRowButton.agentIconName(account.provider))
    iconView.imageScaling = .scaleProportionallyUpOrDown
    // 取不到图标时整块收起，免得卡头左边留一个空洞。
    iconView.isHidden = iconView.image == nil
    iconView.translatesAutoresizingMaskIntoConstraints = false

    stampLabel.identifier = NSUserInterfaceItemIdentifier("usage-quota-stamp-\(account.id)")

    // 徽标紧跟账号名，右侧留一个会撑开的空视图，卡头才不会把徽标推到卡片中间。
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    let headerRow = NSStackView(views: [iconView, titleLabel, planBadge, spacer])
    headerRow.orientation = .horizontal
    headerRow.alignment = .centerY
    headerRow.spacing = 6

    let rows = NSStackView()
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 10
    rows.translatesAutoresizingMaskIntoConstraints = false
    rows.addArrangedSubview(headerRow)
    for row in windowRows { rows.addArrangedSubview(row) }
    rows.addArrangedSubview(stampLabel)
    addSubview(rows)
    rows.pinEdges(to: self, insets: Self.contentInsets)
    NSLayoutConstraint.activate([
      iconView.widthAnchor.constraint(equalToConstant: Self.iconSize),
      iconView.heightAnchor.constraint(equalToConstant: Self.iconSize),
      headerRow.widthAnchor.constraint(equalTo: rows.widthAnchor),
    ])
    for row in windowRows {
      row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }

    apply(account)
    applyColors()
  }

  required init?(coder: NSCoder) { nil }

  // MARK: - 原地更新

  /// 订阅档位与数据时刻的原地更新。
  func apply(_ account: UsageAccountSnapshot) {
    planBadge.apply(plan: account.plan)
    fetchedAt = account.fetchedAt
  }

  /// 展示口径切换：只改数字与条宽，不动结构。
  func apply(displayMode: UsageDisplayMode) {
    for row in windowRows { row.apply(displayMode: displayMode) }
  }

  /// 刷新所有随时间变化的文字。
  func refresh(now: Date) {
    for row in windowRows { row.refresh(now: now) }
    guard let fetchedAt else {
      stampLabel.isHidden = true
      stampLabel.stringValue = ""
      return
    }
    // 超过两分钟才提示：`/usage` 限流很紧，刚取回的数据标「0 分钟前」只是噪声。
    let age = now.timeIntervalSince(fetchedAt)
    stampLabel.isHidden = age <= Self.staleThreshold
    stampLabel.stringValue = L("\(UsageDurationText.make(age)) 前更新")
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  /// 卡片外观统一由 `UsageCardStyle` 给。动态色转 `cgColor` 绑当前外观，
  /// 所以亮暗切换后必须重调一次，否则颜色停在旧值。
  private func applyColors() {
    UsageCardStyle.apply(to: self)
  }
}

// MARK: - 档位徽标

/// 账号名右侧的订阅档位徽标（「Max 20x」「Pro」「Plus」……）。
///
/// 各家的档位叫法不统一，这里不做归一化映射，原样展示数据源给的字符串——
/// 把「5x」翻译成别的说法只会让用户对不上自己在官网看到的订阅名。
@MainActor
final class UsagePlanBadgeView: NSView {
  private static let horizontalInset: CGFloat = 6
  private let label = makeLabel("", size: 10, weight: .medium, color: AsterTheme.secondaryInk)

  /// 当前展示的档位文字；空串表示徽标隐藏。
  var text: String { label.stringValue }

  init(accountID: String) {
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("usage-quota-plan-\(accountID)")
    wantsLayer = true
    layer?.cornerRadius = 5
    addSubview(label)
    label.pinEdges(
      to: self,
      insets: NSEdgeInsets(
        top: 2, left: Self.horizontalInset, bottom: 2, right: Self.horizontalInset))
    setContentHuggingPriority(.required, for: .horizontal)
    apply(plan: nil)
    applyColors()
  }

  required init?(coder: NSCoder) { nil }

  /// 档位为 nil、空串或纯空白时整块隐藏；有值只改文字。
  func apply(plan: String?) {
    let value = plan?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    label.stringValue = value
    isHidden = value.isEmpty
    toolTip = value.isEmpty ? nil : value
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  private func applyColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor = AsterTheme.ink.withAlphaComponent(0.08).cgColor
    }
  }
}

// MARK: - 窗口行

/// 配额卡里的一个窗口，占两行：
/// 上行是「窗口名 + 可伸缩进度条 + 百分比」，下行是「接近上限（仅危险时）+ X 后重置」。
///
/// 轨道宽度随浮动窗伸缩，不用固定宽度：窄窗里固定宽度会留下大片空白。
/// 填充用 `CALayer` 直接设 frame，因为 Auto Layout 的 multiplier 不可变，改比例得重建约束。
@MainActor
final class UsageQuotaWindowRow: NSView {
  private static let trackHeight: CGFloat = 6

  private let usageWindow: AgentUsageWindow
  private let track = NSView()
  private let fill = CALayer()
  private let percentLabel: NSTextField
  private let alertLabel: NSTextField
  private let resetLabel: NSTextField
  private let bottomRow: NSStackView

  /// 告警级别。
  ///
  /// 刻意只认已用百分比，不随展示口径变：「剩余」口径下 4% 是快见底，按剩余值算会判成 normal，
  /// 那条快用光的配额就会显示成安全的绿色。
  let severity: UsageStatusSummary.Severity
  private(set) var displayMode: UsageDisplayMode

  /// 窗口种类，供卡片按种类取行。
  var windowKind: AgentUsageWindowKind { usageWindow.kind }
  /// 当前口径下的进度条填充比例，0…1。
  var fillFraction: Double { displayMode.fillFraction(usedPercent: usageWindow.usedPercent) }
  /// 当前展示的百分比文字。
  var percentText: String { percentLabel.stringValue }
  /// 「接近上限」是否可见。
  var isAlertVisible: Bool { !alertLabel.isHidden }
  /// 当前展示的重置倒计时文字；没有重置时间时为空串。
  var resetText: String { resetLabel.stringValue }
  /// 是否有重置倒计时。没有的话这一行的文字不随时间变化。
  var hasCountdown: Bool { usageWindow.resetsAt != nil }

  /// 悬停提示：窗口名与已用百分比 + 重置时刻（本地时间与相对时长）+ 服务端给的补充说明。
  static func tooltip(for window: AgentUsageWindow, now: Date = Date()) -> String {
    var parts = [L("\(window.displayLabel) 已用 \(String(Int(window.usedPercent.rounded())))%%")]
    if let resetsAt = window.resetsAt {
      let formatter = DateFormatter()
      formatter.dateStyle = .short
      formatter.timeStyle = .short
      parts.append(L("重置于 \(formatter.string(from: resetsAt))（\(RelativeTime.string(since: resetsAt, relativeTo: now))）"))
    }
    if let detail = window.detail { parts.append(detail) }
    return parts.joined(separator: "\n")
  }

  init(window: AgentUsageWindow, accountID: String, displayMode: UsageDisplayMode) {
    usageWindow = window
    self.displayMode = displayMode
    severity = UsageStatusSummary.severity(forUsedPercent: window.usedPercent)
    percentLabel = makeLabel("", size: 15, weight: .semibold)
    alertLabel = makeLabel(L("接近上限"), size: 10, weight: .medium, color: .systemRed)
    resetLabel = makeLabel("", size: 10, color: AsterTheme.tertiaryInk)
    bottomRow = NSStackView()
    super.init(frame: .zero)
    let suffix = "\(accountID)-\(window.kind.rawValue)"
    identifier = NSUserInterfaceItemIdentifier("usage-quota-window-\(suffix)")
    percentLabel.identifier = NSUserInterfaceItemIdentifier("usage-quota-percent-\(suffix)")
    alertLabel.identifier = NSUserInterfaceItemIdentifier("usage-quota-alert-\(suffix)")
    resetLabel.identifier = NSUserInterfaceItemIdentifier("usage-quota-reset-\(suffix)")
    track.identifier = NSUserInterfaceItemIdentifier("usage-quota-track-\(suffix)")
    translatesAutoresizingMaskIntoConstraints = false
    toolTip = Self.tooltip(for: window)

    let nameLabel = makeLabel(window.displayLabel, size: 11, color: AsterTheme.secondaryInk)
    // 窗口名按内容宽度占位，但比进度条更该保留：模型周窗口的名字可能较长，
    // 极窄时让它截断，而不是把整行压出约束冲突。
    nameLabel.setContentHuggingPriority(.required, for: .horizontal)
    nameLabel.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    // 数字跳动时不希望整行重新排版，所以百分比用等宽数字。
    percentLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
    percentLabel.alignment = .right
    percentLabel.setContentHuggingPriority(.required, for: .horizontal)
    percentLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    alertLabel.isHidden = severity != .critical
    resetLabel.alignment = .right
    resetLabel.setContentHuggingPriority(.required, for: .horizontal)

    track.wantsLayer = true
    track.layer?.cornerRadius = Self.trackHeight / 2
    track.layer?.masksToBounds = true
    fill.cornerRadius = Self.trackHeight / 2
    track.layer?.addSublayer(fill)
    track.translatesAutoresizingMaskIntoConstraints = false
    track.setContentHuggingPriority(.defaultLow, for: .horizontal)
    track.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let topRow = NSStackView(views: [nameLabel, track, percentLabel])
    topRow.orientation = .horizontal
    topRow.alignment = .centerY
    topRow.spacing = 8
    topRow.distribution = .fill

    let alertSpacer = NSView()
    alertSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    bottomRow.orientation = .horizontal
    bottomRow.alignment = .centerY
    bottomRow.spacing = 6
    bottomRow.setViews([alertLabel, alertSpacer, resetLabel], in: .leading)

    let stack = NSStackView(views: [topRow, bottomRow])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 3
    addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      track.heightAnchor.constraint(equalToConstant: Self.trackHeight),
      percentLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
      topRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
      bottomRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    updatePercentText()
    refresh(now: Date())
    applyColors()
  }

  required init?(coder: NSCoder) { nil }

  /// 展示口径切换：只改百分比文字与条宽，颜色不变（严重度与口径无关）。
  func apply(displayMode: UsageDisplayMode) {
    guard displayMode != self.displayMode else { return }
    self.displayMode = displayMode
    updatePercentText()
    needsLayout = true
  }

  /// 刷新倒计时文字。没有重置时间的窗口这一列留空。
  func refresh(now: Date) {
    if let resetsAt = usageWindow.resetsAt, resetsAt > now {
      resetLabel.stringValue = L("\(UsageDurationText.make(resetsAt.timeIntervalSince(now))) 后重置")
    } else {
      resetLabel.stringValue = ""
    }
    // 两个都没内容时整行收起，卡片不会多出一截空白。
    bottomRow.isHidden = alertLabel.isHidden && resetLabel.stringValue.isEmpty
  }

  private func updatePercentText() {
    let percent = displayMode.displayPercent(usedPercent: usageWindow.usedPercent)
    percentLabel.stringValue = "\(Int(percent.rounded()))%"
  }

  override func layout() {
    super.layout()
    let bounds = track.bounds
    // 关掉隐式动画：口径切换时条子应当直接落位，滑动过去会看着像数据在变。
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    fill.frame = CGRect(x: 0, y: 0, width: bounds.width * fillFraction, height: bounds.height)
    CATransaction.commit()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  private func applyColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      track.layer?.backgroundColor = AsterTheme.ink.withAlphaComponent(0.1).cgColor
      fill.backgroundColor =
        switch severity {
        case .normal: AsterTheme.accent.cgColor
        case .warning: AsterTheme.warning.cgColor
        case .critical: NSColor.systemRed.cgColor
        }
    }
  }
}

// MARK: - 时长文字

/// 时长短语（「2 小时 5 分」）。「X 后重置」与「X 前更新」共用同一套措辞。
@MainActor
enum UsageDurationText {
  private static let formatter: DateComponentsFormatter = {
    let formatter = DateComponentsFormatter()
    formatter.unitsStyle = .short
    formatter.allowedUnits = [.day, .hour, .minute]
    formatter.maximumUnitCount = 2
    return formatter
  }()

  /// 不足一分钟的差值按一分钟显示：显示「0 分钟」既不准确也没有信息量。
  static func make(_ interval: TimeInterval) -> String {
    formatter.string(from: max(interval, 60)) ?? ""
  }
}
