import Foundation

/// 把主题序列化成 Otty `.ottytheme` TOML 子集。
///
/// 用途：把 Aster 内置主题物化到主题目录（`~/.config/aster/themes`），作为安装包
/// 自带种子文件缺失时的兜底（`swift run`、单测）。输出的每个键都必须能被
/// `ThemeFileParser` 无损读回；已存在的文件（Otty 落盘或用户自定义）绝不覆盖，
/// 覆盖策略由调用方保证。
public enum ThemeFileSerializer {
  public static func serialize(_ theme: TerminalTheme) -> String {
    var lines: [String] = []

    // Otty 主题惯用 6 位 hex；只有带透明度时才写 8 位（解析器两者都收）。
    func hex(_ color: HexColor) -> String {
      color.alpha == 255
        ? String(format: "#%02X%02X%02X", color.red, color.green, color.blue)
        : color.stringValue
    }
    // TOML 数值不写多余的小数尾巴（8 而不是 8.0），带小数时保留原值。
    func number(_ value: Double) -> String {
      value == value.rounded() ? String(Int(value)) : String(value)
    }
    func section(_ name: String) {
      if !lines.isEmpty { lines.append("") }
      lines.append("[\(name)]")
    }
    func write(_ key: String, string value: String) { lines.append("\(key) = \"\(value)\"") }
    func write(_ key: String, color value: HexColor?) {
      if let value { write(key, string: hex(value)) }
    }
    func write(_ key: String, number value: Double?) {
      if let value { lines.append("\(key) = \(number(value))") }
    }
    func write(_ key: String, border width: Double, _ color: HexColor?) {
      guard width > 0, let color else { return }
      write(key, string: "\(number(width))px solid \(hex(color))")
    }
    func write(_ key: String, shadow value: ThemeShadow?) {
      guard let value else { return }
      write(
        key,
        string:
          "\(number(value.x)) \(number(value.y)) \(number(value.blur)) \(hex(value.color))")
    }
    func write(_ key: String, insets value: ThemeInsets) {
      if value.top == value.leading, value.top == value.bottom, value.top == value.trailing {
        lines.append("\(key) = \(number(value.top))")
      } else {
        lines.append(
          "\(key) = [\(number(value.top)), \(number(value.leading)), "
            + "\(number(value.bottom)), \(number(value.trailing))]")
      }
    }
    func write(_ key: String, material value: TerminalThemeMaterial?) {
      if let value { write(key, string: value.rawValue) }
    }

    let palette = theme.palette
    let style = theme.style

    section("meta")
    write("name", string: theme.name)
    write("mode", string: theme.mode.rawValue)

    section("terminal")
    write("foreground", color: palette.foreground)
    write("background", color: palette.windowBackground)
    let ansi = palette.ansiColors.map { "\"\(hex($0))\"" }
    lines.append("palette = [\(ansi.joined(separator: ", "))]")
    write("cursor", color: palette.cursor)
    write("cursor-text", color: palette.cursorText)
    write("selection-background", color: palette.selection)
    write("selection-foreground", color: palette.selectionForeground)

    section("token")
    write("foreground", color: palette.interfaceForeground)
    write("secondary", color: palette.secondaryForeground)
    write("tertiary", color: palette.tertiaryForeground)
    write("accent", color: palette.accent)
    write("radius", number: style.radius)
    if let fonts = style.fontFamilies, !fonts.isEmpty {
      lines.append("font-mono = [\(fonts.map { "\"\($0)\"" }.joined(separator: ", "))]")
    }
    if let bold = style.fontFamilyBold { write("font-mono-bold", string: bold) }
    if let italic = style.fontFamilyItalic { write("font-mono-italic", string: italic) }
    if let boldItalic = style.fontFamilyBoldItalic {
      write("font-mono-bold-italic", string: boldItalic)
    }

    if palette.interfaceWindowBackground != nil || palette.material != nil {
      section("window")
      write("background", color: palette.interfaceWindowBackground)
      write("material", material: palette.material)
    }

    section("panel")
    write("background", color: palette.panelBackground)
    write("surface", color: palette.panelSurface)
    write("border", color: palette.interfaceBorder)

    section("sidebar")
    write("background", color: style.sidebarBackground)
    write("border-right", border: style.sidebarBorderWidth, style.sidebarBorderColor)
    write("material", material: style.sidebarMaterial)
    write("padding", number: style.sidebarPadding)

    if style.titlebarBackground != nil || style.titlebarForeground != nil
      || style.titlebarMaterial != nil
    {
      section("titlebar")
      write("background", color: style.titlebarBackground)
      write("foreground", color: style.titlebarForeground)
      write("material", material: style.titlebarMaterial)
    }

    func writeTab(prefix: String, _ tab: TerminalTabStyle) {
      section(prefix)
      write("radius", number: tab.radius)
      write("height", number: tab.height)
      write("foreground", color: tab.foreground)
      if tab.hoverBackground != nil {
        section("\(prefix).hover")
        write("background", color: tab.hoverBackground)
      }
      section("\(prefix).active")
      write("background", color: tab.activeBackground)
      write("foreground", color: tab.activeForeground)
      write("border", border: tab.activeBorderWidth, tab.activeBorderColor)
      write("font-weight", number: Double(tab.activeFontWeight))
      write("shadow", shadow: tab.activeShadow)
    }
    writeTab(prefix: "tab", style.tab)

    if style.horizontalTabBarBackground != nil || style.horizontalTabBarMaterial != nil
      || style.horizontalTabBarBorderColor != nil || style.horizontalTabBarHeight != nil
    {
      section("tab-bar")
      write("background", color: style.horizontalTabBarBackground)
      write("material", material: style.horizontalTabBarMaterial)
      write("border-bottom", border: 1, style.horizontalTabBarBorderColor)
      write("height", number: style.horizontalTabBarHeight)
    }
    if let horizontal = style.horizontalTab {
      writeTab(prefix: "tab-bar.tab", horizontal)
    }

    section("container")
    write("background", color: style.container.background)
    write("radius", number: style.container.radius)
    write("margin", insets: style.container.margin)
    if let horizontalMargin = style.container.horizontalLayoutMargin {
      write("horizontal-margin", insets: horizontalMargin)
    }
    write("padding", insets: style.container.padding)
    write("border", border: style.container.borderWidth, style.container.borderColor)
    write("shadow", shadow: style.container.shadow)

    return lines.joined(separator: "\n") + "\n"
  }
}
