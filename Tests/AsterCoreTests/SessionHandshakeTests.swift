import Foundation
import Testing
@testable import AsterCore

private func handshakePayload(major: Int = 1, capabilities: [String]? = nil) throws -> Data {
  try JSONSerialization.data(withJSONObject: [
    "type": "hello", "protocolMajor": major, "protocolMinor": 999,
    "serverID": "12345678-1234-1234-1234-123456789abc",
    "serverEpoch": "12345678-1234-1234-1234-123456789abd",
    "sessionID": "12345678-1234-1234-1234-123456789abe",
    "platform": "linux-x86_64", "futureField": true,
    "capabilities": capabilities ?? Array(SessionHandshake.requiredCapabilities) + ["future_capability"],
  ])
}

@Test func remoteHandshakeAllowsNewMinorAndUnknownOptionalFields() throws {
  let value = try JSONDecoder().decode(SessionHandshake.self, from: handshakePayload())
  try value.negotiate()
  #expect(value.capabilities.contains("future_capability"))
}

@Test func remoteHandshakeRejectsMissingCapabilitiesAndIncompatibleMajor() throws {
  let incompatible = try JSONDecoder().decode(SessionHandshake.self, from: handshakePayload(major: 2))
  #expect(throws: SessionHandshakeError.incompatibleMajor) { try incompatible.negotiate() }
  let limited = try JSONDecoder().decode(SessionHandshake.self, from: handshakePayload(capabilities: ["health_check"]))
  #expect(throws: SessionHandshakeError.missingCapabilities(["session_snapshot", "surface_interest", "terminal_control"])) {
    try limited.negotiate()
  }
}

@Test func remoteHandshakeRejectsDuplicateOrMalformedCapabilities() throws {
  for capabilities in [["health_check", "health_check"], ["invalid capability"], [String(repeating: "a", count: 65)]] {
    #expect(throws: SessionHandshakeError.invalidHandshake) {
      try JSONDecoder().decode(SessionHandshake.self, from: handshakePayload(capabilities: capabilities))
    }
  }
}

@Test func remoteHandshakeSharedFixturesAgreeWithRuntime() throws {
  // Decode the outer fixture independently so invalid handshakes remain test cases.
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let bytes = try Data(contentsOf: root.appendingPathComponent("SessionRuntime/protocol/hello-fixtures.json"))
  let cases = try #require(JSONSerialization.jsonObject(with: bytes) as? [[String: Any]])
  for item in cases {
    let expected = try #require(item["result"] as? String)
    let payload = try JSONSerialization.data(withJSONObject: #require(item["hello"]))
    var result = "ok"
    do {
      try JSONDecoder().decode(SessionHandshake.self, from: payload).negotiate()
    } catch let error as SessionHandshakeError {
      switch error {
      case .invalidHandshake: result = "invalidHandshake"
      case .incompatibleMajor: result = "incompatibleMajor"
      case .missingCapabilities: result = "missingCapabilities"
      }
    }
    #expect(result == expected)
  }
}
