// 侧栏「工作区」区块与横向标签条的工作区切换按钮：本机列出窗口内工作区，远端机器列出
// 这台机器的远端工作区，两者共用同一行视图、右键菜单与弹出菜单。
import AppKit
import AsterCore

/// 工作区区块里一行的数据。本机工作区与远端工作区共用，动作按 `target` 分派。
struct WorkspaceGroupSidebarItem: Equatable {
  enum Target: Equatable {
    case local(UUID)
    case remote(machineID: UUID, summary: RemoteWorkspaceSummary)
  }

  var target: Target
  var name: String
  var tabCount: Int
  var isSelected: Bool

  /// 行视图的稳定标识（测试与辅助功能用）：本机是分组 UUID，远端是服务端工作区 ID。
  var identifierSuffix: String {
    switch target {
    case .local(let id): id.uuidString
    case .remote(_, let summary): summary.workspaceID
    }
  }
}

/// 工作区行的配色，取自主题的标签行 token，保证与下方标签行同一套视觉语言。
struct WorkspaceGroupRowStyle {
  var foreground: NSColor
  var activeForeground: NSColor
  var hoverBackground: NSColor
  var activeBackground: NSColor
  var radius: CGFloat
  var insets: ThemeInsets
  var activeWeight: NSFont.Weight

  /// 按主题解析；回退链与 `TabRowButton` 一致。
  @MainActor
  init(theme: TerminalTheme) {
    let tab = theme.style.tab
    foreground = NSColor(
      ThemeRuntime.shared.legibleText(
        tab.foreground ?? theme.resolvedColor(forSlot: "tab.foreground") ?? theme.palette.secondaryForeground, in: theme))
    activeForeground = NSColor(
      tab.activeForeground ?? theme.resolvedColor(forSlot: "tab.activeForeground")
        ?? theme.palette.foreground)
    hoverBackground = NSColor(
      tab.hoverBackground ?? theme.resolvedColor(forSlot: "tab.hoverBackground")
        ?? theme.palette.panelBackground)
    activeBackground = NSColor(
      tab.activeBackground ?? theme.resolvedColor(forSlot: "tab.activeBackground")
        ?? theme.palette.panelBackground)
    radius = tab.radius
    insets = theme.style.resolvedSidebarPadding
    activeWeight = NSFont.Weight(cssWeight: tab.activeFontWeight)
  }
}

/// 侧栏里的一行工作区：图标 + 名称 + 标签数，整行命中。
///
/// 单击在 mouseDown 立即派发，原因与 `SidebarGroupHeaderView` 相同：切换工作区会触发
/// 侧栏整树重建，等到 mouseUp 时这一行可能已被移出视图树，点击就丢了。双击时第二次
/// 按下落在重建后的新行上，`clickCount` 由系统累计，仍能识别为双击。
@MainActor
final class WorkspaceGroupRowView: NSView {
  let item: WorkspaceGroupSidebarItem
  private let style: WorkspaceGroupRowStyle
  private let onSelect: () -> Void
  private let onDoubleClick: () -> Void
  private let menuProvider: () -> NSMenu
  private let background = NSView()
  private var tracking: NSTrackingArea?
  private var hovered = false {
    didSet { if hovered != oldValue { updateStyle() } }
  }

  /// 构建一行；`menuProvider` 每次右键时调用，菜单状态始终是最新的。
  init(
    item: WorkspaceGroupSidebarItem, style: WorkspaceGroupRowStyle,
    onSelect: @escaping () -> Void, onDoubleClick: @escaping () -> Void,
    menuProvider: @escaping () -> NSMenu
  ) {
    self.item = item
    self.style = style
    self.onSelect = onSelect
    self.onDoubleClick = onDoubleClick
    self.menuProvider = menuProvider
    super.init(frame: .zero)
    identifier = NSUserInterfaceItemIdentifier("workspace-group-row-\(item.identifierSuffix)")
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: InterfaceScale.length(30)).isActive = true
    setAccessibilityElement(true)
    setAccessibilityRole(.button)
    setAccessibilityLabel(L("工作区 \(item.name)"))
    setAccessibilityValue(item.isSelected ? L("当前工作区") : nil)

    background.wantsLayer = true
    background.layer?.cornerCurve = .continuous
    background.translatesAutoresizingMaskIntoConstraints = false
    addSubview(background)

    let tint = item.isSelected ? style.activeForeground : style.foreground
    let icon = NSImageView()
    icon.image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: InterfaceScale.font(11), weight: .medium))
    icon.contentTintColor = tint
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.setContentHuggingPriority(.required, for: .horizontal)
    addSubview(icon)

    let name = makeLabel(
      item.name, size: 12.5, weight: item.isSelected ? style.activeWeight : .regular, color: tint)
    name.identifier = NSUserInterfaceItemIdentifier("workspace-group-name-\(item.identifierSuffix)")
    name.translatesAutoresizingMaskIntoConstraints = false
    name.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    addSubview(name)

    let count = makeLabel(
      String(item.tabCount), size: 10, color: AsterTheme.tertiaryInk, monospaced: true)
    count.identifier = NSUserInterfaceItemIdentifier("workspace-group-count-\(item.identifierSuffix)")
    count.toolTip = L("\(String(item.tabCount)) 个标签")
    count.translatesAutoresizingMaskIntoConstraints = false
    count.setContentCompressionResistancePriority(.required, for: .horizontal)
    addSubview(count)

    NSLayoutConstraint.activate([
      // 底卡左右内缩与标签行一致（主题 `[sidebar].padding`），行本身仍整行命中。
      background.leadingAnchor.constraint(
        equalTo: leadingAnchor, constant: CGFloat(style.insets.leading)),
      background.trailingAnchor.constraint(
        equalTo: trailingAnchor, constant: -CGFloat(style.insets.trailing)),
      background.topAnchor.constraint(equalTo: topAnchor, constant: 1),
      background.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
      icon.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
      icon.centerYAnchor.constraint(equalTo: centerYAnchor),
      name.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
      name.centerYAnchor.constraint(equalTo: centerYAnchor),
      name.trailingAnchor.constraint(lessThanOrEqualTo: count.leadingAnchor, constant: -8),
      count.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
      count.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    updateStyle()
  }

  required init?(coder: NSCoder) { nil }

  /// 第一次按下即切换；同一位置的第二次按下（双击）改为重命名。
  override func mouseDown(with event: NSEvent) {
    if event.clickCount >= 2 { onDoubleClick() } else { onSelect() }
  }

  /// 右键菜单按需现建。
  override func menu(for event: NSEvent) -> NSMenu? { menuProvider() }

  /// 辅助功能「按下」等同于单击切换。
  override func accessibilityPerformPress() -> Bool {
    onSelect()
    return true
  }

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

  /// 选中用标签行的激活底色，悬停用悬停底色，其余透明。
  private func updateStyle() {
    let color: NSColor =
      item.isSelected ? style.activeBackground : (hovered ? style.hoverBackground : .clear)
    background.layer?.backgroundColor = color.cgColor
    background.layer?.cornerRadius = style.radius
  }
}

/// 顶部/底部横向标签条开头的工作区按钮：显示当前工作区名，点开是工作区菜单。
/// 同样在 mouseDown 弹出，避免标签条重建吞掉点击。
@MainActor
final class WorkspaceGroupPopUpButton: NSButton {
  private let menuProvider: () -> NSMenu

  /// `title` 是当前工作区名；`menuProvider` 每次点开时现建菜单。
  init(title: String, tint: NSColor, menuProvider: @escaping () -> NSMenu) {
    self.menuProvider = menuProvider
    super.init(frame: .zero)
    self.title = title
    font = NSFont.interface(ofSize: 12, weight: .medium)
    image = NSImage(systemSymbolName: "square.stack", accessibilityDescription: nil)?
      .withSymbolConfiguration(.init(pointSize: InterfaceScale.font(10), weight: .medium))
    imagePosition = .imageLeading
    imageHugsTitle = true
    contentTintColor = tint
    isBordered = false
    lineBreakMode = .byTruncatingTail
    wantsLayer = true
    layer?.cornerRadius = 6
    layer?.cornerCurve = .continuous
    identifier = NSUserInterfaceItemIdentifier("workspace-group-popup")
    toolTip = L("切换工作区")
    setAccessibilityLabel(L("工作区 \(title)"))
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      // 按钮落在横向标签行里，行高同样按界面字号放大，这里不必设上限。
      heightAnchor.constraint(equalToConstant: InterfaceScale.length(24)),
      widthAnchor.constraint(lessThanOrEqualToConstant: InterfaceScale.length(160)),
    ])
  }

  required init?(coder: NSCoder) { nil }

  /// 在按钮下沿弹出菜单；弹出期间给一层按下底色作为反馈。
  override func mouseDown(with event: NSEvent) {
    layer?.backgroundColor = AsterTheme.ink.withAlphaComponent(0.08).cgColor
    let origin = NSPoint(x: bounds.minX, y: isFlipped ? bounds.maxY + 4 : bounds.minY - 4)
    menuProvider().popUp(positioning: nil, at: origin, in: self)
    layer?.backgroundColor = NSColor.clear.cgColor
  }
}

// MARK: - 控制器接线

extension WorkspaceViewController {
  /// 工作区区块的行数据：本机取窗口内工作区；远端取这台机器缓存投影里的工作区
  /// （只读已建出的协调器，不为画侧栏发起网络请求）。
  func workspaceGroupSidebarItems() -> [WorkspaceGroupSidebarItem] {
    guard model.isLocalMachineActive else {
      let machineID = model.activeMachineID
      let summaries = loadedRemoteWorkspaces?.remoteWorkspaces(machineID: machineID) ?? []
      return summaries.map {
        WorkspaceGroupSidebarItem(
          target: .remote(machineID: machineID, summary: $0), name: $0.title,
          tabCount: $0.tabCount, isSelected: $0.isSelected)
      }
    }
    return model.workspaceGroups.map {
      WorkspaceGroupSidebarItem(
        target: .local($0.id), name: $0.name,
        tabCount: model.tabCount(inWorkspaceGroup: $0.id),
        isSelected: $0.id == model.selectedWorkspaceGroupID)
    }
  }

  /// 当前工作区名：本机是选中的窗口内工作区，远端是选中的远端工作区；都没有时为 nil。
  func currentWorkspaceGroupName() -> String? {
    guard model.isLocalMachineActive else {
      return loadedRemoteWorkspaces?.selectedWorkspaceTitle(machineID: model.activeMachineID)
    }
    return model.selectedWorkspaceGroup?.name
  }

  /// 标签区块的 eyebrow：写明这些标签属于哪个工作区。
  func sidebarTabsSectionTitle() -> String {
    guard let name = currentWorkspaceGroupName() else { return L("标签页") }
    return L("\(name) · 标签")
  }

  /// 侧栏工作区区块的行列表（不含标题行，标题行与交通灯共用侧栏 header）。
  func makeWorkspaceGroupRows(theme: TerminalTheme) -> NSView {
    let rows = NSStackView()
    rows.orientation = .vertical
    rows.alignment = .width
    rows.spacing = 0
    rows.identifier = NSUserInterfaceItemIdentifier("workspace-group-section")
    let style = WorkspaceGroupRowStyle(theme: theme)
    for item in workspaceGroupSidebarItems() {
      let row = WorkspaceGroupRowView(
        item: item, style: style,
        onSelect: { [weak self] in self?.selectWorkspaceGroupItem(item) },
        // 双击发生在 mouseDown 里；对话框推到下一轮主循环再弹，不在事件分发中途开模态。
        onDoubleClick: { [weak self] in
          DispatchQueue.main.async { self?.renameWorkspaceGroupItem(item) }
        },
        menuProvider: { [weak self] in self?.makeWorkspaceGroupRowMenu(item) ?? NSMenu() })
      rows.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
    }
    rows.setContentHuggingPriority(.required, for: .vertical)
    rows.setContentCompressionResistancePriority(.required, for: .vertical)
    return rows
  }

  /// 工作区区块标题行右侧的「+」：新建本机或远端工作区。
  func makeWorkspaceGroupAddButton() -> NSButton {
    let button = IconHoverButton(symbol: "plus", accessibilityDescription: L("新建工作区")) {
      [weak self] in
      DispatchQueue.main.async { self?.createWorkspaceGroupFromSidebar() }
    }
    button.image = button.image?.withSymbolConfiguration(
      .init(pointSize: InterfaceScale.font(10), weight: .semibold))
    button.restingTint = AsterTheme.tertiaryInk
    button.toolTip = L("新建工作区")
    button.identifier = NSUserInterfaceItemIdentifier("workspace-group-add-button")
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: InterfaceScale.length(22)),
      button.heightAnchor.constraint(equalToConstant: InterfaceScale.length(22)),
    ])
    return button
  }

  /// 横向标签条开头的工作区按钮。
  func makeWorkspaceGroupPopUpButton(theme: TerminalTheme) -> NSButton {
    let style = WorkspaceGroupRowStyle(theme: theme)
    return WorkspaceGroupPopUpButton(
      title: currentWorkspaceGroupName() ?? L("工作区"), tint: style.foreground
    ) { [weak self] in
      self?.makeWorkspaceGroupSwitchMenu() ?? NSMenu()
    }
  }

  /// 标签右键菜单里的「移到工作区」：列出其它本机工作区；没有其它工作区或当前是远端机器时禁用。
  func makeMoveTabToWorkspaceGroupItem(_ tab: TerminalTabItem) -> NSMenuItem {
    let item = NSMenuItem(title: L("移到工作区"), action: nil, keyEquivalent: "")
    item.identifier = NSUserInterfaceItemIdentifier("tab-menu-move-to-workspace-group")
    let targets = model.isLocalMachineActive
      ? model.workspaceGroups.filter { $0.id != tab.workspaceGroupID } : []
    // 无 action 且无子菜单的项会被菜单自动校验置灰，这就是「禁用」。
    guard !targets.isEmpty else { return item }
    let submenu = NSMenu()
    for group in targets {
      submenu.addItem(
        ActionMenuItem(title: group.name) { [weak self, weak tab] in
          guard let self, let tab else { return }
          model.moveTab(tab.id, toWorkspaceGroup: group.id)
        })
    }
    item.submenu = submenu
    return item
  }

  // MARK: - 菜单

  /// 工作区行的右键菜单：重命名… / 删除（关闭）工作区… / 新建工作区…。
  func makeWorkspaceGroupRowMenu(_ item: WorkspaceGroupSidebarItem) -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    menu.addItem(
      ActionMenuItem(title: L("重命名…")) { [weak self] in self?.renameWorkspaceGroupItem(item) })
    let remove: ActionMenuItem
    switch item.target {
    case .local(let id):
      remove = ActionMenuItem(title: L("删除工作区…")) { [weak self] in
        guard let self else { return }
        WorkspaceGroupActions.confirmAndDelete(id, in: model, window: view.window)
      }
      // 至少保留一个工作区：最后一个不能删。
      remove.isEnabled = model.canDeleteWorkspaceGroup(id)
    case .remote(let machineID, let summary):
      remove = ActionMenuItem(title: L("关闭工作区…")) { [weak self] in
        self?.switcherActions().schedule(.closeRemote(machineID: machineID, summary: summary))
      }
    }
    menu.addItem(remove)
    menu.addItem(.separator())
    menu.addItem(
      ActionMenuItem(title: L("新建工作区…")) { [weak self] in self?.createWorkspaceGroupFromSidebar() })
    return menu
  }

  /// 横向标签条的工作区菜单：勾选当前工作区的列表 + 新建 / 重命名当前工作区。
  func makeWorkspaceGroupSwitchMenu() -> NSMenu {
    let menu = NSMenu()
    menu.autoenablesItems = false
    let items = workspaceGroupSidebarItems()
    for item in items {
      let entry = ActionMenuItem(title: item.name) { [weak self] in
        self?.selectWorkspaceGroupItem(item)
      }
      entry.state = item.isSelected ? .on : .off
      menu.addItem(entry)
    }
    if !items.isEmpty { menu.addItem(.separator()) }
    menu.addItem(
      ActionMenuItem(title: L("新建工作区…")) { [weak self] in self?.createWorkspaceGroupFromSidebar() })
    let rename = ActionMenuItem(title: L("重命名工作区…")) { [weak self] in
      guard let self, let current = workspaceGroupSidebarItems().first(where: \.isSelected) else {
        return
      }
      renameWorkspaceGroupItem(current)
    }
    rename.isEnabled = items.contains(where: \.isSelected)
    menu.addItem(rename)
    return menu
  }

  // MARK: - 动作

  /// 切到某个工作区。本机直接改模型；远端走切换器同一条路径（记使用时间、失败弹窗）。
  func selectWorkspaceGroupItem(_ item: WorkspaceGroupSidebarItem) {
    guard !item.isSelected else { return }
    switch item.target {
    case .local(let id):
      model.selectWorkspaceGroup(id)
    case .remote(let machineID, let summary):
      switcherActions().perform(.selectRemote(machineID: machineID, workspaceID: summary.workspaceID))
    }
  }

  /// 重命名工作区（对话框）。
  func renameWorkspaceGroupItem(_ item: WorkspaceGroupSidebarItem) {
    switch item.target {
    case .local(let id):
      WorkspaceGroupActions.promptRename(id, in: model, window: view.window)
    case .remote(let machineID, let summary):
      switcherActions().perform(
        .renameRemote(
          machineID: machineID, workspaceID: summary.workspaceID, currentTitle: summary.title))
    }
  }

  /// 新建工作区：本机建窗口内工作区；远端在这台机器上建远端工作区并切过去。
  func createWorkspaceGroupFromSidebar() {
    guard !model.isLocalMachineActive else {
      WorkspaceGroupActions.promptCreate(in: model, window: view.window)
      return
    }
    let machineID = model.activeMachineID
    let coordinator = remoteWorkspaces
    let window = view.window
    let existing = coordinator.remoteWorkspaces(machineID: machineID).map(\.title)
    guard
      let title = WorkspaceSheetPresenter.promptForName(
        title: L("新建远端工作区"), message: L("在这台机器上新建一个工作区，里面先开一个 Shell。"),
        current: WorkspaceGroupRules.uniqueName(
          base: AppModel.workspaceGroupNameBase, existing: existing),
        confirm: L("创建"), in: window)
    else { return }
    Task { @MainActor in
      do {
        _ = try await coordinator.createRemoteWorkspace(machineID: machineID, title: title)
      } catch {
        MachineSetupSheet.presentFailure(WorkspaceSheetPresenter.describe(error), in: window)
      }
    }
  }

  /// 远端工作区动作复用 Open Quickly 切换器的执行器，文案、确认与错误弹窗只有一份。
  private func switcherActions() -> WorkspaceSwitcherActions {
    WorkspaceSwitcherActions(
      controller: self, directory: WorkspaceSwitcherActions.appDirectory, fleet: machineFleet)
  }
}
