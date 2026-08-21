import Foundation

/// 主题字体参数的稳定标识。字符串值同时作为持久化 key 与 Otty token 映射，新增角色时
/// 不需要迁移已有覆盖数据。
public enum ThemeFontRole: String, CaseIterable, Codable, Equatable, Sendable {
  case regular
  case bold
  case italic
  case boldItalic
}

/// 用户对某套主题的参数覆盖。
///
/// 改一个参数**不复制整套主题**：内置的 24 套是 Otty 的只读真值表，复制会让主题列表
/// 迅速被「One Light 副本」「One Light 副本 2」堆满，而且副本一旦生成就和上游脱钩，
/// 以后 Otty 更新了原主题也带不过来。覆盖层只记「用户显式改过的参数」，
/// 渲染时叠在原主题之上；清掉覆盖就完整回到原主题。
///
/// 主题文件末尾追加 `# aster-added:` 段落，写明被覆盖的键（沿用 Otty 的文件惯例，
/// 早期版本写的是 `# otty-added:`，整段由 marker 统一剥离，不会残留）。
public struct ThemeColorOverrides: Codable, Equatable, Sendable {
  /// key 是 `ThemeColorSlot.id`（如 `sidebar.background`）。
  public private(set) var colors: [String: HexColor]
  /// 只保存用户改过的 ANSI 色位；未出现的 index 继续继承原主题。
  public private(set) var ansiColors: [Int: HexColor]
  /// key 是 `ThemeFontRole.rawValue`。空数组表示显式取消主题字体参数，缺少 key 才表示
  /// 完全继承原主题；两种状态必须区分，才能表达“恢复自动匹配”。
  public private(set) var fontFamiliesByRole: [String: [String]]

  public init(
    colors: [String: HexColor] = [:],
    ansiColors: [Int: HexColor] = [:],
    fontFamiliesByRole: [String: [String]] = [:]
  ) {
    self.colors = colors
    self.ansiColors = ansiColors
    self.fontFamiliesByRole = fontFamiliesByRole
  }

  private enum CodingKeys: String, CodingKey {
    case colors
    case ansiColors
    case fontFamiliesByRole
  }

  /// 0.4.1 已经持久化过只有 `colors` 的对象。新增参数必须缺省为空，不能让旧数据块
  /// 因缺 key 解码失败后整库回到默认值。
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    colors = try container.decodeIfPresent([String: HexColor].self, forKey: .colors) ?? [:]
    ansiColors = try container.decodeIfPresent([Int: HexColor].self, forKey: .ansiColors) ?? [:]
    fontFamiliesByRole =
      try container.decodeIfPresent([String: [String]].self, forKey: .fontFamiliesByRole) ?? [:]
  }

  public var isEmpty: Bool {
    colors.isEmpty && ansiColors.isEmpty && fontFamiliesByRole.isEmpty
  }

  public subscript(slotID: String) -> HexColor? {
    get { colors[slotID] }
    set { colors[slotID] = newValue }
  }

  public mutating func set(_ color: HexColor, for slotID: String) {
    colors[slotID] = color
  }

  public mutating func clear(_ slotID: String) {
    colors.removeValue(forKey: slotID)
  }

  public mutating func setANSIColor(_ color: HexColor, at index: Int) {
    guard (0..<16).contains(index) else { return }
    ansiColors[index] = color
  }

  public mutating func clearANSIColor(at index: Int) {
    ansiColors.removeValue(forKey: index)
  }

  public func fontFamilies(for role: ThemeFontRole) -> [String]? {
    fontFamiliesByRole[role.rawValue]
  }

  /// `families` 可以为空，表示在当前主题上显式取消该逐样式字体参数。
  public mutating func setFontFamilies(_ families: [String], for role: ThemeFontRole) {
    fontFamiliesByRole[role.rawValue] = families
  }

  public mutating func clearFontFamilies(for role: ThemeFontRole) {
    fontFamiliesByRole.removeValue(forKey: role.rawValue)
  }
}

/// 按主题 ID 保存的覆盖表。内置主题与自定义主题共用一套结构。
public struct ThemeOverrideLibrary: Codable, Equatable, Sendable {
  public private(set) var overridesByThemeID: [String: ThemeColorOverrides]

  public init(overridesByThemeID: [String: ThemeColorOverrides] = [:]) {
    self.overridesByThemeID = overridesByThemeID
  }

  public func overrides(for themeID: String) -> ThemeColorOverrides {
    overridesByThemeID[themeID] ?? ThemeColorOverrides()
  }

  public mutating func setColor(_ color: HexColor, slotID: String, themeID: String) {
    var current = overrides(for: themeID)
    current.set(color, for: slotID)
    overridesByThemeID[themeID] = current
  }

  public mutating func clearColor(slotID: String, themeID: String) {
    var current = overrides(for: themeID)
    current.clear(slotID)
    store(current, themeID: themeID)
  }

  public mutating func setANSIColor(_ color: HexColor, index: Int, themeID: String) {
    var current = overrides(for: themeID)
    current.setANSIColor(color, at: index)
    overridesByThemeID[themeID] = current
  }

  public mutating func clearANSIColor(index: Int, themeID: String) {
    var current = overrides(for: themeID)
    current.clearANSIColor(at: index)
    store(current, themeID: themeID)
  }

  public mutating func setFontFamilies(
    _ families: [String], role: ThemeFontRole, themeID: String
  ) {
    var current = overrides(for: themeID)
    current.setFontFamilies(families, for: role)
    overridesByThemeID[themeID] = current
  }

  public mutating func clearFontFamilies(role: ThemeFontRole, themeID: String) {
    var current = overrides(for: themeID)
    current.clearFontFamilies(for: role)
    store(current, themeID: themeID)
  }

  public mutating func clearAll(themeID: String) {
    overridesByThemeID.removeValue(forKey: themeID)
  }

  private mutating func store(_ overrides: ThemeColorOverrides, themeID: String) {
    if overrides.isEmpty {
      overridesByThemeID.removeValue(forKey: themeID)
    } else {
      overridesByThemeID[themeID] = overrides
    }
  }
}

extension TerminalTheme {
  /// 把用户覆盖叠到主题上。顺序固定，结果只取决于覆盖表内容，不受调用次数影响。
  public func applyingOverrides(_ overrides: ThemeColorOverrides) -> TerminalTheme {
    guard !overrides.isEmpty else { return self }
    // 按 key 排序保证确定性：字典遍历顺序不稳定，而部分 slot 写的是同一个字段
    // （例如 sidebar.foreground 与 interface.foreground），顺序不定会让结果抖动。
    var resolved = overrides.colors.sorted { $0.key < $1.key }.reduce(self) { theme, entry in
      theme.applyingColor(entry.value, toSlot: entry.key)
    }
    for (index, color) in overrides.ansiColors.sorted(by: { $0.key < $1.key })
    where resolved.palette.ansiColors.indices.contains(index) {
      resolved.palette.ansiColors[index] = color
    }
    for role in ThemeFontRole.allCases {
      guard let families = overrides.fontFamilies(for: role) else { continue }
      switch role {
      case .regular: resolved.style.fontFamilies = families.isEmpty ? nil : families
      case .bold: resolved.style.fontFamilyBold = families.first
      case .italic: resolved.style.fontFamilyItalic = families.first
      case .boldItalic: resolved.style.fontFamilyBoldItalic = families.first
      }
    }
    return resolved
  }

  /// 覆盖层序列化成 Otty `.ottytheme` 追加段。
  ///
  /// 每个键都带 `# aster-added:` 注释：用户直接打开主题文件时能一眼看出哪些行是
  /// Aster 写进去的、哪些是原主题自带的，手工删掉注释下面那行就等于撤销覆盖。
  public func themeOverrideSection(_ overrides: ThemeColorOverrides) -> String {
    guard !overrides.isEmpty else { return "" }
    var sections: [String: [String]] = [:]
    var sectionOrder: [String] = []
    for (slotID, color) in overrides.colors.sorted(by: { $0.key < $1.key }) {
      guard let mapping = ThemeFileKeyMap.entry(for: slotID) else { continue }
      if sections[mapping.section] == nil { sectionOrder.append(mapping.section) }
      sections[mapping.section, default: []]
        .append("# aster-added: \(mapping.section).\(mapping.key)")
      sections[mapping.section]?.append("\(mapping.key) = \"\(color.displayString)\"")
    }

    let resolved = applyingOverrides(overrides)
    if !overrides.ansiColors.isEmpty {
      if sections["terminal"] == nil { sectionOrder.append("terminal") }
      let palette = resolved.palette.ansiColors.map { "\"\($0.displayString)\"" }
        .joined(separator: ", ")
      sections["terminal", default: []].append("# aster-added: terminal.palette")
      sections["terminal"]?.append("palette = [\(palette)]")
    }

    let fontKey: [ThemeFontRole: String] = [
      .regular: "font-mono",
      .bold: "font-mono-bold",
      .italic: "font-mono-italic",
      .boldItalic: "font-mono-bold-italic",
    ]
    for role in ThemeFontRole.allCases {
      guard overrides.fontFamilies(for: role) != nil, let key = fontKey[role] else { continue }
      if sections["token"] == nil { sectionOrder.append("token") }
      let families: [String] =
        switch role {
        case .regular: resolved.style.fontFamilies ?? []
        case .bold: resolved.style.fontFamilyBold.map { [$0] } ?? []
        case .italic: resolved.style.fontFamilyItalic.map { [$0] } ?? []
        case .boldItalic: resolved.style.fontFamilyBoldItalic.map { [$0] } ?? []
        }
      let value = families.map { "\"\(Self.escapeTOMLString($0))\"" }.joined(separator: ", ")
      sections["token", default: []].append("# aster-added: token.\(key)")
      sections["token"]?.append("\(key) = [\(value)]")
    }

    guard !sectionOrder.isEmpty else { return "" }
    return sectionOrder.map { section in
      (["[\(section)]"] + (sections[section] ?? [])).joined(separator: "\n")
    }.joined(separator: "\n\n")
  }

  private static func escapeTOMLString(_ value: String) -> String {
    value.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "\"", with: "\\\"")
  }
}

/// slot id ↔ Otty 主题文件里的 `[section] key`。
///
/// 只映射 Otty 真的有的键；`interface.*` 这类 Aster 自己的界面 token 没有对应写法，
/// 写进文件反而会让 Otty 解析出未知键，因此这里返回 nil、只留在应用内的覆盖表里。
public enum ThemeFileKeyMap {
  public struct Entry: Equatable, Sendable {
    public let section: String
    public let key: String
  }

  private static let table: [String: Entry] = [
    "terminal.foreground": Entry(section: "terminal", key: "foreground"),
    "terminal.background": Entry(section: "terminal", key: "background"),
    "interface.window": Entry(section: "window", key: "background"),
    "container.background": Entry(section: "container", key: "background"),
    "container.border": Entry(section: "container", key: "border-color"),
    "panel.background": Entry(section: "panel", key: "background"),
    "panel.surface": Entry(section: "panel", key: "surface"),
    "sidebar.background": Entry(section: "sidebar", key: "background"),
    "sidebar.border": Entry(section: "sidebar", key: "border-color"),
    "titlebar.background": Entry(section: "titlebar", key: "background"),
    "titlebar.foreground": Entry(section: "titlebar", key: "foreground"),
    "tabbar.background": Entry(section: "tab-bar", key: "background"),
    "tabbar.border": Entry(section: "tab-bar", key: "border-color"),
    "tab.foreground": Entry(section: "tab", key: "foreground"),
    "tab.hoverBackground": Entry(section: "tab", key: "hover-background"),
    "tab.activeBackground": Entry(section: "tab", key: "active-background"),
    "tab.activeForeground": Entry(section: "tab", key: "active-foreground"),
    "tab.activeBorderColor": Entry(section: "tab", key: "active-border-color"),
    "cursor.background": Entry(section: "terminal", key: "cursor"),
    "cursor.foreground": Entry(section: "terminal", key: "cursor-text"),
    "selection.background": Entry(section: "terminal", key: "selection"),
    "selection.foreground": Entry(section: "terminal", key: "selection-text"),
  ]

  public static func entry(for slotID: String) -> Entry? { table[slotID] }
}

/// 主题文件里「Aster 追加段落」的读写规则。
///
/// 追加段整体由一行 marker 起头，重写时先按 marker 截断——否则每保存一次就会在
/// 文件尾部再堆一份同样的键，几轮之后主题文件里全是重复段落。
public enum ThemeOverrideFileWriter {
  public static let marker = "# --- aster overrides (managed) ---"

  /// 去掉上一轮写入的追加段，返回主题本体。没有 marker 时原样返回。
  public static func strippingPreviousOverrides(from content: String) -> String {
    guard let range = content.range(of: marker) else { return content }
    return String(content[content.startIndex..<range.lowerBound])
  }
}
