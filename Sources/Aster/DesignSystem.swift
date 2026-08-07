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
  ).palette
  private var dark = TerminalThemeCatalog.resolve(
    named: "Ayu Dark", customThemes: [], mode: .dark
  ).palette

  func update(light: TerminalThemePalette, dark: TerminalThemePalette) {
    lock.lock()
    self.light = light
    self.dark = dark
    lock.unlock()
  }

  func color(for role: Role, appearance: NSAppearance) -> NSColor {
    lock.lock()
    let palette = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
    lock.unlock()

    let value: HexColor
    switch role {
    case .window: value = palette.interfaceWindowBackground ?? palette.windowBackground
    case .container: value = palette.containerBackground
    case .panel: value = palette.panelBackground
    case .surface: value = palette.panelSurface ?? palette.panelBackground
    case .foreground: value = palette.interfaceForeground ?? palette.foreground
    case .secondary: value = palette.secondaryForeground
    case .tertiary: value = palette.tertiaryForeground ?? palette.secondaryForeground
    case .border:
      value = palette.interfaceBorder
        ?? HexColor(
          red: palette.secondaryForeground.red,
          green: palette.secondaryForeground.green,
          blue: palette.secondaryForeground.blue,
          alpha: 61
        )
    case .accent: value = palette.accent
    case .selection: value = palette.selection
    case .warning: value = palette.ansiColors[1]
    }
    return NSColor(value)
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
    state = .active
    isEmphasized = true
    switch themeMaterial {
    case .glass:
      material = .hudWindow
      blendingMode = .behindWindow
      layer?.backgroundColor = NSColor(tint).withAlphaComponent(0.24).cgColor
    case .vibrancyThin:
      material = .sidebar
      blendingMode = .behindWindow
      layer?.backgroundColor = NSColor(tint).withAlphaComponent(0.20).cgColor
    case .vibrancyRegular:
      material = .underWindowBackground
      blendingMode = .behindWindow
      layer?.backgroundColor = NSColor(tint).withAlphaComponent(0.34).cgColor
    case .some(.none), nil:
      material = .contentBackground
      blendingMode = .withinWindow
      layer?.backgroundColor = NSColor(tint).cgColor
    }
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
  static let rowTitleSize: CGFloat = 13
  static let rowDetailSize: CGFloat = 11
  static let groupTitleSize: CGFloat = 11
  // 全高侧栏窗口（fullSizeContentView）下为标题栏红绿灯让出的顶部空间。
  static let sidebarTopInset: CGFloat = 44
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
