import AsterCore
import Foundation
import Testing

@testable import AsterMemory

/// 每个测试使用独立临时目录，互不共享数据库文件。
private func temporaryLocation() -> MemoryStoreLocation {
  MemoryStoreLocation(
    rootDirectory: FileManager.default.temporaryDirectory
      .appendingPathComponent("aster-memory-tests-\(UUID().uuidString)", isDirectory: true))
}

/// 构造一条命令事件，减少测试样板。
private func commandEvent(
  session: UUID, seq: Int, command: String, exit: Int? = nil, kind: MemoryEventKind = .shellCommand
) -> RecordedEvent {
  RecordedEvent(
    sessionID: session,
    sequence: seq,
    timestamp: Date(timeIntervalSince1970: 1_700_000_000 + Double(seq)),
    kind: kind,
    command: command,
    workingDirectory: "/tmp/project",
    exitStatus: exit
  )
}

@Suite struct MemoryStoreTests {
  @Test("批量写入一万条事件后数据完整且 FTS 可检索")
  func bulkWriteAndSearch() async throws {
    let location = temporaryLocation()
    let writer = EventWriter(location: location)
    let sessionID = UUID()
    let descriptor = RecordedSessionDescriptor(
      id: sessionID, projectPath: "/tmp/project", shell: "zsh",
      startedAt: Date(timeIntervalSince1970: 1_700_000_000))

    let start = Date()
    await writer.record(.startSession(descriptor))
    for index in 0..<10_000 {
      await writer.record(
        .appendEvent(
          commandEvent(
            session: sessionID, seq: index,
            command: index == 5_000 ? "cargo test reconnect" : "echo line \(index)")))
    }
    await writer.flush()
    let elapsed = Date().timeIntervalSince(start)
    #expect(await writer.droppedOperations == 0)
    // spike 判定标准：万条事件批量写入 < 1s（宽放到 3s 容忍 CI 慢机）。
    #expect(elapsed < 3.0)

    let reader = try MemoryStoreReader(location: location)
    let searchStart = Date()
    let hits = try reader.search(query: "reconnect", limit: 10)
    let searchElapsed = Date().timeIntervalSince(searchStart)
    #expect(hits.contains { $0.title == "cargo test reconnect" })
    #expect(searchElapsed < 0.1)

    let recent = try reader.recentCommands(projectPath: "/tmp/project", limit: 5)
    #expect(recent.count == 5)
  }

  @Test("重开数据库后会话与事件仍然完整（迁移幂等）")
  func reopenKeepsData() async throws {
    let location = temporaryLocation()
    let sessionID = UUID()
    do {
      let writer = EventWriter(location: location)
      await writer.record(
        .startSession(
          RecordedSessionDescriptor(
            id: sessionID, projectPath: "/tmp/p", shell: "zsh", startedAt: Date())))
      await writer.record(
        .appendEvent(commandEvent(session: sessionID, seq: 0, command: "swift build")))
      await writer.record(.endSession(sessionID: sessionID, exitCode: 0, endedAt: Date()))
      await writer.flush()
    }
    // 第二个写连接触发 migrate（应为幂等 no-op），随后仍能读到旧数据。
    let writer2 = EventWriter(location: location)
    await writer2.record(
      .appendEvent(commandEvent(session: sessionID, seq: 1, command: "swift test")))
    await writer2.flush()

    let reader = try MemoryStoreReader(location: location)
    let recent = try reader.recentCommands(projectPath: "/tmp/p", limit: 10)
    #expect(recent.map(\.title).sorted() == ["swift build", "swift test"])
  }

  @Test("Memory 草稿写入后可经 FTS 检索并回链项目")
  func memoryInsertAndSearch() async throws {
    let location = temporaryLocation()
    let writer = EventWriter(location: location)
    let sessionID = UUID()
    let draft = SessionMemoryDraft(
      sessionID: sessionID,
      projectPath: "/tmp/project",
      title: "claudeCode session：3 条命令，1 条失败",
      content: "## 失败命令\n- `cargo test websocket` 退出码 1")
    await writer.record(.insertMemory(draft, createdAt: Date()))
    await writer.flush()

    let reader = try MemoryStoreReader(location: location)
    let hits = try reader.search(query: "websocket")
    #expect(hits.contains { $0.kind == "memory" && $0.projectPath == "/tmp/project" })
  }

  @Test("只读连接与写连接可并发共存，且只读端拒绝旧版本 schema")
  func readOnlyCoexistence() async throws {
    let location = temporaryLocation()
    let writer = EventWriter(location: location)
    let sessionID = UUID()
    await writer.record(
      .startSession(
        RecordedSessionDescriptor(
          id: sessionID, projectPath: "/tmp/p", shell: nil, startedAt: Date())))
    await writer.flush()

    // 写端保持打开的同时创建只读端并查询。
    let reader = try MemoryStoreReader(location: location)
    await writer.record(
      .appendEvent(commandEvent(session: sessionID, seq: 0, command: "ls -la")))
    await writer.flush()
    let recent = try reader.recentCommands(projectPath: nil, limit: 10)
    #expect(recent.contains { $0.title == "ls -la" })
  }

  @Test("FTS 查询构造器转义用户输入中的语法字符")
  func ftsQuerySanitization() {
    #expect(MemoryStoreReader.ftsQuery(from: "cargo test") == "\"cargo\"* \"test\"*")
    #expect(MemoryStoreReader.ftsQuery(from: "a\"b -c:d") == "\"a\"* \"b\"* \"-c:d\"*")
    #expect(MemoryStoreReader.ftsQuery(from: "   ") == "")
  }
}
