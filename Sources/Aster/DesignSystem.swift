import AppKit
import AsterCore

/// 线程安全保存当前明暗主题。AppKit 控件通过动态 `NSColor` 读取角色色，切换主题后
/// 只需刷新 appearance，无需把具体颜色复制到每个控制器。
final class ThemeRuntime: @unchecked Sendable {
  static let shared = ThemeRuntime()

  enum Role {
    case window, container, panel, surface, foreground, secondary, tertiary, border, accent
    case selection, warning
  }

  private let lock = NSLock()
  private var light = TerminalThemeCatalog.resolve(
    named: "Ayu Light", customThemes: [], mode: .light
  )
  private var dark = TerminalThemeCatalog.resolve(
    named: "Ayu Dark", customThemes: [], mode: .dark
  )

  func update(light: TerminalTheme, dark: TerminalTheme) {
    lock.lock()
    self.light = light
    self.dark = dark
    lock.unlock()
  }

  func color(for role: Role, appearance: NSAppearance) -> NSColor {
    lock.lock()
    let theme = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    lock.unlock()

    let palette = theme.palette
    let value: HexColor
    switch role {
    case .window: value = theme.resolvedColor(forSlot: "interface.window") ?? palette.windowBackground
    case .container: value = theme.resolvedColor(forSlot: "container.background") ?? palette.containerBackground
    case .panel: value = theme.resolvedColor(forSlot: "panel.background") ?? palette.panelBackground
    case .surface: value = theme.resolvedColor(forSlot: "panel.surface") ?? palette.panelBackground
    case .foreground: value = theme.resolvedColor(forSlot: "interface.foreground") ?? palette.foreground
    case .secondary:
      value = theme.resolvedColor(forSlot: "interface.secondaryForeground")
        ?? palette.secondaryForeground
    case .tertiary:
      value = theme.resolvedColor(forSlot: "interface.tertiaryForeground")
        ?? palette.secondaryForeground
    case .border:
      value = theme.resolvedColor(forSlot: "interface.border")
        ?? palette.secondaryForeground
    case .accent: value = theme.resolvedColor(forSlot: "interface.accent") ?? palette.accent
    case .selection: value = theme.resolvedColor(forSlot: "selection.background") ?? palette.selection
    case .warning: value = palette.ansiColors[1]
    }
    return NSColor(value)
  }
}

/// 独立设置窗口的固定色板。
///
/// 这是 CLAUDE.md「主题色只经由 ThemeRuntime 进入视图」规则的一处明确例外：设置页
/// **不跟随终端主题**。主题描述的是终端与工作区的样子，把它铺到设置页会让调色本身
/// 变得不可用——把 window 改成红色，整个设置页连同正在编辑的色板都会变红，用户
/// 无法判断某个颜色是主题效果还是设置页自己的底色。这里的颜色只随系统明暗外观变化。
enum SettingsTheme {
  /// 内容画布。卡片要压在它上面，因此它比卡片更亮（深色模式下更暗）。
  static let canvas = dynamic(light: 0xFFFFFF, dark: 0x1C1C1E)
  /// 分组卡片 / 主题网格 / 主题详情的整块底色。
  static let card = dynamic(light: 0xFAFAFA, dark: 0x262628)
  static let sidebar = dynamic(light: 0xF5F5F7, dark: 0x202022)
  /// 搜索框使用独立的中性灰底，在侧栏上形成清晰输入区域，同时保留原生搜索行为。
  static let searchField = dynamic(light: 0xE9E9EC, dark: 0x2C2C2E)
  static let ink = dynamic(light: 0x1D1D1F, dark: 0xF2F2F7)
  static let secondaryInk = dynamic(light: 0x6E6E73, dark: 0xA1A1A6)
  static let tertiaryInk = dynamic(light: 0x8E8E93, dark: 0x8A8A8F)
  static let hairline = dynamic(light: 0xD8D8DC, dark: 0x3A3A3C)
  /// 选中态跟随系统强调色：设置页属于系统外观的一部分，不该用终端主题的 accent。
  static var accent: NSColor { .controlAccentColor }

  private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
    NSColor(name: nil) { appearance in
      appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(rgb: dark) : NSColor(rgb: light)
    }
  }
}

extension HexColor {
  /// `NSColor` → 领域层色值。取色器与设置页共用同一套转换，避免两处各自取整后漂移。
  ///
  /// 必须四舍五入而不是截断：颜色在 hex → NSColor → HSB → NSColor → hex 的往返里会
  /// 落下浮点误差，`UInt8(0.23137 * 255)` 截断后是 58 而不是 59，用户输入的
  /// `#3b82f6` 会被存成 `#3a82f6`——每往返一次就再暗一档。
  init(nsColor: NSColor) {
    let value = nsColor.usingColorSpace(.sRGB) ?? nsColor
    func channel(_ raw: CGFloat) -> UInt8 {
      UInt8((min(max(raw, 0), 1) * 255).rounded())
    }
    self.init(
      red: channel(value.redComponent),
      green: channel(value.greenComponent),
      blue: channel(value.blueComponent),
      alpha: channel(value.alphaComponent)
    )
  }
}

extension NSColor {
  /// 从 0xRRGGBB 构造不透明色，供固定色板使用。
  fileprivate convenience init(rgb: UInt32) {
    self.init(
      srgbRed: CGFloat((rgb >> 16) & 0xFF) / 255,
      green: CGFloat((rgb >> 8) & 0xFF) / 255,
      blue: CGFloat(rgb & 0xFF) / 255,
      alpha: 1
    )
  }
}

/// 共享的相对时间格式化（如「15 秒前」），供 Open Quickly 与详情面板等浮层共用。
/// @MainActor 隔离保证非 Sendable 的 formatter 不会跨线程共享。
@MainActor
enum RelativeTime {
  private static let formatter: RelativeDateTimeFormatter = {
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter
  }()

  /// 返回 date 相对 reference(默认现在)的本地化相对时间字符串。
  static func string(since date: Date, relativeTo reference: Date = Date()) -> String {
    formatter.localizedString(for: date, relativeTo: reference)
  }
}

/// AppKit 版角色化视觉令牌。动态颜色会跟随窗口 appearance 自动解析。
enum AsterTheme {
  static let paper = dynamic(.window)
  static let sidebar = dynamic(.panel)
  static let panel = dynamic(.surface)
  static let ink = dynamic(.foreground)
  static let secondaryInk = dynamic(.secondary)
  static let tertiaryInk = dynamic(.tertiary)
  static let hairline = dynamic(.border)
  /// 结构分隔线（Pane 之间、工作区与详情面板之间、侧栏边界）专用的更淡描边。
  ///
  /// 与 `hairline` 分开：`hairline` 还要给卡片、输入框、色块描边用，那些地方需要
  /// 看得清的边界；而贯穿整个窗口高度的分隔线用同样的深度会喧宾夺主，视觉上把
  /// 窗口切成几块硬边。这里在主题 border 色基础上再降到 40% 不透明度。
  static let divider = NSColor(name: nil) { appearance in
    ThemeRuntime.shared.color(for: .border, appearance: appearance)
      .withAlphaComponent(0.4)
  }
  static let accent = dynamic(.accent)
  static let selection = dynamic(.selection)
  static let warning = dynamic(.warning)

  static func dynamic(_ role: ThemeRuntime.Role) -> NSColor {
    NSColor(name: nil) { appearance in
      ThemeRuntime.shared.color(for: role, appearance: appearance)
    }
  }
}

/// 将 Otty 的 window/sidebar/titlebar material 映射为原生 `NSVisualEffectView`。
/// 主题色只以半透明 tint 叠加，保留桌面内容透过玻璃后的真实颜色与动态模糊。
final class ThemeVisualEffectView: NSVisualEffectView {
  /// 保留最后一次应用的原始 Otty token，供布局同步和自动化验收读取。layer 上的颜色会
  /// 因 material 叠加透明度，不能反推出用户在主题详情里看到的原始值。
  private(set) var appliedThemeTint: HexColor?
  private(set) var appliedThemeMaterial: TerminalThemeMaterial?
  /// `NSVisualEffectView` 会把自己的系统 material 画在 backing layer 上方，仅设置
  /// `layer.backgroundColor` 会让 April/Pink/Paper 等实色最终被洗成系统白色。主题 tint
  /// 必须作为首个内容子视图画在 material 上方，其它业务子视图再覆盖到它上方。
  private weak var themeTintOverlay: ThemeTintOverlayView?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
    state = .active
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    wantsLayer = true
    state = .active
  }

  func apply(material themeMaterial: TerminalThemeMaterial?, tint: HexColor) {
    appliedThemeTint = tint
    appliedThemeMaterial = themeMaterial
    state = .active
    isEmphasized = true
    switch themeMaterial {
    case .glass:
      material = .hudWindow
      blendingMode = .behindWindow
    case .vibrancyThin:
      material = .sidebar
      blendingMode = .behindWindow
    case .vibrancyRegular:
      material = .underWindowBackground
      blendingMode = .behindWindow
    case .some(.none), nil:
      material = .contentBackground
      blendingMode = .withinWindow
    }
    layer?.backgroundColor = NSColor.clear.cgColor
    let overlay: ThemeTintOverlayView
    if let themeTintOverlay, themeTintOverlay.superview === self {
      overlay = themeTintOverlay
    } else {
      overlay = ThemeTintOverlayView(frame: bounds)
      overlay.autoresizingMask = [.width, .height]
      addSubview(overlay, positioned: .below, relativeTo: subviews.first)
      themeTintOverlay = overlay
    }
    let sourceAlpha = CGFloat(tint.alpha) / 255
    let alpha: CGFloat = switch themeMaterial {
    // Otty 用 alpha=0 的 sidebar tint 表示“只显示玻璃材质”。不能把透明 token
    // 强行改成 24% 不透明白色，否则 Ayu/Floating/Glass 三套侧栏都会明显发白。
    case .glass: sourceAlpha * 0.24
    case .vibrancyThin: sourceAlpha * 0.20
    case .vibrancyRegular: sourceAlpha * 0.34
    case .some(.none), nil: CGFloat(tint.alpha) / 255
    }
    // alpha=0 表示只显示系统 material。不能根据某张截图额外叠一层固定灰黑色：磨砂
    // 的最终像素取决于桌面、窗口层级和系统外观，截图采样值不是主题配置的真实颜色。
    overlay.layer?.backgroundColor = NSColor(tint).withAlphaComponent(alpha).cgColor
  }
}

/// 纯绘制层不参与命中测试，空白侧栏、标题栏和详情区的鼠标事件仍由原容器处理。
private final class ThemeTintOverlayView: NSView {
  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
  }

  required init?(coder: NSCoder) { nil }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// 不创建独立 macOS material 的主题表面。它用于已经位于 Window/Container 材质
/// 内部的 Pane：只应用主题 RGBA，透明色继续透出唯一的外层材质，避免 Inspector 再
/// 叠一层 Sidebar vibrancy 后与同一张容器卡片里的终端产生色差。
final class ThemeSurfaceView: NSView {
  private(set) var appliedThemeTint: HexColor?

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    wantsLayer = true
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    wantsLayer = true
  }

  func apply(tint: HexColor) {
    appliedThemeTint = tint
    layer?.backgroundColor = NSColor(tint).cgColor
  }
}

extension NSColor {
  convenience init(_ color: HexColor) {
    self.init(
      srgbRed: CGFloat(color.red) / 255,
      green: CGFloat(color.green) / 255,
      blue: CGFloat(color.blue) / 255,
      alpha: CGFloat(color.alpha) / 255
    )
  }
}

extension NSView {
  /// 统一创建 Auto Layout 约束，避免 AppKit 迁移后每个页面重复边缘约束样板代码。
  func pinEdges(to parent: NSView, insets: NSEdgeInsets = .zero) {
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
      trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
      topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
      bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom),
    ])
  }

  func removeAllSubviews() {
    subviews.forEach { $0.removeFromSuperview() }
  }
}

extension NSEdgeInsets {
  static let zero = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

  init(_ insets: ThemeInsets) {
    self.init(
      top: insets.top,
      left: insets.leading,
      bottom: insets.bottom,
      right: insets.trailing
    )
  }
}

extension NSFont.Weight {
  init(cssWeight: Int) {
    switch cssWeight {
    case 700...: self = .bold
    case 600..<700: self = .semibold
    case 500..<600: self = .medium
    case 400..<500: self = .regular
    default: self = .light
    }
  }
}

/// 设置页共享的间距、字号与圆角常量。集中一处便于统一视觉节奏，也让布局测试
/// 与实现引用同一真值，避免魔法数散落在各行构建函数里。
enum SettingsMetrics {
  static let cardCornerRadius: CGFloat = 12
  static let rowVerticalInset: CGFloat = 17
  static let rowHorizontalInset: CGFloat = 18
  /// 右侧内容字号统一低于 13pt 侧栏导航，避免卡片文字反客为主。
  static let rowTitleSize: CGFloat = 12
  static let rowDetailSize: CGFloat = 10
  static let groupTitleSize: CGFloat = 10
  static let controlTextSize: CGFloat = 11
  // 全高侧栏窗口（fullSizeContentView）下为标题栏红绿灯让出的顶部空间。
  static let sidebarTopInset: CGFloat = 44
  /// 标准 titled 窗口的标题栏高度；设置页用它盖出一条可拖拽的透明区域。
  static let titlebarDragStripHeight: CGFloat = 28
}

/// 透明拖拽条。设置页内容是一整块 WKWebView，开了 fullSizeContentView 之后标题栏那一条
/// 也落在网页上，WebKit 会吃掉 mouseDown 让窗口拖不动。这层视图压在最上面接管该区域：
/// 单击拖拽交给 `performDrag`（比 `mouseDownCanMoveWindow` 可靠，不依赖窗口背景拖拽开关），
/// 双击沿用系统标题栏的缩放行为。自身不绘制任何内容，透明标题栏下的网页依旧完整可见。
final class SettingsTitlebarDragStrip: NSView {
  override var mouseDownCanMoveWindow: Bool { true }

  override func mouseDown(with event: NSEvent) {
    guard let window else { return super.mouseDown(with: event) }
    if event.clickCount == 2 {
      window.performZoom(nil)
      return
    }
    window.performDrag(with: event)
  }
}

/// 滚动文档使用左上原点，内部仍放置标准 `NSStackView`。不要直接翻转 StackView：
/// AppKit 会同时反转 arrangedSubviews 的垂直排布，导致首项沉到可视区域底部。
final class FlippedDocumentView: NSView {
  override var isFlipped: Bool { true }
}

/// 使用系统 SF Symbols 的无边框图标按钮，保留 28pt 可点击区域和原生按压反馈。
final class SymbolButton: NSButton {
  init(symbol: String, toolTip: String? = nil, target: AnyObject? = nil, action: Selector? = nil) {
    super.init(frame: .zero)
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: toolTip)
    imagePosition = .imageOnly
    bezelStyle = .accessoryBarAction
    isBordered = false
    self.toolTip = toolTip
    self.target = target
    self.action = action
    translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      widthAnchor.constraint(equalToConstant: 28),
      heightAnchor.constraint(equalToConstant: 28),
    ])
  }

  required init?(coder: NSCoder) { nil }
}

/// AppKit 的 target/action 不直接保存 Swift 闭包；该按钮在自身生命周期内安全持有动作。
final class ActionButton: NSButton {
  private let handler: () -> Void

  init(
    title: String = "",
    symbol: String? = nil,
    bezelStyle: NSButton.BezelStyle = .rounded,
    handler: @escaping () -> Void
  ) {
    self.handler = handler
    super.init(frame: .zero)
    self.title = title
    self.bezelStyle = bezelStyle
    if let symbol {
      image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
      imagePosition = title.isEmpty ? .imageOnly : .imageLeading
    }
    target = self
    action = #selector(invoke)
  }

  required init?(coder: NSCoder) { nil }

  @objc private func invoke() { handler() }
}

/// 工作区右上角唯一 Inspector 切换按钮的几何与显隐参数。按钮直接覆盖在根视图上，
/// 不参与 Content / Inspector 宽度求解，所以面板显隐时实例和坐标都不变。
enum InspectorToggleMetrics {
  static let buttonSize: CGFloat = 24
  static let trailingInset: CGFloat = 8
  /// Inspector header 为覆盖按钮留出的宽度：按钮尺寸、窗口右边距和 6pt 安全间隔。
  static let trailingReservedWidth = buttonSize + trailingInset + 6
  /// 距工作区顶边的中心线，与 28pt 标题栏垂直居中。
  static let centerYFromTop: CGFloat = 14
  static let symbol = "sidebar.right"
  /// 收拢完成后同一颗按钮继续短暂停留，再按标题栏悬停状态淡出。
  static let postCollapseHideDelay: Duration = .milliseconds(650)
}

/// 无边框图标按钮 + 悬停底色。`isBordered = false` 的图标默认没有任何指针反馈，看上去
/// 与静态图标无异；凡是可点的图标都应使用该按钮，让用户能判断哪里可以点。
@MainActor
final class IconHoverButton: NSButton {
  private let handler: () -> Void
  private var hoverTrackingArea: NSTrackingArea?
  private var isHovering = false
  /// 非悬停时的图标色。悬停会同时加深图标，只靠底色在浅色主题下不够明显。
  var restingTint: NSColor = AsterTheme.secondaryInk {
    didSet { applyAppearance() }
  }

  init(symbol: String, accessibilityDescription: String? = nil, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(frame: .zero)
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)
    imagePosition = .imageOnly
    bezelStyle = .accessoryBarAction
    isBordered = false
    wantsLayer = true
    layer?.cornerRadius = 5
    target = self
    action = #selector(invoke)
    applyAppearance()
  }

  required init?(coder: NSCoder) { nil }

  /// 换图标（例如暂存 ↔ 取消暂存）后仍要保持当前的悬停配色。
  func setSymbol(_ symbol: String, accessibilityDescription: String? = nil) {
    image = NSImage(systemSymbolName: symbol, accessibilityDescription: accessibilityDescription)
    applyAppearance()
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

  override func mouseEntered(with event: NSEvent) {
    super.mouseEntered(with: event)
    guard !isHovering else { return }
    isHovering = true
    applyAppearance()
  }

  override func mouseExited(with event: NSEvent) {
    super.mouseExited(with: event)
    guard isHovering else { return }
    isHovering = false
    applyAppearance()
  }

  /// 隐藏时收不到 `mouseExited`，重新显示会残留上一次的悬停态。
  override var isHidden: Bool {
    didSet {
      guard isHidden, isHovering else { return }
      isHovering = false
      applyAppearance()
    }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    applyAppearance()
  }

  private func applyAppearance() {
    contentTintColor = isHovering ? AsterTheme.ink : restingTint
    layer?.backgroundColor = isHovering
      ? AsterTheme.ink.withAlphaComponent(0.10).cgColor : NSColor.clear.cgColor
  }

  @objc private func invoke() { handler() }
}

/// 右键菜单项的闭包桥接，避免菜单动作依赖全局单例或脆弱的 responder chain。
final class ActionMenuItem: NSMenuItem {
  private var handler: (() -> Void)?

  init(title: String, handler: @escaping () -> Void) {
    self.handler = handler
    super.init(title: title, action: #selector(invoke), keyEquivalent: "")
    target = self
  }

  required init(coder: NSCoder) {
    handler = nil
    super.init(coder: coder)
  }

  @objc private func invoke() { handler?() }
}

@MainActor
func makeLabel(
  _ value: String,
  size: CGFloat = 12,
  weight: NSFont.Weight = .regular,
  color: NSColor = AsterTheme.ink,
  monospaced: Bool = false
) -> NSTextField {
  let label = NSTextField(labelWithString: value)
  label.font = monospaced
    ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    : NSFont.systemFont(ofSize: size, weight: weight)
  label.textColor = color
  label.lineBreakMode = .byTruncatingTail
  return label
}
