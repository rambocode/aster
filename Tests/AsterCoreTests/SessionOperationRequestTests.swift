import Foundation
import Testing
@testable import AsterCore

@Test func remoteOperationEnvelopesMatchSharedFixturesAndPreserveCounters() throws {
  struct Fixture: Decodable {
    let name: String
    let result: String
    let value: SessionOperationRequest
  }
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let data = try Data(contentsOf: root.appendingPathComponent("SessionRuntime/protocol/envelope-fixtures.json"))
  let fixtures = try JSONDecoder().decode([Fixture].self, from: data)
  var covered = Set<SessionOperationKind>()
  for fixture in fixtures {
    var result = "ok"
    do { try fixture.value.validateEnvelope() }
    catch let error as SessionRequestError { result = String(describing: error) }
    #expect(result == fixture.result, "\(fixture.name)")
    covered.insert(fixture.value.operation)
    let encoded = try JSONEncoder().encode(fixture.value)
    let decoded = try JSONDecoder().decode(SessionOperationRequest.self, from: encoded)
    #expect(decoded.operation == fixture.value.operation)
    #expect(decoded.controlSequence == fixture.value.controlSequence)
    #expect(decoded.createdAtUnixMs == fixture.value.createdAtUnixMs)
    #expect(decoded.expectedLeaseEpoch == fixture.value.expectedLeaseEpoch)
    if fixture.name == "takeover maximum epoch" { #expect(decoded.expectedLeaseEpoch == UInt64.max) }
    if fixture.name == "maximum creation timestamp" { #expect(decoded.createdAtUnixMs == UInt64.max) }
    if fixture.name == "maximum counters" {
      #expect(decoded.controlSequence == UInt64.max)
      #expect(decoded.lease?.leaseEpoch == UInt64.max)
    }
  }
  #expect(covered == Set(SessionOperationKind.allCases))
}
