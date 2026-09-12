import Foundation

/// 服务端握手真值；解码时校验格式，连接时另行协商所需能力。
/// 未知可选字段/能力保留兼容性；发行版本不参与协议主版本判定。
public struct SessionHandshake: Codable, Equatable, Sendable {
  public let type: String
  public let protocolMajor: UInt16
  public let protocolMinor: UInt16
  public let serverID: String
  public let serverEpoch: String
  public let sessionID: String
  public let platform: String
  public let capabilities: [String]

  public static let requiredCapabilities: Set<String> = [
    "session_snapshot", "terminal_control", "surface_interest", "health_check",
  ]

  private enum CodingKeys: String, CodingKey {
    case type, protocolMajor, protocolMinor, serverID, serverEpoch, sessionID, platform, capabilities
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    type = try values.decode(String.self, forKey: .type)
    protocolMajor = try values.decode(UInt16.self, forKey: .protocolMajor)
    protocolMinor = try values.decode(UInt16.self, forKey: .protocolMinor)
    serverID = try values.decode(String.self, forKey: .serverID)
    serverEpoch = try values.decode(String.self, forKey: .serverEpoch)
    sessionID = try values.decode(String.self, forKey: .sessionID)
    platform = try values.decode(String.self, forKey: .platform)
    capabilities = try values.decode([String].self, forKey: .capabilities)
    guard type == "hello", [serverID, serverEpoch, sessionID].allSatisfy(Self.isIdentity),
      ["macos-aarch64", "macos-x86_64", "linux-aarch64", "linux-x86_64"].contains(platform),
      capabilities.count <= 128, Set(capabilities).count == capabilities.count,
      capabilities.allSatisfy(Self.isCapability)
    else { throw SessionHandshakeError.invalidHandshake }
  }

  /// 验证协议兼容性；版本或能力不足时不允许恢复输入。
  public func negotiate(required: Set<String> = Self.requiredCapabilities) throws {
    guard protocolMajor == 1 else { throw SessionHandshakeError.incompatibleMajor }
    let missing = required.subtracting(capabilities)
    guard missing.isEmpty else { throw SessionHandshakeError.missingCapabilities(missing.sorted()) }
  }

  private static func isIdentity(_ value: String) -> Bool {
    guard value.utf8.count == 36, let id = UUID(uuidString: value) else { return false }
    return id.uuidString.lowercased() == value
  }

  private static func isCapability(_ value: String) -> Bool {
    let bytes = Array(value.utf8)
    guard (1...64).contains(bytes.count), let first = bytes.first, (97...122).contains(first) else {
      return false
    }
    return bytes.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }
  }
}

public enum SessionHandshakeError: Error, Equatable, Sendable {
  case invalidHandshake
  case incompatibleMajor
  case missingCapabilities([String])
}
