import AsterCore
import Foundation
import Testing

@Test("记录后按目录取回最近一次会话，尾部斜杠与 .. 归一化到同一目录")
func projectSessionRegistryRecordsLatestPerDirectory() {
  var registry = AgentProjectSessionRegistry()
  let first = Date(timeIntervalSince1970: 1_000)
  let second = Date(timeIntervalSince1970: 2_000)
  var recorded = registry.record(
    provider: .claudeCode, sessionID: "s-1", projectDirectory: "/Users/me/proj/", endedAt: first)
  #expect(recorded)
  recorded = registry.record(
    provider: .codex, sessionID: "s-2", projectDirectory: "/Users/me/proj/sub/..", endedAt: second)
  #expect(recorded)
  let latest = registry.latest(for: "/Users/me/proj")
  #expect(latest?.provider == .codex)
  #expect(latest?.sessionID == "s-2")
  #expect(registry.records.count == 1)
}

@Test("没有原生 resume 能力的 provider、相对路径与非法 session ID 不登记")
func projectSessionRegistryRejectsUnresumable() {
  var registry = AgentProjectSessionRegistry()
  var recorded = registry.record(provider: .gemini, sessionID: "s", projectDirectory: "/tmp/p")
  #expect(!recorded)
  recorded = registry.record(provider: .claudeCode, sessionID: "s", projectDirectory: "relative")
  #expect(!recorded)
  recorded = registry.record(provider: .claudeCode, sessionID: "", projectDirectory: "/tmp/p")
  #expect(!recorded)
  recorded = registry.record(provider: .claudeCode, sessionID: "a\0b", projectDirectory: "/tmp/p")
  #expect(!recorded)
  #expect(registry.latest(for: "/tmp/p") == nil)
}

@Test("没有 session ID 时只登记能「续上最近一次」的 provider")
func projectSessionRegistryRecordsContinueLatestOnlyWhenSupported() {
  var registry = AgentProjectSessionRegistry()
  let claude = registry.record(provider: .claudeCode, sessionID: nil, projectDirectory: "/tmp/p")
  #expect(claude)
  #expect(registry.latest(for: "/tmp/p")?.sessionID == nil)
  #expect(registry.latest(for: "/tmp/p")?.provider == .claudeCode)
  let codex = registry.record(provider: .codex, sessionID: nil, projectDirectory: "/tmp/q")
  #expect(codex)
  // Grok 能 --resume <id>，但没有「续上最近一次」的参数。
  let grok = registry.record(provider: .grokBuild, sessionID: nil, projectDirectory: "/tmp/r")
  #expect(!grok)
  #expect(registry.latest(for: "/tmp/r") == nil)
  #expect(AgentProvider.claudeCode.continueLatestSessionArguments == ["--continue"])
  #expect(AgentProvider.codex.continueLatestSessionArguments == ["resume", "--last"])
}

@Test("超出容量时淘汰结束时间最早的记录")
func projectSessionRegistryTrimsOldest() {
  var registry = AgentProjectSessionRegistry(capacity: 2)
  for index in 0..<3 {
    registry.record(
      provider: .claudeCode, sessionID: "s-\(index)", projectDirectory: "/p/\(index)",
      endedAt: Date(timeIntervalSince1970: Double(index)))
  }
  #expect(registry.latest(for: "/p/0") == nil)
  #expect(registry.latest(for: "/p/1")?.sessionID == "s-1")
  #expect(registry.latest(for: "/p/2")?.sessionID == "s-2")
}

@Test("编解码往返保持记录；解码丢弃不可 resume 的 provider 与坏路径")
func projectSessionStoreRoundTripsAndSanitizes() throws {
  var registry = AgentProjectSessionRegistry()
  registry.record(
    provider: .grokBuild, sessionID: "g-1", projectDirectory: "/p/a",
    endedAt: Date(timeIntervalSince1970: 10))
  let data = try AgentProjectSessionStore.encode(registry)
  let decoded = try AgentProjectSessionStore.decode(data)
  #expect(decoded == registry)

  let tampered = """
    {"capacity":200,"records":{
      "/ok":{"provider":"claudeCode","sessionID":"x","endedAt":0},
      "bad":{"provider":"claudeCode","sessionID":"y","endedAt":0},
      "/gem":{"provider":"gemini","sessionID":"z","endedAt":0}}}
    """
  let sanitized = try AgentProjectSessionStore.decode(Data(tampered.utf8))
  #expect(sanitized.records.count == 1)
  #expect(sanitized.latest(for: "/ok")?.sessionID == "x")
}

@Test("超过字节上限的数据拒绝解码")
func projectSessionStoreRejectsOversizedData() {
  let oversized = Data(repeating: 0x20, count: AgentProjectSessionStore.maximumBytes + 1)
  #expect(throws: AgentProjectSessionStoreError.self) {
    try AgentProjectSessionStore.decode(oversized)
  }
}
