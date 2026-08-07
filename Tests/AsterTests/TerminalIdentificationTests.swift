import SwiftTerm
import Testing

private final class TerminalResponseCollector: TerminalDelegate {
  var bytes: [UInt8] = []

  func send(source: Terminal, data: ArraySlice<UInt8>) {
    bytes.append(contentsOf: data)
  }

  func consume() -> String {
    defer { bytes.removeAll(keepingCapacity: true) }
    return String(decoding: bytes, as: UTF8.self)
  }
}

@Test("终端精确响应 DA1 DA2 XTVERSION 与 DSR")
func terminalRespondsWithAsterIdentification() {
  let collector = TerminalResponseCollector()
  let terminal = Terminal(delegate: collector)
  terminal.programIdentity = TerminalProgramIdentity(
    name: "aster",
    version: "0.4.1",
    deviceAttributesVersion: 401
  )

  terminal.feed(byteArray: Array("\u{1B}[c".utf8))
  #expect(collector.consume() == "\u{1B}[?6c")

  terminal.feed(byteArray: Array("\u{1B}[>c".utf8))
  #expect(collector.consume() == "\u{1B}[>0;401;1c")

  terminal.feed(byteArray: Array("\u{1B}[>q".utf8))
  #expect(collector.consume() == "\u{1B}P>|aster(0.4.1)\u{1B}\\")

  terminal.feed(byteArray: Array("\u{1B}[5n".utf8))
  #expect(collector.consume() == "\u{1B}[0n")

  terminal.feed(byteArray: Array("\u{1B}[6n".utf8))
  #expect(collector.consume() == "\u{1B}[1;1R")
}

@Test("不支持的 DA3 与带参数 XTVERSION 不发送猜测性回包")
func terminalIgnoresUnsupportedIdentificationQueries() {
  let collector = TerminalResponseCollector()
  let terminal = Terminal(delegate: collector)
  terminal.programIdentity = TerminalProgramIdentity(
    name: "aster",
    version: "0.4.1",
    deviceAttributesVersion: 401
  )

  terminal.feed(byteArray: Array("\u{1B}[=c".utf8))
  terminal.feed(byteArray: Array("\u{1B}[>1q".utf8))

  #expect(collector.consume().isEmpty)
}

@Test("SwiftTerm 暴露包含裁剪行数的单调光标与视口位置")
func terminalExposesMonotonicBufferCoordinates() {
  let collector = TerminalResponseCollector()
  let terminal = Terminal(
    delegate: collector,
    options: TerminalOptions(cols: 8, rows: 2, scrollback: 2)
  )
  terminal.feed(byteArray: Array("a\r\nb\r\nc\r\nd".utf8))

  #expect(terminal.cursorAbsolutePosition.row >= 3)
  #expect(terminal.displayAbsoluteRow <= terminal.cursorAbsolutePosition.row)
  #expect(
    terminal.bufferRow(forAbsoluteRow: terminal.cursorAbsolutePosition.row)
      == terminal.buffer.y + terminal.buffer.yBaseForEmbedding
  )
  #expect(terminal.bufferRow(forAbsoluteRow: -1) == nil)
}

@Test("标题查询默认返回空值并仅在显式授权后报告清理后的标题")
func terminalTitleReportRequiresPrivilege() {
  let collector = TerminalResponseCollector()
  let terminal = Terminal(delegate: collector)
  terminal.feed(byteArray: Array("\u{1B}]0;secret-title\u{7}".utf8))

  terminal.feed(byteArray: Array("\u{1B}[21t".utf8))
  #expect(collector.consume() == "\u{1B}]l\u{1B}\\")

  terminal.allowTitleReport = true
  terminal.feed(byteArray: Array("\u{1B}[21t".utf8))
  #expect(collector.consume() == "\u{1B}]lsecret-title\u{1B}\\")
}
