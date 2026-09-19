// AI 用量浮动窗的内容层：顶部页签 + 三页内容的懒构建与生命周期切换。
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
  /// `fullSizeContentView` 下内容铺到标题栏底下，页签要为红绿灯让出这段高度。
  private static let titlebarInset: CGFloat = 28

  private let sections: [Section: UsageSectionController]
  private let defaults: UserDefaults
  private let container = NSView()
  private var tabBar: UsagePanelTabBar?
  private var isVisible = false

  private(set) var selection: Section

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
      defaults: defaults)
  }

  /// 测试注入点：三页换成假实现即可观测 activate / suspend。
  init(sections: [Section: UsageSectionController], defaults: UserDefaults) {
    self.sections = sections
    self.defaults = defaults
    let stored = defaults.string(forKey: Self.selectionDefaultsKey) ?? ""
    selection = Section(rawValue: stored) ?? .quota
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) { nil }

  /// 供测试读取某一页的控制器。
  func sectionController(_ section: Section) -> UsageSectionController? { sections[section] }

  override func loadView() {
    let root = UsagePanelRootView()
    root.identifier = NSUserInterfaceItemIdentifier("usage-panel-content")

    let bar = UsagePanelTabBar(selection: selection) { [weak self] section in
      self?.select(section)
    }
    tabBar = bar
    // 页签只占内容宽度，靠约束贴住左边；拉满会让 NSStackView 把富余宽度平摊给各 chip。
    let barHost = NSView()
    barHost.addSubview(bar)
    bar.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      bar.leadingAnchor.constraint(equalTo: barHost.leadingAnchor),
      bar.topAnchor.constraint(equalTo: barHost.topAnchor),
      bar.bottomAnchor.constraint(equalTo: barHost.bottomAnchor),
      bar.trailingAnchor.constraint(lessThanOrEqualTo: barHost.trailingAnchor),
    ])

    root.addSubview(barHost)
    root.addSubview(container)
    barHost.translatesAutoresizingMaskIntoConstraints = false
    container.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      barHost.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      barHost.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      barHost.topAnchor.constraint(equalTo: root.topAnchor, constant: Self.titlebarInset),
      container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
      container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
      container.topAnchor.constraint(equalTo: barHost.bottomAnchor, constant: 2),
      container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
    ])
    view = root
  }

  // MARK: - 生命周期

  /// 浮动窗显隐。隐藏时当前页必须挂起，否则隐藏的窗口还在取数。
  func setVisible(_ visible: Bool) {
    guard visible != isVisible else { return }
    isVisible = visible
    if visible {
      loadViewIfNeeded()
      installContent()
      sections[selection]?.activate()
    } else {
      sections[selection]?.suspend()
    }
  }

  /// 切页。页签点击与代码切换走同一条路径。
  func select(_ section: Section) {
    guard section != selection else { return }
    if isVisible { sections[selection]?.suspend() }
    selection = section
    defaults.set(section.rawValue, forKey: Self.selectionDefaultsKey)
    tabBar?.select(section)
    guard isVisible else { return }
    installContent()
    sections[selection]?.activate()
  }

  /// 把当前页的视图挂进容器；首次访问 `.view` 才真正构建这一页。
  private func installContent() {
    guard let controller = sections[selection] else { return }
    let content = controller.view
    guard content.superview !== container else { return }
    container.removeAllSubviews()
    container.addSubview(content)
    content.pinEdges(to: container)
  }
}

/// 浮动窗根视图：底层铺一张主题材质，明暗切换时重刷 tint。
///
/// 不直接拿 `ThemeVisualEffectView` 当根视图：它是 `final`，而 tint 需要在
/// `viewDidChangeEffectiveAppearance` 时重算，只能由外层视图代为触发。
@MainActor
final class UsagePanelRootView: NSView {
  private let backdrop = ThemeVisualEffectView()

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    backdrop.autoresizingMask = [.width, .height]
    backdrop.frame = bounds
    addSubview(backdrop)
    applyColors()
  }

  required init?(coder: NSCoder) { nil }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyColors()
  }

  /// 动态主题色要在当前外观下解析成具体色值，否则深浅模式共用一份 RGBA。
  private func applyColors() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      backdrop.apply(material: .vibrancyThin, tint: HexColor(nsColor: AsterTheme.panel))
    }
  }
}

/// 页面标题。`L()` 只接受字面量，映射写在视图层。
@MainActor
func usagePanelSectionTitle(_ section: UsagePanelViewController.Section) -> String {
  switch section {
  case .quota: L("配额")
  case .tokens: L("Token")
  case .sessions: L("会话")
  }
}

/// 浮动窗顶部的 chip 页签行。视觉与详情面板的监控页签一致（选中项淡底圆角）。
@MainActor
final class UsagePanelTabBar: NSStackView {
  private var buttons: [UsagePanelViewController.Section: NSButton] = [:]
  private let onSelect: (UsagePanelViewController.Section) -> Void
  private(set) var selection: UsagePanelViewController.Section

  init(
    selection: UsagePanelViewController.Section,
    onSelect: @escaping (UsagePanelViewController.Section) -> Void
  ) {
    self.selection = selection
    self.onSelect = onSelect
    super.init(frame: .zero)
    orientation = .horizontal
    alignment = .centerY
    spacing = 4
    edgeInsets = NSEdgeInsets(top: 4, left: 14, bottom: 4, right: 14)
    for section in UsagePanelViewController.Section.allCases {
      let button = ActionButton(title: usagePanelSectionTitle(section), bezelStyle: .inline) {
        [weak self] in
        self?.handleClick(section)
      }
      button.isBordered = false
      button.identifier = NSUserInterfaceItemIdentifier("usage-panel-tab-\(section.rawValue)")
      buttons[section] = button
      addArrangedSubview(button)
    }
    applyStyle()
  }

  required init?(coder: NSCoder) { nil }

  /// 外部改选中态（恢复持久化、代码切页）时只更新样式，不再回调。
  func select(_ section: UsagePanelViewController.Section) {
    guard selection != section else { return }
    selection = section
    applyStyle()
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyStyle()
  }

  private func handleClick(_ section: UsagePanelViewController.Section) {
    guard selection != section else { return }
    selection = section
    applyStyle()
    onSelect(section)
  }

  private func applyStyle() {
    for (section, button) in buttons {
      let selected = section == selection
      button.attributedTitle = NSAttributedString(
        string: usagePanelSectionTitle(section),
        attributes: [
          .font: NSFont.systemFont(ofSize: 11.5, weight: selected ? .semibold : .regular),
          .foregroundColor: selected ? AsterTheme.ink : AsterTheme.secondaryInk,
        ])
      button.wantsLayer = true
      button.layer?.cornerRadius = 5
      button.effectiveAppearance.performAsCurrentDrawingAppearance {
        button.layer?.backgroundColor =
          selected ? AsterTheme.ink.withAlphaComponent(0.08).cgColor : NSColor.clear.cgColor
      }
    }
  }
}
