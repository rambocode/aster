// AI 用量浮动窗的外壳视图：顶部表头（标题 / 页签 / 数据时刻 + 刷新）与底部的口径分段条。
import AppKit
import AsterCore
import Foundation

/// 页面标题。`L()` 只接受字面量，映射写在视图层。
@MainActor
func usagePanelSectionTitle(_ section: UsagePanelViewController.Section) -> String {
  switch section {
  case .quota: L("配额")
  case .tokens: L("Token")
  case .sessions: L("会话")
  }
}

// MARK: - 分段控件

/// 一条圆角轨道里的 N 选一分段控件。页签、底栏口径、Token 页区间三处共用同一套样式。
///
/// 用字符串 id 而不是泛型：调用方的枚举各不相同（`Section`、`UsageDisplayMode`、时间区间），
/// 泛型化只会给视图加上无法 `@objc` 暴露的类型参数，换不来什么安全性；`rawValue` ↔ 枚举的
/// 换算留给各自的工厂函数做。
@MainActor
final class UsageSegmentedControl: NSView {
  /// 一格的身份与文字。
  struct Item {
    let id: String
    let title: String
  }

  /// 轨道圆角与内边距。整条轨道包住全部分段，切换时只有里面的胶囊在动。
  private static let trackCornerRadius: CGFloat = 7
  private static let trackInset: CGFloat = 2
  private static let segmentSpacing: CGFloat = 2
  private static let segmentHeight: CGFloat = 20

  private let stack = NSStackView()
  private let identifierPrefix: String
  private let onSelect: (String) -> Void
  private var segments: [String: UsageSegmentButton] = [:]
  /// 每格等宽时的公共宽度约束，`setItems` 换项时要连同旧分段一起拆掉。
  private var widthConstraints: [NSLayoutConstraint] = []

  private(set) var selection: String

  /// - Parameter identifierPrefix: 每格的 identifier 为 `<prefix>-<id>`，供测试与自动化定位。
  init(
    items: [Item],
    selected: String,
    identifierPrefix: String,
    onSelect: @escaping (String) -> Void
  ) {
    self.identifierPrefix = identifierPrefix
    self.onSelect = onSelect
    selection = selected
    super.init(frame: .zero)
    wantsLayer = true
    identifier = NSUserInterfaceItemIdentifier("\(identifierPrefix)-track")
    stack.orientation = .horizontal
    stack.alignment = .centerY
    stack.spacing = Self.segmentSpacing
    addSubview(stack)
    stack.pinEdges(
      to: self,
      insets: NSEdgeInsets(
        top: Self.trackInset, left: Self.trackInset, bottom: Self.trackInset,
        right: Self.trackInset))
    rebuild(items: items, selected: selected)
    applyTrackColors()
  }

  required init?(coder: NSCoder) { nil }

  /// 外部改选中态（恢复持久化、代码切换）时只更新样式，不再回调。幂等。
  func select(_ id: String) {
    guard selection != id, segments[id] != nil else { return }
    selection = id
    applySelection()
  }

  /// 换一组分段（Token 页的时间区间会随数据变）。选中项不在新集合里时退回第一格。
  func setItems(_ items: [Item], selected: String) {
    rebuild(items: items, selected: selected)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyTrackColors()
  }

  // MARK: - 构建

  private func rebuild(items: [Item], selected: String) {
    NSLayoutConstraint.deactivate(widthConstraints)
    widthConstraints.removeAll()
    for view in stack.arrangedSubviews { stack.removeArrangedSubview(view) }
    stack.removeAllSubviews()
    segments.removeAll()
    selection = items.contains(where: { $0.id == selected }) ? selected : (items.first?.id ?? "")

    // 各格等宽、且宽度按最宽的**粗体**文字算：选中态才是 semibold，按常规字重定宽会让
    // 胶囊在切换时忽宽忽窄，整条轨道跟着抖。
    let width = Self.segmentWidth(for: items)
    for item in items {
      let button = UsageSegmentButton(title: item.title) { [weak self] in
        self?.handleClick(item.id)
      }
      button.identifier = NSUserInterfaceItemIdentifier("\(identifierPrefix)-\(item.id)")
      button.translatesAutoresizingMaskIntoConstraints = false
      segments[item.id] = button
      stack.addArrangedSubview(button)
      let widthConstraint = button.widthAnchor.constraint(equalToConstant: width)
      let heightConstraint = button.heightAnchor.constraint(
        equalToConstant: Self.segmentHeight)
      widthConstraints.append(contentsOf: [widthConstraint, heightConstraint])
      NSLayoutConstraint.activate([widthConstraint, heightConstraint])
    }
    applySelection()
  }

  private static func segmentWidth(for items: [Item]) -> CGFloat {
    let font = NSFont.systemFont(ofSize: UsageSegmentButton.fontSize, weight: .semibold)
    let widest =
      items
      .map { ($0.title as NSString).size(withAttributes: [.font: font]).width }
      .max() ?? 0
    return ceil(widest) + UsageSegmentButton.horizontalInset * 2
  }

  private func handleClick(_ id: String) {
    guard selection != id else { return }
    selection = id
    applySelection()
    onSelect(id)
  }

  private func applySelection() {
    for (id, button) in segments { button.isSelected = id == selection }
  }

  /// 动态主题色要在当前外观下解析成具体色值，否则深浅模式共用一份 RGBA。
  ///
  /// 轨道取 9% 而不是实色面板时期的 6%：底下是磨砂玻璃，透出来的桌面会把这么淡的一层
  /// 冲掉，轨道一消失「三格里选中的是哪格」就只剩字重的差别，一眼看不出来。
  private func applyTrackColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.cornerRadius = Self.trackCornerRadius
      layer?.backgroundColor = AsterTheme.ink.withAlphaComponent(0.09).cgColor
    }
  }
}

/// 分段控件里的一格。悬停要有文字反馈，所以不用通用的 `ActionButton`。
@MainActor
final class UsageSegmentButton: NSButton {
  static let fontSize: CGFloat = 12
  static let horizontalInset: CGFloat = 10
  private static let cornerRadius: CGFloat = 5

  private let handler: () -> Void
  private let label: String
  private var hoverArea: NSTrackingArea?
  private var isHovering = false

  /// 选中态由分段控件统一下发；自己负责把它画出来。
  var isSelected = false {
    didSet {
      guard isSelected != oldValue else { return }
      applyStyle()
    }
  }

  init(title: String, handler: @escaping () -> Void) {
    self.handler = handler
    label = title
    super.init(frame: .zero)
    self.title = title
    bezelStyle = .inline
    isBordered = false
    wantsLayer = true
    // 选中态要投一点很轻的阴影，layer 不能裁掉自己的影子。
    layer?.masksToBounds = false
    target = self
    action = #selector(invoke)
    applyStyle()
  }

  required init?(coder: NSCoder) { nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverArea { removeTrackingArea(hoverArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self)
    addTrackingArea(area)
    hoverArea = area
  }

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    guard !isHovering else { return }
    isHovering = true
    applyStyle()
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    guard isHovering else { return }
    isHovering = false
    applyStyle()
  }

  /// 隐藏时收不到 `mouseExited`，重新显示会残留上一次的悬停态。
  override var isHidden: Bool {
    didSet {
      guard isHidden, isHovering else { return }
      isHovering = false
      applyStyle()
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyStyle()
  }

  private func applyStyle() {
    attributedTitle = NSAttributedString(
      string: label,
      attributes: [
        .font: NSFont.systemFont(
          ofSize: Self.fontSize, weight: isSelected ? .semibold : .regular),
        // 未选中项悬停时提到主文字色：没有底色变化的话，光标停在哪一格是看不出来的。
        .foregroundColor: (isSelected || isHovering) ? AsterTheme.ink : AsterTheme.secondaryInk,
      ])
    effectiveAppearance.performAsCurrentDrawingAppearance {
      guard let layer else { return }
      layer.cornerRadius = Self.cornerRadius
      guard isSelected else {
        layer.backgroundColor = NSColor.clear.cgColor
        layer.borderWidth = 0
        layer.shadowOpacity = 0
        return
      }
      layer.backgroundColor = AsterTheme.paper.cgColor
      layer.borderColor = AsterTheme.hairline.withAlphaComponent(0.6).cgColor
      layer.borderWidth = 0.5
      layer.shadowColor = NSColor.black.cgColor
      layer.shadowOpacity = 0.12
      layer.shadowRadius = 2
      layer.shadowOffset = CGSize(width: 0, height: -0.5)
    }
  }

  @objc private func invoke() { handler() }
}

/// 页签分段控件。`Section` ↔ `rawValue` 的换算收在这里，调用方只见枚举。
@MainActor
func makeUsagePanelTabBar(
  selection: UsagePanelViewController.Section,
  onSelect: @escaping (UsagePanelViewController.Section) -> Void
) -> UsageSegmentedControl {
  UsageSegmentedControl(
    items: UsagePanelViewController.Section.allCases.map {
      UsageSegmentedControl.Item(id: $0.rawValue, title: usagePanelSectionTitle($0))
    },
    selected: selection.rawValue,
    identifierPrefix: "usage-panel-tab",
    onSelect: { raw in
      guard let section = UsagePanelViewController.Section(rawValue: raw) else { return }
      onSelect(section)
    })
}

// MARK: - 分隔线

/// 1pt 主题分隔线。表头底下与底栏顶上各压一条，把中间的内容区框出来。
///
/// 用 `AsterTheme.hairline` 而不是更淡的 `AsterTheme.divider`：面板底是磨砂玻璃，透出来的
/// 桌面本身就有花纹，40% 不透明度的线在上面基本消失，表头 / 内容 / 底栏会糊成一片。
@MainActor
final class UsagePanelHairline: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
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

// MARK: - 表头

/// 浮动窗表头：标题行（红绿灯同一带）+ 控件行（页签居中、数据时刻与刷新按钮靠右）。
///
/// 两行而不是一行，是因为 `fullSizeContentView` 下 `NSTitlebarContainerView` 盖在内容视图
/// 之上，落在顶部 28pt 里的按钮点不动（点击会被当成拖窗口）。所以只有不可点的标题文字
/// 放进标题栏那一带，页签和刷新按钮一律压到 28pt 以下。
@MainActor
final class UsagePanelHeaderView: NSView {
  /// 标题栏带高度：红绿灯所在的区域，内容不得放可点控件。
  static let titlebarInset: CGFloat = 28
  /// 控件行高度。
  private static let controlRowHeight: CGFloat = 34
  /// 标题左内缩：三颗窗口按钮最右一颗大约到 x=60，再留一段呼吸位。
  private static let titleLeadingInset: CGFloat = 76
  private static let horizontalInset: CGFloat = 14

  private let titleLabel = makeLabel(L("AI 用量"), size: 13, weight: .semibold)
  private let statusLabel = makeLabel(
    "", size: 11, color: AsterTheme.secondaryInk)
  private let tabBar: UsageSegmentedControl
  private let refreshButton: IconHoverButton

  /// 供测试读取当前的数据时刻文字。
  var statusText: String { statusLabel.stringValue }

  init(
    selection: UsagePanelViewController.Section,
    onSelectSection: @escaping (UsagePanelViewController.Section) -> Void,
    onRefresh: @escaping () -> Void
  ) {
    tabBar = makeUsagePanelTabBar(selection: selection, onSelect: onSelectSection)
    refreshButton = IconHoverButton(
      symbol: "arrow.clockwise", accessibilityDescription: L("刷新"), handler: onRefresh)
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("usage-panel-header")
    titleLabel.identifier = NSUserInterfaceItemIdentifier("usage-panel-title")
    statusLabel.identifier = NSUserInterfaceItemIdentifier("usage-panel-stamp")
    refreshButton.identifier = NSUserInterfaceItemIdentifier("usage-panel-refresh")
    refreshButton.toolTip = L("刷新")

    let hairline = UsagePanelHairline()
    for child in [titleLabel, statusLabel, tabBar, refreshButton, hairline] as [NSView] {
      child.translatesAutoresizingMaskIntoConstraints = false
      addSubview(child)
    }

    // 标题和状态文字都让位给页签：宽度不够时先截断它们，页签始终完整可读。
    titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    statusLabel.setContentCompressionResistancePriority(.defaultLow - 1, for: .horizontal)

    // 页签严格居中于表头（分段控件的宽度由各格的等宽约束完全定死，居中不会有歧义）。
    // 左右两侧的留白约束都降到非必需：窗口拉到最小宽度时先牺牲留白，而不是让页签偏心，
    // 更不是刷一屏约束冲突。
    let controlCenterY = Self.titlebarInset + Self.controlRowHeight / 2
    let tabLeading = tabBar.leadingAnchor.constraint(
      greaterThanOrEqualTo: leadingAnchor, constant: Self.horizontalInset)
    tabLeading.priority = .defaultHigh
    let statusGap = statusLabel.leadingAnchor.constraint(
      greaterThanOrEqualTo: tabBar.trailingAnchor, constant: 8)
    statusGap.priority = .defaultHigh
    NSLayoutConstraint.activate([
      tabBar.centerXAnchor.constraint(equalTo: centerXAnchor),
      tabLeading,
      statusGap,
      titleLabel.leadingAnchor.constraint(
        equalTo: leadingAnchor, constant: Self.titleLeadingInset),
      titleLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingAnchor, constant: -Self.horizontalInset),
      titleLabel.centerYAnchor.constraint(
        equalTo: topAnchor, constant: Self.titlebarInset / 2),

      tabBar.centerYAnchor.constraint(equalTo: topAnchor, constant: controlCenterY),

      refreshButton.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -Self.horizontalInset),
      refreshButton.centerYAnchor.constraint(equalTo: topAnchor, constant: controlCenterY),
      refreshButton.widthAnchor.constraint(equalToConstant: 22),
      refreshButton.heightAnchor.constraint(equalToConstant: 22),

      statusLabel.trailingAnchor.constraint(
        equalTo: refreshButton.leadingAnchor, constant: -6),
      statusLabel.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor),

      hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
      hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
      hairline.bottomAnchor.constraint(equalTo: bottomAnchor),
      heightAnchor.constraint(equalToConstant: Self.titlebarInset + Self.controlRowHeight),
    ])
  }

  required init?(coder: NSCoder) { nil }

  /// 外部代码切页时同步页签样式。
  func select(_ section: UsagePanelViewController.Section) { tabBar.select(section.rawValue) }

  /// 刷新「X 前更新」。
  ///
  /// 刻意不做参考应用那种「N 秒后刷新」倒计时：各来源的轮询节奏并不一致（Claude 走共享
  /// 服务的被动档，其余三家各自 300 秒一轮，还都带节流与失败静默），一个统一的倒计时数字
  /// 对任何一路都不成立，只会让用户按着一个假承诺等。显示数据到手的时刻才是真的。
  func apply(fetchedAt: Date?, now: Date) {
    guard let fetchedAt else {
      // 从来没取到过数据（功能刚开、所有来源都读不到）时说清楚状态，而不是留一片空白。
      statusLabel.stringValue = L("尚未取数")
      return
    }
    statusLabel.stringValue = L("\(UsageDurationText.make(now.timeIntervalSince(fetchedAt))) 前更新")
  }
}

// MARK: - 底栏

/// 浮动窗底栏：左侧「已用 / 剩余」二选一，右侧留空。
///
/// 右侧刻意不放参考应用那排图标按钮——那些是它自己的窗口管理入口（置顶、紧凑模式等），
/// Aster 的浮动窗没有对应能力，摆一排点不动的图标只是噪声。
@MainActor
final class UsagePanelFooterView: NSView {
  private static let height: CGFloat = 32
  private static let horizontalInset: CGFloat = 14

  private let chips: UsageSegmentedControl

  init(displayMode: UsageDisplayMode, onSelect: @escaping (UsageDisplayMode) -> Void) {
    chips = UsageSegmentedControl(
      items: UsageDisplayMode.allCases.map {
        UsageSegmentedControl.Item(id: $0.rawValue, title: $0.shortLabel)
      },
      selected: displayMode.rawValue,
      identifierPrefix: "usage-panel-mode",
      onSelect: { raw in
        guard let mode = UsageDisplayMode(rawValue: raw) else { return }
        onSelect(mode)
      })
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("usage-panel-footer")

    let hairline = UsagePanelHairline()
    for child in [chips, hairline] as [NSView] {
      child.translatesAutoresizingMaskIntoConstraints = false
      addSubview(child)
    }
    NSLayoutConstraint.activate([
      chips.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.horizontalInset),
      chips.trailingAnchor.constraint(
        lessThanOrEqualTo: trailingAnchor, constant: -Self.horizontalInset),
      chips.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 1),
      hairline.leadingAnchor.constraint(equalTo: leadingAnchor),
      hairline.trailingAnchor.constraint(equalTo: trailingAnchor),
      hairline.topAnchor.constraint(equalTo: topAnchor),
      heightAnchor.constraint(equalToConstant: Self.height),
    ])
  }

  required init?(coder: NSCoder) { nil }

  /// 外部改口径（恢复持久化）时只更新样式，不再回调。
  func select(_ mode: UsageDisplayMode) { chips.select(mode.rawValue) }
}
