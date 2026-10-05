import Foundation
import Testing

@testable import AsterCore

// 无 schema 的 protobuf 浅层扫描：只切一层字段，畸形输入一律返回 nil。

@Suite("ProtobufScan")
struct ProtobufScanTests {
  @Test("切出 varint、长度前缀与定长字段")
  func splitsOneLevelOfFields() throws {
    // 1: varint 300；2: bytes "ab"；3: fixed32；4: fixed64。
    let bytes: [UInt8] =
      [0x08, 0xAC, 0x02, 0x12, 0x02, 0x61, 0x62, 0x1D, 1, 2, 3, 4, 0x21, 1, 2, 3, 4, 5, 6, 7, 8]
    let fields = try #require(ProtobufScan.fields(bytes[...]))
    #expect(fields.map(\.number) == [1, 2, 3, 4])
    #expect(ProtobufScan.varint(fields, 1) == 300)
    #expect(ProtobufScan.bytes(fields, 2).map(Array.init) == [0x61, 0x62])
    #expect(fields[2].value == .fixed)
    #expect(fields[3].value == .fixed)
  }

  @Test("嵌套消息由调用方对子字节再扫一次")
  func nestedMessageIsScannedByCaller() throws {
    // 9: { 2: varint 7 }
    let bytes: [UInt8] = [0x4A, 0x02, 0x10, 0x07]
    let outer = try #require(ProtobufScan.fields(bytes[...]))
    let inner = try #require(ProtobufScan.bytes(outer, 9).flatMap { ProtobufScan.fields($0) })
    #expect(ProtobufScan.varint(inner, 2) == 7)
  }

  @Test("重复字段取第一个，类型不符返回 nil")
  func firstMatchAndTypeMismatch() throws {
    let bytes: [UInt8] = [0x08, 0x01, 0x08, 0x02]
    let fields = try #require(ProtobufScan.fields(bytes[...]))
    #expect(ProtobufScan.varint(fields, 1) == 1)
    #expect(ProtobufScan.bytes(fields, 1) == nil)
    #expect(ProtobufScan.varint(fields, 5) == nil)
  }

  @Test("空输入是合法的空消息")
  func emptyInputIsEmptyMessage() {
    #expect(ProtobufScan.fields([UInt8]()[...]) == [])
  }

  @Test("截断、越界长度、非法 wire type、字段号 0 一律返回 nil")
  func rejectsMalformedInput() {
    let cases: [[UInt8]] = [
      [0x08],  // varint 缺值
      [0x08, 0x80],  // varint 没结束
      [0x12, 0x05, 0x61],  // 长度超过剩余字节
      [0x1D, 1, 2],  // fixed32 不够 4 字节
      [0x0B],  // wire type 3（group）
      [0x00, 0x01],  // 字段号 0
      [0x08] + [UInt8](repeating: 0xFF, count: 11),  // varint 超过 10 字节
    ]
    for bytes in cases {
      #expect(ProtobufScan.fields(bytes[...]) == nil, "\(bytes)")
    }
  }
}
