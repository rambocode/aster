import AppKit
import Testing

@testable import Aster
@testable import SwiftTerm

@Test("增大行高会扩大终端网格，但竖线光标不拉伸到整行")
@MainActor
func lineHeightExpandsGridWithoutStretchingBarCursor() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
  view.lineSpacing = 2
  view.getTerminal().options.cursorStyle = .steadyBar
  view.dataReceived(slice: Array(" ".utf8)[...])
  view.updateCursorPosition()

  let caret = try #require(view.caretView)
  caret.style = .steadyBar
  caret.tracksFocus = false
  let height = Int(ceil(caret.bounds.height))
  let width = max(3, Int(ceil(caret.bounds.width)))
  let bitmap = try #require(
    NSBitmapImageRep(
      bitmapDataPlanes: nil,
      pixelsWide: width,
      pixelsHigh: height,
      bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true,
      isPlanar: false,
      colorSpaceName: .deviceRGB,
      bytesPerRow: 0,
      bitsPerPixel: 0
    )
  )
  let context = try #require(NSGraphicsContext(bitmapImageRep: bitmap)?.cgContext)
  // 模拟真实 CALayer 的重复重绘：旧帧可能留下整格光标像素，新帧必须先清空 backing
  // store，再只画与字号一致的竖线区域。
  context.setFillColor(NSColor.systemRed.cgColor)
  context.fill(CGRect(x: 0, y: 0, width: width, height: height))
  caret.drawCursor(in: context, hasFocus: true)

  let paintedRows = (0..<height).count { y in
    (0..<min(width, 3)).contains { x in
      (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
    }
  }

  #expect(view.caretFrame.height > ceil(view.font.ascender - view.font.descender))
  #expect(paintedRows <= Int(ceil(view.font.pointSize)) + 1)
}

@Test("Metal 竖线光标与 AppKit 一样保留行间距")
@MainActor
func metalBarCursorDoesNotConsumeLineSpacing() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
  view.lineSpacing = 2
  let scale: CGFloat = 2

  let metalHeight = MetalTerminalRenderer.barCursorHeightPixels(
    cellHeight: view.caretFrame.height,
    fontPointSize: view.font.pointSize,
    scale: scale
  )

  // 竖线只覆盖字号高度；cell 因 line-height 增加的区域必须留空，避免光标顶到上一行。
  #expect(metalHeight <= ceil(view.font.pointSize * scale))
  #expect(metalHeight < view.caretFrame.height * scale)
}
