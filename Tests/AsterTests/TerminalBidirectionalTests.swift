import AppKit
import Testing

@testable import Aster
@testable import SwiftTerm

@Test("BiDi 映射保持纯 LTR 行不变并按视觉顺序排列 RTL run")
func bidirectionalMapPreservesLTRAndReordersRTLRun() {
  let ltr = TerminalBidirectionalMap.make(
    cells: Array("abc 123").enumerated().map {
      TerminalBidirectionalCell(text: String($0.element), logicalColumn: $0.offset, width: 1)
    },
    columnCount: 7
  )
  #expect(ltr.visualCells.map(\.logicalColumn) == Array(0..<7))

  let mixedText = Array("abc אבג 123")
  let mixed = TerminalBidirectionalMap.make(
    cells: mixedText.enumerated().map {
      TerminalBidirectionalCell(text: String($0.element), logicalColumn: $0.offset, width: 1)
    },
    columnCount: mixedText.count
  )

  #expect(mixed.visualCells.map(\.logicalColumn) == [0, 1, 2, 3, 8, 9, 10, 7, 6, 5, 4])
  #expect(mixed.visualColumn(forLogicalColumn: 6) == 8)
  #expect(mixed.logicalColumn(forVisualColumn: 8) == 6)
}

@Test("BiDi 映射保留宽字符占用的两个网格列")
func bidirectionalMapPreservesWideCellSpan() {
  let map = TerminalBidirectionalMap.make(
    cells: [
      TerminalBidirectionalCell(text: "א", logicalColumn: 0, width: 1),
      TerminalBidirectionalCell(text: "中", logicalColumn: 1, width: 2),
      TerminalBidirectionalCell(text: "ב", logicalColumn: 3, width: 1),
    ],
    columnCount: 4
  )

  #expect(map.visualCells.map(\.width).reduce(0, +) == 4)
  let wideStart = map.visualColumn(forLogicalColumn: 1)
  #expect(map.logicalColumn(forVisualColumn: wideStart) == 1)
  #expect(map.logicalColumn(forVisualColumn: wideStart + 1) == 2)
}

@Test("ECMA-48 mode 8 暂停隐式 BiDi 并可恢复")
func explicitBidirectionalModeDisablesImplicitReordering() {
  let delegate = BidirectionalTerminalDelegate()
  let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 2))
  #expect(!terminal.explicitBidirectionalMode)

  terminal.feed(text: "\u{1B}[8h")
  #expect(terminal.explicitBidirectionalMode)

  terminal.feed(text: "\u{1B}[8l")
  #expect(!terminal.explicitBidirectionalMode)

  terminal.feed(text: "\u{1B}[8h\u{1B}c")
  #expect(!terminal.explicitBidirectionalMode)
}

@Test("终端视图公开视觉与逻辑列双向映射且复制仍使用逻辑顺序")
@MainActor
func terminalViewMapsBidirectionalColumnsWithoutChangingCopiedText() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 20, rows: 2)
  view.dataReceived(slice: Array("abc אבג 123".utf8)[...])

  let visualColumn = view.visualColumn(forLogicalColumn: 6, bufferRow: 0)
  #expect(visualColumn == 8)
  #expect(view.logicalColumn(forVisualColumn: visualColumn, bufferRow: 0) == 6)

  view.setSelection(start: Position(col: 4, row: 0), end: Position(col: 7, row: 0))
  #expect(view.getSelection() == "אבג")

  view.bidirectionalTextEnabled = false
  #expect(view.visualColumn(forLogicalColumn: 6, bufferRow: 0) == 6)
}

@Test("隐式 BiDi 中左右方向键按视觉邻居交换且显式模式保留应用输入")
@MainActor
func terminalViewMovesAcrossRTLInVisualDirection() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 20, rows: 2)
  view.dataReceived(slice: Array("אבג\u{1B}[2G".utf8)[...])
  var sent: [[UInt8]] = []
  view.onEncodedInput = { sent.append(Array($0)) }

  let cursor = view.getTerminal().activeBufferCursorPosition
  #expect(cursor.col == 1)
  #expect(view.bidirectionalTextEnabled)
  #expect(view.getTerminal().keyboardEnhancementFlags.isEmpty)
  #expect(!view.getTerminal().isCurrentBufferAlternate)
  #expect(
    view.logicalColumn(
      visuallyAdjacentToLogicalColumn: cursor.col,
      offset: -1,
      bufferRow: cursor.row
    ) == 2)

  view.keyDown(with: try arrowEvent(keyCode: 123, functionKey: NSLeftArrowFunctionKey))
  #expect(sent == [Array("\u{1B}[C".utf8)])

  sent.removeAll()
  view.dataReceived(slice: Array("\u{1B}[8h".utf8)[...])
  view.keyDown(with: try arrowEvent(keyCode: 123, functionKey: NSLeftArrowFunctionKey))
  #expect(sent == [Array("\u{1B}[D".utf8)])
}

@MainActor
private func arrowEvent(keyCode: UInt16, functionKey: Int) throws -> NSEvent {
  let characters = String(Character(UnicodeScalar(UInt32(functionKey))!))
  return try #require(
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [.function],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: characters,
      charactersIgnoringModifiers: characters,
      isARepeat: false,
      keyCode: keyCode
    ))
}

private final class BidirectionalTerminalDelegate: TerminalDelegate {
  func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
