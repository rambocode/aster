import AppKit
import AsterCore
import Combine
import UniformTypeIdentifiers

/// 保留 `NSSearchField` 的放大镜、清除按钮、输入法和焦点环，只把底色换成设置页自己的
/// 中性灰。底色落在 backing layer 上，因此明暗外观切换时必须重新解析动态颜色。
@MainActor
final class SettingsSearchField: NSSearchField {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    configureAppearance()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    configureAppearance()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    refreshAppearance()
  }

  func refreshAppearance() {
    effectiveAppearance.performAsCurrentDrawingAppearance { [weak self] in
      self?.layer?.backgroundColor = SettingsTheme.searchField.cgColor
    }
  }

  private func configureAppearance() {
    wantsLayer = true
    isBezeled = false
    drawsBackground = false
    focusRingType = .exterior
    layer?.cornerRadius = 7
    refreshAppearance()
  }
}

/// 与 Otty 信息架构一致的九类纯 AppKit 设置页。控件直接写入 `AppPreferences`，
/// 当前终端会话通过其 Combine 订阅即时获得字体、配色、Meta 键和鼠标设置变化。
@MainActor
final class SettingsViewController: NSViewController, NSSearchFieldDelegate {
  /// 设置页首次打开使用 `700 × 460pt`，宽度下限为 `700pt`；宽高由用户拉伸并跨启动
  /// 记忆（真值见 `SettingsWindowGeometry`）。侧栏保持固定，右侧单列内容填满剩余宽度，
  /// 超出高度的部分由分类滚动区域承载。独立设置窗口不得联动主工作区窗口 frame。
  static let defaultContentSize = NSSize(
    width: CGFloat(SettingsWindowGeometry.width),
    height: CGFloat(SettingsWindowGeometry.defaultHeight)
  )

  enum Section: String, CaseIterable {
    case general = "通用"
    case shell = "Shell"
    case controls = "控制"
    case editor = "编辑器"
    case agents = "智能体"
    case appearance = "外观"
    case recipes = "Recipes"
    case shortcuts = "快捷键"
    case advanced = "高级"

    var symbol: String {
      switch self {
      case .general: "exclamationmark.circle"
      case .shell: "terminal"
      case .controls: "cursorarrow.motionlines"
      case .editor: "doc.text"
      case .agents: "sparkles"
      case .appearance: "paintpalette"
      case .recipes: "square.grid.2x2"
      case .shortcuts: "bolt"
      case .advanced: "wrench.and.screwdriver"
      }
    }
  }

  let sections = Section.allCases
  private let preferences: AppPreferences
  private let panelLayoutBinding: WorkspacePanelSettingsBinding
  private let agentSetupService: AgentSetupService
  private var selection: Section = .general
  private var searchText = ""
  private var focusedThemeID: String?
  private var themeDraft: TerminalTheme?
  /// 详情色板取色器的当前目标：这次在改哪套主题的哪个 token。
  private var themeColorPickTarget: (themeID: String, slotID: String, createdCopy: Bool)?
  /// 被点开的那个色块，改色时就地预览，不必重建整页。
  private weak var themeColorPickAnchor: ThemeColorSwatch?
  /// 取色期间挂起整页重建。`updateTheme` 会广播 preferences 变化，重建会销毁 popover
  /// 的锚点视图，取色器在用户拖到一半时就被关掉，之后每一次改色都会因为目标已清空而
  /// 被丢弃——表现就是「调完颜色关掉，值没设置上」。
  private var isPickingThemeColor = false
  private var needsRefreshAfterColorPick = false
  /// 测试需要驱动 scope 切换,保持 internal;界面仍只经分段控件修改。
  var fontScope: FontScope = .computed
  private var message: String?
  private var cancellables: Set<AnyCancellable> = []
  private var refreshScheduled = false
  /// 原生控件已经在点击时就地更新自己的视觉状态。控件回调同步写配置期间，忽略这次
  /// `objectWillChange`，避免下一轮主队列销毁正在播放切换动画的控件并重建整页。
  /// 外部配置变化仍走订阅刷新；确有行级联动的控件由工厂参数显式请求一次刷新。
  private var isApplyingLocalControlAction = false
  private var retainedObjects: [AnyObject] = []
  private weak var sidebarSearchField: NSSearchField?
  // 滚动位置保持：全量重建会丢掉 NSScrollView 状态，这里按分类分桶记录偏移。
  private weak var contentScrollView: NSScrollView?
  private var scrollOffsets: [Section: CGPoint] = [:]
  private var renderedSection: Section?
  /// 常驻骨架：侧栏（含搜索框与九个导航按钮）与内容宿主只创建一次，刷新只换内容区。
  /// 曾经每次刷新都重建整棵树——切分类要重造九个按钮与搜索框，开一个开关要重造字体
  /// 菜单和 24 张主题卡，点击反馈因此被主线程布局工作卡住。
  private weak var contentContainer: NSView?
  private weak var sidebarHost: NSView?
  private weak var sidebarColumn: NSStackView?
  private var sidebarButtons: [(section: Section, button: SettingsSidebarButton)] = []
  /// 当前侧栏按钮对应的分类列表；只有搜索过滤结果变化时才真的重建按钮。
  private var renderedSidebarSections: [Section] = []
  static let sidebarIdentifier = NSUserInterfaceItemIdentifier("settings-sidebar")
  static let contentIdentifier = NSUserInterfaceItemIdentifier("settings-content")
  static let searchIdentifier = NSUserInterfaceItemIdentifier("settings-search")

  enum FontScope: Int, CaseIterable {
    case computed
    case global
    case theme
    case fallback

    var label: String {
      switch self {
      case .computed: "计算值"
      case .global: "全局"
      case .theme: "主题"
      case .fallback: "回退"
      }
    }
  }

  init(
    preferences: AppPreferences,
    panelLayoutBinding: WorkspacePanelSettingsBinding = WorkspacePanelSettingsBinding(),
    agentSetupService: AgentSetupService = AgentSetupService()
  ) {
    self.preferences = preferences
    self.panelLayoutBinding = panelLayoutBinding
    self.agentSetupService = agentSetupService
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  override func loadView() {
    // 初始尺寸取默认值；窗口宽高可由用户拉伸，内容超出高度时由分类滚动视图承载。
    view = NSView(frame: NSRect(origin: .zero, size: Self.defaultContentSize))
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    preferences.objectWillChange
      .sink { [weak self] _ in
        guard let self, !self.isApplyingLocalControlAction else { return }
        self.scheduleRefresh()
      }
      .store(in: &cancellables)
    panelLayoutBinding.objectWillChange
      .sink { [weak self] _ in
        // 与 preferences 同样的豁免：Panel 宽度滑杆是本页控件，拖动时重建内容区会把
        // 正在被拖的滑杆销毁重建，手感直接断掉。
        guard let self, !self.isApplyingLocalControlAction else { return }
        self.scheduleRefresh()
      }
      .store(in: &cancellables)
    NotificationCenter.default.publisher(for: .terminalNotificationAuthorizationDidChange)
      .sink { [weak self] _ in self?.scheduleRefresh() }
      .store(in: &cancellables)
    TerminalNotificationService.shared.refreshAuthorizationStatus()
    refresh()
  }

  /// 切换到指定分类并立即重建内容区；供布局测试与未来的深链入口使用。
  func showSection(_ section: Section) {
    selection = section
    refresh()
  }

  private func scheduleRefresh() {
    guard !isPickingThemeColor else {
      needsRefreshAfterColorPick = true
      return
    }
    guard !refreshScheduled else { return }
    refreshScheduled = true
    DispatchQueue.main.async { [weak self] in
      self?.refreshScheduled = false
      self?.refresh()
    }
  }

  /// 把一次原生控件操作标记为本页发起的局部更新。配置持久化和其它消费者通知照常
  /// 发生，仅设置页自身跳过无意义的整树重建，保证点击反馈不被主线程布局工作打断。
  private func performLocalControlAction(
    refreshAfterAction: Bool = false,
    _ action: () -> Void
  ) {
    isApplyingLocalControlAction = true
    defer {
      isApplyingLocalControlAction = false
      if refreshAfterAction { scheduleRefresh() }
    }
    action()
  }

  /// 只重建内容区并就地更新侧栏选中态；重建前后按分类保存/恢复滚动位置，避免开关
  /// 一次就跳回顶部。骨架常驻是响应速度的关键：侧栏按钮、搜索框以及它们的焦点状态
  /// 都不会因为一次刷新被销毁。
  private func refresh() {
    installSkeletonIfNeeded()
    // 记录的是「当前树实际渲染的分类」而不是 selection：侧栏切换时 selection 已指向
    // 新分类，用它做 key 会把旧页的偏移写错桶。
    if let scroll = contentScrollView, let rendered = renderedSection {
      scrollOffsets[rendered] = scroll.contentView.bounds.origin
    }
    view.appearance = preferences.preferredAppearance
    // 画布与侧栏底色是 layer 上的 `CGColor`：动态 `NSColor` 只在赋值那一刻解析，且
    // 解析依据是 `NSAppearance.current` 而**不是**视图自己的 appearance——直接取
    // `.cgColor` 会在深色模式下拿到浅色值。骨架常驻后必须在每次刷新（明暗切换也走到
    // 这里）以本视图的实际外观重新取值。
    view.effectiveAppearance.performAsCurrentDrawingAppearance { [weak self] in
      guard let self else { return }
      self.view.layer?.backgroundColor = SettingsTheme.canvas.cgColor
      self.sidebarHost?.layer?.backgroundColor = SettingsTheme.sidebar.cgColor
      (self.sidebarSearchField as? SettingsSearchField)?.refreshAppearance()
    }
    updateSidebar()
    guard let container = contentContainer else { return }
    retainedObjects.removeAll()
    container.removeAllSubviews()
    let scroll = makeContentScroll()
    container.addSubview(scroll)
    scroll.pinEdges(to: container)
    renderedSection = selection

    // 必须先布局再恢复偏移：此时文档高度还是 0，直接 scroll(to:) 会被钳回顶部。
    if let scroll = contentScrollView {
      view.layoutSubtreeIfNeeded()
      let offset = scrollOffsets[selection] ?? .zero
      scroll.contentView.scroll(to: offset)
      scroll.reflectScrolledClipView(scroll.contentView)
    }
  }

  /// 建立「侧栏 + 内容宿主」骨架，只执行一次。
  private func installSkeletonIfNeeded() {
    guard contentContainer == nil else { return }
    view.wantsLayer = true
    view.layer?.backgroundColor = SettingsTheme.canvas.cgColor

    let root = NSStackView()
    root.orientation = .horizontal
    root.alignment = .height
    root.distribution = .fill
    root.spacing = 0
    let sidebar = makeSidebar()
    sidebar.translatesAutoresizingMaskIntoConstraints = false
    sidebar.widthAnchor.constraint(equalToConstant: 200).isActive = true
    root.addArrangedSubview(sidebar)
    // 内容宿主承担窗口横向剩余宽度；固有尺寸优先级必须压低，否则根 Stack 会按内容
    // 的最小宽度布局，在右侧留下空白（与内部滚动视图同样的约束理由）。
    let container = NSView()
    container.identifier = Self.contentIdentifier
    container.setContentHuggingPriority(.defaultLow, for: .horizontal)
    container.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    root.addArrangedSubview(container)
    view.addSubview(root)
    root.pinEdges(to: view)
    contentContainer = container
  }

  // MARK: - Shell

  private func makeSidebar() -> NSView {
    let host = NSView()
    host.identifier = Self.sidebarIdentifier
    host.wantsLayer = true
    host.layer?.backgroundColor = SettingsTheme.sidebar.cgColor
    sidebarHost = host
    let column = NSStackView()
    column.orientation = .vertical
    // 默认 alignment 会按按钮固有宽度居中；侧栏导航必须整行拉伸，才能维持
    // Otty 的左对齐导航和完整选中背景。
    column.alignment = .width
    column.spacing = 1
    // 顶部内边距为透明标题栏下的红绿灯让位（全高侧栏窗口）；左右为 0，
    // 让导航行的选中高亮整宽贴到窗口边缘（Otty 风格），搜索框单独留边。
    column.edgeInsets = NSEdgeInsets(top: SettingsMetrics.sidebarTopInset, left: 0, bottom: 12, right: 0)

    let search = SettingsSearchField()
    search.identifier = Self.searchIdentifier
    search.placeholderString = "搜索"
    search.stringValue = searchText
    search.delegate = self
    search.controlSize = .large
    sidebarSearchField = search
    search.translatesAutoresizingMaskIntoConstraints = false
    search.heightAnchor.constraint(equalToConstant: 30).isActive = true
    column.addArrangedSubview(search)
    search.widthAnchor.constraint(equalTo: column.widthAnchor, constant: -24).isActive = true
    column.setCustomSpacing(14, after: search)

    let spacer = NSView()
    column.addArrangedSubview(spacer)
    let version = makeLabel("Aster 0.4.1", size: 9, color: SettingsTheme.tertiaryInk, monospaced: true)
    version.alignment = .center
    column.addArrangedSubview(version)

    host.addSubview(column)
    column.pinEdges(to: host)
    sidebarColumn = column
    rebuildSidebarButtons()
    return host
  }

  /// 侧栏点击：只切内容区，选中态由按钮自己就地翻转。
  private func selectSection(_ section: Section) {
    guard section != selection else { return }
    selection = section
    refresh()
  }

  /// 刷新侧栏。过滤结果没变时只翻转选中态——重建九个按钮意味着重造九个 SF Symbol
  /// 图像视图和标签，纯属浪费，还会让点击瞬间的高亮闪一下。
  private func updateSidebar() {
    guard renderedSidebarSections != filteredSections else {
      for entry in sidebarButtons {
        entry.button.setSelected(entry.section == selection)
        // 高亮底色是 layer 上的 CGColor，明暗切换时按钮实例并不会重建；这里显式重算，
        // 不依赖 `viewDidChangeEffectiveAppearance` 的回调时机。
        entry.button.refreshAppearance()
      }
      return
    }
    rebuildSidebarButtons()
  }

  /// 按当前搜索过滤结果重建导航按钮，插在搜索框与底部占位之间。
  private func rebuildSidebarButtons() {
    guard let column = sidebarColumn else { return }
    for entry in sidebarButtons {
      column.removeArrangedSubview(entry.button)
      entry.button.removeFromSuperview()
    }
    sidebarButtons.removeAll()
    // 索引 0 是搜索框；按钮依次插在它后面，占位视图与版本号仍留在末尾。
    for (offset, section) in filteredSections.enumerated() {
      let button = SettingsSidebarButton(
        section: section,
        selected: section == selection,
        action: { [weak self] in self?.selectSection(section) }
      )
      column.insertArrangedSubview(button, at: offset + 1)
      button.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
      sidebarButtons.append((section, button))
    }
    renderedSidebarSections = filteredSections
  }

  private var filteredSections: [Section] {
    let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    return query.isEmpty ? sections : sections.filter {
      $0.rawValue.localizedCaseInsensitiveContains(query)
    }
  }

  /// 搜索只过滤侧栏导航，内容区保持不动。搜索框现在是常驻实例，逐字输入既不会重建
  /// 内容区，也不再需要事后把 first responder 抢回来（那次抢回来会打断输入法候选）。
  func controlTextDidChange(_ obj: Notification) {
    guard let field = obj.object as? NSSearchField, field === sidebarSearchField else { return }
    searchText = field.stringValue
    updateSidebar()
  }

  private func makeContentScroll() -> NSView {
    let scroll = NSScrollView()
    scroll.drawsBackground = true
    scroll.backgroundColor = SettingsTheme.canvas
    scroll.hasVerticalScroller = true
    scroll.autohidesScrollers = true
    // 右侧滚动区承担窗口横向伸缩；降低固有宽度优先级，避免根 Stack 仅按
    // 文档内容的最小宽度布局，从而在右侧留下大块空白。
    scroll.setContentHuggingPriority(.defaultLow, for: .horizontal)
    scroll.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

    // 只翻转滚动文档，不翻转 StackView 本身。直接翻转 StackView 会把第一项排到
    // 文档底部，短页面仍会出现顶部大空白。
    let document = FlippedDocumentView()
    let content = NSStackView()
    content.orientation = .vertical
    content.alignment = .width
    content.spacing = 16
    content.edgeInsets = NSEdgeInsets(top: 26, left: 26, bottom: 30, right: 26)
    let items = sectionViews()
    for item in items {
      content.addArrangedSubview(item)
      // 每一个顶层项都要显式钉住左右边距，一个都不能漏。`NSStackView` 的 `.width`
      // 对齐 + `edgeInsets` 在两个方向上都不可靠：固有宽度超过可用宽度时，卡片会被
      // 丢到 x=0（系统集成卡片曾因此贴左边缘）；固有宽度小于可用宽度时，视图又会
      // 缩成固有宽度并靠右（放大窗口后主题网格、字体卡整块飘到右侧，左边留大片空白）。
      // 只对部分项加约束就会出现这种「一半满宽、一半靠右」的错位。
      item.leadingAnchor.constraint(
        equalTo: content.leadingAnchor, constant: content.edgeInsets.left
      ).isActive = true
      item.trailingAnchor.constraint(
        equalTo: content.trailingAnchor, constant: -content.edgeInsets.right
      ).isActive = true
    }
    // 分组节奏：标题紧贴自己的卡片（8pt），上一块内容与下一个标题拉开（28pt），
    // 形成截图里「小标题 + 大卡片」的分组观感。
    for (index, item) in items.enumerated() {
      if item.identifier == Self.groupTitleIdentifier {
        content.setCustomSpacing(8, after: item)
        if index > 0 {
          content.setCustomSpacing(28, after: items[index - 1])
        }
      }
    }
    if let message {
      content.addArrangedSubview(makeLabel("✓  \(message)", size: 10.5, color: SettingsTheme.accent))
    }
    document.addSubview(content)
    scroll.documentView = document
    contentScrollView = scroll
    content.translatesAutoresizingMaskIntoConstraints = false
    document.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
      document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
      document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
      document.heightAnchor.constraint(greaterThanOrEqualTo: scroll.contentView.heightAnchor),
      content.leadingAnchor.constraint(equalTo: document.leadingAnchor),
      content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
      content.topAnchor.constraint(equalTo: document.topAnchor),
      document.bottomAnchor.constraint(greaterThanOrEqualTo: content.bottomAnchor),
    ])
    return scroll
  }

  private func sectionViews() -> [NSView] {
    switch selection {
    case .general: generalViews()
    case .shell: shellViews()
    case .controls: controlViews()
    case .editor: editorViews()
    case .agents: agentViews()
    case .appearance: appearanceViews()
    case .recipes: recipeViews()
    case .shortcuts: shortcutViews()
    case .advanced: advancedViews()
    }
  }

  // MARK: - Basic sections

  private func generalViews() -> [NSView] {
    [
      sectionTitle("通用"),
      card([
        popupRow(
          "语言", "界面显示语言",
          items: Self.languageOptions.map(\.label),
          selected: Self.languageOptions.firstIndex {
            $0.value == preferences.configuration.general.language
          } ?? 0
        ) { [weak self] index in
          self?.preferences.configuration.general.language = Self.languageOptions[index].value
        },
        enumPopupRow(
          "启动时", "打开 Aster 时的初始窗口行为",
          value: preferences.configuration.launchBehavior
        ) { [weak self] value in
          self?.preferences.configuration.launchBehavior = value
        },
        toggleRow(
          "最后一个窗口关闭后退出", "关闭全部窗口时同时退出应用",
          value: preferences.configuration.general.quitAfterLastWindowClosed
        ) { [weak self] value in
          self?.preferences.configuration.general.quitAfterLastWindowClosed = value
        },
        toggleRow(
          "全部关闭后新建窗口", "点按 Dock 图标时，若没有窗口则自动新建",
          value: preferences.configuration.general.newWindowWhenAllClosed
        ) { [weak self] value in
          self?.preferences.configuration.general.newWindowWhenAllClosed = value
        },
      ]),
      sectionTitle("关闭确认"),
      card([
        enumPopupRow(
          "关闭标签页", "何时在关闭标签页前询问",
          value: preferences.configuration.general.closeTabConfirmation
        ) { [weak self] value in
          self?.preferences.configuration.general.closeTabConfirmation = value
        },
        enumPopupRow(
          "关闭窗口", "何时在关闭窗口前询问",
          value: preferences.configuration.general.closeWindowConfirmation
        ) { [weak self] value in
          self?.preferences.configuration.general.closeWindowConfirmation = value
        },
        enumPopupRow(
          "关闭面板", "何时在关闭分屏面板前询问",
          value: preferences.configuration.general.closePaneConfirmation
        ) { [weak self] value in
          self?.preferences.configuration.general.closePaneConfirmation = value
        },
      ]),
      sectionTitle("系统集成"),
      card([
        actionRow(
          "默认终端", "将 Aster 注册为 ssh:// 链接的默认打开方式（macOS 以链接处理器代替全局默认终端）",
          title: "设为默认终端"
        ) { [weak self] in self?.registerAsDefaultTerminal() },
        actionRow(
          "安装 CLI", "把 `aster` 命令安装到 PATH，可在终端里用它打开目录或 Recipe",
          title: "安装 CLI"
        ) { [weak self] in self?.installCLI() },
        actionRow(
          "Finder 集成", "Finder 右键菜单「服务」中的「在 Aster 中打开」；可在「系统设置 → 键盘快捷键 → 服务」中重新绑定",
          title: "打开系统设置"
        ) { [weak self] in
          self?.openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.keyboard?Shortcuts")
        },
        actionRow(
          "完全磁盘访问权限", "当终端中的命令需要读写受保护目录时才需要；没有它 Aster 也能工作",
          title: "打开系统设置"
        ) { [weak self] in
          self?.openSystemSettingsPane("x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")
        },
      ]),
    ]
  }

  // MARK: - System integration actions

  /// macOS 没有全局「默认终端」概念，可注册的是 ssh:// 链接处理器；需以 .app 打包运行。
  private func registerAsDefaultTerminal() {
    let bundleURL = Bundle.main.bundleURL
    guard bundleURL.pathExtension == "app" else {
      message = "需要以 Aster.app 方式运行才能设为默认终端"
      refresh()
      return
    }
    NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpenURLsWithScheme: "ssh") { error in
      Task { @MainActor [weak self] in
        guard let self else { return }
        self.message = error == nil
          ? "已将 Aster 设为 ssh:// 链接的默认终端"
          : "设置失败：\(error!.localizedDescription)"
        self.refresh()
      }
    }
  }

  /// 安装 `aster` 命令行启动器脚本：优先 /usr/local/bin，不可写时退回 ~/.local/bin。
  /// `aster learn` 使用 0600 token 鉴权的本机 URL；其它参数继续交给 `open -a`。
  private func installCLI() {
    let fileManager = FileManager.default
    let localBin = "/usr/local/bin"
    let fallback = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin")
    let targetDir = fileManager.isWritableFile(atPath: localBin) ? localBin : fallback
    let target = (targetDir as NSString).appendingPathComponent("aster")
    do {
      try fileManager.createDirectory(atPath: targetDir, withIntermediateDirectories: true)
      try AsterCLIScript.contents.write(toFile: target, atomically: true, encoding: .utf8)
      try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target)
      let pathHint = targetDir == fallback ? "；如 PATH 未包含该目录请自行加入" : ""
      message = "已安装 aster 命令到 \(target)\(pathHint)"
    } catch {
      message = "CLI 安装失败：\(error.localizedDescription)"
    }
    refresh()
  }

  /// 打开系统设置的指定面板（服务快捷键 / 完全磁盘访问）。
  private func openSystemSettingsPane(_ urlString: String) {
    guard let url = URL(string: urlString) else { return }
    NSWorkspace.shared.open(url)
  }

  private func shellViews() -> [NSView] {
    [
      sectionTitle("通用"),
      card([
        infoRow("登录 Shell", ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh", "系统默认"),
        textRow("终端类型", "auto 使用 xterm-256color；自定义名称必须已安装 terminfo", value: preferences.configuration.appearance.terminalIdentity) { [weak self] value in
          self?.preferences.configuration.appearance.terminalIdentity = value
        },
      ]),
      sectionTitle("Shell 集成"),
      card([
        toggleRow(
          "Shell 集成", "通过终端 OSC 标记跟踪当前目录、标题与命令状态",
          value: preferences.configuration.shell.shellIntegration
        ) { [weak self] value in
          self?.setShellIntegrationEnabled(value)
        },
        toggleRow(
          "SSH 集成", "在 SSH 会话中保持目录与标题跟踪",
          value: preferences.configuration.shell.sshIntegration
        ) { [weak self] value in
          self?.preferences.configuration.shell.sshIntegration = value
        },
      ]),
      sectionTitle("常用目录"),
      card([
        toggleRow(
          "自动记录访问目录", "根据 OSC 7 目录变化更新本机 frecency 排名；忽略列表中的目录不会重新出现",
          value: preferences.configuration.shell.resolvedFrecencyAutoRecord
        ) { [weak self] value in
          self?.preferences.configuration.shell.frecencyAutoRecord = value
        },
      ]),
      sectionTitle("会话恢复"),
      card([
        toggleRow(
          "恢复 tmux / screen 会话", "恢复工作区时重新附着多路复用器会话",
          value: preferences.configuration.shell.restoreMultiplexerSessions
        ) { [weak self] value in
          self?.preferences.configuration.shell.restoreMultiplexerSessions = value
        },
        toggleRow(
          "恢复智能体会话", "恢复工作区时继续之前的智能体 CLI 会话",
          value: preferences.configuration.shell.restoreAgentSessions
        ) { [weak self] value in
          self?.preferences.configuration.shell.restoreAgentSessions = value
        },
        toggleRow(
          "恢复运行中的进程", "恢复工作区时重新启动之前运行的命令",
          value: preferences.configuration.shell.restoreProcesses
        ) { [weak self] value in
          self?.preferences.configuration.shell.restoreProcesses = value
        },
      ]),
      sectionTitle("通知"),
      card([
        actionRow(
          "系统权限",
          "当前状态：\(TerminalNotificationService.shared.authorizationSummary)",
          title: "打开系统设置"
        ) {
          TerminalNotificationService.shared.openSystemSettings()
        },
        toggleRow(
          "命令完成时通知", "长时间命令结束后发送系统通知",
          value: preferences.configuration.shell.notifyOnFinish
        ) { [weak self] value in
          self?.preferences.configuration.shell.notifyOnFinish = value
        },
        toggleRow(
          "命令出错时通知", "命令以非零状态退出时发送系统通知",
          value: preferences.configuration.shell.notifyOnError
        ) { [weak self] value in
          self?.preferences.configuration.shell.notifyOnError = value
        },
        toggleRow(
          "Watch 完成时通知", "otty/aster watch 包装的命令结束后发送系统通知",
          value: preferences.configuration.shell.resolvedNotifyOnWatchFinish
        ) { [weak self] value in
          self?.preferences.configuration.shell.notifyOnWatchFinish = value
        },
        toggleRow(
          "通知 — Shell Controlled", "允许终端程序通过 OSC 9、777 或 99 发送通知",
          value: preferences.configuration.shell.resolvedNotificationShellControlled
        ) { [weak self] value in
          self?.preferences.configuration.shell.notificationShellControlled = value
        },
        enumPopupRow(
          "前台通知", "应用位于前台时是否仍显示横幅",
          value: preferences.configuration.shell.resolvedNotifyWhileForeground
        ) { [weak self] value in
          self?.preferences.configuration.shell.notifyWhileForeground = value
        },
        toggleRow(
          "通知时弹跳 Dock 图标", "应用不活跃且收到通知时请求用户注意",
          value: preferences.configuration.shell.resolvedBounceDockIcon
        ) { [weak self] value in
          self?.preferences.configuration.shell.bounceDockIcon = value
        },
        toggleRow(
          "错误退出时播放声音", "命令以非零状态退出时直接播放系统提示音",
          value: preferences.configuration.shell.resolvedSoundOnErrorExit
        ) { [weak self] value in
          self?.preferences.configuration.shell.soundOnErrorExit = value
        },
        toggleRow(
          "声音 — Shell Controlled", "允许终端 BEL 字符播放系统提示音",
          value: preferences.configuration.shell.terminalBell
        ) { [weak self] value in
          self?.preferences.configuration.shell.terminalBell = value
        },
      ]),
      sectionTitle("通知声音"),
      card([
        notificationSoundToggle("错误退出", category: .errorExit),
        notificationSoundToggle("命令完成", category: .commandFinish),
        notificationSoundToggle("应用通知", category: .application),
      ]),
      sectionTitle("标签徽章"),
      card([
        toggleRow(
          "命令完成徽章", "成功退出后在标签上显示强调色圆点",
          value: preferences.configuration.shell.resolvedBadgeCommandFinish
        ) { [weak self] value in
          self?.preferences.configuration.shell.badgeCommandFinish = value
        },
        toggleRow(
          "命令失败徽章", "非零退出或 OSC 进度错误时显示警告",
          value: preferences.configuration.shell.resolvedBadgeCommandFailure
        ) { [weak self] value in
          self?.preferences.configuration.shell.badgeCommandFailure = value
          self?.preferences.configuration.shell.badgeExitStatus = value
        },
        toggleRow(
          "等待输入徽章", "命令等待输入时在标签上显示标记",
          value: preferences.configuration.shell.badgeAwaitingInput
        ) { [weak self] value in
          self?.preferences.configuration.shell.badgeAwaitingInput = value
        },
      ]),
    ]
  }

  private func notificationSoundToggle(
    _ title: String,
    category: TerminalNotificationCategory
  ) -> NSView {
    toggleRow(
      title, "仅控制系统通知附带的声音，不影响通知是否显示",
      value: preferences.configuration.shell.resolvedNotificationSoundCategories.contains(category)
    ) { [weak self] enabled in
      guard let self else { return }
      var categories = preferences.configuration.shell.resolvedNotificationSoundCategories
      if enabled { categories.insert(category) } else { categories.remove(category) }
      preferences.configuration.shell.notificationSoundCategories = categories
    }
  }

  /// Shell 集成开关同时维护 Bash/tmux 的受管启动文件。禁用前明确确认；文件编辑失败
  /// 时保留原配置并显示错误，避免界面宣称关闭但旧区块仍实际生效。
  private func setShellIntegrationEnabled(_ enabled: Bool) {
    guard enabled != preferences.configuration.shell.shellIntegration else { return }
    if !enabled {
      let alert = NSAlert()
      alert.messageText = "关闭 Shell 集成？"
      alert.informativeText = "命令导航、退出状态和精确目录跟踪将停用；相关设置会保留。"
      alert.alertStyle = .warning
      alert.addButton(withTitle: "关闭")
      alert.addButton(withTitle: "取消")
      guard alert.runModal() == .alertFirstButtonReturn else {
        refresh()
        return
      }
    }
    guard let installer = AsterResourceLocations.shellIntegrationInstaller() else {
      message = "找不到签名的 Shell 集成资源，设置未更改。"
      refresh()
      return
    }
    do {
      try installer.reconcile(enabled: enabled)
      preferences.configuration.shell.shellIntegration = enabled
      message = enabled ? "Shell 集成已启用，新 Pane 将立即生效。" : "Shell 集成已关闭。"
    } catch {
      message = "Shell 集成设置失败：\(error.localizedDescription)"
    }
    refresh()
  }

  private func controlViews() -> [NSView] {
    [
      sectionTitle("键盘"),
      card([
        toggleRow("Option 作为 Meta", "发送 Esc 前缀，兼容 Emacs 和 Shell 快捷键", value: preferences.configuration.controls.optionAsMeta) { [weak self] value in
          self?.preferences.configuration.controls.optionAsMeta = value
        },
      ]),
      sectionTitle("Autocomplete"),
      card([
        enumPopupRow(
          "接受候选", "选择用于接受 inline suggestion 的快捷键",
          value: preferences.configuration.controls.resolvedAutocompleteShortcut
        ) { [weak self] value in
          self?.preferences.configuration.controls.autocompleteShortcut = value
        },
        enumPopupRow(
          "候选面板", "自动显示或使用快捷键打开；面板最多显示 8 项",
          value: preferences.configuration.controls.resolvedAutocompleteCandidatePanel
        ) { [weak self] value in
          self?.preferences.configuration.controls.autocompleteCandidatePanel = value
        },
        toggleRow(
          "Inline suggestion", "在终端光标后显示最高排名候选的灰色后缀",
          value: preferences.configuration.controls.resolvedAutocompleteInlineSuggestion
        ) { [weak self] value in
          self?.preferences.configuration.controls.autocompleteInlineSuggestion = value
        },
        toggleRow(
          "本机学习", "在本机脱敏记录命令，并允许 README 与沙箱 help 规格学习",
          value: preferences.configuration.controls.resolvedAutocompleteOnDeviceLearning
        ) { [weak self] value in
          self?.preferences.configuration.controls.autocompleteOnDeviceLearning = value
        },
        textRow(
          "历史忽略模式", "逗号分隔的 glob，例如 ssh *,mysql *；匹配命令不会保存",
          value: preferences.configuration.controls.resolvedAutocompleteHistoryIgnore
            .joined(separator: ",")
        ) { [weak self] value in
          self?.preferences.configuration.controls.autocompleteHistoryIgnore = value
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        },
        enumPopupRow(
          "描述语言", "候选面板中的命令说明语言",
          value: preferences.configuration.controls.resolvedAutocompleteDescriptionLanguage
        ) { [weak self] value in
          self?.preferences.configuration.controls.autocompleteDescriptionLanguage = value
        },
        infoRow(
          "Fig 规格版本", "内置 715 个直接命令规格；只在手动操作时联网",
          AutocompleteService.shared?.specDatabase.sourceRevision.prefix(12).description ?? "不可用"
        ),
        actionRow(
          "更新命令规格", "从 Fig 官方 GitHub tree 手动刷新；不会覆盖本地 help 规格",
          title: "立即更新"
        ) { [weak self] in self?.updateAutocompleteSpecs() },
        actionRow(
          "本机学习数据", "清除历史、固定命令及 frecency；内置和本地规格保留",
          title: "清除"
        ) { [weak self] in self?.clearAutocompleteLearning() },
      ]),
      sectionTitle("鼠标"),
      card([
        toggleRow("允许鼠标报告", "供 vim、tmux、htop 等 TUI 使用", value: preferences.configuration.controls.allowMouseReporting) { [weak self] value in
          self?.preferences.configuration.controls.allowMouseReporting = value
        },
        toggleRow(
          "焦点跟随鼠标", "指针悬停的分屏面板自动获得键盘焦点",
          value: preferences.configuration.controls.focusFollowsMouse
        ) { [weak self] value in
          self?.preferences.configuration.controls.focusFollowsMouse = value
        },
      ]),
      sectionTitle("CLI 与 IPC"),
      card([
        toggleRow(
          "允许发送输入", "允许已鉴权的本机 aster CLI 向终端 Pane 发送文本、按键或命令",
          value: preferences.configuration.controls.resolvedIPCAllowSendKeys
        ) { [weak self] value in
          self?.preferences.configuration.controls.ipcAllowSendKeys = value
        },
        toggleRow(
          "允许敏感会话", "额外允许 CLI 写入正在运行 ssh 或 sudo 的 Pane；需要先开启发送输入",
          value: preferences.configuration.controls.resolvedIPCAllowSensitiveSessions
        ) { [weak self] value in
          self?.preferences.configuration.controls.ipcAllowSensitiveSessions = value
        },
      ]),
      sectionTitle("选择"),
      card([
        toggleRow(
          "Shift+方向键扩展选区", "关闭后把 Shift+方向键原样发送给终端程序",
          value: preferences.configuration.controls.resolvedShiftArrowSelection
        ) { [weak self] value in
          self?.preferences.configuration.controls.shiftArrowSelection = value
        },
        toggleRow(
          "输入时清除选区", "向终端发送文字、导航键、Tab 或 IME 文本时取消选中",
          value: preferences.configuration.controls.resolvedClearSelectionOnTyping
        ) { [weak self] value in
          self?.preferences.configuration.controls.clearSelectionOnTyping = value
        },
        toggleRow(
          "复制后清除选区", "显式复制后取消选中；选中即复制始终保留选区",
          value: preferences.configuration.controls.resolvedClearSelectionOnCopy
        ) { [weak self] value in
          self?.preferences.configuration.controls.clearSelectionOnCopy = value
        },
      ]),
      sectionTitle("复制与粘贴"),
      card([
        toggleRow(
          "选中即复制", "选中文本后自动写入剪贴板",
          value: preferences.configuration.controls.copyOnSelect
        ) { [weak self] value in
          self?.preferences.configuration.controls.copyOnSelect = value
        },
        toggleRow(
          "复制时去除行尾空格", "复制的每行去掉末尾的空白字符",
          value: preferences.configuration.controls.trimTrailingSpaces
        ) { [weak self] value in
          self?.preferences.configuration.controls.trimTrailingSpaces = value
        },
        toggleRow(
          "粘贴保护", "粘贴多行或含控制字符的内容前先确认",
          value: preferences.configuration.controls.pasteProtection
        ) { [weak self] value in
          self?.preferences.configuration.controls.pasteProtection = value
        },
        toggleRow(
          "信任括号粘贴", "程序已协商 bracketed paste 时跳过危险内容确认",
          value: preferences.configuration.controls.resolvedPasteBracketedSafe
        ) { [weak self] value in
          self?.preferences.configuration.controls.pasteBracketedSafe = value
        },
        enumPopupRow(
          "OSC 52 写入剪贴板", "终端程序请求替换系统剪贴板时的权限",
          value: preferences.configuration.controls.resolvedClipboardWriteAccess
        ) { [weak self] value in
          self?.preferences.configuration.controls.clipboardWriteAccess = value
        },
        enumPopupRow(
          "OSC 52 读取剪贴板", "终端程序请求读取系统剪贴板时的权限",
          value: preferences.configuration.controls.resolvedClipboardReadAccess
        ) { [weak self] value in
          self?.preferences.configuration.controls.clipboardReadAccess = value
        },
      ]),
      sectionTitle("文件与链接"),
      card([
        toggleRow(
          "识别终端目标", "识别本地路径、URL 和 OSC 8 显式链接",
          value: preferences.configuration.controls.resolvedLinkDetectionEnabled
        ) { [weak self] value in
          self?.preferences.configuration.controls.linkDetectionEnabled = value
        },
        toggleRow(
          "识别所有 URL Scheme", "关闭后仅识别 http、https、file、mailto 和自定义列表",
          value: preferences.configuration.controls.detectAllLinkSchemes ?? true
        ) { [weak self] value in
          self?.preferences.configuration.controls.detectAllLinkSchemes = value
        },
        textRow(
          "自定义 Scheme", "用逗号分隔，例如 vscode,codex,ssh",
          value: preferences.configuration.controls.resolvedCustomLinkSchemes.sorted()
            .joined(separator: ",")
        ) { [weak self] value in
          let schemes = value.split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter(LinkSchemePolicy.isSyntacticallyValid)
          self?.preferences.configuration.controls.customLinkSchemes = Set(schemes.prefix(64))
        },
        actionRow(
          "安全警告例外", "清除已记住的非标准 Scheme 授权",
          title: "重置警告"
        ) { [weak self] in
          self?.preferences.configuration.controls.allowedNonStandardLinkSchemes = []
        },
      ]),
      sectionTitle("滚动"),
      card([
        toggleRow(
          "平滑滚动", "触控板按像素滚动，并在手势结束时对齐字符行",
          value: preferences.configuration.controls.smoothScrolling
        ) { [weak self] value in
          self?.preferences.configuration.controls.smoothScrolling = value
        },
        enumPopupRow(
          "滚过末尾", "选择最新内容或光标滚到视口中的停靠位置",
          value: preferences.configuration.controls.resolvedScrollPastLastLine
        ) { [weak self] value in
          self?.preferences.configuration.controls.scrollPastLastLine = value
        },
        enumPopupRow(
          "滚过开头", "选择最早内容滚到视口中的停靠位置",
          value: preferences.configuration.controls.resolvedScrollPastFirstLine
        ) { [weak self] value in
          self?.preferences.configuration.controls.scrollPastFirstLine = value
        },
      ]),
      sectionTitle("显示"),
      card([
        toggleRow(
          "链接预览", "悬停链接时显示 URL 目标",
          value: preferences.configuration.controls.showLinkPreviews
        ) { [weak self] value in
          self?.preferences.configuration.controls.showLinkPreviews = value
        },
      ]),
      sectionTitle("安全"),
      card([
        toggleRow(
          "自动安全输入", "检测到密码输入时启用系统安全键盘",
          value: preferences.configuration.controls.secureInputAutomatically
        ) { [weak self] value in
          self?.preferences.configuration.controls.secureInputAutomatically = value
        },
      ]),
    ]
  }

  private func updateAutocompleteSpecs() {
    guard let service = AutocompleteService.shared else {
      message = "Autocomplete 规格服务不可用。"
      refresh()
      return
    }
    message = "正在手动更新 Fig 命令规格…"
    refresh()
    Task { @MainActor [weak self, service] in
      do {
        let revision = try await service.updateNow()
        self?.message = "命令规格已更新到 \(revision.prefix(12))。"
      } catch {
        self?.message = "命令规格更新失败：\(error.localizedDescription)"
      }
      self?.refresh()
    }
  }

  private func clearAutocompleteLearning() {
    guard let service = AutocompleteService.shared else {
      message = "Autocomplete 规格服务不可用。"
      refresh()
      return
    }
    do {
      try service.clearLearning()
      message = "已清除本机 Autocomplete 学习数据。"
    } catch {
      message = "清除失败：\(error.localizedDescription)"
    }
    refresh()
  }

  private func editorViews() -> [NSView] {
    [
      sectionTitle("编辑器"),
      card([
        toggleRow(
          "自动换行", "对长行进行软换行，而不是水平滚动",
          value: preferences.configuration.editor.lineWrap
        ) { [weak self] value in
          self?.preferences.configuration.editor.lineWrap = value
        },
        toggleRow(
          "显示行号", "在文本面板左侧显示行号侧栏",
          value: preferences.configuration.editor.showLineNumbers
        ) { [weak self] value in
          self?.preferences.configuration.editor.showLineNumbers = value
        },
        toggleRow(
          "显示不可见字符", "把空格、Tab、换行渲染为可见符号",
          value: preferences.configuration.editor.showVisibleWhitespace
        ) { [weak self] value in
          self?.preferences.configuration.editor.showVisibleWhitespace = value
        },
        stepperRow(
          "Tab 宽度", "Tab 字符的视觉宽度（列数）",
          value: Double(preferences.configuration.editor.tabSize), range: 2...8
        ) { [weak self] value in
          self?.preferences.configuration.editor.tabSize = Int(value)
        },
        toggleRow(
          "滚动越过末尾", "允许继续向下滚动，使最后一行可位于视口顶部",
          value: preferences.configuration.editor.scrollPastEnd
        ) { [weak self] value in
          self?.preferences.configuration.editor.scrollPastEnd = value
        },
        toggleRow(
          "Vim 按键", "在文件 / 编辑器面板中启用模态编辑",
          value: preferences.configuration.editor.vimKeyBindings
        ) { [weak self] value in
          self?.preferences.configuration.editor.vimKeyBindings = value
        },
      ]),
      sectionTitle("打开文件"),
      card([
        toggleRow(
          "预览富文档", "双击 Markdown 等文件时在相邻面板渲染预览",
          value: preferences.configuration.editor.previewRichDocuments
        ) { [weak self] value in
          self?.preferences.configuration.editor.previewRichDocuments = value
        },
      ]),
    ]
  }

  private func agentViews() -> [NSView] {
    let providers: [(name: String, provider: AgentProvider)] = [
      ("Claude Code", .claudeCode),
      ("Codex", .codex),
      ("OpenCode", .openCode),
      ("Cursor CLI", .cursorCLI),
      ("Kimi Code", .kimiCode),
      ("Pi", .pi),
      ("omp", .omp),
    ]
    // enabledAgents 是命令名数组：开关按「包含与否」读写，保持数组内不重复。
    let agentRows = providers.map { name, provider in
      let command = provider.commandName
      return toggleRow(
        name,
        "\(command) · 是否启用 Aster 的 Agent 行为",
        value: preferences.configuration.agents.enabledAgents.contains(command)
      ) { [weak self] enabled in
        guard let self else { return }
        var agents = self.preferences.configuration.agents.enabledAgents
        agents.removeAll { $0 == command }
        if enabled { agents.append(command) }
        self.preferences.configuration.agents.enabledAgents = agents
      }
    }
    let setupRows = providers.map { agentSetupRow(name: $0.name, provider: $0.provider) }
    let launchRows = providers.map { name, provider in
      textRow(
        name,
        "启动命令；支持带引号参数，留空恢复 \(provider.commandName)",
        value: WorkflowShellCommandEncoder.encode(
          preferences.configuration.agents.launchComponents(for: provider)
        )
      ) { [weak self] value in
        self?.updateAgentLaunchCommand(value, provider: provider, displayName: name)
      }
    }
    return [
      sectionTitle("已启用的智能体"),
      card(agentRows),
      sectionTitle("Agent 集成"),
      card(setupRows),
      sectionTitle("启动命令"),
      card(launchRows),
      sectionTitle("标签徽章"),
      card([
        toggleRow(
          "处理中徽章", "智能体处理任务时在标签上显示标记",
          value: preferences.configuration.agents.badgeProcessing
        ) { [weak self] value in
          self?.preferences.configuration.agents.badgeProcessing = value
        },
        toggleRow(
          "任务完成徽章", "智能体完成任务时在标签上显示标记",
          value: preferences.configuration.agents.badgeTaskComplete
        ) { [weak self] value in
          self?.preferences.configuration.agents.badgeTaskComplete = value
        },
        toggleRow(
          "等待输入徽章", "智能体等待确认时在标签上显示标记",
          value: preferences.configuration.agents.badgeAwaitingInput
        ) { [weak self] value in
          self?.preferences.configuration.agents.badgeAwaitingInput = value
        },
      ]),
      sectionTitle("通知"),
      card([
        toggleRow(
          "任务完成时通知", "智能体完成任务后发送系统通知",
          value: preferences.configuration.agents.notifyTaskComplete
        ) { [weak self] value in
          self?.preferences.configuration.agents.notifyTaskComplete = value
        },
        toggleRow(
          "等待输入时通知", "智能体等待确认时发送系统通知",
          value: preferences.configuration.agents.notifyAwaitingInput
        ) { [weak self] value in
          self?.preferences.configuration.agents.notifyAwaitingInput = value
        },
      ]),
      sectionTitle("运行"),
      card([
        toggleRow(
          "处理期间阻止睡眠", "智能体处理任务时阻止系统进入睡眠",
          value: preferences.configuration.agents.preventSleepWhileProcessing
        ) { [weak self] value in
          self?.preferences.configuration.agents.preventSleepWhileProcessing = value
        },
        toggleRow(
          "恢复智能体会话", "恢复工作区时继续之前的智能体会话",
          value: preferences.configuration.agents.resumeSessions
        ) { [weak self] value in
          self?.preferences.configuration.agents.resumeSessions = value
        },
      ]),
    ]
  }

  private func updateAgentLaunchCommand(
    _ value: String,
    provider: AgentProvider,
    displayName: String
  ) {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    var commands = preferences.configuration.agents.customLaunchCommands ?? [:]
    if trimmed.isEmpty {
      commands.removeValue(forKey: provider.rawValue)
      preferences.configuration.agents.customLaunchCommands = commands
      return
    }
    let components = ShellCommandTokenizer.tokenize(trimmed).tokens
    guard let executable = components.first,
      !components.contains(where: { component in
        component.unicodeScalars.contains(where: {
          CharacterSet.controlCharacters.contains($0)
        })
      }),
      (try? AgentLaunchPrefix(
        executable: executable,
        arguments: Array(components.dropFirst())
      )) != nil
    else {
      message = "\(displayName) 启动命令无效，已保留原设置。"
      refresh()
      return
    }
    commands[provider.rawValue] = components
    preferences.configuration.agents.customLaunchCommands = commands
  }

  /// 每个 provider 都从同一安全服务读取状态；设置页不根据文件是否存在自行猜测，
  /// 因而外部同名文件、损坏配置或未启用的 Codex hooks 不会显示为“已安装”。
  private func agentSetupRow(name: String, provider: AgentProvider) -> NSView {
    do {
      let status = try agentSetupService.status(for: provider)
      let detail: String
      let buttonTitle: String
      if status.managedIntegrationInstalled {
        detail = "\(provider.commandName) · 已安装集成"
        buttonTitle = "卸载"
      } else if status.executableAvailable {
        detail = agentSetupMissingDetail(status)
        buttonTitle = "安装"
      } else {
        detail = "\(provider.commandName) · 未在 PATH 中检测到 CLI"
        buttonTitle = "检测"
      }
      return actionRow(name, detail, title: buttonTitle) { [weak self] in
        self?.performAgentSetupAction(provider, displayName: name)
      }
    } catch {
      return actionRow(
        name,
        "\(provider.commandName) · 配置不可安全读取：\(error.localizedDescription)",
        title: "检测"
      ) { [weak self] in
        self?.performAgentSetupAction(provider, displayName: name)
      }
    }
  }

  private func agentSetupMissingDetail(_ status: AgentSetupStatus) -> String {
    if status.provider == .codex,
      status.managedIntegrationInstalled,
      status.requiredFeatureEnabled != true
    {
      return "codex · Hooks 已安装，但 config.toml 尚未启用 hooks"
    }
    return "\(status.provider.commandName) · 已检测到 CLI，集成尚未安装"
  }

  /// 已安装状态执行精确卸载；未安装状态保持检测/安装语义。所有写入都由安全服务按
  /// Aster 所有权标记处理，设置页不直接编辑 provider 配置。
  private func performAgentSetupAction(_ provider: AgentProvider, displayName: String) {
    do {
      let current = try agentSetupService.status(for: provider)
      if current.managedIntegrationInstalled {
        _ = try agentSetupService.uninstall(provider)
        message = "\(displayName) 集成已卸载；请重启该 Agent。"
      } else if current.executableAvailable {
        let lifecycleHint: String
        if provider == .codex {
          // Codex 会按 hook 定义哈希要求用户首次信任；Aster 不能替用户绕过该安全门。
          lifecycleHint = " 重启 Codex 后请运行 /hooks 审核并信任 Aster hook，再发送一条消息关联会话。"
        } else {
          lifecycleHint = current.plan.linksAfterNextLifecycleEvent
            ? " 启动后发送一条消息即可关联当前会话。"
            : ""
        }
        _ = try agentSetupService.install(provider)
        message = "\(displayName) 集成已安装；请重启该 Agent。\(lifecycleHint)"
      } else {
        message = "未检测到 \(provider.commandName)，请先安装 \(displayName) CLI。"
      }
    } catch {
      message = "\(displayName) 集成失败：\(error.localizedDescription)"
    }
    refresh()
  }

  private func recipeViews() -> [NSView] {
    [
      sectionTitle("命令重放"),
      card([
        enumPopupRow(
          "重放模式", "打开 Recipe 时如何处理其中保存的命令",
          value: preferences.configuration.recipeReplayMode
        ) { [weak self] value in
          self?.preferences.configuration.recipeReplayMode = value
        },
      ]),
      sectionTitle("格式"),
      card([
        infoRow("Recipe 包含", "标签页、分屏方向、目录、文件和可选命令", ".ottyrecipe"),
        infoRow("安全边界", "不会保存 PID、文件描述符、令牌或临时焦点", "可移植"),
      ]),
    ]
  }

  private func shortcutViews() -> [NSView] {
    [
      sectionTitle("快捷键"),
      card([
        infoRow("新建标签页", "", "⌘ T"),
        infoRow("打开文件", "", "⌘ O"),
        infoRow("关闭标签页", "", "⌘ W"),
        infoRow("向右分屏", "", "⌘ D"),
        infoRow("向下分屏", "", "⇧ ⌘ D"),
        infoRow("关闭面板", "", "⌥ ⌘ W"),
        infoRow("命令面板", "", "⌘ K"),
        infoRow("设置", "", "⌘ ,"),
      ]),
    ]
  }

  private func advancedViews() -> [NSView] {
    let selectedAmbiguousBlocks =
      preferences.configuration.appearance.resolvedWidenedEastAsianAmbiguousBlocks
    let ambiguousBlockRows = EastAsianAmbiguousBlock.allCases.map { block in
      toggleRow(
        block.settingsLabel,
        block.settingsDetail,
        value: selectedAmbiguousBlocks.contains(block)
      ) { [weak self] enabled in
        guard let self else { return }
        var blocks = self.preferences.configuration.appearance
          .resolvedWidenedEastAsianAmbiguousBlocks
        if enabled {
          blocks.insert(block)
        } else {
          blocks.remove(block)
        }
        self.preferences.configuration.appearance.widenedEastAsianAmbiguousBlocks = blocks
      }
    }

    return [
      sectionTitle("运行时"),
      card([
        infoRow("终端内核", "VT100 / xterm、真彩色、鼠标、超链接与本地 PTY", "SwiftTerm"),
        infoRow("会话恢复", "保存可重建的标签与分屏结构", "已启用"),
        infoRow("界面框架", "主窗口、设置和所有控件均为原生视图", "AppKit"),
      ]),
      sectionTitle("终端任务"),
      card([
        textRow(
          "自动进度命令", "用逗号分隔；每项按空白分词前缀匹配，留空即关闭",
          value: preferences.configuration.shell.resolvedAutoProgressCommands.joined(separator: ", ")
        ) { [weak self] value in
          self?.preferences.configuration.shell.autoProgressCommands = value
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        },
      ]),
      sectionTitle("标题权限"),
      card([
        toggleRow(
          "标题 — Shell Controlled", "允许终端程序通过 OSC 0、1、2 修改标签与窗口标题",
          value: preferences.configuration.shell.resolvedTitleShellControlled
        ) { [weak self] value in
          self?.preferences.configuration.shell.titleShellControlled = value
        },
        toggleRow(
          "标题报告", "允许终端程序通过 XTWINOPS 读取当前标题；默认关闭以防数据外传",
          value: preferences.configuration.shell.resolvedTitleReport
        ) { [weak self] value in
          self?.preferences.configuration.shell.titleReport = value
        },
      ]),
      sectionTitle("East Asian Ambiguous 宽度"),
      card(ambiguousBlockRows),
      sectionTitle("配置"),
      card([
        actionRow("导出配置", "保存为可备份的 JSON 文件", title: "导出") { [weak self] in self?.exportConfiguration() },
        actionRow("导入配置", "从 JSON 文件替换当前设置", title: "导入") { [weak self] in self?.importConfiguration() },
        actionRow("恢复默认设置", "不会删除 Recipe 和工作区文件", title: "重置") { [weak self] in self?.preferences.reset() },
      ]),
    ]
  }

  // MARK: - Appearance

  private func appearanceViews() -> [NSView] {
    var views: [NSView] = []
    views.append(sectionTitle("布局"))
    views.append(makeLayoutChoices())
    views.append(sectionTitle("标签栏"))
    views.append(card([
      toggleRow(
        "显示标签栏", "关闭后隐藏标签面板，仅保留终端内容",
        value: preferences.configuration.appearance.showTabBar
      ) { [weak self] value in
        self?.preferences.configuration.appearance.showTabBar = value
      },
      enumPopupRow(
        "新标签页位置", "空标签进入当前分组末尾；带内容标签可紧跟当前标签",
        value: preferences.configuration.appearance.resolvedNewTabPosition
      ) { [weak self] value in
        self?.preferences.configuration.appearance.newTabPosition = value
      },
      popupRow(
        "自动隐藏标签面板", "控制侧边栏布局下，标签面板的显示方式",
        items: ["默认", "仅单标签时隐藏"],
        selected: preferences.configuration.appearance.autoHideTabs ? 1 : 0
      ) { [weak self] index in
        self?.preferences.configuration.appearance.autoHideTabs = index == 1
      },
    ]))
    views.append(sectionTitle("窗口"))
    views.append(card([
      popupRow(
        "窗口大小", "新窗口如何决定初始尺寸",
        items: ["记住上次尺寸", "恢复默认尺寸"], selected: 0
      ) { [weak self] index in
        guard index == 1, let self else { return }
        self.preferences.configuration.appearance.windowWidth = 1180
        self.preferences.configuration.appearance.windowHeight = 760
        (NSApp.delegate as? AsterAppDelegate)?.applyDefaultMainWindowSize()
      },
      popupRow(
        "窗口主题", "跟随系统、始终浅色或始终深色",
        items: AppPreferences.Appearance.allCases.map(\.label),
        selected: AppPreferences.Appearance.allCases.firstIndex(of: preferences.appearance) ?? 0
      ) { [weak self] index in
        self?.preferences.appearance = AppPreferences.Appearance.allCases[index]
      },
      panelWidthSliderRow(
        "左侧 Panel 宽度",
        role: .sidebar,
        fallback: preferences.sidebarWidth
      ),
      panelWidthSliderRow(
        "右侧 Panel 宽度",
        role: .inspector,
        fallback: WorkspacePanelLayoutPolicy.inspectorDefaultWidth
      ),
    ]))

    views.append(sectionTitle("Dock"))
    views.append(card([
      toggleRow(
        "任务运行时动画", "任一标签报告进度时让 Dock 图标显示活动状态",
        value: preferences.configuration.appearance.resolvedAnimateDockIconOnProgress
      ) { [weak self] value in
        self?.preferences.configuration.appearance.animateDockIconOnProgress = value
      },
      toggleRow(
        "任务出错时标红", "任一标签失败时将 Dock 图标标红；点击图标跳转到错误标签",
        value: preferences.configuration.appearance.resolvedRedDockIconOnError
      ) { [weak self] value in
        self?.preferences.configuration.appearance.redDockIconOnError = value
      },
      toggleRow(
        "收到通知时跳动", "Aster 不在前台且收到终端通知时请求 Dock 提醒",
        value: preferences.configuration.shell.resolvedBounceDockIcon
      ) { [weak self] value in
        self?.preferences.configuration.shell.bounceDockIcon = value
      },
    ]))

    views.append(sectionTitle("主题"))
    views.append(makeThemeGrid(mode: .light))
    views.append(toggleRow(
      "深色模式使用独立主题",
      "跟随系统配色时，浅色与深色模式分别使用两套主题",
      value: preferences.configuration.appearance.useSeparateDarkTheme,
      refreshAfterAction: true
    ) { [weak self] value in
      self?.preferences.configuration.appearance.useSeparateDarkTheme = value
    })
    if preferences.configuration.appearance.useSeparateDarkTheme {
      views.append(makeThemeGrid(mode: .dark))
    }

    views.append(sectionTitle("详情"))
    views.append(
      ThemeDetailView(theme: focusedTheme) { [weak self] slot, anchor in
        self?.pickColor(for: slot, anchor: anchor)
      })
    let actions = NSStackView(views: [
      contentActionButton(title: "复制") { [weak self] in self?.duplicateTheme() },
      contentActionButton(title: "编辑当前主题") { [weak self] in self?.beginEditingTheme() },
      contentActionButton(title: "打开主题文件夹") { [weak self] in self?.openThemesFolder() },
      contentActionButton(title: "导入主题…") { [weak self] in self?.importTheme() },
      NSView(),
    ])
    // 覆盖是可撤销的：有覆盖时才给出入口，没改过就不要多一个永远点不动的按钮。
    if !preferences.themeOverrides(for: focusedTheme.id).isEmpty {
      actions.insertArrangedSubview(
        contentActionButton(title: "恢复主题原色") { [weak self] in self?.resetThemeOverrides() },
        at: actions.arrangedSubviews.count - 1
      )
    }
    actions.orientation = .horizontal
    actions.spacing = 10
    views.append(actions)
    if let themeDraft { views.append(makeThemeEditor(themeDraft)) }

    views.append(sectionTitle("文本"))
    views.append(card([
      stepperRow("字号", "终端字号", value: preferences.fontSize, range: 9...32) { [weak self] value in
        self?.preferences.fontSize = value
      },
      enumPopupRow(
        "加粗", "选择真实字形、主字体字形或 synthetic bold",
        value: preferences.configuration.appearance.resolvedBoldRendering
      ) { [weak self] value in
        self?.preferences.configuration.appearance.boldRendering = value
      },
      enumPopupRow(
        "斜体", "选择真实字形、主字体字形或 synthetic italic",
        value: preferences.configuration.appearance.resolvedItalicRendering
      ) { [weak self] value in
        self?.preferences.configuration.appearance.italicRendering = value
      },
      toggleRow(
        "下划线", "允许终端程序通过 SGR 显示下划线样式",
        value: preferences.configuration.appearance.resolvedUnderlineRendering
      ) { [weak self] value in
        self?.preferences.configuration.appearance.underlineRendering = value
      },
      toggleRow(
        "闪烁", "允许 SGR 5/6 文本按节奏闪烁；关闭时文本保持可见",
        value: preferences.configuration.appearance.resolvedBlinkRenderingPolicy == .animated
      ) { [weak self] value in
        self?.preferences.configuration.appearance.blinkRenderingPolicy = value ? .animated : .steady
      },
      enumPopupRow(
        "连字", "控制 OpenType 标准、上下文和 discretionary ligatures",
        value: preferences.configuration.appearance.resolvedLigatureLevel
      ) { [weak self] value in
        self?.preferences.configuration.appearance.ligatureLevel = value
      },
      popupRow(
        "字体混合", "控制 macOS 字形平滑；默认使用系统抗锯齿",
        items: ["默认", "关闭"],
        selected: preferences.configuration.appearance.resolvedFontSmoothing ? 0 : 1
      ) { [weak self] index in
        self?.preferences.configuration.appearance.fontSmoothing = index == 0
      },
      popupRow(
        "行高", "终端网格的垂直间距",
        items: ["紧凑 (1.0)", "默认 (1.08)", "宽松 (1.2)"],
        selected: lineHeightSelection(preferences.configuration.appearance.lineHeight)
      ) { [weak self] index in
        self?.preferences.configuration.appearance.lineHeight = [1.0, 1.08, 1.2][index]
      },
    ]))

    views.append(sectionTitle("字体"))
    views.append(makeFontSettings())

    views.append(sectionTitle("光标"))
    views.append(card([
      ThemeCursorPreviewView(
        theme: focusedTheme,
        appearance: preferences.configuration.appearance
      ),
      rowShell(
        "光标颜色", "覆盖主题光标颜色",
        accessory: ClosureColorWell(color: preferences.cursorColor.withAlphaComponent(1)) {
          [weak self] color in
          self?.preferences.configuration.appearance.cursorColorOverride = HexColor(nsColor: color)
        }
      ),
      rowShell(
        "光标下方文字颜色", "仅方块光标覆盖字符时使用",
        accessory: ClosureColorWell(color: preferences.cursorTextColor) { [weak self] color in
          self?.preferences.configuration.appearance.cursorTextColorOverride = HexColor(nsColor: color)
        }
      ),
      sliderRow(
        "光标不透明度", "颜色透明度实时同步到现有终端",
        value: preferences.configuration.appearance.resolvedCursorOpacity,
        range: 0.1...1, suffix: "", fractionDigits: 2
      ) { [weak self] value in
        self?.preferences.configuration.appearance.cursorOpacity = value
      },
      enumPopupRow(
        "光标样式", "方块、竖线、下划线或空心方块",
        value: preferences.configuration.appearance.cursorStyle
      ) { [weak self] value in
        self?.preferences.configuration.appearance.cursorStyle = value
      },
      enumPopupRow(
        "光标闪烁方式",
        "默认模式允许程序覆盖；始终模式忽略 DECSCUSR 与 DEC mode 12",
        value: preferences.configuration.appearance.resolvedCursorBlinkMode
      ) { [weak self] value in
        self?.preferences.configuration.appearance.cursorBlinkMode = value
      },
      enumPopupRow(
        "光标动画", "平滑模式只插值同一行内的短距离移动，并尊重减弱动态效果",
        value: preferences.configuration.appearance.resolvedCursorAnimation
      ) { [weak self] value in
        self?.preferences.configuration.appearance.cursorAnimation = value
      },
      actionRow("主题颜色", "清除覆盖并重新使用当前主题的光标与文字颜色", title: "跟随主题") {
        [weak self] in
        self?.preferences.configuration.appearance.cursorColorOverride = nil
        self?.preferences.configuration.appearance.cursorTextColorOverride = nil
      },
    ]))
    return views
  }

  private func lineHeightSelection(_ value: Double) -> Int {
    let choices = [1.0, 1.08, 1.2]
    return choices.enumerated().min(by: {
      abs($0.element - value) < abs($1.element - value)
    })?.offset ?? 1
  }

  /// 字体页按 Otty 的“计算值 / 全局 / 主题 / 回退”四个来源展示。计算值只读；其它
  /// scope 修改后都进入正式配置或自定义主题，不把临时文本框状态误当成渲染真值。
  /// 字体一律经选择器从已安装列表挑选（含「取消设置」），不再手输字体名。
  private func makeFontSettings() -> NSView {
    let scope = ClosureSegmentedControl(
      labels: FontScope.allCases.map(\.label),
      selected: fontScope.rawValue
    ) { [weak self] index in
      guard let self, let next = FontScope(rawValue: index) else { return }
      self.fontScope = next
      self.refresh()
    }
    let scopeRow = NSStackView(views: [
      makeLabel("设置范围", size: SettingsMetrics.controlTextSize, color: SettingsTheme.secondaryInk),
      scope,
      NSView(),
    ])
    scopeRow.orientation = .horizontal
    scopeRow.spacing = 10

    let rows: [NSView]
    switch fontScope {
    case .computed:
      let fonts = preferences.terminalFontVariants
      rows = [
        cardCaptionRow("由 全局 → 主题 → 回退 解析得到"),
        globalAutomaticStyleToggleRow(),
        infoRow("字体", "", Self.friendlyFontName(fonts.normal)),
        infoRow("字体（粗体）", "", Self.friendlyFontName(fonts.bold)),
        infoRow("字体（斜体）", "", Self.friendlyFontName(fonts.italic)),
        infoRow("字体（粗斜体）", "", Self.friendlyFontName(fonts.boldItalic)),
      ]
    case .global:
      let appearance = preferences.configuration.appearance
      let automatic = appearance.fontFamilyBold == nil
        && appearance.fontFamilyItalic == nil
        && appearance.fontFamilyBoldItalic == nil
      var globalRows: [NSView] = [
        cardCaptionRow("覆盖主题，全局优先"),
        globalAutomaticStyleToggleRow(),
        fontPickerRow(
          "字体", "取消设置则读取当前主题",
          entries: Self.installedFontFamilies(),
          selection: appearance.fontFamily.nilIfBlank
        ) { [weak self] value in
          self?.preferences.configuration.appearance.fontFamily = value ?? ""
        },
      ]
      // 与 Otty 一致:自动匹配开启时不展示逐样式选择器,关闭后展开供显式指定。
      if !automatic {
        let styles = Self.installedFontStyles()
        globalRows += [
          fontPickerRow(
            "字体（粗体）", "", entries: styles, selection: appearance.fontFamilyBold
          ) { [weak self] value in
            self?.preferences.configuration.appearance.fontFamilyBold = value
          },
          fontPickerRow(
            "字体（斜体）", "", entries: styles, selection: appearance.fontFamilyItalic
          ) { [weak self] value in
            self?.preferences.configuration.appearance.fontFamilyItalic = value
          },
          fontPickerRow(
            "字体（粗斜体）", "", entries: styles, selection: appearance.fontFamilyBoldItalic
          ) { [weak self] value in
            self?.preferences.configuration.appearance.fontFamilyBoldItalic = value
          },
        ]
      }
      rows = globalRows
    case .theme:
      let style = focusedTheme.style
      let themeAutomatic = style.fontFamilyBold == nil
        && style.fontFamilyItalic == nil
        && style.fontFamilyBoldItalic == nil
      var themeRows: [NSView] = [
        cardCaptionRow("写入当前主题；修改内置主题时会自动创建可编辑副本"),
        toggleRow(
          "自动匹配粗细与样式",
          "关闭后可为该主题单独指定粗体与斜体字形",
          value: themeAutomatic,
          refreshAfterAction: true
        ) { [weak self] enabled in
          guard let self, enabled != themeAutomatic else { return }
          self.updateFocusedThemeStyle("已更新主题的字体样式") { theme in
            theme.style.fontFamilyBold = nil
            theme.style.fontFamilyItalic = nil
            theme.style.fontFamilyBoldItalic = nil
          }
        },
        fontPickerRow(
          "字体", "写入主题字体栈首位，其余候选保留",
          entries: Self.installedFontFamilies(),
          selection: style.fontFamilies?.first
        ) { [weak self] value in
          self?.updateFocusedThemeStyle("已更新主题字体") { theme in
            let tail = Array((theme.style.fontFamilies ?? []).dropFirst())
            let updated = (value.map { [$0] } ?? []) + tail
            theme.style.fontFamilies = updated.isEmpty ? nil : updated
          }
        },
      ]
      if !themeAutomatic {
        let styles = Self.installedFontStyles()
        themeRows += [
          fontPickerRow("字体（粗体）", "", entries: styles, selection: style.fontFamilyBold) {
            [weak self] value in
            self?.updateFocusedThemeStyle("已更新主题粗体字体") { $0.style.fontFamilyBold = value }
          },
          fontPickerRow("字体（斜体）", "", entries: styles, selection: style.fontFamilyItalic) {
            [weak self] value in
            self?.updateFocusedThemeStyle("已更新主题斜体字体") { $0.style.fontFamilyItalic = value }
          },
          fontPickerRow(
            "字体（粗斜体）", "", entries: styles, selection: style.fontFamilyBoldItalic
          ) { [weak self] value in
            self?.updateFocusedThemeStyle("已更新主题粗斜体字体") {
              $0.style.fontFamilyBoldItalic = value
            }
          },
        ]
      }
      themeRows += [
        textRow(
          "字体候选栈",
          "逗号分隔；首项未安装时依序尝试后续候选",
          value: style.fontFamilies?.joined(separator: ", ") ?? ""
        ) { [weak self] value in
          self?.updateFocusedThemeFontFamilies(value)
        },
        infoRow("当前主题", "字体设置保存到该主题", focusedTheme.name),
      ]
      rows = themeRows
    case .fallback:
      rows = [
        textRow(
          "字体回退",
          "逗号分隔；内置 Nerd Symbols 始终位于首位",
          value: preferences.configuration.appearance.resolvedFontFamilyFallback
            .joined(separator: ", ")
        ) { [weak self] value in
          self?.preferences.configuration.appearance.fontFamilyFallback = value
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        },
      ]
    }

    // 对齐 Otty:动作按钮位于卡片下方左侧。
    let actions = NSStackView(views: [
      contentActionButton(title: "安装字体") { NSFontManager.shared.orderFrontFontPanel(nil) },
      contentActionButton(title: "打开字体文件夹") { [weak self] in self?.openFontsFolder() },
      NSView(),
    ])
    actions.orientation = .horizontal
    actions.spacing = 10
    let column = NSStackView(views: [scopeRow, card(rows), actions])
    column.orientation = .vertical
    column.alignment = .width
    column.spacing = 12
    column.setContentHuggingPriority(.defaultLow, for: .horizontal)
    return column
  }

  /// 计算值 / 全局共用的「自动匹配粗细与样式」开关:状态取全局逐样式覆盖是否为空。
  /// 关闭时把当前解析结果固化到全局,但**绝不写入隐藏系统字体名**(以 "." 开头的
  /// 名字不是稳定 API,历史版本曾把它泄漏进配置导致字体设置不可用)。
  private func globalAutomaticStyleToggleRow() -> NSView {
    let appearance = preferences.configuration.appearance
    let automatic = appearance.fontFamilyBold == nil
      && appearance.fontFamilyItalic == nil
      && appearance.fontFamilyBoldItalic == nil
    return toggleRow(
      "自动匹配粗细与样式",
      "关闭后把当前匹配结果固定到全局设置",
      value: automatic,
      refreshAfterAction: true
    ) { [weak self] enabled in
      guard let self else { return }
      if enabled {
        self.preferences.configuration.appearance.fontFamilyBold = nil
        self.preferences.configuration.appearance.fontFamilyItalic = nil
        self.preferences.configuration.appearance.fontFamilyBoldItalic = nil
      } else {
        let resolved = self.preferences.terminalFontVariants
        self.preferences.configuration.appearance.fontFamilyBold =
          Self.publicFontName(resolved.bold)
        self.preferences.configuration.appearance.fontFamilyItalic =
          Self.publicFontName(resolved.italic)
        self.preferences.configuration.appearance.fontFamilyBoldItalic =
          Self.publicFontName(resolved.boldItalic)
      }
    }
  }

  /// 卡片首行的来源说明(对齐 Otty 每个 scope 的标题行)。
  private func cardCaptionRow(_ text: String) -> NSView {
    let host = NSView()
    host.translatesAutoresizingMaskIntoConstraints = false
    let label = makeLabel(
      text, size: SettingsMetrics.rowDetailSize, color: SettingsTheme.secondaryInk)
    label.translatesAutoresizingMaskIntoConstraints = false
    host.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(
        equalTo: host.leadingAnchor, constant: SettingsMetrics.rowHorizontalInset),
      label.trailingAnchor.constraint(
        lessThanOrEqualTo: host.trailingAnchor, constant: -SettingsMetrics.rowHorizontalInset),
      label.topAnchor.constraint(equalTo: host.topAnchor, constant: 14),
      label.bottomAnchor.constraint(equalTo: host.bottomAnchor),
    ])
    return host
  }

  /// 隐藏系统字体不进入用户可见配置;返回 nil 表示保持自动匹配。
  private static func publicFontName(_ font: NSFont) -> String? {
    font.fontName.hasPrefix(".") ? nil : font.fontName
  }

  /// 计算值页展示的友好字体名:隐藏系统字体显示为语义名称,其余用本地化显示名。
  private static func friendlyFontName(_ font: NSFont) -> String {
    font.fontName.hasPrefix(".") ? "系统等宽字体" : font.displayName ?? font.fontName
  }

  /// 枚举系统字体要遍历成百上千个字体名并逐个构造 `NSFont`，是外观页最贵的一步，
  /// 而它的结果在一次会话里几乎不变。按进程缓存，字体库变化时由下面的监听作废。
  private static var cachedFontFamilies: [FontPickerEntry]?
  private static var cachedFontStyles: [FontPickerEntry]?
  private static var fontLibraryObserver: NSObjectProtocol?

  /// 注册一次字体库变更监听：用户在「字体册」里装了新字体后，选择器下次打开就能看到，
  /// 不必重启应用。
  private static func observeFontLibraryChangesIfNeeded() {
    guard fontLibraryObserver == nil else { return }
    fontLibraryObserver = NotificationCenter.default.addObserver(
      forName: NSNotification.Name(kCTFontManagerRegisteredFontsChangedNotification as String),
      object: nil,
      queue: .main
    ) { _ in
      MainActor.assumeIsolated {
        cachedFontFamilies = nil
        cachedFontStyles = nil
      }
    }
  }

  /// 已安装字体族(过滤隐藏系统字体),供主字体选择器使用。
  private static func installedFontFamilies() -> [FontPickerEntry] {
    observeFontLibraryChangesIfNeeded()
    if let cachedFontFamilies { return cachedFontFamilies }
    let entries = NSFontManager.shared.availableFontFamilies
      .filter { !$0.hasPrefix(".") }
      .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
      .map { FontPickerEntry(title: $0, value: $0, previewFontName: $0) }
    cachedFontFamilies = entries
    return entries
  }

  /// 已安装的等宽字体样式(家族 + 字重/斜体成员),供粗体/斜体选择器使用。
  /// 只列等宽:终端逐格渲染下比例字体没有实用价值,还会把菜单撑到上千项。
  private static func installedFontStyles() -> [FontPickerEntry] {
    observeFontLibraryChangesIfNeeded()
    if let cachedFontStyles { return cachedFontStyles }
    let manager = NSFontManager.shared
    let fixedPitch = manager.availableFontNames(with: .fixedPitchFontMask) ?? []
    let entries = fixedPitch
      .filter { !$0.hasPrefix(".") }
      .compactMap { name -> FontPickerEntry? in
        guard let font = NSFont(name: name, size: 12) else { return nil }
        return FontPickerEntry(
          title: font.displayName ?? name, value: name, previewFontName: name)
      }
      .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    cachedFontStyles = entries
    return entries
  }

  /// 字体选择行:组合框既可从已安装列表下拉选择,也可直接输入字体名;
  /// 清空即「取消设置」。当前值未安装时原样保留显示,不静默丢弃用户配置。
  private func fontPickerRow(
    _ title: String,
    _ detail: String,
    entries: [FontPickerEntry],
    selection: String?,
    action: @escaping (String?) -> Void
  ) -> NSView {
    let picker = FontComboBox(entries: entries, selection: selection) { [weak self] value in
      guard let self else { return }
      self.performLocalControlAction(refreshAfterAction: true) { action(value) }
    }
    picker.translatesAutoresizingMaskIntoConstraints = false
    picker.widthAnchor.constraint(equalToConstant: 230).isActive = true
    return rowShell(title, detail, accessory: picker)
  }

  private func updateFocusedThemeStyle(
    _ successMessage: String, _ mutate: (inout TerminalTheme) -> Void
  ) {
    var editable = focusedTheme
    if editable.isBuiltIn {
      editable = preferences.duplicateTheme(editable)
      focusedThemeID = editable.id
    }
    mutate(&editable)
    guard preferences.updateTheme(editable) else {
      message = "主题字体保存失败，请确认主题名称未冲突"
      refresh()
      return
    }
    do {
      _ = try preferences.saveThemeToLibraryFolder(editable)
      message = "\(successMessage)（\(editable.name)）"
    } catch {
      message = "主题字体已应用，但文件保存失败：\(error.localizedDescription)"
    }
    refresh()
  }

  private func updateFocusedThemeFontFamilies(_ value: String) {
    let families = value.split(separator: ",").map {
      $0.trimmingCharacters(in: .whitespacesAndNewlines)
    }.filter { !$0.isEmpty }
    updateFocusedThemeStyle("已更新主题字体候选栈") { theme in
      theme.style.fontFamilies = families.isEmpty ? nil : families
    }
  }

  private func openFontsFolder() {
    let directory = FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/Fonts", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      NSWorkspace.shared.open(directory)
    } catch {
      message = "无法打开字体文件夹：\(error.localizedDescription)"
      refresh()
    }
  }

  private func makeLayoutChoices() -> NSView {
    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 14
    for layout in TabBarLayout.allCases {
      let card = LayoutChoiceButton(layout: layout, selected: preferences.tabBarLayout == layout) { [weak self] in
        guard let self else { return }
        // 选中描边在另外两张卡上，必须重建这一段内容才能取消旧选中。
        self.performLocalControlAction(refreshAfterAction: true) {
          self.preferences.tabBarLayout = layout
        }
      }
      row.addArrangedSubview(card)
    }
    // 顶层项现在一律满宽，横向行必须自带尾部 spacer，否则卡片会被等分拉伸。
    row.addArrangedSubview(NSView())
    return row
  }

  private func makeThemeGrid(mode: TerminalThemeMode) -> NSView {
    let themes = preferences.themes(for: mode)
    let selectedName = mode == .light
      ? preferences.configuration.appearance.themeName
      : preferences.configuration.appearance.darkThemeName
    // 一行四张卡。原始 700pt 窗口的内容区放不下四个固定 130pt 卡片，因此卡片改为
    // 按列等分宽度（`fillEqually`），窗口拉宽时同步变大，不再写死单卡宽度。
    let columns = 4
    let grid = NSStackView()
    grid.orientation = .vertical
    grid.alignment = .width
    grid.spacing = 14
    for start in stride(from: 0, to: themes.count, by: columns) {
      let row = NSStackView()
      row.orientation = .horizontal
      row.distribution = .fillEqually
      row.spacing = 12
      for theme in themes[start..<min(start + columns, themes.count)] {
        row.addArrangedSubview(
          ThemeCardButton(theme: theme, selected: theme.name == selectedName) { [weak self] in
            guard let self else { return }
            // 选中框与详情区都要跟着换，必须刷新；但走本页局部通道，保证 24 张卡片
            // 只重建一次（配置广播本身不再额外触发一次整页重建）。
            self.performLocalControlAction(refreshAfterAction: true) {
              self.focusedThemeID = theme.id
              self.preferences.selectTheme(theme)
            }
          })
      }
      // 末行不足四个时补占位视图，剩余卡片才不会被等分算法拉宽成异形。
      while row.arrangedSubviews.count < columns { row.addArrangedSubview(NSView()) }
      grid.addArrangedSubview(row)
      row.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
    }
    let host = NSView()
    host.wantsLayer = true
    host.layer?.backgroundColor = SettingsTheme.card.cgColor
    host.layer?.cornerRadius = 12
    host.addSubview(grid)
    grid.pinEdges(to: host, insets: NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16))
    return host
  }

  private var allThemes: [TerminalTheme] {
    TerminalThemeCatalog.builtIns + preferences.themeLibrary.customThemes
  }

  /// 详情区展示的主题：必须带上用户覆盖，色板显示的才是真正生效的颜色。
  private var focusedTheme: TerminalTheme {
    guard let base = allThemes.first(where: { $0.id == focusedThemeID }) else {
      return preferences.activeTheme
    }
    return preferences.resolved(base)
  }

  private func duplicateTheme() {
    let copy = preferences.duplicateTheme(focusedTheme)
    focusedThemeID = copy.id
    do {
      _ = try preferences.saveThemeToLibraryFolder(copy)
      message = "已复制并保存主题“\(copy.name)”"
    } catch { message = "主题已复制，但文件保存失败：\(error.localizedDescription)" }
    refresh()
  }

  /// 点击详情色板里的色块：弹出取色器，选色后就地写回该 token 并保存。
  ///
  /// 内置主题不可原位修改，先自动复制一份再改——否则点一下就会破坏内置真值表。
  /// 复制发生在取色**之前**，取色器里的实时预览因此落在副本上。
  private func pickColor(for slot: ThemeColorSlot, anchor: NSView) {
    // 改色写进覆盖表，不再复制整套主题：内置的 24 套是 Otty 只读真值表，复制会让
    // 主题列表被「副本」堆满，而且副本与上游脱钩。覆盖只记用户显式改过的 token。
    let themeID = focusedTheme.id
    themeColorPickTarget = (themeID: themeID, slotID: slot.id, createdCopy: false)
    let picker = InlineColorPickerViewController(
      title: slot.title,
      color: NSColor(slot.resolved)
    ) { [weak self] color in
      self?.writeThemeColor(color)
    }
    picker.onClose = { [weak self] in self?.finishColorPick() }
    isPickingThemeColor = true
    needsRefreshAfterColorPick = false
    themeColorPickAnchor = anchor as? ThemeColorSwatch
    // 贴着被点的色块弹出：用户改的是哪一格必须一眼可见。`.semitransient` 让面板在
    // 拖动色域时不会因为点到别处就消失，点击色板之外才关闭。
    present(
      picker,
      asPopoverRelativeTo: anchor.bounds,
      of: anchor,
      preferredEdge: .maxY,
      behavior: .semitransient
    )
  }

  /// 取色器每次拖动都会回调；写进覆盖表并落盘，用户看到的是实时生效。
  ///
  /// 这里**不能** `refresh()`：整棵设置页会被重建，popover 的锚点视图随之销毁，
  /// 取色器会在用户拖动色域的过程中被关掉。
  private func writeThemeColor(_ color: NSColor) {
    guard let target = themeColorPickTarget else { return }
    let picked = color.usingColorSpace(.sRGB) ?? color
    preferences.setThemeColor(
      HexColor(nsColor: picked), slotID: target.slotID, themeID: target.themeID)
    themeColorPickAnchor?.showPickedColor(picked)
    needsRefreshAfterColorPick = true
  }

  /// 取色器关闭后再把色板重建一次，让斜线底（派生态）与 tooltip 跟上新值，
  /// 同时把覆盖写进主题文件夹里的 `.ottytheme` 追加段。
  private func finishColorPick() {
    guard isPickingThemeColor else { return }
    isPickingThemeColor = false
    let target = themeColorPickTarget
    themeColorPickTarget = nil
    themeColorPickAnchor = nil
    guard needsRefreshAfterColorPick else { return }
    needsRefreshAfterColorPick = false
    if let target {
      do {
        _ = try preferences.writeThemeOverridesToLibraryFolder(themeID: target.themeID)
        message = "已更新主题“\(focusedTheme.name)”的颜色"
      } catch {
        message = "颜色已生效，但主题文件写入失败：\(error.localizedDescription)"
      }
    }
    refresh()
  }

  /// 撤销当前主题的全部颜色覆盖，回到主题自身（含内置真值表）的原始配色。
  private func resetThemeOverrides() {
    let themeID = focusedTheme.id
    preferences.clearThemeOverrides(themeID: themeID)
    do {
      _ = try preferences.writeThemeOverridesToLibraryFolder(themeID: themeID)
      message = "已恢复主题“\(focusedTheme.name)”的原始配色"
    } catch {
      message = "已恢复原始配色，但主题文件写入失败：\(error.localizedDescription)"
    }
    refresh()
  }

  private func beginEditingTheme() {
    let editable = focusedTheme.isBuiltIn ? preferences.duplicateTheme(focusedTheme) : focusedTheme
    focusedThemeID = editable.id
    themeDraft = editable
    refresh()
  }

  private func makeThemeEditor(_ draft: TerminalTheme) -> NSView {
    let name = ClosureTextField(value: draft.name) { [weak self] value in
      self?.themeDraft?.name = value
    }
    let nameRow = rowShell("主题名称", "自定义主题的显示名称", accessory: name)
    let modeRow = popupRow(
      "配色模式",
      "决定主题出现在浅色或深色主题列表",
      items: ["浅色", "深色"],
      selected: draft.mode == .light ? 0 : 1
    ) { [weak self] index in
      self?.themeDraft?.mode = index == 0 ? .light : .dark
    }
    let colors: [(String, WritableKeyPath<TerminalThemePalette, HexColor>)] = [
      ("终端背景", \.windowBackground),
      ("容器背景", \.containerBackground),
      ("面板背景", \.panelBackground),
      ("终端文字", \.foreground),
      ("次要文字", \.secondaryForeground),
      ("强调色", \.accent),
      ("光标", \.cursor),
      ("选区", \.selection),
    ]
    var rows: [NSView] = [nameRow, modeRow]
    let windowColor = draft.palette.interfaceWindowBackground ?? draft.palette.panelBackground
    let windowWell = ClosureColorWell(color: NSColor(windowColor)) { [weak self] color in
      guard var current = self?.themeDraft else { return }
      current.palette.interfaceWindowBackground = HexColor(nsColor: color)
      self?.themeDraft = current
    }
    rows.append(rowShell("界面窗口", "终端网格之外的窗口底色", accessory: windowWell))
    for (title, keyPath) in colors {
      let well = ClosureColorWell(color: NSColor(draft.palette[keyPath: keyPath])) { [weak self] color in
        guard var current = self?.themeDraft else { return }
        current.palette[keyPath: keyPath] = HexColor(nsColor: color)
        self?.themeDraft = current
      }
      rows.append(rowShell(title, "", accessory: well))
    }
    rows.append(rowShell(
      "ANSI 16 色",
      "上排标准色，下排高亮色",
      accessory: makeANSIColorEditor(draft.palette.ansiColors)
    ))
    let buttons = NSStackView(views: [
      contentActionButton(title: "保存") { [weak self] in self?.saveThemeDraft() },
      contentActionButton(title: "取消") { [weak self] in self?.themeDraft = nil; self?.refresh() },
    ])
    buttons.orientation = .horizontal
    buttons.spacing = 8
    rows.append(buttons)
    return card(rows)
  }

  /// ANSI 色表按 0…7 与 8…15 两排显示；每个色块原位写回草稿，保存前仍由领域层校验完整性。
  private func makeANSIColorEditor(_ colors: [HexColor]) -> NSView {
    let gridColors = Array(colors.prefix(16))
    let rows = stride(from: 0, to: gridColors.count, by: 8).map { start in
      gridColors[start..<min(start + 8, gridColors.count)].enumerated().map { offset, color -> NSView in
        let index = start + offset
        return ClosureColorWell(color: NSColor(color), size: NSSize(width: 30, height: 24)) { [weak self] value in
          guard var current = self?.themeDraft,
                current.palette.ansiColors.indices.contains(index) else { return }
          current.palette.ansiColors[index] = HexColor(nsColor: value)
          self?.themeDraft = current
        }
      }
    }
    let grid = NSGridView(views: rows)
    grid.columnSpacing = 5
    grid.rowSpacing = 5
    return grid
  }

  private func saveThemeDraft() {
    guard let draft = themeDraft else { return }
    do {
      try TerminalThemeStore.validate(draft)
      guard preferences.updateTheme(draft) else {
        message = "主题名称与现有主题重复，请换一个名称"
        refresh()
        return
      }
      _ = try preferences.saveThemeToLibraryFolder(draft)
      focusedThemeID = draft.id
      themeDraft = nil
      message = "主题“\(draft.name)”已保存"
    } catch { message = "主题保存失败：\(error.localizedDescription)" }
    refresh()
  }

  private func importTheme() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = false
    panel.canChooseFiles = true
    panel.allowedContentTypes = ["astertheme", "ottytheme"].compactMap {
      UTType(filenameExtension: $0)
    }
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let theme = try preferences.importTheme(from: url)
      focusedThemeID = theme.id
      _ = try preferences.saveThemeToLibraryFolder(theme)
      message = "已导入主题“\(theme.name)”"
    } catch { message = "主题导入失败：\(error.localizedDescription)" }
    refresh()
  }

  private func openThemesFolder() {
    do { NSWorkspace.shared.open(try preferences.themesDirectory()) }
    catch { message = "无法打开主题文件夹：\(error.localizedDescription)"; refresh() }
  }

  // MARK: - Rows and cards

  /// 大圆角设置卡片；行间不画分隔线，靠每行自身的内边距形成留白节奏（Otty 风格）。
  /// 底色取 `SettingsTheme.card`（浅色固定 #FAFAFA），压在白色画布上形成可见的浅灰
  /// 底块；该色**不跟随终端主题**，改主题不会把设置页染色。
  private func card(_ rows: [NSView]) -> NSView {
    let card = NSStackView()
    card.orientation = .vertical
    card.spacing = 0
    card.wantsLayer = true
    card.layer?.backgroundColor = SettingsTheme.card.cgColor
    card.layer?.cornerRadius = SettingsMetrics.cardCornerRadius
    card.identifier = Self.cardIdentifier
    // 显式压低卡片自身的水平压缩阻力。行内长说明文字的固有宽度（单行不换行）
    // 可能超过内容栈可用宽度（系统集成卡片达 650pt），而栈的压缩阻力取子视图
    // 最大值（750），外层内容栈的 .width 对齐压不动它，只能 break 左侧 inset
    // 约束——卡片曾因此贴到内容区左边缘。压低后由行内文字列吸收压缩并换行。
    card.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    for row in rows {
      card.addArrangedSubview(row)
    }
    return card
  }

  /// 所有设置行的统一底座：左侧「标题 + 可换行灰色说明」，右侧 accessory 控件。
  private func rowShell(_ title: String, _ detail: String, accessory: NSView) -> NSView {
    let host = NSView()
    host.translatesAutoresizingMaskIntoConstraints = false
    let detailLabel = makeLabel(detail, size: SettingsMetrics.rowDetailSize, color: SettingsTheme.secondaryInk)
    // 说明文字允许折行撑高整行；水平抗压缩降为最低，长说明被压缩换行而不是
    // 把右侧 accessory（已 required hugging）挤出卡片。
    detailLabel.lineBreakMode = .byWordWrapping
    detailLabel.maximumNumberOfLines = 0
    detailLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let labels = NSStackView(views: [
      makeLabel(title, size: SettingsMetrics.rowTitleSize, weight: .medium, color: SettingsTheme.ink),
      detailLabel,
    ])
    labels.orientation = .vertical
    labels.alignment = .leading
    labels.spacing = 4
    // 关键点：显式压低文字列整体（而非单个 label）的水平压缩阻力。NSStackView 的
    // 压缩阻力取子视图最大值，只降详情 label 时标题的 750 会「代理」整列，而列宽
    // 又由长说明文字的单行固有宽度决定（可达 650pt）——外层内容栈的 .width 对齐
    // 约束压不动它，只能 break 边距约束，系统集成卡片曾因此丢失左侧 inset。
    labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    // 文字列必须比弹簧视图更愿意拉伸（hugging 低于 spacer 的 250）：否则 labels
    // 停在说明文字的单行固有宽度，行宽超出卡片可用宽度后整卡布局变成多解，
    // 系统集成卡片曾因此丢失左侧 inset 或出现顶部幽灵空白。
    labels.setContentHuggingPriority(.init(240), for: .horizontal)
    accessory.setContentHuggingPriority(.required, for: .horizontal)
    let row = NSStackView(views: [labels, NSView(), accessory])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 12
    row.edgeInsets = NSEdgeInsets(
      top: SettingsMetrics.rowVerticalInset,
      left: SettingsMetrics.rowHorizontalInset,
      bottom: SettingsMetrics.rowVerticalInset,
      right: SettingsMetrics.rowHorizontalInset
    )
    host.addSubview(row)
    row.pinEdges(to: host)
    return host
  }

  private func infoRow(_ title: String, _ detail: String, _ value: String) -> NSView {
    rowShell(
      title,
      detail,
      accessory: makeLabel(value, size: SettingsMetrics.rowDetailSize, color: SettingsTheme.secondaryInk)
    )
  }

  private func toggleRow(
    _ title: String,
    _ detail: String,
    value: Bool,
    refreshAfterAction: Bool = false,
    action: @escaping (Bool) -> Void
  ) -> NSView {
    let control = ClosureSwitch(value: value) { [weak self] value in
      guard let self else { return }
      self.performLocalControlAction(refreshAfterAction: refreshAfterAction) {
        action(value)
      }
    }
    return rowShell(title, detail, accessory: control)
  }

  /// 文本行：提交后不重建内容区，否则刚敲完回车就丢失焦点与光标位置。需要联动的
  /// 调用方（例如写主题字体栈）自己在动作里刷新。
  private func textRow(_ title: String, _ detail: String, value: String, action: @escaping (String) -> Void) -> NSView {
    let field = ClosureTextField(value: value) { [weak self] text in
      guard let self else { return }
      self.performLocalControlAction { action(text) }
    }
    field.translatesAutoresizingMaskIntoConstraints = false
    field.widthAnchor.constraint(equalToConstant: 210).isActive = true
    return rowShell(title, detail, accessory: field)
  }

  /// 下拉行。默认选完刷新一次内容区（不少下拉会改变同页其它行的可见性与可用性），
  /// 但走 `performLocalControlAction` 合并成一次，不再由配置广播额外触发整页重建。
  private func popupRow(
    _ title: String,
    _ detail: String,
    items: [String],
    selected: Int,
    refreshAfterAction: Bool = true,
    action: @escaping (Int) -> Void
  ) -> NSView {
    let control = ClosurePopUpButton(items: items, selected: selected) { [weak self] index in
      guard let self else { return }
      self.performLocalControlAction(refreshAfterAction: refreshAfterAction) { action(index) }
    }
    return rowShell(title, detail, accessory: control)
  }

  /// 枚举下拉行：菜单项与选中索引都由 `allCases` 单一来源生成，杜绝文案数组与
  /// case 顺序两处维护导致的索引错位。
  private func enumPopupRow<T: SettingsEnumOption>(_ title: String, _ detail: String, value: T, action: @escaping (T) -> Void) -> NSView {
    let cases = Array(T.allCases)
    return popupRow(
      title, detail,
      items: cases.map(\.settingsLabel),
      selected: cases.firstIndex(of: value) ?? 0
    ) { index in
      action(cases[index])
    }
  }

  /// 语言下拉的取值表：value 写入配置持久化，label 只用于显示。
  private static let languageOptions: [(label: String, value: String)] = [
    ("跟随系统", "system"),
    ("简体中文", "zh-Hans"),
    ("English", "en"),
  ]

  /// 滑杆行；`fractionDigits` 控制数值标签的小数位（行高倍数等非整数设置需要）。
  private func sliderRow(
    _ title: String,
    _ detail: String,
    value: Double,
    range: ClosedRange<Double>,
    suffix: String,
    fractionDigits: Int = 0,
    identifier: String? = nil,
    enabled: Bool = true,
    action: @escaping (Double) -> Void
  ) -> NSView {
    // 数值标签就地更新：滑杆变化不重建内容区，否则每次松手都会把正在操作的滑杆
    // 销毁重建，连续微调时手感会一顿一顿。
    func format(_ value: Double) -> String {
      fractionDigits == 0
        ? "\(Int(value)) \(suffix)"
        : String(format: "%.\(fractionDigits)f \(suffix)", value)
    }
    let valueLabel = makeLabel(
      format(value),
      size: SettingsMetrics.rowDetailSize,
      color: SettingsTheme.secondaryInk
    )
    let slider = ClosureSlider(value: value, range: range) { [weak self, weak valueLabel] next in
      valueLabel?.stringValue = format(next)
      guard let self else { return }
      self.performLocalControlAction { action(next) }
    }
    slider.identifier = identifier.map { NSUserInterfaceItemIdentifier($0) }
    slider.isEnabled = enabled
    slider.translatesAutoresizingMaskIntoConstraints = false
    slider.widthAnchor.constraint(equalToConstant: 180).isActive = true
    let stack = NSStackView(views: [slider, valueLabel])
    stack.orientation = .horizontal
    stack.spacing = 8
    return rowShell(title, detail, accessory: stack)
  }

  /// Panel 宽度属于最近活动工作区，而不是全局主题配置。无工作区可绑定时仍显示默认
  /// 数值以解释合法范围，但禁用控件，避免用户误以为修改已经应用到某个窗口。
  private func panelWidthSliderRow(
    _ title: String,
    role: WorkspacePanelRole,
    fallback: Double
  ) -> NSView {
    guard let range = WorkspacePanelLayoutPolicy.widthRange(for: role) else { return NSView() }
    let value = panelLayoutBinding.state?.preferredWidth(for: role) ?? fallback
    return sliderRow(
      title,
      "控制最近活动的工作区窗口；也可直接拖动主窗口分隔线",
      value: value,
      range: range,
      suffix: "pt",
      identifier: "settings-panel-width-\(role.rawValue)",
      enabled: panelLayoutBinding.isBound
    ) { [weak panelLayoutBinding] value in
      panelLayoutBinding?.setPreferredWidth(value, for: role)
    }
  }

  /// 步进行：控件自己已经就地更新数值标签，因此不再触发内容区重建。
  private func stepperRow(_ title: String, _ detail: String, value: Double, range: ClosedRange<Double>, action: @escaping (Double) -> Void) -> NSView {
    let control = ClosureStepper(value: value, range: range) { [weak self] next in
      guard let self else { return }
      self.performLocalControlAction { action(next) }
    }
    return rowShell(title, detail, accessory: control)
  }

  private func actionRow(_ title: String, _ detail: String, title buttonTitle: String, action: @escaping () -> Void) -> NSView {
    rowShell(title, detail, accessory: contentActionButton(title: buttonTitle, handler: action))
  }

  /// 设置内容区的按钮统一使用较小字号，与左侧 13pt 导航形成清晰层级。
  private func contentActionButton(
    title: String,
    handler: @escaping () -> Void
  ) -> ActionButton {
    let button = ActionButton(title: title, handler: handler)
    button.font = NSFont.systemFont(ofSize: SettingsMetrics.controlTextSize)
    return button
  }

  /// 分组小标题：灰色小号加字距，identifier 供内容栈识别并收紧「标题 → 卡片」间距。
  private func sectionTitle(_ title: String) -> NSView {
    let label = makeLabel(title, size: SettingsMetrics.groupTitleSize, weight: .medium, color: SettingsTheme.tertiaryInk)
    label.attributedStringValue = NSAttributedString(
      string: title,
      attributes: [
        .font: NSFont.systemFont(ofSize: SettingsMetrics.groupTitleSize, weight: .medium),
        .foregroundColor: SettingsTheme.tertiaryInk,
        .kern: 0.8,
      ]
    )
    label.identifier = Self.groupTitleIdentifier
    // 压低 hugging 让标题在内容栈里撑满整行：否则栈的对齐约束会把固有宽度的
    // 标签靠边放置，导致小标题跑到卡片右上角。
    label.setContentHuggingPriority(.init(100), for: .horizontal)
    return label
  }

  /// 标记分组标题视图，`makeContentScroll` 据此调整标题前后的自定义间距。
  private static let groupTitleIdentifier = NSUserInterfaceItemIdentifier("settings.group-title")
  /// 标记分组卡片视图，`makeContentScroll` 据此对卡片施加显式左右边距约束。
  private static let cardIdentifier = NSUserInterfaceItemIdentifier("settings.card")

  private func exportConfiguration() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "Aster Settings.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
      try encoder.encode(preferences.configuration).write(to: url, options: .atomic)
      message = "配置已导出"
    } catch { message = "导出失败：\(error.localizedDescription)" }
    refresh()
  }

  private func importConfiguration() {
    let panel = NSOpenPanel()
    panel.canChooseFiles = true
    panel.canChooseDirectories = false
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let decoded = try JSONDecoder().decode(AsterConfiguration.self, from: Data(contentsOf: url))
      preferences.importConfiguration(decoded)
      message = "配置已导入"
    } catch { message = "导入失败：\(error.localizedDescription)" }
    refresh()
  }
}

// MARK: - Native setting controls

/// 设置侧栏导航行：整宽方角高亮（Otty 风格），图标与文字通过内部子视图留出
/// 左侧间隙——NSButton 自身的 imageLeading 布局无法控制内容内边距。
///
/// 选中态可就地翻转（`setSelected`），切换分类不再重建按钮；悬停有底色与手型光标，
/// 让「这一行可以点」在指针移上去的瞬间就有反馈。
@MainActor
private final class SettingsSidebarButton: NSButton {
  private let handler: () -> Void
  private let icon: NSImageView
  private let sectionLabel: NSTextField
  private var selected: Bool
  private var isHovering = false { didSet { applyAppearance() } }
  private var hoverTrackingArea: NSTrackingArea?

  init(section: SettingsViewController.Section, selected: Bool, action: @escaping () -> Void) {
    handler = action
    self.selected = selected
    icon = NSImageView(
      image: NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.rawValue) ?? NSImage()
    )
    sectionLabel = makeLabel(section.rawValue, size: 13, color: SettingsTheme.secondaryInk)
    super.init(frame: .zero)
    title = ""
    setAccessibilityLabel(section.rawValue)
    isBordered = false
    wantsLayer = true

    icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
    icon.translatesAutoresizingMaskIntoConstraints = false
    icon.widthAnchor.constraint(equalToConstant: 20).isActive = true
    let row = NSStackView(views: [icon, sectionLabel])
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 9
    addSubview(row)
    row.pinEdges(to: self, insets: NSEdgeInsets(top: 0, left: 22, bottom: 0, right: 12))

    target = self
    self.action = #selector(invoke)
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: 32).isActive = true
    applyAppearance()
  }

  required init?(coder: NSCoder) { nil }

  /// 由设置页在切换分类时调用；值没变就什么都不做，避免无谓重绘。
  func setSelected(_ value: Bool) {
    guard value != selected else { return }
    selected = value
    applyAppearance()
  }

  /// 供设置页在明暗外观变化后强制重算底色与图标/文字着色。
  func refreshAppearance() { applyAppearance() }

  /// 底色是 layer 上的 `CGColor`，动态 `NSColor` 按 `NSAppearance.current` 解析，
  /// 因此必须在本视图的外观下取值，否则深色模式会拿到浅色高亮。
  private func applyAppearance() {
    let alpha: CGFloat = selected ? 0.07 : (isHovering ? 0.04 : 0)
    effectiveAppearance.performAsCurrentDrawingAppearance { [self] in
      layer?.backgroundColor = alpha == 0
        ? NSColor.clear.cgColor
        : SettingsTheme.ink.withAlphaComponent(alpha).cgColor
    }
    let tint = selected ? SettingsTheme.ink : SettingsTheme.secondaryInk
    icon.contentTintColor = tint
    sectionLabel.textColor = tint
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) { isHovering = true }
  override func mouseExited(with event: NSEvent) { isHovering = false }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }

  /// 选中/悬停底色写在 layer 上（`CGColor` 不跟随外观），按钮常驻后必须在明暗切换时
  /// 自己重算，否则深色模式下选中行仍是浅色高亮。
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyAppearance()
  }

  @objc private func invoke() { handler() }
}

@MainActor
private final class ClosureSwitch: NSSwitch {
  private let handler: (Bool) -> Void
  init(value: Bool, action: @escaping (Bool) -> Void) {
    handler = action
    super.init(frame: .zero)
    state = value ? .on : .off
    target = self
    self.action = #selector(changed)
  }
  required init?(coder: NSCoder) { nil }
  @objc private func changed() { handler(state == .on) }
}

@MainActor
/// 字体选择器的候选项:title 为显示名,value 为写入配置的字体/家族名,
/// previewFontName 用于把菜单项渲染成该字体自身的样子。
struct FontPickerEntry {
  let title: String
  let value: String
  let previewFontName: String
}

/// 字体组合框:下拉列出已安装字体供选择,也允许直接输入字体名(带自动补全)。
/// 清空文本即「取消设置」(回到自动/继承);输入的名字与列表项匹配时写入对应
/// 配置值,否则原样保存(计算值页展示实际解析结果)。
@MainActor
private final class FontComboBox: NSComboBox, NSComboBoxDelegate, NSComboBoxDataSource {
  private let handler: (String?) -> Void
  private let entries: [FontPickerEntry]

  init(entries: [FontPickerEntry], selection: String?, action: @escaping (String?) -> Void) {
    self.entries = entries
    handler = action
    super.init(frame: .zero)
    font = NSFont.systemFont(ofSize: SettingsMetrics.controlTextSize)
    placeholderString = "字体"
    usesDataSource = true
    dataSource = self
    completes = true
    numberOfVisibleItems = 16
    isEditable = true
    delegate = self
    if let selection {
      // 显示配置值对应的显示名;未安装时原样显示,不静默改写用户配置。
      stringValue = entries.first(where: { $0.value == selection })?.title ?? selection
    }
    target = self
    self.action = #selector(committed)
  }

  required init?(coder: NSCoder) { nil }

  /// 把当前文本解析为配置值:匹配列表项(显示名或配置名)用其配置值,空串为取消设置。
  private func commitCurrentText() {
    let text = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty else {
      handler(nil)
      return
    }
    let matched = entries.first {
      $0.title.caseInsensitiveCompare(text) == .orderedSame
        || $0.value.caseInsensitiveCompare(text) == .orderedSame
    }
    handler(matched?.value ?? text)
  }

  @objc private func committed() { commitCurrentText() }

  func comboBoxSelectionDidChange(_ notification: Notification) {
    guard indexOfSelectedItem >= 0, entries.indices.contains(indexOfSelectedItem) else { return }
    handler(entries[indexOfSelectedItem].value)
  }

  func controlTextDidEndEditing(_ notification: Notification) {
    commitCurrentText()
  }

  // MARK: NSComboBoxDataSource

  func numberOfItems(in comboBox: NSComboBox) -> Int { entries.count }

  func comboBox(_ comboBox: NSComboBox, objectValueForItemAt index: Int) -> Any? {
    entries.indices.contains(index) ? entries[index].title : nil
  }

  /// 输入自动补全:按显示名前缀匹配(不区分大小写)。
  func comboBox(_ comboBox: NSComboBox, completedString string: String) -> String? {
    entries.first {
      $0.title.range(of: string, options: [.caseInsensitive, .anchored]) != nil
    }?.title
  }
}

private final class ClosurePopUpButton: NSPopUpButton {
  private let handler: (Int) -> Void
  init(items: [String], selected: Int, action: @escaping (Int) -> Void) {
    handler = action
    super.init(frame: .zero, pullsDown: false)
    font = NSFont.systemFont(ofSize: SettingsMetrics.controlTextSize)
    addItems(withTitles: items)
    selectItem(at: min(max(selected, 0), max(items.count - 1, 0)))
    target = self
    self.action = #selector(changed)
  }
  required init?(coder: NSCoder) { nil }
  @objc private func changed() { handler(indexOfSelectedItem) }
}

@MainActor
private final class ClosureSegmentedControl: NSSegmentedControl {
  private let handler: (Int) -> Void

  init(labels: [String], selected: Int, action: @escaping (Int) -> Void) {
    handler = action
    // `init(labels:trackingMode:target:action:)` 由 AppKit 以 Objective-C 工厂方法实现；
    // 从 Swift 子类调用时会把工厂 selector 错发给已经分配的子类实例并在运行时崩溃。
    // 使用指定初始化器逐项配置，既保留相同行为，也保证子类初始化路径有效。
    super.init(frame: .zero)
    font = NSFont.systemFont(ofSize: SettingsMetrics.controlTextSize)
    segmentCount = labels.count
    trackingMode = .selectOne
    for (index, label) in labels.enumerated() {
      setLabel(label, forSegment: index)
    }
    selectedSegment = min(max(selected, 0), max(labels.count - 1, 0))
    target = self
    self.action = #selector(changed)
  }

  required init?(coder: NSCoder) { nil }

  @objc private func changed() {
    handler(selectedSegment)
  }
}

@MainActor
private final class ClosureSlider: NSSlider {
  private let handler: (Double) -> Void
  init(value: Double, range: ClosedRange<Double>, action: @escaping (Double) -> Void) {
    handler = action
    // Swift 6.2 release 优化器会把 NSSlider 的 Objective-C 便捷初始化器与子类闭包
    // 属性组合误判为 owned value 泄漏。使用指定 frame 初始化器后逐项赋值，运行语义
    // 相同，同时避开编译器 ownership 崩溃。
    super.init(frame: .zero)
    minValue = range.lowerBound
    maxValue = range.upperBound
    doubleValue = value
    target = self
    self.action = #selector(changed)
    isContinuous = false
  }
  required init?(coder: NSCoder) { nil }
  @objc private func changed() { handler(doubleValue) }
}

@MainActor
private final class ClosureTextField: NSTextField, NSTextFieldDelegate {
  private let handler: (String) -> Void
  init(value: String, action: @escaping (String) -> Void) {
    handler = action
    super.init(frame: .zero)
    stringValue = value
    font = NSFont.systemFont(ofSize: SettingsMetrics.controlTextSize)
    delegate = self
  }
  required init?(coder: NSCoder) { nil }
  func controlTextDidEndEditing(_ obj: Notification) { handler(stringValue) }
}

@MainActor
private final class ClosureStepper: NSView {
  private let label = NSTextField(labelWithString: "")
  private var value: Double
  private let handler: (Double) -> Void

  init(value: Double, range: ClosedRange<Double>, action: @escaping (Double) -> Void) {
    self.value = value
    handler = action
    super.init(frame: .zero)
    let stepper = NSStepper()
    stepper.minValue = range.lowerBound
    stepper.maxValue = range.upperBound
    stepper.doubleValue = value
    stepper.target = self
    stepper.action = #selector(changed(_:))
    label.stringValue = "\(Int(value))"
    label.font = NSFont.systemFont(ofSize: SettingsMetrics.rowTitleSize)
    let stack = NSStackView(views: [label, stepper])
    stack.orientation = .horizontal
    stack.spacing = 8
    addSubview(stack)
    stack.pinEdges(to: self)
  }
  required init?(coder: NSCoder) { nil }
  @objc private func changed(_ sender: NSStepper) {
    value = sender.doubleValue
    label.stringValue = "\(Int(value))"
    handler(value)
  }
}

@MainActor
private final class ClosureColorWell: NSColorWell {
  private let handler: (NSColor) -> Void
  init(color: NSColor, size: NSSize = NSSize(width: 52, height: 28), action: @escaping (NSColor) -> Void) {
    handler = action
    super.init(frame: NSRect(origin: .zero, size: size))
    self.color = color
    target = self
    self.action = #selector(changed)
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: size.width),
      heightAnchor.constraint(equalToConstant: size.height),
    ])
  }
  required init?(coder: NSCoder) { nil }
  @objc private func changed() { handler(color) }
}

@MainActor
private final class LayoutChoiceButton: NSButton {
  private let handler: () -> Void
  init(layout: TabBarLayout, selected: Bool, action: @escaping () -> Void) {
    handler = action
    super.init(frame: .zero)
    let data: (String, String) = switch layout {
    case .vertical: ("sidebar.left", "垂直标签栏")
    case .top: ("rectangle.topthird.inset.filled", "顶部标签栏")
    case .bottom: ("rectangle.bottomthird.inset.filled", "底部标签栏")
    }
    title = ""
    isBordered = false
    wantsLayer = true
    layer?.backgroundColor = SettingsTheme.card.cgColor
    layer?.cornerRadius = 12
    layer?.borderWidth = selected ? 2 : 1
    // 选中框走主题强调色而不是系统 accent，遵守「主题色只经由 ThemeRuntime」规则。
    layer?.borderColor = (selected ? SettingsTheme.accent : SettingsTheme.hairline).cgColor
    let image = NSImageView(
      image: NSImage(systemSymbolName: data.0, accessibilityDescription: data.1) ?? NSImage()
    )
    image.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 25, weight: .regular)
    image.contentTintColor = SettingsTheme.secondaryInk
    let label = makeLabel(
      data.1,
      size: SettingsMetrics.controlTextSize,
      color: SettingsTheme.secondaryInk
    )
    label.alignment = .center
    let stack = NSStackView(views: [image, label])
    stack.orientation = .vertical
    stack.spacing = 12
    stack.alignment = .centerX
    addSubview(stack)
    stack.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      stack.centerXAnchor.constraint(equalTo: centerXAnchor),
      stack.centerYAnchor.constraint(equalTo: centerYAnchor),
    ])
    target = self
    self.action = #selector(invoke)
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 132),
      heightAnchor.constraint(equalToConstant: 100),
    ])
  }
  required init?(coder: NSCoder) { nil }
  @objc private func invoke() { handler() }
}

@MainActor
private final class ThemeCardButton: NSButton {
  private let handler: () -> Void
  private let selected: Bool
  private var hoverTrackingArea: NSTrackingArea?
  private var isHovering = false { didSet { applyBackground() } }

  init(theme: TerminalTheme, selected: Bool, action: @escaping () -> Void) {
    handler = action
    self.selected = selected
    super.init(frame: .zero)
    title = ""
    setAccessibilityLabel(theme.name)
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 12
    layer?.cornerCurve = .continuous
    layer?.borderWidth = selected ? 2 : 0
    // 同上：主题卡选中描边使用主题强调色。
    layer?.borderColor = SettingsTheme.accent.cgColor
    let preview = ThemeMiniPreviewView(theme: theme)
    let label = makeLabel(
      theme.name,
      size: SettingsMetrics.controlTextSize,
      color: SettingsTheme.secondaryInk
    )
    label.alignment = .center
    // 一行四列后单卡只有 95pt 左右，「Solarized Light」这类长名必须换行显示；
    // 同时压低横向抗压优先级，名称不会反过来把等分的列撑宽。
    label.lineBreakMode = .byWordWrapping
    label.maximumNumberOfLines = 2
    label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    let stack = NSStackView(views: [preview, label])
    stack.orientation = .vertical
    stack.spacing = 8
    stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
    addSubview(stack)
    stack.pinEdges(to: self)
    preview.translatesAutoresizingMaskIntoConstraints = false
    preview.heightAnchor.constraint(equalToConstant: 62).isActive = true
    target = self
    self.action = #selector(invoke)
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      // 卡宽由所在列等分决定，这里只兜住极窄窗口下的最小可读宽度。
      widthAnchor.constraint(greaterThanOrEqualToConstant: 84),
      heightAnchor.constraint(equalToConstant: 118),
    ])
    applyBackground()
  }
  required init?(coder: NSCoder) { nil }

  /// 卡片自身的灰底：预览缩略图多为浅色，没有底色时卡片与网格容器糊成一片，
  /// 看不出「一张张卡」的边界。悬停时加深一档，给出可点反馈。
  private func applyBackground() {
    let alpha: CGFloat = selected ? 0.09 : (isHovering ? 0.08 : 0.05)
    layer?.backgroundColor = SettingsTheme.ink.withAlphaComponent(alpha).cgColor
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  override func mouseEntered(with event: NSEvent) { isHovering = true }
  override func mouseExited(with event: NSEvent) { isHovering = false }

  override func resetCursorRects() {
    addCursorRect(bounds, cursor: .pointingHand)
  }

  @objc private func invoke() { handler() }
}

/// 主题卡片直接按 Otty 的 sidebar/tab/container token 绘制，不使用统一模板近似。
@MainActor
private final class ThemeMiniPreviewView: NSView {
  private let theme: TerminalTheme
  init(theme: TerminalTheme) { self.theme = theme; super.init(frame: .zero); wantsLayer = true }
  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let bounds = bounds.insetBy(dx: 0.5, dy: 0.5)
    let clip = NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8)
    clip.addClip()
    NSColor(theme.palette.interfaceWindowBackground ?? theme.palette.panelBackground).setFill()
    bounds.fill()

    let sidebarRect = NSRect(x: bounds.minX, y: bounds.minY, width: 29, height: bounds.height)
    NSColor(theme.style.sidebarBackground ?? theme.palette.panelBackground).setFill()
    sidebarRect.fill()
    let tabColor = NSColor(theme.style.tab.foreground ?? theme.palette.secondaryForeground)
    let active = NSColor(theme.style.tab.activeBackground ?? theme.palette.panelSurface ?? theme.palette.panelBackground)
    for index in 0..<3 {
      let y = bounds.maxY - 15 - CGFloat(index * 10)
      if index == 1 {
        active.setFill()
        NSBezierPath(roundedRect: NSRect(x: 5, y: y - 3, width: 19, height: 9), xRadius: theme.style.tab.radius * 0.35, yRadius: theme.style.tab.radius * 0.35).fill()
      }
      tabColor.withAlphaComponent(index == 1 ? 0.82 : 0.48).setFill()
      NSBezierPath(roundedRect: NSRect(x: 7, y: y, width: index == 1 ? 13 : 10, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
    }

    let margin = theme.style.container.margin
    let containerRect = NSRect(
      x: 29 + margin.leading * 0.25,
      y: margin.bottom * 0.25,
      width: bounds.width - 29 - (margin.leading + margin.trailing) * 0.25,
      height: bounds.height - (margin.top + margin.bottom) * 0.25
    )
    NSColor(theme.style.container.background ?? theme.palette.renderedTerminalBackground).setFill()
    NSBezierPath(
      roundedRect: containerRect,
      xRadius: min(theme.style.container.radius * 0.45, 8),
      yRadius: min(theme.style.container.radius * 0.45, 8)
    ).fill()
    NSColor(theme.palette.accent).setFill()
    NSBezierPath(ovalIn: NSRect(x: containerRect.minX + 9, y: containerRect.midY - 3, width: 6, height: 6)).fill()
    let foreground = NSColor(theme.palette.foreground)
    let secondary = NSColor(theme.palette.secondaryForeground)
    drawLine(x: containerRect.minX + 22, y: containerRect.midY + 1, width: 30, color: foreground.withAlphaComponent(0.78))
    drawLine(x: containerRect.minX + 22, y: containerRect.midY - 5, width: 48, color: secondary.withAlphaComponent(0.58))
    drawLine(x: containerRect.minX + 22, y: containerRect.midY - 11, width: 34, color: secondary.withAlphaComponent(0.35))
  }

  private func drawLine(x: CGFloat, y: CGFloat, width: CGFloat, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: width, height: 3), xRadius: 1.5, yRadius: 1.5).fill()
  }
}

/// 主题详情色板。
///
/// 顶部是「终端前景 / 背景两个大块 + ANSI 上下两排圆点」，下面按 `ThemeColorGroup`
/// 排成一行行胶囊，每个胶囊是「组名 + 该组的 token 色块」。色块 hover 显示
/// `前景色 · terminal.foreground = "#2a2b33"`，点击直接改色。
///
/// 未显式声明的 token（`slot.isDerived`）画成斜线底：它此刻的颜色是从 window 派生
/// 出来的，改 window 会连带变；用户必须能一眼看出哪些格子属于这种情况。
@MainActor
private final class ThemeDetailView: NSView {
  init(theme: TerminalTheme, onPick: @escaping (ThemeColorSlot, NSView) -> Void) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.backgroundColor = SettingsTheme.card.cgColor
    layer?.cornerRadius = 12

    let slots = theme.colorSlots
    let grouped = Dictionary(grouping: slots, by: \.group)

    let title = makeLabel(
      theme.name,
      size: SettingsMetrics.rowTitleSize,
      weight: .semibold,
      color: SettingsTheme.ink
    )
    let mode = makeLabel(
      theme.mode == .dark ? "深色" : "浅色", size: 10, color: SettingsTheme.secondaryInk)
    let header = NSStackView(views: [title, NSView(), mode])
    header.orientation = .horizontal
    let sample = TerminalSampleView(theme: theme)
    sample.translatesAutoresizingMaskIntoConstraints = false
    sample.heightAnchor.constraint(equalToConstant: 132).isActive = true

    // 顶部：终端前景/背景两个大块（左）+ ANSI 两排（右）。
    let terminalColumn = NSStackView(
      views: (grouped[.terminal] ?? []).map { slot in
        ThemeColorSwatch(slot: slot, size: NSSize(width: 78, height: 44), onPick: onPick)
      })
    terminalColumn.orientation = .vertical
    terminalColumn.alignment = .leading
    terminalColumn.spacing = 8
    let ansi = ANSIColorStrip(colors: theme.palette.ansiColors)
    let top = NSStackView(views: [terminalColumn, NSView(), ansi])
    top.orientation = .horizontal
    top.alignment = .top
    top.spacing = 16

    var rows: [NSView] = [header, sample, top]
    // 组胶囊按固定顺序两三个一行地流式排布，与 Otty 的详情面板节奏一致。
    let groupOrder: [[ThemeColorGroup]] = [
      [.window, .container, .panel],
      [.sidebar, .titlebar, .tabbar],
      [.tab],
      [.accents, .cursor, .selection],
    ]
    for line in groupOrder {
      let capsules = line.compactMap { group -> NSView? in
        guard let groupSlots = grouped[group], !groupSlots.isEmpty else { return nil }
        return ThemeColorGroupCapsule(group: group, slots: groupSlots, onPick: onPick)
      }
      guard !capsules.isEmpty else { continue }
      let row = NSStackView(views: capsules + [NSView()])
      row.orientation = .horizontal
      row.alignment = .centerY
      row.spacing = 10
      rows.append(row)
    }

    let stack = NSStackView(views: rows)
    stack.orientation = .vertical
    // 每一行内部都自带尾部 spacer，因此这里用满宽对齐；改成 .leading 会让 header
    // 与终端样例缩成固有宽度。
    stack.alignment = .width
    stack.spacing = 10
    stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
    addSubview(stack)
    stack.pinEdges(to: self)
  }
  required init?(coder: NSCoder) { nil }
}

/// 一组 token 的胶囊：左侧是组名，右侧顺序排开该组的色块。
@MainActor
private final class ThemeColorGroupCapsule: NSView {
  init(group: ThemeColorGroup, slots: [ThemeColorSlot], onPick: @escaping (ThemeColorSlot, NSView) -> Void) {
    super.init(frame: .zero)
    wantsLayer = true
    layer?.cornerRadius = 15
    layer?.cornerCurve = .continuous
    layer?.borderWidth = 1
    layer?.borderColor = SettingsTheme.hairline.cgColor
    let title = makeLabel(group.title, size: 10, weight: .medium, color: SettingsTheme.ink)
    let swatches = slots.map { ThemeColorSwatch(slot: $0, onPick: onPick) }
    let row = NSStackView(views: [title] + swatches)
    row.orientation = .horizontal
    row.alignment = .centerY
    row.spacing = 8
    row.edgeInsets = NSEdgeInsets(top: 6, left: 14, bottom: 6, right: 12)
    addSubview(row)
    row.pinEdges(to: self)
  }

  required init?(coder: NSCoder) { nil }
}

/// 单个 token 色块。可点（打开取色器）、可悬停（显示 token 与色值）。
@MainActor
private final class ThemeColorSwatch: NSControl {
  private let slot: ThemeColorSlot
  private let onPick: (ThemeColorSlot, NSView) -> Void
  private var hoverTrackingArea: NSTrackingArea?
  private var isHovering = false { didSet { needsDisplay = true } }
  /// 取色器正在改的颜色。非空时覆盖 slot 自带的值与派生态。
  private var pickedColor: NSColor?

  init(
    slot: ThemeColorSlot,
    size: NSSize = NSSize(width: 20, height: 20),
    onPick: @escaping (ThemeColorSlot, NSView) -> Void
  ) {
    self.slot = slot
    self.onPick = onPick
    super.init(frame: .zero)
    wantsLayer = true
    toolTip = slot.tooltip
    identifier = NSUserInterfaceItemIdentifier("theme-slot-\(slot.id)")
    setAccessibilityLabel(slot.tooltip)
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: size.width),
      heightAnchor.constraint(equalToConstant: size.height),
    ])
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
    let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
    let resolved = pickedColor ?? NSColor(slot.resolved)
    // 取色器写过之后这个 token 就是显式值了，不该再画成派生态的斜线底。
    let isDerived = pickedColor == nil && slot.isDerived
    switch slot.kind {
    case .fill:
      if isDerived {
        // 派生值：先铺一层淡底再画斜线，和显式实心块区分开。
        path.addClip()
        resolved.withAlphaComponent(0.35).setFill()
        rect.fill()
        drawDiagonalHatch(in: rect)
      } else {
        resolved.setFill()
        path.fill()
      }
    case .border:
      // border token 画成空心：它本来就只描一圈边，实心块会误导。
      resolved.setStroke()
      path.lineWidth = isDerived ? 1 : 2
      if isDerived {
        path.setLineDash([2.5, 2.5], count: 2, phase: 0)
      }
      path.stroke()
    }
    // 悬停描边：无论哪种画法都要有可点反馈。
    if isHovering {
      let ring = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
      SettingsTheme.accent.setStroke()
      ring.lineWidth = 2
      ring.stroke()
    } else if slot.kind == .fill, !isDerived {
      let hairline = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
      SettingsTheme.hairline.setStroke()
      hairline.lineWidth = 1
      hairline.stroke()
    }
  }

  /// 45° 斜线底纹，表示「主题没写这个 token」。
  private func drawDiagonalHatch(in rect: NSRect) {
    let hatch = NSBezierPath()
    hatch.lineWidth = 1
    var x = rect.minX - rect.height
    while x < rect.maxX {
      hatch.move(to: NSPoint(x: x, y: rect.minY))
      hatch.line(to: NSPoint(x: x + rect.height, y: rect.maxY))
      x += 4
    }
    SettingsTheme.tertiaryInk.withAlphaComponent(0.55).setStroke()
    hatch.stroke()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
    let area = NSTrackingArea(
      rect: .zero,
      options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
      owner: self
    )
    addTrackingArea(area)
    hoverTrackingArea = area
  }

  /// 取色器改色时就地更新这一格。整页重建在取色期间被挂起，没有这个方法色板会
  /// 一直停在旧色，用户以为「没设置上」。赋值后按显式值画（不再是斜线底），因为
  /// 这个 token 已经被显式写入主题了。
  func showPickedColor(_ color: NSColor) {
    pickedColor = color
    needsDisplay = true
  }

  override func mouseEntered(with event: NSEvent) { isHovering = true }
  override func mouseExited(with event: NSEvent) { isHovering = false }
  override func mouseDown(with event: NSEvent) { onPick(slot, self) }
  override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

/// 详情区展示完整 ANSI 色表，便于与 Otty 主题文件逐色核对；上排标准色、下排高亮色。
@MainActor
private final class ANSIColorStrip: NSView {
  init(colors: [HexColor]) {
    super.init(frame: .zero)
    let cells = colors.prefix(16).enumerated().map { index, color -> NSView in
      let cell = NSView()
      cell.wantsLayer = true
      cell.layer?.backgroundColor = NSColor(color).cgColor
      cell.layer?.cornerRadius = 13
      cell.layer?.borderWidth = 0.5
      cell.layer?.borderColor = SettingsTheme.hairline.cgColor
      cell.toolTip = "ANSI \(index) = \"\(color.displayString)\""
      cell.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        cell.widthAnchor.constraint(equalToConstant: 26),
        cell.heightAnchor.constraint(equalToConstant: 26),
      ])
      return cell
    }
    let rows = stride(from: 0, to: cells.count, by: 8).map { start -> NSView in
      let row = NSStackView(views: Array(cells[start..<min(start + 8, cells.count)]))
      row.orientation = .horizontal
      row.spacing = 8
      row.alignment = .centerY
      return row
    }
    let column = NSStackView(views: rows)
    column.orientation = .vertical
    column.spacing = 8
    column.alignment = .trailing
    addSubview(column)
    column.pinEdges(to: self)
  }

  required init?(coder: NSCoder) { nil }
}

@MainActor
private final class TerminalSampleView: NSView {
  private let theme: TerminalTheme
  init(theme: TerminalTheme) { self.theme = theme; super.init(frame: .zero); wantsLayer = true }
  required init?(coder: NSCoder) { nil }
  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    NSColor(theme.palette.renderedTerminalBackground).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
    let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    let lines = [
      "otty@macbook:~  $ eza -la --icons --git",
      "Permissions   Size  User   Date Modified   Name",
      "drwxr-xr-x    12k  otty   22 Aug 13:42   build.sh",
      "-rw-r--r--   4.2k  otty   18 Jul 14:22   main.rs",
    ]
    for (index, line) in lines.enumerated() {
      line.draw(
        at: NSPoint(x: 13, y: bounds.maxY - 26 - CGFloat(index * 25)),
        withAttributes: [.font: font, .foregroundColor: NSColor(theme.palette.foreground)]
      )
    }
  }
}

@MainActor
private final class ThemeCursorPreviewView: NSView {
  private let theme: TerminalTheme
  private let appearanceConfiguration: AppearanceConfiguration

  init(theme: TerminalTheme, appearance: AppearanceConfiguration) {
    self.theme = theme
    appearanceConfiguration = appearance
    super.init(frame: .zero)
    wantsLayer = true
    translatesAutoresizingMaskIntoConstraints = false
    heightAnchor.constraint(equalToConstant: 82).isActive = true
  }

  required init?(coder: NSCoder) { nil }

  override func draw(_ dirtyRect: NSRect) {
    super.draw(dirtyRect)
    NSColor(theme.palette.renderedTerminalBackground).setFill()
    NSBezierPath(roundedRect: bounds, xRadius: 9, yRadius: 9).fill()

    let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
    let segments: [(String, NSColor)] = [
      ("abner", NSColor(theme.palette.ansiColors[2])),
      ("@", NSColor(theme.palette.foreground)),
      ("macbook", NSColor(theme.palette.ansiColors[4])),
      ("$ ", NSColor(theme.palette.ansiColors[5])),
      ("git commit -am ", NSColor(theme.palette.ansiColors[2])),
      ("\"", NSColor(theme.palette.ansiColors[3])),
    ]
    let origin = NSPoint(x: 18, y: bounds.midY - 8)
    var x = origin.x
    for (text, color) in segments {
      let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
      text.draw(at: NSPoint(x: x, y: origin.y), withAttributes: attributes)
      x += text.size(withAttributes: attributes).width
    }

    let source = appearanceConfiguration.cursorColorOverride ?? theme.palette.cursor
    let cursor = NSColor(source).withAlphaComponent(
      CGFloat(appearanceConfiguration.resolvedCursorOpacity)
    )
    let rect = NSRect(x: x + 1, y: origin.y - 1, width: 8, height: 18)
    cursor.set()
    switch appearanceConfiguration.cursorStyle {
    case .block:
      rect.fill()
    case .hollowBlock:
      let path = NSBezierPath(rect: rect.insetBy(dx: 0.75, dy: 0.75))
      path.lineWidth = 1.5
      path.stroke()
    case .bar:
      NSRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height).fill()
    case .underline:
      NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2).fill()
    }
  }
}

private extension String {
  var nilIfBlank: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

/// UI 层为 AsterCore 配置枚举补充的下拉文案协议；领域层不感知任何显示字符串。
private protocol SettingsEnumOption: CaseIterable, Equatable {
  var settingsLabel: String { get }
}

extension CloseConfirmation: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .always: "总是询问"
    case .runningProcess: "有运行中的进程时"
    case .multipleTabs: "有多个标签页时"
    case .never: "从不"
    }
  }
}

extension LaunchBehavior: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .newWindow: "打开新窗口"
    case .restoreLastSession: "恢复上次会话"
    }
  }
}

extension NewTabPosition: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .automatic: "自动"
    case .end: "始终位于末尾"
    case .afterCurrent: "始终紧跟当前标签"
    }
  }
}

extension RecipeReplayMode: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .automatic: "自动执行"
    case .confirmOnce: "执行前确认一次"
    case .oneByOne: "逐条确认"
    case .skip: "跳过命令"
    }
  }
}

extension CursorStyle: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .block: "方块"
    case .bar: "竖线"
    case .underline: "下划线"
    case .hollowBlock: "空心方块"
    }
  }
}

extension TerminalCursorBlinkMode: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .defaultOff: "默认关闭"
    case .defaultOn: "默认开启"
    case .alwaysOff: "始终关闭"
    case .alwaysOn: "始终开启"
    }
  }
}

extension TerminalCursorAnimation: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .off: "关闭"
    case .smooth: "平滑"
    }
  }
}

extension ClipboardAccess: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .allow: "允许"
    case .ask: "每次询问"
    case .deny: "拒绝"
    }
  }
}

extension TerminalScrollPastLastLine: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .disabled: "关闭"
    case .lastLineWithContent: "最后一行内容位于顶部"
    case .lastLineInMiddle: "最后一行内容位于中部"
    case .cursorLine: "光标行位于顶部"
    }
  }
}

extension TerminalScrollPastFirstLine: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .disabled: "关闭"
    case .sameAsLastLine: "跟随末尾设置"
    case .firstLineWithContent: "第一行内容位于底部"
    case .firstLineInMiddle: "第一行内容位于中部"
    }
  }
}

extension AutocompleteShortcut: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .tab: "Tab"
    case .tabAndRightArrow: "Tab 或 →"
    case .controlSpace: "Control-Space"
    case .disabled: "关闭"
    }
  }
}

extension AutocompleteCandidatePanel: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .disabled: "关闭"
    case .automatic: "自动（至少 2 项）"
    case .escape: "Escape"
    case .optionEscape: "Option-Escape / F5"
    }
  }
}

extension AutocompleteDescriptionLanguage: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .system: "跟随系统"
    case .english: "English"
    case .chinese: "简体中文"
    }
  }
}

extension TerminalLigatureLevel: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .none: "关闭"
    case .standard: "标准与上下文"
    case .discretionary: "Discretionary"
    }
  }
}

extension TerminalBlinkRenderingPolicy: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .steady: "稳定显示"
    case .animated: "按 SGR 闪烁"
    }
  }
}

extension TerminalTextStyleRendering: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .automatic: "自动"
    case .disabled: "忽略样式"
    case .primaryFontOnly: "仅主字体"
    case .synthetic: "Synthetic"
    }
  }
}

private extension EastAsianAmbiguousBlock {
  var settingsLabel: String {
    switch self {
    case .enclosedAlphanumerics: "Enclosed Alphanumerics"
    case .numberForms: "Number Forms"
    case .mathematicalOperators: "Mathematical Operators"
    case .miscellaneousTechnical: "Miscellaneous Technical"
    case .miscellaneousSymbols: "Miscellaneous Symbols"
    case .dingbats: "Dingbats"
    case .arrows: "Arrows"
    case .geometricShapes: "Geometric Shapes"
    default: rawValue
    }
  }

  var settingsDetail: String {
    switch self {
    case .enclosedAlphanumerics: "①、Ⓐ、ⓐ 等；默认按双宽显示"
    case .numberForms: "分数与罗马数字等 Number Forms 字符"
    case .mathematicalOperators: "数学运算符；仅在字体按双宽绘制时开启"
    case .miscellaneousTechnical: "⌘、⌥ 等技术符号；仅在字体按双宽绘制时开启"
    case .miscellaneousSymbols: "气象、星象等杂项符号"
    case .dingbats: "装饰符号与标记字符"
    case .arrows: "Unicode 箭头字符"
    case .geometricShapes: "几何图形字符"
    default: "未知 block 不会参与终端宽度计算"
    }
  }
}

extension NotificationForegroundPolicy: SettingsEnumOption {
  fileprivate var settingsLabel: String {
    switch self {
    case .off: "关闭"
    case .always: "始终显示"
    case .tabUnfocused: "仅来源标签未聚焦时"
    }
  }
}
