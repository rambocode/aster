import Foundation
import Testing

@testable import AsterCore

// provider 自维护的会话名：Claude 的 ai-title / custom-title 记录、Codex 的 session_index。

@Test func claudeTitleScanTakesLastRecordAndPrefersCustomTitle() {
  let head = """
    {"type":"user","message":{"content":"the word ai-title inside a prompt must not count"}}
    {"type":"ai-title","aiTitle":"  First  AI\\ttitle ","sessionId":"s"}
    {"type":"ai-title","aiTitle":"Second AI title","sessionId":"s"}
    """
  let tail = """
    {"type":"custom-title","customTitle":"Renamed by user","sessionId":"s"}
    {"type":"custom-title","customTitle":"","sessionId":"s"}
    not json at all
    """
  let titles = AgentSessionTitleIndex.claudeTitles(in: [Data(head.utf8), Data(tail.utf8)])
  #expect(titles.aiTitle == "Second AI title")
  #expect(titles.customTitle == "Renamed by user")
  #expect(titles.preferred == "Renamed by user")
  #expect(AgentSessionTitleIndex.claudeTitles(in: [Data(head.utf8)]).preferred == "Second AI title")
  #expect(AgentSessionTitleIndex.claudeTitles(in: [Data("{\"type\":\"user\"}\n".utf8)]).preferred == nil)
}

@Test func codexSessionIndexLastEntryWinsAndSkipsBrokenLines() {
  let index = """
    {"id":"a","thread_name":"Old name","updated_at":"2026-09-01T00:00:00Z"}
    {"id":"b","thread_name":"Fix parser","updated_at":"2026-09-02T00:00:00Z"}
    {"id":"a","thread_name":"New name","updated_at":"2026-09-03T00:00:00Z"}
    {"id":"c","thread_name":"","updated_at":"2026-09-03T00:00:00Z"}
    {"id":"","thread_name":"no id"}
    broken
    """
  let names = AgentSessionTitleIndex.codexThreadNames(from: Data(index.utf8))
  #expect(names == ["a": "New name", "b": "Fix parser"])
}

@Test func sessionTitleSanitizerStripsControlCharactersAndLimitsLength() {
  #expect(AgentSessionTitleIndex.sanitizedTitle(" a\u{1B}[31m  b\n c ") == "a[31m b c")
  #expect(AgentSessionTitleIndex.sanitizedTitle("   ") == nil)
  #expect(AgentSessionTitleIndex.sanitizedTitle(String(repeating: "x", count: 200))?.count == 120)
}
