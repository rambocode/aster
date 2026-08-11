import AppKit
import Testing

@testable import Aster
@testable import SwiftTerm

// 提示符引导字符像素探针:按默认 pane 的真实字体链(JetBrains Mono 未安装 →
// 系统等宽字体 + Nerd cascade)渲染 "❯",断言其单元格内确实画出了墨水。

/// 用给定字体渲染一行文本,返回非背景像素的 x 范围与总数(设备像素坐标)。
@MainActor
private func inkExtent(
  feeding text: String, font: NSFont
) -> (minX: Int, maxX: Int, count: Int, cellWidth: CGFloat) {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
  view.setFonts(normal: font, bold: font, italic: font, boldItalic: font)
  view.nativeBackgroundColor = .black
  view.nativeForegroundColor = .white
  view.caretView?.removeFromSuperview()
  view.dataReceived(slice: Array(text.utf8)[...])
  guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
    return (-1, -1, 0, view.cellDimension.width)
  }
  view.cacheDisplay(in: view.bounds, to: rep)
  var minX = Int.max
  var maxX = -1
  var count = 0
  for y in 0..<rep.pixelsHigh {
    for x in 0..<rep.pixelsWide {
      guard let color = rep.colorAt(x: x, y: y) else { continue }
      // 只统计明显亮于背景的像素,忽略抗锯齿边缘的极暗噪声。
      if color.brightnessComponent > 0.3 {
        minX = min(minX, x)
        maxX = max(maxX, x)
        count += 1
      }
    }
  }
  let scale = CGFloat(rep.pixelsWide) / view.bounds.width
  return (
    minX == .max ? -1 : minX, maxX, count,
    view.cellDimension.width * scale
  )
}

@Test("默认字体链下提示符引导字符 U+276F 在第 0 列画出墨水")
@MainActor
func promptLeaderRendersInkInFirstCell() throws {
  let fontURL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/fonts/AsterNerdSymbols-Regular.ttf")
  try BundledFontRegistry.registerNerdSymbols(at: fontURL)
  let base = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
  let combined = BundledFontRegistry.addingNerdSymbolsFallback(to: base)

  let reference = inkExtent(feeding: "a", font: combined)
  #expect(reference.count > 0, "参照字符 'a' 应有墨水: \(reference)")

  let leader = inkExtent(feeding: "\u{276F}", font: combined)
  #expect(leader.count > 0, "U+276F 无任何墨水: \(leader)")
  // 引导字符必须主要落在自己的单元格(第 0 列)内,而不是溢出到右侧单元格。
  #expect(
    leader.minX >= 0 && CGFloat(leader.minX) < leader.cellWidth,
    "U+276F 墨水起点在第 0 列之外: \(leader)"
  )
}
