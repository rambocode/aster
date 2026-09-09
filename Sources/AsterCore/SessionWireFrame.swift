import Foundation

/// 后台会话的传输帧；控制负载的 JSON/权限校验由上层协议负责。
public struct SessionWireFrame: Equatable, Sendable {
  public enum Kind: UInt8, Sendable {
    case control = 1
    case surface = 2

    public var maximumPayloadBytes: Int {
      switch self {
      case .control: 1_048_576
      case .surface: 262_144
      }
    }
  }

  public let kind: Kind
  public let payload: Data

  public init(kind: Kind, payload: Data) throws {
    guard !payload.isEmpty, payload.count <= kind.maximumPayloadBytes else {
      throw SessionWireError.invalidFrameLength
    }
    self.kind = kind
    self.payload = payload
  }

  /// 生成 kind + 四字节大端长度 + payload，不执行负载中的任何指令。
  public func encoded() -> Data {
    let count = UInt32(payload.count)
    var result = Data([
      kind.rawValue, UInt8(truncatingIfNeeded: count >> 24),
      UInt8(truncatingIfNeeded: count >> 16), UInt8(truncatingIfNeeded: count >> 8),
      UInt8(truncatingIfNeeded: count),
    ])
    result.append(payload)
    return result
  }
}

public enum SessionWireError: Error, Equatable, Sendable {
  case unknownFrameKind
  case invalidFrameLength
  case truncatedFrame
  case decoderFailed
}

/// 每次最多解码一帧并返回实际消费量，调用方保留同批输入中的后续帧。
/// 解码器只缓存当前帧；长度校验在 payload 分配前完成。协议错误后必须丢弃连接。
public struct SessionWireDecoder: Sendable {
  private var header: [UInt8] = []
  private var payload = Data()
  private var complete = false
  private var failed = false

  public init() {}

  public mutating func feed(_ bytes: Data) throws -> (frame: SessionWireFrame?, consumed: Int) {
    guard !failed else { throw SessionWireError.decoderFailed }
    if complete {
      header.removeAll(keepingCapacity: true)
      payload.removeAll(keepingCapacity: true)
      complete = false
    }
    var consumed = 0
    while header.count < 5 && consumed < bytes.count {
      header.append(bytes[bytes.startIndex + consumed])
      consumed += 1
    }
    guard header.count == 5 else { return (nil, consumed) }
    guard let kind = SessionWireFrame.Kind(rawValue: header[0]) else {
      failed = true
      throw SessionWireError.unknownFrameKind
    }
    let expected = header.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
    guard expected > 0, expected <= kind.maximumPayloadBytes else {
      failed = true
      throw SessionWireError.invalidFrameLength
    }
    let count = min(expected - payload.count, bytes.count - consumed)
    let start = bytes.startIndex + consumed
    payload.append(contentsOf: bytes[start..<(start + count)])
    consumed += count
    guard payload.count == expected else { return (nil, consumed) }
    complete = true
    return (try SessionWireFrame(kind: kind, payload: payload), consumed)
  }

  /// 连接 EOF 时调用；残留帧头或半个 payload 不能被视作正常分离。
  public func finish() throws {
    guard !failed else { throw SessionWireError.decoderFailed }
    guard complete || header.isEmpty else { throw SessionWireError.truncatedFrame }
  }
}
