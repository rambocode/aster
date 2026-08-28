import Foundation
import Testing

@testable import AsterCore

/// NDJSON 行缓冲器的切分与上限。
struct NDJSONFramingTests {
  @Test("跨块切分、CRLF、空行跳过")
  func splitsLinesAcrossChunks() throws {
    var framing = NDJSONFraming(maximumLineBytes: 64)
    #expect(try framing.append(Data("{\"a\":".utf8)) == [])
    #expect(framing.pendingBytes == 5)
    let lines = try framing.append(Data("1}\r\n\n{\"b\":2}\n{\"c\"".utf8))
    #expect(lines.map { String(decoding: $0, as: UTF8.self) } == ["{\"a\":1}", "{\"b\":2}"])
    #expect(framing.pendingBytes == 4)
    #expect(try framing.append(Data("}\n".utf8)).map { String(decoding: $0, as: UTF8.self) } == ["{\"c\"}"])
    #expect(framing.pendingBytes == 0)
  }

  @Test("无换行超限抛 lineTooLarge，且缓冲被清空")
  func rejectsOversizedPendingLine() throws {
    var framing = NDJSONFraming(maximumLineBytes: 8)
    #expect(try framing.append(Data(repeating: 0x61, count: 8)) == [])
    #expect(throws: NDJSONFraming.FramingError.lineTooLarge(bytes: 9)) {
      try framing.append(Data([0x62]))
    }
    #expect(framing.pendingBytes == 0)

    // 带换行的超长行同样拒绝。
    var second = NDJSONFraming(maximumLineBytes: 8)
    #expect(throws: NDJSONFraming.FramingError.lineTooLarge(bytes: 9)) {
      try second.append(Data(repeating: 0x61, count: 9) + Data([0x0A]))
    }
    #expect(second.pendingBytes == 0)
  }

  @Test("默认上限 1 MiB；frame 追加换行")
  func defaultLimitAndFrame() throws {
    #expect(NDJSONFraming().maximumLineBytes == 1 * 1_024 * 1_024)
    var framing = NDJSONFraming()
    #expect(try framing.append(Data(repeating: 0x61, count: 1_024 * 1_024)) == [])
    #expect(throws: NDJSONFraming.FramingError.self) { try framing.append(Data([0x61])) }
    #expect(NDJSONFraming.frame(Data("{}".utf8)) == Data("{}\n".utf8))
  }
}
