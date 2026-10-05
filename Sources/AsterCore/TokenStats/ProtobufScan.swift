// 无 schema 的 protobuf 浅层扫描器：只切出一层字段，够从二进制 blob 里取几个整数和子消息。
import Foundation

/// 把一段 protobuf 字节切成一层字段。
///
/// 为什么不引入 SwiftProtobuf：Antigravity 的 `.proto` 没有公开，我们只按字段号取几个
/// varint，不值得为此加依赖和生成代码。嵌套消息由调用方对 `.bytes` 再扫一次。
/// 输入来自别家的私有格式，随时可能变：任何畸形（截断、非法 wire type、字段号 0）
/// 都返回 nil，由调用方整条跳过，不抛错。
public enum ProtobufScan {
  /// 一个字段的值。定长数值用不到，只跳过不解码。
  public enum Value: Equatable, Sendable {
    case varint(UInt64)
    case bytes(ArraySlice<UInt8>)
    case fixed
  }

  /// 一个字段：字段号 + 值。
  public struct Field: Equatable, Sendable {
    public var number: Int
    public var value: Value
  }

  /// 单层字段数上限；正常消息只有几十个字段，超过说明拿到的不是预期数据。
  static let maximumFields = 4096

  /// 切出一层字段。畸形输入返回 nil。
  public static func fields(_ bytes: ArraySlice<UInt8>) -> [Field]? {
    var index = bytes.startIndex
    var result: [Field] = []
    while index < bytes.endIndex {
      guard result.count < maximumFields, let key = readVarint(bytes, &index) else { return nil }
      let number = Int(truncatingIfNeeded: key >> 3)
      guard number > 0 else { return nil }
      switch key & 7 {
      case 0:
        guard let value = readVarint(bytes, &index) else { return nil }
        result.append(Field(number: number, value: .varint(value)))
      case 1:
        guard bytes.endIndex - index >= 8 else { return nil }
        index += 8
        result.append(Field(number: number, value: .fixed))
      case 2:
        guard let length = readVarint(bytes, &index), length <= UInt64(bytes.endIndex - index)
        else { return nil }
        let end = index + Int(length)
        result.append(Field(number: number, value: .bytes(bytes[index..<end])))
        index = end
      case 5:
        guard bytes.endIndex - index >= 4 else { return nil }
        index += 4
        result.append(Field(number: number, value: .fixed))
      default:
        // wire type 3 / 4（group）早已废弃，6 / 7 不存在：遇到就说明这不是 protobuf。
        return nil
      }
    }
    return result
  }

  /// 第一个指定字段号的 varint；没有或类型不符返回 nil。
  public static func varint(_ fields: [Field], _ number: Int) -> UInt64? {
    for field in fields where field.number == number {
      if case .varint(let value) = field.value { return value }
    }
    return nil
  }

  /// 第一个指定字段号的长度前缀值（子消息或字符串）；没有或类型不符返回 nil。
  public static func bytes(_ fields: [Field], _ number: Int) -> ArraySlice<UInt8>? {
    for field in fields where field.number == number {
      if case .bytes(let value) = field.value { return value }
    }
    return nil
  }

  /// 读一个 base-128 varint 并推进游标。超过 10 字节或数据截断返回 nil。
  private static func readVarint(_ bytes: ArraySlice<UInt8>, _ index: inout Int) -> UInt64? {
    var value: UInt64 = 0
    var shift: UInt64 = 0
    while index < bytes.endIndex, shift < 70 {
      let byte = bytes[index]
      index += 1
      value |= UInt64(byte & 0x7F) << shift
      if byte & 0x80 == 0 { return value }
      shift += 7
    }
    return nil
  }
}
