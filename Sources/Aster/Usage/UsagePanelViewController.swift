// AI 用量浮动窗的内容层：表头 / 三页内容 / 底栏的组装，页面懒构建与生命周期切换。
import AppKit
import AsterCore
import Foundation

/// 浮动窗的三页容器。
///
/// 页面一律懒构建：没切到过的页不碰它的 `view`，也就不会有任何视图和订阅存在。
/// 任一时刻只有一页处于 `activate()`，切页、收起窗口、关功能都走同一条挂起路径。
@MainActor
final class UsagePanelViewController: NSViewController {
  /// 页面身份。`rawValue` 同时用于持久化与视图 identifier。
  enum Section: String, CaseIterable {
    case quota
    case tokens
    case sessions
  }

  /// 选中页的持久化键。
  static let selectionDefaultsKey = "aster.usage.panel-section.v1"
  /// 「已用 / 剩余」口径的持久化键。
  static let displayModeDefaultsKey = "aster.usage.display-mode.v1"
  /// 表头「X 前更新」的自续刷新周期。够细到让文字不至于明显过期，又不会成为常驻负担。
  private static let headerTickInterval: Duration = .seconds(30)

  private let sections: [Section: UsageSectionController]
  private let defaults: UserDefaults
  /// 表头的「X 前更新」与刷新按钮要用它；测试注入的容器允许没有。
  private let quotaStore: UsageQuotaStore?
  private let container = NSView()
  private var header: UsagePanelHeaderView?
  private var footer: UsagePanelFooterView?
  private var isVisible = false
  /// 已经建过视图的页。口径广播只发给它们，免得为了同步一个展示参数就把懒构建的页唤醒。
  private var builtSections: Set<Section> = []
  private var headerTickTask: Task<Void, Never>?

  private(set) var selection: Section
  private(set) var displayMode: UsageDisplayMode

  convenience init(
    quotaStore: UsageQuotaStore,
    sessions: UsageSessionBoardDataSource,
    tokenService: TokenStatsService,
    defaults: UserDefaults
  ) {
    self.init(
      sections: [
        .quota: UsageQuotaSectionController(store: quotaStore),
        .tokens: UsageTokenSectionController(service: tokenService, defaults: defaults),
        .sessions: UsageSessionBoardSectionController(dataSource: sessions),
      ],
      defaults: defaults,
      quotaStore: quotaStore)
  }

  /// 测试注入点：三页换成假实现即可观测 activate / suspend / apply(displayMode:)。
  init(
    sections: [Section: UsageSectionController],
    defaults: UserDefaults,
    quotaStore: UsageQuotaStore? = nil
  ) {
    self.sections = sections
    self.defaults = defaults
    self.quotaStore = quotaStore
    let storedSection = defaults.string(forKey: Self.selectionDefaultsKey) ?? ""
    selection = Section(rawValue: storedSection) ?? .quota
    let storedMode = defaults.string(forKey: Self.displayModeDefaultsKey) ?? ""
    displayMode = UsageDisplayMode(rawValue: storedMode) ?? .used
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  /// 供测试读取某一页的控制器。
  func sectionController(_ section: Section) -> UsageSectionController? { sections[section] }

  /// 诊断 / 测试 seam：表头的自续刷新是否已排上。面板不可见时必须为 false。
  var hasScheduledHeaderTick: Bool { headerTickTask != nil }

  /// 供测试读取表头当前显示的数据时刻文字。
  var headerStatusText: String { header?.statusText ?? "" }

  override func loadView() {
    let root = UsagePanelRootView()
    root.identifier = NSUserInterfaceItemIdentifier("usage-panel-content")

    let header = UsagePanelHeaderView(
      selection: selection,
      onSelectSection: { [weak self] section in self?.select(section) },
      onRefresh: { [weak self] in self?.refreshCurrentSection() })
    let footer = UsagePanelFooterView(displayMode: displayMode) { [weak self] mode in
      self?.select(displayMode: mode)
    }
    self.header = header
    self.footer = footer

    for child in [header, container, footer] as [NSView] {
      child.translatesAutoresizingMaskIntoConstraints = false
      root.addSubview(child)
    }
    NSLayoutConstraint.activate([
      header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      header.topAnchor.constraint(equalTo: root.topAnchor),
      container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      container.topAnchor.constraint(equalTo: header.bottomAnchor),
      footer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      footer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      footer.topAnchor.constraint(equalTo: container.bottomAnchor),
      footer.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    view = root
    header.apply(fetchedAt: latestFetchedAt(), now: Date())
  }

  // MARK: - 生命周期

  /// 浮动窗显隐。隐藏时当前页必须挂起、表头 tick 必须取消，否则隐藏的窗口还在干活。
  func setVisible(_ visible: Bool) {
    guard visible != isVisible else { return }
    isVisible = visible
    if visible {
      loadViewIfNeeded()
      installContent()
      sections[selection]?.activate()
      refreshHeaderStamp()
      scheduleHeaderTick()
    } else {
      cancelHeaderTick()
      sections[selection]?.suspend()
    }
  }

  /// 切页。页签点击与代码切换走同一条路径。
  func select(_ section: Section) {
    guard section != selection else { return }
    if isVisible { sections[selection]?.suspend() }
    selection = section
    defaults.set(section.rawValue, forKey: Self.selectionDefaultsKey)
    header?.select(section)
    guard isVisible else { return }
    installContent()
    sections[selection]?.activate()
  }

  /// 切换「已用 / 剩余」口径。只影响展示，不触发任何取数。
  func select(displayMode mode: UsageDisplayMode) {
    guard mode != displayMode else { return }
    displayMode = mode
    defaults.set(mode.rawValue, forKey: Self.displayModeDefaultsKey)
    footer?.select(mode)
    for section in builtSections { sections[section]?.apply(displayMode: mode) }
  }

  /// 表头刷新按钮：当前页重新取一次，同时把本机各配额来源也催一遍（受 store 自己的节流保护）。
  func refreshCurrentSection() {
    sections[selection]?.refreshRequested()
    quotaStore?.refreshLocalSources()
    refreshHeaderStamp()
  }

  // MARK: - 内容装载

  /// 把当前页的视图挂进容器；首次访问 `.view` 才真正构建这一页。
  ///
  /// 懒构建的页拿不到之前广播过的口径，所以这里在它第一次成形时立刻补一次；
  /// 少了这一步，切到从没打开过的页会看到默认口径的数字。
  private func installContent() {
    guard let controller = sections[selection] else { return }
    let content = controller.view
    if builtSections.insert(selection).inserted {
      controller.apply(displayMode: displayMode)
    }
    guard content.superview !== container else { return }
    container.removeAllSubviews()
    container.addSubview(content)
    content.pinEdges(to: container)
  }

  // MARK: - 表头时刻

  /// 各来源里最新的一次取数时刻。全都没有数据时为 nil。
  private func latestFetchedAt() -> Date? {
    quotaStore?.accounts.compactMap(\.fetchedAt).max()
  }

  private func refreshHeaderStamp() {
    header?.apply(fetchedAt: latestFetchedAt(), now: Date())
  }

  /// 单次延迟任务自续，不用 `Timer`：省掉一个常驻 runloop 源，取消即彻底结束。
  private func scheduleHeaderTick() {
    headerTickTask?.cancel()
    headerTickTask = Task { [weak self] in
      try? await Task.sleep(for: Self.headerTickInterval)
      guard !Task.isCancelled, let self, self.isVisible else { return }
      self.refreshHeaderStamp()
      self.scheduleHeaderTick()
    }
  }

  private func cancelHeaderTick() {
    headerTickTask?.cancel()
    headerTickTask = nil
  }
}

/// 浮动窗根视图：磨砂玻璃，透出窗后的桌面与其它窗口。
///
/// 三个参数都不能想当然：
/// - `.behindWindow` 才会采样窗口**后面**的内容；`.withinWindow` 只在本窗口内部做模糊，
///   配上透明窗体就是一片空白。
/// - `state` 必须钉死 `.active`。面板是 `.nonactivatingPanel` 且 `hidesOnDeactivate = false`，
///   绝大多数时候并不是 key window，默认的 `.followsWindowActiveState` 会让它一失焦就掉成
///   一块灰板。
/// - 不复用仓库里的 `ThemeVisualEffectView`：那个是给终端主题用的，会在材质之上再叠一层
///   主题实色 tint，正好把我们要的「透出桌面」盖掉。这里要的是玻璃，不是刷了色的玻璃。
///
/// 窗体是 `.titled` + `fullSizeContentView`，圆角由系统的窗口遮罩裁切，磨砂不会露出直角。
@MainActor
final class UsagePanelRootView: NSVisualEffectView {
  /// 磨砂之上那层主题蒙版的不透明度。
  ///
  /// 这是「玻璃感 vs 可读性」唯一的调节旋钮：调大更像实色面板，调小更透。之所以非有不可——
  /// `.behindWindow` 会把桌面壁纸的亮度混进面板，却**不会**改变应用的 `effectiveAppearance`，
  /// 所以亮色模式下文字仍然是深色；壁纸一深，深字压在深底上就读不出来了。压一层
  /// `AsterTheme.paper` 把底色拉回主题自己的明度，对比度就和壁纸无关了。
  static let scrimAlpha: CGFloat = 0.70

  private let scrim = UsagePanelScrimView()

  /// 供测试读取蒙版。
  var scrimView: NSView { scrim }

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    // `.popover` 是三个候选里唯一亮暗两套都成立的：`.hudWindow` 是按浅色 vibrant 文字调校的，
    // 亮色外观下会把底压得偏暗，而面板用的是 `AsterTheme.ink` 深色文字，叠上去发闷；
    // `.underWindowBackground` 透得太狠，桌面一乱卡片里的小字就糊。`.popover` 在三者里
    // 不透明度最高，既看得出是玻璃、文字对比度又稳得住，语义上也正是「浮动的辅助面板」。
    material = .popover
    blendingMode = .behindWindow
    state = .active
    wantsLayer = true
    // 蒙版是第一个子视图：`NSVisualEffectView` 把材质画在自己的 backing layer 上，子视图
    // 一律在其之上，所以这一层正好夹在「材质」与「后续加进来的表头 / 内容 / 底栏」之间。
    addSubview(scrim)
    scrim.pinEdges(to: self)
  }

  required init?(coder: NSCoder) { nil }
}

/// 磨砂与内容之间的主题蒙版。只负责铺一层色，不参与任何交互。
private final class UsagePanelScrimView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    identifier = NSUserInterfaceItemIdentifier("usage-panel-scrim")
    applyColors()
  }

  required init?(coder: NSCoder) { nil }

  /// 蒙版铺满整块面板，命中测试必须整层放行；否则滚动、点页签、拖窗口全被它吃掉。
  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  /// 动态主题色要在当前外观下解析成具体色值，否则深浅模式共用一份 RGBA。
  private func applyColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.backgroundColor =
        AsterTheme.paper.withAlphaComponent(UsagePanelRootView.scrimAlpha).cgColor
    }
  }
}
