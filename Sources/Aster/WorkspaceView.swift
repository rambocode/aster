import AppKit
import AsterCore
import Combine

/// 纯 AppKit 主工作区。控制器根据领域模型重建轻量窗口框架，但终端 `NSView` 由
/// `TerminalSession` 长期持有，标签切换或布局刷新不会重启 PTY、清空滚动历史或 TUI。
@MainActor
final class WorkspaceViewController: NSViewController {
  private enum SidebarSectionKind: Equatable {
    case ungrouped
    case project(SidebarProjectKind)
    case date
  }

  /// 分组身份与可见标题分离：本地同名目录仍按完整路径区分，侧栏只画末级目录名；
  /// SSH 则按 OpenSSH 最终 hostname 合并，并使用远端专属图标。
  private struct SidebarTabSection {
    let identifier: String?
    let title: String?
    let toolTip: String?
    let kind: SidebarSectionKind
    var tabs: [TerminalTabItem]
  }

  let model: AppModel
  private let preferences: AppPreferences
  /// 安全输入是进程级能力，生产窗口共享单例；测试可注入无副作用实现，避免调用全局
  /// Carbon 状态。窗口只观察真实系统保护状态，不自行维护第二份开关。
  private let secureInputCoordinator: SecureInputCoordinator
  /// 每个窗口独立串行文件渲染，避免多个 Pane 同时驱动 Highlighter/Markdown，
  /// 也避免窗口之间共享队列造成无关工作区互相阻塞。
  private let fileRenderer: any FileRendering
  /// 与当前窗口 UserDefaults suite 一一对应的 Panel 布局状态。左右栏拖动只写这里，
  /// 不再通过全局 `AppPreferences` 把所有窗口强制同步成同一宽度。
  let panelLayoutStore: WorkspacePanelLayoutStore
  private var modelSubscriptions: Set<AnyCancellable> = []
  private var tabSubscriptions: Set<AnyCancellable> = []
  /// 当前视图树内同一标签可能同时出现在一种标签布局中。数组保留扩展余地，并让活动
  /// 状态只原地更新行尾附件，不因 Agent hook 重建终端工作区。
  private var tabRowsByID: [UUID: [TabRowButton]] = [:]
  private var pendingTabActivityIDs: Set<UUID> = []
  private var tabActivityRefreshScheduled = false
  private var retainedObjects: [AnyObject] = []
  private var refreshScheduled = false
  /// 设置窗口独立于工作区，但配置仍是全局的。展示期间只延后配置触发的结构刷新，
  /// 避免设置控件动画与多个工作区整树重建争抢主线程；Tab/Pane 等工作区模型变化
  /// 必须继续立即刷新，现存终端偏好也会立即就地应用。
  private var settingsPresentationActive = false
  private var needsRefreshAfterSettingsDismiss = false
  private var terminalPreferenceApplyScheduled = false
  /// 设置窗口打开时仍要判断主题是否已离开当前渲染快照。普通配置继续延迟整树刷新，
  /// 但主题、明暗外观或标签栏布局变化必须实时重建主界面，不能只更新终端后等设置窗口关闭。
  private var renderedTheme: TerminalTheme?
  private var renderedAppearance: AppPreferences.Appearance?
  private var renderedTabBarLayout: TabBarLayout?
  /// 「视图」配置（标签规则 / 角标摆放）与徽章开关的最近渲染值：设置窗口打开期间只有
  /// 它们变化才重建标签行，避免每次快照都整树刷新。
  private var renderedViewConfiguration: ViewConfiguration?
  private var renderedBadgeSettings: [Bool] = []
  /// 当前渲染出来的面板容器。焦点切换只更新这里的状态与 first responder，
  /// 不重建视图树。
  private var paneHosts: [UUID: ActivePaneHostView] = [:]
  private var editorTextViews: [UUID: NSTextView] = [:]
  /// Prompt Queue 叠在单个活动 Pane 底部，不参与外层工作区 stack 的尺寸推导；这样
  /// 显隐不会拆下其它 Pane 或重启终端容器。
  private weak var promptQueueBar: PromptQueueBarView?
  /// 队列条当前挂在哪个 Pane 上。移除时要按这个 ID 把内容底边还回去，否则旧 host
  /// 会一直保留被顶起的高度。
  private var promptQueueBarHostPaneID: UUID?
  private var agentChatSheet: AgentChatSendSheetController?
  // `nonisolated(unsafe)`：只在主线程读写，但 deinit 是 nonisolated，需要能取回它
  // 来注销监视器，否则控制器释放后事件监视器仍然存活。
  private nonisolated(unsafe) var paneClickMonitor: Any?
  /// 命令面板、Open Quickly、全局查找和 Agent 历史共用窗口级 Esc 兜底。搜索框
  /// 失焦后事件不会经过 `OverlaySearchField`，因此不能只依赖控件自己的 keyDown。
  private nonisolated(unsafe) var workspaceOverlayKeyMonitor: Any?
  /// 主题选择器是独立 key Panel；展示期间后方工作区仍是实时预览画布，
  /// 不能暂停终端光标状态。
  private var themeSwitcherPresentationActive = false
  /// 垂直侧栏顶部「+ 新建 / 折叠」悬停动作区；refresh 整树重建后重新赋值。
  private weak var sidebarHoverActions: NSView?
  /// 两个动作按钮各自跟随不同的感应区：「+」跟随左栏，「折叠」跟随红绿灯行。
  private weak var sidebarAddTabButton: NSButton?
  private weak var sidebarToggleButton: NSButton?
  /// 「左栏」感应区（展开态是侧栏本体，折叠态是顶部悬停带）。
  private weak var sidebarHoverRegion: NSView?
  /// 「红绿灯行」感应区（展开态是侧栏顶部那一行，折叠态同为顶部悬停带）。
  private weak var titleBarHoverRegion: NSView?
  /// 顶部标题按钮只在悬停/弹层打开时切换成路径胶囊；普通状态继续显示活动程序标题。
  private weak var workspaceTitleButton: WorkspaceTitleButton?
  /// 安全输入活动时显示在中央工作区标题栏右侧，位置与 Otty 一致；状态变化只更新
  /// 该视图，不重建终端树或打断当前 TUI 输入。
  private weak var secureInputIndicator: SecureInputIndicatorView?
  /// 根视图右上角唯一的详情面板入口。面板显隐只更新这一实例的显示策略，不在
  /// Content 与 Inspector header 之间创建、移动或交换按钮。
  /// 强持有以跨 `refresh()` 复用同一实例；按钮回调弱捕获控制器，不形成引用环。
  private var inspectorToggleButton: IconHoverButton?
  /// 详情面板收起后的展开入口只响应工作区标题栏悬停。单独记录这块区域，避免复用
  /// 左栏红绿灯行的窄感应区，导致右端按钮只有移到窗口左上角才会出现。
  private weak var inspectorTitleBarHoverRegion: NSView?
  /// 收拢结束后的延迟隐藏截止时间；deadline 跨 `refresh()` 保留，即使其间因其它
  /// 模型事件重建工作区，新根视图上的按钮也会延续同一显示策略。
  private var inspectorToggleRevealDeadline: ContinuousClock.Instant?
  private var inspectorToggleHideTask: Task<Void, Never>?
  private var inspectorTitleBarIsHovered = false
  /// `NSPopover` 不会被视图层级强持有。控制器持有到关闭回调，避免点击标题后弹层
  /// 在下一轮 run loop 立刻释放。
  private var workspaceTitlePopover: NSPopover?
  /// 详情面板在同一标签的常规状态刷新与收起/重开之间保持实例稳定，避免 Files 树和
  /// 搜索框先被销毁再创建。切换标签后按新 Tab ID 替换，防止订阅继续指向旧标签。
  private var detailsPanelController: DetailsPanelViewController?
  private var detailsPanelTabID: UUID?
  /// 主窗口左、中、右三个语义区域的统一布局边界。详情显隐和宽度更新都只作用在
  /// 这里，不重建中栏里的终端视图或递归 Pane 树。
  private weak var workspacePanelSplitView: WorkspacePanelSplitView?
  /// Open Quickly 通过独立 presentation 事件局部挂载；控制器跨关闭保留，以复用搜索框、
  /// 结果行与约束，普通开关不再重建侧栏、终端和详情面板。
  private var openQuicklyController: OpenQuicklyOverlayViewController?
  /// 底层 scrim 与面板分开：它只负责压低工作区对比度和接收外部点击，
  /// 不参与搜索或结果布局，避免深色阴影影响内容对齐。
  private var openQuicklyBackdrop: OpenQuicklyBackdropView?

  init(
    model: AppModel,
    preferences: AppPreferences,
    panelLayoutStore: WorkspacePanelLayoutStore,
    fileRenderer: any FileRendering = FileRenderPipeline(),
    secureInputCoordinator: SecureInputCoordinator = .shared
  ) {
    self.model = model
    self.preferences = preferences
    self.panelLayoutStore = panelLayoutStore
    self.fileRenderer = fileRenderer
    self.secureInputCoordinator = secureInputCoordinator
    super.init(nibName: nil, bundle: nil)
  }

  /// 兼容单元测试和独立预览的临时入口。生产窗口必须显式注入与 `AppModel` 相同的
  /// defaults suite；临时入口使用唯一 suite，避免测试污染标准偏好域。
  convenience init(
    model: AppModel,
    preferences: AppPreferences,
    secureInputCoordinator: SecureInputCoordinator = .shared
  ) {
    let suite = "Aster.WorkspacePanelPreview.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    self.init(
      model: model,
      preferences: preferences,
      panelLayoutStore: WorkspacePanelLayoutStore(
        defaults: defaults,
        legacySidebarWidth: preferences.sidebarWidth
      ),
      secureInputCoordinator: secureInputCoordinator
    )
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    view = ThemeVisualEffectView(frame: NSRect(x: 0, y: 0, width: 1180, height: 760))
    view.identifier = NSUserInterfaceItemIdentifier("workspace-window")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    model.objectWillChange
      .sink { [weak self] _ in self?.scheduleRefresh() }
      .store(in: &modelSubscriptions)
    model.tabActivityChanged
      .sink { [weak self] tabID in self?.scheduleTabActivityRefresh(tabID) }
      .store(in: &modelSubscriptions)
    model.openQuicklyPresentationChanged
      .sink { [weak self] presented in self?.setOpenQuicklyPresented(presented) }
      .store(in: &modelSubscriptions)
    model.inspectorPresentationChanged
      .sink { [weak self, weak preferences] presented in
        preferences?.inspectorPresented = presented
        self?.setInspectorPresented(presented)
      }
      .store(in: &modelSubscriptions)
    model.promptQueuePresentationChanged
      .sink { [weak self] paneID in self?.setPromptQueuePresented(for: paneID) }
      .store(in: &modelSubscriptions)
    model.agentChatPresentationRequested
      .sink { [weak self] presentation in self?.presentAgentChatSheet(presentation) }
      .store(in: &modelSubscriptions)
    preferences.objectWillChange
      .sink { [weak self] _ in self?.schedulePreferenceRefresh() }
      .store(in: &modelSubscriptions)
    secureInputCoordinator.$isSystemProtectionActive
      .removeDuplicates()
      .sink { [weak self] active in self?.updateSecureInputIndicator(active: active) }
      .store(in: &modelSubscriptions)
    NotificationCenter.default.publisher(
      for: .panePictureInPictureOwnershipDidChange,
      object: model
    )
    .sink { [weak self] _ in self?.scheduleRefresh() }
    .store(in: &modelSubscriptions)
    // 详情面板显隐跟随持久化的偏好值；之后用户的每次切换再写回，重启窗口即恢复。
    model.isInspectorPresented = preferences.inspectorPresented
    model.ensureInitialTab()
    installPaneClickMonitor()
    installWorkspaceOverlayKeyMonitor()
    observeWindowActivation()
    refresh()
  }

  /// 布局落定后按指针实际位置对齐一次悬停按钮。`refresh()` 重建侧栏时不会补发
  /// 鼠标事件，只有在这里同步，点击标签页后指针仍停在侧栏上的「+」才不会消失。
  override func viewDidLayout() {
    super.viewDidLayout()
    updateSidebarHoverVisibility(animated: false)
    updateInspectorToggleVisibility(animated: false)
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

  /// 展开或收起详情面板时只更新当前内容区。控制器和已经加载的页面继续保留，终端
  /// 视图不离开层级，因此 first responder、拖选和高频 TUI 绘制都不会被打断。
  private func setInspectorPresented(_ presented: Bool) {
    guard isViewLoaded else { return }
    if presented {
      cancelInspectorToggleDelayedHide()
      setHoverButtonVisible(inspectorToggleButton, true, animated: false)
      attachDetailsPanelIfNeeded(animated: true)
    } else {
      detachDetailsPanelIfNeeded()
    }
  }

  /// 「视图 → 标签页与标题定制」规则对某个标签的解析结果（别名 / 图标 / 标题模板）。
  private func tabRuleOutcome(for tab: TerminalTabItem) -> TabTitleRuleService.Outcome {
    let index = (model.tabs.firstIndex { $0.id == tab.id } ?? 0) + 1
    return TabTitleRuleService.resolve(
      tab: tab, index: index, configuration: preferences.configuration.resolvedView)
  }

  /// 规则标题的优先级：用户手动固定名 > 规则模板 > Agent 会话标题 / 自动标题。
  private func ruleTitle(for tab: TerminalTabItem) -> String? {
    if case .name = tab.tabTitleOverride { return nil }
    return tabRuleOutcome(for: tab).renderedTitle
  }

  private func detailsControllerForSelectedTab() -> DetailsPanelViewController {
    let selectedTabID = model.selectedTabID
    if let cached = detailsPanelController, detailsPanelTabID == selectedTabID {
      return cached
    }
    let details = DetailsPanelViewController(model: model, preferences: preferences)
    detailsPanelController = details
    detailsPanelTabID = selectedTabID
    return details
  }

  /// 把详情面板作为 Container 内的 trailing Pane 接入内层 split。`refresh()` 初次构建
  /// 直接传入 Content + Inspector，只有用户主动开关时才从这里做局部插入动画。
  private func attachDetailsPanelIfNeeded(animated: Bool = false) {
    guard let split = workspacePanelSplitView else { return }
    let details = detailsControllerForSelectedTab()
    let resumesCachedController = details.isViewLoaded
    if details.parent !== self { addChild(details) }
    details.synchronizeAppearanceIfNeeded()
    details.synchronizeSectionsIfNeeded()
    if resumesCachedController { details.setPresentationActive(true) }
    split.insert(
      WorkspacePanel(role: .inspector, contentView: details.view),
      animated: animated
    )
  }

  /// 收起只移除 Inspector Panel；控制器仍由窗口持有，稍后重开时可复用查询、折叠
  /// 状态和已经完成的检查结果。
  private func detachDetailsPanelIfNeeded() {
    // 关闭动作开始时就为同一颗按钮启动延迟隐藏。按钮在根视图中始终保持原位，
    // Panel 裁剪与解除挂载都不会导致它移除或重新出现。
    beginInspectorToggleDelayedHide()
    guard let split = workspacePanelSplitView else {
      return
    }
    detailsPanelController?.setPresentationActive(false)
    split.removePanel(.inspector, animated: true) { [weak self] in
      guard let self, !model.isInspectorPresented else { return }
      // 真正解除挂载后重新起算，保证同一颗按钮从“Panel 完全关闭”这一刻起
      // 仍停留 650ms；鼠标不在标题栏时再淡出。
      self.beginInspectorToggleDelayedHide()
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
    // 必须在视图已连到 window 之后再进入展示边界，确保自动聚焦能建立 field editor，
    // 且内部点击命中测试使用当前窗口的最终视图层级。
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

  /// 窗口获得/失去键盘焦点时同步依赖焦点的界面状态。
  ///
  /// 失焦时刻意不叠任何褪色遮罩：终端内容在非活动窗口里也保持原色，
  /// 只有光标停闪与悬停控件隐藏这类「不接收输入」的提示。
  func updateWindowActivationOverlay() {
    // 还没上屏的视图按「活动」处理，避免测试与首帧出现无谓的状态抖动。
    let isActive = (view.window?.isKeyWindow ?? true) || themeSwitcherPresentationActive
    // 悬停按钮只在键盘焦点窗口露出，窗口失焦/回焦都要按当前指针位置重算一次。
    updateSidebarHoverVisibility(animated: false)
    updateInspectorToggleVisibility(animated: false)
    // 非活动窗口里的终端停止光标闪烁；后台标签的会话一并同步，切回来时状态已正确。
    for tab in model.tabs {
      for runtime in tab.runtimes.values {
        runtime.terminalSession?.setWindowActive(isActive)
      }
    }
  }

  deinit {
    if let paneClickMonitor { NSEvent.removeMonitor(paneClickMonitor) }
    if let workspaceOverlayKeyMonitor { NSEvent.removeMonitor(workspaceOverlayKeyMonitor) }
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

  /// 工作区级临时浮层无论当前 first responder 是搜索框、结果按钮还是终端，都由
  /// 所属窗口消费 Esc 并统一关闭。事件严格按 window 过滤，多窗口之间互不影响；
  /// 没有浮层时原样放行，保留终端、Vi Mode 与 Autocomplete 的既有 Esc 语义。
  private func installWorkspaceOverlayKeyMonitor() {
    workspaceOverlayKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) {
      [weak self] event in
      guard let self, event.keyCode == 53,
        let window = self.view.window, event.window === window,
        self.model.isPalettePresented || self.model.isOpenQuicklyPresented
          || self.model.isGlobalFindPresented || self.model.isAgentHistoryPresented
      else { return event }
      self.model.dismissWorkspaceOverlays()
      return nil
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
        routePaneClick(host.paneID, in: tab)
        return
      }
      candidate = current.superview
    }
  }

  /// 点击落点到面板激活的统一入口。点到的已经是活动 Pane 时 `activePaneID` 不变、
  /// 不发局部事件，但键盘焦点可能早已丢到浮层或容器上（终端视图自身不在 mouseDown
  /// 抢 first responder），必须在这里显式交接一次，点击才有自愈能力。
  func routePaneClick(_ paneID: UUID, in tab: TerminalTabItem) {
    if paneID == tab.activePaneID {
      focusActivePane(in: tab)
    } else {
      tab.setActivePane(paneID)
    }
  }

  // MARK: - 侧栏悬停动作区

  /// 生成「+ 新建标签页」与「折叠/展开标签栏」按钮行，两个按钮默认隐藏，各自跟随
  /// 不同的感应区淡入（见 `updateSidebarHoverVisibility`）。侧栏展开与折叠共用。
  ///
  /// 这里刻意不用 `NSStackView`：两个按钮显隐时机不同，栈会在隐藏时抽走槽位，让
  /// 「+」在折叠按钮出现前后左右横跳。改用固定约束后，任一按钮单独显示都不移位。
  private func makeHoverActionsRow(sidebarVisible: Bool) -> NSView {
    let row = HoverActionsContainerView()
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
      button.alphaValue = 0
      button.isHidden = true
      row.addSubview(button)
      NSLayoutConstraint.activate([
        button.widthAnchor.constraint(equalToConstant: 24),
        button.heightAnchor.constraint(equalToConstant: 22),
        button.topAnchor.constraint(equalTo: row.topAnchor),
        button.bottomAnchor.constraint(equalTo: row.bottomAnchor),
      ])
    }
    NSLayoutConstraint.activate([
      addTabButton.leadingAnchor.constraint(equalTo: row.leadingAnchor),
      toggleButton.leadingAnchor.constraint(equalTo: addTabButton.trailingAnchor, constant: 2),
      toggleButton.trailingAnchor.constraint(equalTo: row.trailingAnchor),
    ])
    sidebarAddTabButton = addTabButton
    sidebarToggleButton = toggleButton
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
    // 折叠态没有左栏，悬停带同时充当「左栏」与「红绿灯行」感应区：进入顶部即两个
    // 按钮一起淡入，否则用户无处触发「+」。
    sidebarHoverRegion = strip
    titleBarHoverRegion = strip
    strip.addTrackingArea(makeHoverTrackingArea())
    return content
  }

  /// 悬停感应区统一用「进入/移动/离开」三类事件驱动：只有 enter/exit 时，指针在
  /// 侧栏内部跨越红绿灯行边界不会有任何事件，折叠按钮就永远不会按行切换。
  private func makeHoverTrackingArea() -> NSTrackingArea {
    NSTrackingArea(
      rect: .zero,
      options: [
        .mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect,
      ],
      owner: self,
      userInfo: nil
    )
  }

  /// 三个入口都只做一件事：按指针的真实位置重算两个按钮各自的可见性。
  override func mouseEntered(with event: NSEvent) {
    updateSidebarHoverVisibility(animated: true)
    updateInspectorToggleVisibility(pointerInWindow: event.locationInWindow, animated: true)
  }

  override func mouseExited(with event: NSEvent) {
    updateSidebarHoverVisibility(animated: true)
    updateInspectorToggleVisibility(pointerInWindow: event.locationInWindow, animated: true)
  }

  override func mouseMoved(with event: NSEvent) {
    updateSidebarHoverVisibility(animated: true)
    updateInspectorToggleVisibility(pointerInWindow: event.locationInWindow, animated: true)
  }

  /// 「+」跟随左栏、「折叠」跟随红绿灯行，各自独立淡入淡出。
  ///
  /// 状态一律由指针当前位置推导，而不是记在事件回调里：`refresh()` 会整树重建侧栏，
  /// 新建的 tracking area 在指针不动时不会补发 `mouseEntered`。点一下标签页触发重建
  /// 后，若沿用事件态，「+」就会凭空消失，直到用户重新划出再划入侧栏。
  func updateSidebarHoverVisibility(animated: Bool) {
    let visibility = resolveSidebarHoverVisibility()
    setHoverButtonVisible(sidebarAddTabButton, visibility.showsNewTab, animated: animated)
    setHoverButtonVisible(sidebarToggleButton, visibility.showsCollapseToggle, animated: animated)
  }

  /// 把两块感应区与指针换算到同一套窗口坐标，再交给 `AsterCore` 的规则判定。
  /// 窗口不是键盘焦点窗口时不传指针，与 tracking area 的 `.activeInKeyWindow` 一致。
  private func resolveSidebarHoverVisibility() -> SidebarHoverActionVisibility {
    guard let window = view.window, window.isKeyWindow else { return .hidden }
    return SidebarHoverActionVisibility.resolve(
      pointer: window.mouseLocationOutsideOfEventStream,
      sidebar: hoverRegionRectInWindow(sidebarHoverRegion),
      titleBarRow: hoverRegionRectInWindow(titleBarHoverRegion)
    )
  }

  private func hoverRegionRectInWindow(_ region: NSView?) -> CGRect? {
    guard let region, region.window === view.window else { return nil }
    return region.convert(region.bounds, to: nil)
  }

  /// 右上角只有一颗根视图覆盖按钮。Inspector 展开时常显；收起后按延迟
  /// 与标题栏悬停状态决定显隐，不在 Content 与 Panel header 之间交接视图。
  private func updateInspectorToggleVisibility(
    pointerInWindow: NSPoint? = nil,
    animated: Bool,
    synchronizesPointerFromWindow: Bool = true
  ) {
    guard let button = inspectorToggleButton else { return }
    if model.isInspectorPresented {
      button.toolTip = "收起详情面板"
      setHoverButtonVisible(button, true, animated: animated)
      return
    }
    button.toolTip = "展开详情面板"

    if let window = view.window,
      let titleBarRect = hoverRegionRectInWindow(inspectorTitleBarHoverRegion)
    {
      if let pointerInWindow {
        // 正常事件只会由 `.activeInKeyWindow` tracking area 发送；显式坐标可直接用于
        // 更新缓存。延迟结束时使用这个事件态，避免读取已经过期的 event stream 坐标。
        inspectorTitleBarIsHovered = titleBarRect.contains(pointerInWindow)
      } else if synchronizesPointerFromWindow {
        inspectorTitleBarIsHovered =
          window.isKeyWindow
          && titleBarRect.contains(window.mouseLocationOutsideOfEventStream)
      }
    } else if synchronizesPointerFromWindow {
      inspectorTitleBarIsHovered = false
    }

    let withinPostCollapseDelay =
      inspectorToggleRevealDeadline.map {
        ContinuousClock.now < $0
      } ?? false
    setHoverButtonVisible(
      button,
      withinPostCollapseDelay || inspectorTitleBarIsHovered,
      animated: animated
    )
  }

  /// 保持根视图上的唯一按钮可见；若指针不在标题栏，650ms 后再淡出。指针仍在
  /// 标题栏时只结束延迟态，不隐藏按钮。
  private func beginInspectorToggleDelayedHide() {
    inspectorToggleHideTask?.cancel()
    let deadline = ContinuousClock.now.advanced(
      by: InspectorToggleMetrics.postCollapseHideDelay
    )
    inspectorToggleRevealDeadline = deadline
    updateInspectorToggleVisibility(animated: false)
    inspectorToggleHideTask = Task { @MainActor [weak self] in
      try? await Task.sleep(for: InspectorToggleMetrics.postCollapseHideDelay)
      guard !Task.isCancelled, let self,
        self.inspectorToggleRevealDeadline == deadline
      else { return }
      self.inspectorToggleRevealDeadline = nil
      self.updateInspectorToggleVisibility(
        animated: true,
        synchronizesPointerFromWindow: false
      )
    }
  }

  private func cancelInspectorToggleDelayedHide() {
    inspectorToggleHideTask?.cancel()
    inspectorToggleHideTask = nil
    inspectorToggleRevealDeadline = nil
  }

  /// 切换单个动作按钮的透明度；不可见时同时 `isHidden`，避免隐形按钮拦截该区域的
  /// 窗口拖动。值没变时直接返回——本方法会在 `viewDidLayout` 里被调用，重复写
  /// `isHidden` 会再触发一轮布局。
  private func setHoverButtonVisible(_ button: NSView?, _ visible: Bool, animated: Bool) {
    guard let button else { return }
    let targetAlpha: CGFloat = visible ? 1 : 0
    guard button.isHidden != !visible || button.alphaValue != targetAlpha else { return }
    if visible { button.isHidden = false }
    guard animated else {
      button.alphaValue = targetAlpha
      button.isHidden = !visible
      return
    }
    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.15
        button.animator().alphaValue = targetAlpha
      },
      completionHandler: {
        // completionHandler 是 @Sendable 闭包，回主 actor 再改 isHidden。
        Task { @MainActor in
          // 悬停状态可能在动画期间反转。只完成仍然对应当前目标透明度的那次过渡，
          // 防止旧的淡入 completion 在 Inspector 状态反转后覆盖当前显隐结果。
          guard abs(button.alphaValue - targetAlpha) < 0.001 else { return }
          button.isHidden = !visible
        }
      }
    )
  }

  private func scheduleRefresh() {
    guard !refreshScheduled else { return }
    refreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      self?.refreshScheduled = false
      self?.refresh()
    }
  }

  /// 配置在 `@Published` 的 will-change 阶段发出通知，因此先让出当前调用栈，再读取
  /// 新值。设置展示期间，普通配置只更新终端并把结构刷新合并到关闭时；主题、明暗外观
  /// 与标签栏布局是用户正在预览的结果，必须立即刷新工作区全部 AppKit 对象。
  private func schedulePreferenceRefresh() {
    if settingsPresentationActive { needsRefreshAfterSettingsDismiss = true }
    if !terminalPreferenceApplyScheduled {
      terminalPreferenceApplyScheduled = true
      DispatchQueue.main.async { [weak self] in
        guard let self else { return }
        self.terminalPreferenceApplyScheduled = false
        // `runtimes` 可能在 AppKit 整树替换的一次事务内暂时多于 layout 叶节点。只遍历
        // layout 会漏掉仍显示在旧 Pane host 中的终端，造成分屏两侧停留在不同主题。
        // 先更新所有存活 Session，再以实际视图树为准补发纯视觉令牌，主题预览才能
        // 对用户屏幕上的每个 Pane 同时生效。
        for tab in self.model.tabs {
          for runtime in tab.runtimes.values {
            runtime.terminalSession?.apply(preferences: self.preferences)
          }
        }
        self.updateSecureInputIndicator(
          active: self.secureInputCoordinator.isSystemProtectionActive)
        self.applyThemeToVisibleTerminals(in: self.view)
        self.detailsPanelController?.synchronizeSectionsIfNeeded()
        if self.settingsPresentationActive,
          self.renderedTheme != self.preferences.activeTheme
            || self.renderedAppearance != self.preferences.appearance
            || self.renderedTabBarLayout != self.preferences.tabBarLayout
            || self.renderedViewConfiguration != self.preferences.configuration.resolvedView
            || self.renderedBadgeSettings != self.currentBadgeSettings()
        {
          self.refresh()
        }
      }
    }
    if !settingsPresentationActive { scheduleRefresh() }
  }

  private func currentBadgeSettings() -> [Bool] {
    let shell = preferences.configuration.shell
    return [shell.badgeExitStatus, shell.resolvedBadgeCommandFinish, shell.resolvedBadgeCommandFailure, shell.badgeAwaitingInput]
  }

  /// AppKit 允许被替换的旧子树存活到当前布局事务结束；递归扫描是为了更新这些真正
  /// 还在窗口里的终端，不把主题正确性依赖在模型与视图恰好处于同一个过渡瞬间。
  private func applyThemeToVisibleTerminals(in root: NSView) {
    if let terminal = root as? GhosttySurfaceView {
      terminal.updateConfiguration(GhosttyConfiguration.make(preferences: preferences))
      return
    }
    for subview in root.subviews {
      applyThemeToVisibleTerminals(in: subview)
    }
  }

  /// 由 AppDelegate 在唯一设置窗口显示/关闭时同步。关闭时只合并补一次工作区刷新，
  /// 不把设置窗口的生命周期或视图层级耦合进工作区控制器。
  func setSettingsPresentationActive(_ active: Bool) {
    guard settingsPresentationActive != active else { return }
    settingsPresentationActive = active
    guard !active else { return }
    if needsRefreshAfterSettingsDismiss {
      needsRefreshAfterSettingsDismiss = false
      refresh()
    } else if let tab = model.selectedTab {
      focusActivePane(in: tab)
    }
  }

  /// 由 AppDelegate 在菜单主题 Panel 展示/收起时调用。只改变窗口活动呈现，不耦合
  /// Panel 的视图或选择状态，主题切换产生的整树刷新仍可安全执行。
  func setThemeSwitcherPresentationActive(_ active: Bool) {
    guard themeSwitcherPresentationActive != active else { return }
    themeSwitcherPresentationActive = active
    updateWindowActivationOverlay()
  }

  private func refresh() {
    // 终端视图由 Session 长期持有，但从视图树移除时 AppKit 仍可能清掉 first
    // responder。记录正在输入的实例，重排完成后同步恢复，避免异步回焦前丢一个按键。
    let previouslyFocusedTerminal = view.window?.firstResponder as? GhosttySurfaceView
    if !model.isOpenQuicklyPresented { openQuicklyController?.invalidateTargets() }
    observeTabs()
    // `refresh()` 会替换整个布局；详情控制器本身仍按当前 Tab 缓存，重建后的 Panel
    // split 会按展示状态重新接入它。
    workspacePanelSplitView = nil
    workspaceTitlePopover?.close()
    workspaceTitlePopover = nil
    retainedObjects.removeAll()
    paneHosts.removeAll()
    editorTextViews.removeAll()
    tabRowsByID.removeAll(keepingCapacity: true)
    // 设置控制器跨展示复用，保留分类、搜索和滚动位置；只重建工作区临时子控制器。
    children.forEach { $0.removeFromParent() }
    view.removeAllSubviews()
    view.appearance = preferences.preferredAppearance
    updateWindowTitle(model.selectedTab?.windowTitle ?? "Aster")

    let theme = preferences.activeTheme
    renderedTheme = theme
    renderedAppearance = preferences.appearance
    renderedTabBarLayout = preferences.tabBarLayout
    renderedViewConfiguration = preferences.configuration.resolvedView
    renderedBadgeSettings = currentBadgeSettings()
    if let background = view as? ThemeVisualEffectView {
      background.apply(
        material: theme.palette.material,
        tint: theme.resolvedColor(forSlot: "interface.window")
          ?? theme.palette.interfaceWindowBackground ?? theme.palette.panelBackground
      )
    }

    // Pane/overlay 中仍有一批动态 NSColor 需要落到 CALayer.cgColor。CGColor 只在赋值
    // 当下解析，依据是 NSAppearance.current 而不是未来挂载窗口的 appearance；若直接
    // 构建，暗色工作区会把 Find Bar、Pane Toolbar 等冻结成白色。所有主布局对象必须
    // 在根视图的实际外观上下文中创建，主题切换后的整树刷新也会重新解析一次。
    var layout: NSView!
    view.effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
      layout = makeWorkspaceLayout()
    }
    view.addSubview(layout)
    layout.pinEdges(to: view)
    installInspectorToggleOverlay()
    if let paneID = model.presentedPromptQueuePaneID {
      setPromptQueuePresented(for: paneID)
    }

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
        palette.view.widthAnchor.constraint(equalToConstant: 560),
        palette.view.heightAnchor.constraint(lessThanOrEqualToConstant: 480),
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
    // 只有旧终端仍属于当前活动 Pane 时才同步回焦——拆分/切换后活动 Pane 已换人,
    // 无条件恢复会让键盘输入劫持回旧 Pane,与视觉焦点分裂(输入进错 Pane 的根因)。
    let activeSession = model.selectedTab?.activeRuntime?.terminalSession
    let restoredTerminalFocus: Bool
    if !blocksTerminalFocus, let terminal = previouslyFocusedTerminal,
      terminal.window === view.window, let window = view.window,
      activeSession?.owns(terminal) == true
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
        // Terminal 的只读态会改变终端 HUD，仍需刷新；File Pane 自己就地更新编辑器和
        // 模式胶囊，不能为一次锁定拆掉整个分屏树和 WebKit/终端视图。
        guard runtime.descriptor.kind == .terminal else { continue }
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
      // 程序标题（OSC 0/1/2）走行内局部刷新：Agent CLI 每秒多次改标题，整树重建
      // 会打断其他 Pane 的输入、IME 组合、滚动，并让 Panels 点击卡顿。
      tab.titleChanged
        .sink { [weak self, weak tab] _ in
          guard let self, let tab else { return }
          for row in self.tabRowsByID[tab.id] ?? [] where row.window != nil {
            row.refreshTitle()
          }
          // Agent 会话标题变化也走本通道；标题栏胶囊只跟随当前选中标签的活动 Pane。
          if tab.id == self.model.selectedTabID {
            self.workspaceTitleButton?.agentSessionTitle = tab.activeAgentSessionTitle
            self.workspaceTitleButton?.agentProvider = tab.activeSession?.activeAgentProvider
          }
        }
        .store(in: &tabSubscriptions)
      tab.workingDirectoryChanged
        .sink { [weak self, weak tab] change in
          guard let self, let tab, tab.id == self.model.selectedTabID,
            change.paneID == tab.activePaneID
          else { return }
          self.workspaceTitleButton?.workingDirectory = change.directory
        }
        .store(in: &tabSubscriptions)
      tab.documentLineRevealRequested
        .sink { [weak self] request in
          self?.revealEditorLine(request.line, paneID: request.paneID)
        }
        .store(in: &tabSubscriptions)
    }
  }

  /// Agent lifecycle、完成未读和显式 badge 只改变标签附件。状态事件可能与一次已排队的
  /// 全局刷新相邻；字典始终只保存当前视图树中的按钮，因此不会更新已移除的旧行。
  private func scheduleTabActivityRefresh(_ tabID: UUID) {
    pendingTabActivityIDs.insert(tabID)
    guard !tabActivityRefreshScheduled else { return }
    tabActivityRefreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      self.tabActivityRefreshScheduled = false
      let tabIDs = self.pendingTabActivityIDs
      self.pendingTabActivityIDs.removeAll(keepingCapacity: true)
      for tabID in tabIDs {
        for row in self.tabRowsByID[tabID] ?? [] where row.window != nil {
          row.refreshActivityBadge()
        }
      }
    }
  }

  /// 同步系统窗口标题与自定义标题区。该更新不重建视图树，因此仅 OSC 2 变化或
  /// 分屏焦点切换不会打断终端选择、滚动和 TUI 绘制。
  private func updateWindowTitle(_ title: String) {
    view.window?.title = title
    workspaceTitleButton?.programTitle = title
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

  /// 切换聚焦 Pane 时只更新路由状态，不重建视图树。视觉反馈是未聚焦 Pane 的内容
  /// alpha 褪色（host 内部实现）加终端光标与实际 first responder；不使用颜色遮罩，
  /// 透明主题的 window 色经 `withAlphaComponent` 会变成近黑色块。
  private func updatePaneActivationOverlays(in tab: TerminalTabItem) {
    for (paneID, host) in paneHosts {
      let isActive = paneID == tab.activePaneID
      host.isActivePane = isActive
      tab.runtime(for: paneID)?.terminalSession?.setPaneActive(isActive)
    }
  }

  /// 把键盘焦点交给当前面板：终端面板交给 SwiftTerm 视图，其余面板交给容器本身。
  /// 交接失败时记录结构化原因——「Pane 永远无法输入」类问题只能靠这里的现场定位。
  private func focusActivePane(in tab: TerminalTabItem) {
    if let session = tab.activeRuntime?.terminalSession {
      // PiP 拥有长期终端容器时，主工作区只显示占位；这里也不能跨窗口把
      // first responder 强行交给 PiP 中的终端。
      guard !PanePictureInPictureOwnership.isOwnedByPictureInPicture(session) else {
        DiagnosticsCenter.shared.record(
          "workspace.focus_pane_skipped", level: .info, category: .workspace,
          attributes: ["reason": "pip_owned"])
        return
      }
      if !session.focus() {
        let responder = view.window?.firstResponder.map { String(describing: type(of: $0)) }
        DiagnosticsCenter.shared.record(
          "workspace.focus_pane_failed", level: .error, category: .workspace,
          attributes: [
            "reason": session.focusFailureReason ?? "unknown",
            "first_responder": responder ?? "nil",
            "pane": tab.activePaneID.uuidString,
            "session": session.id.uuidString,
            "lifecycle": String(describing: session.lifecycleState),
            "running": session.isRunning ? "1" : "0",
          ])
      }
      return
    }
    guard let host = paneHosts[tab.activePaneID], let window = host.window else {
      DiagnosticsCenter.shared.record(
        "workspace.focus_pane_failed", level: .error, category: .workspace,
        attributes: ["reason": "no_session_no_host"])
      return
    }
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
    var panels: [WorkspacePanel] = []
    let content: NSView

    if !showsTabs {
      // 折叠态：内容区左上角叠加悬停动作区（+ 新建 / 展开标签栏），鼠标进入顶部
      // 悬停带时淡入，离开淡出——折叠后无需进设置页也能恢复侧栏。
      content = makeCollapsedContentArea()
    } else if preferences.tabBarLayout == .vertical {
      panels.append(WorkspacePanel(role: .sidebar, contentView: makeVerticalTabBar()))
      content = makeContentArea()
    } else {
      let stack = NSStackView()
      stack.orientation = .vertical
      stack.spacing = 0
      stack.distribution = .fill
      let bar = makeHorizontalTabBar(isBottom: preferences.tabBarLayout == .bottom)
      let theme = preferences.activeTheme
      let divider = makeDivider(
        color: NSColor(
          theme.resolvedColor(forSlot: "tabbar.border")
            ?? theme.palette.interfaceBorder ?? theme.palette.panelBackground
        ),
        vertical: false
      )
      divider.identifier = NSUserInterfaceItemIdentifier("workspace-tabbar-border")
      let workspace = makeContentArea()
      workspace.setContentHuggingPriority(.defaultLow, for: .vertical)
      workspace.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
      if preferences.tabBarLayout == .top {
        stack.addArrangedSubview(bar)
        stack.addArrangedSubview(divider)
        stack.addArrangedSubview(workspace)
      } else {
        stack.addArrangedSubview(workspace)
        stack.addArrangedSubview(divider)
        stack.addArrangedSubview(bar)
      }
      // 与竖直标签栏布局同理：内容区没有固有宽度，左右分屏会被 NSSplitView 的
      // `width == 0 @250` 回退约束压到最窄。约束必须在入栈之后建立。
      // 标签栏与分隔线同样要显式绑定栈宽：纵向栈默认按固有宽度对齐，缺了这两条
      // 约束时整条标签栏会缩成内容宽度的一小段浮在窗口中间。
      for member in [workspace, bar, divider] {
        member.translatesAutoresizingMaskIntoConstraints = false
        member.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
      }
      content = stack
    }

    // Otty 的 Inspector 是 Container 卡片内部的 trailing Pane，不是与左侧 Tabs 对称的
    // 第二个 Sidebar。外层 split 因此只负责 Sidebar ↔ Content；详情 Pane 的宽度、
    // 动画和分隔线在 makeTerminalWorkspace 创建的内层 split 中处理。
    panels.append(WorkspacePanel(role: .content, contentView: content))
    let theme = preferences.activeTheme
    let sidebarDividerColor: NSColor = if theme.style.sidebarBorderWidth == 0,
      theme.style.sidebarBackground?.alpha == 0
    {
      // Floating/Glass 用透明 Sidebar + `border-right = none` 让 Window material 连成
      // 一片。NSSplitView 仍保留 1pt 拖动几何，但静止态不能把 fallback border 画回来。
      .clear
    } else {
      NSColor(
        theme.resolvedColor(forSlot: "sidebar.border")
          ?? theme.palette.interfaceBorder ?? theme.palette.panelBackground
      )
    }
    let split = WorkspacePanelSplitView(
      panels: panels,
      layoutStore: panelLayoutStore,
      dividerColor: sidebarDividerColor
    )
    return split
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
    NSLayoutConstraint.activate([
      workspace.leadingAnchor.constraint(equalTo: host.leadingAnchor),
      workspace.topAnchor.constraint(equalTo: host.topAnchor),
      workspace.bottomAnchor.constraint(equalTo: host.bottomAnchor),
      workspace.trailingAnchor.constraint(equalTo: host.trailingAnchor),
    ])
    return host
  }

  // MARK: - Tab bars

  private func makeVerticalTabBar() -> NSView {
    let theme = preferences.activeTheme
    let background = ThemeVisualEffectView()
    background.identifier = NSUserInterfaceItemIdentifier("workspace-sidebar")
    background.apply(
      material: theme.style.sidebarMaterial ?? theme.palette.material,
      tint: theme.resolvedColor(forSlot: "sidebar.background")
        ?? theme.style.sidebarBackground ?? theme.palette.panelBackground
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
    let title = makeLabel(
      "TABS",
      size: 10,
      weight: .semibold,
      // Otty 把 section eyebrow 画成 tertiary chrome；Sidebar foreground 是正文层级，
      // 用在这里会让 Floating Card 的 TABS 与活动标签一样黑。
      color: NSColor(
        theme.resolvedColor(forSlot: "interface.tertiaryForeground")
          ?? theme.palette.tertiaryForeground ?? theme.palette.secondaryForeground
      )
    )
    title.identifier = NSUserInterfaceItemIdentifier("workspace-sidebar-foreground")
    title.translatesAutoresizingMaskIntoConstraints = false
    let menu = SidebarOptionsButton { [weak self] in
      self?.makeSidebarOptionsMenu() ?? NSMenu()
    }
    header.addSubview(title)
    header.addSubview(menu)
    NSLayoutConstraint.activate([
      // 与标签行文案左对齐（行底卡左内缩 + 卡内边距 10）。右侧可由主题独立覆盖，
      // 不能拿 trailing padding 反推左侧位置。
      title.leadingAnchor.constraint(
        equalTo: header.leadingAnchor,
        constant: CGFloat(theme.style.resolvedSidebarPadding.leading) + 10),
      title.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -12),
      menu.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
      menu.bottomAnchor.constraint(equalTo: header.bottomAnchor, constant: -5),
    ])
    column.addArrangedSubview(header)

    // 红绿灯行感应区：header 顶部与交通灯同高的一条带子，只用来界定「折叠」按钮的
    // 显示范围。它不自带 tracking area，也不参与命中测试（否则会吃掉窗口拖动），
    // 指针位置由侧栏那一个 tracking area 统一推导。
    let titleBarRow = ClickThroughStripView()
    titleBarRow.translatesAutoresizingMaskIntoConstraints = false
    header.addSubview(titleBarRow)
    NSLayoutConstraint.activate([
      titleBarRow.leadingAnchor.constraint(equalTo: header.leadingAnchor),
      titleBarRow.trailingAnchor.constraint(equalTo: header.trailingAnchor),
      titleBarRow.topAnchor.constraint(equalTo: header.topAnchor),
      titleBarRow.heightAnchor.constraint(equalToConstant: 30),
    ])
    titleBarHoverRegion = titleBarRow

    // 悬停动作区：「+ 新建标签」跟随整个侧栏，「折叠标签栏」跟随上面那条红绿灯行。
    // 两个按钮都放在 header 顶部右侧，与红绿灯同一水平线。
    let hoverActions = makeHoverActionsRow(sidebarVisible: true)
    header.addSubview(hoverActions)
    hoverActions.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      hoverActions.trailingAnchor.constraint(equalTo: header.trailingAnchor, constant: -6),
      hoverActions.topAnchor.constraint(equalTo: header.topAnchor, constant: 4),
    ])
    sidebarHoverActions = hoverActions

    // 鼠标进入侧栏任意位置就显示「+」；inVisibleRect 让跟踪区域跟随侧栏尺寸。
    sidebarHoverRegion = background
    background.addTrackingArea(makeHoverTrackingArea())

    let rows = NSStackView()
    rows.orientation = .vertical
    // 垂直栈默认按控件固有宽度居中。Otty 的标签从侧栏左缘铺到右缘，显式
    // 使用 width 对齐后，选中背景才不会缩成内容宽度的小卡片。
    rows.alignment = .width
    rows.spacing = 0
    for section in sidebarTabSections() {
      var sectionCollapsed = false
      if let identifier = section.identifier, let title = section.title {
        sectionCollapsed = preferences.isSidebarGroupCollapsed(title: identifier)
        let header = makeSidebarGroupHeader(
          identifier: identifier,
          title: title,
          toolTip: section.toolTip,
          kind: section.kind,
          collapsed: sectionCollapsed
        )
        rows.addArrangedSubview(header)
        header.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
      }
      // 折叠的分组只留组头；标签行整组不进视图树（对齐 Otty 的分组折叠）。
      if sectionCollapsed { continue }
      for tab in section.tabs {
        let ruleOutcome = tabRuleOutcome(for: tab)
        let button = TabRowButton(
          tab: tab,
          selected: tab.id == model.selectedTabID,
          horizontal: false,
          theme: theme,
          showsExitStatus: preferences.configuration.shell.badgeExitStatus,
          showsFinished: preferences.configuration.shell.resolvedBadgeCommandFinish,
          showsFailure: preferences.configuration.shell.resolvedBadgeCommandFailure,
          showsAwaitingInput: preferences.configuration.shell.badgeAwaitingInput,
          tabIcon: ruleOutcome.resolution.icon,
          badgePlacement: preferences.configuration.resolvedView.resolvedBadgePlacement,
          displayTitleProvider: { [weak self, weak tab] in
            guard let self, let tab else { return "" }
            if let ruled = self.ruleTitle(for: tab) { return ruled }
            guard section.kind == .project(.local) else { return tab.displayTitle }
            // 对齐 Otty：有 Agent 会话标题时显示它，否则显示 ~ 缩写的完整目录路径
            // （组头已经是项目名，行里再显示短名就是重复信息）。
            if let agentTitle = tab.activeAgentSessionTitle { return agentTitle }
            let directory = tab.workingDirectory
            return directory.isEmpty
              ? tab.displayTitle
              : (directory as NSString).abbreviatingWithTildeInPath
          },
          displayTitleToolTip: section.kind == .project(.local) ? tab.workingDirectory : nil,
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
        tabRowsByID[tab.id, default: []].append(button)
        rows.addArrangedSubview(button)
        button.widthAnchor.constraint(equalTo: rows.widthAnchor).isActive = true
        if model.dividerAfterTabIDs.contains(tab.id) {
          let divider = makeDivider(color: AsterTheme.divider, vertical: false)
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
  private func sidebarTabSections() -> [SidebarTabSection] {
    let sorted = model.tabs.sorted { lhs, rhs in
      let lhsDate = preferences.sidebarTabOrder == .createdTime ? lhs.createdAt : lhs.updatedAt
      let rhsDate = preferences.sidebarTabOrder == .createdTime ? rhs.createdAt : rhs.updatedAt
      if lhsDate != rhsDate { return lhsDate > rhsDate }
      return lhs.id.uuidString < rhs.id.uuidString
    }
    guard preferences.sidebarTabGrouping != .none else {
      return [SidebarTabSection(
        identifier: nil,
        title: nil,
        toolTip: nil,
        kind: .ungrouped,
        tabs: sorted
      )]
    }

    var sectionOrder: [String] = []
    var grouped: [String: SidebarTabSection] = [:]
    for tab in sorted {
      let section: SidebarTabSection
      switch preferences.sidebarTabGrouping {
      case .none:
        section = SidebarTabSection(
          identifier: nil, title: nil, toolTip: nil, kind: .ungrouped, tabs: [])
      case .project:
        let project = SidebarProjectGroup.resolve(
          directory: tab.workingDirectory,
          homeDirectory: NSHomeDirectory(),
          fallback: tab.title,
          sshEndpoint: tab.activeSession?.sshRemoteEndpoint
        )
        section = SidebarTabSection(
          identifier: project.identifier,
          title: project.title,
          toolTip: project.toolTip,
          kind: .project(project.kind),
          tabs: []
        )
      case .date:
        let title = sidebarDateGroupTitle(for: tab.createdAt)
        section = SidebarTabSection(
          identifier: title,
          title: title,
          toolTip: title,
          kind: .date,
          tabs: []
        )
      }
      guard let identifier = section.identifier else { continue }
      if grouped[identifier] == nil {
        sectionOrder.append(identifier)
        grouped[identifier] = section
      }
      grouped[identifier]?.tabs.append(tab)
    }
    return sectionOrder.compactMap { grouped[$0] }
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

  /// 项目/日期分组的组头行：本地目录使用文件夹，SSH hostname 使用电脑图标。
  /// 折叠状态按稳定 identifier 保存，短标题不会把同名目录的状态串在一起。
  private func makeSidebarGroupHeader(
    identifier: String,
    title: String,
    toolTip: String?,
    kind: SidebarSectionKind,
    collapsed: Bool = false
  ) -> NSView {
    let theme = preferences.activeTheme
    // 分组属于标签列表正文，Otty 使用普通 tab foreground，而不是更淡的 tertiary。
    // 这在 Floating Card 中分别对应 #52525B 与 #A1A1AA，层级差异很明显。
    let groupForeground = NSColor(
      theme.resolvedColor(forSlot: "tab.foreground")
        ?? theme.style.tab.foreground ?? theme.palette.secondaryForeground
    )
    let host = SidebarGroupHeaderView { [weak self] in
      guard let self else { return }
      self.preferences.toggleSidebarGroupCollapsed(title: identifier)
      // 折叠是工作区上的直接操作，必须立即重排；不能依赖偏好观察器——设置窗口
      // 打开期间它会把结构刷新合并推迟到关窗。scheduleRefresh 自带去重，
      // 与观察器各自调度也只会重建一次。
      self.scheduleRefresh()
    }
    host.setAccessibilityRole(.button)
    host.setAccessibilityLabel("\(collapsed ? "展开" : "折叠")分组 \(title)")
    host.translatesAutoresizingMaskIntoConstraints = false
    host.heightAnchor.constraint(equalToConstant: 30).isActive = true

    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 5
    row.alignment = .centerY
    let groupSymbol = kind == .project(.ssh) ? "desktopcomputer" : "folder"
    for symbol in [collapsed ? "chevron.right" : "chevron.down", groupSymbol] {
      let icon = NSImageView()
      icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
      icon.contentTintColor = groupForeground
      icon.setContentHuggingPriority(.required, for: .horizontal)
      icon.setContentCompressionResistancePriority(.required, for: .horizontal)
      row.addArrangedSubview(icon)
    }
    let label = makeLabel(title, size: 10.5, weight: .semibold, color: groupForeground)
    label.identifier = NSUserInterfaceItemIdentifier("sidebar-group-header")
    label.lineBreakMode = .byTruncatingMiddle
    label.toolTip = toolTip
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    row.addArrangedSubview(label)

    host.addSubview(row)
    row.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      // 分组标题同样对齐标签行文案的左缘；单边 padding 必须只影响自己的方向。
      row.leadingAnchor.constraint(
        equalTo: host.leadingAnchor,
        constant: CGFloat(theme.style.resolvedSidebarPadding.leading) + 10),
      row.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -12),
      row.centerYAnchor.constraint(equalTo: host.centerYAnchor),
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

  /// 顶部/底部横向标签栏：满宽材质条 + 内容自适应的胶囊标签 + 「新建/整理」图标按钮。
  /// 顶部布局在标签行上方多留 27pt 标题带，让交通灯落在自己的行里（对齐 Otty）。
  private func makeHorizontalTabBar(isBottom: Bool) -> NSView {
    let theme = preferences.activeTheme
    let background = ThemeVisualEffectView()
    background.identifier = NSUserInterfaceItemIdentifier("workspace-tabbar")
    background.apply(
      material: theme.style.horizontalTabBarMaterial ?? theme.palette.material,
      tint: theme.resolvedColor(forSlot: "tabbar.background")
        ?? theme.style.horizontalTabBarBackground ?? theme.style.sidebarBackground
          ?? theme.palette.panelBackground
    )
    // Otty `[tab-bar].height` 原生默认 36。
    let rowHeight = theme.style.horizontalTabBarHeight ?? 36
    // 顶部布局在标签行上方叠一条 28pt 标题带（与交通灯同一行，承载中央目录胶囊）；
    // 标签行整体落在系统标题栏命中区之下，标签左上角不会被窗口拖拽区吃掉点击。
    let titleBandHeight: CGFloat = 28
    background.translatesAutoresizingMaskIntoConstraints = false
    background.heightAnchor.constraint(
      equalToConstant: isBottom ? rowHeight : rowHeight + titleBandHeight
    ).isActive = true

    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 4
    row.alignment = .centerY
    // 标签行独占自己的一行，左缘从窗口边起排。
    row.edgeInsets = NSEdgeInsets(top: 0, left: 10, bottom: 0, right: 8)
    for tab in model.tabs {
      let ruleOutcome = tabRuleOutcome(for: tab)
      let button = TabRowButton(
        tab: tab,
        selected: tab.id == model.selectedTabID,
        horizontal: true,
        rowHeight: rowHeight,
        theme: theme,
        showsExitStatus: preferences.configuration.shell.badgeExitStatus,
        showsFinished: preferences.configuration.shell.resolvedBadgeCommandFinish,
        showsFailure: preferences.configuration.shell.resolvedBadgeCommandFailure,
        showsAwaitingInput: preferences.configuration.shell.badgeAwaitingInput,
        tabIcon: ruleOutcome.resolution.icon,
        badgePlacement: preferences.configuration.resolvedView.resolvedBadgePlacement,
        displayTitleProvider: { [weak self, weak tab] in
          guard let self, let tab else { return "" }
          return self.ruleTitle(for: tab) ?? tab.displayTitle
        },
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
      tabRowsByID[tab.id, default: []].append(button)
      row.addArrangedSubview(button)
    }
    // 无边框图标按钮自带悬停底色反馈，与胶囊标签的视觉密度一致。横向标签条只保留
    // 「+」新建入口；命令面板走快捷键与菜单，不在标签行占一个图标位。
    let newTab = IconHoverButton(symbol: "plus", accessibilityDescription: "新建标签页") {
      [weak self] in self?.model.newTab()
    }
    newTab.toolTip = "新建标签页"
    newTab.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      newTab.widthAnchor.constraint(equalToConstant: 26),
      newTab.heightAnchor.constraint(equalToConstant: 26),
    ])
    row.addArrangedSubview(newTab)
    if isBottom {
      background.addSubview(row)
      row.pinEdges(to: background)
    } else {
      // 顶部布局：标题带在上、标签行在下。中央胶囊与交通灯共处 28pt 标题带，
      // 内容区不再重复渲染标题行（见 makeTerminalWorkspace）。
      let column = NSStackView()
      column.orientation = .vertical
      column.alignment = .width
      column.spacing = 0
      let titleBand: NSView
      if let tab = model.selectedTab {
        titleBand = makeWorkspaceHeader(tab)
      } else {
        // 没有可选中标签时仍保留交通灯行的高度占位，标签行不上浮进拖拽区。
        let spacer = NSView()
        spacer.translatesAutoresizingMaskIntoConstraints = false
        spacer.heightAnchor.constraint(equalToConstant: titleBandHeight).isActive = true
        titleBand = spacer
      }
      column.addArrangedSubview(titleBand)
      row.translatesAutoresizingMaskIntoConstraints = false
      row.heightAnchor.constraint(equalToConstant: rowHeight).isActive = true
      column.addArrangedSubview(row)
      background.addSubview(column)
      column.pinEdges(to: background)
      // 纵向栈默认按固有宽度排布子项；标题带与标签行必须显式绑定栈宽，否则标签行
      // 会缩成内容宽度的一小段浮在中间、标签不再左对齐（与 makeWorkspaceLayout 同一坑）。
      for member in [titleBand, row] {
        member.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
      }
    }
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
    // 顶部标签布局把中央标题并入标签条上方的标题带（与交通灯同一行），内容区不再
    // 重复渲染；标题带在 makeHorizontalTabBar 中构建。其余布局保持内容区顶部标题。
    let titleLivesInTabBar = preferences.tabBarLayout == .top
      && preferences.configuration.appearance.showsTabBar(tabCount: model.tabs.count)
    if !titleLivesInTabBar { stack.addArrangedSubview(makeWorkspaceHeader(tab)) }
    if model.isFindPresented { stack.addArrangedSubview(makeFindBar(tab)) }

    let style = preferences.activeTheme.style.container
    let margin = preferences.tabBarLayout == .vertical
      ? style.margin : (style.horizontalLayoutMargin ?? style.margin)
    let wrapper = NSView()
    let container = NSView()
    container.identifier = NSUserInterfaceItemIdentifier("workspace-container")
    container.wantsLayer = true
    container.layer?.backgroundColor = NSColor(
      preferences.activeTheme.resolvedColor(forSlot: "container.background")
        ?? style.background ?? preferences.activeTheme.palette.containerBackground
    ).cgColor
    container.layer?.cornerRadius = style.radius
    container.layer?.cornerCurve = .continuous
    container.layer?.borderWidth = style.borderWidth
    container.layer?.borderColor = NSColor(
      preferences.activeTheme.resolvedColor(forSlot: "container.border")
        ?? style.borderColor ?? preferences.activeTheme.palette.containerBackground
    ).cgColor
    if let shadow = style.shadow {
      container.shadow = NSShadow()
      container.shadow?.shadowColor = NSColor(shadow.color)
      container.shadow?.shadowBlurRadius = shadow.blur
      container.shadow?.shadowOffset = NSSize(width: shadow.x, height: -shadow.y)
      container.layer?.masksToBounds = false
    }
    wrapper.addSubview(container)
    container.pinEdges(to: wrapper, insets: NSEdgeInsets(margin))

    let center = NSStackView()
    center.orientation = .vertical
    // Pane 容器没有固有宽度；显式按 stack 宽度拉伸，避免递归 NSSplitView 被压成 1 pt。
    center.alignment = .width
    center.spacing = 0

    let paneHost = NSView()
    let paneTree = makePaneContent(tab)
    paneHost.addSubview(paneTree)
    paneTree.pinEdges(to: paneHost, insets: NSEdgeInsets(style.padding))
    center.addArrangedSubview(paneHost)
    let composer = model.isComposerPresented
      && model.composerState(for: tab.activePaneID).presentation == .docked
      ? makeAgentComposer(tab) : nil
    if let composer { center.addArrangedSubview(composer) }

    var bodyPanels = [WorkspacePanel(role: .content, contentView: center)]
    if model.isInspectorPresented {
      let details = detailsControllerForSelectedTab()
      let resumesCachedController = details.isViewLoaded
      if details.parent !== self { addChild(details) }
      details.synchronizeAppearanceIfNeeded()
      if resumesCachedController { details.setPresentationActive(true) }
      bodyPanels.append(WorkspacePanel(role: .inspector, contentView: details.view))
    }
    let theme = preferences.activeTheme
    let bodySplit = WorkspacePanelSplitView(
      panels: bodyPanels,
      layoutStore: panelLayoutStore,
      dividerColor: NSColor(
        theme.resolvedColor(forSlot: "container.border")
          ?? style.borderColor ?? theme.palette.interfaceBorder ?? theme.palette.panelBackground
      )
    )
    workspacePanelSplitView = bodySplit

    // 阴影留在外层 container；单独的裁剪层只负责把终端与 Inspector 收进主题圆角。
    // 直接给 container.masksToBounds 会连同 Floating Card 的外投影一起裁掉。
    let clip = NSView()
    clip.wantsLayer = true
    clip.layer?.cornerRadius = style.radius
    clip.layer?.cornerCurve = .continuous
    clip.layer?.masksToBounds = style.radius > 0
    container.addSubview(clip)
    clip.pinEdges(to: container)
    clip.addSubview(bodySplit)
    bodySplit.pinEdges(to: clip)

    stack.addArrangedSubview(wrapper)
    // 这些内容容器没有 intrinsicContentSize；两个方向都必须显式绑定，否则 NSStackView
    // 会退回「固有尺寸」布局。上下分屏尤其致命：NSSplitView 给每个面板加了
    // `height == 0 @250` 的回退约束，没有必需高度约束时整个内容区会塌成一条分隔条。
    wrapper.translatesAutoresizingMaskIntoConstraints = false
    paneHost.translatesAutoresizingMaskIntoConstraints = false
    var constraints: [NSLayoutConstraint] = [
      wrapper.widthAnchor.constraint(equalTo: stack.widthAnchor),
      wrapper.bottomAnchor.constraint(equalTo: stack.bottomAnchor),
      paneHost.widthAnchor.constraint(equalTo: center.widthAnchor),
      paneHost.topAnchor.constraint(equalTo: center.topAnchor),
    ]
    if let composer {
      constraints.append(paneHost.bottomAnchor.constraint(equalTo: composer.topAnchor))
      constraints.append(composer.bottomAnchor.constraint(equalTo: center.bottomAnchor))
    } else {
      constraints.append(paneHost.bottomAnchor.constraint(equalTo: center.bottomAnchor))
    }
    NSLayoutConstraint.activate(constraints)
    return stack
  }

  private func makeWorkspaceHeader(_ tab: TerminalTabItem) -> NSView {
    let theme = preferences.activeTheme
    let background = WorkspaceTitleBarBackgroundView()
    // 中央标题是 workspace 背景面上的内容，不是另一块 chrome。Window 已在控制器根
    // 视图统一承载实色或 material；标题若再建 NSVisualEffectView，会让透明主题重复
    // 合成一次玻璃并在 28pt 边界形成横向接缝。普通透明层同时保留标题的布局和命中区。
    background.wantsLayer = true
    background.layer?.backgroundColor = workspaceHeaderBackgroundColor(theme).cgColor
    background.translatesAutoresizingMaskIntoConstraints = false
    background.identifier = NSUserInterfaceItemIdentifier("workspace-titlebar")
    background.heightAnchor.constraint(equalToConstant: 28).isActive = true
    inspectorTitleBarHoverRegion = background
    background.addTrackingArea(makeHoverTrackingArea())

    // Otty 常驻显示缩写后的工作目录胶囊。点击入口承载命名、目录、Git、分屏与查找
    // 等动作；程序的 OSC 2/0 标题继续同步到原生窗口标题，不占用这条定位入口。
    let title = WorkspaceTitleButton(
      programTitle: tab.windowTitle,
      workingDirectory: tab.workingDirectory,
      foregroundColor: NSColor(
        theme.resolvedColor(forSlot: "titlebar.foreground")
          ?? theme.style.titlebarForeground ?? theme.palette.secondaryForeground
      ),
      // 只传显式值。`resolvedColor` 会把缺省 titlebar 背景派生成终端色，若在这里使用，
      // Floating Card / Glass Light 会凭空多出一个不透明胶囊。
      backgroundColor: theme.style.titlebarBackground.map(NSColor.init)
    ) { [weak self, weak tab] button in
      guard let self, let tab else { return }
      self.showWorkspaceTitlePopover(anchor: button, tab: tab)
    }
    title.identifier = NSUserInterfaceItemIdentifier("workspace-title-button")
    title.agentSessionTitle = tab.activeAgentSessionTitle
    title.agentProvider = tab.activeSession?.activeAgentProvider
    workspaceTitleButton = title
    background.addSubview(title)
    title.translatesAutoresizingMaskIntoConstraints = false

    let secureInput = SecureInputIndicatorView()
    secureInput.identifier = NSUserInterfaceItemIdentifier("workspace-secure-input-indicator")
    secureInput.isHidden = !secureInputCoordinator.isSystemProtectionActive
      || !preferences.configuration.controls.resolvedSecureInputIndication
    secureInputIndicator = secureInput
    background.addSubview(secureInput)
    secureInput.translatesAutoresizingMaskIntoConstraints = false

    NSLayoutConstraint.activate([
      title.centerXAnchor.constraint(equalTo: background.centerXAnchor),
      title.centerYAnchor.constraint(equalTo: background.centerYAnchor),
      title.leadingAnchor.constraint(greaterThanOrEqualTo: background.leadingAnchor, constant: 12),
      title.trailingAnchor.constraint(
        lessThanOrEqualTo: background.trailingAnchor, constant: -12),
      title.heightAnchor.constraint(equalToConstant: 24),
      secureInput.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -12),
      secureInput.centerYAnchor.constraint(equalTo: background.centerYAnchor),
    ])
    return background
  }

  /// 内容列标题带的底色（对齐 Otty）。
  ///
  /// Otty 的深色主题里，标题带不是一块独立的 chrome：容器贴边铺满时（margin 全 0，
  /// 如 Solarized Dark / Nord），标题带直接延续容器（终端）底色，与下方 pane 连成一片；
  /// 只有 Floating Card 这类带外边距的主题，标题带才露出 window 底。主题显式声明
  /// `titlebar.background` 的（April / Ayu Light 等浅色主题）继续由窗口根视图承载
  /// 实色或 material，这里保持透明，避免在 vibrancy 上再压一层不透明色。透明主题的
  /// 容器色本身是透明 RGBA，画上去等价于不画，因此不需要单独分支。
  private func workspaceHeaderBackgroundColor(_ theme: TerminalTheme) -> NSColor {
    guard theme.style.titlebarBackground == nil else { return .clear }
    let container = theme.style.container
    let margin = preferences.tabBarLayout == .vertical
      ? container.margin : (container.horizontalLayoutMargin ?? container.margin)
    let edgeToEdge = margin.top == 0 && margin.leading == 0 && margin.trailing == 0
    guard edgeToEdge else { return .clear }
    return NSColor(
      theme.resolvedColor(forSlot: "container.background")
        ?? container.background ?? theme.palette.containerBackground
    )
  }

  /// 协调器已经把请求、应用激活状态和 Carbon API 结果收敛成真实状态；这里仅做局部
  /// 显隐，不根据菜单勾选或某个 Pane 的推测重复判断。
  private func updateSecureInputIndicator(active: Bool) {
    secureInputIndicator?.isHidden = !active
      || !preferences.configuration.controls.resolvedSecureInputIndication
  }

  /// 安装工作区唯一的 Inspector 切换按钮。它直接属于根视图，不参与
  /// Sidebar / Content / Inspector 的 split 宽度求解，因此 Panel 显隐前后实例和
  /// 窗口坐标都不变。详情 header 只为它预留命中空间。
  private func installInspectorToggleOverlay() {
    let theme = preferences.activeTheme
    let button: IconHoverButton
    if let existing = inspectorToggleButton {
      button = existing
    } else {
      button = IconHoverButton(
        symbol: InspectorToggleMetrics.symbol,
        accessibilityDescription: "详情面板"
      ) { [weak self] in
        self?.model.toggleInspector()
      }
      button.identifier = NSUserInterfaceItemIdentifier("workspace-inspector-toggle")
      inspectorToggleButton = button
    }
    button.restingTint = NSColor(
      theme.resolvedColor(forSlot: "titlebar.foreground")
        ?? theme.style.titlebarForeground ?? theme.palette.secondaryForeground
    )
    view.addSubview(button)
    button.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      button.trailingAnchor.constraint(
        equalTo: view.trailingAnchor, constant: -InspectorToggleMetrics.trailingInset),
      button.centerYAnchor.constraint(
        equalTo: view.topAnchor, constant: InspectorToggleMetrics.centerYFromTop),
      button.widthAnchor.constraint(equalToConstant: InspectorToggleMetrics.buttonSize),
      button.heightAnchor.constraint(equalToConstant: InspectorToggleMetrics.buttonSize),
    ])
    updateInspectorToggleVisibility(animated: false)
  }

  /// 点击路径胶囊显示工作区动作。再次点击同一入口会关闭；弹层关闭后恢复普通程序标题。
  private func showWorkspaceTitlePopover(anchor: WorkspaceTitleButton, tab: TerminalTabItem) {
    if workspaceTitlePopover?.isShown == true {
      workspaceTitlePopover?.close()
      return
    }
    let content = WorkspaceTitlePopoverViewController(
      model: model,
      preferences: preferences,
      tab: tab
    )
    let popover = NSPopover()
    popover.behavior = .transient
    popover.animates = true
    popover.delegate = self
    popover.contentViewController = content
    popover.contentSize = NSSize(width: 280, height: 462)
    workspaceTitlePopover = popover
    anchor.setPopoverPresented(true)
    popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
  }

  private func makeFindBar(_ tab: TerminalTabItem) -> NSView {
    let bar = NSView()
    bar.identifier = NSUserInterfaceItemIdentifier("workspace-findbar")
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
    case .editor, .preview:
      let controller = FilePaneViewController(
        runtime: runtime,
        tab: tab,
        model: model,
        preferences: preferences,
        renderer: fileRenderer
      )
      addChild(controller)
      retainedObjects.append(controller)
      content = controller.view
      if let textView = controller.sourceTextView {
        editorTextViews[runtime.id] = textView
      }
      controller.onSourceTextViewChanged = { [weak self] textView in
        self?.editorTextViews[runtime.id] = textView
      }
    case .fileBrowser:
      let controller = FileBrowserViewController(runtime: runtime, tab: tab, model: model)
      addChild(controller)
      retainedObjects.append(controller)
      content = controller.view
    case .web:
      let controller = WebPaneViewController(
        runtime: runtime,
        persistData: preferences.configuration.resolvedView.resolvedWebPanePersistData)
      addChild(controller)
      retainedObjects.append(controller)
      content = controller.view
    }
    host.installContent(content)
    // 单 Pane 无处可拖；只有分屏时安装顶部拖动把手。Pane 背景始终由主题负责，
    // 非聚焦 Pane 的变灰由 host 内容 alpha 表达，不叠加改变颜色的遮罩。
    if tab.layout.allPanes.count > 1 {
      host.installDragHandle { [weak self] paneID, event in
        self?.beginPaneDrag(paneID: paneID, event: event)
      }
      // 关闭走「先激活再关闭」:closeActivePane 以活动 Pane 为对象,并顺带走
      // 关闭确认/最近关闭记录等既有语义,不另开一条关闭路径。
      host.installCloseButton { [weak self, weak tab] paneID in
        guard let self, let tab else { return }
        tab.setActivePane(paneID)
        self.model.closeActivePane()
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
        opened = tab.openWebURL(url) || opened
      }
    }
    if opened { model.persistWorkspace() }
    return opened
  }

  /// 局部挂载 Prompt Queue。队列条作为 Pane 的底部附件占据布局空间（不是覆盖层），
  /// 终端因此少绘几行而不是被挡住最后的输出；分屏树不重建，SwiftTerm 视图仍是同一
  /// 个实例，切换 Pane、关闭条或刷新后都由 stable Pane UUID 重新定位。
  private func setPromptQueuePresented(for paneID: UUID?) {
    if let previous = promptQueueBarHostPaneID, let host = paneHosts[previous] {
      host.setBottomAccessory(nil)
    }
    promptQueueBar?.removeFromSuperview()
    promptQueueBar = nil
    promptQueueBarHostPaneID = nil
    guard let paneID,
      let host = paneHosts[paneID],
      model.canPresentPromptQueue,
      model.selectedTab?.activePaneID == paneID
    else { return }
    let bar = PromptQueueBarView(
      draft: model.promptQueueDraft(for: paneID),
      items: model.promptQueueItems(for: paneID),
      onDraftChanged: { [weak model] value in
        model?.updatePromptQueueDraft(value, paneID: paneID) ?? false
      },
      onEnqueue: { [weak model] in model?.enqueuePromptQueueDraft(paneID: paneID) ?? false },
      onSend: { [weak model] id in model?.sendPromptQueueItem(id: id, paneID: paneID) ?? false },
      onRemove: { [weak model] id in model?.removePromptQueueItem(id: id, paneID: paneID) },
      onClose: { [weak model] in model?.hidePromptQueue(paneID: paneID) }
    )
    host.setBottomAccessory(bar)
    promptQueueBar = bar
    promptQueueBarHostPaneID = paneID
  }

  private func presentAgentChatSheet(_ presentation: AgentChatPresentation) {
    guard let window = view.window else {
      model.notice = "无法显示发送到聊天窗口。"
      return
    }
    // 一个工作区窗口同时只允许一个确认面板，重复触发时保留已经填写的 Comment。
    guard agentChatSheet == nil else { return }
    let sheet = AgentChatSendSheetController(model: model, presentation: presentation)
    agentChatSheet = sheet
    sheet.present(on: window) { [weak self, weak sheet] in
      guard self?.agentChatSheet === sheet else { return }
      self?.agentChatSheet = nil
    }
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
    // Pane 焦点是工作区领域状态；在新 View 挂入可见树之前同步，保证非活动分屏第一帧
    // 就使用不闪烁的同形状光标，而不是 SwiftTerm 默认的失焦空心方块。
    session.setPaneActive(tab.activePaneID == runtime.id)
    // PTY 只在 Pane 首次挂载时创建；Recipe 命令因此必须从这里启动。短暂让出主线程，
    // 给 Shell Integration 安装 prompt hook 的时间，后续命令再由完成事件严格串行推进。
    Task { @MainActor [weak model] in
      try? await Task.sleep(for: .milliseconds(350))
      model?.startPendingRecipeCommands(paneID: runtime.id)
    }
    host.removeFromSuperview()
    // Session 的终端 Host 会跨工作区刷新长期复用；先移除上一轮短生命周期状态视图，
    // 避免重复 warning/结束卡堆叠在同一个 Metal-backed 终端之上。
    host.subviews.filter {
      guard let identifier = $0.identifier?.rawValue else { return false }
      return identifier.hasPrefix("terminal-startup-warning-")
        || identifier.hasPrefix("terminal-ended-overlay-")
    }.forEach { $0.removeFromSuperview() }
    if let error = session.startupError, session.lifecycleState != .startFailed {
      let warning = makeLabel(error, size: 10.5, color: AsterTheme.warning)
      warning.identifier = NSUserInterfaceItemIdentifier(
        "terminal-startup-warning-\(session.id.uuidString)")
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
    if let endedOverlay = TerminalLifecycleOverlayView(session: session) {
      host.addSubview(endedOverlay)
      endedOverlay.pinEdges(to: host)
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
    host.identifier = NSUserInterfaceItemIdentifier("agent-composer")
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

    let textView = ComposerTextView()
    textView.identifier = NSUserInterfaceItemIdentifier("agent-composer-input")
    textView.string = state.draft
    // 空草稿必须提示可在当前 Pane 直接输入，避免被误认为只读终端日志。
    textView.placeholder = "Type here..."
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
  /// 整理菜单是工作区内的直接交互，点击必须立刻看到列表变化。偏好通道在设置窗口
  /// 打开期间会把结构刷新合并到关窗时（schedulePreferenceRefresh 的动画去抖），
  /// 这里各自补一次显式 scheduleRefresh，保证反馈不被那个去抖吞掉。
  @objc private func setSidebarGroupingNone() {
    preferences.sidebarTabGrouping = .none
    scheduleRefresh()
  }
  @objc private func setSidebarGroupingProject() {
    preferences.sidebarTabGrouping = .project
    scheduleRefresh()
  }
  @objc private func setSidebarGroupingDate() {
    preferences.sidebarTabGrouping = .date
    scheduleRefresh()
  }
  @objc private func setSidebarOrderCreated() {
    preferences.sidebarTabOrder = .createdTime
    scheduleRefresh()
  }
  @objc private func setSidebarOrderUpdated() {
    preferences.sidebarTabOrder = .updatedTime
    scheduleRefresh()
  }
  @objc private func insertSidebarDivider() { model.insertDividerAfterSelectedTab() }
  @objc private func removeAllSidebarDividers() { model.removeAllTabDividers() }
  @objc private func showSettings() { (NSApp.delegate as? AsterAppDelegate)?.showSettings(nil) }
}

extension WorkspaceViewController: NSPopoverDelegate {
  func popoverDidClose(_ notification: Notification) {
    workspaceTitleButton?.setPopoverPresented(false)
    workspaceTitlePopover = nil
  }
}
