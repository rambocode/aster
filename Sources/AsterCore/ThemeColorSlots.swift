import Foundation

extension HexColor {
  /// 展示用短写。持久化仍用 8 位大写的 `stringValue`；这里按 Otty 主题文件的写法
  /// 输出小写，不透明色省略 alpha，方便与 `.ottytheme` 逐字比对。
  public var displayString: String {
    alpha == 255
      ? String(format: "#%02x%02x%02x", red, green, blue)
      : String(format: "#%02x%02x%02x%02x", red, green, blue, alpha)
  }
}

/// 主题详情色板的分组。顺序即界面里胶囊的排列顺序。
public enum ThemeColorGroup: String, CaseIterable, Codable, Equatable, Sendable {
  case terminal
  case window
  case container
  case panel
  case sidebar
  case titlebar
  case tabbar
  case tab
  case accents
  case cursor
  case selection

  public var title: String {
    switch self {
    case .terminal: "Terminal"
    case .window: "Window"
    case .container: "Container"
    case .panel: "Panel"
    case .sidebar: "Sidebar"
    case .titlebar: "Titlebar"
    case .tabbar: "Tabbar"
    case .tab: "Tab"
    case .accents: "Accents"
    case .cursor: "光标"
    case .selection: "选区"
    }
  }
}

/// 色块的绘制语义。界面据此决定画实心块、空心描边还是「未设置」的斜线底。
public enum ThemeColorSlotKind: String, Codable, Equatable, Sendable {
  /// 实心填充。
  case fill
  /// 只画描边（容器/侧栏/标签的 border token）。
  case border
}

/// 主题里一个可读可改的颜色位。
///
/// 关键区别是 `value` 与 `resolved`：`value == nil` 表示主题没有显式声明这个 token，
/// 它此刻的颜色是从 window 一侧派生出来的（`resolved`）。界面必须把两者画得不一样，
/// 否则用户无法判断「改 window 会不会连带改到它」。
public struct ThemeColorSlot: Identifiable, Equatable, Sendable {
  public let id: String
  /// 中文可读名，用于 tooltip 的前半段。
  public let title: String
  public let group: ThemeColorGroup
  /// 主题显式声明的值；`nil` 表示未声明、跟随 window 派生。
  public let value: HexColor?
  /// 当前实际生效的颜色。
  public let resolved: HexColor
  public let kind: ThemeColorSlotKind

  public init(
    id: String,
    title: String,
    group: ThemeColorGroup,
    value: HexColor?,
    resolved: HexColor,
    kind: ThemeColorSlotKind = .fill
  ) {
    self.id = id
    self.title = title
    self.group = group
    self.value = value
    self.resolved = resolved
    self.kind = kind
  }

  /// 是否为「未显式设置、跟随 window 派生」。
  public var isDerived: Bool { value == nil }

  /// tooltip 文案：`前景色 · terminal.foreground = "#2a2b33"`。派生值额外标注来源。
  public var tooltip: String {
    let hex = "\(title) · \(id) = \"\(resolved.displayString)\""
    return isDerived ? "\(hex)（未设置，跟随 Window 派生）" : hex
  }
}

extension TerminalTheme {
  /// 返回设置页某个颜色位当前真正生效的值。
  ///
  /// 工作区渲染也必须调用这个入口，不能在 AppKit 层重新抄一套 fallback；否则详情色板
  /// 显示的是一个颜色，窗口、侧栏或标签栏却会按另一条级联规则绘制。
  public func resolvedColor(forSlot id: String) -> HexColor? {
    colorSlots.first { $0.id == id }?.resolved
  }

  /// 详情色板的完整 token 表。顺序稳定，界面直接按 `group` 分段渲染。
  ///
  /// 只列出真实存在的 token，不为了凑视觉格数造不存在的颜色——色板要能当作
  /// 「这套主题到底声明了什么」的真值来读。
  public var colorSlots: [ThemeColorSlot] {
    let windowFallback = palette.interfaceWindowBackground ?? palette.panelBackground
    // `interface.border` 是唯一一个「必须自己有对比度」的描边令牌：Pane 分隔条、卡片和
    // 输入框描边都取它。跟随窗口底色会在 window 与 container 同色的主题（One Light 的
    // 纯白）上退化成不可见的同色线，所以这里单独派生一条发丝线；其余 border 令牌保持
    // Otty `1px solid auto` 的语义（auto = 窗口底色），不受影响。
    let borderFallback = mode.nativeBorder(
      over: windowFallback,
      foreground: palette.interfaceForeground ?? palette.foreground
    )
    func slot(
      _ id: String,
      _ title: String,
      _ group: ThemeColorGroup,
      _ value: HexColor?,
      derivedFrom fallback: HexColor,
      kind: ThemeColorSlotKind = .fill
    ) -> ThemeColorSlot {
      ThemeColorSlot(
        id: id, title: title, group: group, value: value,
        resolved: value ?? fallback, kind: kind)
    }

    var slots: [ThemeColorSlot] = [
      // 终端色永远是显式的：SwiftTerm 不能没有前景/背景。
      slot("terminal.foreground", "前景色", .terminal, palette.foreground, derivedFrom: palette.foreground),
      slot("terminal.background", "背景色", .terminal, palette.windowBackground, derivedFrom: palette.windowBackground),
      slot("interface.window", "窗口底色", .window, palette.interfaceWindowBackground, derivedFrom: palette.panelBackground),
      slot("container.background", "容器背景", .container, style.container.background, derivedFrom: palette.containerBackground),
      slot("container.border", "容器边框", .container, style.container.borderColor, derivedFrom: windowFallback, kind: .border),
      slot("panel.background", "面板背景", .panel, palette.panelBackground, derivedFrom: palette.panelBackground),
      slot("panel.surface", "面板表面", .panel, palette.panelSurface, derivedFrom: palette.panelBackground),
      slot("panel.border", "面板边框", .panel, palette.interfaceBorder, derivedFrom: windowFallback, kind: .border),
      // Sidebar 这一组同时作用于左侧标签栏与右侧详情面板，两栏共用同一批 token。
      slot("sidebar.background", "侧栏背景（左右两栏）", .sidebar, style.sidebarBackground, derivedFrom: palette.panelBackground),
      slot("sidebar.foreground", "侧栏文字（左右两栏）", .sidebar, palette.interfaceForeground, derivedFrom: palette.foreground),
      slot("sidebar.border", "侧栏边框（左右两栏）", .sidebar, style.sidebarBorderColor, derivedFrom: windowFallback, kind: .border),
      slot("titlebar.background", "标题栏背景", .titlebar, style.titlebarBackground, derivedFrom: palette.renderedTerminalBackground),
      slot("titlebar.foreground", "标题栏文字", .titlebar, style.titlebarForeground, derivedFrom: palette.secondaryForeground),
      slot("tabbar.background", "标签栏背景", .tabbar, style.horizontalTabBarBackground, derivedFrom: style.sidebarBackground ?? palette.panelBackground),
      slot("tabbar.border", "标签栏边框", .tabbar, style.horizontalTabBarBorderColor, derivedFrom: windowFallback, kind: .border),
      slot("tab.foreground", "标签文字", .tab, style.tab.foreground, derivedFrom: palette.secondaryForeground),
      // Otty 级联：hover → ui.hover（原生叠加色）；active → 主题声明的 panel.surface，
      // 否则原生选中叠加色。不能回退到 panel 底色——那会让选中/悬停与侧栏同色而不可见。
      slot("tab.hoverBackground", "标签悬停底色", .tab, style.tab.hoverBackground, derivedFrom: mode.nativeTabHoverBackground),
      slot("tab.activeBackground", "选中标签底色", .tab, style.tab.activeBackground, derivedFrom: palette.panelSurface ?? mode.nativeTabActiveBackground),
      slot("tab.activeForeground", "选中标签文字", .tab, style.tab.activeForeground, derivedFrom: palette.foreground),
      slot("tab.activeBorderColor", "选中标签边框", .tab, style.tab.activeBorderColor, derivedFrom: windowFallback, kind: .border),
      slot("interface.accent", "强调色", .accents, palette.accent, derivedFrom: palette.accent),
      slot("interface.foreground", "界面文字", .accents, palette.interfaceForeground, derivedFrom: palette.foreground),
      slot("interface.secondaryForeground", "次要文字", .accents, palette.secondaryForeground, derivedFrom: palette.secondaryForeground),
      slot("interface.tertiaryForeground", "三级文字", .accents, palette.tertiaryForeground, derivedFrom: palette.secondaryForeground),
      slot("interface.border", "界面描边", .accents, palette.interfaceBorder, derivedFrom: borderFallback, kind: .border),
      slot("cursor.background", "光标", .cursor, palette.cursor, derivedFrom: palette.cursor),
      slot("cursor.foreground", "光标下文字", .cursor, palette.cursorText, derivedFrom: palette.renderedTerminalBackground),
      slot("selection.background", "选区", .selection, palette.selection, derivedFrom: palette.selection),
      slot("selection.foreground", "选区文字", .selection, palette.selectionForeground, derivedFrom: palette.foreground),
    ]
    slots.sort { lhs, rhs in
      guard let left = ThemeColorGroup.allCases.firstIndex(of: lhs.group),
        let right = ThemeColorGroup.allCases.firstIndex(of: rhs.group), left != right
      else { return false }
      return left < right
    }
    return slots
  }

  /// 把某个 slot 改成新颜色。未知 id 返回自身，调用方因此不必先做存在性判断。
  ///
  /// 写回一律落在该 token 自己的字段上：派生位被赋值后就变成显式值，从此不再跟随
  /// window 变化——这正是用户点色块改色时期望的语义。
  public func applyingColor(_ color: HexColor, toSlot id: String) -> TerminalTheme {
    var copy = self
    switch id {
    case "terminal.foreground": copy.palette.foreground = color
    case "terminal.background": copy.palette.windowBackground = color
    case "interface.window": copy.palette.interfaceWindowBackground = color
    case "container.background": copy.style.container.background = color
    case "container.border":
      copy.style.container.borderColor = color
      // 颜色位是用户可操作设置；若原主题没有边框，改单色后至少启用 1pt，避免出现
      // “设置已经保存但画面完全没变化”的假成功。
      if copy.style.container.borderWidth == 0 { copy.style.container.borderWidth = 1 }
    case "panel.background": copy.palette.panelBackground = color
    case "panel.surface": copy.palette.panelSurface = color
    case "panel.border": copy.palette.interfaceBorder = color
    case "sidebar.background": copy.style.sidebarBackground = color
    case "sidebar.foreground": copy.palette.interfaceForeground = color
    case "sidebar.border": copy.style.sidebarBorderColor = color
    case "titlebar.background": copy.style.titlebarBackground = color
    case "titlebar.foreground": copy.style.titlebarForeground = color
    case "tabbar.background": copy.style.horizontalTabBarBackground = color
    case "tabbar.border": copy.style.horizontalTabBarBorderColor = color
    case "tab.foreground":
      // Parser 会把 `[tab-bar.tab]` 的继承结果展开成完整值。改色时以“改前是否与
      // 基础字段相等”识别继承字段并同步更新；真正不同的横向专属覆盖继续保留。
      let horizontalInherited = copy.style.horizontalTab?.foreground == copy.style.tab.foreground
      copy.style.tab.foreground = color
      if horizontalInherited { copy.style.horizontalTab?.foreground = color }
    case "tab.hoverBackground":
      let horizontalInherited =
        copy.style.horizontalTab?.hoverBackground == copy.style.tab.hoverBackground
      copy.style.tab.hoverBackground = color
      if horizontalInherited { copy.style.horizontalTab?.hoverBackground = color }
    case "tab.activeBackground":
      let horizontalInherited =
        copy.style.horizontalTab?.activeBackground == copy.style.tab.activeBackground
      copy.style.tab.activeBackground = color
      if horizontalInherited { copy.style.horizontalTab?.activeBackground = color }
    case "tab.activeForeground":
      let horizontalInherited =
        copy.style.horizontalTab?.activeForeground == copy.style.tab.activeForeground
      copy.style.tab.activeForeground = color
      if horizontalInherited { copy.style.horizontalTab?.activeForeground = color }
    case "tab.activeBorderColor":
      let horizontalInherited =
        copy.style.horizontalTab?.activeBorderColor == copy.style.tab.activeBorderColor
        && copy.style.horizontalTab?.activeBorderWidth == copy.style.tab.activeBorderWidth
      copy.style.tab.activeBorderColor = color
      if copy.style.tab.activeBorderWidth == 0 { copy.style.tab.activeBorderWidth = 1 }
      if horizontalInherited {
        copy.style.horizontalTab?.activeBorderColor = color
        if copy.style.horizontalTab?.activeBorderWidth == 0 {
          copy.style.horizontalTab?.activeBorderWidth = 1
        }
      }
    case "interface.accent": copy.palette.accent = color
    case "interface.foreground": copy.palette.interfaceForeground = color
    case "interface.secondaryForeground": copy.palette.secondaryForeground = color
    case "interface.tertiaryForeground": copy.palette.tertiaryForeground = color
    case "interface.border": copy.palette.interfaceBorder = color
    case "cursor.background": copy.palette.cursor = color
    case "cursor.foreground": copy.palette.cursorText = color
    case "selection.background": copy.palette.selection = color
    case "selection.foreground": copy.palette.selectionForeground = color
    default: break
    }
    return copy
  }
}
