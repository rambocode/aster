import Foundation

/// 生产操作信封。动态参数沿用 JSONValue，修订号、租约代次和控制序号独立解码为 UInt64。
/// 此类型只校验身份/范围/前置条件；各操作参数按对应 schema 与领域规则继续验证。
public struct SessionOperationRequest: Codable, Sendable {
  public struct Target: Codable, Sendable {
    public let serverID: String
    public let serverEpoch: String
    public let sessionID: String
  }
  public struct Lease: Codable, Sendable {
    public let leaseID: String
    public let leaseEpoch: UInt64
  }
  public let type: String
  public let requestID: String
  public let clientID: String
  public let scope: SessionOperationScope
  public let operation: SessionOperationKind
  public let target: Target?
  public let expectedRevision: UInt64?
  public let createdAtUnixMs: UInt64?
  /// params 内的租约代数独立保留 UInt64 精度。
  public let expectedLeaseEpoch: UInt64?
  public let lease: Lease?
  public let controlSequence: UInt64?
  public let params: JSONValue
  public let extensions: [String: String]?

  enum CodingKeys: String, CodingKey { case type, requestID, clientID, scope, operation, target, expectedRevision, createdAtUnixMs, lease, controlSequence, params, extensions }
  struct ParameterKey: CodingKey {
    let stringValue: String
    let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    type = try c.decode(String.self, forKey: .type)
    requestID = try c.decode(String.self, forKey: .requestID)
    clientID = try c.decode(String.self, forKey: .clientID)
    scope = try c.decode(SessionOperationScope.self, forKey: .scope)
    operation = try c.decode(SessionOperationKind.self, forKey: .operation)
    target = try c.decodeIfPresent(Target.self, forKey: .target)
    expectedRevision = try c.decodeIfPresent(UInt64.self, forKey: .expectedRevision)
    createdAtUnixMs = try c.decodeIfPresent(UInt64.self, forKey: .createdAtUnixMs)
    lease = try c.decodeIfPresent(Lease.self, forKey: .lease)
    controlSequence = try c.decodeIfPresent(UInt64.self, forKey: .controlSequence)
    params = try c.decode(JSONValue.self, forKey: .params)
    extensions = try c.decodeIfPresent([String: String].self, forKey: .extensions)
    if operation == .terminalAttach, case .object(let object) = params, object["expectedLeaseEpoch"] != nil {
      let p = try c.nestedContainer(keyedBy: ParameterKey.self, forKey: .params)
      expectedLeaseEpoch = try p.decode(UInt64.self, forKey: ParameterKey(stringValue: "expectedLeaseEpoch")!)
    } else { expectedLeaseEpoch = nil }
  }
  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: CodingKeys.self)
    try c.encode(type, forKey: .type)
    try c.encode(requestID, forKey: .requestID)
    try c.encode(clientID, forKey: .clientID)
    try c.encode(scope, forKey: .scope)
    try c.encode(operation, forKey: .operation)
    try c.encodeIfPresent(target, forKey: .target)
    try c.encodeIfPresent(expectedRevision, forKey: .expectedRevision)
    try c.encodeIfPresent(createdAtUnixMs, forKey: .createdAtUnixMs)
    try c.encodeIfPresent(lease, forKey: .lease)
    try c.encodeIfPresent(controlSequence, forKey: .controlSequence)
    try c.encodeIfPresent(extensions, forKey: .extensions)
    if let expectedLeaseEpoch, case .object(let object) = params {
      var p = c.nestedContainer(keyedBy: ParameterKey.self, forKey: .params)
      for (key, value) in object where key != "expectedLeaseEpoch" {
        try p.encode(value, forKey: ParameterKey(stringValue: key)!)
      }
      try p.encode(expectedLeaseEpoch, forKey: ParameterKey(stringValue: "expectedLeaseEpoch")!)
    } else { try c.encode(params, forKey: .params) }
  }

  public func validateEnvelope() throws {
    let metadata = operation.metadata
    guard type == "request", Self.validID(requestID), Self.validID(clientID) else { throw SessionRequestError.invalidIdentity }
    guard scope == metadata.scope else { throw SessionRequestError.wrongScope }
    if scope == .session {
      guard let target, [target.serverID, target.serverEpoch, target.sessionID].allSatisfy(Self.validID) else {
        throw SessionRequestError.invalidTarget
      }
    } else if target != nil { throw SessionRequestError.invalidTarget }
    guard (createdAtUnixMs != nil) == metadata.requiresCreatedAt,
      (expectedRevision != nil) == metadata.requiresRevision,
      (lease != nil) == metadata.requiresLease,
      (controlSequence != nil) == metadata.requiresControlSequence
    else { throw SessionRequestError.invalidPreconditions }
    if let lease, !Self.validID(lease.leaseID) { throw SessionRequestError.invalidIdentity }
    guard case .object = params else { throw SessionRequestError.invalidParameters }
    if operation == .terminalAttach, case .object(let object) = params {
      if let takeover = object["takeover"] {
        guard case .bool(let enabled) = takeover else { throw SessionRequestError.invalidParameters }
        if enabled && expectedLeaseEpoch == nil { throw SessionRequestError.invalidPreconditions }
      }
    }
    if let extensions {
      guard extensions.count <= 32, extensions.values.allSatisfy({ $0.utf8.count <= 4096 }) else {
        throw SessionRequestError.invalidParameters
      }
    }
  }

  static func validID(_ value: String) -> Bool {
    guard value.utf8.count == 36, let id = UUID(uuidString: value) else { return false }
    return value == id.uuidString.lowercased()
  }
}

public enum SessionRequestError: Error, Equatable, Sendable {
  case invalidIdentity, wrongScope, invalidTarget, invalidPreconditions, invalidParameters
}
