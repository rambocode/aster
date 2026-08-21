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
  private let sidebarRowInset: CGFloat
  private let tab: TerminalTabItem
  private let selected: Bool
  private let horizontal: Bool
  private let showsExitStatus: Bool
  private let showsFinished: Bool
  private let showsFailure: Bool
  private let showsAwaitingInput: Bool
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
    onClose: (() -> Void)?,
    action: @escaping () -> Void,
    onDragEnd: @escaping (NSPoint) -> Void
  ) {
    self.tab = tab
    self.selected = selected
    self.horizontal = horizontal
    self.showsExitStatus = showsExitStatus
    self.showsFinished = showsFinished
    self.showsFailure = showsFailure
    self.showsAwaitingInput = showsAwaitingInput
    let resolvedStyle = horizontal ? (theme.style.horizontalTab ?? theme.style.tab) : theme.style.tab
    style = resolvedStyle
    sidebarRowInset = CGFloat(theme.style.sidebarPadding ?? 8)
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
          equalTo: leadingAnchor, constant: sidebarRowInset),
        rowBackground.trailingAnchor.constraint(
          equalTo: trailingAnchor, constant: -sidebarRowInset),
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
      tab.displayTitle,
      size: horizontal ? 12 : 13,
      weight: selected ? NSFont.Weight(cssWeight: style.activeFontWeight) : .regular,
      color: selected ? resolvedActiveForeground : resolvedForeground
    )
    addSubview(primary)
    primary.translatesAutoresizingMaskIntoConstraints = false
    titleLabel = primary

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
      close.contentTintColor = AsterTheme.secondaryInk
    }
    close.identifier = NSUserInterfaceItemIdentifier("sidebar-tab-close-\(tab.id.uuidString)")
    close.toolTip = "关闭标签页"
    close.setAccessibilityLabel("关闭标签页 \(tab.displayTitle)")
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
        primary.leadingAnchor.constraint(equalTo: rowBackground.leadingAnchor, constant: 10),
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
    } else {
      NSLayoutConstraint.activate([
        // 文案与右侧槽位都按圆角底的内缘对齐，卡片左右各留出 10pt 内边距。
        primary.leadingAnchor.constraint(equalTo: rowBackground.leadingAnchor, constant: 10),
        primary.centerYAnchor.constraint(equalTo: centerYAnchor),
        primary.trailingAnchor.constraint(
          lessThanOrEqualTo: accessorySlot.leadingAnchor, constant: -8),
        accessorySlot.trailingAnchor.constraint(
          equalTo: rowBackground.trailingAnchor, constant: -4),
        accessorySlot.centerYAnchor.constraint(equalTo: centerYAnchor),
        accessorySlot.widthAnchor.constraint(equalToConstant: 28),
        accessorySlot.heightAnchor.constraint(equalToConstant: 28),
        close.centerXAnchor.constraint(equalTo: accessorySlot.centerXAnchor),
        close.centerYAnchor.constraint(equalTo: accessorySlot.centerYAnchor),
        close.widthAnchor.constraint(equalToConstant: 24),
        close.heightAnchor.constraint(equalToConstant: 24),
      ])
    }
    refreshActivityBadge()
    updateAccessoryVisibility()
    updateStyle()
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
    titleLabel?.stringValue = tab.displayTitle
    closeButton?.setAccessibilityLabel("关闭标签页 \(tab.displayTitle)")
  }

  /// 只替换标签的状态附件，不重建 Sidebar、Pane 或长期存活的终端视图。Agent hook
  /// 在 processing/awaiting/idle 之间切换时调用本方法，状态图标因此能即时变化，同时
  /// 不打断 TUI 输入、选择或 Files 当前目录。状态键相同则完全跳过重建：running
  /// spinner 若被销毁重建会不断重启动画，视觉上表现为“转得飞快”。
  func refreshActivityBadge() {
    let key = activityBadgeKey()
    guard let slot = accessorySlot else { return }
    if key == renderedBadgeKey, accessoryView != nil {
      updateAccessoryVisibility()
      return
    }
    renderedBadgeKey = key
    accessoryView?.removeFromSuperview()
    let accessory = makeActivityAccessory()
    accessory.translatesAutoresizingMaskIntoConstraints = false
    slot.addSubview(accessory)
    NSLayoutConstraint.activate([
      accessory.centerXAnchor.constraint(equalTo: slot.centerXAnchor),
      accessory.centerYAnchor.constraint(equalTo: slot.centerYAnchor),
    ])
    accessoryView = accessory
    updateAccessoryVisibility()
  }

  /// 徽章渲染结果的等价键。与 `makeActivityAccessory` 的分支一一对应；spinner
  /// 不显示百分比，因此 `.running` 的 percent 变化不进入键值，避免进度刷新重启动画。
  private func activityBadgeKey() -> String {
    switch tab.activityBadge {
    case .running:
      return "running"
    case .awaitingInput where showsAwaitingInput:
      return "awaiting-input"
    case .error where showsFailure && showsExitStatus:
      return "error-\(tab.lastCommandExitStatus.map(String.init) ?? "!")"
    case .finished where showsFinished && showsExitStatus:
      return "finished"
    case .completed where showsFinished && showsExitStatus:
      return "completed"
    default:
      return "idle"
    }
  }

  /// 构建当前活动状态的附件视图；纵横两种方向共用状态分支，只有 idle 内容不同。
  private func makeActivityAccessory() -> NSView {
    let accessory: NSView
    let stateName: String
    let accessibilityLabel: String
    switch tab.activityBadge {
    case .running:
      let spinner = NSProgressIndicator()
      spinner.style = .spinning
      spinner.controlSize = .small
      spinner.isIndeterminate = true
      spinner.isDisplayedWhenStopped = false
      spinner.startAnimation(nil)
      accessory = spinner
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
    case .finished where showsFinished && showsExitStatus:
      accessory = makeLabel("●", size: 9, weight: .semibold, color: AsterTheme.accent)
      stateName = "finished"
      accessibilityLabel = "已完成"
    case .completed where showsFinished && showsExitStatus:
      accessory = makeLabel("✓", size: 11, weight: .semibold, color: AsterTheme.accent)
      stateName = "completed"
      accessibilityLabel = "刚刚完成"
    default:
      // 横向胶囊里放不下 shell 名，idle 只留空槽占位；纵向沿用选中行显示 shell 名。
      accessory = makeLabel(
        !horizontal && selected
          ? URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
            .lastPathComponent
          : "",
        size: 10, color: AsterTheme.tertiaryInk, monospaced: true
      )
      stateName = "idle"
      accessibilityLabel = "空闲"
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
      accessoryView?.isHidden = hovered
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

/// 递归分屏使用 `NSSplitView`，拖动结束后的比例写回领域模型以供会话恢复。
///
/// 分隔条默认是一条 1pt 灰线；指针进入命中区后加粗为主题强调色，双击恢复等分。
