import Foundation

/// 将任意边界切分的 PTY 字节流增量解码为 UTF-8 文本。
///
/// `read(2)` 不保证落在 Unicode 标量边界上。本类型保留末尾尚未完整的 2～4 字节
/// 序列，直到后续数据到达，避免把合法中文或 emoji 解码成替换字符。
public final class UTF8StreamDecoder: @unchecked Sendable {
  private let lock = NSLock()
  private var pendingBytes: [UInt8] = []

  public init() {}

  /// 追加一段数据并返回本轮能够完整解码的文本。
  public func append(_ data: Data) -> String {
    lock.lock()
    defer { lock.unlock() }

    var bytes = pendingBytes
    bytes.append(contentsOf: data)
    let completeCount = Self.completePrefixLength(in: bytes)
    pendingBytes = Array(bytes.dropFirst(completeCount))
    return String(decoding: bytes.prefix(completeCount), as: UTF8.self)
  }

  private static func completePrefixLength(in bytes: [UInt8]) -> Int {
    var index = 0
    while index < bytes.count {
      let first = bytes[index]
      let expectedLength: Int
      switch first {
      case 0x00...0x7F: expectedLength = 1
      case 0xC2...0xDF: expectedLength = 2
      case 0xE0...0xEF: expectedLength = 3
      case 0xF0...0xF4: expectedLength = 4
      default:
        // 非法起始字节交给 String(decoding:) 生成一个替换字符，不能无限缓存。
        index += 1
        continue
      }

      guard index + expectedLength <= bytes.count else { break }
      if expectedLength > 1 {
        let continuation = bytes[(index + 1)..<(index + expectedLength)]
        if !continuation.allSatisfy({ (0x80...0xBF).contains($0) }) {
          index += 1
          continue
        }
      }
      index += expectedLength
    }
    return index
  }
}
