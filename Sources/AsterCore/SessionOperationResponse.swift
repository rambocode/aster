import Foundation

/// 结果类型由操作绑定，避免把嵌套租约/事件计数降为 Double。
public struct SessionOperationResponse<Result: Codable & Sendable>: Codable, Sendable {
  public let type: String
  public let requestID: String
  public let operation: SessionOperationKind
  public let scope: SessionOperationScope
  public let target: SessionOperationRequest.Target?
  public let revision: UInt64?
  public let result: Result

  /// 在应用结果前核对在途请求及服务实例；仅结构正确不代表响应属于当前任务。
  public func validate(for request: SessionOperationRequest) throws {
    try request.validateEnvelope()
    guard type == "response", requestID == request.requestID,
      operation == request.operation, scope == request.scope
    else { throw SessionResponseError.requestMismatch }
    if scope == .session {
      guard let target, let expected = request.target, revision != nil,
        target.serverID == expected.serverID, target.serverEpoch == expected.serverEpoch,
        target.sessionID == expected.sessionID
      else { throw SessionResponseError.targetMismatch }
    } else if target != nil || revision != nil { throw SessionResponseError.targetMismatch }
  }
}

public struct SessionRemoteError: Codable, Sendable {
  public enum Retry: String, Codable, Sendable {
    case never
    case afterQuery = "after_query"
    case afterReconnect = "after_reconnect"
    case backoff
  }
  public let code: String
  public let message: String
  public let retry: Retry
}

public struct SessionOperationFailure: Codable, Sendable {
  public let type: String
  public let requestID: String
  public let operation: String
  public let scope: SessionOperationScope
  public let target: SessionOperationRequest.Target?
  public let error: SessionRemoteError

  public func validate(for request: SessionOperationRequest) throws {
    try request.validateEnvelope()
    guard type == "error", requestID == request.requestID,
      operation == request.operation.rawValue, scope == request.scope
    else { throw SessionResponseError.requestMismatch }
    if let target {
      guard let expected = request.target, target.serverID == expected.serverID,
        target.serverEpoch == expected.serverEpoch, target.sessionID == expected.sessionID
      else { throw SessionResponseError.targetMismatch }
    }
    guard let first = error.code.utf8.first, (97...122).contains(first), error.code.utf8.count <= 64,
      error.code.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 95 }),
      error.message.utf8.count <= 4096
    else { throw SessionResponseError.invalidError }
  }
}

public struct SessionEvent<Body: Codable & Sendable>: Codable, Sendable {
  public let type: String
  public let event: String
  public let eventID: String
  public let target: SessionOperationRequest.Target
  public let sequence: UInt64
  public let revision: UInt64
  public let body: Body

  /// 事件必须来自当前实例；序号不得回退，缺口由调用方触发完整状态同步。
  public func validate(event expectedEvent: String, target expected: SessionOperationRequest.Target, after sequence: UInt64?, minimumRevision: UInt64? = nil) throws {
    guard SessionOperationRequest.validID(eventID) else { throw SessionResponseError.invalidEventID }
    guard event == expectedEvent else { throw SessionResponseError.eventMismatch }
    guard type == "event", target.serverID == expected.serverID,
      target.serverEpoch == expected.serverEpoch, target.sessionID == expected.sessionID
    else { throw SessionResponseError.targetMismatch }
    if let sequence {
      guard self.sequence > sequence else { throw SessionResponseError.staleEvent }
      guard self.sequence == sequence + 1 else { throw SessionResponseError.sequenceGap }
    }
    if let minimumRevision, revision < minimumRevision { throw SessionResponseError.staleRevision }
  }
}

public enum SessionResponseError: Error, Equatable, Sendable {
  case requestMismatch, targetMismatch, invalidError, staleEvent, sequenceGap, eventMismatch, invalidEventID, staleRevision
}
