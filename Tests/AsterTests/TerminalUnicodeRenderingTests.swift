import AppKit
import Testing

@testable import Aster
@testable import SwiftTerm

@Test("East Asian Ambiguous block 可按配置加宽且默认仅加宽圈字母数字")
func configurableEastAsianAmbiguousWidth() throws {
  let delegate = UnicodeTerminalDelegate()
  var options = TerminalOptions(cols: 20, rows: 2)
  options.widenedEastAsianAmbiguousBlocks = [.enclosedAlphanumerics]
  let terminal = Terminal(delegate: delegate, options: options)

  terminal.feed(text: "①→")

  #expect(try #require(terminal.getCharData(col: 0, row: 0)).width == 2)
  #expect(try #require(terminal.getCharData(col: 2, row: 0)).width == 1)

  terminal.feed(text: "\r\u{1B}[2K")
  terminal.options.widenedEastAsianAmbiguousBlocks = [.arrows]
  terminal.feed(text: "①→")

  #expect(try #require(terminal.getCharData(col: 0, row: 0)).width == 1)
  #expect(try #require(terminal.getCharData(col: 1, row: 0)).width == 2)

  terminal.feed(text: "\r\u{1B}[2K")
  terminal.options.widenedEastAsianAmbiguousBlocks = .all
  terminal.feed(text: "א")
  #expect(try #require(terminal.getCharData(col: 0, row: 0)).width == 1)
}

@Test("终端视图重设网格尺寸时保留 Unicode 宽度策略")
@MainActor
func terminalResizePreservesUnicodeOptions() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.getTerminal().options.widenedEastAsianAmbiguousBlocks = [.arrows, .dingbats]

  view.resize(cols: 90, rows: 28)

  #expect(view.getTerminal().options.widenedEastAsianAmbiguousBlocks == [.arrows, .dingbats])
}

@Test("连字、粗斜体策略和隐藏文本进入 CoreText 属性")
@MainActor
func terminalTextStylesProduceConfiguredAttributes() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.ligatureMode = .discretionary
  view.boldStyleMode = .disabled
  view.italicStyleMode = .disabled

  let regular = try #require(view.getAttributes(CharData.defaultAttr, withUrl: false))
  #expect(regular[NSAttributedString.Key.ligature] as? Int == 2)

  view.dataReceived(slice: Array("\u{1B}[1;3;8mhidden".utf8)[...])
  let hiddenCell = try #require(view.getTerminal().getCharData(col: 0, row: 0))
  let hidden = try #require(view.getAttributes(hiddenCell.attribute, withUrl: false))
  #expect((hidden[.font] as? NSFont) == view.font)
  #expect((hidden[.foregroundColor] as? NSColor) == (hidden[.backgroundColor] as? NSColor))
}

@Test("SGR 6 与 SGR 5 一样形成 blink 样式且 SGR 25 清除")
func rapidBlinkUsesTerminalBlinkStyle() throws {
  let delegate = UnicodeTerminalDelegate()
  let terminal = Terminal(delegate: delegate, options: TerminalOptions(cols: 20, rows: 2))

  terminal.feed(text: "\u{1B}[6mA\u{1B}[25mB")

  let blinking = try #require(terminal.getCharData(col: 0, row: 0))
  let steady = try #require(terminal.getCharData(col: 1, row: 0))
  #expect(blinking.attribute.style.contains(.blink))
  #expect(!steady.attribute.style.contains(.blink))
}

@Test("blink 动画关闭时稳定显示，开启后隐藏相位仅改变渲染属性")
@MainActor
func animatedBlinkChangesOnlyRenderedForeground() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.dataReceived(slice: Array("\u{1B}[5mA".utf8)[...])
  let cell = try #require(view.getTerminal().getCharData(col: 0, row: 0))
  let steady = try #require(view.getAttributes(cell.attribute, withUrl: false))
  #expect((steady[.foregroundColor] as? NSColor) != (steady[.backgroundColor] as? NSColor))

  view.animatedTextBlinkEnabled = true
  view.textBlinkPhaseVisible = false
  view.resetCaches()
  let hiddenPhase = try #require(view.getAttributes(cell.attribute, withUrl: false))
  #expect((hiddenPhase[.foregroundColor] as? NSColor) == (hiddenPhase[.backgroundColor] as? NSColor))
  #expect(view.getTerminal().getCharacter(for: cell) == "A")

  view.animatedTextBlinkEnabled = false
  #expect(view.textBlinkTimer == nil)
}

private final class UnicodeTerminalDelegate: TerminalDelegate {
  func send(source: Terminal, data: ArraySlice<UInt8>) {}
}
