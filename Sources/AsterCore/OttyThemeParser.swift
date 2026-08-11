import Foundation

/// Otty `.ottytheme` 的受限 TOML 读取器。
///
/// 主题格式只需要 section、`key = value`、字符串、数字和数组；刻意不实现完整 TOML，
/// 避免为导入主题引入解析器依赖。未知键会保留向前兼容，已知键若类型不合法则回退到
/// 安全默认值，最终仍由 `TerminalThemeStore.validate` 校验名称、身份和 ANSI 16 色。
enum OttyThemeParser {
  static func parse(data: Data, sourceName: String) throws -> TerminalTheme {
    guard let source = String(data: data, encoding: .utf8) else {
      throw TerminalThemeStoreError.invalidFormat("主题文件不是有效的 UTF-8。")
    }
    let document = try OttyThemeDocument(source: source)
    let name = document.string("meta.name")?.trimmingCharacters(in: .whitespacesAndNewlines)
      ?? sourceName
    let foreground = document.color("terminal.foreground") ?? HexColor("#D0D0D0")!
    let background = document.color("terminal.background") ?? HexColor("#101010")!
    let ansi = document.colors("terminal.palette")
    let panel = document.color("panel.background") ?? background
    let surface = document.color("panel.surface") ?? panel
    let mode = try resolvedMode(
      document.string("meta.mode"),
      visualBackground: background.alpha == 0 ? surface : background)
    let container = document.color("container.background") ?? background
    let interfaceForeground = document.color("token.foreground") ?? foreground
    let secondary = document.color("token.secondary") ?? interfaceForeground
    let accent = document.color("token.accent") ?? ansi.dropFirst(4).first ?? foreground
    let material = document.material("window.material")
    let cursor = document.color("terminal.cursor") ?? foreground
    let cursorText = document.color("terminal.cursor-text") ?? background
    let selection = document.color("terminal.selection-background")
      ?? HexColor(red: foreground.red, green: foreground.green, blue: foreground.blue, alpha: 77)
    let selectionForeground = document.color("terminal.selection-foreground") ?? background

    let theme = TerminalTheme(
      id: "otty-\(slug(sourceName))-\(stableIdentifier(data))",
      name: name,
      mode: mode,
      palette: TerminalThemePalette(
        windowBackground: background,
        containerBackground: container,
        panelBackground: panel,
        foreground: foreground,
        secondaryForeground: secondary,
        accent: accent,
        cursor: cursor,
        selection: selection,
        ansiColors: ansi,
        interfaceWindowBackground: document.color("window.background"),
        interfaceForeground: interfaceForeground,
        tertiaryForeground: document.color("token.tertiary"),
        panelSurface: surface,
        interfaceBorder: document.color("panel.border"),
        cursorText: cursorText,
        selectionForeground: selectionForeground,
        material: material
      ),
      style: makeStyle(document),
      isBuiltIn: false
    )
    return theme
  }

  private static func makeStyle(_ document: OttyThemeDocument) -> TerminalThemeStyle {
    let sidebarBorder = document.border("sidebar.border-right")
    let activeBorder = document.border("tab.active.border")
    let containerBorder = document.border("container.border")
    let tabBarBorder = document.border("tab-bar.border-bottom")
    let tab = TerminalTabStyle(
      radius: document.number("tab.radius", in: 0...128) ?? 6,
      height: document.number("tab.height", in: 0...256),
      foreground: document.color("tab.foreground"),
      hoverBackground: document.color("tab.hover.background"),
      activeBackground: document.color("tab.active.background"),
      activeForeground: document.color("tab.active.foreground"),
      activeBorderColor: activeBorder.color,
      activeBorderWidth: activeBorder.width,
      activeFontWeight: document.fontWeight("tab.active.font-weight", default: 600),
      activeShadow: document.shadow("tab.active.shadow")
    )
    return TerminalThemeStyle(
      radius: document.number("token.radius", in: 0...128) ?? 8,
      fontFamilies: document.strings("token.font-mono"),
      // 逐样式字体是单值键;写成栈时取首项,与 font-mono 的解析语义保持一致。
      fontFamilyBold: document.strings("token.font-mono-bold")?.first,
      fontFamilyItalic: document.strings("token.font-mono-italic")?.first,
      fontFamilyBoldItalic: document.strings("token.font-mono-bold-italic")?.first,
      sidebarBackground: document.color("sidebar.background"),
      sidebarBorderColor: sidebarBorder.color,
      sidebarBorderWidth: sidebarBorder.width,
      sidebarMaterial: document.material("sidebar.material"),
      titlebarBackground: document.color("titlebar.background"),
      titlebarForeground: document.color("titlebar.foreground"),
      titlebarMaterial: document.material("titlebar.material"),
      tab: tab,
      horizontalTab: horizontalTabStyle(document, inheriting: tab),
      horizontalTabBarBackground: document.color("tab-bar.background"),
      horizontalTabBarMaterial: document.material("tab-bar.material"),
      horizontalTabBarBorderColor: tabBarBorder.color,
      horizontalTabBarHeight: document.number("tab-bar.height", in: 0...256),
      container: TerminalContainerStyle(
        background: document.color("container.background"),
        radius: document.number("container.radius", in: 0...128) ?? 0,
        margin: document.insets("container.margin") ?? .zero,
        horizontalLayoutMargin: document.insets("container.horizontal-margin"),
        padding: document.insets("container.padding") ?? ThemeInsets(all: 8),
        borderColor: containerBorder.color,
        borderWidth: containerBorder.width,
        shadow: document.shadow("container.shadow")
      )
    )
  }

  private static func horizontalTabStyle(
    _ document: OttyThemeDocument,
    inheriting base: TerminalTabStyle
  ) -> TerminalTabStyle? {
    let prefix = "tab-bar.tab"
    guard document.contains(prefix: prefix) else { return nil }
    let borderKey = "\(prefix).active.border"
    let shadowKey = "\(prefix).active.shadow"
    let border = document.border(borderKey)
    return TerminalTabStyle(
      radius: document.number("\(prefix).radius", in: 0...128) ?? base.radius,
      height: document.number("\(prefix).height", in: 0...256) ?? base.height,
      foreground: document.color("\(prefix).foreground") ?? base.foreground,
      hoverBackground: document.color("\(prefix).hover.background") ?? base.hoverBackground,
      activeBackground: document.color("\(prefix).active.background") ?? base.activeBackground,
      activeForeground: document.color("\(prefix).active.foreground") ?? base.activeForeground,
      activeBorderColor: document.hasValue(borderKey) ? border.color : base.activeBorderColor,
      activeBorderWidth: document.hasValue(borderKey) ? border.width : base.activeBorderWidth,
      activeFontWeight: document.fontWeight(
        "\(prefix).active.font-weight", default: base.activeFontWeight),
      activeShadow: document.hasValue(shadowKey) ? document.shadow(shadowKey) : base.activeShadow
    )
  }

  private static func resolvedMode(
    _ declaredMode: String?,
    visualBackground: HexColor
  ) throws -> TerminalThemeMode {
    if let declaredMode {
      switch declaredMode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
      case "light": return .light
      case "dark": return .dark
      default:
        throw TerminalThemeStoreError.invalidFormat("主题 meta.mode 必须是 light 或 dark。")
      }
    }
    func linear(_ value: UInt8) -> Double {
      let component = Double(value) / 255
      return component <= 0.04045
        ? component / 12.92
        : pow((component + 0.055) / 1.055, 2.4)
    }
    let luminance = 0.2126 * linear(visualBackground.red)
      + 0.7152 * linear(visualBackground.green)
      + 0.0722 * linear(visualBackground.blue)
    return luminance >= 0.5 ? .light : .dark
  }

  private static func slug(_ value: String) -> String {
    let result = value.lowercased().unicodeScalars.map { scalar -> Character in
      CharacterSet.alphanumerics.contains(scalar) ? Character(String(scalar)) : "-"
    }
    return String(result).split(separator: "-").joined(separator: "-").prefix(64).description
  }

  /// FNV-1a 只用于生成稳定的本地主题身份，不承担安全校验或内容认证。
  private static func stableIdentifier(_ data: Data) -> String {
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in data {
      hash ^= UInt64(byte)
      hash &*= 0x100000001b3
    }
    return String(hash, radix: 16)
  }
}

private struct OttyThemeDocument {
  private let values: [String: String]

  init(source: String) throws {
    var parsed: [String: String] = [:]
    var section = ""
    var pending = ""
    var bracketDepth = 0

    for rawLine in source.split(omittingEmptySubsequences: false, whereSeparator: \Character.isNewline) {
      let line = Self.strippingComment(String(rawLine)).trimmingCharacters(in: .whitespaces)
      if line.isEmpty { continue }
      if pending.isEmpty, line.hasPrefix("["), line.hasSuffix("]") {
        section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        continue
      }
      pending += pending.isEmpty ? line : " " + line
      bracketDepth += Self.bracketDelta(line)
      guard bracketDepth >= 0 else {
        throw TerminalThemeStoreError.invalidFormat("主题包含未配对的数组闭括号。")
      }
      if bracketDepth > 0 { continue }
      guard let equal = pending.firstIndex(of: "=") else {
        throw TerminalThemeStoreError.invalidFormat("主题包含无法识别的设置行。")
      }
      let key = pending[..<equal].trimmingCharacters(in: .whitespaces)
      let value = pending[pending.index(after: equal)...].trimmingCharacters(in: .whitespaces)
      guard !key.isEmpty else {
        throw TerminalThemeStoreError.invalidFormat("主题包含空设置名。")
      }
      parsed[section.isEmpty ? key : "\(section).\(key)"] = value
      pending = ""
      bracketDepth = 0
    }
    guard pending.isEmpty, bracketDepth == 0 else {
      throw TerminalThemeStoreError.invalidFormat("主题包含未闭合的数组。")
    }
    values = parsed
  }

  func contains(prefix: String) -> Bool {
    values.keys.contains { $0 == prefix || $0.hasPrefix(prefix + ".") }
  }

  func hasValue(_ key: String) -> Bool {
    values[key] != nil
  }

  func string(_ key: String) -> String? {
    guard let raw = values[key] else { return nil }
    return Self.unquoted(raw)
  }

  func strings(_ key: String) -> [String]? {
    guard let raw = values[key] else { return nil }
    if raw.hasPrefix("["), raw.hasSuffix("]") {
      let result = Self.quotedValues(raw)
      return result.isEmpty ? nil : result
    }
    let result = Self.unquoted(raw)
    return result.isEmpty ? nil : [result]
  }

  func number(_ key: String, in range: ClosedRange<Double>? = nil) -> Double? {
    guard let raw = values[key] else { return nil }
    guard let value = Double(Self.unquoted(raw)), value.isFinite else { return nil }
    guard let range else { return value }
    return min(max(value, range.lowerBound), range.upperBound)
  }

  /// 外部主题的字体权重先约束到 CSS 可用范围，再转换为整数，避免 NaN、Infinity
  /// 或超大 Double 在 `Int` 初始化时触发不可恢复的运行时 trap。
  func fontWeight(_ key: String, default defaultValue: Int) -> Int {
    let value = number(key, in: 1...1000) ?? Double(defaultValue)
    return Int(value.rounded())
  }

  func colors(_ key: String) -> [HexColor] {
    guard let raw = values[key], raw.hasPrefix("["), raw.hasSuffix("]") else { return [] }
    return Self.quotedValues(raw).compactMap(Self.color)
  }

  func color(_ key: String) -> HexColor? {
    guard let value = string(key) else { return nil }
    return Self.color(value)
  }

  func material(_ key: String) -> TerminalThemeMaterial? {
    guard let value = string(key) else { return nil }
    return TerminalThemeMaterial(rawValue: value)
  }

  func insets(_ key: String) -> ThemeInsets? {
    guard let raw = values[key] else { return nil }
    if raw.hasPrefix("["), raw.hasSuffix("]") {
      let numbers = raw.dropFirst().dropLast().split(separator: ",").compactMap {
        Double($0.trimmingCharacters(in: .whitespaces))
      }
      guard numbers.count == 4, numbers.allSatisfy(\.isFinite) else { return nil }
      let safe = numbers.map { min(max($0, -256), 256) }
      return ThemeInsets(top: safe[0], leading: safe[1], bottom: safe[2], trailing: safe[3])
    }
    guard let scalar = Double(Self.unquoted(raw)), scalar.isFinite else { return nil }
    return ThemeInsets(all: min(max(scalar, -256), 256))
  }

  func border(_ key: String) -> (width: Double, color: HexColor?) {
    guard let raw = string(key), raw != "none" else { return (0, nil) }
    let components = raw.split(whereSeparator: \Character.isWhitespace)
    let parsedWidth = components.first.flatMap {
      Double($0.replacingOccurrences(of: "px", with: ""))
    }
    let width = parsedWidth.flatMap { value in
      value.isFinite ? min(max(value, 0), 32) : nil
    } ?? 0
    let color = components.reversed().lazy.compactMap { Self.color(String($0)) }.first
      ?? Self.color(raw)
    return (width, color)
  }

  func shadow(_ key: String) -> ThemeShadow? {
    guard let raw = string(key), raw != "none" else { return nil }
    let pattern = #"^\s*(-?[0-9.]+)(?:px)?\s+(-?[0-9.]+)(?:px)?\s+([0-9.]+)(?:px)?\s+(.+?)\s*$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: raw, range: NSRange(raw.startIndex..., in: raw)),
      match.numberOfRanges == 5,
      let xRange = Range(match.range(at: 1), in: raw),
      let yRange = Range(match.range(at: 2), in: raw),
      let blurRange = Range(match.range(at: 3), in: raw),
      let colorRange = Range(match.range(at: 4), in: raw),
      let x = Double(raw[xRange]), let y = Double(raw[yRange]), let blur = Double(raw[blurRange]),
      x.isFinite, y.isFinite, blur.isFinite,
      let color = Self.color(String(raw[colorRange]))
    else { return nil }
    return ThemeShadow(
      x: min(max(x, -256), 256),
      y: min(max(y, -256), 256),
      blur: min(max(blur, 0), 256),
      color: color)
  }

  private static func strippingComment(_ value: String) -> String {
    var inString = false
    var escaped = false
    for index in value.indices {
      let character = value[index]
      if character == "\\", inString { escaped.toggle(); continue }
      if character == "\"", !escaped { inString.toggle() }
      if character == "#", !inString { return String(value[..<index]) }
      escaped = false
    }
    return value
  }

  private static func bracketDelta(_ value: String) -> Int {
    var inString = false
    var escaped = false
    var result = 0
    for character in value {
      if escaped {
        escaped = false
        continue
      }
      if character == "\\", inString {
        escaped = true
        continue
      }
      if character == "\"" {
        inString.toggle()
        continue
      }
      if !inString, character == "[" { result += 1 }
      if !inString, character == "]" { result -= 1 }
    }
    return result
  }

  private static func unquoted(_ value: String) -> String {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= 2, trimmed.first == "\"", trimmed.last == "\"" else {
      return trimmed
    }
    return String(trimmed.dropFirst().dropLast())
  }

  private static func quotedValues(_ value: String) -> [String] {
    let pattern = #"\"([^\"]*)\""#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: value, range: NSRange(value.startIndex..., in: value)).compactMap {
      guard let range = Range($0.range(at: 1), in: value) else { return nil }
      return String(value[range])
    }
  }

  private static func color(_ value: String) -> HexColor? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
    if normalized == "none" { return HexColor(red: 0, green: 0, blue: 0, alpha: 0) }
    if let hex = HexColor(normalized) { return hex }
    let pattern = #"^rgba\(\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)\s*,\s*([0-9.]+)\s*\)$"#
    guard let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(in: normalized, range: NSRange(normalized.startIndex..., in: normalized)),
      match.numberOfRanges == 5
    else { return nil }
    let values = (1...4).compactMap { index -> Double? in
      guard let range = Range(match.range(at: index), in: normalized) else { return nil }
      return Double(normalized[range])
    }
    guard values.count == 4, values[0...2].allSatisfy({ (0...255).contains($0) }),
      (0...1).contains(values[3])
    else { return nil }
    return HexColor(
      red: UInt8(values[0].rounded()),
      green: UInt8(values[1].rounded()),
      blue: UInt8(values[2].rounded()),
      alpha: UInt8((values[3] * 255).rounded())
    )
  }
}
