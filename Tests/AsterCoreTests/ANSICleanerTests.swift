import Testing

@testable import AsterCore

@Test("ANSI SGR 序列不会污染终端的可见文本")
func stripsSGRSequences() {
  let result = ANSICleaner.visibleText(from: "\u{001B}[31merror\u{001B}[0m")

  #expect(result == "error")
}

@Test("回车刷新当前行，而不是不断追加进度输出")
func carriageReturnReplacesCurrentLine() {
  var transcript = TerminalTranscript()

  transcript.append("Downloading 10%\rDownloading 80%")

  #expect(transcript.text == "Downloading 80%")
}

@Test("退格会删除光标前一个可见字符")
func backspaceRemovesPreviousCharacter() {
  var transcript = TerminalTranscript()

  transcript.append("helol\u{8}\u{8}lo")

  #expect(transcript.text == "hello")
}

@Test("清屏序列会清空旧内容并保留后续输出")
func eraseDisplayClearsTranscript() {
  var transcript = TerminalTranscript()

  transcript.append("old output\n")
  transcript.append("\u{001B}[2J\u{001B}[Hfresh")

  #expect(transcript.text == "fresh")
}

@Test("PTY 的 CRLF 换行会保留已经输出的当前行")
func carriageReturnLineFeedPreservesLine() {
  var transcript = TerminalTranscript()

  transcript.append("first\r\nsecond")

  #expect(transcript.text == "first\nsecond")
}

@Test("跨输出片段的 CRLF 仍被识别为一个换行")
func splitCarriageReturnLineFeedPreservesLine() {
  var transcript = TerminalTranscript()

  transcript.append("first\r")
  transcript.append("\nsecond")

  #expect(transcript.text == "first\nsecond")
}

@Test("空终端收到退格不会越界")
func backspaceOnEmptyTranscriptIsSafe() {
  var transcript = TerminalTranscript()

  transcript.append("\u{8}")

  #expect(transcript.text.isEmpty)
}

@Test("跨输出片段的 ANSI CSI 序列不会留下残片")
func splitANSISequenceIsBuffered() {
  var transcript = TerminalTranscript()

  transcript.append("\u{001B}[3")
  transcript.append("1mred\u{001B}[0m")

  #expect(transcript.text == "red")
}
