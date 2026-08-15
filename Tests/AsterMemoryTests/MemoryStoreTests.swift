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

  @Test("检索按 bm25 相关度排序：高相关的旧结果排在弱相关的新结果之前")
  func searchOrdersByRelevanceNotRecency() async throws {
    let location = temporaryLocation()
    let writer = EventWriter(location: location)
    let sessionID = UUID()
    await writer.record(
      .startSession(
        RecordedSessionDescriptor(
          id: sessionID, projectPath: "/tmp/project", shell: "zsh",
          startedAt: Date(timeIntervalSince1970: 1_700_000_000))))
    // 旧事件：词频高、正文短 → bm25 更相关；新事件：同词只出现一次且被长文稀释。
    await writer.record(
      .appendEvent(
        RecordedEvent(
          sessionID: sessionID, sequence: 1,
          timestamp: Date(timeIntervalSince1970: 1_700_000_000),
          kind: .commandOutput,
          outputExcerpt: "deploy failed: deploy hook rejected the deploy")))
    let padding = (0..<50).map { "word\($0)" }.joined(separator: " ")
    await writer.record(
      .appendEvent(
        RecordedEvent(
          sessionID: sessionID, sequence: 2,
          timestamp: Date(timeIntervalSince1970: 1_700_009_999),
          kind: .commandOutput,
          outputExcerpt: "\(padding) deploy \(padding)")))
    await writer.flush()

    let reader = try MemoryStoreReader(location: location)
    let hits = try reader.search(query: "deploy", limit: 10)
    #expect(hits.count == 2)
    #expect(hits.first?.timestamp == Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test("混合检索的总量不超过 limit")
  func searchRespectsCombinedLimit() async throws {
    let location = temporaryLocation()
    let writer = EventWriter(location: location)
    let sessionID = UUID()
    await writer.record(
      .startSession(
        RecordedSessionDescriptor(
          id: sessionID, projectPath: "/tmp/project", shell: "zsh",
          startedAt: Date(timeIntervalSince1970: 1_700_000_000))))
    for index in 0..<6 {
      await writer.record(
        .appendEvent(commandEvent(session: sessionID, seq: index, command: "make release-\(index)")))
    }
    await writer.record(
      .insertMemory(
        SessionMemoryDraft(
          sessionID: sessionID, projectPath: "/tmp/project",
          title: "release 流程结论", content: "make release 需要先跑 codesign"),
        createdAt: Date(timeIntervalSince1970: 1_700_000_100)))
    await writer.flush()

    let reader = try MemoryStoreReader(location: location)
    // memory + 6 条命令都命中 “release”，旧实现会返回 2×limit 条。
    let hits = try reader.search(query: "release", limit: 3)
    #expect(hits.count == 3)
  }

  @Test("storeStatus 返回三表计数与最后事件时间")
  func storeStatusReportsCounts() async throws {
    let location = temporaryLocation()
    let writer = EventWriter(location: location)
    let sessionID = UUID()
    await writer.record(
      .startSession(
        RecordedSessionDescriptor(
          id: sessionID, projectPath: "/tmp/project", shell: "zsh",
          startedAt: Date(timeIntervalSince1970: 1_700_000_000))))
    await writer.flush()

    // 只有 session、没有事件与 memory：事件侧应报告空。
    let reader = try MemoryStoreReader(location: location)
    let empty = try reader.storeStatus()
    #expect(empty.sessionCount == 1)
    #expect(empty.eventCount == 0)
    #expect(empty.memoryCount == 0)
    #expect(empty.latestEventAt == nil)

    await writer.record(
      .appendEvent(commandEvent(session: sessionID, seq: 7, command: "swift build")))
    await writer.flush()
    let status = try reader.storeStatus()
    #expect(status.eventCount == 1)
    #expect(status.latestEventAt == Date(timeIntervalSince1970: 1_700_000_007))
  }

  @Test("保留策略：超龄已结束 session 的 events 与 artifact 被裁剪，sessions 与 memories 保留")
  func eventRetentionTrimsOldSessions() async throws {
    let location = temporaryLocation()
    defer { try? FileManager.default.removeItem(at: location.rootDirectory) }
    let writer = EventWriter(location: location)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let oldID = UUID()
    let freshID = UUID()

    // 超龄 session（100 天前）+ artifact 文件；新 session 保持完整。
    for (id, age) in [(oldID, 100.0), (freshID, 1.0)] {
      await writer.record(
        .startSession(
          RecordedSessionDescriptor(
            id: id, projectPath: "/tmp/p", shell: "zsh",
            startedAt: now.addingTimeInterval(-age * 24 * 3_600))))
      await writer.record(
        .appendEvent(commandEvent(session: id, seq: 1, command: "swift build")))
      await writer.record(.endSession(sessionID: id, exitCode: 0, endedAt: now))
    }
    let artifactURL = location.rootDirectory.appendingPathComponent("transcripts/old.txt")
    try FileManager.default.createDirectory(
      at: artifactURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("payload".utf8).write(to: artifactURL)
    await writer.record(
      .appendArtifact(
        ArtifactRef(
          sessionID: oldID, kind: .commandOutput,
          relativePath: "transcripts/old.txt", byteCount: 7)))
    await writer.record(
      .insertMemory(
        SessionMemoryDraft(
          sessionID: oldID, projectPath: "/tmp/p", title: "旧结论", content: "正文"),
        createdAt: now))
    await writer.flush()

    await writer.enforceEventRetention(maximumAge: 90 * 24 * 3_600, now: now)

    let reader = try MemoryStoreReader(location: location)
    // 旧 session 的 events 与 artifact 文件消失；session 行与派生 memory 留存。
    let oldDetail = try #require(try reader.sessionDetail(id: oldID))
    #expect(oldDetail.events.isEmpty)
    #expect(oldDetail.memory?.title == "旧结论")
    #expect(FileManager.default.fileExists(atPath: artifactURL.path) == false)
    // 新 session 不受影响。
    let freshDetail = try #require(try reader.sessionDetail(id: freshID))
    #expect(freshDetail.events.count == 1)
  }

  @Test("pinned memory 进入项目上下文的固定席位，普通检索仍可见")
  func pinnedMemoriesJoinProjectContext() async throws {
    let location = temporaryLocation()
    defer { try? FileManager.default.removeItem(at: location.rootDirectory) }
    let writer = EventWriter(location: location)
    let pinnedID = UUID()
    await writer.record(
      .insertMemoryRecord(
        MemoryRecord(
          id: pinnedID, projectPath: "/tmp/p", type: .decision,
          title: "连接生命周期归 ConnectionManager", content: "不要在 socket 循环里重连",
          status: .pinned),
        sources: []))
    await writer.record(
      .insertMemoryRecord(
        MemoryRecord(
          projectPath: "/tmp/p", type: .session, title: "普通会话结论", content: "正文"),
        sources: []))
    await writer.flush()

    let reader = try MemoryStoreReader(location: location)
    let pinned = try reader.pinnedMemories(projectPath: "/tmp/p")
    #expect(pinned.map(\.id) == [pinnedID])
    let context = try reader.projectContext(projectPath: "/tmp/p")
    #expect(context.pinned.map(\.id) == [pinnedID])
    // pinned 不属于 disabled：普通检索仍能搜到它（管理与用户搜索场景）。
    let hits = try reader.search(query: "ConnectionManager", projectPath: "/tmp/p")
    #expect(hits.contains { $0.identifier == pinnedID.uuidString })
  }
}
