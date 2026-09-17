import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("Agent resume 命令逐参数 Shell 编码")
func agentShellCommandEncoderPreservesArgumentBoundaries() throws {
  let metadata = AgentSessionMetadata(
    id: "session;$(touch /tmp/nope) ' quoted",
    configuration: .init(provider: .codex, providerIdentifier: "openai", model: "gpt"),
    projectDirectory: "/tmp",
    title: "Unsafe",
    createdAt: .distantPast,
    updatedAt: .distantPast,
    transcriptFileURL: URL(fileURLWithPath: "/tmp/session.jsonl")
  )
  let plan = try AgentSessionCommandPlanner.plan(.resume, session: metadata)

  #expect(
    AgentShellCommandEncoder.encode(plan)
      == "'codex' 'resume' 'session;$(touch /tmp/nope) '\\'' quoted'"
  )
}

@Test("Agent 历史发现只读取可信根目录内的有界普通会话文件")
func agentHistoryDiscoveryReadsKnownProviderRoots() async throws {
  let manager = FileManager.default
  let home = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  let codex = home.appendingPathComponent(".codex/sessions/2026/08/08", isDirectory: true)
  try manager.createDirectory(at: codex, withIntermediateDirectories: true)
  let transcript = codex.appendingPathComponent("session-1.jsonl")
  try Data("{\"role\":\"user\",\"content\":\"Fix the parser\"}\n".utf8).write(to: transcript)
  defer { try? manager.removeItem(at: home) }

  let histories = await AgentHistoryDiscoveryService.discover(homeDirectory: home)

  #expect(histories.count == 1)
  #expect(histories[0].metadata.id == "session-1")
  #expect(histories[0].metadata.title == "Fix the parser")
  #expect(histories[0].metadata.configuration.provider == .codex)
}

// 用户机器上 ~/.claude/projects 有 900+ 个会话文件时，正在运行的最新会话曾因「枚举到
// 500 个就停」被漏扫，标签行拿不到会话标题；数量上限必须在按修改时间排序之后施加。
@Test("Agent 历史发现按修改时间排序后再限量，最新会话不会被枚举顺序漏掉")
func agentHistoryDiscoveryKeepsNewestSessionsWhenExceedingFileLimit() async throws {
  let manager = FileManager.default
  let home = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  let project = home.appendingPathComponent(".claude/projects/-tmp-demo", isDirectory: true)
  try manager.createDirectory(at: project, withIntermediateDirectories: true)
  defer { try? manager.removeItem(at: home) }
  let base = Date(timeIntervalSinceNow: -3_600)
  for index in 0..<6 {
    let url = project.appendingPathComponent("session-\(index).jsonl")
    try Data("{\"type\":\"user\",\"message\":{\"content\":\"prompt \(index)\"}}\n".utf8).write(to: url)
    try manager.setAttributes(
      [.modificationDate: base.addingTimeInterval(Double(index) * 60)], ofItemAtPath: url.path)
  }

  let histories = await AgentHistoryDiscoveryService.discover(homeDirectory: home, maximumFiles: 3)

  #expect(histories.count == 3)
  #expect(Set(histories.map(\.metadata.id)) == ["session-5", "session-4", "session-3"])
}

// 一条 400KB 的 tool_result 曾让整份 transcript 解析失败、会话从列表消失；超过单文件上限
// 的长会话则只读文件头。两种情况都必须仍能得到标题。
@Test("Agent 历史发现容忍超长记录与超大文件，仍从文件头推导标题")
func agentHistoryDiscoveryDegradesOversizedTranscriptsInsteadOfDroppingThem() async throws {
  let manager = FileManager.default
  let home = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  let project = home.appendingPathComponent(".claude/projects/-tmp-demo", isDirectory: true)
  try manager.createDirectory(at: project, withIntermediateDirectories: true)
  defer { try? manager.removeItem(at: home) }
  let limits = AgentTranscriptLimits(
    maximumInputBytes: 2_048, maximumRecordBytes: 256, maximumRecords: 100,
    maximumEntries: 100, maximumEntryBytes: 256)

  // 文件 A：第二条记录超过单条上限。
  let oversizedRecord = "{\"type\":\"user\",\"message\":{\"content\":\"\(String(repeating: "x", count: 600))\"}}\n"
  try Data(("{\"type\":\"user\",\"message\":{\"content\":\"Fix the divider\"}}\n" + oversizedRecord).utf8)
    .write(to: project.appendingPathComponent("oversized-record.jsonl"))
  // 文件 B：整体超过单文件上限，首条记录在文件头。
  var huge = "{\"type\":\"user\",\"message\":{\"content\":\"Restore banner\"}}\n"
  while huge.utf8.count < 6_000 {
    huge += "{\"type\":\"assistant\",\"message\":{\"content\":\"\(String(repeating: "y", count: 100))\"}}\n"
  }
  try Data(huge.utf8).write(to: project.appendingPathComponent("huge-file.jsonl"))

  let histories = await AgentHistoryDiscoveryService.discover(homeDirectory: home, limits: limits)
  let titles = Dictionary(uniqueKeysWithValues: histories.map { ($0.metadata.id, $0.metadata.title) })
  #expect(titles["oversized-record"] == "Fix the divider")
  #expect(titles["huge-file"] == "Restore banner")
}

// 标题优先取 provider 自己的会话名：Claude 的 custom-title（可能在文件尾）> ai-title >
// 首条 prompt；Codex 取 ~/.codex/session_index.jsonl 的 thread_name，缺席时回落 prompt。
@Test("Agent 历史发现优先使用 provider 自维护的会话名")
func agentHistoryDiscoveryPrefersProviderSessionTitles() async throws {
  let manager = FileManager.default
  let home = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  let claude = home.appendingPathComponent(".claude/projects/-tmp-demo", isDirectory: true)
  let codex = home.appendingPathComponent(".codex/sessions/2026/09/17", isDirectory: true)
  try manager.createDirectory(at: claude, withIntermediateDirectories: true)
  try manager.createDirectory(at: codex, withIntermediateDirectories: true)
  defer { try? manager.removeItem(at: home) }
  let limits = AgentTranscriptLimits(
    maximumInputBytes: 2_048, maximumRecordBytes: 512, maximumRecords: 1_000,
    maximumEntries: 1_000, maximumEntryBytes: 256)

  // Claude A：ai-title 在文件头，custom-title 在超出文件头上限的尾部。
  var renamed = "{\"type\":\"user\",\"message\":{\"content\":\"first prompt\"}}\n"
  renamed += "{\"type\":\"ai-title\",\"aiTitle\":\"AI generated\",\"sessionId\":\"a\"}\n"
  while renamed.utf8.count < 5_000 {
    renamed += "{\"type\":\"assistant\",\"message\":{\"content\":\"\(String(repeating: "y", count: 120))\"}}\n"
  }
  renamed += "{\"type\":\"custom-title\",\"customTitle\":\"User renamed\",\"sessionId\":\"a\"}\n"
  try Data(renamed.utf8).write(to: claude.appendingPathComponent("renamed.jsonl"))
  // Claude B：只有 ai-title。Claude C：什么都没有，回落 prompt。
  try Data(("{\"type\":\"user\",\"message\":{\"content\":\"first prompt\"}}\n"
    + "{\"type\":\"ai-title\",\"aiTitle\":\"AI only\",\"sessionId\":\"b\"}\n").utf8)
    .write(to: claude.appendingPathComponent("ai-only.jsonl"))
  try Data("{\"type\":\"user\",\"message\":{\"content\":\"plain prompt\"}}\n".utf8)
    .write(to: claude.appendingPathComponent("plain.jsonl"))
  // Codex：索引里有名字的取名字，没有的回落 prompt。
  let named = "rollout-2026-09-17T09-12-22-01a0aceb-fe8e-7db3-aa44-fa5f57ff7b04"
  let unnamed = "rollout-2026-09-17T09-52-15-01a0ad10-8336-7ec0-ab1d-38944191bc41"
  for name in [named, unnamed] {
    try Data("{\"type\":\"response_item\",\"payload\":{\"type\":\"message\",\"role\":\"user\",\"content\":[{\"type\":\"input_text\",\"text\":\"codex prompt\"}]}}\n".utf8)
      .write(to: codex.appendingPathComponent("\(name).jsonl"))
  }
  try Data("{\"id\":\"01a0aceb-fe8e-7db3-aa44-fa5f57ff7b04\",\"thread_name\":\"Thread from index\",\"updated_at\":\"2026-09-17T01:13:12Z\"}\n".utf8)
    .write(to: home.appendingPathComponent(".codex/session_index.jsonl"))

  let histories = await AgentHistoryDiscoveryService.discover(homeDirectory: home, limits: limits)
  let titles = Dictionary(uniqueKeysWithValues: histories.map { ($0.metadata.id, $0.metadata.title) })
  #expect(titles["renamed"] == "User renamed")
  #expect(titles["ai-only"] == "AI only")
  #expect(titles["plain"] == "plain prompt")
  #expect(titles[named] == "Thread from index")
  #expect(titles[unnamed] == "codex prompt")
}
