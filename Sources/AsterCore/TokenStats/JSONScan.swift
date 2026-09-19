// 浅层 JSON 字节扫描器：在原始字节上走一遍取出需要的几个成员，不构造中间对象。
// 移植自 jettoai/tally（MIT）的 JSONScan。
import Foundation

/// 对「一个 JSON 对象的顶层成员」做浅层遍历的字节读取器。
///
/// 为什么不用 `JSONDecoder`：transcript 的一行可能有几百 KB（推理正文、工具参数、文件内容），
/// 而真正要的只有六个整数。解整行意味着把那几百 KB 全部物化一遍。这个扫描器跳过不关心的值、
/// 不解释它们，代价是一趟线性扫描且几乎不分配；只有被明确要求的少数小成员才会转成 Swift 值。
///
/// 它**故意**不是 JSON 校验器：遇到畸形输入就停在当前位置，返回此前已读到的成员。
/// 这正好是扫描器想要的「安静跳过坏行」语义——transcript 是 append-only 日志，
/// 崩溃会把最后一行截断，一行坏行不能让整个文件作废。
public struct JSONScan {
  public let bytes: UnsafeRawBufferPointer

  public init(bytes: UnsafeRawBufferPointer) { self.bytes = bytes }

  /// 对 `object.lowerBound` 处对象的每个 `key: value` 直接成员调用 `body`，
  /// 传入 key 的范围（不含引号）与 value 的范围（含引号/花括号）。嵌套对象和数组被整体跳过，不递归。
  public func forEachMember(in object: Range<Int>, _ body: (Range<Int>, Range<Int>) -> Void) {
    var i = object.lowerBound
    guard i < object.upperBound, bytes[i] == UInt8(ascii: "{") else { return }
    i += 1
    while i < object.upperBound {
      i = skipSpace(i, object.upperBound)
      guard i < object.upperBound else { return }
      let c = bytes[i]
      if c == UInt8(ascii: "}") { return }
      if c == UInt8(ascii: ",") { i += 1; continue }
      guard c == UInt8(ascii: "\"") else { return }  // 畸形，停在当前位置
      // 闭合引号不在缓冲区内的 key 没有可报告的范围。这是活跃 transcript 最后一行的常见形态
      // （写入方刚好 flush 到下一个 key 的开引号），必须和其它畸形输入一样停下，
      // 而不是构造出一个反向的 Range 直接崩溃。
      let keyEnd = endOfString(i, object.upperBound)
      guard keyEnd > i + 1, bytes[keyEnd - 1] == UInt8(ascii: "\"") else { return }
      let key = (i + 1)..<(keyEnd - 1)
      i = skipSpace(keyEnd, object.upperBound)
      guard i < object.upperBound, bytes[i] == UInt8(ascii: ":") else { return }
      i = skipSpace(i + 1, object.upperBound)
      guard i < object.upperBound else { return }
      let valueEnd = endOfValue(i, object.upperBound)
      body(key, i..<valueEnd)
      i = valueEnd
    }
  }

  /// 取名为 `key` 的单个成员，没有则为 nil。
  /// 要读同一对象的两个及以上成员时用一次 `forEachMember` 更划算：这里每次查找都重走一遍对象。
  public func member(_ key: StaticString, in object: Range<Int>) -> Range<Int>? {
    var found: Range<Int>?
    forEachMember(in: object) { k, v in
      if found == nil, self.key(k, is: key) { found = v }
    }
    return found
  }

  /// key 的字节是否等于某个 ASCII 字面量。
  public func key(_ range: Range<Int>, is literal: StaticString) -> Bool {
    guard range.count == literal.utf8CodeUnitCount else { return false }
    return literal.withUTF8Buffer { expected in
      for offset in 0..<expected.count where bytes[range.lowerBound + offset] != expected[offset] {
        return false
      }
      return true
    }
  }

  /// 非负整数成员的值。不是纯整数（`null`、小数、字符串）时返回 nil，
  /// 调用方一律把这种情况当作「该字段缺失」。
  public func int64(_ range: Range<Int>) -> Int64? {
    var value: Int64 = 0
    var any = false
    for i in range {
      let c = bytes[i]
      guard c >= UInt8(ascii: "0"), c <= UInt8(ascii: "9") else { return nil }
      value = value * 10 + Int64(c - UInt8(ascii: "0"))
      any = true
    }
    return any ? value : nil
  }

  /// 字符串成员的值（已反转义）。`range` 是 `forEachMember` 给出的带引号范围。
  public func string(_ range: Range<Int>) -> String? {
    guard range.count >= 2, bytes[range.lowerBound] == UInt8(ascii: "\"") else { return nil }
    let inner = (range.lowerBound + 1)..<(range.upperBound - 1)
    var scalars: [UInt8] = []
    scalars.reserveCapacity(inner.count)
    var i = inner.lowerBound
    while i < inner.upperBound {
      let c = bytes[i]
      if c == UInt8(ascii: "\\"), i + 1 < inner.upperBound {
        let next = bytes[i + 1]
        switch next {
        case UInt8(ascii: "n"): scalars.append(UInt8(ascii: "\n"))
        case UInt8(ascii: "t"): scalars.append(UInt8(ascii: "\t"))
        case UInt8(ascii: "r"): scalars.append(UInt8(ascii: "\r"))
        // `\uXXXX` 原样保留：这里读到的字符串只有 POSIX 路径和 ISO 时间戳，
        // 用转义写出来的路径和它自己仍然能一致地做 key。
        default: scalars.append(next)
        }
        i += 2
      } else {
        scalars.append(c)
        i += 1
      }
    }
    return String(decoding: scalars, as: UTF8.self)
  }

  // MARK: - 字节游走

  private func skipSpace(_ from: Int, _ end: Int) -> Int {
    var i = from
    while i < end {
      switch bytes[i] {
      case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"): i += 1
      default: return i
      }
    }
    return i
  }

  /// `from` 处字符串的闭合引号之后一位的下标。
  private func endOfString(_ from: Int, _ end: Int) -> Int {
    var i = from + 1
    while i < end {
      let c = bytes[i]
      if c == UInt8(ascii: "\\") { i += 2; continue }
      if c == UInt8(ascii: "\"") { return i + 1 }
      i += 1
    }
    return end
  }

  /// `from` 处的值（不论何种类型）结束后一位的下标。
  ///
  /// 对象/数组用深度计数整体跳过，并且遇到字符串先整段跳过——否则路径或正文里的
  /// `{`、`]` 会被当成结构字符，把深度算歪。
  public func endOfValue(_ from: Int, _ end: Int) -> Int {
    guard from < end else { return end }
    switch bytes[from] {
    case UInt8(ascii: "\""):
      return endOfString(from, end)
    case UInt8(ascii: "{"), UInt8(ascii: "["):
      var depth = 0
      var i = from
      while i < end {
        let c = bytes[i]
        if c == UInt8(ascii: "\"") {
          i = endOfString(i, end)
          continue
        }
        if c == UInt8(ascii: "{") || c == UInt8(ascii: "[") { depth += 1 }
        if c == UInt8(ascii: "}") || c == UInt8(ascii: "]") {
          depth -= 1
          if depth == 0 { return i + 1 }
        }
        i += 1
      }
      return end
    default:
      var i = from
      while i < end {
        switch bytes[i] {
        case UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]"),
          UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
          return i
        default: i += 1
        }
      }
      return end
    }
  }
}
