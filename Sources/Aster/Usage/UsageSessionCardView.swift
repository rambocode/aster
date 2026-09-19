// 会话看板上的一张卡：Agent 图标、标题、目录、状态徽标与进程树占用。
import AppKit
import AsterCore

/// 一张会话卡。
///
/// 做成 `NSButton` 而不是普通视图：整张卡就是一个「跳到这个 Pane」的动作，
/// 交给 AppKit 管按钮语义，测试也能直接 `performClick(nil)`，不必伪造鼠标事件。
@MainActor
final class UsageSessionCardView: NSButton {
  /// 卡片对应的 Pane。座位数组与增量更新都以它为身份。
  let entryID: UUID

  private let accentBar = NSView()
  private let iconView = NSImageView()
  private let titleLabel: NSTextField
  private let statusLabel: NSTextField
  private let directoryLabel: NSTextField
  private let footprintLabel: NSTextField
  private let onActivate: (UUID) -> Void

  private var isHovering = false
  private var hoverTrackingArea: NSTrackingArea?
  /// 当前状态。颜色随外观切换重刷时要用，不能只写进 label。
  private var status: AgentControlStatus = .unknown

  init(entryID: UUID, onActivate: @escaping (UUID) -> Void) {
    self.entryID = entryID
    self.onActivate = onActivate
    titleLabel = makeLabel("", size: 12, weight: .semibold)
    statusLabel = makeLabel("", size: 10, weight: .medium, color: AsterTheme.tertiaryInk)
    directoryLabel = makeLabel("", size: 10, color: AsterTheme.tertiaryInk)
    footprintLabel = makeLabel(
      "", size: 10, color: AsterTheme.secondaryInk, monospaced: true)
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("usage-session-card")
    setButtonType(.momentaryChange)
    isBordered = false
    title = ""
    focusRingType = .none
    wantsLayer = true
    layer?.cornerRadius = 8
    target = self
    action = #selector(handleClick)
    buildLayout()
    applyColors()
  }

  required init?(coder: NSCoder) { nil }

  // MARK: - 内容

  /// 原地更新卡片内容。状态或占用变化只改文字与颜色，不重建视图。
  func update(entry: UsageSessionEntry, footprint: ProcessFootprint?) {
    status = entry.status
    titleLabel.stringValue = Self.displayTitle(for: entry)
    iconView.image = TabIconArtwork.image(named: TabRowButton.agentIconName(entry.provider))
    statusLabel.stringValue = Self.statusTitle(entry.status)
    let directory = entry.workingDirectory ?? ""
    directoryLabel.stringValue = (directory as NSString).abbreviatingWithTildeInPath
    directoryLabel.isHidden = directory.isEmpty
    footprintLabel.stringValue = Self.footprintText(footprint)
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

  /// 状态徽标文案。`L()` 只接受字面量，枚举到文案的映射只能写在视图层。
  static func statusTitle(_ status: AgentControlStatus) -> String {
    switch status {
    case .blocked: L("等待输入")
    case .working: L("运行中")
    case .done: L("已完成")
    case .idle: L("空闲")
    case .unknown: L("未知")
    }
  }

  /// 底行占用文案。
  ///
  /// CPU / 内存先在 Core 的纯函数里拼成 `String` 再插值：`L()` 的 key 里出现字面 `%`
  /// 要写成 `%%`，而插值表达式必须是 `String`，把 `12%` 整个作为参数传进去最稳妥。
  static func footprintText(_ footprint: ProcessFootprint?) -> String {
    let cpu = UsageSessionBoardOrder.cpuText(footprint?.cpuPercent)
    let memory = UsageSessionBoardOrder.memoryText(footprint?.memoryBytes)
    guard let footprint else { return L("CPU \(cpu) · 内存 \(memory)") }
    let processes = String(footprint.processes)
    return L("CPU \(cpu) · 内存 \(memory) · \(processes) 个进程")
  }

  // MARK: - 测试读取点

  var titleText: String { titleLabel.stringValue }
  var statusText: String { statusLabel.stringValue }
  var directoryText: String { directoryLabel.stringValue }
  var footprintText: String { footprintLabel.stringValue }
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

    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    statusLabel.alignment = .right
    statusLabel.setContentHuggingPriority(.required, for: .horizontal)
    statusLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
    directoryLabel.lineBreakMode = .byTruncatingMiddle
    directoryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    footprintLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    let header = NSStackView(views: [iconView, titleLabel, statusLabel])
    header.orientation = .horizontal
    header.alignment = .centerY
    header.spacing = 6
    header.distribution = .fill

    let rows = NSStackView(views: [header, directoryLabel, footprintLabel])
    rows.orientation = .vertical
    rows.alignment = .leading
    rows.spacing = 3
    rows.translatesAutoresizingMaskIntoConstraints = false

    accentBar.wantsLayer = true
    accentBar.layer?.cornerRadius = 1.5
    accentBar.isHidden = true
    accentBar.translatesAutoresizingMaskIntoConstraints = false
    accentBar.identifier = NSUserInterfaceItemIdentifier("usage-session-card-accent")

    addSubview(accentBar)
    addSubview(rows)
    rows.pinEdges(to: self, insets: NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12))
    NSLayoutConstraint.activate([
      accentBar.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 3),
      accentBar.topAnchor.constraint(equalTo: topAnchor, constant: 6),
      accentBar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
      accentBar.widthAnchor.constraint(equalToConstant: 3),
      iconView.widthAnchor.constraint(equalToConstant: 14),
      iconView.heightAnchor.constraint(equalToConstant: 14),
      // 三行都要按卡片宽度收口，否则 `.leading` 对齐的 stack 会让长目录把卡片撑宽。
      header.widthAnchor.constraint(equalTo: rows.widthAnchor),
      directoryLabel.widthAnchor.constraint(equalTo: rows.widthAnchor),
      footprintLabel.widthAnchor.constraint(equalTo: rows.widthAnchor),
    ])
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  /// 动态主题色必须在当前外观下解析成 `cgColor`，否则深浅模式共用同一份 RGBA。
  private func applyColors() {
    statusLabel.textColor = Self.statusColor(status)
    iconView.contentTintColor = AsterTheme.secondaryInk
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor =
        AsterTheme.ink.withAlphaComponent(isHovering ? 0.09 : 0.05).cgColor
      layer?.borderColor = AsterTheme.hairline.withAlphaComponent(0.5).cgColor
      layer?.borderWidth = 1
      accentBar.layer?.backgroundColor = NSColor.systemRed.cgColor
    }
  }

  /// 状态徽标配色：等待输入用系统红（与状态栏红点同一个红），运行中用强调色，其余次要色。
  static func statusColor(_ status: AgentControlStatus) -> NSColor {
    switch status {
    case .blocked: .systemRed
    case .working: AsterTheme.accent
    case .done: AsterTheme.secondaryInk
    case .idle, .unknown: AsterTheme.tertiaryInk
    }
  }
}
