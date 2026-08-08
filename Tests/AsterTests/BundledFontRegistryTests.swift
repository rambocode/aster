import AppKit
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
