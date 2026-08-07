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
  /// 当前渲染出来的面板容器。焦点切换只更新这里的指示器与 first responder，
  /// 不重建视图树。
  private var paneHosts: [UUID: ActivePaneHostView] = [:]
  // `nonisolated(unsafe)`：只在主线程读写，但 deinit 是 nonisolated，需要能取回它
  // 来注销监视器，否则控制器释放后事件监视器仍然存活。
  private nonisolated(unsafe) var paneClickMonitor: Any?
  private var inactiveOverlay: InactiveWindowOverlayView?
  /// 垂直侧栏顶部「+ 新建 / 折叠」悬停动作区；refresh 整树重建后重新赋值。
  private weak var sidebarHoverActions: NSView?
  private weak var windowTitleLabel: NSTextField?

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
    installPaneClickMonitor()
    observeWindowActivation()
    refresh()
  }

  /// 跟踪本窗口的键盘焦点状态。通知按窗口过滤，多窗口时互不影响。
  private func observeWindowActivation() {
    let center = NotificationCenter.default
    for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification] {
      center.publisher(for: name)
        .sink { [weak self] notification in
          guard let self, (notification.object as? NSWindow) === self.view.window else { return }
          self.updateWindowActivationOverlay()
        }
        .store(in: &modelSubscriptions)
    }
  }

  /// 当前是否叠着失焦遮罩（供测试断言）。
  var isShowingInactiveOverlay: Bool { inactiveOverlay?.superview === view }

  /// 失焦时叠加褪色遮罩，重新聚焦时移除。遮罩始终是最上层视图，
  /// 因此工作区刷新（会清空并重建子视图）之后必须重新安放。
  func updateWindowActivationOverlay() {
    // 还没上屏的视图按「活动」处理，避免测试与首帧出现无谓的灰罩。
    let isActive = view.window?.isKeyWindow ?? true
    // 非活动窗口里的终端停止光标闪烁；后台标签的会话一并同步，切回来时状态已正确。
    for tab in model.tabs {
      for runtime in tab.runtimes.values {
        runtime.terminalSession?.setWindowActive(isActive)
      }
    }
    guard !isActive else {
      inactiveOverlay?.removeFromSuperview()
      inactiveOverlay = nil
      return
    }
    if let inactiveOverlay, inactiveOverlay.superview === view {
      view.addSubview(inactiveOverlay, positioned: .above, relativeTo: nil)
      return
    }
    let overlay = InactiveWindowOverlayView(frame: view.bounds)
    overlay.autoresizingMask = [.width, .height]
    view.addSubview(overlay, positioned: .above, relativeTo: nil)
    inactiveOverlay = overlay
  }

  deinit {
    if let paneClickMonitor { NSEvent.removeMonitor(paneClickMonitor) }
  }

  /// 用窗口级事件监视器跟踪「点了哪个分屏」。终端和文本视图会自己消费 `mouseDown`
  /// 并且不向 responder 链上抛，容器视图的 `mouseDown` 永远收不到点击——只靠容器
  /// 事件会让 activePaneID 永远停在最后一次拆分出来的面板上，「关闭当前面板」也就
  /// 总是关错对象。
  private func installPaneClickMonitor() {
    paneClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown])
    { [weak self] event in
      self?.activatePane(from: event)
      return event
    }
  }

  private func activatePane(from event: NSEvent) {
    guard let window = view.window, event.window === window,
      let tab = model.selectedTab, tab.layout.allPanes.count > 1,
      let hit = window.contentView?.hitTest(event.locationInWindow)
    else { return }
    // 命中的是终端网格等叶子视图，沿 superview 链向上找到它所属的面板容器。
    var candidate: NSView? = hit
    while let current = candidate {
      if let host = current as? ActivePaneHostView {
        tab.setActivePane(host.paneID)
        return
      }
      candidate = current.superview
    }
  }

  // MARK: - 侧栏悬停动作区

  /// 生成「+ 新建标签页」与「折叠/展开标签栏」按钮行，默认隐藏（悬停时由
  /// `setSidebarHoverActionsVisible` 淡入）。侧栏展开与折叠两种布局共用。
  private func makeHoverActionsRow(sidebarVisible: Bool) -> NSStackView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 2
    let addTabButton = ActionButton(symbol: "plus", bezelStyle: .inline) { [weak self] in
      self?.model.newTab()
    }
    addTabButton.toolTip = "新建标签页"
    let toggleButton = ActionButton(symbol: "sidebar.left", bezelStyle: .inline) { [weak self] in
      self?.preferences.configuration.appearance.showTabBar.toggle()
    }
    toggleButton.toolTip = sidebarVisible
      ? "折叠标签栏（悬停顶部或从「显示」菜单恢复）"
      : "展开标签栏"
    for button in [addTabButton, toggleButton] {
      button.isBordered = false
      button.contentTintColor = AsterTheme.secondaryInk
      button.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 24),
        button.heightAnchor.constraint(equalToConstant: 22),
      ])
      row.addArrangedSubview(button)
    }
    row.alphaValue = 0
    row.isHidden = true
    return row
  }

  /// 折叠态内容区：顶部叠加点击穿透的悬停带与「+ / 展开」按钮行。悬停带覆盖红绿灯
  /// 及其右侧区域，鼠标一进入窗口顶部就淡入按钮；按钮行是兄弟视图（不在悬停带内），
  /// 否则点击穿透会把按钮自己的点击也吞掉。
  private func makeCollapsedContentArea() -> NSView {
    let content = makeContentArea()
    let strip = ClickThroughStripView()
    strip.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(strip)
    NSLayoutConstraint.activate([
      strip.leadingAnchor.constraint(equalTo: content.leadingAnchor),
      strip.topAnchor.constraint(equalTo: content.topAnchor),
      strip.widthAnchor.constraint(equalToConstant: 340),
      strip.heightAnchor.constraint(equalToConstant: 44),
    ])
    let actions = makeHoverActionsRow(sidebarVisible: false)
    actions.translatesAutoresizingMaskIntoConstraints = false
    content.addSubview(actions)
    NSLayoutConstraint.activate([
      // leading 必须让开红绿灯的命中/遮挡区（实测延伸到约 103pt，比视觉圆点更宽），
      // 否则「+」按钮会被窗口标题栏区域整个盖住。
      actions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 108),
      actions.topAnchor.constraint(equalTo: content.topAnchor, constant: 4),
    ])
    sidebarHoverActions = actions
    let tracking = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    strip.addTrackingArea(tracking)
    return content
  }

  /// 侧栏 tracking area 的 owner 是本控制器：进入时淡入「+ / 折叠」按钮，离开时淡出。
  override func mouseEntered(with event: NSEvent) {
    setSidebarHoverActionsVisible(true)
  }

  override func mouseExited(with event: NSEvent) {
    setSidebarHoverActionsVisible(false)
  }

  /// 切换悬停动作区透明度；不可见时同时 isHidden，避免隐形按钮拦截该区域的窗口拖动。
  private func setSidebarHoverActionsVisible(_ visible: Bool) {
    guard let actions = sidebarHoverActions else { return }
    if visible { actions.isHidden = false }
    NSAnimationContext.runAnimationGroup({ context in
      context.duration = 0.15
      actions.animator().alphaValue = visible ? 1 : 0
    }, completionHandler: {
      // completionHandler 是 @Sendable 闭包，回主 actor 再改 isHidden。
      Task { @MainActor in
        actions.isHidden = !visible
      }
    })
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
    paneHosts.removeAll()
    children.forEach { $0.removeFromParent() }
    view.removeAllSubviews()
    view.appearance = preferences.preferredAppearance
    updateWindowTitle(model.selectedTab?.windowTitle ?? "Aster")

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

    // 视图树刚重建，first responder 还停在被移除的旧视图上；等本轮布局结束后把
    // 键盘焦点交还给当前面板。只聚焦活动面板——过去对每个终端都调用 focus()，
    // 最后渲染的那个会抢走输入焦点，用户看到的焦点框与真正接收按键的面板不一致。
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      if let tab = self.model.selectedTab { self.focusActivePane(in: tab) }
      self.updateWindowActivationOverlay()
    }
  }

  private func observeTabs() {
    tabSubscriptions.removeAll()
    for tab in model.tabs {
      tab.objectWillChange
        .sink { [weak self] _ in self?.scheduleRefresh() }
        .store(in: &tabSubscriptions)
      // 焦点切换走独立通道做局部更新：整树重建会打断终端拖选与 TUI 重绘。
      tab.activePaneChanged
        .sink { [weak self, weak tab] _ in
          guard let self, let tab, tab.id == self.model.selectedTabID else { return }
          self.updatePaneActivationOverlays(in: tab)
          self.focusActivePane(in: tab)
        }
        .store(in: &tabSubscriptions)
      tab.windowTitleChanged
        .sink { [weak self, weak tab] title in
          guard let self, let tab, tab.id == self.model.selectedTabID else { return }
          self.updateWindowTitle(title)
        }
        .store(in: &tabSubscriptions)
    }
  }

  /// 同步系统窗口标题与自定义标题区。该更新不重建视图树，因此仅 OSC 2 变化或
  /// 分屏焦点切换不会打断终端选择、滚动和 TUI 绘制。
  private func updateWindowTitle(_ title: String) {
    view.window?.title = title
    windowTitleLabel?.stringValue = title
  }

  /// 一次 Pane 拖放的落点：`direction` 为 nil 表示落在面板中心（交换两个面板）。
  private struct PaneDropTarget {
    let paneID: UUID
    let direction: SplitDirection?
    let rect: NSRect
    var isSwap: Bool { direction == nil }
  }

  /// 从把手按下开始接管事件循环，直到抬起。用 `trackEvents` 而不是 `NSDraggingSession`：
  /// 落点全在自己窗口内，不需要跨应用拖放的粘贴板协议，事件循环也更好控制。
  private func beginPaneDrag(paneID: UUID, event: NSEvent) {
    guard let window = view.window, (model.selectedTab?.layout.allPanes.count ?? 0) > 1 else {
      return
    }
    let overlay = PaneDropOverlayView(frame: view.bounds)
    overlay.autoresizingMask = [.width, .height]
    view.addSubview(overlay)
    NSCursor.closedHand.push()

    var target: PaneDropTarget?
    window.trackEvents(
      matching: [.leftMouseDragged, .leftMouseUp],
      timeout: .greatestFiniteMagnitude,
      mode: .eventTracking
    ) { tracked, stop in
      guard let tracked else {
        stop.pointee = true
        return
      }
      let point = self.view.convert(tracked.locationInWindow, from: nil)
      target = self.paneDropTarget(at: point, source: paneID)
      overlay.highlight = target.map { ($0.rect, $0.isSwap) }
      if tracked.type == .leftMouseUp { stop.pointee = true }
    }

    overlay.removeFromSuperview()
    NSCursor.pop()
    guard let target else { return }
    if let direction = target.direction {
      model.movePane(paneID, nextTo: target.paneID, direction: direction)
    } else {
      model.swapPanes(paneID, target.paneID)
    }
  }

  /// 命中落点：指针在目标面板四边 25% 以内时插到该侧，否则落在中心表示交换。
  /// 拖回自己身上没有任何有效语义，直接不返回落点（覆盖层也就不会高亮）。
  private func paneDropTarget(at point: NSPoint, source: UUID) -> PaneDropTarget? {
    for (paneID, host) in paneHosts where paneID != source {
      guard host.window != nil else { continue }
      let frame = host.convert(host.bounds, to: view)
      guard frame.contains(point) else { continue }
      let zone = PaneDropGeometry.zone(in: frame, at: point)
      return PaneDropTarget(paneID: paneID, direction: zone.direction, rect: zone.rect)
    }
    return nil
  }

  /// 切换聚焦面板时只翻转各 Pane 的褪色遮罩，不重建视图树。
  private func updatePaneActivationOverlays(in tab: TerminalTabItem) {
    for (paneID, host) in paneHosts {
      host.isActivePane = paneID == tab.activePaneID
    }
  }

  /// 把键盘焦点交给当前面板：终端面板交给 SwiftTerm 视图，其余面板交给容器本身。
  private func focusActivePane(in tab: TerminalTabItem) {
    if let session = tab.activeRuntime?.terminalSession {
      session.focus()
      return
    }
    guard let host = paneHosts[tab.activePaneID], let window = host.window else { return }
    window.makeFirstResponder(host)
  }

  private func makeWorkspaceLayout() -> NSView {
    let showsTabs = preferences.configuration.appearance.showsTabBar(tabCount: model.tabs.count)
    // 折叠态：内容区左上角叠加悬停动作区（+ 新建 / 展开标签栏），鼠标进入顶部
    // 悬停带时淡入，离开淡出——折叠后无需进设置页也能恢复侧栏。
    guard showsTabs else { return makeCollapsedContentArea() }

    switch preferences.tabBarLayout {
    case .vertical:
      let stack = NSStackView()
      stack.orientation = .horizontal
      stack.spacing = 0
      stack.distribution = .fill
      // 侧栏、分隔线与内容区必须等高填满窗口。默认的 centerY 对齐会让内容区退回自身的
      // 固有高度：上下分屏时 NSSplitView 给每个面板加了 `height == 0 @250` 约束，内容区
      // 因此只剩「标题栏 + 分隔条 + 状态栏」的高度，两个终端都被压成 0。
      stack.alignment = .height
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
      content.translatesAutoresizingMaskIntoConstraints = false
      content.heightAnchor.constraint(equalTo: stack.heightAnchor).isActive = true
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
      // 与竖直标签栏布局同理：内容区没有固有宽度，左右分屏会被 NSSplitView 的
      // `width == 0 @250` 回退约束压到最窄。约束必须在入栈之后建立。
      content.translatesAutoresizingMaskIntoConstraints = false
      content.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
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

    // 悬停动作区：「+ 新建标签」与「折叠标签栏」，默认隐藏，鼠标进入侧栏时淡入。
    // 放在 header 顶部右侧，与红绿灯同一水平线。
    let hoverActions = makeHoverActionsRow(sidebarVisible: true)
    header.addSubview(hoverActions)
    hoverActions.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hoverActions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
      hoverActions.topAnchor.constraint(equalTo: header.topAnchor, constant: 4),
    ])
    sidebarHoverActions = hoverActions

    // 鼠标进入侧栏任意位置都显示动作区；inVisibleRect 让跟踪区域跟随侧栏尺寸。
    let tracking = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self,
      userInfo: nil
    )
    background.addTrackingArea(tracking)

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
          showsExitStatus: preferences.configuration.shell.badgeExitStatus,
          showsFinished: preferences.configuration.shell.resolvedBadgeCommandFinish,
          showsFailure: preferences.configuration.shell.resolvedBadgeCommandFailure,
          showsAwaitingInput: preferences.configuration.shell.badgeAwaitingInput,
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
    let sorted: [TerminalTabItem]
    switch preferences.sidebarTabOrder {
    case .manual:
      sorted = model.tabs
    case .createdTime, .updatedTime:
      sorted = model.tabs.sorted { lhs, rhs in
        let lhsDate = preferences.sidebarTabOrder == .createdTime ? lhs.createdAt : lhs.updatedAt
        let rhsDate = preferences.sidebarTabOrder == .createdTime ? rhs.createdAt : rhs.updatedAt
        if lhsDate != rhsDate { return lhsDate > rhsDate }
        return lhs.id.uuidString < rhs.id.uuidString
      }
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
        showsExitStatus: preferences.configuration.shell.badgeExitStatus,
        showsFinished: preferences.configuration.shell.resolvedBadgeCommandFinish,
        showsFailure: preferences.configuration.shell.resolvedBadgeCommandFailure,
        showsAwaitingInput: preferences.configuration.shell.badgeAwaitingInput,
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
    menu.addItem(ActionMenuItem(title: "重命名标签页…") { [weak self, weak tab] in
      guard let self, let tab else { return }
      model.select(tab)
      model.promptRenameSelectedTab()
    })
    menu.addItem(ActionMenuItem(title: "恢复自动标题") { [weak self, weak tab] in
      guard let self, let tab else { return }
      tab.setTabTitleOverride(.automatic)
      model.persistWorkspace()
    })
    menu.addItem(.separator())
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
    let paneTree = makePaneContent(tab)
    paneHost.addSubview(paneTree)
    paneTree.pinEdges(to: paneHost, insets: NSEdgeInsets(style.padding))
    inner.addArrangedSubview(paneHost)
    let statusBar = preferences.showStatusBar ? makeStatusBar(tab) : nil
    if let statusBar { inner.addArrangedSubview(statusBar) }
    stack.addArrangedSubview(wrapper)
    // 这些内容容器没有 intrinsicContentSize；两个方向都必须显式绑定，否则 NSStackView
    // 会退回「固有尺寸」布局。上下分屏尤其致命：NSSplitView 给每个面板加了
    // `height == 0 @250` 的回退约束，没有必需高度约束时整个内容区会塌成一条分隔条。
    wrapper.translatesAutoresizingMaskIntoConstraints = false
    paneHost.translatesAutoresizingMaskIntoConstraints = false
    var constraints: [NSLayoutConstraint] = [
      wrapper.widthAnchor.constraint(equalTo: stack.widthAnchor),
      wrapper.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
      paneHost.widthAnchor.constraint(equalTo: inner.widthAnchor),
      paneHost.topAnchor.constraint(equalTo: inner.topAnchor),
    ]
    if let statusBar {
      // 状态栏必须先钉在底边，Pane 区才有「剩余空间」可以填充；只写 paneHost 与状态栏
      // 的相邻关系时两者会一起收缩到固有高度，把下方整块留白。
      constraints.append(statusBar.bottomAnchor.constraint(equalTo: inner.bottomAnchor))
      constraints.append(paneHost.bottomAnchor.constraint(equalTo: statusBar.topAnchor))
    } else {
      constraints.append(paneHost.bottomAnchor.constraint(equalTo: inner.bottomAnchor))
    }
    NSLayoutConstraint.activate(constraints)
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

    // 标题区显示活动 Pane 的 OSC 2/0 窗口标题；OSC 1 的短名称只驱动标签文案。
    // 文件、分屏和命令面板仍由菜单与快捷键提供，不在标题栏重复堆放按钮。
    let title = makeLabel(
      tab.windowTitle,
      size: 10.5,
      color: theme.style.titlebarForeground.map(NSColor.init) ?? AsterTheme.secondaryInk
    )
    title.identifier = NSUserInterfaceItemIdentifier("workspace-window-title")
    windowTitleLabel = title
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

  /// 工作区内容区：处于「缩放拆分」状态时只渲染被放大的那一个面板，其余面板保持
  /// 运行（PTY 与滚动历史不受影响），退出放大后原样回到分屏树。
  private func makePaneContent(_ tab: TerminalTabItem) -> NSView {
    if let zoomed = tab.zoomedPaneID, tab.layout.allPanes.count > 1,
      let descriptor = tab.layout.allPanes.first(where: { $0.id == zoomed })
    {
      return makePaneLeaf(descriptor, tab: tab)
    }
    return makePaneTree(tab.layout, tab: tab, path: [])
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
    let host = ActivePaneHostView(
      paneID: descriptor.id,
      isActive: tab.activePaneID == descriptor.id
    ) { [weak tab] in
      tab?.setActivePane(descriptor.id)
    }
    paneHosts[descriptor.id] = host
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
    // 单 Pane 既无处可拖，也不需要区分聚焦状态；两种装饰都只在分屏时安装。
    // 遮罩先于把手安装，把手才会浮在遮罩之上。
    if tab.layout.allPanes.count > 1 {
      host.installInactiveOverlay()
      host.installDragHandle { [weak self] paneID, event in
        self?.beginPaneDrag(paneID: paneID, event: event)
      }
    }
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
    // 放大态下其它分屏不可见，状态栏必须给出提示，否则会被误读成分屏丢失。
    let paneCount = tab.layout.allPanes.count
    let zoomHint = tab.zoomedPaneID != nil && paneCount > 1 ? "ZOOMED   " : ""
    let right = makeLabel("\(zoomHint)\(paneCount) PANE\(paneCount == 1 ? "" : "S")   UTF-8", size: 9.5, weight: .medium, color: AsterTheme.tertiaryInk, monospaced: true)
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

  init(
    tab: TerminalTabItem,
    selected: Bool,
    horizontal: Bool,
    theme: TerminalTheme,
    showsExitStatus: Bool,
    showsFinished: Bool,
    showsFailure: Bool,
    showsAwaitingInput: Bool,
    action: @escaping () -> Void
  ) {
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
    if horizontal {
      switch tab.activityBadge {
      case .running:
        image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: "正在运行")
      case .awaitingInput where showsAwaitingInput:
        image = NSImage(systemSymbolName: "hand.raised.fill", accessibilityDescription: "等待输入")
      case .error where showsFailure && showsExitStatus:
        image = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "执行失败")
      case .finished where showsFinished && showsExitStatus:
        image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "已完成")
      case .completed where showsFinished && showsExitStatus:
        image = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "刚刚完成")
      default:
        image = nil
      }
      imagePosition = .imageTrailing
    }
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
      switch tab.activityBadge {
      case .running:
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)
        accessory = spinner
      case .awaitingInput where showsAwaitingInput:
        accessory = makeLabel(
          "✋", size: 11, weight: .semibold, color: AsterTheme.warning
        )
      case .error where showsFailure && showsExitStatus:
        accessory = makeLabel(
          tab.lastCommandExitStatus.map(String.init) ?? "!",
          size: 10,
          weight: .semibold,
          color: AsterTheme.warning,
          monospaced: true
        )
      case .finished where showsFinished && showsExitStatus:
        accessory = makeLabel("●", size: 9, weight: .semibold, color: AsterTheme.accent)
      case .completed where showsFinished && showsExitStatus:
        accessory = makeLabel("✓", size: 11, weight: .semibold, color: AsterTheme.accent)
      default:
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
///
/// 分隔条默认是一条 1pt 灰线；指针进入命中区后加粗为主题强调色，双击恢复等分。
@MainActor
private final class PersistedSplitView: NSSplitView, NSSplitViewDelegate {
  /// 命中区比可见线宽得多：1pt 的线几乎抓不住，Otty 同样用一条细线 + 宽感应带。
  private static let hitThickness: CGFloat = 6
  private let ratio: Double
  private let onRatioChanged: (Double) -> Void
  private var positioned = false
  private var isUserResizing = false
  private var isHoveringDivider = false {
    didSet { if oldValue != isHoveringDivider { needsDisplay = true } }
  }
  private var dividerTrackingArea: NSTrackingArea?

  init(axis: SplitAxis, ratio: Double, onRatioChanged: @escaping (Double) -> Void) {
    self.ratio = ratio
    self.onRatioChanged = onRatioChanged
    super.init(frame: .zero)
    isVertical = axis == .horizontal
    dividerStyle = .thin
    delegate = self
  }

  required init?(coder: NSCoder) { nil }

  override var dividerThickness: CGFloat { Self.hitThickness }

  /// 只画中间 1pt（悬停时 2pt）的线，命中区其余部分留白透出容器底色，
  /// 视觉上仍是 Otty 那条细分隔线。
  override func drawDivider(in rect: NSRect) {
    // 窗口不是键盘焦点窗口时一律画成灰线：非活动窗口不应该有强调色。
    let isHoveringDivider = self.isHoveringDivider && (window?.isKeyWindow ?? false)
    let thickness: CGFloat = isHoveringDivider ? 2 : 1
    let line =
      isVertical
      ? NSRect(x: rect.midX - thickness / 2, y: rect.minY, width: thickness, height: rect.height)
      : NSRect(x: rect.minX, y: rect.midY - thickness / 2, width: rect.width, height: thickness)
    (isHoveringDivider ? AsterTheme.accent : AsterTheme.hairline).setFill()
    line.fill()
  }

  /// 两个子视图之间的空隙就是分隔条命中区；不依赖 `NSSplitView` 的坐标翻转约定。
  private var dividerHitRect: NSRect? {
    guard arrangedSubviews.count == 2 else { return nil }
    let first = arrangedSubviews[0].frame
    let second = arrangedSubviews[1].frame
    if isVertical {
      return NSRect(
        x: min(first.maxX, second.maxX), y: 0, width: dividerThickness, height: bounds.height)
    }
    return NSRect(
      x: 0, y: min(first.maxY, second.maxY), width: bounds.width, height: dividerThickness)
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let dividerTrackingArea { removeTrackingArea(dividerTrackingArea) }
    guard let rect = dividerHitRect else {
      isHoveringDivider = false
      return
    }
    let area = NSTrackingArea(
      rect: rect,
      options: [.mouseEnteredAndExited, .activeInKeyWindow],
      owner: self
    )
    addTrackingArea(area)
    dividerTrackingArea = area
    // 移除感应区不会补发 mouseExited：指针正好停在旧感应区里时高亮会一直卡住。
    // 每次重建后按指针的真实位置对齐一次状态。
    syncHoverState()
  }

  /// 高亮只在「本窗口是键盘焦点窗口，且指针确实压在分隔条命中区上」时成立。
  private func syncHoverState() {
    guard let window, window.isKeyWindow, let rect = dividerHitRect else {
      isHoveringDivider = false
      return
    }
    let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
    isHoveringDivider = rect.contains(point)
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    syncHoverState()
  }

  override func mouseEntered(with event: NSEvent) { isHoveringDivider = true }
  override func mouseExited(with event: NSEvent) { isHoveringDivider = false }

  /// `NSSplitView` 把「分隔条厚度」当作与分隔方向垂直的固有尺寸（水平分隔时固有高度
  /// 只有 1pt），因为它的子视图走 autoresizing、无法反推内容尺寸。放进 `NSStackView`
  /// 后这个固有高度会把整个内容区压成一条线：上下分屏只剩分隔条，两个终端高度都是 0。
  /// 分屏区域的尺寸完全由外层容器给定，这里直接取消固有尺寸。
  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  /// 比例针对「扣掉分隔条之后的可用长度」，否则第一块会固定多出一个分隔条的厚度，
  /// 等分看起来是歪的。
  private var contentLength: CGFloat {
    max(0, (isVertical ? bounds.width : bounds.height) - dividerThickness)
  }

  override func layout() {
    super.layout()
    guard !positioned, arrangedSubviews.count == 2 else { return }
    // 首轮布局可能在拿到真实尺寸前发生；此时定位分隔条会把比例锁在无效值上。
    guard contentLength > 1 else { return }
    positioned = true
    setPosition(max(1, contentLength * ratio), ofDividerAt: 0)
  }

  func splitViewDidResizeSubviews(_ notification: Notification) {
    // 命中区是由两个子视图的间隙算出来的，自身 frame 不变时 AppKit 不会重建它，
    // 拖完分隔条后感应区就会停在旧位置。
    updateTrackingAreas()
    guard positioned, isUserResizing, arrangedSubviews.count == 2 else { return }
    let first = isVertical ? arrangedSubviews[0].frame.width : arrangedSubviews[0].frame.height
    guard contentLength > 0 else { return }
    onRatioChanged(min(max(first / contentLength, 0.05), 0.95))
  }

  override func mouseDown(with event: NSEvent) {
    // 双击分隔条恢复等分，与参考应用一致；单击进入原生拖动，比例在拖动中写回。
    if event.clickCount == 2, let rect = dividerHitRect,
      rect.contains(convert(event.locationInWindow, from: nil))
    {
      guard contentLength > 1 else { return }
      setPosition(contentLength * 0.5, ofDividerAt: 0)
      onRatioChanged(0.5)
      return
    }
    isUserResizing = true
    super.mouseDown(with: event)
    isUserResizing = false
  }
}

/// Pane 拖放的落点几何。与 AppKit 状态无关的纯函数：给定目标面板矩形和指针位置，
/// 得出该落在哪一侧（或中心），以及要高亮的区域。
enum PaneDropGeometry {
  /// 四边各占 25%——比例太小会难以命中，太大则中心的「交换」区域几乎消失。
  static let edgeFraction: CGFloat = 0.25

  /// - Returns: `direction` 为 nil 表示落在中心（交换语义），此时 `rect` 是整个面板。
  static func zone(
    in frame: NSRect,
    at point: NSPoint,
    edgeFraction: CGFloat = edgeFraction
  ) -> (direction: SplitDirection?, rect: NSRect) {
    let local = NSPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    let halfWidth = frame.width / 2
    let halfHeight = frame.height / 2
    let edgeX = frame.width * edgeFraction
    let edgeY = frame.height * edgeFraction
    // AppKit 非翻转坐标：y 越小越靠近底边，因此 `.down` 用 local.y、`.up` 用其补数。
    let candidates: [(direction: SplitDirection, distance: CGFloat, limit: CGFloat, rect: NSRect)] = [
      (.left, local.x, edgeX,
       NSRect(x: frame.minX, y: frame.minY, width: halfWidth, height: frame.height)),
      (.right, frame.width - local.x, edgeX,
       NSRect(x: frame.midX, y: frame.minY, width: halfWidth, height: frame.height)),
      (.down, local.y, edgeY,
       NSRect(x: frame.minX, y: frame.minY, width: frame.width, height: halfHeight)),
      (.up, frame.height - local.y, edgeY,
       NSRect(x: frame.minX, y: frame.midY, width: frame.width, height: halfHeight)),
    ]
    guard let nearest = candidates.filter({ $0.distance <= $0.limit }).min(by: {
      $0.distance < $1.distance
    }) else {
      return (nil, frame)
    }
    return (nearest.direction, nearest.rect)
  }
}

/// 窗口失去键盘焦点时叠在工作区之上的褪色遮罩。
///
/// AppKit 只会自动灰化系统控件，终端网格、侧栏和自绘视图都不受影响，非活动窗口
/// 看起来仍然「亮着」，多窗口下分不清哪个在接收输入。遮罩用主题窗口底色，
/// 因此深浅主题都是朝各自背景褪色，而不是压一层固定的灰。
@MainActor
private final class InactiveWindowOverlayView: NSView {
  /// 覆盖层不参与命中测试：失焦窗口的第一次点击仍应正常落到下面的终端上。
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    AsterTheme.paper.withAlphaComponent(0.45).setFill()
    dirtyRect.fill()
  }
}

/// 拖动 Pane 时覆盖在工作区之上的落点提示层。参考应用用两种颜色区分语义：
/// 面板边缘（强调色）＝插到这一侧，面板中心（绿色）＝与该面板交换位置。
@MainActor
private final class PaneDropOverlayView: NSView {
  var highlight: (rect: NSRect, isSwap: Bool)? {
    didSet { needsDisplay = true }
  }

  /// 拖动全程由 `trackEvents` 驱动，覆盖层不参与命中测试。
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func draw(_ dirtyRect: NSRect) {
    guard let highlight else { return }
    let color = highlight.isSwap ? NSColor.systemGreen : AsterTheme.accent
    let path = NSBezierPath(roundedRect: highlight.rect.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
    color.withAlphaComponent(0.20).setFill()
    path.fill()
    color.withAlphaComponent(0.85).setStroke()
    path.lineWidth = 2
    path.stroke()
  }
}

/// Pane 顶边的胶囊拖动把手。参考应用的说法是「move the pointer near the top and a small
/// capsule appears」：靠近顶边淡入短胶囊，指针压在胶囊上时变长并换成抓手光标，
/// 按住即可把整个 Pane 拖到别处。
@MainActor
private final class PaneDragHandleView: NSView {
  private static let collapsedWidth: CGFloat = 28
  private static let expandedWidth: CGFloat = 56
  private let capsule = NSView()
  private var capsuleWidth: NSLayoutConstraint?
  private var trackingArea: NSTrackingArea?
  private let onDragStart: (NSEvent) -> Void
  /// 指针是否靠近 Pane 顶边（由上层的点击穿透感应带驱动）。
  var isRevealed = false {
    didSet { if oldValue != isRevealed { updateAppearance() } }
  }
  private var isHovered = false {
    didSet { if oldValue != isHovered { updateAppearance() } }
  }

  init(onDragStart: @escaping (NSEvent) -> Void) {
    self.onDragStart = onDragStart
    super.init(frame: .zero)
    wantsLayer = true
    capsule.wantsLayer = true
    capsule.layer?.cornerRadius = 2
    capsule.layer?.cornerCurve = .continuous
    capsule.layer?.backgroundColor = AsterTheme.tertiaryInk.cgColor
    capsule.translatesAutoresizingMaskIntoConstraints = false
    addSubview(capsule)
    let width = capsule.widthAnchor.constraint(equalToConstant: Self.collapsedWidth)
    capsuleWidth = width
    NSLayoutConstraint.activate([
      capsule.centerXAnchor.constraint(equalTo: centerXAnchor),
      capsule.centerYAnchor.constraint(equalTo: centerYAnchor),
      capsule.heightAnchor.constraint(equalToConstant: 4),
      width,
    ])
    alphaValue = 0
  }

  required init?(coder: NSCoder) { nil }

  /// 完全透明时不参与命中测试，否则 Pane 顶部中央会出现一块点不到终端的死区。
  override func hitTest(_ point: NSPoint) -> NSView? {
    alphaValue > 0.01 ? super.hitTest(point) : nil
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let trackingArea { removeTrackingArea(trackingArea) }
    let area = NSTrackingArea(
      rect: bounds,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .cursorUpdate],
      owner: self
    )
    addTrackingArea(area)
    trackingArea = area
  }

  override func mouseEntered(with event: NSEvent) { isHovered = true }
  override func mouseExited(with event: NSEvent) { isHovered = false }
  override func cursorUpdate(with event: NSEvent) {
    if isRevealed { NSCursor.openHand.set() } else { super.cursorUpdate(with: event) }
  }

  override func mouseDown(with event: NSEvent) {
    guard isRevealed else {
      super.mouseDown(with: event)
      return
    }
    onDragStart(event)
  }

  private func updateAppearance() {
    let expanded = isRevealed && isHovered
    capsule.layer?.backgroundColor =
      (expanded ? AsterTheme.accent : AsterTheme.tertiaryInk).cgColor
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.14
      context.allowsImplicitAnimation = true
      animator().alphaValue = isRevealed ? 1 : 0
      capsuleWidth?.animator().constant = expanded ? Self.expandedWidth : Self.collapsedWidth
      superview?.layoutSubtreeIfNeeded()
    }
  }
}

/// 全点击穿透的透明悬停带：只承载 tracking area 探测鼠标进入窗口顶部，
/// 自身与子视图不参与命中测试，不会拦截下方终端的点击与拖选。
private final class ClickThroughStripView: NSView {
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

@MainActor
private final class ActivePaneHostView: NSView {  /// 所属面板的 ID：窗口级点击监视器沿 superview 链命中本视图后据此激活对应面板。
  /// 顶边感应带与把手的高度：太矮抓不到，太高会让顶部一整条都在触发淡入。
  private static let handleRevealHeight: CGFloat = 14
  let paneID: UUID
  private let activation: () -> Void
  private var dragHandle: PaneDragHandleView?
  private var handleTrackingArea: NSTrackingArea?
  private var inactiveOverlay: NSView?
  /// 焦点状态可原地切换：切换聚焦面板只改这层遮罩的可见性，不重建视图树。
  var isActivePane: Bool {
    didSet { inactiveOverlay?.isHidden = isActivePane }
  }

  init(paneID: UUID, isActive: Bool, activation: @escaping () -> Void) {
    self.paneID = paneID
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

  /// 顶边感应带：指针靠近 Pane 顶部时淡入拖动把手。用 `NSTrackingArea` 而不是叠一层
  /// 视图——终端要占满整个 Pane，任何实体覆盖层都会吃掉那一条上的点击与拖选。
  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let handleTrackingArea { removeTrackingArea(handleTrackingArea) }
    guard dragHandle != nil else { return }
    let strip = NSRect(
      x: 0, y: max(0, bounds.height - Self.handleRevealHeight),
      width: bounds.width, height: min(bounds.height, Self.handleRevealHeight))
    let area = NSTrackingArea(
      rect: strip,
      options: [.mouseEnteredAndExited, .activeInKeyWindow],
      owner: self
    )
    addTrackingArea(area)
    handleTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) { dragHandle?.isRevealed = true }
  override func mouseExited(with event: NSEvent) { dragHandle?.isRevealed = false }

  /// 给非聚焦的 Pane 铺一层褪色遮罩。取代过去那条强调色顶边——遮罩把「哪个 Pane
  /// 在接收输入」表达为整块对比，而不是一条比终端内容还抢眼的装饰线。
  /// 遮罩必须叠在内容之上、且点击穿透：点非活动 Pane 的第一下要能同时激活它并落到终端。
  func installInactiveOverlay() {
    guard inactiveOverlay == nil else { return }
    let overlay = ClickThroughStripView()
    overlay.wantsLayer = true
    overlay.layer?.backgroundColor = AsterTheme.paper.withAlphaComponent(0.30).cgColor
    overlay.isHidden = isActivePane
    addSubview(overlay)
    overlay.pinEdges(to: self)
    inactiveOverlay = overlay
  }

  /// 安装顶边拖动把手；只有存在多个 Pane 时才有意义（单 Pane 无处可拖）。
  func installDragHandle(onDragStart: @escaping (UUID, NSEvent) -> Void) {
    guard dragHandle == nil else { return }
    let paneID = paneID
    let handle = PaneDragHandleView { event in onDragStart(paneID, event) }
    handle.translatesAutoresizingMaskIntoConstraints = false
    addSubview(handle)
    NSLayoutConstraint.activate([
      handle.centerXAnchor.constraint(equalTo: centerXAnchor),
      handle.topAnchor.constraint(equalTo: topAnchor),
      handle.widthAnchor.constraint(equalToConstant: 96),
      handle.heightAnchor.constraint(equalToConstant: Self.handleRevealHeight),
    ])
    dragHandle = handle
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
