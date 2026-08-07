import Foundation
import Testing

@testable import AsterCore

@Test("跨读取块的 UTF-8 字符只在完整后输出")
func splitUTF8SequenceIsBuffered() {
  let decoder = UTF8StreamDecoder()
  let bytes = Array("终".utf8)

  #expect(decoder.append(Data(bytes.prefix(2))).isEmpty)
  #expect(decoder.append(Data(bytes.dropFirst(2))) == "终")
}

@Test("完整文本与尾部半个字符可以同时处理")
func completePrefixAndIncompleteSuffixAreSeparated() {
  let decoder = UTF8StreamDecoder()
  let suffix = Array("端".utf8)
  var firstChunk = Array("Aster ".utf8)
  firstChunk.append(contentsOf: suffix.prefix(1))

  #expect(decoder.append(Data(firstChunk)) == "Aster ")
  #expect(decoder.append(Data(suffix.dropFirst())) == "端")
}
