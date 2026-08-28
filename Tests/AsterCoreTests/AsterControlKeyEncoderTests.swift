import Testing

@testable import AsterCore

/// 逻辑键名编码。
struct AsterControlKeyEncoderTests {
  @Test("固定键名、控制组合、Alt 组合与大小写")
  func encodesKeys() throws {
    #expect(try AsterControlKeyEncoder.encode("Enter") == [13])
    #expect(try AsterControlKeyEncoder.encode("return") == [13])
    #expect(try AsterControlKeyEncoder.encode("tab") == [9])
    #expect(try AsterControlKeyEncoder.encode("ESC") == [27])
    #expect(try AsterControlKeyEncoder.encode("backspace") == [127])
    #expect(try AsterControlKeyEncoder.encode("ctrl-c") == [3])
    #expect(try AsterControlKeyEncoder.encode("C-c") == [3])
    #expect(try AsterControlKeyEncoder.encode("control-z") == [26])
    #expect(try AsterControlKeyEncoder.encode("C-[") == [27])
    #expect(try AsterControlKeyEncoder.encode("M-b") == [27, 0x62])
    #expect(try AsterControlKeyEncoder.encode("alt-x") == [27, 0x78])
    #expect(try AsterControlKeyEncoder.encode("up") == Array("\u{1B}[A".utf8))
    #expect(try AsterControlKeyEncoder.encode("PageDown") == Array("\u{1B}[6~".utf8))
    #expect(try AsterControlKeyEncoder.encode("f5") == Array("\u{1B}[15~".utf8))
    #expect(try AsterControlKeyEncoder.encode(["C-u", "Enter"]) == [21, 13])
    #expect(try AsterControlKeyEncoder.encode("ctrl+c") == [3])
    #expect(try AsterControlKeyEncoder.encode("Ctrl+Z") == [26])
    #expect(try AsterControlKeyEncoder.encode("alt+x") == [27, 0x78])
    // 末尾的 `+` 是键本身，不当连接符；`+` 不是合法控制组合字符。
    #expect(!AsterControlKeyEncoder.isKnown("C-+"))
    #expect(!AsterControlKeyEncoder.isKnown("+"))
    #expect(AsterControlKeyEncoder.isKnown("space"))
    #expect(!AsterControlKeyEncoder.isKnown("C-1"))
    #expect(!AsterControlKeyEncoder.isKnown("ctrl-"))
    #expect(!AsterControlKeyEncoder.isKnown("bogus"))
    #expect(throws: AsterControlKeyEncoder.EncodeError.unknownKey("bogus")) {
      try AsterControlKeyEncoder.encode(["enter", "bogus"])
    }
  }
}
