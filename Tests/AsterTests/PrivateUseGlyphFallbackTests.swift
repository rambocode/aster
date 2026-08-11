import AppKit
import CoreText
import Testing

@testable import Aster
@testable import SwiftTerm

// PUA(私用区)提示符字形回归:系统等宽字体对 PUA 码位会跳过自定义 cascade 直落
// LastResort(渲染成空白/占位框),Powerline 箭头因此从提示符里消失。终端必须在
// 构串阶段就为 PUA 字符解析出真实字形字体。

/// 把一行文本喂给终端并返回该行整形后所有 run 的解析字体名。
@MainActor
private func resolvedRunFonts(feeding text: String, font: NSFont) -> [String] {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 400))
  view.setFonts(normal: font, bold: font, italic: font, boldItalic: font)
  view.dataReceived(slice: Array(text.utf8)[...])
  let terminal = view.getTerminal()
  let info = view.buildAttributedString(
    row: 0, line: terminal.buffer.lines[0], cols: terminal.cols)
  var fonts: [String] = []
  for segment in info.segments {
    let line = CTLineCreateWithAttributedString(segment.attributedString)
    for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
      let attributes = CTRunGetAttributes(run) as? [NSAttributedString.Key: Any] ?? [:]
      if let runFont = attributes[.font] as? NSFont {
        fonts.append(CTFontCopyPostScriptName(runFont as CTFont) as String)
      }
    }
  }
  return fonts
}

@Test("系统等宽字体下 Powerline PUA 字形不落 LastResort")
@MainActor
func puaGlyphResolvesUnderSystemMonospacedFont() throws {
  let fontURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/fonts/AsterNerdSymbols-Regular.ttf")
  try BundledFontRegistry.registerNerdSymbols(at: fontURL)

  // 用户可显式选择任意系统等宽字体，Nerd cascade 仍必须负责 PUA 图标。
  let base = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  let combined = BundledFontRegistry.addingNerdSymbolsFallback(to: base)

  // Powerline 右实心箭头(E0B0)+ 常规提示符箭头(276F)。
  let fonts = resolvedRunFonts(feeding: "\u{E0B0}\u{276F} x", font: combined)
  #expect(!fonts.isEmpty)
  #expect(
    !fonts.contains("LastResort"),
    "PUA 字形整形落到 LastResort(即空白/占位框): \(fonts)"
  )
  #expect(
    fonts.contains(BundledFontRegistry.nerdSymbolsPostScriptName),
    "E0B0 应由内置 Nerd 字体渲染: \(fonts)"
  )
}
