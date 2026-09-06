import AppKit
import AsterCore

/// 终端 Pane 底部的 Agent 用量条：左侧 provider 名，右侧按快照里存在的窗口显示
/// 「5h / 周 / 会话」三个小 meter。不承担任何自动行为；唯一的交互是点击整条
/// 向 Agent 提交它自己的统计命令（`AgentProvider.usageStatsCommand`）。
@MainActor
final class AgentUsageBarView: NSView {
  static let preferredHeight: CGFloat = 20
  /// 超过该百分比切换为 warning 色，提示接近配额上限。
  static let warningThreshold: Double = 80

  private let providerLabel = makeLabel("", size: 10, weight: .semibold, color: AsterTheme.secondaryInk)
  private var meters: [AgentUsageWindowKind: AgentUsageMeterView] = [:]
  private(set) var snapshot: AgentUsageSnapshot
  /// 点击回调，参数是要提交的斜杠命令；provider 没有统计命令时不会触发。
  var onOpenStats: ((String) -> Void)?

  /// 当前 provider 的统计命令；nil 时整条不可点击、不显示手型指针。
  var statsCommand: String? { snapshot.provider.usageStatsCommand }

  init(snapshot: AgentUsageSnapshot) {
    self.snapshot = snapshot
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("agent-usage-bar")
    translatesAutoresizingMaskIntoConstraints = false
    setAccessibilityRole(.group)

    let stack = NSStackView()
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.addArrangedSubview(providerLabel)
    // 固定创建三个 meter，按快照显隐；这样 `apply` 只改数值，不增删子视图。
    for kind in AgentUsageWindowKind.allCases {
      let meter = AgentUsageMeterView(kind: kind)
      meters[kind] = meter
      stack.addArrangedSubview(meter)
    }
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    stack.addArrangedSubview(spacer)
    addSubview(stack)
    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
      stack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    apply(snapshot)
  }

  required init?(coder: NSCoder) { nil }

  /// 单击整条：把 provider 的统计命令交给回调。meter 自身有 tooltip，点击仍冒泡到这里。
  override func mouseDown(with event: NSEvent) {
    guard event.clickCount == 1, let statsCommand, let onOpenStats else {
      super.mouseDown(with: event)
      return
    }
    onOpenStats(statsCommand)
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    if statsCommand != nil { addCursorRect(bounds, cursor: .pointingHand) }
  }

  /// 原地更新：只改 meter 的比例、颜色、文字与 tooltip，不重建子视图。
  func apply(_ snapshot: AgentUsageSnapshot) {
    self.snapshot = snapshot
    providerLabel.stringValue = snapshot.provider.displayName
    providerLabel.toolTip = statsCommand.map { "点击在 \(snapshot.provider.displayName) 中运行 \($0) 查看统计" }
    window?.invalidateCursorRects(for: self)
    for (kind, meter) in meters {
      if let window = snapshot.window(kind) {
        meter.apply(window)
        meter.isHidden = false
      } else {
        meter.isHidden = true
      }
    }
    setAccessibilityLabel(
      "\(snapshot.provider.displayName) 用量 "
        + snapshot.windows.map { "\($0.kind.shortLabel) \(Int($0.usedPercent))%" }.joined(separator: "，"))
  }
}

/// 单个 meter：短标签 + 圆角轨道 + 百分比文字。填充用 CALayer 直接设 frame，
/// 不走约束 multiplier（AppKit 的 multiplier 不可变，改比例得重建约束）。
@MainActor
final class AgentUsageMeterView: NSView {
  private static let trackWidth: CGFloat = 56
  private static let trackHeight: CGFloat = 4

  let kind: AgentUsageWindowKind
  private let label: NSTextField
  private let track = NSView()
  private let fill = CALayer()
  private let percentLabel = makeLabel("", size: 10, weight: .medium, color: AsterTheme.secondaryInk, monospaced: true)
  private(set) var fraction: Double = 0
  private var isWarning = false

  init(kind: AgentUsageWindowKind) {
    self.kind = kind
    label = makeLabel(kind.shortLabel, size: 10, weight: .regular, color: AsterTheme.tertiaryInk)
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("agent-usage-meter-\(kind.rawValue)")
    translatesAutoresizingMaskIntoConstraints = false
    track.wantsLayer = true
    track.layer?.cornerRadius = Self.trackHeight / 2
    track.layer?.masksToBounds = true
    fill.cornerRadius = Self.trackHeight / 2
    track.layer?.addSublayer(fill)
    track.translatesAutoresizingMaskIntoConstraints = false
    percentLabel.alignment = .right

    let stack = NSStackView(views: [label, track, percentLabel])
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = 5
    stack.translatesAutoresizingMaskIntoConstraints = false
    addSubview(stack)
    NSLayoutConstraint.activate([
      track.widthAnchor.constraint(equalToConstant: Self.trackWidth),
      track.heightAnchor.constraint(equalToConstant: Self.trackHeight),
      percentLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
      stack.leadingAnchor.constraint(equalTo: leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: trailingAnchor),
      stack.topAnchor.constraint(equalTo: topAnchor),
      stack.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
    applyColors()
  }

  required init?(coder: NSCoder) { nil }

  func apply(_ window: AgentUsageWindow) {
    fraction = min(max(window.usedPercent / 100, 0), 1)
    isWarning = window.usedPercent >= AgentUsageBarView.warningThreshold
    percentLabel.stringValue = "\(Int(window.usedPercent.rounded()))%"
    toolTip = Self.tooltip(for: window)
    applyColors()
    needsLayout = true
  }

  /// tooltip：窗口名 + 重置时间（本地时刻与相对时长）+ 补充说明。
  static func tooltip(for window: AgentUsageWindow, now: Date = Date()) -> String {
    var parts = ["\(window.kind.shortLabel) 已用 \(Int(window.usedPercent.rounded()))%"]
    if let resetsAt = window.resetsAt {
      let formatter = DateFormatter()
      formatter.dateStyle = .short
      formatter.timeStyle = .short
      parts.append("重置于 \(formatter.string(from: resetsAt))（\(RelativeTime.string(since: resetsAt, relativeTo: now))）")
    }
    if let detail = window.detail { parts.append(detail) }
    return parts.joined(separator: "\n")
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

  /// 动态 NSColor 要在当前外观下取 cgColor，明暗切换时重取。
  private func applyColors() {
    let appearance = effectiveAppearance
    appearance.performAsCurrentDrawingAppearance {
      track.layer?.backgroundColor = AsterTheme.hairline.cgColor
      fill.backgroundColor = (isWarning ? AsterTheme.warning : AsterTheme.accent).cgColor
    }
  }
}
