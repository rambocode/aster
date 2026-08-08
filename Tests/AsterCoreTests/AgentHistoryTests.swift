import Foundation
import Testing

@testable import AsterCore

@Test func transcriptParserExtractsMessagesReasoningAndToolCallsAcrossSchemas() throws {
  let jsonLines = #"""
    {"type":"user","timestamp":"2026-08-08T10:00:00Z","message":{"content":"Fix the parser"}}
    {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"Check bounds"},{"type":"text","text":"I will inspect it."},{"type":"tool_use","name":"Read","input":{"path":"Parser.swift"}}]}}
    {"type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Codex result"}]}}
    """#

  let report = try AgentTranscriptParser.parse(
    Data(jsonLines.utf8),
    provider: .claudeCode
  )

  #expect(report.skippedRecordCount == 0)
  #expect(
    report.entries.map(\.kind) == [
      .message(role: .user),
      .reasoning,
      .message(role: .assistant),
      .toolCall(name: "Read"),
      .message(role: .assistant),
    ]
  )
  #expect(report.entries.map(\.text).contains("Check bounds"))
  #expect(report.entries.map(\.text).contains("Codex result"))
}

@Test func transcriptParserSkipsMalformedRecordsAndTruncatesEntryContentOnUTF8Boundaries() throws {
  let jsonLines = #"""
    {"type":"user","message":{"content":"1234567890🙂more"}}
    not-json
    """#
  let limits = AgentTranscriptLimits(
    maximumInputBytes: 1_024,
    maximumRecordBytes: 512,
    maximumRecords: 10,
    maximumEntries: 10,
    maximumEntryBytes: 12
  )

  let report = try AgentTranscriptParser.parse(
    Data(jsonLines.utf8),
    provider: .claudeCode,
    limits: limits
  )

  #expect(report.entries.count == 1)
  #expect(report.entries[0].text == "1234567890")
  #expect(report.truncatedEntryCount == 1)
  #expect(report.skippedRecordCount == 1)
}

@Test func transcriptParserRejectsInputRecordAndCountLimitViolations() {
  let inputLimited = AgentTranscriptLimits(
    maximumInputBytes: 8,
    maximumRecordBytes: 8,
    maximumRecords: 1,
    maximumEntries: 1,
    maximumEntryBytes: 8
  )
  #expect(throws: AgentTranscriptError.inputTooLarge(maximumBytes: 8)) {
    try AgentTranscriptParser.parse(
      Data(#"{"type":"user"}"#.utf8),
      provider: .codex,
      limits: inputLimited
    )
  }

  let recordLimited = AgentTranscriptLimits(
    maximumInputBytes: 100,
    maximumRecordBytes: 8,
    maximumRecords: 10,
    maximumEntries: 10,
    maximumEntryBytes: 10
  )
  #expect(throws: AgentTranscriptError.recordTooLarge(index: 0, maximumBytes: 8)) {
    try AgentTranscriptParser.parse(
      Data(#"{"type":"user"}"#.utf8),
      provider: .codex,
      limits: recordLimited
    )
  }

  let countLimited = AgentTranscriptLimits(
    maximumInputBytes: 100,
    maximumRecordBytes: 50,
    maximumRecords: 1,
    maximumEntries: 10,
    maximumEntryBytes: 10
  )
  #expect(throws: AgentTranscriptError.tooManyRecords(maximum: 1)) {
    try AgentTranscriptParser.parse(
      Data("{}\n{}".utf8),
      provider: .codex,
      limits: countLimited
    )
  }
}

@Test func transcriptParserCountsEveryTopLevelArrayItemAgainstTheRecordLimit() {
  let limits = AgentTranscriptLimits(
    maximumInputBytes: 100,
    maximumRecordBytes: 100,
    maximumRecords: 1,
    maximumEntries: 10,
    maximumEntryBytes: 10
  )

  #expect(throws: AgentTranscriptError.tooManyRecords(maximum: 1)) {
    try AgentTranscriptParser.parse(
      Data(#"[{"type":"user","content":"a"},{"type":"user","content":"b"}]"#.utf8),
      provider: .codex,
      limits: limits
    )
  }
}

@Test func historySearchMatchesMetadataAndTranscriptWithBoundedResults() throws {
  let first = AgentSessionMetadata.stub(
    id: "first",
    title: "Payment migration",
    updatedAt: Date(timeIntervalSince1970: 20)
  )
  let second = AgentSessionMetadata.stub(
    id: "second",
    title: "Unrelated",
    updatedAt: Date(timeIntervalSince1970: 30)
  )
  let firstTranscript = AgentTranscriptReport(
    entries: [
      AgentTranscriptEntry(
        sourceRecordIndex: 0,
        kind: .message(role: .assistant),
        timestamp: nil,
        text: "Resolved the PAYMENT failure safely"
      )
    ],
    skippedRecordCount: 0,
    truncatedEntryCount: 0
  )

  let results = try AgentHistorySearch.search(
    query: "payment failure",
    histories: [
      AgentSessionHistory(metadata: second, transcript: .empty),
      AgentSessionHistory(metadata: first, transcript: firstTranscript),
    ],
    limit: 1
  )

  #expect(results.count == 1)
  #expect(results[0].sessionID == "first")
  #expect(results[0].snippet?.localizedCaseInsensitiveContains("payment") == true)
  #expect(results[0].snippet?.utf8.count ?? 0 <= AgentHistorySearch.maximumSnippetBytes)
}

@Test func resumeDescriptorChoosesLivePaneOrNativeResumeWithoutLosingConfiguration() {
  let metadata = AgentSessionMetadata.stub(
    id: "session-1",
    title: "Parser",
    updatedAt: Date(timeIntervalSince1970: 20)
  )

  #expect(metadata.resumeDescriptor(isCurrentlyRunning: true).action == .focusLiveSession)
  let stopped = metadata.resumeDescriptor(isCurrentlyRunning: false)
  #expect(stopped.action == .launchNativeResume)
  #expect(stopped.configuration == metadata.configuration)
  #expect(stopped.sessionID == metadata.id)
}

@Test func historySearchRejectsAnOversizedCallerConstructedIndex() {
  let metadata = AgentSessionMetadata.stub(
    id: "large",
    title: "Large",
    updatedAt: Date(timeIntervalSince1970: 20)
  )
  let transcript = AgentTranscriptReport(
    entries: [
      AgentTranscriptEntry(
        sourceRecordIndex: 0,
        kind: .message(role: .assistant),
        timestamp: nil,
        text: "123456789"
      )
    ],
    skippedRecordCount: 0,
    truncatedEntryCount: 0
  )

  #expect(throws: AgentHistorySearchError.indexTooLarge(maximumBytes: 8)) {
    try AgentHistorySearch.search(
      query: "large",
      histories: [AgentSessionHistory(metadata: metadata, transcript: transcript)],
      limit: 1,
      limits: AgentHistorySearchLimits(maximumIndexedBytes: 8)
    )
  }
}

extension AgentSessionMetadata {
  fileprivate static func stub(
    id: String,
    title: String,
    updatedAt: Date
  ) -> AgentSessionMetadata {
    AgentSessionMetadata(
      id: id,
      configuration: AgentSessionConfiguration(
        provider: .codex,
        providerIdentifier: "openai",
        model: "gpt-5.4",
        systemPrompt: "Stay focused"
      ),
      projectDirectory: "/tmp/project",
      title: title,
      createdAt: Date(timeIntervalSince1970: 10),
      updatedAt: updatedAt,
      transcriptFileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl")
    )
  }
}
