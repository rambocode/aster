import Foundation

/// NDJSON 行缓冲器：把任意切分的字节流按 `\n` 切成完整行。server 与 CLI 共用。
/// 未闭合的行累计超过 `maximumLineBytes` 即抛错，调用方应回 `request_too_large` 并断开，
/// 防止对端用无换行的超长流耗尽内存。
public struct NDJSONFraming: Sendable {
  public enum FramingError: Error, Equatable, Sendable {
    case lineTooLarge(bytes: Int)
  }

  public let maximumLineBytes: Int
  private var buffer = Data()

  public init(maximumLineBytes: Int = AsterControlProtocol.maximumRequestBytes) {
    self.maximumLineBytes = maximumLineBytes
  }

  /// 缓冲区当前未闭合的字节数。
  public var pendingBytes: Int { buffer.count }

  /// 追加数据并返回其中所有完整行（不含换行符；`\r\n` 的 `\r` 也剥掉）。空行被跳过。
  /// 抛错后缓冲区已清空，连接应被关闭。
  public mutating func append(_ data: Data) throws -> [Data] {
    buffer.append(data)
    var lines: [Data] = []
    while let newline = buffer.firstIndex(of: 0x0A) {
      var line = buffer[buffer.startIndex..<newline]
      if line.last == 0x0D { line = line.dropLast() }
      // 完整行本身也受上限约束，不能靠「刚好带了换行」绕过。
      guard line.count <= maximumLineBytes else {
        let size = line.count
        buffer.removeAll()
        throw FramingError.lineTooLarge(bytes: size)
      }
      if !line.isEmpty { lines.append(Data(line)) }
      buffer.removeSubrange(buffer.startIndex...newline)
    }
    guard buffer.count <= maximumLineBytes else {
      let size = buffer.count
      buffer.removeAll()
      throw FramingError.lineTooLarge(bytes: size)
    }
    return lines
  }

  /// 丢弃未闭合的残余数据。
  public mutating func reset() {
    buffer.removeAll()
  }

  /// 把一条 JSON 行编码成带换行的输出帧。
  public static func frame(_ line: Data) -> Data {
    var output = line
    output.append(0x0A)
    return output
  }
}
