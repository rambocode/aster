import Foundation
import Testing
@testable import AsterCore

private struct WireFixture: Decodable {
  let name: String
  let wire: [UInt8]
  let payload: [UInt8]?
  let kind: UInt8?
  let error: String?
}

@Test func remoteFrameSharedFixturesMatchAtEverySplit() throws {
  let root = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
  let fixtures = try JSONDecoder().decode(
    [WireFixture].self,
    from: Data(contentsOf: root.appendingPathComponent("SessionRuntime/protocol/framing-fixtures.json")))
  for fixture in fixtures {
    for split in 0...fixture.wire.count {
      var decoder = SessionWireDecoder()
      var frames: [SessionWireFrame] = []
      var caught: SessionWireError?
      do {
        for part in [Data(fixture.wire[..<split]), Data(fixture.wire[split...])] {
          let result = try decoder.feed(part)
          #expect(result.consumed == part.count)
          if let frame = result.frame { frames.append(frame) }
        }
        try decoder.finish()
      } catch let error as SessionWireError { caught = error }
      if let expected = fixture.error {
        #expect(caught.map { String(describing: $0) } == expected, "\(fixture.name), split \(split)")
      } else {
        #expect(caught == nil)
        #expect(frames.count == 1)
        #expect(frames.first?.payload == Data(fixture.payload!))
        #expect(frames.first?.kind.rawValue == fixture.kind)
        #expect(frames.first?.encoded() == Data(fixture.wire))
      }
    }
  }
}

@Test func remoteFrameCoalescedDataRetainsFrameBoundariesAndSliceIndices() throws {
  let first = try SessionWireFrame(kind: .control, payload: Data("{}".utf8))
  let second = try SessionWireFrame(kind: .surface, payload: Data([0, 255, 65]))
  let batch = first.encoded() + second.encoded()
  var decoder = SessionWireDecoder()
  let head = try decoder.feed(batch)
  #expect(head.frame == first)
  #expect(head.consumed == first.encoded().count)
  let tail = try decoder.feed(batch.dropFirst(head.consumed))
  #expect(tail.frame == second)
  try decoder.finish()
}

@Test func remoteFrameInvalidHeaderPermanentlyInvalidatesDecoder() throws {
  var decoder = SessionWireDecoder()
  #expect(throws: SessionWireError.invalidFrameLength) {
    try decoder.feed(Data([1, 255, 255, 255, 255]))
  }
  #expect(throws: SessionWireError.decoderFailed) { try decoder.feed(Data()) }
  #expect(throws: SessionWireError.decoderFailed) { try decoder.finish() }
}
