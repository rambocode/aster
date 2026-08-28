import AppKit
import AsterCore
import Combine

/// 左侧 Panel 内的标签、分组和操作控件。

/// 分组头的点击宿主：整行命中，单击切换该分组的折叠状态（对齐 Otty 分组折叠）。
/// 用 mouseDown 立即派发的原因与 TabRowButton 相同——折叠会触发侧栏整树重建，
/// 等 mouseUp 时视图可能已被销毁导致点击丢失。
@MainActor
final class SidebarGroupHeaderView: NSView {
  private let onToggle: () -> Void

  init(onToggle: @escaping () -> Void) {
    self.onToggle = onToggle
    super.init(frame: .zero)
  }

  required init?(coder: NSCoder) { nil }

  override func mouseDown(with event: NSEvent) {
    onToggle()
  }
}

@MainActor
final class SidebarOptionsButton: NSButton {
  private let menuProvider: () -> NSMenu

  init(menuProvider: @escaping () -> NSMenu) {
    self.menuProvider = menuProvider
    super.init(frame: .zero)
    image = NSImage(
      systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: "整理标签")
    imagePosition = .imageOnly
    toolTip = "整理标签"
    isBordered = false
    // Otty 的整理按钮与 TABS eyebrow 同属三级 chrome，不跟随系统默认 control tint；
    // 否则 Floating Card 等主题切换后图标会突然变成主文字色。
    contentTintColor = AsterTheme.tertiaryInk
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.cornerCurve = .continuous
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 28),
      heightAnchor.constraint(equalToConstant: 28),
    ])
    menu = menuProvider()
  }

  required init?(coder: NSCoder) { nil }

  override func mouseDown(with event: NSEvent) {
    layer?.backgroundColor = AsterTheme.ink.withAlphaComponent(0.08).cgColor
    let menu = menuProvider()
    self.menu = menu
    menu.popUp(positioning: nil, at: NSPoint(x: bounds.minX, y: bounds.minY - 4), in: self)
    layer?.backgroundColor = NSColor.clear.cgColor
  }
}

/// AppKit 原生标签行直接按 Otty token 设置 layer；悬停、选中、字重、边框和阴影
/// 都不经过跨框架的 Material/Shape 二次混色。
@MainActor
final class TabRowButton: NSButton {
  /// 视觉底卡两侧留白 = Otty `[sidebar].padding`（默认 8pt）；April 等主题写 0
  /// 实现整行铺满。按钮本身仍保持整行命中宽度。
  private let sidebarRowInsets: ThemeInsets
  private let tab: TerminalTabItem
  /// group by project 可覆盖纵向行文案；闭包保证后续局部标题刷新仍遵守当前投影，
  /// 不会被 OSC 标题重新改回完整路径。
  private let displayTitleProvider: () -> String
  private let displayTitleToolTip: String?
  private let selected: Bool
  private let horizontal: Bool
  private let showsExitStatus: Bool
  private let showsFinished: Bool
  private let showsFailure: Bool
  private let showsAwaitingInput: Bool
  /// 规则解析出的标签图标；nil 表示没有规则命中。
  private let tabIcon: TabRuleIcon?
  /// 图标与角标的摆放：合并时图标占用状态槽、有状态时让位；分开时图标固定在标题左侧。
  private let badgePlacement: TabBadgePlacement
  private let style: TerminalTabStyle
  private let resolvedForeground: NSColor
  private let resolvedActiveForeground: NSColor
  private let resolvedHoverBackground: NSColor
  private let resolvedActiveBackground: NSColor
  private let resolvedActiveBorder: NSColor
  private let handler: () -> Void
  private let onDragEnd: (NSPoint) -> Void
  private var tracking: NSTrackingArea?
  /// 状态附件与其固定槽位；纵横两种方向共用同一套「附件 ↔ 关闭按钮」切换。
  private weak var accessoryView: NSView?
  private weak var accessorySlot: NSView?
  private weak var closeButton: NSButton?
  /// 横向胶囊的槽位宽度：仅在需要展示关闭按钮或状态徽章时占位，
  /// 未选中的纯文字标签收紧为 0，避免标签之间出现大段空白。
  private var slotWidthConstraint: NSLayoutConstraint?
  /// 纵向行的标题标签；标题经 `titleChanged` 局部刷新，不重建整行。
  private weak var titleLabel: NSTextField?
  /// 纵向行标题左侧的状态槽（对齐 Otty）：静态时放 Agent / 规则图标，运行时放动画图标。
  /// 横向胶囊没有这个槽，状态仍走右侧 accessorySlot。
  private weak var statusSlot: NSView?
  /// 状态槽宽度：无图标可显示时收紧为 0，标题贴回卡片内边距（Otty 无图标行不留空位）。
  private var statusSlotWidthConstraint: NSLayoutConstraint?
  /// 状态槽与标题的间距：槽收起时一并归零。
  private var titleLeadingGapConstraint: NSLayoutConstraint?
  /// 纵向行右侧的 shell 名 / Pane 数量标签，悬停时让位给关闭按钮。
  private weak var trailingLabel: NSTextField?
  /// 最近一次渲染的徽章状态键；状态未变时跳过附件重建，避免 spinner 动画被反复重启。
  private var renderedBadgeKey: String?
  /// 侧栏行的内缩圆角底。整行仍然是全宽命中区，只有这层底色两侧留边并带圆角，
  /// 因此指针落在行的任何位置都能点中，视觉上却是一枚独立的圆角卡片。
  private weak var rowBackground: NSView?
  private var hovered = false {
    didSet {
      guard hovered != oldValue else { return }
      updateStyle()
      updateAccessoryVisibility()
    }
  }

  init(
    tab: TerminalTabItem,
    selected: Bool,
    horizontal: Bool,
    rowHeight: CGFloat? = nil,
    theme: TerminalTheme,
    showsExitStatus: Bool,
    showsFinished: Bool,
    showsFailure: Bool,
    showsAwaitingInput: Bool,
    tabIcon: TabRuleIcon? = nil,
    badgePlacement: TabBadgePlacement = .combined,
    displayTitleProvider: (() -> String)? = nil,
    displayTitleToolTip: String? = nil,
    onClose: (() -> Void)?,
    action: @escaping () -> Void,
    onDragEnd: @escaping (NSPoint) -> Void
  ) {
    self.tab = tab
    self.displayTitleProvider = displayTitleProvider ?? { tab.displayTitle }
    self.displayTitleToolTip = displayTitleToolTip
    self.selected = selected
    self.horizontal = horizontal
    self.showsExitStatus = showsExitStatus
    self.showsFinished = showsFinished
    self.showsFailure = showsFailure
    self.showsAwaitingInput = showsAwaitingInput
    self.tabIcon = tabIcon
    self.badgePlacement = badgePlacement
    let resolvedStyle = horizontal ? (theme.style.horizontalTab ?? theme.style.tab) : theme.style.tab
    style = resolvedStyle
    sidebarRowInsets = theme.style.resolvedSidebarPadding
    resolvedForeground = NSColor(
      resolvedStyle.foreground
        ?? theme.resolvedColor(forSlot: "tab.foreground") ?? theme.palette.secondaryForeground
    )
    resolvedActiveForeground = NSColor(
      resolvedStyle.activeForeground
        ?? theme.resolvedColor(forSlot: "tab.activeForeground") ?? theme.palette.foreground
    )
    resolvedHoverBackground = NSColor(
      resolvedStyle.hoverBackground
        ?? theme.resolvedColor(forSlot: "tab.hoverBackground") ?? theme.palette.panelBackground
    )
    resolvedActiveBackground = NSColor(
      resolvedStyle.activeBackground
        ?? theme.resolvedColor(forSlot: "tab.activeBackground") ?? theme.palette.panelBackground
    )
    resolvedActiveBorder = NSColor(
      resolvedStyle.activeBorderColor
        ?? theme.resolvedColor(forSlot: "tab.activeBorderColor") ?? theme.palette.panelBackground
    )
    handler = action
    self.onDragEnd = onDragEnd
    super.init(frame: .zero)
    title = ""
    alignment = .left
    isBordered = false
    bezelStyle = .inline
    wantsLayer = true
    layer?.cornerCurve = .continuous
    target = self
    self.action = #selector(invoke)
    identifier = NSUserInterfaceItemIdentifier("workspace-tab-row-\(tab.id.uuidString)")
    translatesAutoresizingMaskIntoConstraints = false
    // 纵向行总高 = 胶囊高（Otty `[tab].height`，原生默认 36pt）+ 上下各 1pt 行距。
    heightAnchor.constraint(
      equalToConstant: horizontal ? (rowHeight ?? 36) : ((style.height ?? 36) + 2)
    ).isActive = true

    // 纵横两个方向共用「整行命中 + 内缩圆角底」结构：纵向是左右内缩的行卡，
    // 横向是上下内缩的胶囊。底必须先入栈，才能垫在标题与右侧附件下面。
    let rowBackground = NSView()
    rowBackground.identifier = NSUserInterfaceItemIdentifier(
      "workspace-tab-background-\(tab.id.uuidString)")
    rowBackground.wantsLayer = true
    rowBackground.layer?.cornerCurve = .continuous
    rowBackground.translatesAutoresizingMaskIntoConstraints = false
    addSubview(rowBackground)
    if horizontal {
      // 横向胶囊高度 = Otty `[tab-bar.tab].height`（原生默认 28），在标签条内垂直居中，
      // 不再用固定上下内缩推算——主题自定义条高时胶囊高度不该跟着变。
      NSLayoutConstraint.activate([
        rowBackground.leadingAnchor.constraint(equalTo: leadingAnchor),
        rowBackground.trailingAnchor.constraint(equalTo: trailingAnchor),
        rowBackground.centerYAnchor.constraint(equalTo: centerYAnchor),
        rowBackground.heightAnchor.constraint(equalToConstant: style.height ?? 28),
      ])
    } else {
      NSLayoutConstraint.activate([
        rowBackground.leadingAnchor.constraint(
          equalTo: leadingAnchor, constant: CGFloat(sidebarRowInsets.leading)),
        rowBackground.trailingAnchor.constraint(
          equalTo: trailingAnchor, constant: -CGFloat(sidebarRowInsets.trailing)),
        rowBackground.topAnchor.constraint(equalTo: topAnchor, constant: 1),
        rowBackground.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
      ])
    }
    self.rowBackground = rowBackground

    // 选中与未选中显示同一份展示名（Agent 会话标题优先，其次目录稳定显示名），
    // 切换标签时行文案不再在「完整路径 / 短名」之间跳变。
    // 纵向标签字号对齐 Otty `[tab].font-size` 原生默认 13；选中字重跟随主题
    // `tab.active.font-weight`，不再固定 semibold。
    let primary = makeLabel(
      self.displayTitleProvider(),
      size: horizontal ? 12 : 13,
      weight: selected ? NSFont.Weight(cssWeight: style.activeFontWeight) : .regular,
      color: selected ? resolvedActiveForeground : resolvedForeground
    )
    addSubview(primary)
    primary.translatesAutoresizingMaskIntoConstraints = false
    titleLabel = primary
    primary.toolTip = displayTitleToolTip

    // 横向胶囊的「分开」摆放：图标固定在标题左侧，状态角标仍走右侧槽位。
    // 纵向行不走这里——图标与状态统一进标题左侧的 statusSlot。
    var leadingIcon: NSView?
    if horizontal, badgePlacement == .separate, let tabIcon,
      let iconView = TabIconArtwork.makeView(for: tabIcon, fallbackTint: selected ? resolvedActiveForeground : resolvedForeground)
    {
      iconView.translatesAutoresizingMaskIntoConstraints = false
      iconView.identifier = NSUserInterfaceItemIdentifier("sidebar-tab-icon-\(tab.id.uuidString)")
      addSubview(iconView)
      leadingIcon = iconView
    }

    // 状态附件与关闭按钮共用固定槽位（纵向 28pt / 横向胶囊内 16pt），悬停切换时
    // 标题不会水平抖动。关闭动作直接针对该 tab，不先选中后台标签。
    let accessorySlot = NSView()
    accessorySlot.translatesAutoresizingMaskIntoConstraints = false
    addSubview(accessorySlot)
    self.accessorySlot = accessorySlot
    let close: NSButton
    if horizontal {
      // 胶囊内的小号关闭按钮：IconHoverButton 自带悬停底色反馈。
      let hoverClose = IconHoverButton(symbol: "xmark", accessibilityDescription: "关闭标签页") {
        onClose?()
      }
      hoverClose.image = NSImage(systemSymbolName: "xmark", accessibilityDescription: "关闭标签页")?
        .withSymbolConfiguration(.init(pointSize: 8, weight: .bold))
      hoverClose.restingTint = selected ? resolvedActiveForeground : resolvedForeground
      close = hoverClose
    } else {
      close = ActionButton(symbol: "xmark", bezelStyle: .inline) {
        onClose?()
      }
      close.isBordered = false
      close.contentTintColor = selected ? resolvedActiveForeground : resolvedForeground
    }
    close.identifier = NSUserInterfaceItemIdentifier("sidebar-tab-close-\(tab.id.uuidString)")
    close.toolTip = "关闭标签页"
    close.setAccessibilityLabel("关闭标签页 \(self.displayTitleProvider())")
    close.translatesAutoresizingMaskIntoConstraints = false
    accessorySlot.addSubview(close)
    closeButton = close
    if horizontal {
      // 槽位宽度是状态量（0 或 16），由 updateAccessoryVisibility 统一维护。
      let slotWidth = accessorySlot.widthAnchor.constraint(equalToConstant: 16)
      slotWidthConstraint = slotWidth
      NSLayoutConstraint.activate([
        // 标题按「等式」参与宽度求解：胶囊宽度 = 10 + 标题 + 4 + 槽 + 6，
        // 上限 190pt 之后按尾部截断，长标题不会把标签栏挤爆。
        primary.centerYAnchor.constraint(equalTo: centerYAnchor),
        primary.trailingAnchor.constraint(equalTo: accessorySlot.leadingAnchor, constant: -4),
        primary.widthAnchor.constraint(lessThanOrEqualToConstant: 190),
        accessorySlot.trailingAnchor.constraint(
          equalTo: rowBackground.trailingAnchor, constant: -6),
        accessorySlot.centerYAnchor.constraint(equalTo: centerYAnchor),
        slotWidth,
        accessorySlot.heightAnchor.constraint(equalToConstant: 16),
        close.centerXAnchor.constraint(equalTo: accessorySlot.centerXAnchor),
        close.centerYAnchor.constraint(equalTo: accessorySlot.centerYAnchor),
        close.widthAnchor.constraint(equalToConstant: 16),
        close.heightAnchor.constraint(equalToConstant: 16),
      ])
      activateLeadingConstraints(primary: primary, icon: leadingIcon, background: rowBackground, inset: 10)
    } else {
      // 纵向行结构对齐 Otty：[状态/图标槽] 标题 …… [shell 名 | 悬停关闭]。
      // 状态槽在标题左侧，宽度是状态量（0 或 16），由 refreshActivityBadge 维护。
      let statusSlot = NSView()
      statusSlot.identifier = NSUserInterfaceItemIdentifier("sidebar-tab-status-slot-\(tab.id.uuidString)")
      statusSlot.translatesAutoresizingMaskIntoConstraints = false
      addSubview(statusSlot)
      self.statusSlot = statusSlot
      let statusWidth = statusSlot.widthAnchor.constraint(equalToConstant: 16)
      statusSlotWidthConstraint = statusWidth
      let titleGap = primary.leadingAnchor.constraint(equalTo: statusSlot.trailingAnchor, constant: 6)
      titleLeadingGapConstraint = titleGap
      // 右侧 shell 名标签：Otty 每一行都显示（不只选中行）；多 Pane 时改显示数量。
      let trailing = makeLabel("", size: 10, color: AsterTheme.tertiaryInk, monospaced: true)
      trailing.identifier = NSUserInterfaceItemIdentifier("sidebar-tab-shell-\(tab.id.uuidString)")
      trailing.translatesAutoresizingMaskIntoConstraints = false
      trailing.setContentCompressionResistancePriority(.required, for: .horizontal)
      accessorySlot.addSubview(trailing)
      trailingLabel = trailing
      NSLayoutConstraint.activate([
        statusSlot.leadingAnchor.constraint(equalTo: rowBackground.leadingAnchor, constant: 10),
        statusSlot.centerYAnchor.constraint(equalTo: centerYAnchor),
        statusSlot.heightAnchor.constraint(equalToConstant: 16),
        statusWidth,
        // 槽宽为 0 时标题贴 10pt 内边距；有图标时图标与标题之间留 6pt。
        titleGap,
        primary.centerYAnchor.constraint(equalTo: centerYAnchor),
        primary.trailingAnchor.constraint(
          lessThanOrEqualTo: accessorySlot.leadingAnchor, constant: -8),
        accessorySlot.trailingAnchor.constraint(
          equalTo: rowBackground.trailingAnchor, constant: -4),
        accessorySlot.centerYAnchor.constraint(equalTo: centerYAnchor),
        // 槽位至少 28pt（放得下关闭按钮），shell 名更宽时按内容撑开。
        accessorySlot.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
        accessorySlot.heightAnchor.constraint(equalToConstant: 28),
        trailing.leadingAnchor.constraint(greaterThanOrEqualTo: accessorySlot.leadingAnchor, constant: 2),
        trailing.trailingAnchor.constraint(equalTo: accessorySlot.trailingAnchor, constant: -6),
        trailing.centerYAnchor.constraint(equalTo: accessorySlot.centerYAnchor),
        close.centerXAnchor.constraint(equalTo: accessorySlot.centerXAnchor),
        close.centerYAnchor.constraint(equalTo: accessorySlot.centerYAnchor),
        close.widthAnchor.constraint(equalToConstant: 24),
        close.heightAnchor.constraint(equalToConstant: 24),
      ])
      refreshTrailingLabel()
    }
    refreshActivityBadge()
    updateAccessoryVisibility()
    updateStyle()
  }

  /// 标题的左缘：有前置图标时排在图标之后，否则直接贴卡片内边距。
  private func activateLeadingConstraints(primary: NSView, icon: NSView?, background: NSView, inset: CGFloat) {
    if let icon {
      NSLayoutConstraint.activate([
        icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: inset),
        icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        primary.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
      ])
    } else {
      primary.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: inset).isActive = true
    }
  }

  /// 在 mouseDown 立即派发选择，不依赖 mouseUp 的 target/action：终端输出会触发
  /// 侧栏整树重建，若等到 mouseUp，按钮可能已在按下与抬起之间被销毁，点击就会丢失。
  override func mouseDown(with event: NSEvent) {
    handler()
    guard let window else { return }
    let origin = event.locationInWindow
    var draggedPoint: NSPoint?
    window.trackEvents(
      matching: [.leftMouseDragged, .leftMouseUp],
      timeout: .greatestFiniteMagnitude,
      mode: .eventTracking
    ) { tracked, stop in
      guard let tracked else {
        stop.pointee = true
        return
      }
      if tracked.type == .leftMouseDragged {
        let delta = hypot(
          tracked.locationInWindow.x - origin.x,
          tracked.locationInWindow.y - origin.y
        )
        if delta >= 5 { draggedPoint = window.convertPoint(toScreen: tracked.locationInWindow) }
      } else if tracked.type == .leftMouseUp {
        if draggedPoint != nil {
          draggedPoint = window.convertPoint(toScreen: tracked.locationInWindow)
        }
        stop.pointee = true
      }
    }
    if let draggedPoint { onDragEnd(draggedPoint) }
  }

  required init?(coder: NSCoder) { nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(
      rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }

  /// 程序标题（OSC 0/1/2）变化时就地更新行文案；不重建行、不触碰附件与终端视图。
  func refreshTitle() {
    let value = displayTitleProvider()
    titleLabel?.stringValue = value
    titleLabel?.toolTip = displayTitleToolTip
    closeButton?.setAccessibilityLabel("关闭标签页 \(value)")
  }

  /// 只替换标签的状态附件，不重建 Sidebar、Pane 或长期存活的终端视图。Agent hook
  /// 在 processing/awaiting/idle 之间切换时调用本方法，状态图标因此能即时变化，同时
  /// 不打断 TUI 输入、选择或 Files 当前目录。状态键相同则完全跳过重建：running
  /// spinner 若被销毁重建会不断重启动画，视觉上表现为“转得飞快”。
  func refreshActivityBadge() {
    refreshTrailingLabel()
    let key = activityBadgeKey()
    // 纵向行的状态附件挂在标题左侧的 statusSlot；横向胶囊仍挂在右侧 accessorySlot。
    guard let slot = horizontal ? accessorySlot : statusSlot else { return }
    if key == renderedBadgeKey, accessoryView != nil || key == "idle" {
      updateAccessoryVisibility()
      return
    }
    renderedBadgeKey = key
    accessoryView?.removeFromSuperview()
    accessoryView = nil
    if let accessory = makeActivityAccessory() {
      accessory.translatesAutoresizingMaskIntoConstraints = false
      slot.addSubview(accessory)
      NSLayoutConstraint.activate([
        accessory.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
        accessory.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
      ])
      accessoryView = accessory
    }
    // 纵向行没有任何图标可显示时状态槽收紧为 0，标题直接贴卡片内边距。
    statusSlotWidthConstraint?.constant = accessoryView == nil ? 0 : 16
    titleLeadingGapConstraint?.constant = accessoryView == nil ? 0 : 6
    updateAccessoryVisibility()
  }

  /// 右侧标签文案：默认是当前标签的 shell 名；标签内有多个 Pane 时改为显示 Pane 数量。
  private func refreshTrailingLabel() {
    guard let trailingLabel else { return }
    let paneCount = tab.runtimes.count
    if paneCount > 1 {
      trailingLabel.stringValue = "\(paneCount)"
      trailingLabel.toolTip = "此标签页有 \(paneCount) 个 Pane"
    } else {
      trailingLabel.stringValue = URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
      ).lastPathComponent
      trailingLabel.toolTip = nil
    }
  }

  /// 对齐 Otty：纵向行有 Agent / 规则图标时，回合结束一律回到静态图标，
  /// 不显示「已完成 ● / ✓」实心圆；运行中仍由动画接管。
  private var suppressesReadBadge: Bool {
    !horizontal && idleTabIcon != nil
  }

  /// 行图标 / 动画所用的 provider：跟随当前活动 Pane；活动 Pane 不是 Agent（普通 shell、
  /// 编辑器）时才回落到标签里任意一个 Agent 会话，保证「标签里有 Agent」仍然可见。
  private var preferredAgentProvider: AgentProvider? {
    tab.activeSession?.activeAgentProvider
      ?? tab.runtimes.values.compactMap({ $0.terminalSession?.activeAgentProvider }).first
  }

  /// 运行动画样式（对齐 Otty）：Claude Code 半圆 ◑ 旋转；Codex 2×2 点阵循环；
  /// 其它 Agent / 普通命令暂时沿用半圆旋转。
  private var runningAnimationStyle: TabActivitySpinnerView.Style {
    preferredAgentProvider == .codex ? .dots : .spin
  }

  /// 纵向行静态图标：规则图标优先，其次是当前活动 Pane 正在运行的 Agent 图标。
  private var idleTabIcon: TabRuleIcon? {
    if let tabIcon { return tabIcon }
    guard let provider = preferredAgentProvider else { return nil }
    return TabRuleIcon(name: Self.agentIconName(provider))
  }

  /// Agent provider → 图标集（`settings-ui/tab-icons`）里的图标名；图标集没有专属图的
  /// provider 统一落到 `terminal-ai`。
  static func agentIconName(_ provider: AgentProvider) -> String {
    switch provider {
    case .claudeCode: "claude"
    case .codex: "openai"
    case .grokBuild: "grok"
    case .gemini: "gemini"
    case .githubCopilot: "copilot"
    case .openCode, .cursorCLI, .kimiCode, .pi, .omp,
      .amp, .droid, .devin, .kiro, .qoder, .qwen, .hermes,
      .antigravity, .maki, .muse, .cline, .kilo:
      "terminal-ai"
    }
  }

  /// 徽章渲染结果的等价键。与 `makeActivityAccessory` 的分支一一对应；spinner
  /// 不显示百分比，因此 `.running` 的 percent 变化不进入键值，避免进度刷新重启动画。
  private func activityBadgeKey() -> String {
    switch tab.activityBadge {
    case .running:
      return runningAnimationStyle == .dots ? "running-dots" : "running-spin"
    case .awaitingInput where showsAwaitingInput:
      return "awaiting-input"
    case .error where showsFailure && showsExitStatus:
      return "error-\(tab.lastCommandExitStatus.map(String.init) ?? "!")"
    case .finished where showsFinished && showsExitStatus && !suppressesReadBadge:
      return "finished"
    case .completed where showsFinished && showsExitStatus && !suppressesReadBadge:
      return "completed"
    default:
      if !horizontal {
        // 纵向行 idle 键要带上图标来源：Agent 启动/退出时图标随之切换。
        if let icon = idleTabIcon { return "idle-icon-\(icon.emoji ?? icon.name ?? "")" }
        if tab.activeSession?.sshRemoteEndpoint != nil { return "ssh-remote" }
        return "idle"
      }
      return badgePlacement == .combined && tabIcon != nil ? "idle-icon" : "idle"
    }
  }

  /// 构建当前活动状态的附件视图；纵横两种方向共用状态分支，只有 idle 内容不同。
  /// 返回 nil 表示当前没有任何东西可显示（纵向行无图标、无状态）。
  private func makeActivityAccessory() -> NSView? {
    let accessory: NSView
    let stateName: String
    let accessibilityLabel: String
    switch tab.activityBadge {
    case .running:
      // 运行动画对齐 Otty，按 Agent 区分（见 runningAnimationStyle）。不再用系统 spinner。
      let tint = selected ? resolvedActiveForeground : resolvedForeground
      accessory = TabActivitySpinnerView(tint: tint, style: runningAnimationStyle)
      stateName = "running"
      accessibilityLabel = "正在运行"
    case .awaitingInput where showsAwaitingInput:
      accessory = makeLabel("✋", size: 11, weight: .semibold, color: AsterTheme.warning)
      stateName = "awaiting-input"
      accessibilityLabel = "等待输入"
    case .error where showsFailure && showsExitStatus:
      accessory = makeLabel(
        tab.lastCommandExitStatus.map(String.init) ?? "!",
        size: 10, weight: .semibold, color: AsterTheme.warning, monospaced: true
      )
      stateName = "error"
      accessibilityLabel = "执行失败"
    case .finished where showsFinished && showsExitStatus && !suppressesReadBadge:
      accessory = makeLabel("●", size: 9, weight: .semibold, color: AsterTheme.accent)
      stateName = "finished"
      accessibilityLabel = "已完成"
    case .completed where showsFinished && showsExitStatus && !suppressesReadBadge:
      accessory = makeLabel("✓", size: 11, weight: .semibold, color: AsterTheme.accent)
      stateName = "completed"
      accessibilityLabel = "刚刚完成"
    default:
      if !horizontal, let icon = idleTabIcon,
        let iconView = TabIconArtwork.makeView(for: icon, fallbackTint: selected ? resolvedActiveForeground : resolvedForeground)
      {
        // 纵向行静态图标：规则图标或 Agent 图标，有状态发生时上面的分支会接管。
        accessory = iconView
        stateName = "icon"
        accessibilityLabel = icon.name.map { "标签图标 \($0)" } ?? "空闲"
      } else if !horizontal, tab.activeSession?.sshRemoteEndpoint != nil {
        let icon = NSImageView()
        icon.image = NSImage(
          systemSymbolName: "desktopcomputer", accessibilityDescription: "SSH 远端")?
          .withSymbolConfiguration(.init(pointSize: 10, weight: .medium))
        icon.contentTintColor = AsterTheme.tertiaryInk
        accessory = icon
        stateName = "ssh-remote"
        accessibilityLabel = "SSH 远端"
      } else if badgePlacement == .combined, let tabIcon,
        let iconView = TabIconArtwork.makeView(for: tabIcon, fallbackTint: selected ? resolvedActiveForeground : resolvedForeground)
      {
        // 「合并」摆放：平时状态槽显示用户图标，有状态发生时上面的分支会接管。
        accessory = iconView
        stateName = "icon"
        accessibilityLabel = "空闲"
      } else if horizontal {
        // 横向胶囊里放不下 shell 名，idle 只留空槽占位。
        accessory = makeLabel("", size: 10, color: AsterTheme.tertiaryInk, monospaced: true)
        stateName = "idle"
        accessibilityLabel = "空闲"
      } else {
        // 纵向行无图标无状态：状态槽整体收起，shell 名由右侧 trailingLabel 常驻显示。
        return nil
      }
    }
    accessory.identifier = NSUserInterfaceItemIdentifier(
      "sidebar-tab-status-\(tab.id.uuidString)-\(stateName)")
    accessory.setAccessibilityLabel(accessibilityLabel)
    return accessory
  }

  /// 横向选中胶囊常显关闭按钮、未选中保持纯文字（对齐 Otty 顶/底部标签栏）；
  /// 纵向沿用「悬停时徽章让位给关闭按钮」的切换。
  private func updateAccessoryVisibility() {
    if horizontal {
      closeButton?.isHidden = !selected
      accessoryView?.isHidden = selected
      // 关闭按钮或徽章至少有一个可见时槽位才占 16pt；纯文字标签收紧为 0，
      // 悬停不改变宽度，标签排布不会抖动。
      slotWidthConstraint?.constant = (selected || activityBadgeKey() != "idle") ? 16 : 0
    } else {
      // 纵向行：左侧状态图标常驻；右侧 shell 名在悬停时让位给关闭按钮。
      trailingLabel?.isHidden = hovered
      closeButton?.isHidden = !hovered
    }
  }

  /// 依据选中/悬停状态刷新内缩底卡（纵向行卡与横向胶囊共用）的配色与装饰。
  private func updateStyle() {
    // 前景与字重由 titleLabel 承载；contentTintColor 仍保留为主题矩阵测试的取值口。
    contentTintColor = selected ? resolvedActiveForeground : resolvedForeground
    // 装饰一律画在内缩底层上；行本体保持透明，否则内缩底外面会再糊一层直角色块。
    let decoration = rowBackground?.layer
    layer?.backgroundColor = NSColor.clear.cgColor
    layer?.borderWidth = 0
    layer?.shadowOpacity = 0
    // 圆角忠实取主题 `[tab].radius`（原生默认 8）：April 声明 0 + padding 0 时
    // 就是 Otty 的整行铺满直角样式，不再强加圆角下限。
    decoration?.cornerRadius = style.radius
    let background: NSColor
    if selected {
      background = resolvedActiveBackground
    } else if hovered {
      // 主题没给悬停色时也必须有反馈，否则鼠标扫过侧栏毫无变化。
      background = resolvedHoverBackground
    } else {
      background = .clear
    }
    decoration?.backgroundColor = background.cgColor
    decoration?.borderWidth = selected ? style.activeBorderWidth : 0
    decoration?.borderColor = resolvedActiveBorder.cgColor
    if selected, let shadow = style.activeShadow {
      decoration?.shadowColor = NSColor(shadow.color).cgColor
      decoration?.shadowOpacity = 1
      decoration?.shadowRadius = shadow.blur
      decoration?.shadowOffset = NSSize(width: shadow.x, height: -shadow.y)
    } else {
      decoration?.shadowOpacity = 0
    }
  }

  @objc private func invoke() { handler() }
}

/// 标签行的运行动画（对齐 Otty），图形画在独立 sublayer 上并只动 sublayer：直接动
/// 视图自己的 layer 时 AppKit 会改写 anchorPoint/position，图标会绕着行内打转。
@MainActor
final class TabActivitySpinnerView: NSView {
  /// `.spin`：半实心圆 ◑ 绕竖轴左右翻转（Claude Code / 默认）；`.dots`：2×2 点阵，
  /// 三亮一暗，暗点顺时针轮转（Codex）。
  enum Style: Equatable {
    case spin
    case dots
  }

  private let style: Style
  private let tint: NSColor
  private var glyphs: [CALayer] = []
  /// `.spin` 样式里真正翻转的半圆层；圆环留在 glyphs[0] 上不动。
  private weak var flipTarget: CALayer?

  init(tint: NSColor, style: Style = .spin) {
    self.style = style
    self.tint = tint
    super.init(frame: NSRect(x: 0, y: 0, width: 14, height: 14))
    // 显式 layer-hosting：先给 layer 再置 wantsLayer，保证下面 addSublayer 时
    // layer 一定存在（layer-backed 模式下 layer 可能延迟到入窗才创建，sublayer 会丢）。
    layer = CALayer()
    wantsLayer = true
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 14),
      heightAnchor.constraint(equalToConstant: 14),
    ])
    switch style {
    case .spin: buildSpinGlyph()
    case .dots: buildDotGlyphs()
    }
  }

  required init?(coder: NSCoder) { nil }

  /// 圆环（只描边）+ 左半实心（只填充）分两个路径画在同一个 layer 上：
  /// 之前把整圆也交给 fillColor，结果是一个实心圆盘，转起来看不出动。
  private func buildSpinGlyph() {
    let glyph = CAShapeLayer()
    let ring = CAShapeLayer()
    ring.path = CGPath(ellipseIn: CGRect(x: 2, y: 2, width: 10, height: 10), transform: nil)
    ring.fillColor = nil
    ring.strokeColor = tint.cgColor
    ring.lineWidth = 1.2
    let half = CAShapeLayer()
    let path = CGMutablePath()
    path.move(to: CGPoint(x: 7, y: 7))
    path.addArc(center: CGPoint(x: 7, y: 7), radius: 5, startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
    path.closeSubpath()
    half.path = path
    half.fillColor = tint.cgColor
    half.strokeColor = nil
    // 半圆自己的 bounds/anchor 以圆心为轴，翻转时圆环保持不动。
    half.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
    half.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    half.position = CGPoint(x: 7, y: 7)
    glyph.addSublayer(ring)
    glyph.addSublayer(half)
    glyph.bounds = CGRect(x: 0, y: 0, width: 14, height: 14)
    glyph.anchorPoint = CGPoint(x: 0.5, y: 0.5)
    glyph.position = CGPoint(x: 7, y: 7)
    layer?.addSublayer(glyph)
    glyphs = [glyph]
    flipTarget = half
  }

  /// 四个 2.4pt 圆点，按 左上 → 右上 → 右下 → 左下 顺时针排列，便于轮转暗点。
  private func buildDotGlyphs() {
    let centers = [CGPoint(x: 4.5, y: 9.5), CGPoint(x: 9.5, y: 9.5), CGPoint(x: 9.5, y: 4.5), CGPoint(x: 4.5, y: 4.5)]
    glyphs = centers.map { center in
      let dot = CAShapeLayer()
      dot.path = CGPath(ellipseIn: CGRect(x: -1.2, y: -1.2, width: 2.4, height: 2.4), transform: nil)
      dot.fillColor = tint.cgColor
      dot.position = center
      layer?.addSublayer(dot)
      return dot
    }
  }

  /// 进入窗口时启动动画；离开窗口时 CoreAnimation 会丢弃动画，回来必须重新加。
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    let scale = window?.backingScaleFactor ?? 2
    glyphs.forEach { glyph in
      glyph.contentsScale = scale
      glyph.sublayers?.forEach { $0.contentsScale = scale }
    }
    switch style {
    case .spin:
      // 对齐 Otty：圆环不动，只有半圆绕竖轴翻转（左半实 → 右半实 → 回来）。
      let spin = CABasicAnimation(keyPath: "transform.rotation.y")
      spin.fromValue = 0
      spin.toValue = 2 * Double.pi
      spin.duration = 1.6
      spin.repeatCount = .infinity
      spin.isRemovedOnCompletion = false
      flipTarget?.add(spin, forKey: "aster-spin")
    case .dots:
      // 每个点在自己的时间片变暗，四个点错开 1/4 周期，效果是暗点顺时针跑。
      for (index, dot) in glyphs.enumerated() {
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [1, 0.15, 1, 1, 1]
        fade.keyTimes = [0, 0.001, 0.25, 0.5, 1]
        fade.calculationMode = .discrete
        fade.duration = 0.8
        fade.timeOffset = Double(index) * 0.2
        fade.repeatCount = .infinity
        fade.isRemovedOnCompletion = false
        dot.add(fade, forKey: "aster-dots")
      }
    }
  }

  /// sublayer 始终钉在视图中心（点阵按各自偏移），视图 frame 变化不影响动画中心。
  override func layout() {
    super.layout()
    guard style == .spin else { return }
    glyphs.first?.position = CGPoint(x: bounds.midX, y: bounds.midY)
  }
}

/// 递归分屏使用 `NSSplitView`，拖动结束后的比例写回领域模型以供会话恢复。
///
/// 分隔条默认是一条 1pt 灰线；指针进入命中区后加粗为主题强调色，双击恢复等分。
