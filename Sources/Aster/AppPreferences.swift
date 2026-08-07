import AppKit
import AsterCore
import Combine
import Foundation

/// 九类设置共享的持久化配置入口。领域配置以单个 JSON 数据块保存，确保 Recipe、
/// 主题和布局字段可以原子迁移；AppKit 控制器通过 Combine 订阅变化并刷新原生控件。
@MainActor
final class AppPreferences: ObservableObject {
  enum Appearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }
    var label: String {
      switch self {
      case .system: "跟随系统"
      case .light: "浅色"
      case .dark: "深色"
      }
    }
  }

  @Published var appearance: Appearance {
    didSet {
      defaults.set(appearance.rawValue, forKey: Keys.appearance)
      synchronizeThemeRuntime()
    }
  }

  @Published var configuration: AsterConfiguration {
    didSet {
      persistConfiguration()
      synchronizeThemeRuntime()
    }
  }

  @Published private(set) var themeLibrary: TerminalThemeLibrary {
    didSet {
      persistThemeLibrary()
      synchronizeThemeRuntime()
    }
  }

  @Published var sidebarTabGrouping: SidebarTabGrouping {
    didSet { defaults.set(sidebarTabGrouping.rawValue, forKey: Keys.sidebarTabGrouping) }
  }

  @Published var sidebarTabOrder: SidebarTabOrder {
    didSet { defaults.set(sidebarTabOrder.rawValue, forKey: Keys.sidebarTabOrder) }
  }

  private let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    appearance = Appearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system
    if let data = defaults.data(forKey: Keys.configuration),
      let decoded = try? JSONDecoder().decode(AsterConfiguration.self, from: data)
    {
      configuration = decoded.normalized()
    } else {
      configuration = .default
    }
    if let data = defaults.data(forKey: Keys.themeLibrary),
      let decoded = try? JSONDecoder().decode(TerminalThemeLibrary.self, from: data)
    {
      themeLibrary = decoded
    } else {
      themeLibrary = TerminalThemeLibrary()
    }
    sidebarTabGrouping =
      SidebarTabGrouping(rawValue: defaults.string(forKey: Keys.sidebarTabGrouping) ?? "") ?? .none
    sidebarTabOrder =
      SidebarTabOrder(rawValue: defaults.string(forKey: Keys.sidebarTabOrder) ?? "") ?? .createdTime
    migrateLegacySidebarWidth()
    migrateMissingThemeSelections()
    synchronizeThemeRuntime()
  }

  var preferredAppearance: NSAppearance? {
    switch appearance {
    case .system: nil
    case .light: NSAppearance(named: .aqua)
    case .dark: NSAppearance(named: .darkAqua)
    }
  }

  var fontSize: Double {
    get { configuration.appearance.fontSize }
    set { configuration.appearance.fontSize = min(max(newValue, 9), 32) }
  }

  var sidebarWidth: Double {
    get { configuration.appearance.sidebarWidth }
    set { configuration.appearance.sidebarWidth = min(max(newValue, 180), 360) }
  }

  var showStatusBar: Bool {
    get { configuration.appearance.showStatusBar }
    set { configuration.appearance.showStatusBar = newValue }
  }

  var tabBarLayout: TabBarLayout {
    get { configuration.tabBarLayout }
    set { configuration.tabBarLayout = newValue }
  }

  var optionAsMeta: Bool { configuration.controls.optionAsMeta }
  var allowMouseReporting: Bool { configuration.controls.allowMouseReporting }
  var terminalIdentity: String { configuration.appearance.terminalIdentity }

  var terminalFont: NSFont {
    NSFont(name: configuration.appearance.fontFamily, size: fontSize)
      ?? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
  }

  var terminalForegroundColor: NSColor {
    NSColor(activeTheme.palette.foreground)
  }

  var terminalBackgroundColor: NSColor {
    NSColor(activeTheme.palette.renderedTerminalBackground)
  }

  var cursorColor: NSColor { NSColor(activeTheme.palette.cursor) }
  var cursorTextColor: NSColor {
    NSColor(activeTheme.palette.cursorText ?? activeTheme.palette.windowBackground)
  }
  var selectionColor: NSColor { NSColor(activeTheme.palette.selection) }
  var selectionForegroundColor: NSColor {
    NSColor(activeTheme.palette.selectionForeground ?? activeTheme.palette.windowBackground)
  }
  var ansiColors: [HexColor] { activeTheme.palette.ansiColors }

  var lightTheme: TerminalTheme {
    TerminalThemeCatalog.resolve(
      named: configuration.appearance.themeName,
      customThemes: themeLibrary.customThemes,
      mode: .light
    )
  }

  var darkTheme: TerminalTheme {
    TerminalThemeCatalog.resolve(
      named: configuration.appearance.darkThemeName,
      customThemes: themeLibrary.customThemes,
      mode: .dark
    )
  }

  var activeTheme: TerminalTheme {
    if usesDarkAppearance {
      return configuration.appearance.useSeparateDarkTheme ? darkTheme : lightTheme
    }
    return lightTheme
  }

  func themes(for mode: TerminalThemeMode) -> [TerminalTheme] {
    (TerminalThemeCatalog.builtIns + themeLibrary.customThemes).filter { $0.mode == mode }
  }

  func selectTheme(_ theme: TerminalTheme) {
    if theme.mode == .dark {
      configuration.appearance.darkThemeName = theme.name
    } else {
      configuration.appearance.themeName = theme.name
    }
  }

  @discardableResult
  func duplicateTheme(_ source: TerminalTheme) -> TerminalTheme {
    var library = themeLibrary
    let duplicate = library.add(source.duplicated())
    themeLibrary = library
    selectTheme(duplicate)
    return duplicate
  }

  @discardableResult
  func updateTheme(_ theme: TerminalTheme) -> Bool {
    guard !theme.isBuiltIn,
      let previous = themeLibrary.customThemes.first(where: { $0.id == theme.id })
    else { return false }
    let wasSelectedAsLight = configuration.appearance.themeName == previous.name
    let wasSelectedAsDark = configuration.appearance.darkThemeName == previous.name
    var library = themeLibrary
    guard library.update(theme) else { return false }
    themeLibrary = library
    if previous.mode == theme.mode {
      if wasSelectedAsLight { configuration.appearance.themeName = theme.name }
      if wasSelectedAsDark { configuration.appearance.darkThemeName = theme.name }
    } else {
      if wasSelectedAsLight { configuration.appearance.themeName = "Ayu Light" }
      if wasSelectedAsDark { configuration.appearance.darkThemeName = "Ayu Dark" }
      selectTheme(theme)
    }
    return true
  }

  @discardableResult
  func importTheme(from url: URL) throws -> TerminalTheme {
    let imported = try TerminalThemeStore.load(from: url)
    var library = themeLibrary
    let stored = library.add(imported)
    themeLibrary = library
    selectTheme(stored)
    return stored
  }

  func saveThemeToLibraryFolder(_ theme: TerminalTheme) throws -> URL {
    let directory = try themesDirectory()
    let safeName = theme.name.replacingOccurrences(
      of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
    let url = directory.appendingPathComponent(safeName).appendingPathExtension("astertheme")
    try TerminalThemeStore.save(theme, to: url)
    return url
  }

  func themesDirectory() throws -> URL {
    let base = try FileManager.default.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let directory = base.appendingPathComponent("Aster/Themes", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }

  func reset() {
    configuration = .default
    appearance = .system
  }

  func importConfiguration(_ candidate: AsterConfiguration) {
    var imported = candidate.normalized()
    // “始终允许”属于这台 Mac 上由用户亲自确认的安全状态，不能随 JSON 导入；否则
    // 第三方配置文件可预置 scheme 授权并绕过首次警告。
    imported.controls.allowedNonStandardLinkSchemes = []
    configuration = imported
  }

  private var usesDarkAppearance: Bool {
    switch appearance {
    case .light: false
    case .dark: true
    case .system:
      NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
  }

  private func persistConfiguration() {
    guard let data = try? JSONEncoder().encode(configuration) else { return }
    defaults.set(data, forKey: Keys.configuration)
  }

  private func persistThemeLibrary() {
    guard let data = try? JSONEncoder().encode(themeLibrary) else { return }
    defaults.set(data, forKey: Keys.themeLibrary)
  }

  private func migrateMissingThemeSelections() {
    // Otty 1.3.1 使用完整名称。保留旧选择的意图，避免升级后静默回退到 Ayu Dark。
    if configuration.appearance.darkThemeName == "Catppuccin" {
      configuration.appearance.darkThemeName = "Catppuccin Mocha"
    }
    let names = Set((TerminalThemeCatalog.builtIns + themeLibrary.customThemes).map(\.name))
    if !names.contains(configuration.appearance.themeName) {
      configuration.appearance.themeName = "Ayu Light"
    }
    if !names.contains(configuration.appearance.darkThemeName) {
      configuration.appearance.darkThemeName = "Ayu Dark"
    }
  }

  /// 0.4.0 的 AppKit 初版默认 250pt，使 Otty 的窄侧栏在常用窗口尺寸下显得过宽。
  /// 只迁移仍等于旧默认值的配置；用户主动调整过的其他宽度保持不变。
  private func migrateLegacySidebarWidth() {
    guard !defaults.bool(forKey: Keys.compactSidebarMigration) else { return }
    defaults.set(true, forKey: Keys.compactSidebarMigration)
    if abs(configuration.appearance.sidebarWidth - 250) < 0.5 {
      configuration.appearance.sidebarWidth = 220
    }
  }

  private func synchronizeThemeRuntime() {
    let darkPalette =
      configuration.appearance.useSeparateDarkTheme ? darkTheme.palette : lightTheme.palette
    ThemeRuntime.shared.update(light: lightTheme.palette, dark: darkPalette)
  }

  private enum Keys {
    static let appearance = "appearance"
    static let configuration = "aster.configuration.v2"
    static let themeLibrary = "aster.theme-library.v1"
    static let compactSidebarMigration = "aster.migration.compact-sidebar.v1"
    static let sidebarTabGrouping = "aster.sidebar.tab-grouping.v1"
    static let sidebarTabOrder = "aster.sidebar.tab-order.v1"
  }
}
