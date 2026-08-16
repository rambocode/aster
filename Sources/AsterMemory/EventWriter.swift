import AsterCore
import Foundation

/// Session Memory 的唯一写入者。actor 串行化保证进程内单写者约定；
/// 调用方 fire-and-forget，任何存储故障都被吞掉并计数——记录层绝不反向影响终端
/// （PRD §12.1：Intelligence can fail. Terminal cannot.）。
public actor EventWriter {
  /// 写操作的封闭集合；批量事务按到达顺序执行。
  public enum Operation: Sendable {
    case upsertProject(ProjectIdentity, openedAt: Date)
    case startSession(RecordedSessionDescriptor)
    case updateSessionAgent(sessionID: UUID, provider: String?, agentSessionID: String?)
    case updateSessionGit(
      sessionID: UUID, branch: String?, commitBefore: String?, commitAfter: String?)
    case assignSessionTask(sessionID: UUID, taskID: UUID?)
    case endSession(sessionID: UUID, exitCode: Int?, endedAt: Date)
    case appendEvent(RecordedEvent)
    case appendArtifact(ArtifactRef)
    case markArtifactPurged(id: UUID)
    case insertMemory(SessionMemoryDraft, createdAt: Date)
    case insertMemoryRecord(MemoryRecord, sources: [MemorySourceRef])
    case updateMemoryStatus(id: UUID, status: MemoryStatus)
    case deleteMemory(id: UUID)
    case upsertTask(TaskDescriptor)
    case deleteSession(id: UUID)
  }

  private let location: MemoryStoreLocation
  private var database: MemoryDatabase?
  private var openFailed = false
  private var pending: [Operation] = []
  private var flushTask: Task<Void, Never>?
  /// 有界队列：存储故障或洪峰时丢弃而不是积压内存。
  private let maximumPending: Int
  public private(set) var droppedOperations = 0
  public private(set) var lastError: String?

  public init(location: MemoryStoreLocation, maximumPending: Int = 4_096) {
    self.location = location
    self.maximumPending = maximumPending
  }

  /// 入队一个写操作。到达批量阈值立即落库，否则合并进 250ms 的延迟 flush。
  public func record(_ operation: Operation) {
    guard pending.count < maximumPending else {
      droppedOperations += 1
      return
    }
    pending.append(operation)
    if pending.count >= 64 {
      flushNow()
    } else if flushTask == nil {
      flushTask = Task { [weak self] in
        try? await Task.sleep(for: .milliseconds(250))
        await self?.flushNow()
      }
    }
  }

  /// 立即把缓冲写入数据库（测试与 session 结束时调用）。
  public func flush() {
    flushNow()
  }

  /// 清空全部记录：丢弃待写队列、关闭写连接、删除数据库与 transcripts 目录。
  ///
  /// 必须由写者本人执行，不能让 UI 直接删文件：连接一旦打开，`unlink` 只摘掉目录项，
  /// writer 仍持有那个 inode 并继续往里写，用户看到「已清空」但数据其实还在长，
  /// 要重启进程才干净。这里先释放连接（`MemoryDatabase.deinit` 会 `sqlite3_close_v2`）
  /// 再删文件，最后复位状态，让下一条事件重新建库。
  ///
  /// 并发写者（例如此刻正在收尾的一次 CLI 提炼）在删除之后仍可能提交一批写入：
  /// 那批会命中新建的空库或直接失败被吞掉，都不会把旧数据带回来。
  public func purgeAll() {
    flushTask?.cancel()
    flushTask = nil
    pending.removeAll(keepingCapacity: false)
    database = nil

    let fileManager = FileManager.default
    let databasePath = location.databaseURL.path
    // WAL 模式下真正持有数据的是三个文件，只删主文件会留下可恢复的 -wal。
    for suffix in ["", "-wal", "-shm"] {
      try? fileManager.removeItem(atPath: databasePath + suffix)
    }
    try? fileManager.removeItem(
      at: location.rootDirectory.appendingPathComponent("transcripts", isDirectory: true))

    // 复位失败标记：上一轮的开库失败不应让清空后的新库永远写不进去。
    openFailed = false
    droppedOperations = 0
    lastError = nil
  }

  /// 回读某个 session 的全部事件（按序号升序）。供 session 结束后的 Memory 提炼
  /// 使用；走写连接在 actor 内完成，不与批量写并发。读取失败返回空数组。
  public func recordedEvents(sessionID: UUID) -> [RecordedEvent] {
    flushNow()
    guard let database = openDatabaseIfNeeded() else { return [] }
    let rows =
      (try? database.query(
        """
        SELECT seq, at, kind, command, cwd, exit_status, output_excerpt, source, payload
        FROM events WHERE session_id = ? ORDER BY seq ASC
        """,
        [.text(sessionID.uuidString)]
      )) ?? []
    return rows.compactMap { MemoryRowMapping.event(row: $0, sessionID: sessionID) }
  }

  /// 回读 session 描述符（含 agent 归属），供提炼阶段构造完整上下文。
  public func sessionDescriptor(sessionID: UUID) -> RecordedSessionDescriptor? {
    flushNow()
    guard let database = openDatabaseIfNeeded() else { return nil }
    let rows =
      (try? database.query(
        """
        SELECT id, project_path, shell, agent_provider, agent_session_id, started_at,
               task_id, git_branch
        FROM sessions WHERE id = ?
        """,
        [.text(sessionID.uuidString)]
      )) ?? []
    return rows.first.flatMap(MemoryRowMapping.sessionDescriptor(row:))
  }

  /// 上一进程遗留的未闭合会话（崩溃、强退或退出竞速让行永远停在 'active'）。
  /// 返回每个会话最后一条事件的时间（无事件时取 started_at），供启动补收把它们
  /// 按真实活动时间闭合并补跑提炼。调用方负责排除本进程仍活跃的会话。
  public func abandonedActiveSessions() -> [(id: UUID, lastActivityAt: Date)] {
    flushNow()
    guard let database = openDatabaseIfNeeded() else { return [] }
    let rows =
      (try? database.query(
        """
        SELECT s.id, coalesce(max(e.at), s.started_at)
        FROM sessions s LEFT JOIN events e ON e.session_id = s.id
        WHERE s.status = 'active'
        GROUP BY s.id
        """)) ?? []
    return rows.compactMap { row in
      guard let id = UUID(uuidString: MemoryRowMapping.string(row, 0)),
        let timestamp = MemoryRowMapping.real(row, 1)
      else { return nil }
      return (id, Date(timeIntervalSince1970: timestamp))
    }
  }

  /// Raw events 的保留策略（PRD §23：Memory 不能无限增长；借鉴 zero-mem 的 retention）。
  ///
  /// 裁剪对象是**已结束且超龄** session 的 events 行与 artifact 文件——L0 原始层可裁剪；
  /// sessions 行（含 git/agent 归属与统计意义）和 memories（提炼层，长期资产）永久保留，
  /// 这与「Raw 可丢、结论长存」的分层一致。events 删除经 FTS 触发器同步清索引。
  /// 幂等且以 session 为原子单位：不会留下裁了一半事件的 session。
  public func enforceEventRetention(
    maximumAge: TimeInterval = 90 * 24 * 3_600,
    now: Date = Date()
  ) {
    flushNow()
    guard let database = openDatabaseIfNeeded() else { return }
    let cutoff = now.timeIntervalSince1970 - maximumAge
    let doomed =
      (try? database.query(
        """
        SELECT id FROM sessions
        WHERE status = 'ended' AND started_at < ?
          AND EXISTS (SELECT 1 FROM events e WHERE e.session_id = sessions.id)
        """,
        [.real(cutoff)]
      )) ?? []
    guard !doomed.isEmpty else { return }
    for row in doomed {
      let sessionID = MemoryRowMapping.string(row, 0)
      // 先删 artifact 文件再删行：文件删除失败下次仍会被同一查询捞到重试。
      let artifactRows =
        (try? database.query(
          "SELECT relative_path FROM artifacts WHERE session_id = ?", [.text(sessionID)]
        )) ?? []
      for artifactRow in artifactRows {
        let path = MemoryRowMapping.string(artifactRow, 0)
        try? FileManager.default.removeItem(
          at: location.rootDirectory.appendingPathComponent(path))
      }
      try? database.run("DELETE FROM artifacts WHERE session_id = ?", [.text(sessionID)])
      try? database.run("DELETE FROM events WHERE session_id = ?", [.text(sessionID)])
    }
  }

  /// transcripts 目录的总配额裁剪：超过上限时按创建时间删除最旧的 artifact 文件，
  /// 并把对应行标记为 purged（保留事件与指针，只丢正文）。
  public func enforceArtifactQuota(maximumBytes: Int) {
    flushNow()
    guard let database = openDatabaseIfNeeded() else { return }
    let rows =
      (try? database.query(
        """
        SELECT id, relative_path, byte_count FROM artifacts
        WHERE purged = 0 ORDER BY created_at DESC
        """)) ?? []
    var total = 0
    var doomed: [(String, String)] = []
    for row in rows {
      let identifier = MemoryRowMapping.string(row, 0)
      let path = MemoryRowMapping.string(row, 1)
      let bytes = MemoryRowMapping.int(row, 2) ?? 0
      total += bytes
      if total > maximumBytes { doomed.append((identifier, path)) }
    }
    guard !doomed.isEmpty else { return }
    for (identifier, path) in doomed {
      let url = location.rootDirectory.appendingPathComponent(path)
      try? FileManager.default.removeItem(at: url)
      try? database.run(
        "UPDATE artifacts SET purged = 1 WHERE id = ?", [.text(identifier)])
    }
  }

  private func flushNow() {
    flushTask?.cancel()
    flushTask = nil
    guard !pending.isEmpty else { return }
    guard let database = openDatabaseIfNeeded() else {
      // 开库失败：丢弃本批并记数，不无限重试拖垮队列。
      droppedOperations += pending.count
      pending.removeAll(keepingCapacity: true)
      return
    }
    let batch = pending
    pending.removeAll(keepingCapacity: true)
    // 事务手动展开：Swift 6 严格并发把 non-Sendable 连接传入闭包判为潜在竞争，
    // actor 内直接顺序调用等价且可通过检查。
    do {
      try database.execute("BEGIN IMMEDIATE")
      do {
        for operation in batch {
          try apply(operation, to: database)
        }
        try database.execute("COMMIT")
      } catch {
        try? database.execute("ROLLBACK")
        throw error
      }
    } catch {
      droppedOperations += batch.count
      lastError = String(describing: error)
    }
  }

  /// 惰性开库：第一条操作到达时才创建目录、打开连接并迁移，
  /// 保证 Session 创建路径零同步 IO（engineering-pitfalls 纪律）。
  private func openDatabaseIfNeeded() -> MemoryDatabase? {
    if let database { return database }
    guard !openFailed else { return nil }
    do {
      try location.prepareDirectory()
      let database = try MemoryDatabase(path: location.databaseURL.path)
      try MemorySchema.migrate(database)
      try? FileManager.default.setAttributes(
        [.posixPermissions: 0o600], ofItemAtPath: location.databaseURL.path)
      self.database = database
      return database
    } catch {
      openFailed = true
      lastError = String(describing: error)
      return nil
    }
  }

  private func apply(_ operation: Operation, to database: MemoryDatabase) throws {
    switch operation {
    case .upsertProject(let project, let openedAt):
      // path 唯一：同一目录重复打开只刷新时间戳，不产生重复项目。
      try database.run(
        """
        INSERT INTO projects (id, path, name, git_remote, created_at, updated_at, last_opened_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        ON CONFLICT(path) DO UPDATE SET
          name = excluded.name,
          git_remote = coalesce(excluded.git_remote, projects.git_remote),
          updated_at = excluded.updated_at,
          last_opened_at = excluded.last_opened_at
        """,
        [
          .text(project.id.uuidString),
          .text(project.path),
          .text(project.name),
          project.gitRemote.map(MemoryDatabase.Value.text) ?? .null,
          .real(openedAt.timeIntervalSince1970),
          .real(openedAt.timeIntervalSince1970),
          .real(openedAt.timeIntervalSince1970),
        ]
      )
    case .startSession(let descriptor):
      try database.run(
        """
        INSERT OR IGNORE INTO sessions
          (id, project_path, shell, agent_provider, agent_session_id, started_at, status,
           task_id, git_branch)
        VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?)
        """,
        [
          .text(descriptor.id.uuidString),
          .text(descriptor.projectPath),
          descriptor.shell.map(MemoryDatabase.Value.text) ?? .null,
          descriptor.agentProvider.map(MemoryDatabase.Value.text) ?? .null,
          descriptor.agentSessionID.map(MemoryDatabase.Value.text) ?? .null,
          .real(descriptor.startedAt.timeIntervalSince1970),
          descriptor.taskID.map { MemoryDatabase.Value.text($0.uuidString) } ?? .null,
          descriptor.gitBranch.map(MemoryDatabase.Value.text) ?? .null,
        ]
      )
    case .updateSessionAgent(let sessionID, let provider, let agentSessionID):
      try database.run(
        "UPDATE sessions SET agent_provider = ?, agent_session_id = ? WHERE id = ?",
        [
          provider.map(MemoryDatabase.Value.text) ?? .null,
          agentSessionID.map(MemoryDatabase.Value.text) ?? .null,
          .text(sessionID.uuidString),
        ]
      )
    case .updateSessionGit(let sessionID, let branch, let before, let after):
      // coalesce 保证后续快照不会把已记录的 before commit 覆盖成 NULL。
      try database.run(
        """
        UPDATE sessions SET
          git_branch = coalesce(?, git_branch),
          git_commit_before = coalesce(git_commit_before, ?),
          git_commit_after = coalesce(?, git_commit_after)
        WHERE id = ?
        """,
        [
          branch.map(MemoryDatabase.Value.text) ?? .null,
          before.map(MemoryDatabase.Value.text) ?? .null,
          after.map(MemoryDatabase.Value.text) ?? .null,
          .text(sessionID.uuidString),
        ]
      )
    case .assignSessionTask(let sessionID, let taskID):
      try database.run(
        "UPDATE sessions SET task_id = ? WHERE id = ?",
        [
          taskID.map { MemoryDatabase.Value.text($0.uuidString) } ?? .null,
          .text(sessionID.uuidString),
        ]
      )
    case .endSession(let sessionID, let exitCode, let endedAt):
      try database.run(
        "UPDATE sessions SET ended_at = ?, exit_code = ?, status = 'ended' WHERE id = ?",
        [
          .real(endedAt.timeIntervalSince1970),
          exitCode.map { MemoryDatabase.Value.integer(Int64($0)) } ?? .null,
          .text(sessionID.uuidString),
        ]
      )
    case .appendEvent(let event):
      try database.run(
        """
        INSERT INTO events
          (session_id, seq, at, kind, command, cwd, exit_status, output_excerpt, source, payload)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          .text(event.sessionID.uuidString),
          .integer(Int64(event.sequence)),
          .real(event.timestamp.timeIntervalSince1970),
          .text(event.kind.rawValue),
          event.command.map(MemoryDatabase.Value.text) ?? .null,
          event.workingDirectory.map(MemoryDatabase.Value.text) ?? .null,
          event.exitStatus.map { MemoryDatabase.Value.integer(Int64($0)) } ?? .null,
          event.outputExcerpt.map(MemoryDatabase.Value.text) ?? .null,
          event.source.map { MemoryDatabase.Value.text($0.rawValue) } ?? .null,
          event.payload.map(MemoryDatabase.Value.text) ?? .null,
        ]
      )
    case .appendArtifact(let artifact):
      try database.run(
        """
        INSERT OR REPLACE INTO artifacts
          (id, session_id, event_id, kind, relative_path, byte_count, purged, created_at)
        VALUES (?, ?, NULL, ?, ?, ?, 0, ?)
        """,
        [
          .text(artifact.id.uuidString),
          .text(artifact.sessionID.uuidString),
          .text(artifact.kind.rawValue),
          .text(artifact.relativePath),
          .integer(Int64(artifact.byteCount)),
          .real(artifact.createdAt.timeIntervalSince1970),
        ]
      )
    case .markArtifactPurged(let id):
      try database.run(
        "UPDATE artifacts SET purged = 1 WHERE id = ?", [.text(id.uuidString)])
    case .insertMemory(let draft, let createdAt):
      // 兼容 spike 的规则式草稿：以 session id 作为 memory id，天然幂等。
      try database.run(
        """
        INSERT OR REPLACE INTO memories
          (id, project_path, session_id, type, title, content, created_at,
           status, importance, confidence, extractor, updated_at, access_count)
        VALUES (?, ?, ?, 'session', ?, ?, ?, 'active', 0, 1.0, 'ruleBased', ?, 0)
        """,
        [
          .text(draft.sessionID.uuidString),
          .text(draft.projectPath),
          .text(draft.sessionID.uuidString),
          .text(draft.title),
          .text(draft.content),
          .real(createdAt.timeIntervalSince1970),
          .real(createdAt.timeIntervalSince1970),
        ]
      )
      try database.run(
        """
        INSERT OR IGNORE INTO memory_sources (memory_id, source_kind, source_id)
        VALUES (?, 'session', ?)
        """,
        [.text(draft.sessionID.uuidString), .text(draft.sessionID.uuidString)]
      )
    case .insertMemoryRecord(let memory, let sources):
      try database.run(
        """
        INSERT OR REPLACE INTO memories
          (id, project_path, session_id, task_id, type, title, content, summary, created_at,
           status, importance, confidence, extractor, updated_at, access_count)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 0)
        """,
        [
          .text(memory.id.uuidString),
          .text(memory.projectPath),
          memory.sessionID.map { MemoryDatabase.Value.text($0.uuidString) } ?? .null,
          memory.taskID.map { MemoryDatabase.Value.text($0.uuidString) } ?? .null,
          .text(memory.type.rawValue),
          .text(memory.title),
          .text(memory.content),
          memory.summary.map(MemoryDatabase.Value.text) ?? .null,
          .real(memory.createdAt.timeIntervalSince1970),
          .text(memory.status.rawValue),
          .integer(Int64(memory.importance)),
          .real(memory.confidence),
          .text(memory.extractor.rawValue),
          .real(memory.createdAt.timeIntervalSince1970),
        ]
      )
      for source in sources {
        try database.run(
          """
          INSERT OR IGNORE INTO memory_sources (memory_id, source_kind, source_id)
          VALUES (?, ?, ?)
          """,
          [
            .text(memory.id.uuidString), .text(source.kind.rawValue), .text(source.identifier),
          ]
        )
      }
    case .updateMemoryStatus(let id, let status):
      try database.run(
        "UPDATE memories SET status = ?, updated_at = ? WHERE id = ?",
        [
          .text(status.rawValue), .real(Date().timeIntervalSince1970), .text(id.uuidString),
        ]
      )
    case .deleteMemory(let id):
      try database.run(
        "DELETE FROM memory_sources WHERE memory_id = ?", [.text(id.uuidString)])
      try database.run("DELETE FROM memories WHERE id = ?", [.text(id.uuidString)])
    case .upsertTask(let task):
      try database.run(
        """
        INSERT OR REPLACE INTO tasks (id, project_id, title, status, summary, created_at, updated_at)
        VALUES (?, (SELECT id FROM projects WHERE path = ?), ?, ?, ?, ?, ?)
        """,
        [
          .text(task.id.uuidString),
          .text(task.projectPath),
          .text(task.title),
          .text(task.status.rawValue),
          task.summary.map(MemoryDatabase.Value.text) ?? .null,
          .real(task.createdAt.timeIntervalSince1970),
          .real(task.updatedAt.timeIntervalSince1970),
        ]
      )
    case .deleteSession(let id):
      // 删除 session 必须连带清掉事件、artifact 行与派生 memory，
      // 否则「删除记录」在用户看来只是从列表消失（PRD §101 透明性）。
      try database.run("DELETE FROM events WHERE session_id = ?", [.text(id.uuidString)])
      try database.run("DELETE FROM artifacts WHERE session_id = ?", [.text(id.uuidString)])
      try database.run(
        "DELETE FROM memory_sources WHERE memory_id IN (SELECT id FROM memories WHERE session_id = ?)",
        [.text(id.uuidString)])
      try database.run("DELETE FROM memories WHERE session_id = ?", [.text(id.uuidString)])
      try database.run("DELETE FROM sessions WHERE id = ?", [.text(id.uuidString)])
    }
  }
}
