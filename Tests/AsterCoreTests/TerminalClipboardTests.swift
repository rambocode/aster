import Foundation
import Testing

@testable import AsterCore

@Test("复制转换仅删除每个物理行末尾的空白并保留原换行符")
func copiedTextTrimsOnlyTrailingWhitespace() {
  let source = "  first  \r\nsecond\t\n third \t"

  #expect(
    TerminalClipboardText.trimmingTrailingWhitespace(in: source) == "  first\r\nsecond\n third")
  #expect(TerminalClipboardText.trimmingTrailingWhitespace(in: "") == "")
}

@Test("选中即复制优先保留选区，显式复制清理只在独立开启时生效")
func selectionPolicyKeepsHighlightForCopyOnSelect() {
  #expect(
    TerminalSelectionPolicy.clearsAfterExplicitCopy(
      copyOnSelect: false,
      clearSelectionOnCopy: true
    ))
  #expect(
    !TerminalSelectionPolicy.clearsAfterExplicitCopy(
      copyOnSelect: true,
      clearSelectionOnCopy: true
    ))
  #expect(
    !TerminalSelectionPolicy.clearsAfterExplicitCopy(
      copyOnSelect: false,
      clearSelectionOnCopy: false
    ))
}

@Test("危险粘贴会分别识别多行、末尾换行、提权命令和不可见控制字符")
func pasteAnalyzerClassifiesIndependentRisks() {
  #expect(PasteRiskAnalyzer.analyze("printf hello").risks.isEmpty)
  #expect(PasteRiskAnalyzer.analyze("echo one\necho two").risks == [.multipleLines])
  #expect(PasteRiskAnalyzer.analyze("echo one\n").risks == [.trailingNewline])
  #expect(PasteRiskAnalyzer.analyze("echo one\n\n").risks == [.multipleLines, .trailingNewline])
  #expect(PasteRiskAnalyzer.analyze("sudo rm -rf ./tmp").risks == [.privilegeEscalation])
  #expect(PasteRiskAnalyzer.analyze("su - root").risks == [.privilegeEscalation])
  #expect(PasteRiskAnalyzer.analyze("printf '\u{1B}[31m'").risks == [.controlCharacters])
  #expect(PasteRiskAnalyzer.analyze("tab\tinside a line").risks.isEmpty)
  #expect(PasteRiskAnalyzer.analyze("carriage\rreturn").risks == [.multipleLines])
}

@Test("提权命令检测使用命令词边界，普通单词不会误报")
func pasteAnalyzerUsesPrivilegeCommandBoundaries() {
  #expect(PasteRiskAnalyzer.analyze("echo sudoer assumption").risks.isEmpty)
  #expect(PasteRiskAnalyzer.analyze("doas --user=root true").risks.isEmpty)
  #expect(PasteRiskAnalyzer.analyze("echo ok; sudo reboot").risks.contains(.privilegeEscalation))
}

@Test("粘贴保护在备用屏或可信括号粘贴中跳过，其余危险内容要求确认")
func pasteProtectionPolicyHonorsTerminalContext() {
  let risky = PasteRiskAnalyzer.analyze("echo one\necho two")

  #expect(PasteProtectionPolicy.requiresConfirmation(for: risky, protectionEnabled: true))
  #expect(
    !PasteProtectionPolicy.requiresConfirmation(
      for: risky,
      protectionEnabled: true,
      isAlternateScreen: true
    ))
  #expect(
    !PasteProtectionPolicy.requiresConfirmation(
      for: risky,
      protectionEnabled: true,
      isBracketedPasteMode: true,
      treatsBracketedPasteAsSafe: true
    ))
  #expect(!PasteProtectionPolicy.requiresConfirmation(for: risky, protectionEnabled: false))

  let escapeInjection = PasteRiskAnalyzer.analyze("safe\u{1B}[201~\necho injected")
  #expect(
    PasteProtectionPolicy.requiresConfirmation(
      for: escapeInjection,
      protectionEnabled: true,
      isAlternateScreen: true,
      isBracketedPasteMode: true,
      treatsBracketedPasteAsSafe: true
    ))
}

@Test("OSC 52 解析区分读写请求并拒绝畸形或超限载荷")
func osc52ParserValidatesClipboardRequests() throws {
  let parser = OSC52RequestParser(maximumEncodedBytes: 32, maximumDecodedBytes: 16)

  #expect(try parser.parse(ArraySlice("c;?".utf8)) == .read(selection: "c"))
  #expect(try parser.parse(ArraySlice("q;?".utf8)) == .read(selection: "q"))
  #expect(
    try parser.parse(ArraySlice("p;\(Data("hello".utf8).base64EncodedString())".utf8))
      == .write(selection: "p", text: "hello")
  )
  #expect(throws: OSC52ParseError.self) {
    try parser.parse(ArraySlice("c;not-base64!".utf8))
  }
  #expect(throws: OSC52ParseError.self) {
    try parser.parse(ArraySlice("clipboard;?".utf8))
  }
  #expect(throws: OSC52ParseError.self) {
    try parser.parse(ArraySlice("c;\(String(repeating: "A", count: 36))".utf8))
  }
}

@Test("OSC 52 响应使用七位 OSC/ST 并限制返回剪贴板大小")
func osc52ResponseIsBoundedAndProtocolSafe() throws {
  let response = try OSC52ResponseEncoder(maximumTextBytes: 8).encode(
    selection: "c",
    text: "hello"
  )

  #expect(String(decoding: response, as: UTF8.self) == "\u{1B}]52;c;aGVsbG8=\u{1B}\\")
  #expect(throws: OSC52ResponseError.self) {
    try OSC52ResponseEncoder(maximumTextBytes: 4).encode(selection: "c", text: "hello")
  }
}

@Test("粘贴传输只在请求括号模式时包裹精确控制序列")
func pasteTransmissionEncodesBracketedModeExactly() {
  #expect(PasteTransmissionEncoder.encode("echo ok", bracketed: false) == Array("echo ok".utf8))
  #expect(
    PasteTransmissionEncoder.encode("echo ok", bracketed: true)
      == Array("\u{1B}[200~echo ok\u{1B}[201~".utf8)
  )
  #expect(
    PasteTransmissionEncoder.encode("safe\u{1B}[201~echo injected", bracketed: true)
      == Array("\u{1B}[200~safe\\x1B[201~echo injected\u{1B}[201~".utf8)
  )
}

@Test("特殊字符粘贴生成可由 POSIX Shell 安全解释为单个参数的文本")
func shellPasteEscaperHandlesQuotesAndEmptyText() {
  #expect(ShellPasteEscaper.escape("") == "''")
  #expect(ShellPasteEscaper.escape("plain text") == "'plain text'")
  #expect(ShellPasteEscaper.escape("it's $HOME") == "'it'\\''s $HOME'")
}

@Test("粘贴预览把控制字符可视化并限制长度")
func pastePreviewIsSanitizedAndBounded() {
  let analysis = PasteRiskAnalyzer.analyze("ab\u{1B}cd")

  #expect(analysis.preview() == "ab\\u{1B}cd")
  #expect(analysis.preview(maximumCharacters: 3) == "ab\\u{1B}…")
}

@Test("文件 Base64 粘贴只读取有界普通文件")
func fileBase64PasteRejectsUnsupportedAndOversizedFiles() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("AsterClipboardTests-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let file = directory.appendingPathComponent("payload.bin")
  try Data([0x00, 0x01, 0xFE, 0xFF]).write(to: file)

  #expect(try TerminalFilePasteEncoder.encodeBase64(path: file.path) == "AAH+/w==")
  #expect(throws: TerminalFilePasteError.fileTooLarge) {
    try TerminalFilePasteEncoder.encodeBase64(path: file.path, maximumBytes: 3)
  }
  #expect(throws: TerminalFilePasteError.unsupportedFile) {
    try TerminalFilePasteEncoder.encodeBase64(path: directory.path)
  }
  let symbolicLink = directory.appendingPathComponent("payload-link.bin")
  try FileManager.default.createSymbolicLink(at: symbolicLink, withDestinationURL: file)
  #expect(throws: TerminalFilePasteError.unsupportedFile) {
    try TerminalFilePasteEncoder.encodeBase64(path: symbolicLink.path)
  }
}

@Test("OSC 流在进入终端解析器前中止超限 OSC 52 并跨分片恢复")
func oscStreamLimiterBoundsClipboardSequenceBeforeParser() {
  var limiter = TerminalOSCStreamLimiter(
    maximumSequenceBytes: 32,
    maximumClipboardSequenceBytes: 10
  )

  let first = limiter.consume(Array("before\u{1B}]52;AAA".utf8))
  let second = limiter.consume(Array("AAAAA\u{7}after".utf8))

  #expect(String(decoding: first, as: UTF8.self) == "before\u{1B}]52;AAA")
  // OSC introducer和 `52;` 已占 5 字节，因此只再放行 5 字节正文；第 6 字节改为 CAN。
  #expect(String(decoding: second, as: UTF8.self) == "AA\u{18}after")
}

@Test("OSC 流限制器原样保留正常 OSC 并限制其它未终止序列")
func oscStreamLimiterPreservesValidSequencesAndBoundsGenericOSC() {
  var limiter = TerminalOSCStreamLimiter(
    maximumSequenceBytes: 9,
    maximumClipboardSequenceBytes: 8
  )
  let valid = Array("\u{1B}]2;title\u{7}text".utf8)
  #expect(limiter.consume(valid) == valid)

  let oversized = limiter.consume(Array("\u{1B}]9;123456789\u{7}tail".utf8))
  #expect(String(decoding: oversized, as: UTF8.self) == "\u{1B}]9;12345\u{18}tail")
}

@Test("通知 OSC 在进入 SwiftTerm 前使用独立 8 KiB 级上限")
func oscStreamLimiterBoundsNotificationSequencesIndependently() {
  var limiter = TerminalOSCStreamLimiter(
    maximumSequenceBytes: 64,
    maximumClipboardSequenceBytes: 60,
    maximumNotificationSequenceBytes: 12
  )

  let oversized = limiter.consume(Array("\u{1B}]99;i=x;123456789\u{7}tail".utf8))

  #expect(String(decoding: oversized, as: UTF8.self) == "\u{1B}]99;i=x;123\u{18}tail")
}

@Test("OSC 流限制器跨 ESC-ST 恢复并继续限制紧随其后的 OSC")
func oscStreamLimiterTracksSequencesAfterEscapeTermination() {
  var limiter = TerminalOSCStreamLimiter(
    maximumSequenceBytes: 10,
    maximumClipboardSequenceBytes: 8
  )
  let normal = Array("\u{1B}]2;ok\u{1B}\\tail".utf8)
  #expect(limiter.consume(normal) == normal)

  let chained = Array("\u{1B}]52;AAAA\u{1B}]52;BBBB\u{1B}\\tail".utf8)
  #expect(
    String(decoding: limiter.consume(chained), as: UTF8.self)
      == "\u{1B}]52;AAA\u{18}\u{1B}]52;BBB\u{18}tail"
  )
}

@Test("OSC 流限制器规范化八位 OSC/ST 与 SUB 并保持跨分片限长")
func oscStreamLimiterNormalizesEightBitControls() {
  var limiter = TerminalOSCStreamLimiter(
    maximumSequenceBytes: 12,
    maximumClipboardSequenceBytes: 10
  )
  let first = limiter.consume([0x9D] + Array("52;c;?".utf8))
  let second = limiter.consume([0x9C] + Array("tail".utf8))
  #expect(first == Array("\u{1B}]52;c;?".utf8))
  #expect(second == Array("\u{1B}\\tail".utf8))

  let cancelled = limiter.consume([0x9D] + Array("2;discarded".utf8) + [0x1A])
  #expect(cancelled.last == 0x18)

  let oversized = limiter.consume([0x9D] + Array("52;AAAAAA".utf8) + [0x9C])
  #expect(String(decoding: oversized, as: UTF8.self) == "\u{1B}]52;AAAAA\u{18}")
}

@Test("OSC 流限制器不把 UTF-8 延续字节 0x9D 误判为 C1 OSC")
func oscStreamLimiterPassesThroughUTF8ContinuationBytes() {
  // ❯(U+276F = E2 9D AF)等提示符字符的中间字节是 0x9D;若被当 C1 OSC 起始符,
  // 提示符与其后全部输出都会被吞进一条永不终止的 OSC(starship 默认提示符即如此)。
  var limiter = TerminalOSCStreamLimiter()
  let prompt = Array("\u{276F} echo hi\r\n".utf8)
  #expect(limiter.consume(prompt) == prompt)

  let ornaments = Array("\u{276E}\u{2770}\u{275D}".utf8)
  #expect(limiter.consume(ornaments) == ornaments)

  // 多字节字符跨 PTY 分片时,延续字节可能出现在分片开头,穿越状态必须跨调用保持。
  var chunked = TerminalOSCStreamLimiter()
  let first = chunked.consume([0xE2])
  let second = chunked.consume([0x9D, 0xAF] + Array("x".utf8))
  #expect(first + second == Array("\u{276F}x".utf8))

  // 非延续位置的裸 0x9D 仍是 C1 OSC,继续规范化为 ESC ]。
  var c1 = TerminalOSCStreamLimiter()
  let raw = c1.consume([0x9D] + Array("2;t".utf8) + [0x07])
  #expect(raw == Array("\u{1B}]2;t\u{7}".utf8))
}

@Test("OSC 流限制器在任意状态识别八位 OSC 起始符")
func oscStreamLimiterTracksEightBitOSCFromEveryRelevantState() {
  var limiter = TerminalOSCStreamLimiter(
    maximumSequenceBytes: 12,
    maximumClipboardSequenceBytes: 10
  )

  // SwiftTerm 的 0x9D 是全局转换；即使紧跟 ESC，也必须进入受限 OSC 状态。
  let afterEscape = limiter.consume([0x1B, 0x9D] + Array("52;AAAAAA".utf8) + [0x07])
  #expect(String(decoding: afterEscape, as: UTF8.self) == "\u{1B}\u{1B}]52;AAAAA\u{18}")

  // OSC 内的新 0x9D 会重置当前 OSC。CAN 防止规范化时派发前一条不完整请求，
  // 新序列仍独立执行自身的 OSC 52 限长。
  let nested = limiter.consume(
    [0x9D] + Array("52;old".utf8) + [0x9D] + Array("52;BBBBBB".utf8) + [0x1A]
  )
  #expect(String(decoding: nested, as: UTF8.self) == "\u{1B}]52;old\u{18}\u{1B}]52;BBBBB\u{18}")

  // 八位 ST 与 SUB 结束后，下一分片的新 OSC 必须重新受到相同限制。
  _ = limiter.consume([0x9D] + Array("2;ok".utf8) + [0x9C])
  let afterEightBitST = limiter.consume([0x9D] + Array("52;CCCCCC".utf8) + [0x07])
  #expect(String(decoding: afterEightBitST, as: UTF8.self) == "\u{1B}]52;CCCCC\u{18}")
}

@Test("OSC 流限制器镜像 SwiftTerm Escape 状态中的控制字符")
func oscStreamLimiterTracksControlsThatPreserveEscapeState() {
  for control: UInt8 in [0x00, 0x07, 0x09, 0x18, 0x1C, 0x1F, 0x7F] {
    var limiter = TerminalOSCStreamLimiter(
      maximumSequenceBytes: 12,
      maximumClipboardSequenceBytes: 10
    )
    let prefix = limiter.consume([0x1B, control])
    let payload = limiter.consume(Array("]52;AAAAAA".utf8) + [0x07])

    #expect(prefix == [0x1B, control])
    #expect(String(decoding: payload, as: UTF8.self) == "]52;AAAAA\u{18}")
  }

  // ESC 结束旧 OSC 后，SwiftTerm 进入同一个 Escape 状态；其中穿插 BEL 也不能让
  // limiter 忘记随后 `]` 会启动下一条 OSC。
  var chainedLimiter = TerminalOSCStreamLimiter(
    maximumSequenceBytes: 12,
    maximumClipboardSequenceBytes: 10
  )
  let chained = chainedLimiter.consume(
    Array("\u{1B}]2;old\u{1B}".utf8) + [0x07] + Array("]52;BBBBBB".utf8) + [0x07]
  )
  #expect(String(decoding: chained, as: UTF8.self) == "\u{1B}]2;old\u{1B}\u{7}]52;BBBBB\u{18}")
}
