import AppKit
import AsterCore
import Combine

/// 纯 AppKit 主工作区。控制器根据领域模型重建轻量窗口框架，但终端 `NSView` 由
/// `TerminalSession` 长期持有，标签切换或布局刷新不会重启 PTY、清空滚动历史或 TUI。
@MainActor
final class WorkspaceViewController: NSViewController {
  let model: AppModel
  private let preferences: AppPreferences
  private var modelSubscriptions: Set<AnyCancellable> = []
  private var tabSubscriptions: Set<AnyCancellable> = []
  private var retainedObjects: [AnyObject] = []
  private var refreshScheduled = false
  /// 当前渲染出来的面板容器。焦点切换只更新这里的指示器与 first responder，
  /// 不重建视图树。
  private var paneHosts: [UUID: ActivePaneHostView] = [:]
  private var editorTextViews: [UUID: NSTextView] = [:]
  // `nonisolated(unsafe)`：只在主线程读写，但 deinit 是 nonisolated，需要能取回它
  // 来注销监视器，否则控制器释放后事件监视器仍然存活。
  private nonisolated(unsafe) var paneClickMonitor: Any?
  private var inactiveOverlay: InactiveWindowOverlayView?
  /// 垂直侧栏顶部「+ 新建 / 折叠」悬停动作区；refresh 整树重建后重新赋值。
  private weak var sidebarHoverActions: NSView?
  private weak var windowTitleLabel: NSTextField?
  /// 详情面板在同一标签的常规状态刷新与收起/重开之间保持实例稳定，避免 Files 树和
  /// 搜索框先被销毁再创建。切换标签后按新 Tab ID 替换，防止订阅继续指向旧标签。
  private var detailsPanelController: DetailsPanelViewController?
  private var detailsPanelTabID: UUID?
  /// Open Quickly 通过独立 presentation 事件局部挂载；控制器跨关闭保留，以复用搜索框、
  /// 结果行与约束，普通开关不再重建侧栏、终端和详情面板。
  private var openQuicklyController: OpenQuicklyOverlayViewController?
  /// 底层 scrim 与面板分开：它只负责压低工作区对比度和接收外部点击，
  /// 不参与搜索或结果布局，避免深色阴影影响内容对齐。
  private var openQuicklyBackdrop: OpenQuicklyBackdropView?

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
    model.openQuicklyPresentationChanged
      .sink { [weak self] presented in self?.setOpenQuicklyPresented(presented) }
      .store(in: &modelSubscriptions)
    preferences.objectWillChange
      .sink { [weak self] _ in self?.scheduleRefresh() }
      .store(in: &modelSubscriptions)
    NotificationCenter.default.publisher(
      for: .panePictureInPictureOwnershipDidChange,
      object: model
    )
    .sink { [weak self] _ in self?.scheduleRefresh() }
    .store(in: &modelSubscriptions)
    // 详情面板显隐跟随持久化的偏好值；之后用户的每次切换再写回，重启窗口即恢复。
    model.isInspectorPresented = preferences.inspectorPresented
    model.$isInspectorPresented
      .removeDuplicates()
      .dropFirst()
      .sink { [weak preferences] presented in preferences?.inspectorPresented = presented }
      .store(in: &modelSubscriptions)
    model.ensureInitialTab()
    installPaneClickMonitor()
    observeWindowActivation()
    refresh()
  }

  /// 局部显示或移除 Open Quickly。关闭后终端焦点同步恢复，避免等待下一轮 run loop
  /// 时用户输入的第一个字符丢失。
  private func setOpenQuicklyPresented(_ presented: Bool) {
    guard isViewLoaded else { return }
    if presented {
      attachOpenQuicklyOverlay(refreshesTargets: false)
    } else {
      openQuicklyController?.didDismiss()
      openQuicklyController?.view.removeFromSuperview()
      openQuicklyController?.removeFromParent()
      openQuicklyBackdrop?.removeFromSuperview()
      if let tab = model.selectedTab { focusActivePane(in: tab) }
    }
  }

  /// 把缓存浮层约束到工作区顶层。使用相对两侧的上限约束，在窄窗口中仍保留边距；
  /// 700pt 首选宽度比旧实现更接近 Otty 的横向密度。
  private func attachOpenQuicklyOverlay(refreshesTargets: Bool) {
    let overlay: OpenQuicklyOverlayViewController
    if let cached = openQuicklyController {
      overlay = cached
      overlay.prepareForPresentation(
        filter: model.openQuicklyInitialFilter,
        refreshesTargets: refreshesTargets
      )
    } else {
      overlay = OpenQuicklyOverlayViewController(model: model)
      openQuicklyController = overlay
    }
    if overlay.parent !== self { addChild(overlay) }
    // `didPresent` 需要立即更新已构建的 chip；先加载视图，使用户仍按住
    // 打开面板时的 ⌘ 时，首帧就能显示快捷键提示。
    overlay.loadViewIfNeeded()
    if openQuicklyBackdrop?.superview !== view {
      let backdrop = OpenQuicklyBackdropView { [weak model] in
        model?.isOpenQuicklyPresented = false
      }
      openQuicklyBackdrop = backdrop
      view.addSubview(backdrop)
      backdrop.pinEdges(to: view)
    }
    guard overlay.view.superview !== view else {
      view.addSubview(overlay.view, positioned: .above, relativeTo: openQuicklyBackdrop)
      overlay.didPresent()
      return
    }
    view.addSubview(overlay.view)
    overlay.view.translatesAutoresizingMaskIntoConstraints = false
    let preferredWidth = overlay.view.widthAnchor.constraint(equalToConstant: 700)
    // 750 会被 All/文件夹页的长路径固有宽度挤破，导致不同过滤器下浮层忽宽忽窄。
    // 999 固定正常窗口宽度；required 的两侧边距约束在窄窗口中仍可优先让它收缩。
    preferredWidth.priority = NSLayoutConstraint.Priority(999)
    NSLayoutConstraint.activate([
      overlay.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      overlay.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 68),
      preferredWidth,
      overlay.view.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 28),
      overlay.view.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -28),
      overlay.view.heightAnchor.constraint(lessThanOrEqualToConstant: 520),
    ])
    // 必须在视图已连到 window 之后再建立搜索焦点；提前调用时
    // `makeFirstResponder` 只会留在 NSWindow，用户第一次点击无法直接输入。
    overlay.didPresent()
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
    center.publisher(for: NSApplication.didResignActiveNotification)
      .sink { [weak self] _ in
        // Open Quickly 是短暂的键盘导航层，不应跨应用切换保留；
        // 回到 Aster 后由用户再次显式打开，避免隐藏层突然接收输入。
        guard self?.model.isOpenQuicklyPresented == true else { return }
        self?.model.isOpenQuicklyPresented = false
      }
      .store(in: &modelSubscriptions)
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
    // 终端视图由 Session 长期持有，但从视图树移除时 AppKit 仍可能清掉 first
    // responder。记录正在输入的实例，重排完成后同步恢复，避免异步回焦前丢一个按键。
    let previouslyFocusedTerminal = view.window?.firstResponder as? AsterTerminalView
    if !model.isOpenQuicklyPresented { openQuicklyController?.invalidateTargets() }
    observeTabs()
    retainedObjects.removeAll()
    paneHosts.removeAll()
    editorTextViews.removeAll()
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

    if let tab = model.selectedTab, model.isComposerPresented,
      model.composerState(for: tab.activePaneID).presentation == .floating
    {
      let composer = makeAgentComposer(tab)
      view.addSubview(composer)
      composer.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        composer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
        composer.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -42),
        composer.widthAnchor.constraint(equalToConstant: 560),
      ])
    }

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
    } else if model.isOpenQuicklyPresented {
      attachOpenQuicklyOverlay(refreshesTargets: true)
    } else if model.isGlobalFindPresented {
      let globalFind = GlobalFindOverlayViewController(model: model)
      addChild(globalFind)
      retainedObjects.append(globalFind)
      view.addSubview(globalFind.view)
      globalFind.view.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        globalFind.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        globalFind.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 82),
        globalFind.view.widthAnchor.constraint(equalToConstant: 680),
        globalFind.view.heightAnchor.constraint(lessThanOrEqualToConstant: 520),
      ])
    } else if model.isAgentHistoryPresented {
      let history = AgentHistoryOverlayViewController(model: model)
      addChild(history)
      retainedObjects.append(history)
      view.addSubview(history.view)
      history.view.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        history.view.centerXAnchor.constraint(equalTo: view.centerXAnchor),
        history.view.topAnchor.constraint(equalTo: view.topAnchor, constant: 64),
        history.view.widthAnchor.constraint(equalToConstant: 760),
        history.view.heightAnchor.constraint(equalToConstant: 560),
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

    let blocksTerminalFocus = model.isFindPresented || model.isPalettePresented
      || model.isOpenQuicklyPresented || model.isGlobalFindPresented
      || model.isAgentHistoryPresented
    let restoredTerminalFocus: Bool
    if !blocksTerminalFocus, let terminal = previouslyFocusedTerminal,
      terminal.window === view.window, let window = view.window
    {
      restoredTerminalFocus = window.makeFirstResponder(terminal)
    } else {
      restoredTerminalFocus = false
    }

    // 视图树刚重建，first responder 还停在被移除的旧视图上；等本轮布局结束后把
    // 键盘焦点交还给当前面板。只聚焦活动面板——过去对每个终端都调用 focus()，
    // 最后渲染的那个会抢走输入焦点，用户看到的焦点框与真正接收按键的面板不一致。
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      // 搜索框和命令面板各自安排 first responder；此时不能再把焦点抢回终端，
      // 否则 Vi `/`/`?` 打开的查找栏虽然可见，却无法接收查询文本。
      if !restoredTerminalFocus,
        !self.model.isFindPresented, !self.model.isPalettePresented,
        !self.model.isOpenQuicklyPresented, !self.model.isGlobalFindPresented,
        !self.model.isAgentHistoryPresented,
        let tab = self.model.selectedTab
      {
        self.focusActivePane(in: tab)
      }
      self.updateWindowActivationOverlay()
    }
  }

  private func observeTabs() {
    tabSubscriptions.removeAll()
    for tab in model.tabs {
      tab.objectWillChange
        .sink { [weak self] _ in self?.scheduleRefresh() }
        .store(in: &tabSubscriptions)
      for runtime in tab.runtimes.values {
        runtime.$isReadOnly
          .dropFirst()
          .sink { [weak self] _ in self?.scheduleRefresh() }
          .store(in: &tabSubscriptions)
      }
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
      tab.documentLineRevealRequested
        .sink { [weak self] request in
          self?.revealEditorLine(request.line, paneID: request.paneID)
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
      // PiP 拥有长期终端容器时，主工作区只显示占位；这里也不能跨窗口把
      // first responder 强行交给 PiP 中的终端。
      guard !PanePictureInPictureOwnership.isOwnedByPictureInPicture(session) else { return }
      session.focus()
      return
    }
    guard let host = paneHosts[tab.activePaneID], let window = host.window else { return }
    window.makeFirstResponder(host)
  }

  private func revealEditorLine(_ line: Int, paneID: UUID) {
    guard let textView = editorTextViews[paneID], line > 0 else { return }
    let source = textView.string as NSString
    var location = 0
    for _ in 1..<line {
      let range = source.lineRange(for: NSRange(location: location, length: 0))
      location = NSMaxRange(range)
      if location >= source.length { break }
    }
    let range = source.lineRange(for: NSRange(location: min(location, source.length), length: 0))
    textView.setSelectedRange(range)
    textView.scrollRangeToVisible(range)
    textView.window?.makeFirstResponder(textView)
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
      // 因此只剩「标题栏 + 分隔条」的高度，两个终端都被压成 0。
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
      let selectedTabID = model.selectedTabID
      let details: DetailsPanelViewController
      if let cached = detailsPanelController, detailsPanelTabID == selectedTabID {
        details = cached
      } else {
        detailsPanelController = nil
        detailsPanelTabID = nil
        details = DetailsPanelViewController(model: model, preferences: preferences)
        detailsPanelController = details
        detailsPanelTabID = selectedTabID
      }
      if details.parent !== self { addChild(details) }
      details.synchronizeAppearanceIfNeeded()
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
      // 收起时仅从布局移除，保留已完成布局的四页与检查结果；同一标签再次展开可
      // 直接复用。若期间切换标签，展开分支会按 Tab ID 创建新控制器。
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
          onClose: { [weak self, weak tab] in
            guard let tab else { return }
            self?.model.closeTab(id: tab.id)
          },
          action: { [weak self, weak tab] in
            guard let tab else { return }
            self?.model.select(tab)
          },
          onDragEnd: { [weak self, weak tab] point in
            guard let self, let tab else { return }
            (NSApp.delegate as? AsterAppDelegate)?.moveTab(
              tab.id, from: self.model, toScreenPoint: point)
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
        onClose: nil,
        action: { [weak self, weak tab] in
          guard let tab else { return }
          self?.model.select(tab)
        },
        onDragEnd: { [weak self, weak tab] point in
          guard let self, let tab else { return }
          (NSApp.delegate as? AsterAppDelegate)?.moveTab(
            tab.id, from: self.model, toScreenPoint: point)
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
    let composer = model.isComposerPresented
      && model.composerState(for: tab.activePaneID).presentation == .docked
      ? makeAgentComposer(tab) : nil
    if let composer { inner.addArrangedSubview(composer) }
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
    if let composer {
      constraints.append(paneHost.bottomAnchor.constraint(equalTo: composer.topAnchor))
      constraints.append(composer.bottomAnchor.constraint(equalTo: inner.bottomAnchor))
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

    // 右侧详情面板的悬停切换按钮：指针进入标题栏右端感应区时淡入。面板展开后不
    // 渲染该按钮（收起入口在面板 header 右侧），标题重新获得完整可用宽度。
    var titleTrailing: NSLayoutConstraint
    if model.isInspectorPresented {
      titleTrailing = title.trailingAnchor.constraint(
        lessThanOrEqualTo: background.trailingAnchor, constant: -12)
    } else {
      let inspectorToggle = ActionButton(symbol: "sidebar.right", bezelStyle: .accessoryBarAction) {
        [weak self] in self?.model.toggleInspector()
      }
      inspectorToggle.isBordered = false
      inspectorToggle.toolTip = "展开详情面板"
      inspectorToggle.identifier = NSUserInterfaceItemIdentifier("workspace-inspector-toggle")
      inspectorToggle.contentTintColor = AsterTheme.secondaryInk
      let hoverReveal = TitlebarHoverRevealView(content: inspectorToggle)
      background.addSubview(hoverReveal)
      hoverReveal.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        hoverReveal.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -2),
        hoverReveal.topAnchor.constraint(equalTo: background.topAnchor),
        hoverReveal.bottomAnchor.constraint(equalTo: background.bottomAnchor),
      ])
      titleTrailing = title.trailingAnchor.constraint(
        lessThanOrEqualTo: hoverReveal.leadingAnchor, constant: -8)
    }
    NSLayoutConstraint.activate([
      title.centerXAnchor.constraint(equalTo: background.centerXAnchor),
      title.centerYAnchor.constraint(equalTo: background.centerYAnchor),
      title.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: 12),
      titleTrailing,
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
    field.identifier = NSUserInterfaceItemIdentifier(tab.id.uuidString)
    let caseSensitive = NSButton(title: "Aa", target: nil, action: nil)
    caseSensitive.setButtonType(.toggle)
    caseSensitive.bezelStyle = .inline
    caseSensitive.toolTip = "区分大小写"
    let regularExpression = NSButton(title: ".*", target: nil, action: nil)
    regularExpression.setButtonType(.toggle)
    regularExpression.bezelStyle = .inline
    regularExpression.toolTip = "正则表达式"
    let summary = makeLabel("0 / 0", size: 10, color: AsterTheme.secondaryInk, monospaced: true)
    summary.alignment = .right
    summary.translatesAutoresizingMaskIntoConstraints = false
    summary.widthAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
    let controller = TerminalFindBarController(
      session: tab.activeSession,
      field: field,
      caseSensitiveButton: caseSensitive,
      regularExpressionButton: regularExpression,
      summaryLabel: summary
    )
    retainedObjects.append(controller)
    field.delegate = controller
    field.target = controller
    field.action = #selector(TerminalFindBarController.findNext(_:))
    caseSensitive.target = controller
    caseSensitive.action = #selector(TerminalFindBarController.optionsChanged(_:))
    regularExpression.target = controller
    regularExpression.action = #selector(TerminalFindBarController.optionsChanged(_:))
    let previous = ActionButton(symbol: "chevron.up") { [weak controller] in
      controller?.findPrevious(nil)
    }
    let next = ActionButton(symbol: "chevron.down") { [weak controller] in
      controller?.findNext(nil)
    }
    let close = ActionButton(symbol: "xmark") { [weak self, weak tab] in
      tab?.activeSession?.clearFind()
      self?.model.isFindPresented = false
    }
    let row = NSStackView(views: [
      field, summary, caseSensitive, regularExpression, previous, next, close,
    ])
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
      isActive: tab.activePaneID == descriptor.id,
      onExternalDrop: { [weak self, weak tab, weak runtime] pasteboard, zone in
        guard let self, let tab, let runtime else { return false }
        return self.handleExternalDrop(
          pasteboard,
          zone: zone,
          runtime: runtime,
          tab: tab
        )
      }
    ) { [weak tab] in
      tab?.setActivePane(descriptor.id)
    }
    paneHosts[descriptor.id] = host
    let content: NSView
    switch descriptor.kind {
    case .terminal: content = makeTerminalPane(runtime, tab: tab)
    case .editor: content = makeEditorPane(runtime, tab: tab)
    case .fileBrowser:
      let controller = FileBrowserViewController(runtime: runtime, tab: tab, model: model)
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

  /// Finder/浏览器/其它 App 的标准拖放入口。目录在绿色内半区创建继承该目录的终端，
  /// 蓝色外半区创建文件浏览器；普通文件创建只读预览，文本走完整粘贴保护链路。
  private func handleExternalDrop(
    _ pasteboard: NSPasteboard,
    zone: ExternalPaneDropZone,
    runtime: WorkspacePaneRuntime,
    tab: TerminalTabItem
  ) -> Bool {
    let urls = pasteboard.readObjects(
      forClasses: [NSURL.self],
      options: [.urlReadingFileURLsOnly: false]
    ) as? [URL] ?? []
    if urls.isEmpty, let text = pasteboard.string(forType: .string),
      let session = runtime.terminalSession
    {
      return session.pasteDroppedText(text)
    }
    var opened = false
    for url in urls.prefix(32) {
      if url.isFileURL {
        guard let values = try? url.resourceValues(forKeys: [
          .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
        ]), values.isSymbolicLink != true
        else { continue }
        if values.isDirectory == true {
          if zone.opensTerminal {
            tab.split(direction: zone.direction, workingDirectory: url.path)
          } else {
            tab.split(
              direction: zone.direction,
              kind: .fileBrowser,
              resourcePath: url.path,
              workingDirectory: url.path
            )
          }
          opened = true
        } else if values.isRegularFile == true {
          tab.split(
            direction: zone.direction,
            kind: .preview,
            resourcePath: url.path,
            workingDirectory: url.deletingLastPathComponent().path
          )
          opened = true
        }
      } else if ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
        opened = NSWorkspace.shared.open(url) || opened
      }
    }
    if opened { model.persistWorkspace() }
    return opened
  }

  private func makeTerminalPane(_ runtime: WorkspacePaneRuntime, tab: TerminalTabItem) -> NSView {
    guard let session = runtime.terminalSession else {
      return makeCenteredMessage(title: "终端不可用", symbol: "terminal")
    }
    session.onRequestFind = { [weak self] in
      self?.model.isFindPresented = true
    }
    session.onPasteIntoComposer = { [weak self] text in
      self?.model.appendToComposer(text, paneID: runtime.id)
    }
    session.onSendSelectionToChat = { [weak self] in
      self?.model.sendTerminalSelectionToChat()
    }
    if PanePictureInPictureOwnership.isOwnedByPictureInPicture(session) {
      let placeholder = makeCenteredMessage(
        title: "正在 Picture in Picture 中显示",
        symbol: "pip"
      )
      placeholder.identifier = NSUserInterfaceItemIdentifier(
        "pane-picture-in-picture-placeholder-\(runtime.id.uuidString)"
      )
      return placeholder
    }
    let host = session.makeTerminalHost(preferences: preferences)
    // PTY 只在 Pane 首次挂载时创建；Recipe 命令因此必须从这里启动。短暂让出主线程，
    // 给 Shell Integration 安装 prompt hook 的时间，后续命令再由完成事件严格串行推进。
    Task { @MainActor [weak model] in
      try? await Task.sleep(for: .milliseconds(350))
      model?.startPendingRecipeCommands(paneID: runtime.id)
    }
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
    let title = runtime.isReadOnly ? "\(name)  READ ONLY" : name
    column.addArrangedSubview(makePaneToolbar(title: title, symbol: "doc.text", save: runtime.saveDocument))
    if let error = runtime.documentError, runtime.documentText.isEmpty {
      column.addArrangedSubview(makeCenteredMessage(title: error, symbol: "exclamationmark.triangle"))
    } else {
      let textView = NSTextView()
      textView.string = runtime.documentText
      textView.isEditable = !runtime.isReadOnly
      textView.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
      textView.textColor = AsterTheme.ink
      textView.backgroundColor = AsterTheme.paper
      textView.isAutomaticQuoteSubstitutionEnabled = false
      textView.isAutomaticDashSubstitutionEnabled = false
      let delegate = DocumentTextDelegate(runtime: runtime)
      textView.delegate = delegate
      editorTextViews[runtime.id] = textView
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

  /// Composer 属于活动 Pane，但草稿状态保存在 AppModel；工作区因主题、标签或窗口
  /// 刷新重建视图时，文本与附件仍能恢复。发送与 Queue 都走领域状态机。
  private func makeAgentComposer(_ tab: TerminalTabItem) -> NSView {
    let paneID = tab.activePaneID
    let state = model.composerState(for: paneID)
    let queue = model.promptQueue(for: paneID)
    let host = NSView()
    host.wantsLayer = true
    host.layer?.backgroundColor = AsterTheme.panel.withAlphaComponent(0.98).cgColor
    host.layer?.borderWidth = 1
    host.layer?.borderColor = AsterTheme.hairline.cgColor
    host.layer?.cornerRadius = state.presentation == .floating ? 12 : 0
    host.shadow = state.presentation == .floating ? NSShadow() : nil
    host.shadow?.shadowBlurRadius = 20
    host.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.2)
    host.translatesAutoresizingMaskIntoConstraints = false
    host.heightAnchor.constraint(equalToConstant: 174).isActive = true

    let textView = NSTextView()
    textView.string = state.draft
    textView.font = NSFont.systemFont(ofSize: 12)
    textView.textColor = AsterTheme.ink
    textView.backgroundColor = AsterTheme.paper
    textView.isAutomaticQuoteSubstitutionEnabled = false
    textView.isAutomaticDashSubstitutionEnabled = false
    textView.textContainerInset = NSSize(width: 8, height: 7)
    let delegate = AgentComposerTextDelegate(model: model, paneID: paneID)
    textView.delegate = delegate
    retainedObjects.append(delegate)
    let scroll = NSScrollView()
    scroll.hasVerticalScroller = true
    scroll.borderType = .noBorder
    scroll.documentView = textView

    let provider = tab.activeSession?.activeAgentProvider?.commandName ?? "当前终端"
    let stateLabel: String = switch tab.activeSession?.agentTaskState {
    case .processing: "处理中"
    case .awaitingInput: "等待输入"
    case .idle, nil: "空闲"
    }
    let title = makeLabel(
      "Composer · \(provider) · \(stateLabel)",
      size: 10.5, weight: .semibold, color: AsterTheme.secondaryInk)
    let pin = ActionButton(title: state.isPinned ? "取消 Pin" : "Pin", bezelStyle: .inline) {
      [weak self] in
      self?.model.setComposerPinned(!state.isPinned, paneID: paneID)
    }
    let floatingTitle = state.presentation == .floating ? "停靠" : "浮动"
    let floating = ActionButton(title: floatingTitle, bezelStyle: .inline) { [weak self] in
      if state.presentation == .floating {
        self?.model.dockComposer(paneID: paneID)
      } else {
        self?.model.floatComposer(paneID: paneID)
      }
    }
    let close = ActionButton(symbol: "xmark", bezelStyle: .inline) { [weak self] in
      self?.model.closeComposer(paneID: paneID)
    }
    let header = NSStackView(views: [title, NSView(), pin, floating, close])
    header.orientation = .horizontal
    header.spacing = 6

    let attachments = NSStackView()
    attachments.orientation = .horizontal
    attachments.spacing = 5
    for attachment in state.attachments {
      let chip = ActionButton(title: "\(attachment.displayName) ×", bezelStyle: .inline) {
        [weak self] in
        self?.model.removeComposerAttachment(attachment.id, paneID: paneID)
      }
      chip.toolTip = attachment.fileURL.path
      attachments.addArrangedSubview(chip)
    }
    let queueLabel = makeLabel(
      "Queue \(queue.pending.count + (queue.inFlight == nil ? 0 : 1))",
      size: 10, color: AsterTheme.tertiaryInk, monospaced: true)
    let attach = ActionButton(title: "附件…", bezelStyle: .rounded) { [weak self] in
      let panel = NSOpenPanel()
      panel.canChooseFiles = true
      panel.canChooseDirectories = false
      panel.allowsMultipleSelection = true
      guard panel.runModal() == .OK else { return }
      for url in panel.urls { self?.model.addComposerAttachment(url, paneID: paneID) }
    }
    let enqueue = ActionButton(title: "Queue", bezelStyle: .rounded) { [weak self] in
      self?.model.queueComposer(paneID: paneID)
    }
    let send = ActionButton(title: "发送", bezelStyle: .rounded) { [weak self, weak textView] in
      guard let self else { return }
      if let value = textView?.string { _ = model.updateComposerDraft(value, paneID: paneID) }
      model.submitComposer(paneID: paneID)
    }
    send.keyEquivalent = "\r"
    let footer = NSStackView(views: [attachments, NSView(), queueLabel, attach, enqueue, send])
    footer.orientation = .horizontal
    footer.spacing = 7

    let column = NSStackView(views: [header, scroll, footer])
    column.orientation = .vertical
    column.spacing = 7
    column.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 8, right: 10)
    host.addSubview(column)
    column.pinEdges(to: host)
    return host
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
}

// MARK: - AppKit components

@MainActor
private final class AgentComposerTextDelegate: NSObject, NSTextViewDelegate {
  private weak var model: AppModel?
  private let paneID: UUID

  init(model: AppModel, paneID: UUID) {
    self.model = model
    self.paneID = paneID
  }

  func textDidChange(_ notification: Notification) {
    guard let textView = notification.object as? NSTextView else { return }
    _ = model?.updateComposerDraft(textView.string, paneID: paneID)
  }
}

/// 当前 Pane 查找栏的轻量控制器。实时搜索、选项和计数共享同一状态，避免每个按钮
/// 各自读取一套条件；控制器随工作区本轮视图树一起释放。
@MainActor
private final class TerminalFindBarController: NSObject, NSSearchFieldDelegate {
  private weak var session: TerminalSession?
  private weak var field: NSSearchField?
  private weak var caseSensitiveButton: NSButton?
  private weak var regularExpressionButton: NSButton?
  private weak var summaryLabel: NSTextField?

  init(
    session: TerminalSession?,
    field: NSSearchField,
    caseSensitiveButton: NSButton,
    regularExpressionButton: NSButton,
    summaryLabel: NSTextField
  ) {
    self.session = session
    self.field = field
    self.caseSensitiveButton = caseSensitiveButton
    self.regularExpressionButton = regularExpressionButton
    self.summaryLabel = summaryLabel
  }

  func controlTextDidChange(_ obj: Notification) {
    guard let field, !field.stringValue.isEmpty else {
      session?.clearFind()
      summaryLabel?.stringValue = "0 / 0"
      return
    }
    _ = perform(previous: false)
  }

  @objc func findNext(_ sender: Any?) { _ = perform(previous: false) }
  @objc func findPrevious(_ sender: Any?) { _ = perform(previous: true) }
  @objc func optionsChanged(_ sender: Any?) {
    session?.clearFind()
    _ = perform(previous: false)
  }

  @discardableResult
  private func perform(previous: Bool) -> Bool {
    guard let session, let term = field?.stringValue, !term.isEmpty else { return false }
    let caseSensitive = caseSensitiveButton?.state == .on
    let regularExpression = regularExpressionButton?.state == .on
    let found = session.findNext(
      term,
      previous: previous,
      caseSensitive: caseSensitive,
      regularExpression: regularExpression
    )
    let summary = session.findMatchSummary(
      term,
      caseSensitive: caseSensitive,
      regularExpression: regularExpression
    )
    summaryLabel?.stringValue = "\(summary.index) / \(summary.total)"
    return found
  }
}

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
  private let onDragEnd: (NSPoint) -> Void
  private var tracking: NSTrackingArea?
  private weak var verticalAccessory: NSView?
  private weak var closeButton: NSButton?
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
    style = horizontal ? (theme.style.horizontalTab ?? theme.style.tab) : theme.style.tab
    handler = action
    self.onDragEnd = onDragEnd
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
      // 状态附件与关闭按钮共用固定 28pt 槽位，悬停切换时标题不会
      // 水平抖动。关闭动作直接针对该 tab，不先选中后台标签。
      let accessorySlot = NSView()
      accessorySlot.translatesAutoresizingMaskIntoConstraints = false
      addSubview(accessorySlot)
      accessory.translatesAutoresizingMaskIntoConstraints = false
      accessorySlot.addSubview(accessory)
      let close = ActionButton(symbol: "xmark", bezelStyle: .inline) {
        onClose?()
      }
      close.identifier = NSUserInterfaceItemIdentifier("sidebar-tab-close-\(tab.id.uuidString)")
      close.toolTip = "关闭标签页"
      close.isBordered = false
      close.contentTintColor = AsterTheme.secondaryInk
      close.setAccessibilityLabel("关闭标签页 \(tab.title)")
      close.translatesAutoresizingMaskIntoConstraints = false
      accessorySlot.addSubview(close)
      verticalAccessory = accessory
      closeButton = close
      NSLayoutConstraint.activate([
        primary.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
        primary.centerYAnchor.constraint(equalTo: centerYAnchor),
        primary.trailingAnchor.constraint(
          lessThanOrEqualTo: accessorySlot.leadingAnchor, constant: -8),
        accessorySlot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        accessorySlot.centerYAnchor.constraint(equalTo: centerYAnchor),
        accessorySlot.widthAnchor.constraint(equalToConstant: 28),
        accessorySlot.heightAnchor.constraint(equalToConstant: 28),
        accessory.centerXAnchor.constraint(equalTo: accessorySlot.centerXAnchor),
        accessory.centerYAnchor.constraint(equalTo: accessorySlot.centerYAnchor),
        close.centerXAnchor.constraint(equalTo: accessorySlot.centerXAnchor),
        close.centerYAnchor.constraint(equalTo: accessorySlot.centerYAnchor),
        close.widthAnchor.constraint(equalToConstant: 24),
        close.heightAnchor.constraint(equalToConstant: 24),
      ])
      updateAccessoryVisibility()
    }
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
    let area = NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect], owner: self)
    addTrackingArea(area)
    tracking = area
  }

  override func mouseEntered(with event: NSEvent) { hovered = true }
  override func mouseExited(with event: NSEvent) { hovered = false }

  private func updateAccessoryVisibility() {
    verticalAccessory?.isHidden = hovered
    closeButton?.isHidden = !hovered
  }

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

/// 标题栏右端的悬停揭示容器：内含详情面板切换按钮与一小段感应边距，自持
/// tracking area（owner 是自身，不与控制器的侧栏悬停处理串扰）。只在面板收起
/// 时挂载——面板展开后标题栏不再渲染它，收起入口在面板 header 右侧。
private final class TitlebarHoverRevealView: NSView {
  init(content: NSView) {
    super.init(frame: .zero)
    alphaValue = 0
    addSubview(content)
    content.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      content.centerYAnchor.constraint(equalTo: centerYAnchor),
      content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
      // 感应区向左多延伸 18pt，按钮不必精确命中也能触发揭示。
      content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
      topAnchor.constraint(equalTo: content.topAnchor),
      bottomAnchor.constraint(equalTo: content.bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { nil }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach { removeTrackingArea($0) }
    addTrackingArea(
      NSTrackingArea(
        rect: bounds, options: [.activeInKeyWindow, .mouseEnteredAndExited, .inVisibleRect],
        owner: self, userInfo: nil))
  }

  override func mouseEntered(with event: NSEvent) { setRevealed(true) }
  override func mouseExited(with event: NSEvent) { setRevealed(false) }

  private func setRevealed(_ revealed: Bool) {
    NSAnimationContext.runAnimationGroup { context in
      context.duration = 0.15
      animator().alphaValue = revealed ? 1 : 0
    }
  }
}

/// 外部对象落在 Pane 边缘的语义。最靠边的蓝区打开对象 Pane；相邻的绿色内半区仅对
/// 目录有效，用该目录创建终端。文本不区分区域，始终粘贴到目标终端。
struct ExternalPaneDropZone: Equatable {
  let direction: SplitDirection
  let opensTerminal: Bool
}

@MainActor
private final class ActivePaneHostView: NSView {
  /// 所属面板的 ID：窗口级点击监视器沿 superview 链命中本视图后据此激活对应面板。
  /// 顶边感应带与把手的高度：太矮抓不到，太高会让顶部一整条都在触发淡入。
  private static let handleRevealHeight: CGFloat = 14
  let paneID: UUID
  private let activation: () -> Void
  private let onExternalDrop: (NSPasteboard, ExternalPaneDropZone) -> Bool
  private var dragHandle: PaneDragHandleView?
  private var handleTrackingArea: NSTrackingArea?
  private var inactiveOverlay: NSView?
  private var externalDropZone: ExternalPaneDropZone?
  /// 焦点状态可原地切换：切换聚焦面板只改这层遮罩的可见性，不重建视图树。
  var isActivePane: Bool {
    didSet { inactiveOverlay?.isHidden = isActivePane }
  }

  init(
    paneID: UUID,
    isActive: Bool,
    onExternalDrop: @escaping (NSPasteboard, ExternalPaneDropZone) -> Bool,
    activation: @escaping () -> Void
  ) {
    self.paneID = paneID
    self.activation = activation
    self.onExternalDrop = onExternalDrop
    isActivePane = isActive
    super.init(frame: .zero)
    wantsLayer = true
    registerForDraggedTypes([.fileURL, .URL, .string])
  }

  required init?(coder: NSCoder) { nil }

  override func mouseDown(with event: NSEvent) {
    activation()
    super.mouseDown(with: event)
  }

  override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
    updateExternalDropZone(sender)
  }

  override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
    updateExternalDropZone(sender)
  }

  override func draggingExited(_ sender: NSDraggingInfo?) {
    externalDropZone = nil
    layer?.borderWidth = 0
  }

  override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
    defer { draggingExited(sender) }
    guard let externalDropZone else { return false }
    activation()
    return onExternalDrop(sender.draggingPasteboard, externalDropZone)
  }

  private func updateExternalDropZone(_ sender: NSDraggingInfo) -> NSDragOperation {
    let point = convert(sender.draggingLocation, from: nil)
    guard bounds.contains(point), bounds.width > 0, bounds.height > 0 else { return [] }
    let distances: [(SplitDirection, CGFloat)] = [
      (.left, point.x), (.right, bounds.width - point.x),
      (.down, point.y), (.up, bounds.height - point.y),
    ]
    guard let nearest = distances.min(by: { $0.1 < $1.1 }) else { return [] }
    let dimension = nearest.0.isHorizontal ? bounds.width : bounds.height
    guard nearest.1 <= dimension * 0.30 else { return [] }
    externalDropZone = ExternalPaneDropZone(
      direction: nearest.0,
      opensTerminal: nearest.1 > dimension * 0.15
    )
    layer?.borderWidth = 2
    layer?.borderColor = (externalDropZone?.opensTerminal == true
      ? NSColor.systemGreen : AsterTheme.accent).cgColor
    return .copy
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
  private let model: AppModel
  private var directory: URL
  private var entries: [URL] = []
  private let table = NSTableView()

  init(runtime: WorkspacePaneRuntime, tab: TerminalTabItem, model: AppModel) {
    self.runtime = runtime
    self.tab = tab
    self.model = model
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
      menu.addItem(ActionMenuItem(title: "发送到 Chat") { [weak self] in
        self?.model.sendFileToChat(url)
      })
    }
    menu.addItem(.separator())
    menu.addItem(ActionMenuItem(title: "复制绝对路径") {
      NSPasteboard.general.clearContents()
      NSPasteboard.general.setString(url.path, forType: .string)
    })
    menu.addItem(ActionMenuItem(title: "在新终端中打开所在目录") { [weak tab] in
      let directory = self.isDirectory(url) ? url.path : url.deletingLastPathComponent().path
      tab?.split(direction: .right, workingDirectory: directory)
    })
    menu.addItem(ActionMenuItem(title: "在当前终端中 cd 到所在目录") { [weak tab] in
      let directory = self.isDirectory(url) ? url.path : url.deletingLastPathComponent().path
      _ = tab?.openDirectoryInTerminal(directory)
    })
    menu.addItem(.separator())
    menu.addItem(ActionMenuItem(title: "在 Finder 中显示") {
      NSWorkspace.shared.activateFileViewerSelecting([url])
    })
    menu.addItem(ActionMenuItem(title: "使用默认应用打开") {
      NSWorkspace.shared.open(url)
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

/// Open Quickly 展示时覆盖工作区的轻量 scrim。点击浮层外部关闭，但不抢占
/// 面板内部的鼠标和键盘事件。
@MainActor
private final class OpenQuicklyBackdropView: NSView {
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
private final class OpenQuicklyPanelView: NSView {
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
      NSRect(x: bounds.minX, y: bounds.minY, width: searchRect.minX - bounds.minX,
        height: bounds.height),
      NSRect(x: searchRect.maxX, y: bounds.minY, width: bounds.maxX - searchRect.maxX,
        height: bounds.height),
      NSRect(x: searchRect.minX, y: bounds.minY, width: searchRect.width,
        height: searchRect.minY - bounds.minY),
      NSRect(x: searchRect.minX, y: searchRect.maxY, width: searchRect.width,
        height: bounds.maxY - searchRect.maxY),
    ]
    for rect in rects where rect.width > 0 && rect.height > 0 {
      addCursorRect(rect, cursor: .arrow)
    }
  }
}

/// Borderless NSSearchField 的图标/文本布局。起点基于 bounds 而不是 bezel，
/// 因此关闭系统边框后仍保持 8pt 图标左边距和 8pt 图文间距。
@MainActor
private final class OpenQuicklySearchFieldCell: NSSearchFieldCell {
  override func searchButtonRect(forBounds rect: NSRect) -> NSRect {
    let size: CGFloat = 16
    return NSRect(x: rect.minX + 4, y: rect.midY - size / 2, width: size, height: size)
  }

  override func searchTextRect(forBounds rect: NSRect) -> NSRect {
    var textRect = super.searchTextRect(forBounds: rect)
    let leading = rect.minX + 28
    let consumed = max(0, leading - textRect.minX)
    textRect.origin.x = leading
    textRect.size.width = max(0, textRect.width - consumed)
    return textRect
  }
}

/// Open Quickly 浮层:标签条过滤 + 双行结果列表(图标/相对时间/类型徽章)+ 底部
/// 快捷键栏。数据与匹配在 AsterCore 的 OpenQuicklyIndex,这里只负责展示与动作接线。
@MainActor
private final class OpenQuicklyOverlayViewController: NSViewController, NSSearchFieldDelegate {
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

    // 系统 borderless NSSearchField 不会自动为搜索图标重新计算文本起点，
    // 使用显式 cell 留出 24pt，避免 placeholder 与图标重叠。
    search.cell = OpenQuicklySearchFieldCell(textCell: "")
    search.placeholderString = "搜索命令、URL、文件…"
    search.identifier = NSUserInterfaceItemIdentifier("open-quickly-search")
    // 保留 NSSearchField 的搜索图标、IME 和文本编辑能力，只去掉会形成蓝色
    // 长条的系统 bezel/focus ring；插入光标仍清晰表示输入焦点。
    search.isBezeled = false
    search.drawsBackground = false
    search.focusRingType = .none
    search.cell?.focusRingType = .none
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
    host.searchInputView = search

    let column = NSStackView()
    column.orientation = .vertical
    column.alignment = .width
    column.spacing = 8
    column.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 10, right: 14)
    let filterStrip = makeFilterStrip()
    let resultsScroll = makeResultsScroll()
    let separator = makeSeparator()
    let footer = makeFooter()
    let fullWidthViews = [search, filterStrip, resultsScroll, separator, footer]
    for arrangedView in fullWidthViews {
      column.addArrangedSubview(arrangedView)
      arrangedView.translatesAutoresizingMaskIntoConstraints = false
      arrangedView.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -28).isActive = true
    }
    host.addSubview(column)
    column.pinEdges(to: host)
    view = host
    rebuildTargets()
    reload()
    DispatchQueue.main.async { [weak search] in search?.window?.makeFirstResponder(search) }
  }

  /// 展示边界安装本地事件监视。使用 local monitor 而不是仅覆写搜索框
  /// `keyDown`，因为 AppKit 会在 first responder 之前处理 `⌘W` 等菜单等价键。
  func didPresent() {
    setCommandHintsVisible(NSEvent.modifierFlags.contains(.command))
    if let window = view.window {
      // `initialFirstResponder` 保证浮层恰在窗口激活过程中打开时，成为 key
      // 后仍落到搜索框；已经是 key window 时则由 `makeFirstResponder` 立即生效。
      window.initialFirstResponder = search
      window.makeFirstResponder(search)
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
      // 直接把浮层 bounds 投影到 window 坐标后判定，与 `event.locationInWindow`
      // 使用同一坐标系。反向转换事件点在 full-size content view 与标题栏共存时
      // 可能把搜索框内点击误判成外部点击。
      let overlayRectInWindow = view.convert(view.bounds, to: nil)
      if !overlayRectInWindow.contains(event.locationInWindow) {
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
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
      resultsStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      resultsStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      resultsStack.topAnchor.constraint(equalTo: document.topAnchor),
      document.bottomAnchor.constraint(greaterThanOrEqualTo: resultsStack.bottomAnchor),
      scroll.heightAnchor.constraint(lessThanOrEqualToConstant: 400),
    ])
    return scroll
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
    rows.forEach { $0.detachFromResultsStack() }
    resultsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
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
          guard let self, let index = self.visibleTargets.firstIndex(where: {
            $0.item.id == item.id
          }) else { return }
          self.selectedIndex = index
          self.activateSelection()
        }
        resultsStack.addArrangedSubview(row)
        row.attach(to: resultsStack)
        rows.append(row)
      }
    }
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
      result.append(Target(
        item: .init(
          id: "opened:\(tab.id.uuidString)", kind: .opened, title: tab.title,
          detail: tab.workingDirectory),
        symbol: "macwindow", badge: "标签", accented: false, actionTitle: "跳转到标签"
      ) { [weak model, weak tab] in
        guard let tab else { return }
        model?.select(tab)
        model?.isOpenQuicklyPresented = false
      })
      result[result.count - 1].menuActions = [(
        title: "关闭标签",
        handler: { [weak model, weak tab] in
          guard let tab else { return }
          model?.select(tab)
          model?.isOpenQuicklyPresented = false
          model?.closeSelectedTab()
        }
      )]
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
        result.append(Target(
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
      result.append(Target(
        item: .init(
          id: "recent:\(snapshot.id.uuidString)", kind: .recent, title: snapshot.title,
          detail: directory),
        symbol: "clock.arrow.circlepath", badge: "最近", accented: false,
        actionTitle: "恢复标签"
      ) { [weak model] in _ = model?.reopenClosedTab(id: snapshot.id) })
    }
    for match in model.frequentFolderMatches(limit: 200) {
      result.append(Target(
        item: .init(
          id: "folder:\(match.path)", kind: .folder,
          title: URL(fileURLWithPath: match.path).lastPathComponent,
          detail: match.path, score: match.score),
        symbol: "folder", badge: "文件夹", accented: false, actionTitle: "新建标签"
      ) { [weak model] in model?.newTab(workingDirectory: match.path, hasContent: true) })
      result[result.count - 1].menuActions = [(
        title: "在 Finder 中显示",
        handler: { [weak model] in
          NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: match.path)
          model?.isOpenQuicklyPresented = false
        }
      )]
    }
    for host in readSSHHosts() {
      result.append(Target(
        item: .init(id: "ssh:\(host.alias)", kind: .ssh, title: host.alias, detail: host.destination),
        symbol: "network", badge: "SSH", accented: false, actionTitle: "连接"
      ) { [weak model] in model?.openSSHHost(host) })
    }
    for provider in model.enabledAgentProviders {
      result.append(Target(
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
      result.append(Target(
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
      result[result.count - 1].menuActions = [(
        title: "Fork 会话",
        handler: { [weak model] in model?.continueAgentSession(metadata, kind: .fork) }
      )]
    }
    for url in readRecipeURLs() {
      result.append(Target(
        item: .init(
          id: "recipe:\(url.path)", kind: .recipe,
          title: url.deletingPathExtension().lastPathComponent, detail: url.path),
        symbol: "doc.text", badge: "Recipe", accented: false, actionTitle: "打开 Recipe"
      ) { [weak model] in model?.openRecipe(from: url) })
      result[result.count - 1].menuActions = [(
        title: "在 Finder 中显示",
        handler: { [weak model] in
          NSWorkspace.shared.selectFile(
            url.lastPathComponent,
            inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
          model?.isOpenQuicklyPresented = false
        }
      )]
    }
    return result
  }

  /// 「当前」页的提示词分组:pane ↔ session 没有可靠映射(metadata 不含 tty/pid),
  /// 用启发式取当前 tab 中正在运行 Agent 的 pane(优先聚焦 pane)的同 provider、
  /// updatedAt 最新会话,列出其最近 6 条 user prompt,点击粘贴回终端输入行。
  private func makePromptTargets(tab: TerminalTabItem) -> [Target] {
    let agentPanes = tab.layout.allPanes.compactMap {
      pane -> (paneID: UUID, provider: AgentProvider)? in
      guard let provider = tab.runtime(for: pane.id)?.terminalSession?.activeAgentProvider
      else { return nil }
      return (pane.id, provider)
    }
    let ordered = agentPanes.sorted { lhs, _ in lhs.paneID == tab.activePaneID }
    guard let match = ordered.first,
      let history = model.agentHistories
        .filter({ $0.metadata.configuration.provider == match.provider })
        .max(by: { $0.metadata.updatedAt < $1.metadata.updatedAt })
    else { return [] }
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
        model?.insertPromptIntoPane(tabID: tab.id, paneID: match.paneID, text: entry.text)
      }
      target.menuActions = [(
        title: "复制到剪贴板",
        handler: { [weak model] in
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(entry.text, forType: .string)
          model?.isOpenQuicklyPresented = false
        }
      )]
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
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants]
    ) else { return [] }
    return entries.filter { url in
      guard ["asterrecipe", "ottyrecipe"].contains(url.pathExtension.lowercased()),
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
      else { return false }
      return values.isRegularFile == true && values.isSymbolicLink != true
    }.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
      .prefix(200).map { $0 }
  }

  private func readRegularTextFile(_ url: URL, maximumBytes: Int) -> String? {
    guard let values = try? url.resourceValues(forKeys: [
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
private final class OpenQuicklyChip: NSButton {
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
      text.append(NSAttributedString(
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
    layer?.backgroundColor = isChipSelected
      ? AsterTheme.accent.withAlphaComponent(0.14).cgColor : NSColor.clear.cgColor
    layer?.borderColor = (isChipSelected ? AsterTheme.accent : AsterTheme.hairline)
      .withAlphaComponent(isChipSelected ? 0.70 : 0.72).cgColor
    setAccessibilityLabel(showsCommandHint ? "\(fullTitle), \(commandHint)" : fullTitle)
  }
}

/// Open Quickly 单行结果:SF Symbol 图标 + 标题/副标题双行 + 右侧相对时间与类型徽章。
@MainActor
private final class OpenQuicklyRowView: NSButton {
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
    badgeBackground.layer?.backgroundColor = AsterTheme.secondaryInk
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
    layer?.backgroundColor = isRowSelected
      ? AsterTheme.accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
  }
}

@MainActor
private final class GlobalFindOverlayViewController: NSViewController, NSSearchFieldDelegate {
  private let model: AppModel
  private let stack = NSStackView()
  private let search = OverlaySearchField()
  private let caseSensitive = NSButton(title: "Aa", target: nil, action: nil)
  private let regularExpression = NSButton(title: ".*", target: nil, action: nil)
  private let documents: [WorkspaceSearchDocument]
  private var results: [WorkspaceSearchResult] = []
  private var buttons: [NSButton] = []
  private var selectedIndex = 0

  init(model: AppModel) {
    self.model = model
    documents = model.workspaceSearchDocuments()
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
    search.placeholderString = "在全部终端和已打开文件中查找…"
    search.delegate = self
    search.onMove = { [weak self] delta in self?.moveSelection(delta) }
    search.onActivate = { [weak self] _ in self?.activateSelection() }
    search.onCancel = { [weak model] in model?.isGlobalFindPresented = false }
    for button in [caseSensitive, regularExpression] {
      button.setButtonType(.toggle)
      button.bezelStyle = .inline
      button.target = self
      button.action = #selector(optionsChanged(_:))
    }
    caseSensitive.toolTip = "区分大小写"
    regularExpression.toolTip = "正则表达式"
    let header = NSStackView(views: [search, caseSensitive, regularExpression])
    header.orientation = .horizontal
    header.spacing = 8
    stack.addArrangedSubview(header)
    host.addSubview(stack)
    stack.pinEdges(to: host)
    view = host
    reload()
    DispatchQueue.main.async { [weak search] in search?.window?.makeFirstResponder(search) }
  }

  func controlTextDidChange(_ obj: Notification) {
    selectedIndex = 0
    reload()
  }

  @objc private func optionsChanged(_ sender: Any?) {
    selectedIndex = 0
    reload()
  }

  private func reload() {
    while stack.arrangedSubviews.count > 1 {
      stack.arrangedSubviews.last?.removeFromSuperview()
    }
    results = GlobalWorkspaceSearch.search(
      documents: documents,
      query: search.stringValue,
      options: .init(
        caseSensitive: caseSensitive.state == .on,
        regularExpression: regularExpression.state == .on
      ),
      maximumResults: 500
    )
    buttons.removeAll()
    if search.stringValue.isEmpty {
      stack.addArrangedSubview(makeLabel("输入内容以搜索当前窗口的全部 Pane。", size: 11, color: AsterTheme.secondaryInk))
      return
    }
    if results.isEmpty {
      stack.addArrangedSubview(makeLabel("没有匹配项", size: 11, color: AsterTheme.secondaryInk))
      return
    }
    for result in results.prefix(12) {
      let button = ActionButton(
        title: "\(result.title):\(result.line)    \(result.preview)", bezelStyle: .inline
      ) { [weak model] in
        model?.revealWorkspaceLocation(
          tabID: result.tabID,
          paneID: result.paneID,
          absoluteRow: result.absoluteRow
        )
      }
      button.alignment = .left
      button.isBordered = false
      button.translatesAutoresizingMaskIntoConstraints = false
      button.heightAnchor.constraint(equalToConstant: 34).isActive = true
      stack.addArrangedSubview(button)
      buttons.append(button)
    }
    selectedIndex = min(selectedIndex, buttons.count - 1)
    updateSelectionAppearance()
  }

  private func moveSelection(_ delta: Int) {
    guard !buttons.isEmpty else { return }
    selectedIndex = (selectedIndex + delta + buttons.count) % buttons.count
    updateSelectionAppearance()
  }

  private func activateSelection() {
    guard results.indices.contains(selectedIndex) else { return }
    let result = results[selectedIndex]
    model.revealWorkspaceLocation(
      tabID: result.tabID,
      paneID: result.paneID,
      absoluteRow: result.absoluteRow
    )
  }

  private func updateSelectionAppearance() {
    for (index, button) in buttons.enumerated() {
      button.wantsLayer = true
      button.layer?.cornerRadius = 6
      button.layer?.backgroundColor = index == selectedIndex
        ? AsterTheme.accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
    }
  }
}

@MainActor
private final class AgentHistoryOverlayViewController: NSViewController, NSSearchFieldDelegate {
  private let model: AppModel
  private let search = OverlaySearchField()
  private let resultsStack = NSStackView()
  private let transcript = NSTextView()
  private var histories: [AgentSessionHistory] = []
  private var selectedIndex = 0
  private var historyCancellable: AnyCancellable?

  init(model: AppModel) {
    self.model = model
    super.init(nibName: nil, bundle: nil)
    historyCancellable = model.agentHistoriesChanged.sink { [weak self] _ in
      guard let self, self.isViewLoaded else { return }
      self.reload()
    }
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    let host = NSView()
    host.wantsLayer = true
    host.layer?.backgroundColor = AsterTheme.panel.withAlphaComponent(0.99).cgColor
    host.layer?.cornerRadius = 12
    host.layer?.borderWidth = 1
    host.layer?.borderColor = AsterTheme.hairline.cgColor
    host.shadow = NSShadow()
    host.shadow?.shadowBlurRadius = 24
    host.shadow?.shadowColor = NSColor.black.withAlphaComponent(0.22)

    search.placeholderString = "搜索 Agent 标题、项目、模型或 transcript…"
    search.delegate = self
    search.onMove = { [weak self] delta in self?.moveSelection(delta) }
    search.onActivate = { [weak self] _ in self?.resumeSelection() }
    search.onCancel = { [weak model] in model?.isAgentHistoryPresented = false }
    let refresh = ActionButton(symbol: "arrow.clockwise") { [weak model] in
      model?.reloadAgentHistory()
    }
    let close = ActionButton(symbol: "xmark") { [weak model] in
      model?.isAgentHistoryPresented = false
    }
    let header = NSStackView(views: [search, refresh, close])
    header.orientation = .horizontal
    header.spacing = 8

    resultsStack.orientation = .vertical
    resultsStack.spacing = 4
    let resultsScroll = NSScrollView()
    resultsScroll.hasVerticalScroller = true
    resultsScroll.drawsBackground = false
    resultsScroll.documentView = resultsStack
    resultsStack.translatesAutoresizingMaskIntoConstraints = false
    resultsStack.widthAnchor.constraint(equalTo: resultsScroll.contentView.widthAnchor).isActive = true
    resultsScroll.translatesAutoresizingMaskIntoConstraints = false
    resultsScroll.widthAnchor.constraint(equalToConstant: 270).isActive = true

    transcript.isEditable = false
    transcript.isSelectable = true
    transcript.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
    transcript.textColor = AsterTheme.ink
    transcript.backgroundColor = AsterTheme.paper
    transcript.textContainerInset = NSSize(width: 12, height: 12)
    let transcriptScroll = NSScrollView()
    transcriptScroll.hasVerticalScroller = true
    transcriptScroll.documentView = transcript
    let body = NSStackView(views: [resultsScroll, transcriptScroll])
    body.orientation = .horizontal
    body.spacing = 8
    body.distribution = .fill

    let resume = ActionButton(title: "Resume", bezelStyle: .rounded) { [weak self] in
      self?.continueSelection(.resume)
    }
    let fork = ActionButton(title: "Fork / Branch", bezelStyle: .rounded) { [weak self] in
      self?.continueSelection(.fork)
    }
    let footer = NSStackView(views: [NSView(), fork, resume])
    footer.orientation = .horizontal
    footer.spacing = 8
    let column = NSStackView(views: [header, body, footer])
    column.orientation = .vertical
    column.spacing = 8
    column.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
    host.addSubview(column)
    column.pinEdges(to: host)
    view = host
    reload()
    DispatchQueue.main.async { [weak search] in search?.window?.makeFirstResponder(search) }
  }

  func controlTextDidChange(_ obj: Notification) {
    selectedIndex = 0
    reload()
  }

  private func reload() {
    resultsStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
    let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    if query.isEmpty {
      histories = Array(model.agentHistories.prefix(100))
    } else if let matches = try? AgentHistorySearch.search(
      query: query, histories: model.agentHistories, limit: 100
    ) {
      histories = matches.compactMap { match in
        model.agentHistories.first { $0.metadata == match.metadata }
      }
    } else {
      histories = []
    }
    selectedIndex = min(selectedIndex, max(0, histories.count - 1))
    if histories.isEmpty {
      resultsStack.addArrangedSubview(
        makeLabel("没有 Agent 历史", size: 11, color: AsterTheme.secondaryInk))
      transcript.string = ""
      return
    }
    for (index, history) in histories.enumerated() {
      let metadata = history.metadata
      let button = ActionButton(
        title: "\(metadata.title)\n\(metadata.configuration.provider.commandName)",
        bezelStyle: .inline
      ) { [weak self] in
        self?.selectedIndex = index
        self?.updateSelection()
      }
      button.alignment = .left
      button.isBordered = false
      button.translatesAutoresizingMaskIntoConstraints = false
      button.heightAnchor.constraint(equalToConstant: 46).isActive = true
      resultsStack.addArrangedSubview(button)
    }
    updateSelection()
  }

  private func moveSelection(_ delta: Int) {
    guard !histories.isEmpty else { return }
    selectedIndex = (selectedIndex + delta + histories.count) % histories.count
    updateSelection()
  }

  private func updateSelection() {
    for (index, view) in resultsStack.arrangedSubviews.enumerated() {
      view.wantsLayer = true
      view.layer?.cornerRadius = 6
      view.layer?.backgroundColor = index == selectedIndex
        ? AsterTheme.accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
    }
    guard histories.indices.contains(selectedIndex) else {
      transcript.string = ""
      return
    }
    let history = histories[selectedIndex]
    transcript.string = history.transcript.entries.map { entry in
      let label: String = switch entry.kind {
      case .message(let role): role.rawValue.uppercased()
      case .reasoning: "REASONING"
      case .toolCall(let name): "TOOL · \(name)"
      case .attachment(let name): "ATTACHMENT · \(name ?? "file")"
      }
      return "[\(label)]\n\(entry.text)"
    }.joined(separator: "\n\n")
    transcript.scrollToBeginningOfDocument(nil)
  }

  private func resumeSelection() { continueSelection(.resume) }

  private func continueSelection(_ kind: AgentContinuationKind) {
    guard histories.indices.contains(selectedIndex) else { return }
    model.continueAgentSession(histories[selectedIndex].metadata, kind: kind)
  }
}

@MainActor
private final class PaletteOverlayViewController: NSViewController, NSSearchFieldDelegate {
  private let model: AppModel
  private let stack = NSStackView()
  private let search = OverlaySearchField()
  private var commands: [PaletteCommand] = []
  private var buttons: [NSButton] = []
  private var selectedIndex = 0

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
    search.onMove = { [weak self] delta in self?.moveSelection(delta) }
    search.onActivate = { [weak self] keepsOpen in self?.activateSelection(keepsOpen: keepsOpen) }
    search.onCancel = { [weak model] in model?.isPalettePresented = false }
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
    commands = CommandPalette.filter(model.paletteCommands, query: search.stringValue)
    selectedIndex = min(selectedIndex, max(0, commands.count - 1))
    buttons.removeAll()
    for command in commands.prefix(9) {
      let scope = switch command.scope {
      case .pane: "Pane"
      case .window: "Window"
      case .application: "App"
      }
      let button = ActionButton(title: "\(command.title)    [\(scope)]", bezelStyle: .inline) { [weak self] in
        self?.model.performPaletteCommand(command)
      }
      button.alignment = .left
      button.isBordered = false
      button.contentTintColor = AsterTheme.ink
      button.translatesAutoresizingMaskIntoConstraints = false
      button.heightAnchor.constraint(equalToConstant: 34).isActive = true
      stack.addArrangedSubview(button)
      buttons.append(button)
    }
    updateSelectionAppearance()
  }

  private func moveSelection(_ delta: Int) {
    guard !buttons.isEmpty else { return }
    selectedIndex = (selectedIndex + delta + buttons.count) % buttons.count
    updateSelectionAppearance()
  }

  private func activateSelection(keepsOpen: Bool) {
    guard commands.indices.contains(selectedIndex) else { return }
    model.performPaletteCommand(commands[selectedIndex], dismissesPalette: !keepsOpen)
    if keepsOpen { reload() }
  }

  private func updateSelectionAppearance() {
    for (index, button) in buttons.enumerated() {
      button.wantsLayer = true
      button.layer?.cornerRadius = 6
      button.layer?.backgroundColor = index == selectedIndex
        ? AsterTheme.accent.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
    }
  }
}

/// 命令面板、Open Quickly 与全局搜索共用的键盘导航搜索框。只截获列表导航键，
/// 其它组合键继续由 NSSearchField 处理，IME 与系统文本编辑行为不受影响。
@MainActor
private final class OverlaySearchField: NSSearchField {
  var onMove: ((Int) -> Void)?
  var onActivate: ((Bool) -> Void)?
  var onCancel: (() -> Void)?
  /// ⌘1…9 快速选中第 N 行；仅 Open Quickly 接线。
  var onQuickSelect: ((Int) -> Void)?
  /// ⌘K 弹出选中行的操作菜单；仅 Open Quickly 接线。
  var onShowActions: (() -> Void)?

  override func keyDown(with event: NSEvent) {
    // ⌘ 组合键优先于导航键判断:数字走 Quick Select,K 走操作菜单,其余放行。
    if event.modifierFlags.contains(.command),
      let character = event.charactersIgnoringModifiers?.first
    {
      if let digit = character.wholeNumberValue, (1...9).contains(digit) {
        onQuickSelect?(digit)
        return
      }
      if character == "k" {
        onShowActions?()
        return
      }
    }
    switch event.keyCode {
    case 125:
      onMove?(1)
    case 126:
      onMove?(-1)
    case 36, 76:
      onActivate?(event.modifierFlags.contains(.command))
    case 53:
      onCancel?()
    default:
      super.keyDown(with: event)
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
