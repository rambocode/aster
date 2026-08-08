import AppKit
import AsterCore
import Combine
import Foundation

struct TerminalFontVariants {
  let normal: NSFont
  let bold: NSFont
  let italic: NSFont
  let boldItalic: NSFont
}

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

  /// 用户对各套主题的颜色覆盖。改色写在这里而不是复制整套主题，内置真值表因此
  /// 保持只读，主题列表也不会被一堆「副本」淹没。
  @Published private(set) var themeOverrides: ThemeOverrideLibrary {
    didSet {
      persistThemeOverrides()
      synchronizeThemeRuntime()
    }
  }

  @Published var sidebarTabGrouping: SidebarTabGrouping {
    didSet { defaults.set(sidebarTabGrouping.rawValue, forKey: Keys.sidebarTabGrouping) }
  }

  @Published var sidebarTabOrder: SidebarTabOrder {
    didSet { defaults.set(sidebarTabOrder.rawValue, forKey: Keys.sidebarTabOrder) }
  }

  /// 右侧详情面板的显隐与选中页属于轻量 UI 状态，随 UserDefaults 持久化但不进入
  /// 配置 JSON（与侧栏分组/排序同级）。刻意不用 @Published：显隐由
  /// `AppModel.inspectorPresentationChanged` 驱动内容区局部约束切换，选中页由面板
  /// 本地即时生效；这里仅落盘，不能触发工作区重建。
  var inspectorPresented: Bool {
    get { defaults.bool(forKey: Keys.inspectorPresented) }
    set { defaults.set(newValue, forKey: Keys.inspectorPresented) }
  }

  var inspectorSection: Int {
    get { min(max(defaults.integer(forKey: Keys.inspectorSection), 0), 3) }
    set { defaults.set(min(max(newValue, 0), 3), forKey: Keys.inspectorSection) }
  }

  /// Git 页「在编辑器中打开」记住的目标 bundle ID。只是一个偏好指针：真正可用的编辑器
  /// 每次由 `WorkspaceEditorLocator` 重新探测，卸载后会自动回落到第一个已安装项。
  var inspectorGitEditorBundleIdentifier: String? {
    get { defaults.string(forKey: Keys.inspectorGitEditor) }
    set { defaults.set(newValue, forKey: Keys.inspectorGitEditor) }
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
    if let data = defaults.data(forKey: Keys.themeOverrides),
      let decoded = try? JSONDecoder().decode(ThemeOverrideLibrary.self, from: data)
    {
      themeOverrides = decoded
    } else {
      themeOverrides = ThemeOverrideLibrary()
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

  var tabBarLayout: TabBarLayout {
    get { configuration.tabBarLayout }
    set { configuration.tabBarLayout = newValue }
  }

  var optionAsMeta: Bool { configuration.controls.optionAsMeta }
  var allowMouseReporting: Bool { configuration.controls.allowMouseReporting }
  var terminalIdentity: String { configuration.appearance.terminalIdentity }

  var terminalFont: NSFont {
    terminalFontVariants.normal
  }

  var terminalFontVariants: TerminalFontVariants {
    let appearance = configuration.appearance
    let globalFamily = appearance.fontFamily.trimmingCharacters(in: .whitespacesAndNewlines)
    let systemMonospaced = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    let normal: NSFont
    if !globalFamily.isEmpty {
      normal = BundledFontRegistry.font(named: globalFamily, size: fontSize) ?? systemMonospaced
    } else if let candidates = activeTheme.style.fontFamilies, !candidates.isEmpty {
      // Otty 的 font-mono 是按顺序解析的字体栈；首项未安装不能直接退到系统字体，
      // 否则后面的 SF Mono / Menlo 永远没有机会生效。generic `monospace` 是栈终点。
      normal = candidates.lazy.compactMap { rawName -> NSFont? in
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        if name.lowercased() == "monospace" { return systemMonospaced }
        return BundledFontRegistry.font(named: name, size: self.fontSize)
      }.first
        ?? BundledFontRegistry.font(named: "JetBrains Mono", size: fontSize)
        ?? systemMonospaced
    } else {
      normal = BundledFontRegistry.font(named: "JetBrains Mono", size: fontSize)
        ?? systemMonospaced
    }
    let manager = NSFontManager.shared
    let bold = appearance.fontFamilyBold.flatMap {
      BundledFontRegistry.font(named: $0, size: fontSize)
    } ?? manager.convert(normal, toHaveTrait: .boldFontMask)
    let italic = appearance.fontFamilyItalic.flatMap {
      BundledFontRegistry.font(named: $0, size: fontSize)
    } ?? manager.convert(normal, toHaveTrait: .italicFontMask)
    let boldItalic = appearance.fontFamilyBoldItalic.flatMap {
      BundledFontRegistry.font(named: $0, size: fontSize)
    } ?? manager.convert(normal, toHaveTrait: [.boldFontMask, .italicFontMask])
    let fallbacks = appearance.resolvedFontFamilyFallback
    return TerminalFontVariants(
      normal: BundledFontRegistry.addingNerdSymbolsFallback(
        to: normal, additionalFamilies: fallbacks),
      bold: BundledFontRegistry.addingNerdSymbolsFallback(
        to: bold, additionalFamilies: fallbacks),
      italic: BundledFontRegistry.addingNerdSymbolsFallback(
        to: italic, additionalFamilies: fallbacks),
      boldItalic: BundledFontRegistry.addingNerdSymbolsFallback(
        to: boldItalic, additionalFamilies: fallbacks)
    )
  }

  var terminalForegroundColor: NSColor {
    NSColor(activeTheme.palette.foreground)
  }

  var terminalBackgroundColor: NSColor {
    NSColor(activeTheme.palette.renderedTerminalBackground)
  }

  var cursorColor: NSColor {
    let source = configuration.appearance.cursorColorOverride ?? activeTheme.palette.cursor
    return NSColor(source).withAlphaComponent(
      CGFloat(configuration.appearance.resolvedCursorOpacity)
    )
  }
  var cursorTextColor: NSColor {
    NSColor(
      configuration.appearance.cursorTextColorOverride
        ?? activeTheme.palette.cursorText
        ?? activeTheme.palette.windowBackground
    )
  }
  var selectionColor: NSColor { NSColor(activeTheme.palette.selection) }
  var selectionForegroundColor: NSColor {
    NSColor(activeTheme.palette.selectionForeground ?? activeTheme.palette.windowBackground)
  }
  var ansiColors: [HexColor] { activeTheme.palette.ansiColors }

  var lightTheme: TerminalTheme {
    resolved(
      TerminalThemeCatalog.resolve(
        named: configuration.appearance.themeName,
        customThemes: themeLibrary.customThemes,
        mode: .light
      ))
  }

  var darkTheme: TerminalTheme {
    resolved(
      TerminalThemeCatalog.resolve(
        named: configuration.appearance.darkThemeName,
        customThemes: themeLibrary.customThemes,
        mode: .dark
      ))
  }

  /// 主题的最终形态 = 基础主题 + 用户覆盖。所有读取路径都必须经过这里，
  /// 否则终端与界面会看到不同版本的同一套主题。
  func resolved(_ theme: TerminalTheme) -> TerminalTheme {
    theme.applyingOverrides(themeOverrides.overrides(for: theme.id))
  }

  var activeTheme: TerminalTheme {
    if usesDarkAppearance {
      return configuration.appearance.useSeparateDarkTheme ? darkTheme : lightTheme
    }
    return lightTheme
  }

  func themes(for mode: TerminalThemeMode) -> [TerminalTheme] {
    (TerminalThemeCatalog.builtIns + themeLibrary.customThemes)
      .filter { $0.mode == mode }
      .map(resolved)
  }

  func selectTheme(_ theme: TerminalTheme) {
    if theme.mode == .dark {
      configuration.appearance.darkThemeName = theme.name
    } else {
      configuration.appearance.themeName = theme.name
    }
  }

  /// 改一个 token 的颜色：写进覆盖表，原主题（含内置真值表）保持不动。
  ///
  /// 覆盖同时落到主题文件夹里那份 `.ottytheme`：文件末尾追加带 `# otty-added:`
  /// 注释的段落，用户能直接看到、也能手工删掉某一行来撤销覆盖。
  func setThemeColor(_ color: HexColor, slotID: String, themeID: String) {
    var library = themeOverrides
    library.setColor(color, slotID: slotID, themeID: themeID)
    themeOverrides = library
  }

  /// 撤销某个 token 的覆盖，回到原主题的值（或它的派生值）。
  func clearThemeColor(slotID: String, themeID: String) {
    var library = themeOverrides
    library.clearColor(slotID: slotID, themeID: themeID)
    themeOverrides = library
  }

  /// 撤销整套主题的全部覆盖。
  func clearThemeOverrides(themeID: String) {
    var library = themeOverrides
    library.clearAll(themeID: themeID)
    themeOverrides = library
  }

  func themeOverrides(for themeID: String) -> ThemeColorOverrides {
    themeOverrides.overrides(for: themeID)
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

  /// 把某套主题的用户覆盖写成 Otty 追加段落，落到主题文件夹里的同名 `.ottytheme`。
  ///
  /// 追加而不是重写：文件里原主题的内容一字不动，用户覆盖以 `# otty-added:` 注释
  /// 标出，删掉注释下面那行就撤销了这一条。文件不存在时先写出主题本体再追加。
  @discardableResult
  func writeThemeOverridesToLibraryFolder(themeID: String) throws -> URL? {
    let overrides = themeOverrides.overrides(for: themeID)
    let section = TerminalTheme.ottyOverrideSection(overrides)
    guard !section.isEmpty,
      let theme = (TerminalThemeCatalog.builtIns + themeLibrary.customThemes)
        .first(where: { $0.id == themeID })
    else { return nil }
    let directory = try themesDirectory()
    let safeName = theme.name.replacingOccurrences(
      of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
    let url = directory.appendingPathComponent(safeName).appendingPathExtension("ottytheme")
    let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    // 每次写出都先剥掉上一轮追加的段落，否则同一个键会在文件里越堆越多。
    let base = ThemeOverrideFileWriter.strippingPreviousOverrides(from: existing)
    let body = base.isEmpty ? "" : base.trimmingCharacters(in: .newlines) + "\n\n"
    let content = body + ThemeOverrideFileWriter.marker + "\n" + section + "\n"
    try content.write(to: url, atomically: true, encoding: .utf8)
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
    // 本机安全授权不能随 JSON 导入；否则第三方配置可预置 scheme 例外，或把 OSC 52
    // 读取改成无提示允许。显式 Deny 属于更严格策略，可以安全保留。
    imported.controls.allowedNonStandardLinkSchemes = []
    if imported.controls.resolvedClipboardReadAccess == .allow {
      imported.controls.clipboardReadAccess = .ask
    }
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

  private func persistThemeOverrides() {
    guard let data = try? JSONEncoder().encode(themeOverrides) else { return }
    defaults.set(data, forKey: Keys.themeOverrides)
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
    static let themeOverrides = "aster.theme-overrides.v1"
    static let compactSidebarMigration = "aster.migration.compact-sidebar.v1"
    static let sidebarTabGrouping = "aster.sidebar.tab-grouping.v1"
    static let sidebarTabOrder = "aster.sidebar.tab-order.v1"
    static let inspectorPresented = "aster.inspector.presented.v1"
    static let inspectorSection = "aster.inspector.section.v1"
    static let inspectorGitEditor = "aster.inspector.git-editor.v1"
  }
}
