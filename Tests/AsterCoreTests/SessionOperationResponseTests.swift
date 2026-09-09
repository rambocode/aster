import Foundation
import Testing
@testable import AsterCore

private struct AttachmentResult: Codable, Sendable {
  let attachmentID: String
  let terminalID: String
  let readOnly: Bool
  let lease: SessionOperationRequest.Lease
}
private struct RevokedLease: Codable, Sendable {
  let terminalID: String
  let leaseID: String
  let leaseEpoch: UInt64
  let reason: String
}

@Test func remoteRepliesMatchSharedFixturesAndKeepNestedCountersExact() throws {
  struct Fixture: Decodable {
    let name: String
    let kind: String
    let requestJSON: String
    let valueJSON: String
    let afterSequence: UInt64?
    let minimumRevision: UInt64?
    let result: String
  }
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf:
    root.appendingPathComponent("SessionRuntime/protocol/reply-fixtures.json")))
  for fixture in fixtures {
    let request = try JSONDecoder().decode(SessionOperationRequest.self, from: Data(fixture.requestJSON.utf8))
    let bytes = Data(fixture.valueJSON.utf8)
    var result = "ok"
    do {
      switch fixture.kind {
      case "response":
        let value = try JSONDecoder().decode(SessionOperationResponse<AttachmentResult>.self, from: bytes)
        try value.validate(for: request)
        let roundtrip = try JSONDecoder().decode(SessionOperationResponse<AttachmentResult>.self,
          from: JSONEncoder().encode(value))
        #expect(roundtrip.revision == UInt64.max)
        #expect(roundtrip.result.lease.leaseEpoch == UInt64.max)
      case "error":
        let value = try JSONDecoder().decode(SessionOperationFailure.self, from: bytes)
        try value.validate(for: request)
        let roundtrip = try JSONDecoder().decode(SessionOperationFailure.self, from: JSONEncoder().encode(value))
        #expect(roundtrip.error.code == value.error.code)
      case "event":
        let value = try JSONDecoder().decode(SessionEvent<RevokedLease>.self, from: bytes)
        try value.validate(event: "lease.revoked", target: #require(request.target), after: fixture.afterSequence, minimumRevision: fixture.minimumRevision)
        let roundtrip = try JSONDecoder().decode(SessionEvent<RevokedLease>.self, from: JSONEncoder().encode(value))
        #expect(roundtrip.sequence == UInt64.max)
        #expect(roundtrip.body.leaseEpoch == UInt64.max)
      default: Issue.record("Unknown fixture kind")
      }
    } catch let error as SessionResponseError { result = String(describing: error) }
    #expect(result == fixture.result, "\(fixture.name)")
  }
}


private struct ObservationResult: Codable, Sendable {
  let attachmentID: String
  let terminalID: String
  let readOnly: Bool
  let currentLeaseEpoch: UInt64
}

@Test func remoteObservationPreservesExactCurrentLeaseEpoch() throws {
  struct Fixture: Decodable {
    let requestJSON: String
    let valueJSON: String
    let epoch: UInt64
  }
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf:
    root.appendingPathComponent("SessionRuntime/protocol/observe-fixtures.json")))
  for fixture in fixtures {
    let request = try JSONDecoder().decode(SessionOperationRequest.self, from: Data(fixture.requestJSON.utf8))
    let value = try JSONDecoder().decode(SessionOperationResponse<ObservationResult>.self,
      from: Data(fixture.valueJSON.utf8))
    try value.validate(for: request)
    let roundtrip = try JSONDecoder().decode(SessionOperationResponse<ObservationResult>.self,
      from: JSONEncoder().encode(value))
    #expect(roundtrip.result.readOnly)
    #expect(roundtrip.result.currentLeaseEpoch == fixture.epoch)
  }
}
