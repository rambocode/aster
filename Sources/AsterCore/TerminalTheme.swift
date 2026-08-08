import Foundation

public enum TerminalThemeMode: String, Codable, CaseIterable, Equatable, Sendable {
  case light
  case dark
}

/// Otty 主题可声明的原生窗口材质。该值保留在主题模型中，透明主题因此不会退化成纯色主题。
public enum TerminalThemeMaterial: String, Codable, Equatable, Sendable {
  case none
  case glass
  case vibrancyThin = "vibrancy-thin"
  case vibrancyRegular = "vibrancy-regular"
}

/// 与 Otty 四边数组顺序一致的布局内边距：top、leading、bottom、trailing。
public struct ThemeInsets: Codable, Equatable, Sendable {
  public var top: Double
  public var leading: Double
  public var bottom: Double
  public var trailing: Double

  public init(top: Double, leading: Double, bottom: Double, trailing: Double) {
    self.top = top
    self.leading = leading
    self.bottom = bottom
    self.trailing = trailing
  }

  public init(all value: Double) {
    self.init(top: value, leading: value, bottom: value, trailing: value)
  }

  public static let zero = ThemeInsets(all: 0)
}

/// Otty CSS 风格阴影的可序列化表示。AppKit 渲染时保留偏移、模糊与透明度。
public struct ThemeShadow: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var blur: Double
  public var color: HexColor

  public init(x: Double, y: Double, blur: Double, color: HexColor) {
    self.x = x
    self.y = y
    self.blur = blur
    self.color = color
  }
}

/// 标签行的完整交互样式。可选颜色表示沿用主题的角色色，而不是硬编码替代值。
public struct TerminalTabStyle: Codable, Equatable, Sendable {
  public var radius: Double
  public var height: Double?
  public var foreground: HexColor?
  public var hoverBackground: HexColor?
  public var activeBackground: HexColor?
  public var activeForeground: HexColor?
  public var activeBorderColor: HexColor?
  public var activeBorderWidth: Double
  public var activeFontWeight: Int
  public var activeShadow: ThemeShadow?

  public init(
    radius: Double = 6,
    height: Double? = nil,
    foreground: HexColor? = nil,
    hoverBackground: HexColor? = nil,
    activeBackground: HexColor? = nil,
    activeForeground: HexColor? = nil,
    activeBorderColor: HexColor? = nil,
    activeBorderWidth: Double = 0,
    activeFontWeight: Int = 600,
    activeShadow: ThemeShadow? = nil
  ) {
    self.radius = radius
    self.height = height
    self.foreground = foreground
    self.hoverBackground = hoverBackground
    self.activeBackground = activeBackground
    self.activeForeground = activeForeground
    self.activeBorderColor = activeBorderColor
    self.activeBorderWidth = activeBorderWidth
    self.activeFontWeight = activeFontWeight
    self.activeShadow = activeShadow
  }
}

/// 终端容器独立于终端色表的布局与装饰。该结构直接对应 Otty `[container]`。
public struct TerminalContainerStyle: Codable, Equatable, Sendable {
  public var background: HexColor?
  public var radius: Double
  public var margin: ThemeInsets
  /// 顶部或底部标签布局没有侧栏时，可用独立外边距保持 Otty 的对称留白。
  public var horizontalLayoutMargin: ThemeInsets?
  public var padding: ThemeInsets
  public var borderColor: HexColor?
  public var borderWidth: Double
  public var shadow: ThemeShadow?

  public init(
    background: HexColor? = nil,
    radius: Double = 0,
    margin: ThemeInsets = .zero,
    horizontalLayoutMargin: ThemeInsets? = nil,
    padding: ThemeInsets = ThemeInsets(all: 8),
    borderColor: HexColor? = nil,
    borderWidth: Double = 0,
    shadow: ThemeShadow? = nil
  ) {
    self.background = background
    self.radius = radius
    self.margin = margin
    self.horizontalLayoutMargin = horizontalLayoutMargin
    self.padding = padding
    self.borderColor = borderColor
    self.borderWidth = borderWidth
    self.shadow = shadow
  }
}

/// Otty 主题中颜色之外的界面真值。旧版 `.astertheme` 未保存这些字段时使用稳定默认值。
public struct TerminalThemeStyle: Codable, Equatable, Sendable {
  public var radius: Double
  /// Otty `[token].font-mono` 的候选顺序；空值表示使用全局或应用 fallback。
  public var fontFamilies: [String]?
  public var sidebarBackground: HexColor?
  public var sidebarBorderColor: HexColor?
  public var sidebarBorderWidth: Double
  public var sidebarMaterial: TerminalThemeMaterial?
  public var titlebarBackground: HexColor?
  public var titlebarForeground: HexColor?
  public var titlebarMaterial: TerminalThemeMaterial?
  public var tab: TerminalTabStyle
  public var horizontalTab: TerminalTabStyle?
  public var horizontalTabBarBackground: HexColor?
  public var horizontalTabBarMaterial: TerminalThemeMaterial?
  public var horizontalTabBarBorderColor: HexColor?
  public var horizontalTabBarHeight: Double?
  public var container: TerminalContainerStyle

  public init(
    radius: Double = 8,
    fontFamilies: [String]? = nil,
    sidebarBackground: HexColor? = nil,
    sidebarBorderColor: HexColor? = nil,
    sidebarBorderWidth: Double = 0,
    sidebarMaterial: TerminalThemeMaterial? = nil,
    titlebarBackground: HexColor? = nil,
    titlebarForeground: HexColor? = nil,
    titlebarMaterial: TerminalThemeMaterial? = nil,
    tab: TerminalTabStyle = TerminalTabStyle(),
    horizontalTab: TerminalTabStyle? = nil,
    horizontalTabBarBackground: HexColor? = nil,
    horizontalTabBarMaterial: TerminalThemeMaterial? = nil,
    horizontalTabBarBorderColor: HexColor? = nil,
    horizontalTabBarHeight: Double? = nil,
    container: TerminalContainerStyle = TerminalContainerStyle()
  ) {
    self.radius = radius
    self.fontFamilies = fontFamilies
    self.sidebarBackground = sidebarBackground
    self.sidebarBorderColor = sidebarBorderColor
    self.sidebarBorderWidth = sidebarBorderWidth
    self.sidebarMaterial = sidebarMaterial
    self.titlebarBackground = titlebarBackground
    self.titlebarForeground = titlebarForeground
    self.titlebarMaterial = titlebarMaterial
    self.tab = tab
    self.horizontalTab = horizontalTab
    self.horizontalTabBarBackground = horizontalTabBarBackground
    self.horizontalTabBarMaterial = horizontalTabBarMaterial
    self.horizontalTabBarBorderColor = horizontalTabBarBorderColor
    self.horizontalTabBarHeight = horizontalTabBarHeight
    self.container = container
  }
}

/// 同时驱动工作区界面与终端的主题颜色。ANSI 固定保存 16 色，前 8 个是标准色，
/// 后 8 个是高亮色，导入时必须完整提供，避免终端退回不可预测的系统默认值。
public struct TerminalThemePalette: Codable, Equatable, Sendable {
  /// 终端网格的背景色。透明主题使用 alpha 为 0 的颜色，不能被界面窗口底色替代。
  public var windowBackground: HexColor
  public var containerBackground: HexColor
  public var panelBackground: HexColor
  /// 终端字形前景色。界面文字可通过 `interfaceForeground` 单独覆盖。
  public var foreground: HexColor
  public var secondaryForeground: HexColor
  public var accent: HexColor
  public var cursor: HexColor
  public var selection: HexColor
  public var ansiColors: [HexColor]
  /// Otty 主题中独立于终端的界面令牌。均为可选字段，以兼容旧版 `.astertheme` 文件。
  public var interfaceWindowBackground: HexColor?
  public var interfaceForeground: HexColor?
  public var tertiaryForeground: HexColor?
  public var panelSurface: HexColor?
  public var interfaceBorder: HexColor?
  public var cursorText: HexColor?
  public var selectionForeground: HexColor?
  public var material: TerminalThemeMaterial?

  public init(
    windowBackground: HexColor,
    containerBackground: HexColor,
    panelBackground: HexColor,
    foreground: HexColor,
    secondaryForeground: HexColor,
    accent: HexColor,
    cursor: HexColor,
    selection: HexColor,
    ansiColors: [HexColor],
    interfaceWindowBackground: HexColor? = nil,
    interfaceForeground: HexColor? = nil,
    tertiaryForeground: HexColor? = nil,
    panelSurface: HexColor? = nil,
    interfaceBorder: HexColor? = nil,
    cursorText: HexColor? = nil,
    selectionForeground: HexColor? = nil,
    material: TerminalThemeMaterial? = nil
  ) {
    self.windowBackground = windowBackground
    self.containerBackground = containerBackground
    self.panelBackground = panelBackground
    self.foreground = foreground
    self.secondaryForeground = secondaryForeground
    self.accent = accent
    self.cursor = cursor
    self.selection = selection
    self.ansiColors = ansiColors
    self.interfaceWindowBackground = interfaceWindowBackground
    self.interfaceForeground = interfaceForeground
    self.tertiaryForeground = tertiaryForeground
    self.panelSurface = panelSurface
    self.interfaceBorder = interfaceBorder
    self.cursorText = cursorText
    self.selectionForeground = selectionForeground
    self.material = material
  }

  /// SwiftTerm 的终端颜色不保存 alpha。对于 Otty 的透明 `none` 背景，使用主题
  /// 自己的 surface（其次为 panel）作为预合成底色，避免透明黑退化为纯黑。
  public var renderedTerminalBackground: HexColor {
    windowBackground.alpha == 0 ? (panelSurface ?? panelBackground) : windowBackground
  }
}

public struct TerminalTheme: Identifiable, Codable, Equatable, Sendable {
  public var id: String
  public var name: String
  public var mode: TerminalThemeMode
  public var palette: TerminalThemePalette
  public var style: TerminalThemeStyle
  public var isBuiltIn: Bool

  public init(
    id: String,
    name: String,
    mode: TerminalThemeMode,
    palette: TerminalThemePalette,
    style: TerminalThemeStyle = TerminalThemeStyle(),
    isBuiltIn: Bool
  ) {
    self.id = id
    self.name = name
    self.mode = mode
    self.palette = palette
    self.style = style
    self.isBuiltIn = isBuiltIn
  }

  private enum CodingKeys: String, CodingKey {
    case id, name, mode, palette, style, isBuiltIn
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    name = try container.decode(String.self, forKey: .name)
    mode = try container.decode(TerminalThemeMode.self, forKey: .mode)
    palette = try container.decode(TerminalThemePalette.self, forKey: .palette)
    style = try container.decodeIfPresent(TerminalThemeStyle.self, forKey: .style)
      ?? TerminalThemeStyle()
    isBuiltIn = try container.decode(Bool.self, forKey: .isBuiltIn)
  }

  /// 复制内置或自定义主题时生成独立身份，后续编辑不会修改来源主题。
  public func duplicated(name: String? = nil) -> TerminalTheme {
    var result = self
    result.id = UUID().uuidString
    result.name = name ?? "\(self.name) 副本"
    result.isBuiltIn = false
    return result
  }
}

/// 用户主题集合的纯值模型。所有写入都会清除 `isBuiltIn`，并为重名主题生成可预测
/// 的序号后缀，避免导入或复制后选择器出现无法区分的条目。
public struct TerminalThemeLibrary: Codable, Equatable, Sendable {
  public private(set) var customThemes: [TerminalTheme]

  public init(customThemes: [TerminalTheme] = []) {
    self.customThemes = customThemes.filter { !$0.isBuiltIn }
  }

  @discardableResult
  public mutating func add(_ candidate: TerminalTheme) -> TerminalTheme {
    var theme = candidate
    theme.isBuiltIn = false
    let baseName = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
    var resolvedName = baseName
    var suffix = 2
    let existingNames = Set(customThemes.map(\.name) + TerminalThemeCatalog.builtIns.map(\.name))
    while existingNames.contains(resolvedName) {
      resolvedName = "\(baseName) \(suffix)"
      suffix += 1
    }
    theme.name = resolvedName
    if customThemes.contains(where: { $0.id == theme.id }) {
      theme.id = UUID().uuidString
    }
    customThemes.append(theme)
    return theme
  }

  @discardableResult
  public mutating func update(_ theme: TerminalTheme) -> Bool {
    guard !theme.isBuiltIn,
      (try? TerminalThemeStore.validate(theme)) != nil,
      !TerminalThemeCatalog.builtIns.contains(where: { $0.name == theme.name }),
      !customThemes.contains(where: { $0.id != theme.id && $0.name == theme.name }),
      let index = customThemes.firstIndex(where: { $0.id == theme.id })
    else {
      return false
    }
    customThemes[index] = theme
    return true
  }

  @discardableResult
  public mutating func remove(id: String) -> Bool {
    guard let index = customThemes.firstIndex(where: { $0.id == id }) else { return false }
    customThemes.remove(at: index)
    return true
  }
}

public enum TerminalThemeCatalog {
  /// 与 Otty 1.3.1 内置 `.ottytheme` 一一对应的 24 套主题。
  public static let builtIns: [TerminalTheme] = OttyBuiltInThemes.all

  public static func theme(named name: String) -> TerminalTheme? {
    builtIns.first { $0.name == name }
  }

  /// 按名称解析内置或用户主题。用户主题优先，便于导入后替换同名预设；选择失效时
  /// 回退到对应明暗模式的 Ayu 主题，保证界面始终具有完整可读的调色板。
  public static func resolve(
    named name: String,
    customThemes: [TerminalTheme],
    mode: TerminalThemeMode
  ) -> TerminalTheme {
    if let custom = customThemes.first(where: { $0.name == name && $0.mode == mode }) {
      return custom
    }
    if let builtIn = builtIns.first(where: { $0.name == name && $0.mode == mode }) {
      return builtIn
    }
    let fallbackName = mode == .dark ? "Ayu Dark" : "Ayu Light"
    return theme(named: fallbackName) ?? builtIns[0]
  }

}

public enum TerminalThemeStoreError: Error, Equatable {
  case invalidFileExtension
  case notRegularFile
  case fileTooLarge
  case invalidFormat(String)
  case invalidName
  case invalidIdentifier
  case invalidPalette
}

extension TerminalThemeStoreError: LocalizedError {
  public var errorDescription: String? {
    switch self {
    case .invalidFileExtension: "主题文件必须使用 .astertheme 或 .ottytheme 后缀。"
    case .notRegularFile: "主题必须是普通文件。"
    case .fileTooLarge: "主题文件超过 256 KiB。"
    case .invalidFormat(let message): message
    case .invalidName: "主题名称不能为空且不能超过 128 字节。"
    case .invalidIdentifier: "主题标识无效。"
    case .invalidPalette: "主题必须包含完整的 16 色 ANSI 调色板。"
    }
  }
}

public enum TerminalThemeStore {
  private static let maximumFileSize = 256 * 1_024

  public static func save(_ theme: TerminalTheme, to fileURL: URL) throws {
    guard fileURL.pathExtension.lowercased() == "astertheme" else {
      throw TerminalThemeStoreError.invalidFileExtension
    }
    try validate(theme)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(theme).write(to: fileURL, options: .atomic)
  }

  public static func load(from fileURL: URL) throws -> TerminalTheme {
    let fileExtension = fileURL.pathExtension.lowercased()
    guard fileExtension == "astertheme" || fileExtension == "ottytheme" else {
      throw TerminalThemeStoreError.invalidFileExtension
    }
    let values = try fileURL.resourceValues(forKeys: [
      .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey,
    ])
    guard values.isRegularFile == true, values.isSymbolicLink != true else {
      throw TerminalThemeStoreError.notRegularFile
    }
    guard (values.fileSize ?? 0) <= maximumFileSize else {
      throw TerminalThemeStoreError.fileTooLarge
    }
    let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
    guard data.count <= maximumFileSize else { throw TerminalThemeStoreError.fileTooLarge }
    var theme: TerminalTheme
    if fileExtension == "ottytheme" {
      theme = try OttyThemeParser.parse(
        data: data,
        sourceName: fileURL.deletingPathExtension().lastPathComponent
      )
    } else {
      theme = try JSONDecoder().decode(TerminalTheme.self, from: data)
    }
    theme.isBuiltIn = false
    try validate(theme)
    return theme
  }

  public static func validate(_ theme: TerminalTheme) throws {
    let name = theme.name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.utf8.count <= 128 else {
      throw TerminalThemeStoreError.invalidName
    }
    guard !theme.id.isEmpty, theme.id.utf8.count <= 128 else {
      throw TerminalThemeStoreError.invalidIdentifier
    }
    guard theme.palette.ansiColors.count == 16 else {
      throw TerminalThemeStoreError.invalidPalette
    }
  }
}
