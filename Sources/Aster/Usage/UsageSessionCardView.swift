// 会话看板上的一张卡：Agent 图标 + 标题 + 状态胶囊，下面是目录与 CPU / 内存 / 进程三等分指标列。
import AppKit
import AsterCore

/// 卡头右侧的状态胶囊。
///
/// 做成独立视图而不是带背景的标签：胶囊底色要跟着明暗外观重刷，`NSTextField`
/// 自己的 `backgroundColor` 不走 layer，画不出圆角小底。
@MainActor
final class UsageSessionStatusBadge: NSView {
  private let label = makeLabel("", size: 10, weight: .medium, color: AsterTheme.secondaryInk)
  /// 是否走警示（红色）配色。等待输入的会话用它。
  private(set) var isAlert = false

  init() {
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("usage-session-status-badge")
    wantsLayer = true
    layer?.cornerRadius = 4
    addSubview(label)
    label.pinEdges(to: self, insets: NSEdgeInsets(top: 1, left: 5, bottom: 1, right: 5))
    applyColors()
  }

  required init?(coder: NSCoder) { nil }

  /// 原地改文字与配色，不重建视图。
  func update(text: String, isAlert: Bool) {
    label.stringValue = text
    self.isAlert = isAlert
    applyColors()
  }

  var text: String { label.stringValue }
  var textColor: NSColor { label.textColor ?? AsterTheme.secondaryInk }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  /// 动态主题色必须在当前外观下解析成 `cgColor`，否则深浅模式共用同一份 RGBA。
  private func applyColors() {
    let tint: NSColor = isAlert ? .systemRed : AsterTheme.secondaryInk
    label.textColor = tint
    effectiveAppearance.performAsCurrentDrawingAppearance {
      let base: NSColor = isAlert ? .systemRed : AsterTheme.ink
      layer?.backgroundColor = base.withAlphaComponent(0.08).cgColor
    }
  }
}

/// 卡片底部的一列指标：标签在上、数值在下。
@MainActor
final class UsageSessionMetricColumn: NSStackView {
  private let nameLabel: NSTextField
  private let valueLabel: NSTextField

  init(name: String, key: String) {
    // 磨砂背景下 tertiaryInk 的小字会发虚，标签提到 secondaryInk，数值保持 ink。
    nameLabel = makeLabel(name, size: 10, color: AsterTheme.secondaryInk)
    valueLabel = makeLabel("", size: 12, weight: .semibold, monospaced: true)
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier(key)
    orientation = .vertical
    alignment = .leading
    spacing = 1
    addArrangedSubview(nameLabel)
    addArrangedSubview(valueLabel)
  }

  required init?(coder: NSCoder) { nil }

  /// 只改数值，标签常驻。
  func update(_ value: String) {
    valueLabel.stringValue = value
  }

  // MARK: - 测试读取点

  var nameText: String { nameLabel.stringValue }
  var valueText: String { valueLabel.stringValue }
  var orderedTexts: [String] {
    arrangedSubviews.compactMap { ($0 as? NSTextField)?.stringValue }
  }
}

/// 一张会话卡。
///
/// 做成 `NSButton` 而不是普通视图：整张卡就是一个「跳到这个 Pane」的动作，
/// 交给 AppKit 管按钮语义，测试也能直接 `performClick(nil)`，不必伪造鼠标事件。
@MainActor
final class UsageSessionCardView: NSButton {
  /// 卡片对应的 Pane。座位数组与增量更新都以它为身份。
  let entryID: UUID

  /// 取不到占用时的占位文案，与 Core 的 `cpuText(nil)` 保持一致。
  private static let unavailableText = "—"

  private let accentBar = NSView()
  private let iconView = NSImageView()
  private let titleLabel: NSTextField
  private let statusBadge = UsageSessionStatusBadge()
  private let directoryLabel: NSTextField
  private let cpuColumn: UsageSessionMetricColumn
  private let memoryColumn: UsageSessionMetricColumn
  private let processColumn: UsageSessionMetricColumn
  private let metricsStack = NSStackView()
  private let onActivate: (UUID) -> Void

  private var isHovering = false
  private var hoverTrackingArea: NSTrackingArea?

  init(entryID: UUID, onActivate: @escaping (UUID) -> Void) {
    self.entryID = entryID
    self.onActivate = onActivate
    titleLabel = makeLabel("", size: 15, weight: .semibold)
    // 目录同理：磨砂上 tertiaryInk 几乎看不见。
    directoryLabel = makeLabel("", size: 11, color: AsterTheme.secondaryInk)
    cpuColumn = UsageSessionMetricColumn(name: L("CPU"), key: "usage-session-metric-cpu")
    memoryColumn = UsageSessionMetricColumn(name: L("内存"), key: "usage-session-metric-memory")
    processColumn = UsageSessionMetricColumn(name: L("进程"), key: "usage-session-metric-process")
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("usage-session-card")
    setButtonType(.momentaryChange)
    isBordered = false
    title = ""
    focusRingType = .none
    wantsLayer = true
    target = self
    action = #selector(handleClick)
    buildLayout()
    clearMetrics()
    applyColors()
  }

  required init?(coder: NSCoder) { nil }

  // MARK: - 内容

  /// 原地更新卡片内容。状态或占用变化只改文字与颜色，不重建视图。
  func update(entry: UsageSessionEntry, footprint: ProcessFootprint?) {
    titleLabel.stringValue = Self.displayTitle(for: entry)
    iconView.image = TabIconArtwork.image(named: TabRowButton.agentIconName(entry.provider))
    statusBadge.update(text: Self.statusTitle(entry.status), isAlert: entry.status == .blocked)
    let directory = entry.workingDirectory ?? ""
    directoryLabel.stringValue = (directory as NSString).abbreviatingWithTildeInPath
    directoryLabel.isHidden = directory.isEmpty
    cpuColumn.update(UsageSessionBoardOrder.cpuText(footprint?.cpuPercent))
    memoryColumn.update(UsageSessionBoardOrder.memoryText(footprint?.memoryBytes))
    processColumn.update(footprint.map { String($0.processes) } ?? Self.unavailableText)
    // 目录被中间截断后仍要能读全，完整路径留在 tooltip 里。
    toolTip = directory.isEmpty ? nil : directory
    accentBar.isHidden = entry.status != .blocked
    applyColors()
  }

  /// 卡片标题：终端标题优先，其次是工作目录最后一段，都没有就用 Agent 名。
  static func displayTitle(for entry: UsageSessionEntry) -> String {
    if let title = entry.title, !title.isEmpty { return title }
    if let directory = entry.workingDirectory, !directory.isEmpty {
      let last = (directory as NSString).lastPathComponent
      if !last.isEmpty { return last }
    }
    return entry.provider.displayName
  }

  /// 状态胶囊文案。`L()` 只接受字面量，枚举到文案的映射只能写在视图层。
  static func statusTitle(_ status: AgentControlStatus) -> String {
    switch status {
    case .blocked: L("等待输入")
    case .working: L("运行中")
    case .done: L("已完成")
    case .idle: L("空闲")
    case .unknown: L("未知")
    }
  }

  /// 首帧还没有采样结果，三列先摆破折号，避免出现空白列。
  private func clearMetrics() {
    for column in metricColumns { column.update(Self.unavailableText) }
  }

  // MARK: - 测试读取点

  var titleText: String { titleLabel.stringValue }
  var statusText: String { statusBadge.text }
  var statusTextColor: NSColor { statusBadge.textColor }
  var directoryText: String { directoryLabel.stringValue }
  /// 目录必须中间截断：路径的头尾比中段更有信息量。
  var directoryTruncatesMiddle: Bool { directoryLabel.lineBreakMode == .byTruncatingMiddle }
  var metricColumns: [UsageSessionMetricColumn] { [cpuColumn, memoryColumn, processColumn] }
  var metricsDistribution: NSStackView.Distribution { metricsStack.distribution }
  var cpuText: String { cpuColumn.valueText }
  var memoryText: String { memoryColumn.valueText }
  var processText: String { processColumn.valueText }
  var showsBlockedAccent: Bool { !accentBar.isHidden }

  // MARK: - 交互

  @objc private func handleClick() {
    onActivate(entryID)
  }

  /// 整张卡都是点击区：默认命中测试会被内部的标签先吃掉点击。
  /// `point` 来自父视图坐标系，换算后只判断是否落在卡片内。
  override func hitTest(_ point: NSPoint) -> NSView? {
    guard let superview else { return nil }
    return bounds.contains(convert(point, from: superview)) ? self : nil
  }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    isHovering = true
    applyColors()
  }

  override func mouseExited(with event: NSEvent) {
    isHovering = false
    applyColors()
  }

  // MARK: - 视觉

  private func buildLayout() {
    iconView.imageScaling = .scaleProportionallyUpOrDown
    iconView.translatesAutoresizingMaskIntoConstraints = false
    iconView.setContentHuggingPriority(.required, for: .horizontal)

    // 让末尾的弹簧吸收多余宽度，胶囊才会紧贴标题右侧；否则标题会被拉长，把胶囊
    // 推到卡片最右边。标题的抗压缩最低，长标题先截断，胶囊始终完整。
    titleLabel.setContentHuggingPriority(NSLayoutConstraint.Priority(251), for: .horizontal)
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    statusBadge.setContentHuggingPriority(.required, for: .horizontal)
    statusBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
    let spacer = NSView()
    spacer.translatesAutoresizingMaskIntoConstraints = false
    spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
    // 空视图没有固有高度，`.centerY` 对齐会留下歧义，显式钉成 0 高。
    spacer.heightAnchor.constraint(equalToConstant: 0).isActive = true

    directoryLabel.lineBreakMode = .byTruncatingMiddle
    directoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let header = NSStackView(views: [iconView, titleLabel, statusBadge, spacer])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 6
    header.distribution = .fill
    header.identifier = NSUserInterfaceItemIdentifier("usage-session-card-header")

    metricsStack.orientation = .horizontal
    metricsStack.alignment = .top
    metricsStack.distribution = .fillEqually
    metricsStack.spacing = 8
    metricsStack.identifier = NSUserInterfaceItemIdentifier("usage-session-metrics")
    for column in metricColumns { metricsStack.addArrangedSubview(column) }

    let rows = NSStackView(views: [header, directoryLabel, metricsStack])
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 4
    // 指标列与上面的身份信息是两组内容，留出更大的间距把它们分开。
    rows.setCustomSpacing(12, after: directoryLabel)
    rows.translatesAutoresizingMaskIntoConstraints = false

    accentBar.wantsLayer = true
    accentBar.layer?.cornerRadius = 1.5
    accentBar.isHidden = true
    accentBar.translatesAutoresizingMaskIntoConstraints = false
    accentBar.identifier = NSUserInterfaceItemIdentifier("usage-session-card-accent")

    addSubview(accentBar)
    addSubview(rows)
    let inset = UsageCardStyle.contentInset
    rows.pinEdges(
      to: self,
      insets: NSEdgeInsets(top: inset, left: inset, bottom: inset, right: inset))
    NSLayoutConstraint.activate([
      accentBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
      accentBar.topAnchor.constraint(equalTo: topAnchor, constant: 8),
      accentBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -8),
      accentBar.widthAnchor.constraint(equalToConstant: 3),
      iconView.widthAnchor.constraint(equalToConstant: 16),
      iconView.heightAnchor.constraint(equalToConstant: 16),
      // 三行都要按卡片宽度收口，否则 `.leading` 对齐的 stack 会让长目录把卡片撑宽。
      header.widthAnchor.constraint(equalTo: rows.widthAnchor),
      directoryLabel.widthAnchor.constraint(equalTo: rows.widthAnchor),
      metricsStack.widthAnchor.constraint(equalTo: rows.widthAnchor),
    ])
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  /// 动态主题色必须在当前外观下解析成 `cgColor`，否则深浅模式共用同一份 RGBA。
  private func applyColors() {
    iconView.contentTintColor = AsterTheme.secondaryInk
    // 卡片底与描边走三页共用的 `UsageCardStyle`，悬停态由它内部加深。
    UsageCardStyle.apply(to: self, hovered: isHovering)
    effectiveAppearance.performAsCurrentDrawingAppearance {
      accentBar.layer?.backgroundColor = NSColor.systemRed.cgColor
    }
  }
}
