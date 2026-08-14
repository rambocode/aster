import Foundation
import Testing

@testable import AsterCore

/// 构造事件的测试便捷函数。
private func event(
  _ session: UUID, _ seq: Int, _ kind: MemoryEventKind,
  command: String? = nil, exit: Int? = nil, excerpt: String? = nil
) -> RecordedEvent {
  RecordedEvent(
    sessionID: session, sequence: seq,
    timestamp: Date(timeIntervalSince1970: Double(seq)),
    kind: kind, command: command, workingDirectory: "/tmp/p",
    exitStatus: exit, outputExcerpt: excerpt)
}

@Suite struct RecordingPolicyTests {
  @Test("关闭开关时一律不记录")
  func disabledPolicy() {
    let policy = RecordingPolicy(isEnabled: false)
    #expect(!policy.shouldRecord(workingDirectory: "/tmp/anything"))
  }

  @Test("排除目录按路径段边界前缀匹配")
  func excludedPrefixes() {
    let policy = RecordingPolicy(
      isEnabled: true, excludedPathPrefixes: ["/Users/mike/secret", "/opt/vault/"])
    #expect(!policy.shouldRecord(workingDirectory: "/Users/mike/secret"))
    #expect(!policy.shouldRecord(workingDirectory: "/Users/mike/secret/sub"))
    // 同名前缀但不同路径段不能误伤。
    #expect(policy.shouldRecord(workingDirectory: "/Users/mike/secrets"))
    #expect(!policy.shouldRecord(workingDirectory: "/opt/vault/data"))
    #expect(policy.shouldRecord(workingDirectory: "/Users/mike/project"))
  }

  @Test("空 cwd（如远端 SSH）保守拒绝")
  func emptyDirectoryRejected() {
    let policy = RecordingPolicy(isEnabled: true)
    #expect(!policy.shouldRecord(workingDirectory: ""))
  }
}

@Suite struct RuleBasedSessionMemoryExtractorTests {
  private let session = RecordedSessionDescriptor(
    id: UUID(), projectPath: "/tmp/p", shell: "zsh",
    startedAt: Date(timeIntervalSince1970: 0))

  @Test("没有任何命令的 session 不产生 Memory")
  func emptySessionYieldsNil() {
    let events = [
      event(session.id, 1, .sessionStarted),
      event(session.id, 2, .sessionEnded),
    ]
    #expect(RuleBasedSessionMemoryExtractor.extract(session: session, events: events) == nil)
  }

  @Test("失败命令进入摘要并统计正确")
  func failureSummary() {
    let events = [
      event(session.id, 1, .sessionStarted),
      event(session.id, 2, .shellCommand, command: "swift build"),
      event(session.id, 3, .commandFinished, exit: 0),
      event(session.id, 4, .shellCommand, command: "cargo test websocket"),
      event(session.id, 5, .commandOutput, exit: 1, excerpt: "error: connection reset"),
      event(session.id, 6, .commandFinished, exit: 1),
      event(session.id, 7, .sessionEnded),
    ]
    let draft = RuleBasedSessionMemoryExtractor.extract(session: session, events: events)
    #expect(draft != nil)
    #expect(draft?.title.contains("2 条命令") == true)
    #expect(draft?.title.contains("1 条失败") == true)
    #expect(draft?.content.contains("cargo test websocket") == true)
    #expect(draft?.content.contains("connection reset") == true)
  }

  @Test("agent provider 出现在标题中")
  func agentProviderInTitle() {
    var agentSession = session
    agentSession.agentProvider = "claudeCode"
    let events = [
      event(agentSession.id, 1, .shellCommand, command: "claude"),
      event(agentSession.id, 2, .commandFinished, exit: 0),
    ]
    let draft = RuleBasedSessionMemoryExtractor.extract(session: agentSession, events: events)
    #expect(draft?.title.hasPrefix("claudeCode") == true)
  }
}

@Suite struct AgentContextRedactorPublicTests {
  @Test("公开后的 redactor 仍遮盖常见 secret")
  func redactsSecrets() {
    let input = "export AWS_SECRET_KEY=abc123 curl -H 'Authorization: Bearer tok_456'"
    let result = AgentContextRedactor.redact(input)
    #expect(!result.value.contains("abc123"))
    #expect(!result.value.contains("tok_456"))
    #expect(result.count >= 2)
  }
}
