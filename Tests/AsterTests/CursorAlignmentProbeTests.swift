import AppKit
import Testing

@testable import Aster
@testable import SwiftTerm

// 光标水平对齐探针:光标必须落在其逻辑列对应的网格 x 上,与文本绘制共用同一网格。

/// 喂入内容后返回 (caretX, 期望X, buffer.x, cellWidth),用于对比光标与网格的偏差。
@MainActor
private func caretGeometry(
  feeding content: String,
  in view: AsterTerminalView
) -> (caretX: CGFloat, expectedX: CGFloat, column: Int, cellWidth: CGFloat) {
  view.dataReceived(slice: Array(content.utf8)[...])
  view.updateCursorPosition()
  let terminal = view.getTerminal()
  let buffer = terminal.buffer
  let cellWidth = view.cellDimension.width
  let caretX = view.caretView?.frame.origin.x ?? -1
  return (caretX, CGFloat(buffer.x) * cellWidth, buffer.x, cellWidth)
}

@Test("各类提示符内容下光标 x 与逻辑列网格坐标一致")
@MainActor
func cursorAlignsWithGridForPromptContents() throws {
  let cases: [(name: String, content: String)] = [
    ("纯 ASCII", "abc"),
    ("箭头提示符", "\u{276F} "),
    ("powerline 分隔", "seg\u{E0B0} "),
    ("CJK 宽字符", "目录 "),
    ("emoji", "🚀 "),
    ("彩色徽章", "\u{1B}[44m ~/source \u{1B}[42m v3.12.6 \u{1B}[100m 23:53 \u{1B}[0m"),
    ("换行后空提示", "line1\r\n\u{276F} "),
  ]
  // 覆盖真实应用的渲染配置组合:双向文本开关 × ambiguous 宽度 × 行距。
  let bidiModes = [false, true]
  for bidi in bidiModes {
    for testCase in cases {
      let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 803, height: 400))
      view.bidirectionalTextEnabled = bidi
      view.lineSpacing = 2
      let geometry = caretGeometry(feeding: testCase.content, in: view)
      #expect(
        abs(geometry.caretX - geometry.expectedX) < 0.5,
        "\(testCase.name)(bidi=\(bidi)): caretX=\(geometry.caretX) 期望=\(geometry.expectedX) col=\(geometry.column) cell=\(geometry.cellWidth)"
      )
    }
  }
}
