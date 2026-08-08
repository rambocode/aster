import AppKit
import AsterCore
import CoreText
import Testing

@testable import Aster

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
