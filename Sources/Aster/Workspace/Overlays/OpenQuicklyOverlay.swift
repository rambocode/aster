import AppKit
import AsterCore
import Combine

/// Open Quickly 浮层的搜索、筛选和结果行组件。

@MainActor
final class OpenQuicklyBackdropView: NSView {
  private let dismiss: () -> Void

  init(dismiss: @escaping () -> Void) {
    self.dismiss = dismiss
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = NSColor.black.withAlphaComponent(0.055).cgColor
    identifier = NSUserInterfaceItemIdentifier("open-quickly-backdrop")
    setAccessibilityElement(true)
    setAccessibilityLabel("关闭 Open Quickly")
  }

  required init?(coder: NSCoder) { nil }

  override func mouseDown(with event: NSEvent) { dismiss() }
  override func rightMouseDown(with event: NSEvent) { dismiss() }
  override func otherMouseDown(with event: NSEvent) { dismiss() }
}

/// 只在真正的搜索框范围保留 I-beam，面板其余区域显式使用普通箭头。
/// AppKit 在 borderless 搜索框上偶尔会留下过大的 cursor rect，四个外围矩形
/// 能在不干扰搜索框文本定位的前提下覆盖它。
@MainActor
final class OpenQuicklyPanelView: NSView {
  weak var searchInputView: NSView?

  override func resetCursorRects() {
    super.resetCursorRects()
    guard let searchInputView else {
      addCursorRect(bounds, cursor: .arrow)
      return
    }
    let searchRect = convert(searchInputView.bounds, from: searchInputView)
      .intersection(bounds)
    let rects = [
      NSRect(
        x: bounds.minX, y: bounds.minY, width: searchRect.minX - bounds.minX,
        height: bounds.height),
      NSRect(
        x: searchRect.maxX, y: bounds.minY, width: bounds.maxX - searchRect.maxX,
        height: bounds.height),
      NSRect(
        x: searchRect.minX, y: bounds.minY, width: searchRect.width,
        height: searchRect.minY - bounds.minY),
      NSRect(
        x: searchRect.minX, y: searchRect.maxY, width: searchRect.width,
        height: bounds.maxY - searchRect.maxY),
    ]
    for rect in rects where rect.width > 0 && rect.height > 0 {
      addCursorRect(rect, cursor: .arrow)
    }
  }
}

/// Open Quickly 浮层:标签条过滤 + 双行结果列表(图标/相对时间/类型徽章)+ 底部
/// 快捷键栏。数据与匹配在 AsterCore 的 OpenQuicklyIndex,这里只负责展示与动作接线。
@MainActor
final class OpenQuicklyOverlayViewController: NSViewController, NSSearchFieldDelegate {
  /// 可跳转目标:action 是 ↩ 主动作,menuActions 供 ⌘K 弹出的上下文菜单。
  private struct Target {
    let item: OpenQuicklyItem
    let symbol: String
    let badge: String
    /// 运行中的命令行用 accent 图标突出,其余保持 secondaryInk。
    let accented: Bool
    let actionTitle: String
    let action: () -> Void
    var menuActions: [(title: String, handler: () -> Void)] = []
  }

  private let model: AppModel
  private let resultsStack = NSStackView()
  /// `NSScrollView` 不会把 documentView 的固有高度传给外层 NSStackView，因此由结果
  /// 内容显式驱动高度；否则数据和行都已创建时，滚动区仍可能被压缩成 0。
  private var resultsHeightConstraint: NSLayoutConstraint?
  private let search = OverlaySearchField()
  private var chips: [OpenQuicklyFilter: OpenQuicklyChip] = [:]
  private var selectedFilter: OpenQuicklyFilter
  private var targets: [Target] = []
  private var targetsByID: [String: Target] = [:]
  private var searchIndex = OpenQuicklyIndex(items: [])
  private var visibleTargets: [Target] = []
  /// 顶部过滤器和搜索输入复用可见行，避免每次点击都创建几十个 NSView 与约束。
  private var rowPool: [OpenQuicklyRowView] = []
  private var rows: [OpenQuicklyRowView] = []
  private var selectedIndex = 0
  private var historyCancellable: AnyCancellable?
  private var targetsNeedRefresh = true
  private var showsCommandHints = false
  /// 浮层事件监视只在展示期间存活；关闭后立即移除，避免拦截终端的
  /// `⌘W` / `⌘R` 等既有快捷键。`deinit` 是 nonisolated，因此句柄标为 unsafe。
  private nonisolated(unsafe) var overlayEventMonitor: Any?

  init(model: AppModel) {
    self.model = model
    self.selectedFilter = model.openQuicklyInitialFilter
    super.init(nibName: nil, bundle: nil)
    historyCancellable = model.agentHistoriesChanged.sink { [weak self] _ in
      guard let self, self.isViewLoaded else { return }
      self.rebuildTargets()
      self.reload()
    }
  }

  required init?(coder: NSCoder) { nil }

  deinit {
    if let overlayEventMonitor { NSEvent.removeMonitor(overlayEventMonitor) }
  }

  override func loadView() {
    let host = OpenQuicklyPanelView()
    host.wantsLayer = true
    host.layer?.backgroundColor = AsterTheme.panel.withAlphaComponent(0.99).cgColor
    host.layer?.cornerRadius = 16
    host.layer?.borderWidth = 1
    host.layer?.borderColor = AsterTheme.hairline.withAlphaComponent(0.90).cgColor
    host.layer?.shadowColor = NSColor.black.cgColor
    host.layer?.shadowOpacity = 0.22
    host.layer?.shadowRadius = 24
    host.layer?.shadowOffset = CGSize(width: 0, height: -10)
    host.layer?.masksToBounds = false
    host.identifier = NSUserInterfaceItemIdentifier("open-quickly-overlay")

    search.placeholderString = "搜索命令、URL、文件…"
    search.identifier = NSUserInterfaceItemIdentifier("open-quickly-search")
    // 保留 NSSearchField 的搜索图标、IME 和文本编辑能力，只去掉会形成蓝色
    // 长条的系统 bezel/focus ring；插入光标仍清晰表示输入焦点。
    search.isBezeled = false
    search.drawsBackground = false
    search.focusRingType = .none
    search.cell?.focusRingType = .none
    // Borderless `NSSearchFieldCell` 的默认 icon/text rect 在不同 macOS 外观下并不一致。
    // 不覆写 cell 的局部坐标；改为移除内部 icon、将输入控件整体放在显式图标右侧，确保
    // placeholder、正在编辑文本和 IME 候选都共享同一个真实可输入区域。
    (search.cell as? NSSearchFieldCell)?.searchButtonCell = nil
    search.font = NSFont.systemFont(ofSize: 15)
    search.translatesAutoresizingMaskIntoConstraints = false
    search.heightAnchor.constraint(equalToConstant: 36).isActive = true
    search.setContentHuggingPriority(.required, for: .vertical)
    search.setContentCompressionResistancePriority(.required, for: .vertical)
    search.delegate = self
    search.onMove = { [weak self] delta in self?.moveSelection(delta) }
    search.onActivate = { [weak self] _ in self?.activateSelection() }
    search.onCancel = { [weak model] in model?.isOpenQuicklyPresented = false }
    search.onQuickSelect = { [weak self] digit in self?.quickSelect(digit) }
    search.onShowActions = { [weak self] in self?.showActionsMenu() }
    let searchRow = NSView()
    searchRow.identifier = NSUserInterfaceItemIdentifier("open-quickly-search-row")
    let searchIcon = NSImageView()
    searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "搜索")
    // 图标本身可能包含不同主题/系统版本的透明留白；显式按 16pt 槽位居中和等比缩放，
    // 避免默认 image alignment 让视觉中心偏向 placeholder 的基线。
    searchIcon.imageAlignment = .alignCenter
    searchIcon.imageScaling = .scaleProportionallyDown
    searchIcon.contentTintColor = AsterTheme.secondaryInk
    searchIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
    searchIcon.identifier = NSUserInterfaceItemIdentifier("open-quickly-search-icon")
    searchIcon.translatesAutoresizingMaskIntoConstraints = false
    searchRow.addSubview(searchIcon)
    searchRow.addSubview(search)
    NSLayoutConstraint.activate([
      searchIcon.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor, constant: 8),
      searchIcon.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
      searchIcon.widthAnchor.constraint(equalToConstant: 16),
      searchIcon.heightAnchor.constraint(equalToConstant: 16),
      search.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor, constant: 32),
      search.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor),
      search.topAnchor.constraint(equalTo: searchRow.topAnchor),
      search.bottomAnchor.constraint(equalTo: searchRow.bottomAnchor),
    ])
    host.searchInputView = searchRow

    let column = NSStackView()
    column.orientation = .vertical
    column.alignment = .width
    column.spacing = 8
    column.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 10, right: 14)
    let filterStrip = makeFilterStrip()
    let resultsScroll = makeResultsScroll()
    let separator = makeSeparator()
    let footer = makeFooter()
    let fullWidthViews = [searchRow, filterStrip, resultsScroll, separator, footer]
    for arrangedView in fullWidthViews {
      column.addArrangedSubview(arrangedView)
      arrangedView.translatesAutoresizingMaskIntoConstraints = false
      arrangedView.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -28).isActive =
        true
    }
    host.addSubview(column)
    column.pinEdges(to: host)
    view = host
    rebuildTargets()
    reload()
  }

  /// 展示边界安装本地事件监视。使用 local monitor 而不是仅覆写搜索框
  /// `keyDown`，因为 AppKit 会在 first responder 之前处理 `⌘W` 等菜单等价键。
  func didPresent() {
    setCommandHintsVisible(NSEvent.modifierFlags.contains(.command))
    if let window = view.window {
      // 浮层打开后立即进入搜索；`initialFirstResponder` 同时覆盖窗口恰在激活过程中的
      // 展示路径。首次同步请求发生在挂载边界，field editor 可能还没准备好；下一轮
      // 主循环必须重试一次，真实 key window 才会稳定把输入交给搜索框。
      window.initialFirstResponder = search
      window.makeFirstResponder(search)
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self, let window,
          self.model.isOpenQuicklyPresented,
          self.view.window === window
        else { return }
        window.makeFirstResponder(self.search)
        self.search.selectText(nil)
      }
    }
    guard overlayEventMonitor == nil else { return }
    overlayEventMonitor = NSEvent.addLocalMonitorForEvents(
      matching: [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] event in
      guard let self else { return event }
      return self.handleOverlayEvent(event)
    }
  }

  /// 关闭时同步清除监视和可见提示，重开时不会泄漏上一次 modifier 状态。
  func didDismiss() {
    if view.window?.initialFirstResponder === search {
      view.window?.initialFirstResponder = nil
    }
    if let overlayEventMonitor {
      NSEvent.removeMonitor(overlayEventMonitor)
      self.overlayEventMonitor = nil
    }
    setCommandHintsVisible(false)
  }

  private func handleOverlayEvent(_ event: NSEvent) -> NSEvent? {
    if [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type) {
      guard let window = view.window, event.window === window else { return event }
      let isInside = containsWindowPoint(event.locationInWindow)
      if !isInside {
        model.isOpenQuicklyPresented = false
      }
      return event
    }
    let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    if event.type == .flagsChanged {
      setCommandHintsVisible(modifiers.contains(.command))
      return event
    }
    guard event.type == .keyDown else { return event }
    if event.keyCode == 53 {
      model.isOpenQuicklyPresented = false
      return nil
    }
    guard modifiers.contains(.command),
      !modifiers.contains(.option), !modifiers.contains(.control), !modifiers.contains(.shift),
      let character = event.charactersIgnoringModifiers?.lowercased()
    else { return event }
    let shortcuts: [String: OpenQuicklyFilter] = [
      "0": .all, "w": .opened, "r": .recent, "z": .folder,
      "s": .ssh, "g": .agent, "j": .current, "e": .recipe,
    ]
    guard let filter = shortcuts[character] else { return event }
    selectFilter(filter)
    return nil
  }

  /// 以 window 的真实命中视图作为内外点击真值。直接比较 window 坐标矩形在
  /// full-size content window 中可能受标题栏坐标转换影响，把可见搜索框误判为外部。
  /// NSSearchField 编辑期间使用 window 共享的 field editor，它不在浮层子树中，
  /// 因此需要把当前 editor 也视为搜索框内部命中。
  func containsWindowPoint(_ point: NSPoint) -> Bool {
    guard let window = view.window,
      let hitView = window.contentView?.hitTest(point)
    else { return false }
    if let editor = search.currentEditor(),
      hitView === editor || hitView.isDescendant(of: editor)
    { return true }
    return hitView === view || hitView.isDescendant(of: view)
  }

  /// 重开缓存浮层时恢复初始过滤器和空查询。目标只在展示边界更新；过滤器切换和逐字
  /// 搜索只访问内存索引，不重复读取 SSH config、Recipes 或 Agent 历史。
  func prepareForPresentation(filter: OpenQuicklyFilter, refreshesTargets: Bool) {
    selectedFilter = filter
    guard isViewLoaded else { return }
    search.stringValue = ""
    for (key, chip) in chips { chip.isChipSelected = key == filter }
    if refreshesTargets || targetsNeedRefresh { rebuildTargets() }
    selectedIndex = 0
    reload()
  }

  private func rebuildTargets() {
    targets = makeTargets()
    targetsByID = Dictionary(uniqueKeysWithValues: targets.map { ($0.item.id, $0) })
    searchIndex = OpenQuicklyIndex(items: targets.map(\.item))
    targetsNeedRefresh = false
  }

  func invalidateTargets() { targetsNeedRefresh = true }

#if DEBUG
  /// Test seam for verifying that Prompt history remains actionable when no Agent CLI is active.
  var promptTargetIDsForTesting: [String] {
    targets.map(\.item.id).filter { $0.hasPrefix("prompt:") }
  }

  /// Executes the same target closure used by Return/click without depending on row hit testing.
  func activateTargetForTesting(id: String) {
    targetsByID[id]?.action()
  }
#endif

  /// 顶部分类标签条:替代原 NSPopUpButton,与参考设计一致。
  private func makeFilterStrip() -> NSView {
    let strip = NSStackView()
    strip.orientation = .horizontal
    strip.spacing = 4
    let titles: [OpenQuicklyFilter: String] = [
      .all: "全部", .opened: "已打开", .recent: "最近", .folder: "文件夹",
      .ssh: "SSH", .agent: "智能体", .current: "当前", .recipe: "Recipes",
    ]
    for filter in OpenQuicklyFilter.allCases {
      let chip = OpenQuicklyChip(
        title: titles[filter] ?? filter.rawValue,
        commandHint: Self.commandHint(for: filter)
      ) { [weak self] in
        self?.selectFilter(filter)
      }
      chip.identifier = NSUserInterfaceItemIdentifier("open-quickly-chip-\(filter.rawValue)")
      chip.isChipSelected = filter == selectedFilter
      chips[filter] = chip
      strip.addArrangedSubview(chip)
    }
    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    strip.addArrangedSubview(spacer)
    return strip
  }

  /// 快捷键与用户按住 ⌘ 时 chip 下方的动态提示保持同一数据源。
  private static func commandHint(for filter: OpenQuicklyFilter) -> String {
    switch filter {
    case .all: "⌘0"
    case .opened: "⌘W"
    case .recent: "⌘R"
    case .folder: "⌘Z"
    case .ssh: "⌘S"
    case .agent: "⌘G"
    case .current: "⌘J"
    case .recipe: "⌘E"
    }
  }

  /// 结果区滚动容器:内容不足时收缩,超出 400pt 滚动;沿用详情面板的顶部锚定模式。
  private func makeResultsScroll() -> NSView {
    resultsStack.orientation = .vertical
    resultsStack.alignment = .width
    resultsStack.spacing = 2
    resultsStack.identifier = NSUserInterfaceItemIdentifier("open-quickly-results")
    let scroll = NSScrollView()
    scroll.drawsBackground = false
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    let document = FlippedDocumentView()
    document.addSubview(resultsStack)
    scroll.documentView = document
    resultsStack.translatesAutoresizingMaskIntoConstraints = false
    document.translatesAutoresizingMaskIntoConstraints = false
    scroll.translatesAutoresizingMaskIntoConstraints = false
    let heightConstraint = scroll.heightAnchor.constraint(equalToConstant: 1)
    resultsHeightConstraint = heightConstraint
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
      resultsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      resultsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      resultsStack.topAnchor.constraint(equalTo: document.topAnchor),
      document.bottomAnchor.constraint(greaterThanOrEqualTo: resultsStack.bottomAnchor),
      heightConstraint,
    ])
    return scroll
  }

  /// 按当前 arrangedSubviews 的真实 fitting height 更新滚动区，最多展示 400pt；超出
  /// 部分继续由 NSScrollView 滚动。最小 1pt 避免空内容造成不确定的零高约束。
  private func updateResultsHeight() {
    resultsStack.needsLayout = true
    resultsStack.layoutSubtreeIfNeeded()
    let contentHeight = ceil(resultsStack.fittingSize.height)
    resultsHeightConstraint?.constant = min(400, max(1, contentHeight))
  }

  private func makeSeparator() -> NSView {
    let line = NSView()
    line.wantsLayer = true
    line.layer?.backgroundColor = AsterTheme.hairline.cgColor
    line.translatesAutoresizingMaskIntoConstraints = false
    line.heightAnchor.constraint(equalToConstant: 1).isActive = true
    return line
  }

  /// 底部快捷键栏:左 Quick Select 提示,右「跳转到 ↩」与「操作 ⌘K」按钮。
  private func makeFooter() -> NSView {
    let quickSelect = makeLabel("Quick Select ⌘1–9", size: 10, color: AsterTheme.tertiaryInk)
    let jump = makeLabel("跳转到 ↩", size: 10, color: AsterTheme.tertiaryInk)
    let actions = ActionButton(title: "操作 ⌘K", bezelStyle: .inline) { [weak self] in
      self?.showActionsMenu()
    }
    actions.font = NSFont.systemFont(ofSize: 10)
    let row = NSStackView(views: [quickSelect, NSView(), jump, actions])
    row.orientation = .horizontal
    row.spacing = 8
    return row
  }

  private func selectFilter(_ filter: OpenQuicklyFilter) {
    guard filter != selectedFilter else { return }
    selectedFilter = filter
    for (key, chip) in chips { chip.isChipSelected = key == filter }
    selectedIndex = 0
    reload()
  }

  func controlTextDidChange(_ obj: Notification) {
    selectedIndex = 0
    reload()
  }

  private func reload() {
    for row in rows { row.detachFromResultsStack() }
    for view in resultsStack.arrangedSubviews { view.removeFromSuperview() }
    let items = searchIndex.search(
      query: search.stringValue,
      filter: selectedFilter,
      maximumResults: 50
    )
    visibleTargets = items.compactMap { targetsByID[$0.id] }
    rows.removeAll()
    if visibleTargets.isEmpty {
      resultsStack.addArrangedSubview(
        makeLabel("没有匹配项", size: 11, color: AsterTheme.secondaryInk))
      updateResultsHeight()
      return
    }
    // 多类型视图(.all / .current)按 kind 分组并显示小节标题;单类型过滤器下
    // 标签条已说明类型,不再重复标题。
    let showHeaders = selectedFilter == .all || selectedFilter == .current
    for section in OpenQuicklyIndex.sections(for: items) {
      if showHeaders {
        let header = makeLabel(
          Self.sectionTitle(for: section.kind), size: 10, weight: .semibold,
          color: AsterTheme.tertiaryInk)
        header.alignment = .left
        header.translatesAutoresizingMaskIntoConstraints = false
        let wrapper = NSView()
        wrapper.addSubview(header)
        header.pinEdges(to: wrapper, insets: NSEdgeInsets(top: 6, left: 4, bottom: 2, right: 4))
        resultsStack.addArrangedSubview(wrapper)
      }
      for item in section.items {
        guard let target = targetsByID[item.id] else { continue }
        let rowIndex = rows.count
        let row: OpenQuicklyRowView
        if rowPool.indices.contains(rowIndex) {
          row = rowPool[rowIndex]
        } else {
          row = OpenQuicklyRowView()
          rowPool.append(row)
        }
        row.configure(
          item: item, symbol: target.symbol, badge: target.badge,
          accented: target.accented
        ) { [weak self] in
          guard let self,
            let index = self.visibleTargets.firstIndex(where: {
              $0.item.id == item.id
            })
          else { return }
          self.selectedIndex = index
          self.activateSelection()
        }
        resultsStack.addArrangedSubview(row)
        row.attach(to: resultsStack)
        rows.append(row)
      }
    }
    updateResultsHeight()
    selectedIndex = min(selectedIndex, rows.count - 1)
    updateCommandHintAppearance()
    updateSelectionAppearance()
  }

  /// 小节标题与徽章文案共用同一套中文映射。
  private static func sectionTitle(for kind: OpenQuicklyKind) -> String {
    switch kind {
    case .opened: "已打开"
    case .current: "当前"
    case .prompt: "提示词"
    case .recent: "最近"
    case .folder: "文件夹"
    case .ssh: "SSH"
    case .agent: "智能体"
    case .recipe: "Recipes"
    }
  }

  private func moveSelection(_ delta: Int) {
    guard !rows.isEmpty else { return }
    selectedIndex = (selectedIndex + delta + rows.count) % rows.count
    updateSelectionAppearance()
  }

  /// ⌘1…9 按可见顺序(跨小节连续编号)直接激活对应行。
  private func quickSelect(_ digit: Int) {
    let index = digit - 1
    guard visibleTargets.indices.contains(index) else { return }
    selectedIndex = index
    updateSelectionAppearance()
    activateSelection()
  }

  private func activateSelection() {
    guard visibleTargets.indices.contains(selectedIndex) else { return }
    visibleTargets[selectedIndex].action()
  }

  /// ⌘K / 底部按钮:弹出选中行的操作菜单,首项是主动作,其余为 kind 附加动作。
  private func showActionsMenu() {
    guard visibleTargets.indices.contains(selectedIndex),
      rows.indices.contains(selectedIndex)
    else { return }
    let target = visibleTargets[selectedIndex]
    let menu = NSMenu()
    menu.addItem(ActionMenuItem(title: target.actionTitle) { target.action() })
    if !target.menuActions.isEmpty {
      menu.addItem(.separator())
      for entry in target.menuActions {
        menu.addItem(ActionMenuItem(title: entry.title) { entry.handler() })
      }
    }
    let row = rows[selectedIndex]
    menu.popUp(
      positioning: nil,
      at: NSPoint(x: row.bounds.maxX - 24, y: row.bounds.midY),
      in: row)
  }

  private func updateSelectionAppearance() {
    for (index, row) in rows.enumerated() {
      row.isRowSelected = index == selectedIndex
    }
  }

  /// 修饰键变化只更新已复用的 chip/行外观，不重做搜索或创建视图。
  private func setCommandHintsVisible(_ visible: Bool) {
    guard showsCommandHints != visible else { return }
    showsCommandHints = visible
    for chip in chips.values { chip.showsCommandHint = visible }
    updateCommandHintAppearance()
  }

  private func updateCommandHintAppearance() {
    for (index, row) in rows.enumerated() {
      row.setCommandHint(index < 9 ? "⌘\(index + 1)" : nil, visible: showsCommandHints)
    }
  }

  /// 构建全部候选目标。每类目标的 symbol/badge/菜单在创建时确定,reload 只做过滤。
  private func makeTargets() -> [Target] {
    var result: [Target] = []
    for tab in model.tabs {
      result.append(
        Target(
          item: .init(
            id: "opened:\(tab.id.uuidString)", kind: .opened, title: tab.title,
            detail: tab.workingDirectory),
          symbol: "macwindow", badge: "标签", accented: false, actionTitle: "跳转到标签"
        ) { [weak model, weak tab] in
          guard let tab else { return }
          model?.select(tab)
          model?.isOpenQuicklyPresented = false
        })
      result[result.count - 1].menuActions = [
        (
          title: "关闭标签",
          handler: { [weak model, weak tab] in
            guard let tab else { return }
            model?.select(tab)
            model?.isOpenQuicklyPresented = false
            model?.closeSelectedTab()
          }
        )
      ]
    }
    if let current = model.selectedTab {
      for (index, pane) in current.layout.allPanes.enumerated() {
        let session = current.runtime(for: pane.id)?.terminalSession
        let command = session?.foregroundCommandName
        // 运行中的前台命令(如 kimi)直接显示命令名;关联时间取同 provider 最新会话。
        let matchedHistory: AgentSessionHistory? = session?.activeAgentProvider.flatMap {
          provider in
          model.agentHistories
            .filter { $0.metadata.configuration.provider == provider }
            .max { $0.metadata.updatedAt < $1.metadata.updatedAt }
        }
        result.append(
          Target(
            item: .init(
              id: "current:\(current.id.uuidString):\(pane.id.uuidString)", kind: .current,
              title: command ?? "Pane \(index + 1) · \(pane.kind.rawValue)",
              detail: pane.workingDirectory,
              timestamp: matchedHistory?.metadata.updatedAt),
            symbol: pane.kind == .terminal ? "terminal" : "doc.text",
            badge: command != nil ? "Cmd" : "Pane",
            accented: command != nil, actionTitle: "聚焦 Pane"
          ) { [weak model, weak current] in
            guard let current else { return }
            model?.revealWorkspaceLocation(tabID: current.id, paneID: pane.id)
          })
      }
      result.append(contentsOf: makePromptTargets(tab: current))
    }
    for snapshot in model.recentlyClosedSnapshots {
      let directory = snapshot.layout.allPanes.first?.workingDirectory ?? ""
      result.append(
        Target(
          item: .init(
            id: "recent:\(snapshot.id.uuidString)", kind: .recent, title: snapshot.title,
            detail: directory),
          symbol: "clock.arrow.circlepath", badge: "最近", accented: false,
          actionTitle: "恢复标签"
        ) { [weak model] in _ = model?.reopenClosedTab(id: snapshot.id) })
    }
    for match in model.frequentFolderMatches(limit: 200) {
      result.append(
        Target(
          item: .init(
            id: "folder:\(match.path)", kind: .folder,
            title: URL(fileURLWithPath: match.path).lastPathComponent,
            detail: match.path, score: match.score),
          symbol: "folder", badge: "文件夹", accented: false, actionTitle: "新建标签"
        ) { [weak model] in model?.newTab(workingDirectory: match.path, hasContent: true) })
      result[result.count - 1].menuActions = [
        (
          title: "在 Finder 中显示",
          handler: { [weak model] in
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: match.path)
            model?.isOpenQuicklyPresented = false
          }
        )
      ]
    }
    for host in readSSHHosts() {
      result.append(
        Target(
          item: .init(
            id: "ssh:\(host.alias)", kind: .ssh, title: host.alias, detail: host.destination),
          symbol: "network", badge: "SSH", accented: false, actionTitle: "连接"
        ) { [weak model] in model?.openSSHHost(host) })
    }
    for provider in model.enabledAgentProviders {
      result.append(
        Target(
          item: .init(
            id: "agent-launch:\(provider.rawValue)",
            kind: .agent,
            title: "启动 \(provider.commandName)",
            detail: "在当前目录创建新的 Agent 会话"
          ),
          symbol: "sparkles", badge: "Agent", accented: false, actionTitle: "启动"
        ) { [weak model] in model?.launchAgent(provider) })
    }
    for history in model.agentHistories.prefix(500) {
      let metadata = history.metadata
      result.append(
        Target(
          item: .init(
            id: "agent:\(metadata.configuration.provider.rawValue):\(metadata.id)",
            kind: .agent,
            title: metadata.title,
            detail: "\(metadata.configuration.provider.commandName) · \(metadata.projectDirectory)",
            timestamp: metadata.updatedAt
          ),
          symbol: "bubble.left.and.bubble.right", badge: "会话", accented: false,
          actionTitle: "继续会话"
        ) { [weak model] in model?.continueAgentSession(metadata, kind: .resume) })
      result[result.count - 1].menuActions = [
        (
          title: "Fork 会话",
          handler: { [weak model] in model?.continueAgentSession(metadata, kind: .fork) }
        )
      ]
    }
    for url in readRecipeURLs() {
      result.append(
        Target(
          item: .init(
            id: "recipe:\(url.path)", kind: .recipe,
            title: url.deletingPathExtension().lastPathComponent, detail: url.path),
          symbol: "doc.text", badge: "Recipe", accented: false, actionTitle: "打开 Recipe"
        ) { [weak model] in model?.openRecipe(from: url) })
      result[result.count - 1].menuActions = [
        (
          title: "在 Finder 中显示",
          handler: { [weak model] in
            NSWorkspace.shared.selectFile(
              url.lastPathComponent,
              inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
            model?.isOpenQuicklyPresented = false
          }
        )
      ]
    }
    return result
  }

  /// 「当前」页的提示词分组：pane ↔ session 没有可靠映射（metadata 不含 tty/pid）。
  /// 有运行中的 Agent 时沿用同 provider 最新历史并优先写回对应 Pane；没有 Agent 时，
  /// 使用全部 provider 中最近的历史，并把 Prompt 写入当前可用终端。历史 Prompt 因而
  /// 是通用终端输入能力，不依赖前台恰好运行 Codex、Claude Code 等 Agent CLI。
  private func makePromptTargets(tab: TerminalTabItem) -> [Target] {
    let terminalPanes = tab.layout.allPanes.compactMap {
      pane -> (paneID: UUID, provider: AgentProvider?)? in
      guard let session = tab.runtime(for: pane.id)?.terminalSession else { return nil }
      return (pane.id, session.activeAgentProvider)
    }
    guard let activeTerminal = terminalPanes.first(where: { $0.paneID == tab.activePaneID })
      ?? terminalPanes.first
    else { return [] }
    let agentTerminal = terminalPanes.first {
      $0.paneID == tab.activePaneID && $0.provider != nil
    } ?? terminalPanes.first { $0.provider != nil }
    let destination = agentTerminal ?? activeTerminal
    let candidateHistories: [AgentSessionHistory]
    if let provider = agentTerminal?.provider {
      candidateHistories = model.agentHistories.filter {
        $0.metadata.configuration.provider == provider
      }
    } else {
      candidateHistories = model.agentHistories
    }
    guard let history = candidateHistories.max(by: {
      $0.metadata.updatedAt < $1.metadata.updatedAt
    }) else { return [] }
    let prompts = history.transcript.entries.filter {
      if case .message(role: .user) = $0.kind { return !$0.text.isEmpty }
      return false
    }.suffix(6)
    return prompts.reversed().map { entry in
      let collapsed = entry.text
        .components(separatedBy: .whitespacesAndNewlines)
        .filter { !$0.isEmpty }
        .joined(separator: " ")
      var target = Target(
        item: .init(
          id: "prompt:\(history.metadata.id):\(entry.sourceRecordIndex)", kind: .prompt,
          title: collapsed, detail: history.metadata.title, timestamp: entry.timestamp),
        symbol: "quote.bubble", badge: "Prompt", accented: false, actionTitle: "粘贴到终端"
      ) { [weak model] in
        model?.insertPromptIntoPane(tabID: tab.id, paneID: destination.paneID, text: entry.text)
      }
      target.menuActions = [
        (
          title: "复制到剪贴板",
          handler: { [weak model] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.text, forType: .string)
            model?.isOpenQuicklyPresented = false
          }
        )
      ]
      return target
    }
  }

  private func readSSHHosts() -> [SSHHost] {
    let url = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent(".ssh/config")
    guard let text = readRegularTextFile(url, maximumBytes: 1 * 1_024 * 1_024) else { return [] }
    return SSHConfigParser.parse(text)
  }

  private func readRecipeURLs() -> [URL] {
    let root = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Application Support/Aster/Recipes", isDirectory: true)
    guard
      let entries = try? FileManager.default.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: [.skipsHiddenFiles, .skipsPackageDescendants]
      )
    else { return [] }
    return entries.filter { url in
      guard ["asterrecipe", "ottyrecipe"].contains(url.pathExtension.lowercased()),
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      else { return false }
      return values.isRegularFile == true && values.isSymbolicLink != true
    }.sorted {
      $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending
    }
    .prefix(200).map { $0 }
  }

  private func readRegularTextFile(_ url: URL, maximumBytes: Int) -> String? {
    guard
      let values = try? url.resourceValues(forKeys: [
        .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
      ]), values.isRegularFile == true, values.isSymbolicLink != true,
      let size = values.fileSize, size <= maximumBytes,
      let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), data.count <= maximumBytes
    else { return nil }
    return String(data: data, encoding: .utf8)
  }
}

/// Open Quickly 顶部过滤器 chip:未选中次要文字无底色,选中 accent 文字 + accent 浅底。
@MainActor
final class OpenQuicklyChip: NSButton {
  var isChipSelected = false {
    didSet { applyAppearance() }
  }
  var showsCommandHint = false {
    didSet {
      guard showsCommandHint != oldValue else { return }
      invalidateIntrinsicContentSize()
      applyAppearance()
    }
  }

  private let fullTitle: String
  private let commandHint: String
  private let stableWidth: CGFloat

  /// 创建文字 chip;点击经闭包桥接,避免 target/action 样板。
  init(title: String, commandHint: String, handler: @escaping () -> Void) {
    fullTitle = title
    self.commandHint = commandHint
    let titleWidth = (title as NSString).size(withAttributes: [
      .font: NSFont.systemFont(ofSize: 12, weight: .semibold)
    ]).width
    let hintWidth = (commandHint as NSString).size(withAttributes: [
      .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium)
    ]).width
    stableWidth = ceil(max(titleWidth, hintWidth)) + 20
    super.init(frame: .zero)
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.borderWidth = 1
    target = self
    action = #selector(invoke)
    self.handler = handler
    translatesAutoresizingMaskIntoConstraints = false
    applyAppearance()
  }

  required init?(coder: NSCoder) { nil }

  private var handler: (() -> Void)?

  @objc private func invoke() { handler?() }

  /// 宽度按标题和快捷键的较大者预留，按下/松开 ⌘ 只改变高度，不让标签条
  /// 水平跳动。快捷键可见时增高为双行 pill。
  override var intrinsicContentSize: NSSize {
    NSSize(width: stableWidth, height: showsCommandHint ? 42 : 26)
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyAppearance()
  }

  private func applyAppearance() {
    let color = isChipSelected ? AsterTheme.accent : AsterTheme.secondaryInk
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = .center
    let text = NSMutableAttributedString(
      string: fullTitle,
      attributes: [
        .font: NSFont.systemFont(ofSize: 12, weight: isChipSelected ? .semibold : .regular),
        .foregroundColor: color,
        .paragraphStyle: paragraph,
      ])
    if showsCommandHint {
      text.append(
        NSAttributedString(
          string: "\n\(commandHint)",
          attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 9.5, weight: .medium),
            .foregroundColor: isChipSelected
              ? AsterTheme.accent.withAlphaComponent(0.88) : AsterTheme.tertiaryInk,
            .paragraphStyle: paragraph,
          ]))
    }
    attributedTitle = text
    layer?.cornerRadius = showsCommandHint ? 16 : 12
    layer?.backgroundColor =
      isChipSelected
      ? AsterTheme.accent.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
    layer?.borderColor =
      (isChipSelected ? AsterTheme.accent : AsterTheme.hairline)
      .withAlphaComponent(isChipSelected ? 0.70 : 0.72).cgColor
    setAccessibilityLabel(showsCommandHint ? "\(fullTitle), \(commandHint)" : fullTitle)
  }
}

/// Open Quickly 单行结果:SF Symbol 图标 + 标题/副标题双行 + 右侧相对时间与类型徽章。
@MainActor
final class OpenQuicklyRowView: NSButton {
  var isRowSelected = false {
    didSet { applySelection() }
  }

  private let icon = NSImageView()
  private let titleLabel = makeLabel("", size: 13, color: AsterTheme.ink)
  private let detailLabel = makeLabel("", size: 11, color: AsterTheme.secondaryInk)
  private let timestampLabel = makeLabel("", size: 11, color: AsterTheme.tertiaryInk)
  private let badgeLabel = makeLabel("", size: 9, weight: .medium, color: AsterTheme.secondaryInk)
  private let badgeBackground = NSView()
  private let shortcutLabel = makeLabel(
    "", size: 10, weight: .medium, color: AsterTheme.secondaryInk)
  private let shortcutBackground = NSView()
  private var handler: (() -> Void)?
  private var resultsWidthConstraint: NSLayoutConstraint?

  /// 结构和约束只创建一次；`configure` 更新文本与动作，使过滤器切换只改现有行内容。
  init() {
    super.init(frame: .zero)
    title = ""
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 8
    target = self
    action = #selector(invoke)

    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 16).isActive = true
    icon.heightAnchor.constraint(equalToConstant: 16).isActive = true

    shortcutBackground.wantsLayer = true
    shortcutBackground.layer?.cornerRadius = 4
    shortcutBackground.layer?.backgroundColor = AsterTheme.panel.cgColor
    shortcutBackground.layer?.borderWidth = 1
    shortcutBackground.layer?.borderColor = AsterTheme.hairline.withAlphaComponent(0.72).cgColor
    shortcutBackground.addSubview(shortcutLabel)
    shortcutLabel.pinEdges(
      to: shortcutBackground, insets: NSEdgeInsets(top: 2, left: 5, bottom: 2, right: 5))
    shortcutBackground.isHidden = true

    titleLabel.lineBreakMode = .byTruncatingTail
    detailLabel.lineBreakMode = .byTruncatingMiddle
    let textColumn = NSStackView(views: [titleLabel, detailLabel])
    textColumn.orientation = .vertical
    textColumn.spacing = 1
    textColumn.alignment = .leading

    let trailing = NSStackView()
    trailing.orientation = .horizontal
    trailing.spacing = 8
    trailing.alignment = .centerY
    trailing.addArrangedSubview(timestampLabel)
    badgeBackground.wantsLayer = true
    badgeBackground.layer?.cornerRadius = 4
    badgeBackground.layer?.backgroundColor =
      AsterTheme.secondaryInk
      .withAlphaComponent(0.12).cgColor
    badgeBackground.addSubview(badgeLabel)
    badgeLabel.pinEdges(
      to: badgeBackground, insets: NSEdgeInsets(top: 2, left: 5, bottom: 2, right: 5))
    trailing.addArrangedSubview(badgeBackground)

    let spacer = NSView()
    spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
    spacer.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let row = NSStackView(views: [shortcutBackground, icon, textColumn, spacer, trailing])
    row.orientation = .horizontal
    row.spacing = 10
    row.alignment = .centerY
    addSubview(row)
    row.pinEdges(to: self, insets: NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 10))
    textColumn.setContentHuggingPriority(.defaultHigh, for: .horizontal)
    textColumn.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: 44).isActive = true
  }

  required init?(coder: NSCoder) { nil }

  /// 跨视图宽度约束只在行已经加入 Stack 后激活；复用前先停用，避免约束引用已经
  /// 移出层级的行。这样既得到整行选中背景，也不会触发 no-common-ancestor 异常。
  func attach(to stack: NSStackView) {
    resultsWidthConstraint?.isActive = false
    let constraint = widthAnchor.constraint(equalTo: stack.widthAnchor)
    constraint.isActive = true
    resultsWidthConstraint = constraint
  }

  func detachFromResultsStack() {
    resultsWidthConstraint?.isActive = false
    resultsWidthConstraint = nil
  }

  /// 复用行时完整覆盖所有可见状态，防止上一过滤器的时间、徽章或动作泄漏到新结果。
  func configure(
    item: OpenQuicklyItem, symbol: String, badge: String, accented: Bool,
    handler: @escaping () -> Void
  ) {
    self.handler = handler
    identifier = NSUserInterfaceItemIdentifier("open-quickly-row-\(item.id)")
    icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: badge)
    icon.contentTintColor = accented ? AsterTheme.accent : AsterTheme.secondaryInk
    titleLabel.stringValue = item.title
    detailLabel.stringValue = item.detail
    detailLabel.isHidden = item.detail.isEmpty
    timestampLabel.stringValue = item.timestamp.map { RelativeTime.string(since: $0) } ?? ""
    timestampLabel.isHidden = item.timestamp == nil
    badgeLabel.stringValue = badge
    badgeBackground.identifier = NSUserInterfaceItemIdentifier("open-quickly-badge-\(item.id)")
    shortcutBackground.identifier = NSUserInterfaceItemIdentifier(
      "open-quickly-shortcut-\(item.id)")
    toolTip = item.detail.isEmpty ? item.title : "\(item.title)\n\(item.detail)"
    setAccessibilityLabel(item.title)
  }

  /// 按住 ⌘ 时，前九行用与实际 Quick Select 一致的键帽替换图标；
  /// 其余行仍保留类型图标，避免暗示不存在的快捷键。
  func setCommandHint(_ hint: String?, visible: Bool) {
    let showsHint = visible && hint != nil
    shortcutLabel.stringValue = hint ?? ""
    shortcutBackground.isHidden = !showsHint
    icon.isHidden = showsHint
  }

  @objc private func invoke() { handler?() }

  private func applySelection() {
    layer?.backgroundColor =
      isRowSelected
      ? AsterTheme.accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
  }
}
