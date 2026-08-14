import AsterCore
import AsterMemory
import Foundation
import Testing

@testable import Aster

// MARK: - 测试夹具

/// 在临时目录里搭一个假的 home，按 provider 的真实目录布局落一个 transcript。
private func makeHome() throws -> URL {
  let home = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  return home
}

private func writeClaudeTranscript(
  home: URL,
  encodedProjectDirectory: String,
  sessionID: String,
  contents: String
) throws -> URL {
  let directory = home.appendingPathComponent(
    ".claude/projects/\(encodedProjectDirectory)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appendingPathComponent("\(sessionID).jsonl")
  try Data(contents.utf8).write(to: url)
  return url
}

/// 一段包含读、写与非文件工具的 Claude Code transcript。
private func sampleTranscript(projectPath: String) -> String {
  """
  {"type":"user","cwd":"\(projectPath)","message":{"role":"user","content":"修一下解析器"}}
  {"type":"assistant","timestamp":"2026-08-14T01:00:00.000Z","cwd":"\(projectPath)","message":{"role":"assistant","content":[{"type":"tool_use","name":"Read","input":{"file_path":"\(projectPath)/Parser.swift"}}]}}
  {"type":"assistant","timestamp":"2026-08-14T01:00:05.000Z","cwd":"\(projectPath)","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","input":{"file_path":"\(projectPath)/Parser.swift","old_string":"a","new_string":"b"}}]}}
  {"type":"assistant","timestamp":"2026-08-14T01:00:09.000Z","cwd":"\(projectPath)","message":{"role":"assistant","content":[{"type":"tool_use","name":"Bash","input":{"command":"swift test --filter Parser"}}]}}
  """
}

/// transcript 定位、事件补录与项目归属的集成验证。
@Suite("AgentTranscriptIngestion")
struct AgentTranscriptIngestionTests {
  // MARK: - transcript 定位

  @Test("按 provider 根目录与会话 ID 定位 transcript")
  func locatesTranscriptByProviderAndSessionIdentifier() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let sessionID = "11111111-2222-3333-4444-555555555555"
    _ = try writeClaudeTranscript(
      home: home, encodedProjectDirectory: "-tmp-project", sessionID: sessionID,
      contents: sampleTranscript(projectPath: "/tmp/project"))

    let located = AgentTranscriptIngestion.locateTranscript(
      provider: .claudeCode, agentSessionID: sessionID, homeDirectory: home)

    guard case .success(let url) = located else {
      Issue.record("未能定位 transcript")
      return
    }
    #expect(url.lastPathComponent == "\(sessionID).jsonl")
  }

  @Test("Codex 的 rollout 文件名带时间戳前缀也能匹配会话 ID")
  func matchesCodexRolloutFileName() {
    let url = URL(
      fileURLWithPath: "/h/.codex/sessions/2026/08/14/rollout-2026-08-14T01-00-00-abc-def.jsonl")
    #expect(
      AgentTranscriptIngestion.matchesSessionIdentifier(url: url, agentSessionID: "abc-def"))
    #expect(
      !AgentTranscriptIngestion.matchesSessionIdentifier(url: url, agentSessionID: "abc"))
  }

  @Test("没有稳定历史根目录的 provider 直接判定为不可摄取")
  func providersWithoutTranscriptRootFailFast() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }

    for provider in [AgentProvider.pi, .omp] {
      let located = AgentTranscriptIngestion.locateTranscript(
        provider: provider, agentSessionID: "x", homeDirectory: home)
      guard case .failure(let reason) = located else {
        Issue.record("\(provider) 不应定位到 transcript")
        continue
      }
      #expect(reason == .providerHasNoTranscriptRoot)
    }
  }

  @Test("会话 ID 对不上时返回 not_found，不退而求其次拿别的会话")
  func missingTranscriptFailsClosed() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    _ = try writeClaudeTranscript(
      home: home, encodedProjectDirectory: "-tmp-project", sessionID: "aaaa",
      contents: sampleTranscript(projectPath: "/tmp/project"))

    let located = AgentTranscriptIngestion.locateTranscript(
      provider: .claudeCode, agentSessionID: "bbbb", homeDirectory: home)
    guard case .failure(let reason) = located else {
      Issue.record("不应定位到不相关的 transcript")
      return
    }
    #expect(reason == .transcriptNotFound)
  }

  // MARK: - 路径归一

  @Test("相对路径按会话项目目录补全成绝对路径")
  func resolvesRelativeToolPathsAgainstProject() {
    #expect(
      AgentTranscriptIngestion.resolvedPath("packages/core/goal.ts", projectPath: "/tmp/project")
        == "/tmp/project/packages/core/goal.ts")
    #expect(
      AgentTranscriptIngestion.resolvedPath("/abs/A.swift", projectPath: "/tmp/project")
        == "/abs/A.swift")
    #expect(AgentTranscriptIngestion.resolvedPath(nil, projectPath: "/tmp/project") == nil)
    // 项目目录本身未知时不编造前缀，原样保留。
    #expect(AgentTranscriptIngestion.resolvedPath("a/b.txt", projectPath: "") == "a/b.txt")
  }

  // MARK: - 事件补录

  @Test("transcript 摄取补录工具调用与文件读写事件")
  func ingestAppendsToolCallAndFileEvents() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let sessionID = "99999999-8888-7777-6666-555555555555"
    _ = try writeClaudeTranscript(
      home: home, encodedProjectDirectory: "-tmp-project", sessionID: sessionID,
      contents: sampleTranscript(projectPath: "/tmp/project"))

    let store = MemoryStoreLocation(rootDirectory: home.appendingPathComponent("Memory"))
    let writer = EventWriter(location: store)
    let recordedSession = UUID()
    await writer.record(
      .startSession(
        RecordedSessionDescriptor(
          id: recordedSession, projectPath: "/tmp/project", shell: "/bin/zsh", startedAt: Date())))
    // 先放一条终端事件，验证补录的序号从它之后继续。
    await writer.record(
      .appendEvent(
        RecordedEvent(
          sessionID: recordedSession, sequence: 1, timestamp: Date(), kind: .shellCommand,
          command: "claude", workingDirectory: "/tmp/project", source: .terminal)))

    await AgentTranscriptIngestion.ingest(
      sessionID: recordedSession,
      provider: .claudeCode,
      agentSessionID: sessionID,
      projectPath: "/tmp/project",
      writer: writer,
      homeDirectory: home
    )

    let events = await writer.recordedEvents(sessionID: recordedSession)
    let ingested = events.filter { $0.source == .transcript }

    #expect(events.count == ingested.count + 1)
    #expect(ingested.map(\.sequence) == Array(2...(1 + ingested.count)))
    #expect(ingested.filter { $0.kind == .agentToolCall }.map(\.command) == ["Read", "Edit", "Bash"])
    #expect(ingested.filter { $0.kind == .fileRead }.count == 1)
    #expect(ingested.filter { $0.kind == .fileModified }.count == 1)
    // Bash 没有可判定的目标路径，因而只留工具调用，不派生文件事件。
    #expect(
      ingested.first { $0.kind == .fileRead }?.payload
        == #"{"path":"/tmp/project/Parser.swift","tool":"Read"}"#)
  }

  @Test("重复摄取同一会话不产生第二份工具调用")
  func ingestIsIdempotent() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let sessionID = "12121212-3434-5656-7878-909090909090"
    _ = try writeClaudeTranscript(
      home: home, encodedProjectDirectory: "-tmp-project", sessionID: sessionID,
      contents: sampleTranscript(projectPath: "/tmp/project"))

    let store = MemoryStoreLocation(rootDirectory: home.appendingPathComponent("Memory"))
    let writer = EventWriter(location: store)
    let recordedSession = UUID()
    await writer.record(
      .startSession(
        RecordedSessionDescriptor(
          id: recordedSession, projectPath: "/tmp/project", shell: nil, startedAt: Date())))

    for _ in 0..<2 {
      await AgentTranscriptIngestion.ingest(
        sessionID: recordedSession, provider: .claudeCode, agentSessionID: sessionID,
        projectPath: "/tmp/project", writer: writer, homeDirectory: home)
    }

    let events = await writer.recordedEvents(sessionID: recordedSession)
    #expect(events.filter { $0.kind == .agentToolCall }.count == 3)
    #expect(Set(events.map(\.sequence)).count == events.count)
  }

  @Test("摄取事件不携带 prompt、工具参数或输出正文")
  func ingestKeepsPromptAndToolArgumentsOut() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let sessionID = "abcdabcd-1111-2222-3333-444444444444"
    _ = try writeClaudeTranscript(
      home: home, encodedProjectDirectory: "-tmp-project", sessionID: sessionID,
      contents: sampleTranscript(projectPath: "/tmp/project"))

    let store = MemoryStoreLocation(rootDirectory: home.appendingPathComponent("Memory"))
    let writer = EventWriter(location: store)
    let recordedSession = UUID()
    await writer.record(
      .startSession(
        RecordedSessionDescriptor(
          id: recordedSession, projectPath: "/tmp/project", shell: nil, startedAt: Date())))

    await AgentTranscriptIngestion.ingest(
      sessionID: recordedSession, provider: .claudeCode, agentSessionID: sessionID,
      projectPath: "/tmp/project", writer: writer, homeDirectory: home)

    let events = await writer.recordedEvents(sessionID: recordedSession)
    let text = events.map { [$0.command, $0.payload, $0.outputExcerpt].compactMap { $0 }.joined() }
      .joined(separator: "\n")

    #expect(!events.isEmpty)
    #expect(!text.contains("修一下解析器"))
    #expect(!text.contains("swift test --filter Parser"))
    #expect(!text.contains("old_string"))
    #expect(events.allSatisfy { $0.outputExcerpt == nil })
  }

  @Test("transcript 缺失时静默降级，不写入任何事件")
  func ingestDegradesSilentlyWhenTranscriptMissing() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }

    let store = MemoryStoreLocation(rootDirectory: home.appendingPathComponent("Memory"))
    let writer = EventWriter(location: store)
    let recordedSession = UUID()
    await writer.record(
      .startSession(
        RecordedSessionDescriptor(
          id: recordedSession, projectPath: "/tmp/project", shell: nil, startedAt: Date())))
    await writer.record(
      .appendEvent(
        RecordedEvent(
          sessionID: recordedSession, sequence: 1, timestamp: Date(), kind: .shellCommand,
          command: "claude", workingDirectory: "/tmp/project", source: .terminal)))

    await AgentTranscriptIngestion.ingest(
      sessionID: recordedSession, provider: .claudeCode, agentSessionID: "not-there",
      projectPath: "/tmp/project", writer: writer, homeDirectory: home)

    let events = await writer.recordedEvents(sessionID: recordedSession)
    #expect(events.count == 1)
    #expect(events[0].source == .terminal)
  }

  // MARK: - 项目归属

  @Test("历史发现按 transcript 的 cwd 还原项目目录而不是主目录")
  func historyDiscoveryUsesTranscriptWorkingDirectory() async throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let project = home.appendingPathComponent("work/parser", isDirectory: true)
    try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
    _ = try writeClaudeTranscript(
      home: home,
      encodedProjectDirectory: AgentTranscriptProjectMapping.encodedDirectoryName(
        forProjectPath: project.path),
      sessionID: "77777777-0000-1111-2222-333333333333",
      contents: sampleTranscript(projectPath: project.path))

    let histories = await AgentHistoryDiscoveryService.discover(homeDirectory: home)

    #expect(histories.count == 1)
    #expect(histories[0].metadata.projectDirectory == project.path)
    #expect(histories[0].metadata.projectDirectory != home.path)
  }

  @Test("判不出项目归属时返回空串，不再伪造主目录")
  func inferredProjectDirectoryNeverFallsBackToHome() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let codex = home.appendingPathComponent(
      ".codex/sessions/2026/08/14/rollout-2026-08-14T01-00-00-abc.jsonl")

    let directory = AgentHistoryDiscoveryService.inferredProjectDirectory(
      url: codex,
      provider: .codex,
      home: home,
      transcriptData: Data(#"{"type":"event_msg","payload":{"type":"task_started"}}"#.utf8)
    )

    #expect(directory.isEmpty)
  }

  @Test("Codex 的 session_meta cwd 让会话获得真实项目归属")
  func codexAttributionUsesSessionMetaWorkingDirectory() throws {
    let home = try makeHome()
    defer { try? FileManager.default.removeItem(at: home) }
    let codex = home.appendingPathComponent(
      ".codex/sessions/2026/08/14/rollout-2026-08-14T01-00-00-abc.jsonl")
    let jsonl = #"{"type":"session_meta","payload":{"id":"abc","cwd":"/Users/mike/src/Tandem"}}"#

    let attribution = AgentHistoryDiscoveryService.projectAttribution(
      url: codex, provider: .codex, home: home, transcriptData: Data(jsonl.utf8))

    #expect(attribution?.path == "/Users/mike/src/Tandem")
    #expect(attribution?.confidence == .transcriptWorkingDirectory)
  }
}
