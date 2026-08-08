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
