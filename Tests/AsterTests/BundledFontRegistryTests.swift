import AppKit
import AsterCore
import CoreText
import Testing

@testable import Aster

private var bundledFontsResourcesDirectory: URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources", isDirectory: true)
}

@Test("内置 JetBrains Mono 注册后提供完整终端样式")
@MainActor
func bundledJetBrainsMonoProvidesTerminalVariants() throws {
  try BundledFontRegistry.registerBundledFonts(
    resourcesDirectory: bundledFontsResourcesDirectory
  )
  let normal = try #require(
    BundledFontRegistry.font(
      named: BundledFontRegistry.jetBrainsMonoFamilyName,
      size: 13
    )
  )
  let manager = NSFontManager.shared
  let bold = manager.convert(normal, toHaveTrait: .boldFontMask)
  let italic = manager.convert(normal, toHaveTrait: .italicFontMask)
  let boldItalic = manager.convert(normal, toHaveTrait: [.boldFontMask, .italicFontMask])

  #expect(normal.familyName == BundledFontRegistry.jetBrainsMonoFamilyName)
  #expect(normal.fontName == "JetBrainsMono-Regular")
  #expect(!manager.traits(of: normal).contains(.boldFontMask))
  // CoreText 会把可变轴实例命名为 `Regular_Bold`，不能按静态字体文件的
  // PostScript 名断言；family、样式 trait 与独立字面共同证明轴解析正确。
  #expect(bold.familyName == BundledFontRegistry.jetBrainsMonoFamilyName)
  #expect(bold.fontName != normal.fontName)
  #expect(manager.traits(of: bold).contains(.boldFontMask))
  #expect(italic.fontName == "JetBrainsMono-Italic")
  #expect(manager.traits(of: italic).contains(.italicFontMask))
  #expect(boldItalic.familyName == BundledFontRegistry.jetBrainsMonoFamilyName)
  #expect(boldItalic.fontName != italic.fontName)
  #expect(manager.traits(of: boldItalic).contains([.boldFontMask, .italicFontMask]))

  // 通过生产偏好解析链再次验收，避免只证明 CoreText 可见、实际 pane 却仍选中兜底字体。
  let suiteName = "AsterTests.BundledDefaultFont.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let variants = AppPreferences(defaults: defaults).terminalFontVariants
  #expect(variants.normal.fontName == "JetBrainsMono-Regular")
  #expect(!manager.traits(of: variants.normal).contains(.boldFontMask))
  #expect(manager.traits(of: variants.bold).contains(.boldFontMask))
}

@Test("Otty 内置字体集合全部注册并可按原字体名解析")
@MainActor
func allOttyBundledFontsAreRegistered() throws {
  try BundledFontRegistry.registerBundledFonts(
    resourcesDirectory: bundledFontsResourcesDirectory
  )

  let expectedFiles = Set([
    "JetBrainsMono.ttf",
    "JetBrainsMono-Italic.ttf",
    "OfficeCodePro-Regular.ttf",
    "OfficeCodePro-Bold.ttf",
    "OfficeCodePro-Italic.ttf",
    "OfficeCodePro-BoldItalic.ttf",
    "SymbolsNerdFontMono-Regular.ttf",
  ])
  #expect(Set(BundledFontRegistry.ottyFontFileNames) == expectedFiles)

  let officeRegular = try #require(NSFont(name: "OfficeCodePro-Regular", size: 13))
  let officeBold = try #require(NSFont(name: "OfficeCodePro-Bold", size: 13))
  let officeItalic = try #require(NSFont(name: "OfficeCodePro-RegularItalic", size: 13))
  let officeBoldItalic = try #require(NSFont(name: "OfficeCodePro-BoldItalic", size: 13))
  let symbols = try #require(NSFont(name: "SymbolsNFM", size: 13))
  let manager = NSFontManager.shared

  #expect(officeRegular.familyName == "Office Code Pro")
  #expect(!manager.traits(of: officeRegular).contains([.boldFontMask, .italicFontMask]))
  #expect(manager.traits(of: officeBold).contains(.boldFontMask))
  #expect(manager.traits(of: officeItalic).contains(.italicFontMask))
  #expect(manager.traits(of: officeBoldItalic).contains([.boldFontMask, .italicFontMask]))
  #expect(symbols.familyName == "Symbols Nerd Font Mono")
}

@Test("内置 Nerd Symbols 注册后覆盖 BMP 与补充平面图标")
@MainActor
func bundledNerdSymbolsCoversDocumentedPrivateUseRanges() throws {
  let fontURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/fonts/AsterNerdSymbols-Regular.ttf")
  try BundledFontRegistry.registerNerdSymbols(at: fontURL)
  let font = try #require(NSFont(name: BundledFontRegistry.nerdSymbolsPostScriptName, size: 13))
  let characters = CTFontCopyCharacterSet(font as CTFont) as CharacterSet

  #expect(characters.contains(UnicodeScalar(0xE0B0)!))
  #expect(characters.contains(UnicodeScalar(0xF0001)!))
}

@Test("终端基础字体把内置 Nerd Symbols 放在显式 fallback 首位")
@MainActor
func terminalFontUsesBundledNerdSymbolsCascade() throws {
  let fontURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/fonts/AsterNerdSymbols-Regular.ttf")
  try BundledFontRegistry.registerNerdSymbols(at: fontURL)
  let base = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  let cascaded = BundledFontRegistry.addingNerdSymbolsFallback(to: base)
  let resolved = CTFontCreateForString(cascaded as CTFont, "\u{E0B0}" as CFString, .init(location: 0, length: 1))

  #expect(CTFontCopyPostScriptName(resolved) as String == BundledFontRegistry.nerdSymbolsPostScriptName)
}

@Test("终端字体级联保留用户配置的 fallback 顺序")
@MainActor
func terminalFontPreservesConfiguredFallbackOrder() throws {
  _ = NSApplication.shared
  let fontURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/fonts/AsterNerdSymbols-Regular.ttf")
  try BundledFontRegistry.registerNerdSymbols(at: fontURL)
  let suiteName = "AsterTests.FontFallback.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.appearance.fontFamily = "Menlo"
  preferences.configuration.appearance.fontFamilyFallback = ["Helvetica", "Courier"]

  let cascadeAttribute = NSFontDescriptor.AttributeName(
    rawValue: kCTFontCascadeListAttribute as String
  )
  let descriptors = preferences.terminalFont.fontDescriptor.fontAttributes[cascadeAttribute]
    as? [NSFontDescriptor]
  let names = descriptors?.compactMap(\.postscriptName) ?? []

  #expect(names.first == BundledFontRegistry.nerdSymbolsPostScriptName)
  #expect(names.dropFirst().contains { $0.contains("Helvetica") })
  #expect(names.dropFirst().contains { $0.contains("Courier") })
}

@Test("主题字体候选会跳过未安装字体并采用下一个可用字体")
@MainActor
func terminalFontUsesFirstAvailableThemeCandidate() throws {
  _ = NSApplication.shared
  let suiteName = "AsterTests.ThemeFontCandidates.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName)!
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.appearance.fontFamily = ""
  var custom = preferences.duplicateTheme(
    try #require(TerminalThemeCatalog.theme(named: "Ayu Light")))
  custom.style.fontFamilies = ["Aster Missing Font \(UUID().uuidString)", "Menlo", "monospace"]
  #expect(preferences.updateTheme(custom))
  preferences.selectTheme(custom)

  #expect(preferences.terminalFontVariants.normal.familyName == "Menlo")
}
