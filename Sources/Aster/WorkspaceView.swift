import AppKit
import AsterCore
import Combine

/// 纯 AppKit 主工作区。控制器根据领域模型重建轻量窗口框架，但终端 `NSView` 由
/// `TerminalSession` 长期持有，标签切换或布局刷新不会重启 PTY、清空滚动历史或 TUI。
@MainActor
final class WorkspaceViewController: NSViewController {
  private let model: AppModel
  private let preferences: AppPreferences
  private var modelSubscriptions: Set<AnyCancellable> = []
  private var tabSubscriptions: Set<AnyCancellable> = []
  private var retainedObjects: [AnyObject] = []
  private var refreshScheduled = false

  init(model: AppModel, preferences: AppPreferences) {
    self.model = model
    self.preferences = preferences
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    view = ThemeVisualEffectView(frame: NSRect(x: 0, y: 0, width: 1180, height: 760))
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    model.objectWillChange
      .sink { [weak self] _ in self?.scheduleRefresh() }
      .store(in: &modelSubscriptions)
    preferences.objectWillChange
      .sink { [weak self] _ in self?.scheduleRefresh() }
      .store(in: &modelSubscriptions)
    model.ensureInitialTab()
    refresh()
  }

  private func scheduleRefresh() {
    guard !refreshScheduled else { return }
    refreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      self?.refreshScheduled = false
      self?.refresh()
    }
  }

  private func refresh() {
    observeTabs()
    retainedObjects.removeAll()
    children.forEach { $0.removeFromParent() }
    view.removeAllSubviews()
    view.appearance = preferences.preferredAppearance

    let theme = preferences.activeTheme
    if let background = view as? ThemeVisualEffectView {
      background.apply(
        material: theme.palette.material,
        tint: theme.palette.interfaceWindowBackground ?? theme.palette.panelBackground
      )
    }

    let layout = makeWorkspaceLayout()
    view.addSubview(layout)
    layout.pinEdges(to: view)

    if model.isPalettePresented {
      let palette = PaletteOverlayViewController(model: model)
      addChild(palette)
      retainedObjects.append(palette)
      view.addSubview(palette.view)
      palette.view.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        palette.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        palette.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 82),
        palette.view.widthAnchor.constraint(equalToConstant: 520),
        palette.view.heightAnchor.constraint(lessThanOrEqualToConstant: 430),
      ])
    }

    if let notice = model.notice {
      let toast = makeToast(notice)
      view.addSubview(toast)
      toast.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        toast.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        toast.topAnchor.constraint(equalTo: view.topAnchor, constant: 46),
      ])
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.2) { [weak self] in
        if self?.model.notice == notice { self?.model.notice = nil }
      }
    }
  }

  private func observeTabs() {
    tabSubscriptions.removeAll()
    for tab in model.tabs {
      tab.objectWillChange
        .sink { [weak self] _ in self?.scheduleRefresh() }
        .store(in: &tabSubscriptions)
    }
  }

  private func makeWorkspaceLayout() -> NSView {
    let showsTabs = preferences.configuration.appearance.showsTabBar(tabCount: model.tabs.count)
    guard showsTabs else { return makeContentArea() }

    switch preferences.tabBarLayout {
    case .vertical:
      let stack = NSStackView()
      stack.orientation = .horizontal
      stack.spacing = 0
      stack.distribution = .fill
      let sidebar = makeVerticalTabBar()
      sidebar.translatesAutoresizingMaskIntoConstraints = false
      sidebar.widthAnchor.constraint(equalToConstant: preferences.sidebarWidth).isActive = true
      stack.addArrangedSubview(sidebar)
      if preferences.activeTheme.style.sidebarBorderWidth > 0 {
        stack.addArrangedSubview(
          makeDivider(
            color: preferences.activeTheme.style.sidebarBorderColor.map(NSColor.init)
              ?? AsterTheme.hairline,
            vertical: true,
            thickness: preferences.activeTheme.style.sidebarBorderWidth
          ))
      }
      let content = makeContentArea()
      content.setContentHuggingPriority(.defaultLow, for: .horizontal)
      content.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      stack.addArrangedSubview(content)
      return stack

    case .top, .bottom:
      let stack = NSStackView()
      stack.orientation = .vertical
      stack.spacing = 0
      stack.distribution = .fill
      let bar = makeHorizontalTabBar(isBottom: preferences.tabBarLayout == .bottom)
      let divider = makeDivider(color: AsterTheme.hairline, vertical: false)
      let content = makeContentArea()
      content.setContentHuggingPriority(.defaultLow, for: .vertical)
      content.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
      if preferences.tabBarLayout == .top {
        stack.addArrangedSubview(bar)
        stack.addArrangedSubview(divider)
        stack.addArrangedSubview(content)
      } else {
        stack.addArrangedSubview(content)
        stack.addArrangedSubview(divider)
        stack.addArrangedSubview(bar)
      }
      return stack
    }
  }

  private func makeContentArea() -> NSView {
    let host = NSView()
    let workspace: NSView
    if let tab = model.selectedTab {
      workspace = makeTerminalWorkspace(tab)
    } else {
      workspace = makeEmptyWorkspace()
    }
    host.addSubview(workspace)
    workspace.translatesAutoresizingMaskIntoConstraints = false
    if model.isInspectorPresented {
      let divider = makeDivider(color: AsterTheme.hairline, vertical: true)
      let details = DetailsPanelViewController(model: model, preferences: preferences)
      addChild(details)
      retainedObjects.append(details)
      host.addSubview(divider)
      host.addSubview(details.view)
      details.view.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        workspace.leadingAnchor.constraint(equalTo: host.leadingAnchor),
        workspace.topAnchor.constraint(equalTo: host.topAnchor),
        workspace.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        divider.leadingAnchor.constraint(equalTo: workspace.trailingAnchor),
        divider.topAnchor.constraint(equalTo: host.topAnchor),
        divider.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        details.view.leadingAnchor.constraint(equalTo: divider.trailingAnchor),
        details.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        details.view.topAnchor.constraint(equalTo: host.topAnchor),
        details.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        details.view.widthAnchor.constraint(equalToConstant: 278),
      ])
    } else {
      workspace.pinEdges(to: host)
    }
    return host
  }

  // MARK: - Tab bars

  private func makeVerticalTabBar() -> NSView {
    let theme = preferences.activeTheme
    let background = ThemeVisualEffectView()
    background.apply(
      material: theme.style.sidebarMaterial ?? theme.palette.material,
      tint: theme.style.sidebarBackground ?? theme.palette.panelBackground
    )

    let column = NSStackView()
    column.orientation = .vertical
    column.alignment = .width
    column.distribution = .fill
    column.spacing = 0
    background.addSubview(column)
    column.pinEdges(to: background)

    let header = NSView()
    header.translatesAutoresizingMaskIntoConstraints = false
    header.heightAnchor.constraint(equalToConstant: 68).isActive = true
    let title = makeLabel("TABS", size: 10, weight: .semibold, color: AsterTheme.tertiaryInk)
    title.translatesAutoresizingMaskIntoConstraints = false
    let menu = SidebarOptionsButton { [weak self] in
      self?.makeSidebarOptionsMenu() ?? NSMenu()
    }
    header.addSubview(title)
    header.addSubview(menu)
    NSLayoutConstraint.activate([
      title.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 12),
      title.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12),
      menu.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
      menu.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -5),
    ])
    column.addArrangedSubview(header)

    let rows = NSStackView()
    rows.orientation = .vertical
    // 垂直栈默认按控件固有宽度居中。Otty 的标签从侧栏左缘铺到右缘，显式
    // 使用 width 对齐后，选中背景才不会缩成内容宽度的小卡片。
    rows.alignment = .width
    rows.spacing = 0
    for section in sidebarTabSections() {
      if let title = section.title {
        let header = makeSidebarGroupHeader(title)
        rows.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
      }
      for tab in section.tabs {
        let button = TabRowButton(
          tab: tab,
          selected: tab.id == model.selectedTabID,
          horizontal: false,
          theme: theme,
          action: { [weak self, weak tab] in
            guard let tab else { return }
            self?.model.select(tab)
          }
        )
        button.menu = makeTabContextMenu(tab)
        rows.addArrangedSubview(button)
        button.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        if model.dividerAfterTabIDs.contains(tab.id) {
          let divider = makeDivider(color: AsterTheme.hairline, vertical: false)
          divider.identifier = NSUserInterfaceItemIdentifier("sidebar-manual-divider")
          rows.addArrangedSubview(divider)
          divider.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        }
      }
    }
    // 当前标签数量受工作区模型控制，直接把紧凑列表放进侧栏栈能保证首次窗口布局
    // 立即可见。旧实现嵌套 NSScrollView 时其 arrangedSubview 高度被压到 0，导致整列
    // 标签消失；多标签仍按固定行高向下排列，窗口最小高度足以容纳常用工作区。
    rows.setContentHuggingPriority(.required, for: .vertical)
    rows.setContentCompressionResistancePriority(.required, for: .vertical)
    column.addArrangedSubview(rows)
    rows.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .vertical)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    column.addArrangedSubview(spacer)

    return background
  }

  /// 排序先于分组执行，使每个分组内部与未分组列表使用同一时间顺序；相同时间使用
  /// UUID 作为稳定兜底，避免 AppKit 刷新时标签随机跳动。
  private func sidebarTabSections() -> [(title: String?, tabs: [TerminalTabItem])] {
    let sorted = model.tabs.sorted { lhs, rhs in
      let lhsDate = preferences.sidebarTabOrder == .createdTime ? lhs.createdAt : lhs.updatedAt
      let rhsDate = preferences.sidebarTabOrder == .createdTime ? rhs.createdAt : rhs.updatedAt
      if lhsDate != rhsDate { return lhsDate > rhsDate }
      return lhs.id.uuidString < rhs.id.uuidString
    }
    guard preferences.sidebarTabGrouping != .none else {
      return [(nil, sorted)]
    }

    var sectionOrder: [String] = []
    var grouped: [String: [TerminalTabItem]] = [:]
    for tab in sorted {
      let key: String
      switch preferences.sidebarTabGrouping {
      case .none:
        key = ""
      case .project:
        let name = URL(fileURLWithPath: tab.workingDirectory).lastPathComponent
        key = name.isEmpty ? tab.title : name
      case .date:
        key = sidebarDateGroupTitle(for: tab.createdAt)
      }
      if grouped[key] == nil { sectionOrder.append(key) }
      grouped[key, default: []].append(tab)
    }
    return sectionOrder.map { ($0, grouped[$0] ?? []) }
  }

  private func sidebarDateGroupTitle(for date: Date) -> String {
    let calendar = Calendar.current
    if calendar.isDateInToday(date) { return "Today" }
    if calendar.isDateInYesterday(date) { return "Yesterday" }
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.dateStyle = .medium
    formatter.timeStyle = .none
    return formatter.string(from: date)
  }

  private func makeSidebarGroupHeader(_ title: String) -> NSView {
    let host = NSView()
    host.translatesAutoresizingMaskIntoConstraints = false
    host.heightAnchor.constraint(equalToConstant: 30).isActive = true
    let label = makeLabel(title, size: 10.5, weight: .semibold, color: AsterTheme.tertiaryInk)
    label.identifier = NSUserInterfaceItemIdentifier("sidebar-group-header")
    host.addSubview(label)
    label.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: 12),
      label.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -12),
      label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
    ])
    return host
  }

  /// 菜单内容在每次展开时重建，勾选状态始终反映最新分组、排序和分隔线状态。
  private func makeSidebarOptionsMenu() -> NSMenu {
    let menu = NSMenu(title: "整理标签")
    menu.autoenablesItems = false
    menu.addItem(makeSidebarMenuHeader("GROUP"))
    menu.addItem(
      makeSidebarMenuItem(
        "No Grouping", symbol: "list.bullet", action: #selector(setSidebarGroupingNone),
        state: preferences.sidebarTabGrouping == .none ? .on : .off))
    menu.addItem(
      makeSidebarMenuItem(
        "By Project", symbol: "folder", action: #selector(setSidebarGroupingProject),
        state: preferences.sidebarTabGrouping == .project ? .on : .off))
    menu.addItem(
      makeSidebarMenuItem(
        "By Date", symbol: "calendar", action: #selector(setSidebarGroupingDate),
        state: preferences.sidebarTabGrouping == .date ? .on : .off))
    menu.addItem(.separator())
    menu.addItem(makeSidebarMenuHeader("ORDER"))
    menu.addItem(
      makeSidebarMenuItem(
        "Created Time", symbol: "clock", action: #selector(setSidebarOrderCreated),
        state: preferences.sidebarTabOrder == .createdTime ? .on : .off))
    menu.addItem(
      makeSidebarMenuItem(
        "Updated Time", symbol: "clock.arrow.circlepath", action: #selector(setSidebarOrderUpdated),
        state: preferences.sidebarTabOrder == .updatedTime ? .on : .off))
    menu.addItem(.separator())
    menu.addItem(makeSidebarMenuHeader("DIVIDER"))
    menu.addItem(
      makeSidebarMenuItem(
        "Insert Divider", symbol: "plus", action: #selector(insertSidebarDivider)))
    menu.addItem(
      makeSidebarMenuItem(
        "Remove All Dividers", symbol: "trash", action: #selector(removeAllSidebarDividers)))
    return menu
  }

  /// 原生菜单没有独立 section API，禁用项配合小号半粗体可获得截图中的分组标题，
  /// 同时不会进入键盘选择序列。
  private func makeSidebarMenuHeader(_ title: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
    item.isEnabled = false
    item.attributedTitle = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
        .foregroundColor: AsterTheme.tertiaryInk,
      ]
    )
    return item
  }

  private func makeSidebarMenuItem(
    _ title: String,
    symbol: String,
    action: Selector,
    state: NSControl.StateValue = .off
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
    item.target = self
    item.isEnabled = true
    item.state = state
    item.image = NSImage(
      systemSymbolName: symbol,
      accessibilityDescription: title
    )?.withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
    return item
  }

  private func makeHorizontalTabBar(isBottom: Bool) -> NSView {
    let theme = preferences.activeTheme
    let background = ThemeVisualEffectView()
    background.apply(
      material: theme.style.horizontalTabBarMaterial ?? theme.palette.material,
      tint: theme.style.horizontalTabBarBackground ?? theme.style.sidebarBackground
        ?? theme.palette.panelBackground
    )
    let height = theme.style.horizontalTabBarHeight ?? 40
    background.translatesAutoresizingMaskIntoConstraints = false
    background.heightAnchor.constraint(equalToConstant: isBottom ? height : height + 27).isActive = true

    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 3
    row.alignment = .centerY
    if !isBottom {
      row.edgeInsets = NSEdgeInsets(top: 27, left: 70, bottom: 0, right: 8)
    } else {
      row.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
    }
    for tab in model.tabs {
      let button = TabRowButton(
        tab: tab,
        selected: tab.id == model.selectedTabID,
        horizontal: true,
        theme: theme,
        action: { [weak self, weak tab] in
          guard let tab else { return }
          self?.model.select(tab)
        }
      )
      button.menu = makeTabContextMenu(tab)
      row.addArrangedSubview(button)
    }
    row.addArrangedSubview(ActionButton(symbol: "plus") { [weak self] in self?.model.newTab() })
    row.addArrangedSubview(ActionButton(symbol: "line.3.horizontal") { [weak self] in
      self?.model.togglePalette()
    })
    background.addSubview(row)
    row.pinEdges(to: background)
    return background
  }

  private func makeTabContextMenu(_ tab: TerminalTabItem) -> NSMenu {
    let menu = NSMenu()
    menu.addItem(ActionMenuItem(title: "向右分屏") { [weak self, weak tab] in
      guard let self, let tab else { return }
      model.select(tab)
      model.splitSelectedTab(.right)
    })
    menu.addItem(ActionMenuItem(title: "向下分屏") { [weak self, weak tab] in
      guard let self, let tab else { return }
      model.select(tab)
      model.splitSelectedTab(.down)
    })
    menu.addItem(ActionMenuItem(title: "打开文件浏览器") { [weak self, weak tab] in
      guard let self, let tab else { return }
      model.select(tab)
      tab.openFileBrowser()
      model.persistWorkspace()
    })
    menu.addItem(.separator())
    menu.addItem(ActionMenuItem(title: "关闭标签页") { [weak self, weak tab] in
      guard let self, let tab else { return }
      model.select(tab)
      model.closeSelectedTab()
    })
    return menu
  }

  // MARK: - Workspace content

  private func makeTerminalWorkspace(_ tab: TerminalTabItem) -> NSView {
    let stack = NSStackView()
    stack.orientation = .vertical
    stack.alignment = .width
    stack.spacing = 0
    stack.addArrangedSubview(makeWorkspaceHeader(tab))
    if model.isFindPresented { stack.addArrangedSubview(makeFindBar(tab)) }

    let style = preferences.activeTheme.style.container
    let margin = preferences.tabBarLayout == .vertical
      ? style.margin : (style.horizontalLayoutMargin ?? style.margin)
    let wrapper = NSView()
    let container = NSView()
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor(
      style.background ?? preferences.activeTheme.palette.containerBackground
    ).cgColor
    container.layer?.cornerRadius = style.radius
    container.layer?.cornerCurve = .continuous
    container.layer?.borderWidth = style.borderWidth
    container.layer?.borderColor = style.borderColor.map(NSColor.init)?.cgColor
    if let shadow = style.shadow {
      container.shadow = NSShadow()
      container.shadow?.shadowColor = NSColor(shadow.color)
      container.shadow?.shadowBlurRadius = shadow.blur
      container.shadow?.shadowOffset = NSSize(width: shadow.x, height: -shadow.y)
      container.layer?.masksToBounds = false
    }
    wrapper.addSubview(container)
    container.pinEdges(to: wrapper, insets: NSEdgeInsets(margin))

    let inner = NSStackView()
    inner.orientation = .vertical
    // Pane 容器没有固有宽度；显式按 stack 宽度拉伸，避免递归 NSSplitView 被压成 1 pt。
    inner.alignment = .width
    inner.spacing = 0
    container.addSubview(inner)
    inner.pinEdges(to: container)

    let paneHost = NSView()
    let paneTree = makePaneTree(tab.layout, tab: tab, path: [])
    paneHost.addSubview(paneTree)
    paneTree.pinEdges(to: paneHost, insets: NSEdgeInsets(style.padding))
    inner.addArrangedSubview(paneHost)
    if preferences.showStatusBar { inner.addArrangedSubview(makeStatusBar(tab)) }
    stack.addArrangedSubview(wrapper)
    // 这些内容容器没有 intrinsicContentSize；显式绑定横向尺寸，保证 AppKit 的
    // NSStackView 不会在主题边距存在时把 Pane 树压缩到最小宽度。
    wrapper.translatesAutoresizingMaskIntoConstraints = false
    paneHost.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      wrapper.widthAnchor.constraint(equalTo: stack.widthAnchor),
      paneHost.widthAnchor.constraint(equalTo: inner.widthAnchor),
    ])
    return stack
  }

  private func makeWorkspaceHeader(_ tab: TerminalTabItem) -> NSView {
    let theme = preferences.activeTheme
    let background = ThemeVisualEffectView()
    // Otty 的右侧标题区与终端画布连续，主题声明的 titlebar material 只用于
    // 独立系统标题栏。这里使用终端最终背景色，避免 vibrancy 把右侧顶部压成灰条。
    background.apply(
      material: TerminalThemeMaterial.none,
      tint: theme.palette.renderedTerminalBackground
    )
    background.translatesAutoresizingMaskIntoConstraints = false
    background.identifier = NSUserInterfaceItemIdentifier("workspace-titlebar")
    background.heightAnchor.constraint(equalToConstant: 28).isActive = true

    // Otty 的右侧顶部只显示当前目录。文件、分屏和命令面板仍由菜单与快捷键提供，
    // 不在标题栏重复堆放按钮，终端内容因此可以紧贴原生标题区开始。
    let path = tab.workingDirectory.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    let title = makeLabel(
      path,
      size: 10.5,
      color: theme.style.titlebarForeground.map(NSColor.init) ?? AsterTheme.secondaryInk
    )
    title.alignment = .center
    background.addSubview(title)
    title.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      title.centerXAnchor.constraint(equalTo: background.centerXAnchor),
      title.centerYAnchor.constraint(equalTo: background.centerYAnchor),
      title.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: 12),
      title.trailingAnchor.constraint(lessThanOrEqualTo: background.trailingAnchor, constant: -12),
    ])
    return background
  }

  private func makeFindBar(_ tab: TerminalTabItem) -> NSView {
    let bar = NSView()
    bar.wantsLayer = true
    bar.layer?.backgroundColor = AsterTheme.panel.cgColor
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.heightAnchor.constraint(equalToConstant: 36).isActive = true
    bar.addBottomBorder(color: AsterTheme.hairline)

    let field = NSSearchField()
    field.placeholderString = "在终端缓冲区中查找"
    field.target = self
    field.action = #selector(findNext(_:))
    field.identifier = NSUserInterfaceItemIdentifier(tab.id.uuidString)
    let previous = ActionButton(symbol: "chevron.up") { [weak tab, weak field] in
      guard let term = field?.stringValue else { return }
      _ = tab?.activeSession?.findNext(term, previous: true)
    }
    let next = ActionButton(symbol: "chevron.down") { [weak tab, weak field] in
      guard let term = field?.stringValue else { return }
      _ = tab?.activeSession?.findNext(term)
    }
    let close = ActionButton(symbol: "xmark") { [weak self] in self?.model.isFindPresented = false }
    let row = NSStackView(views: [field, previous, next, close])
    row.orientation = .horizontal
    row.spacing = 8
    row.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
    bar.addSubview(row)
    row.pinEdges(to: bar)
    DispatchQueue.main.async { [weak field] in field?.window?.makeFirstResponder(field) }
    return bar
  }

  private func makePaneTree(
    _ layout: PaneLayout,
    tab: TerminalTabItem,
    path: [Int]
  ) -> NSView {
    switch layout {
    case .leaf(let descriptor):
      return makePaneLeaf(descriptor, tab: tab)
    case .split(let axis, let first, let second, let ratio):
      let split = PersistedSplitView(
        axis: axis,
        ratio: ratio,
        onRatioChanged: { [weak tab] newRatio in
          tab?.updateSplitRatio(at: path, ratio: newRatio)
        }
      )
      split.addArrangedSubview(makePaneTree(first, tab: tab, path: path + [0]))
      split.addArrangedSubview(makePaneTree(second, tab: tab, path: path + [1]))
      return split
    }
  }

  private func makePaneLeaf(_ descriptor: PaneDescriptor, tab: TerminalTabItem) -> NSView {
    guard let runtime = tab.runtime(for: descriptor.id) else {
      return makeCenteredMessage(title: "面板不可用", symbol: "exclamationmark.triangle")
    }
    let host = ActivePaneHostView(isActive: tab.activePaneID == descriptor.id) {
      tab.activePaneID = descriptor.id
    }
    let content: NSView
    switch descriptor.kind {
    case .terminal: content = makeTerminalPane(runtime, tab: tab)
    case .editor: content = makeEditorPane(runtime, tab: tab)
    case .fileBrowser:
      let controller = FileBrowserViewController(runtime: runtime, tab: tab)
      addChild(controller)
      retainedObjects.append(controller)
      content = controller.view
    case .preview: content = makePreviewPane(runtime)
    }
    host.addSubview(content)
    content.pinEdges(to: host)
    // 单 Pane 无需额外蓝色顶边；只有分屏时才显示焦点边界，避免主界面比 Otty
    // 多出一条高对比装饰线。
    if tab.layout.allPanes.count > 1 { host.installIndicator() }
    return host
  }

  private func makeTerminalPane(_ runtime: WorkspacePaneRuntime, tab: TerminalTabItem) -> NSView {
    guard let session = runtime.terminalSession else {
      return makeCenteredMessage(title: "终端不可用", symbol: "terminal")
    }
    let host = session.makeTerminalHost(preferences: preferences)
    host.removeFromSuperview()
    if let error = session.startupError {
      let warning = makeLabel(error, size: 10.5, color: AsterTheme.warning)
      warning.wantsLayer = true
      warning.layer?.backgroundColor = AsterTheme.panel.withAlphaComponent(0.92).cgColor
      warning.layer?.cornerRadius = 7
      warning.translatesAutoresizingMaskIntoConstraints = false
      host.addSubview(warning)
      NSLayoutConstraint.activate([
        warning.centerXAnchor.constraint(equalTo: host.centerXAnchor),
        warning.topAnchor.constraint(equalTo: host.topAnchor, constant: 9),
      ])
    }
    DispatchQueue.main.async { [weak session] in session?.focus() }
    return host
  }

  private func makeEditorPane(_ runtime: WorkspacePaneRuntime, tab: TerminalTabItem) -> NSView {
    let column = NSStackView()
    column.orientation = .vertical
    column.spacing = 0
    let name = URL(fileURLWithPath: runtime.descriptor.resourcePath ?? "Untitled").lastPathComponent
      + (runtime.isDirty ? " •" : "")
    column.addArrangedSubview(makePaneToolbar(title: name, symbol: "doc.text", save: runtime.saveDocument))
    if let error = runtime.documentError, runtime.documentText.isEmpty {
      column.addArrangedSubview(makeCenteredMessage(title: error, symbol: "exclamationmark.triangle"))
    } else {
      let textView = NSTextView()
      textView.string = runtime.documentText
      textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
      textView.textColor = AsterTheme.ink
      textView.backgroundColor = AsterTheme.paper
      textView.isAutomaticQuoteSubstitutionEnabled = false
      textView.isAutomaticDashSubstitutionEnabled = false
      let delegate = DocumentTextDelegate(runtime: runtime)
      textView.delegate = delegate
      retainedObjects.append(delegate)
      let scroll = NSScrollView()
      scroll.hasVerticalScroller = true
      scroll.documentView = textView
      column.addArrangedSubview(scroll)
    }
    return column
  }

  private func makePreviewPane(_ runtime: WorkspacePaneRuntime) -> NSView {
    let column = NSStackView()
    column.orientation = .vertical
    column.spacing = 0
    column.addArrangedSubview(makePaneToolbar(title: "预览", symbol: "eye", save: nil))
    let textView = NSTextView()
    textView.isEditable = false
    textView.drawsBackground = false
    textView.textColor = AsterTheme.ink
    textView.font = NSFont.systemFont(ofSize: 14)
    textView.textContainerInset = NSSize(width: 28, height: 28)
    if let path = runtime.descriptor.resourcePath {
      do { textView.string = try String(contentsOfFile: path, encoding: .utf8) }
      catch { textView.string = "无法预览：\(error.localizedDescription)" }
    }
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.documentView = textView
    column.addArrangedSubview(scroll)
    return column
  }

  private func makePaneToolbar(title: String, symbol: String, save: (() -> Void)?) -> NSView {
    let bar = NSView()
    bar.wantsLayer = true
    bar.layer?.backgroundColor = AsterTheme.panel.cgColor
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.heightAnchor.constraint(equalToConstant: 36).isActive = true
    bar.addBottomBorder(color: AsterTheme.hairline)
    let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
    let label = makeLabel(title, size: 11, weight: .medium)
    let row = NSStackView(views: [icon, label])
    row.orientation = .horizontal
    row.spacing = 8
    if let save { row.addArrangedSubview(ActionButton(symbol: "square.and.arrow.down", handler: save)) }
    row.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
    bar.addSubview(row)
    row.pinEdges(to: bar)
    return bar
  }

  private func makeStatusBar(_ tab: TerminalTabItem) -> NSView {
    let bar = NSView()
    bar.wantsLayer = true
    bar.layer?.backgroundColor = AsterTheme.panel.cgColor
    bar.translatesAutoresizingMaskIntoConstraints = false
    bar.heightAnchor.constraint(equalToConstant: 26).isActive = true
    bar.addTopBorder(color: AsterTheme.hairline)
    let state = tab.activeSession?.statusIsRunning == false ? "●  session ended" : "●  workspace"
    let path = tab.workingDirectory.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    let label = makeLabel("\(state)  ·  \(path)", size: 9.5, weight: .medium, color: AsterTheme.tertiaryInk, monospaced: true)
    let right = makeLabel("\(tab.layout.allPanes.count) PANE\(tab.layout.allPanes.count == 1 ? "" : "S")   UTF-8", size: 9.5, weight: .medium, color: AsterTheme.tertiaryInk, monospaced: true)
    let row = NSStackView(views: [label, NSView(), right])
    row.orientation = .horizontal
    row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
    bar.addSubview(row)
    row.pinEdges(to: bar)
    return bar
  }

  private func makeEmptyWorkspace() -> NSView {
    makeCenteredMessage(title: "新建标签页开始使用 Aster", symbol: "terminal")
  }

  private func makeCenteredMessage(title: String, symbol: String) -> NSView {
    let host = NSView()
    let image = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: title) ?? NSImage())
    image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 32, weight: .ultraLight)
    let label = makeLabel(title, size: 12, color: AsterTheme.secondaryInk)
    let stack = NSStackView(views: [image, label])
    stack.orientation = .vertical
    stack.spacing = 12
    host.addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: host.centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: host.centerYAnchor),
    ])
    return host
  }

  private func makeDivider(color: NSColor, vertical: Bool, thickness: CGFloat = 1) -> NSView {
    let divider = NSView()
    divider.wantsLayer = true
    divider.layer?.backgroundColor = color.cgColor
    divider.translatesAutoresizingMaskIntoConstraints = false
    if vertical { divider.widthAnchor.constraint(equalToConstant: thickness).isActive = true }
    else { divider.heightAnchor.constraint(equalToConstant: thickness).isActive = true }
    return divider
  }

  private func makeToast(_ message: String) -> NSView {
    let label = makeLabel(message, size: 11, weight: .medium)
    label.wantsLayer = true
    label.layer?.backgroundColor = AsterTheme.panel.withAlphaComponent(0.95).cgColor
    label.layer?.cornerRadius = 8
    label.layer?.borderWidth = 1
    label.layer?.borderColor = AsterTheme.hairline.cgColor
    label.alignment = .center
    label.translatesAutoresizingMaskIntoConstraints = false
    label.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
    label.heightAnchor.constraint(equalToConstant: 34).isActive = true
    return label
  }

  @objc private func newTab() { model.newTab() }
  @objc private func togglePalette() { model.togglePalette() }
  @objc private func setSidebarGroupingNone() { preferences.sidebarTabGrouping = .none }
  @objc private func setSidebarGroupingProject() { preferences.sidebarTabGrouping = .project }
  @objc private func setSidebarGroupingDate() { preferences.sidebarTabGrouping = .date }
  @objc private func setSidebarOrderCreated() { preferences.sidebarTabOrder = .createdTime }
  @objc private func setSidebarOrderUpdated() { preferences.sidebarTabOrder = .updatedTime }
  @objc private func insertSidebarDivider() { model.insertDividerAfterSelectedTab() }
  @objc private func removeAllSidebarDividers() { model.removeAllTabDividers() }
  @objc private func showSettings() { (NSApp.delegate as? AsterAppDelegate)?.showSettings(nil) }
  @objc private func findNext(_ sender: NSSearchField) {
    _ = model.selectedTab?.activeSession?.findNext(sender.stringValue)
  }
}

// MARK: - AppKit components

/// `TABS` 标题右侧的标签整理入口。使用原生 `NSMenu` 保留 macOS 的毛玻璃、阴影、
/// 键盘导航和辅助功能；菜单展开期间按钮保持截图中的浅灰圆角按下态。
@MainActor
private final class SidebarOptionsButton: NSButton {
  private let menuProvider: () -> NSMenu

  init(menuProvider: @escaping () -> NSMenu) {
    self.menuProvider = menuProvider
    super.init(frame: .zero)
    image = NSImage(systemSymbolName: "line.3.horizontal.decrease", accessibilityDescription: "整理标签")
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
private final class TabRowButton: NSButton {
  private let tab: TerminalTabItem
  private let selected: Bool
  private let style: TerminalTabStyle
  private let handler: () -> Void
  private var tracking: NSTrackingArea?
  private var hovered = false { didSet { updateStyle() } }

  init(tab: TerminalTabItem, selected: Bool, horizontal: Bool, theme: TerminalTheme, action: @escaping () -> Void) {
    self.tab = tab
    self.selected = selected
    style = horizontal ? (theme.style.horizontalTab ?? theme.style.tab) : theme.style.tab
    handler = action
    super.init(frame: .zero)
    title = horizontal ? tab.title : ""
    alignment = .left
    isBordered = false
    bezelStyle = .inline
    wantsLayer = true
    layer?.cornerCurve = .continuous
    target = self
    self.action = #selector(invoke)
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: style.height ?? (horizontal ? 31 : 47)).isActive = true
    if horizontal { widthAnchor.constraint(greaterThanOrEqualToConstant: 92).isActive = true }
    if !horizontal {
      // 选中与未选中显示同一份 `tab.title`（目录稳定显示名），切换标签时行文案
      // 不再在「完整路径 / 短名」之间跳变。
      let primary = makeLabel(
        tab.title,
        size: selected ? 11.5 : 11,
        weight: selected ? .semibold : .regular,
        color: selected ? (style.activeForeground.map(NSColor.init) ?? AsterTheme.ink)
          : (style.foreground.map(NSColor.init) ?? AsterTheme.secondaryInk)
      )
      addSubview(primary)
      primary.translatesAutoresizingMaskIntoConstraints = false

      // 右侧 accessory：有前台命令在运行时显示 spinner（业务状态来源为
      // TerminalSession 的前台进程组检测），否则选中行显示 shell 名。
      let accessory: NSView
      if tab.hasRunningCommand {
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)
        accessory = spinner
      } else {
        accessory = makeLabel(
          selected
            ? URL(fileURLWithPath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh").lastPathComponent
            : "",
          size: 10,
          color: AsterTheme.tertiaryInk,
          monospaced: true
        )
      }
      addSubview(accessory)
      accessory.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        primary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
        primary.centerYAnchor.constraint(equalTo: centerYAnchor),
        primary.trailingAnchor.constraint(lessThanOrEqualTo: accessory.leadingAnchor, constant: -8),
        accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
        accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
      ])
    }
    updateStyle()
  }

  /// 在 mouseDown 立即派发选择，不依赖 mouseUp 的 target/action：终端输出会触发
  /// 侧栏整树重建，若等到 mouseUp，按钮可能已在按下与抬起之间被销毁，点击就会丢失。
  override func mouseDown(with event: NSEvent) {
    handler()
  }

  required init?(coder: NSCoder) { nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let tracking { removeTrackingArea(tracking) }
    let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }

  private func updateStyle() {
    let foreground = selected ? style.activeForeground : style.foreground
    contentTintColor = foreground.map(NSColor.init) ?? AsterTheme.ink
    font = NSFont.systemFont(
      ofSize: selected ? 12.5 : 12,
      weight: selected ? NSFont.Weight(cssWeight: style.activeFontWeight) : .regular
    )
    layer?.cornerRadius = style.radius
    let background: NSColor
    if selected { background = style.activeBackground.map(NSColor.init) ?? AsterTheme.ink.withAlphaComponent(0.075) }
    else if hovered { background = style.hoverBackground.map(NSColor.init) ?? .clear }
    else { background = .clear }
    layer?.backgroundColor = background.cgColor
    layer?.borderWidth = selected ? style.activeBorderWidth : 0
    layer?.borderColor = style.activeBorderColor.map(NSColor.init)?.cgColor
    if selected, let shadow = style.activeShadow {
      layer?.shadowColor = NSColor(shadow.color).cgColor
      layer?.shadowOpacity = 1
      layer?.shadowRadius = shadow.blur
      layer?.shadowOffset = NSSize(width: shadow.x, height: -shadow.y)
    } else {
      layer?.shadowOpacity = 0
    }
  }

  @objc private func invoke() { handler() }
}

/// 递归分屏使用 `NSSplitView`，拖动结束后的比例写回领域模型以供会话恢复。
@MainActor
private final class PersistedSplitView: NSSplitView, NSSplitViewDelegate {
  private let ratio: Double
  private let onRatioChanged: (Double) -> Void
  private var positioned = false
  private var isUserResizing = false

  init(axis: SplitAxis, ratio: Double, onRatioChanged: @escaping (Double) -> Void) {
    self.ratio = ratio
    self.onRatioChanged = onRatioChanged
    super.init(frame: .zero)
    isVertical = axis == .horizontal
    dividerStyle = .thin
    delegate = self
  }

  required init?(coder: NSCoder) { nil }

  override func layout() {
    super.layout()
    guard !positioned, arrangedSubviews.count == 2 else { return }
    positioned = true
    let length = isVertical ? bounds.width : bounds.height
    setPosition(max(1, length * ratio), ofDividerAt: 0)
  }

  func splitViewDidResizeSubviews(_ notification: Notification) {
    guard positioned, isUserResizing, arrangedSubviews.count == 2 else { return }
    let total = isVertical ? bounds.width : bounds.height
    let first = isVertical ? arrangedSubviews[0].frame.width : arrangedSubviews[0].frame.height
    guard total > 0 else { return }
    onRatioChanged(min(max(first / total, 0.05), 0.95))
  }

  override func mouseDown(with event: NSEvent) {
    isUserResizing = true
    super.mouseDown(with: event)
    isUserResizing = false
  }
}

@MainActor
private final class ActivePaneHostView: NSView {
  private let activation: () -> Void
  private let isActivePane: Bool

  init(isActive: Bool, activation: @escaping () -> Void) {
    self.activation = activation
    isActivePane = isActive
    super.init(frame: .zero)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { nil }

  override func mouseDown(with event: NSEvent) {
    activation()
    super.mouseDown(with: event)
  }

  func installIndicator() {
    guard isActivePane else { return }
    let indicator = NSView()
    indicator.wantsLayer = true
    indicator.layer?.backgroundColor = AsterTheme.accent.cgColor
    addSubview(indicator)
    indicator.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      indicator.leadingAnchor.constraint(equalTo: leadingAnchor),
      indicator.trailingAnchor.constraint(equalTo: trailingAnchor),
      indicator.topAnchor.constraint(equalTo: topAnchor),
      indicator.heightAnchor.constraint(equalToConstant: 2),
    ])
  }
}

@MainActor
private final class DocumentTextDelegate: NSObject, NSTextViewDelegate {
  weak var runtime: WorkspacePaneRuntime?
  init(runtime: WorkspacePaneRuntime) { self.runtime = runtime }
  func textDidChange(_ notification: Notification) {
    guard let text = notification.object as? NSTextView else { return }
    runtime?.updateDocument(text.string)
  }
}

@MainActor
private final class FileBrowserViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
  private let runtime: WorkspacePaneRuntime
  private weak var tab: TerminalTabItem?
  private var directory: URL
  private var entries: [URL] = []
  private let table = NSTableView()

  init(runtime: WorkspacePaneRuntime, tab: TerminalTabItem) {
    self.runtime = runtime
    self.tab = tab
    directory = URL(fileURLWithPath: runtime.descriptor.resourcePath ?? runtime.descriptor.workingDirectory)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let column = NSStackView()
    column.orientation = .vertical
    column.spacing = 0
    let toolbar = NSView()
    toolbar.wantsLayer = true
    toolbar.layer?.backgroundColor = AsterTheme.panel.cgColor
    toolbar.translatesAutoresizingMaskIntoConstraints = false
    toolbar.heightAnchor.constraint(equalToConstant: 36).isActive = true
    let back = ActionButton(symbol: "chevron.left") { [weak self] in self?.goUp() }
    let refresh = ActionButton(symbol: "arrow.clockwise") { [weak self] in self?.reload() }
    let title = makeLabel(directory.lastPathComponent, size: 11, weight: .semibold)
    let row = NSStackView(views: [back, title, NSView(), refresh])
    row.orientation = .horizontal
    row.edgeInsets = NSEdgeInsets(top: 4, left: 9, bottom: 4, right: 9)
    toolbar.addSubview(row)
    row.pinEdges(to: toolbar)
    column.addArrangedSubview(toolbar)

    table.headerView = nil
    table.addTableColumn(NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name")))
    table.dataSource = self
    table.delegate = self
    table.target = self
    table.doubleAction = #selector(openSelected)
    table.backgroundColor = AsterTheme.paper
    let contextMenu = NSMenu()
    contextMenu.delegate = self
    table.menu = contextMenu
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.documentView = table
    column.addArrangedSubview(scroll)
    view = column
    reload()
  }

  func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

  func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
    guard entries.indices.contains(row) else { return nil }
    let url = entries[row]
    let cell = NSTableCellView()
    let directory = isDirectory(url)
    let image = NSImageView(image: NSImage(systemSymbolName: directory ? "folder" : "doc", accessibilityDescription: nil) ?? NSImage())
    image.contentTintColor = directory ? AsterTheme.accent : AsterTheme.secondaryInk
    let label = makeLabel(url.lastPathComponent, size: 11.5)
    let stack = NSStackView(views: [image, label])
    stack.orientation = .horizontal
    stack.spacing = 8
    cell.addSubview(stack)
    stack.pinEdges(to: cell, insets: NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8))
    return cell
  }

  private func reload() {
    do {
      entries = try FileManager.default.contentsOfDirectory(
        at: directory,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
      ).sorted {
        let left = isDirectory($0)
        let right = isDirectory($1)
        return left == right
          ? $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
          : left
      }
    } catch { entries = [] }
    table.reloadData()
  }

  private func goUp() {
    let parent = directory.deletingLastPathComponent()
    guard parent.path != directory.path else { return }
    directory = parent
    reload()
  }

  @objc private func openSelected() {
    guard entries.indices.contains(table.selectedRow) else { return }
    let url = entries[table.selectedRow]
    if isDirectory(url) { directory = url; reload() }
    else { tab?.openFile(url) }
  }

  /// 根据当前右键命中的行动态生成菜单，避免在目录刷新后菜单仍引用失效 URL。
  func menuWillOpen(_ menu: NSMenu) {
    menu.removeAllItems()
    let row = table.clickedRow >= 0 ? table.clickedRow : table.selectedRow
    guard entries.indices.contains(row) else { return }
    table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    let url = entries[row]
    menu.addItem(ActionMenuItem(title: isDirectory(url) ? "打开文件夹" : "打开") { [weak self] in
      self?.openURL(url)
    })
    if !isDirectory(url) {
      menu.addItem(ActionMenuItem(title: "在预览中打开") { [weak self] in
        self?.tab?.openPreview(url)
      })
    }
    menu.addItem(.separator())
    menu.addItem(ActionMenuItem(title: "在 Finder 中显示") {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    })
  }

  private func openURL(_ url: URL) {
    if isDirectory(url) {
      directory = url
      reload()
    } else {
      tab?.openFile(url)
    }
  }

  private func isDirectory(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
  }
}

@MainActor
private final class DetailsPanelViewController: NSViewController {
  private let model: AppModel
  private let preferences: AppPreferences
  private let contentHost = NSView()
  private var selection = 0

  init(model: AppModel, preferences: AppPreferences) {
    self.model = model
    self.preferences = preferences
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let theme = preferences.activeTheme
    let background = ThemeVisualEffectView()
    background.apply(
      material: theme.palette.material,
      tint: theme.palette.panelBackground
    )
    let column = NSStackView()
    column.orientation = .vertical
    column.spacing = 0
    let selector = NSSegmentedControl(
      labels: ["信息", "大纲", "Git"],
      trackingMode: .selectOne,
      target: self,
      action: #selector(changeSection(_:))
    )
    selector.selectedSegment = selection
    let selectorHost = NSView()
    selectorHost.addSubview(selector)
    selector.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      selector.leadingAnchor.constraint(equalTo: selectorHost.leadingAnchor, constant: 10),
      selector.trailingAnchor.constraint(equalTo: selectorHost.trailingAnchor, constant: -10),
      selector.centerYAnchor.constraint(equalTo: selectorHost.centerYAnchor),
      selectorHost.heightAnchor.constraint(equalToConstant: 48),
    ])
    column.addArrangedSubview(selectorHost)
    column.addArrangedSubview(contentHost)
    background.addSubview(column)
    column.pinEdges(to: background)
    view = background
    reloadContent()
  }

  @objc private func changeSection(_ sender: NSSegmentedControl) {
    selection = max(sender.selectedSegment, 0)
    reloadContent()
  }

  /// 详情、大纲与 Git 共享同一原生容器，只替换内容视图，切换时不会重建右侧面板。
  private func reloadContent() {
    contentHost.removeAllSubviews()
    let content: NSView
    switch selection {
    case 1: content = makeOutlineContent()
    case 2: content = makeGitContent()
    default: content = makeInformationContent()
    }
    contentHost.addSubview(content)
    content.pinEdges(to: contentHost)
  }

  private func makeInformationContent() -> NSView {
    let info = NSStackView()
    info.orientation = .vertical
    info.alignment = .leading
    info.spacing = 16
    let tab = model.selectedTab
    info.addArrangedSubview(makeInfo("标签", tab?.title ?? "—"))
    info.addArrangedSubview(makeInfo("目录", tab?.workingDirectory ?? "—"))
    info.addArrangedSubview(makeInfo("面板", "\(tab?.layout.allPanes.count ?? 0)"))
    info.addArrangedSubview(makeInfo("终端", "xterm-256color"))
    return makeScrollableContent(info)
  }

  private func makeOutlineContent() -> NSView {
    let outline = NSStackView()
    outline.orientation = .vertical
    outline.alignment = .leading
    outline.spacing = 10
    outline.addArrangedSubview(makeLabel("工作区结构", size: 10, weight: .semibold, color: AsterTheme.tertiaryInk))
    for (index, pane) in (model.selectedTab?.layout.allPanes ?? []).enumerated() {
      let presentation: (symbol: String, title: String) = switch pane.kind {
      case .terminal: ("terminal", "终端")
      case .editor: ("doc.text", "编辑器")
      case .preview: ("eye", "预览")
      case .fileBrowser: ("folder", "文件浏览器")
      }
      let image = NSImageView(image: NSImage(systemSymbolName: presentation.symbol, accessibilityDescription: nil) ?? NSImage())
      image.contentTintColor = AsterTheme.secondaryInk
      let row = NSStackView(views: [image, makeLabel("Pane \(index + 1) · \(presentation.title)", size: 11)])
      row.orientation = .horizontal
      row.spacing = 8
      outline.addArrangedSubview(row)
    }
    return makeScrollableContent(outline)
  }

  private func makeGitContent() -> NSView {
    let message = makeLabel("在终端中使用 Git\n完整保留你现有的命令行工作流。", size: 11, color: AsterTheme.secondaryInk)
    message.alignment = .center
    message.maximumNumberOfLines = 2
    message.lineBreakMode = .byWordWrapping
    let host = NSView()
    host.addSubview(message)
    message.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      message.centerXAnchor.constraint(equalTo: host.centerXAnchor),
      message.centerYAnchor.constraint(equalTo: host.centerYAnchor),
      message.leadingAnchor.constraint(greaterThanOrEqualTo: host.leadingAnchor, constant: 18),
      message.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -18),
    ])
    return host
  }

  private func makeScrollableContent(_ stack: NSStackView) -> NSView {
    stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    scroll.documentView = stack
    stack.translatesAutoresizingMaskIntoConstraints = false
    stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor).isActive = true
    return scroll
  }

  private func makeInfo(_ title: String, _ value: String) -> NSView {
    let stack = NSStackView(views: [
      makeLabel(title.uppercased(), size: 9, weight: .semibold, color: AsterTheme.tertiaryInk),
      makeLabel(value, size: 11),
    ])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 4
    return stack
  }
}

@MainActor
private final class PaletteOverlayViewController: NSViewController, NSSearchFieldDelegate {
  private let model: AppModel
  private let stack = NSStackView()
  private let search = NSSearchField()

  init(model: AppModel) {
    self.model = model
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let host = NSView()
    host.wantsLayer = true
    host.layer?.backgroundColor = AsterTheme.panel.withAlphaComponent(0.98).cgColor
    host.layer?.cornerRadius = 12
    host.layer?.borderWidth = 1
    host.layer?.borderColor = AsterTheme.hairline.cgColor
    host.shadow = NSShadow()
    host.shadow?.shadowBlurRadius = 24
    host.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.22)
    stack.orientation = .vertical
    stack.spacing = 6
    stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    search.placeholderString = "输入命令或操作…"
    search.delegate = self
    stack.addArrangedSubview(search)
    host.addSubview(stack)
    stack.pinEdges(to: host)
    view = host
    reload()
    DispatchQueue.main.async { [weak search] in search?.window?.makeFirstResponder(search) }
  }

  func controlTextDidChange(_ obj: Notification) { reload() }

  private func reload() {
    while stack.arrangedSubviews.count > 1 {
      stack.arrangedSubviews.last?.removeFromSuperview()
    }
    let commands = CommandPalette.filter(model.paletteCommands, query: search.stringValue)
    for command in commands.prefix(9) {
      let button = ActionButton(title: command.title, bezelStyle: .inline) { [weak self] in
        self?.model.performPaletteCommand(command)
      }
      button.alignment = .left
      button.isBordered = false
      button.contentTintColor = AsterTheme.ink
      button.translatesAutoresizingMaskIntoConstraints = false
      button.heightAnchor.constraint(equalToConstant: 34).isActive = true
      stack.addArrangedSubview(button)
    }
  }
}

private extension NSView {
  func addTopBorder(color: NSColor) {
    let border = NSView()
    border.wantsLayer = true
    border.layer?.backgroundColor = color.cgColor
    addSubview(border)
    border.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      border.leadingAnchor.constraint(equalTo: leadingAnchor),
      border.trailingAnchor.constraint(equalTo: trailingAnchor),
      border.topAnchor.constraint(equalTo: topAnchor),
      border.heightAnchor.constraint(equalToConstant: 1),
    ])
  }

  func addBottomBorder(color: NSColor) {
    let border = NSView()
    border.wantsLayer = true
    border.layer?.backgroundColor = color.cgColor
    addSubview(border)
    border.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      border.leadingAnchor.constraint(equalTo: leadingAnchor),
      border.trailingAnchor.constraint(equalTo: trailingAnchor),
      border.bottomAnchor.constraint(equalTo: bottomAnchor),
      border.heightAnchor.constraint(equalToConstant: 1),
    ])
  }
}
