import AsterCore
import Foundation

/// Memory / 命令历史的一条检索命中，字段已展平为展示所需的最小集合。
public struct MemorySearchHit: Equatable, Sendable {
  public let kind: String
  /// memory 命中时为 memory id，command 命中时为所属 session id。
  public let identifier: String
  public let title: String
  public let detail: String
  public let projectPath: String
  public let timestamp: Date

  public init(
    kind: String, identifier: String = "", title: String, detail: String,
    projectPath: String, timestamp: Date
  ) {
    self.kind = kind
    self.identifier = identifier
    self.title = title
    self.detail = detail
    self.projectPath = projectPath
    self.timestamp = timestamp
  }
}

/// Session 列表项：描述符 + 结束时间 + 统计，供 Timeline 列表与 MCP 概要使用。
public struct SessionSummaryRow: Equatable, Sendable {
  public let descriptor: RecordedSessionDescriptor
  public let endedAt: Date?
  public let commandCount: Int
  public let failureCount: Int
  public let memoryTitle: String?

  public init(
    descriptor: RecordedSessionDescriptor, endedAt: Date?, commandCount: Int,
    failureCount: Int, memoryTitle: String?
  ) {
    self.descriptor = descriptor
    self.endedAt = endedAt
    self.commandCount = commandCount
    self.failureCount = failureCount
    self.memoryTitle = memoryTitle
  }
}

/// 项目级上下文包（MCP `get_project_context` 的数据源）。
public struct ProjectContextSnapshot: Equatable, Sendable {
  public let projectPath: String
  public let projectName: String
  public let sessions: [SessionSummaryRow]
  public let memories: [MemoryRecord]
  public let tasks: [TaskDescriptor]

  public init(
    projectPath: String, projectName: String, sessions: [SessionSummaryRow],
    memories: [MemoryRecord], tasks: [TaskDescriptor]
  ) {
    self.projectPath = projectPath
    self.projectName = projectName
    self.sessions = sessions
    self.memories = memories
    self.tasks = tasks
  }
}

/// 只读查询层：MCP server、Inspector UI 与测试共用。持只读连接，永不发起写操作，
/// 与主应用的单写者（EventWriter）可安全并发。
public final class MemoryStoreReader {
  private let database: MemoryDatabase
  private let location: MemoryStoreLocation

  /// 打开只读连接并做 schema 版本握手；版本不匹配抛错，调用方转结构化错误。
  public init(location: MemoryStoreLocation) throws {
    self.location = location
    database = try MemoryDatabase(path: location.databaseURL.path, readOnly: true)
    let version = try database.userVersion()
    guard version == MemorySchema.currentVersion else {
      throw MemoryDatabaseError(
        operation: "schema-handshake",
        code: -1,
        message: "store version \(version), expected \(MemorySchema.currentVersion)"
      )
    }
  }

  // MARK: - 检索

  /// FTS 检索 memories 与历史命令事件的混合结果。
  /// `status='disabled'` 的 memory 被排除：用户屏蔽即代表不应再进入任何 Agent 上下文。
  public func search(query: String, projectPath: String? = nil, limit: Int = 10) throws
    -> [MemorySearchHit]
  {
    let match = Self.ftsQuery(from: query)
    guard !match.isEmpty else { return [] }
    let bounded = max(1, min(limit, 50))
    var hits: [MemorySearchHit] = []

    var memorySQL = """
      SELECT m.id, m.title, m.content, m.project_path, m.created_at
      FROM memories_fts f JOIN memories m ON m.rowid = f.rowid
      WHERE memories_fts MATCH ? AND m.status != 'disabled'
      """
    var memoryValues: [MemoryDatabase.Value] = [.text(match)]
    if let projectPath, !projectPath.isEmpty {
      memorySQL += " AND m.project_path = ?"
      memoryValues.append(.text(projectPath))
    }
    memorySQL += " ORDER BY m.created_at DESC LIMIT ?"
    memoryValues.append(.integer(Int64(bounded)))

    for row in try database.query(memorySQL, memoryValues) {
      hits.append(
        MemorySearchHit(
          kind: "memory",
          identifier: MemoryRowMapping.string(row, 0),
          title: MemoryRowMapping.string(row, 1),
          detail: MemoryRowMapping.string(row, 2),
          projectPath: MemoryRowMapping.string(row, 3),
          timestamp: Date(timeIntervalSince1970: MemoryRowMapping.real(row, 4) ?? 0)
        ))
    }

    var eventSQL = """
      SELECT e.session_id, e.command, e.exit_status, e.output_excerpt, s.project_path, e.at
      FROM events_fts f
      JOIN events e ON e.id = f.rowid
      JOIN sessions s ON s.id = e.session_id
      WHERE events_fts MATCH ? AND e.kind IN ('shell_command', 'command_output')
      """
    var eventValues: [MemoryDatabase.Value] = [.text(match)]
    if let projectPath, !projectPath.isEmpty {
      eventSQL += " AND s.project_path = ?"
      eventValues.append(.text(projectPath))
    }
    eventSQL += " ORDER BY e.at DESC LIMIT ?"
    eventValues.append(.integer(Int64(bounded)))

    for row in try database.query(eventSQL, eventValues) {
      let excerpt = MemoryRowMapping.string(row, 3)
      let exit = MemoryRowMapping.int(row, 2)
      var detail = exit.map { "exit \($0)" } ?? ""
      if !excerpt.isEmpty {
        detail += detail.isEmpty ? "" : "\n"
        detail += String(excerpt.suffix(500))
      }
      hits.append(
        MemorySearchHit(
          kind: "command",
          identifier: MemoryRowMapping.string(row, 0),
          title: MemoryRowMapping.string(row, 1),
          detail: detail,
          projectPath: MemoryRowMapping.string(row, 4),
          timestamp: Date(timeIntervalSince1970: MemoryRowMapping.real(row, 5) ?? 0)
        ))
    }
    return hits.sorted { $0.timestamp > $1.timestamp }
  }

  /// 与某个文件路径或关键词相关的历史：命令、失败与 memory 混合，按时间倒序。
  /// 供 MCP `get_related_history`：Agent 进入某模块时可主动查询过往经验。
  public func relatedHistory(keyword: String, projectPath: String?, limit: Int = 20) throws
    -> [MemorySearchHit]
  {
    // 文件路径带 `/` 与 `.`，FTS unicode61 会切成多个 token；
    // 只取末段文件名做匹配，命中率比整路径高得多。
    let leaf = (keyword as NSString).lastPathComponent
    let effective = leaf.isEmpty ? keyword : leaf
    return try search(query: effective, projectPath: projectPath, limit: limit)
  }

  /// 最近的命令事件（可选按项目路径过滤），供 get_recent_commands 工具直接返回。
  public func recentCommands(projectPath: String?, limit: Int = 20) throws -> [MemorySearchHit] {
    let bounded = max(1, min(limit, 100))
    var sql = """
      SELECT e.session_id, e.command, e.exit_status, s.project_path, e.at
      FROM events e JOIN sessions s ON s.id = e.session_id
      WHERE e.kind = 'shell_command'
      """
    var values: [MemoryDatabase.Value] = []
    if let projectPath, !projectPath.isEmpty {
      sql += " AND s.project_path = ?"
      values.append(.text(projectPath))
    }
    sql += " ORDER BY e.at DESC LIMIT ?"
    values.append(.integer(Int64(bounded)))
    return try database.query(sql, values).map { row in
      let exit = MemoryRowMapping.int(row, 2)
      return MemorySearchHit(
        kind: "command",
        identifier: MemoryRowMapping.string(row, 0),
        title: MemoryRowMapping.string(row, 1),
        detail: exit.map { "exit \($0)" } ?? "",
        projectPath: MemoryRowMapping.string(row, 3),
        timestamp: Date(timeIntervalSince1970: MemoryRowMapping.real(row, 4) ?? 0)
      )
    }
  }

  // MARK: - Session

  /// 某项目（或全部）的 session 列表，按开始时间倒序，附命令与失败计数。
  public func sessions(projectPath: String?, limit: Int = 50) throws -> [SessionSummaryRow] {
    let bounded = max(1, min(limit, 200))
    var sql = """
      SELECT s.id, s.project_path, s.shell, s.agent_provider, s.agent_session_id, s.started_at,
             s.task_id, s.git_branch, s.ended_at,
             (SELECT count(*) FROM events e WHERE e.session_id = s.id AND e.kind = 'shell_command'),
             (SELECT count(*) FROM events e WHERE e.session_id = s.id
                AND e.kind = 'command_finished' AND e.exit_status != 0),
             (SELECT m.title FROM memories m WHERE m.session_id = s.id LIMIT 1)
      FROM sessions s
      """
    var values: [MemoryDatabase.Value] = []
    if let projectPath, !projectPath.isEmpty {
      sql += " WHERE s.project_path = ?"
      values.append(.text(projectPath))
    }
    sql += " ORDER BY s.started_at DESC LIMIT ?"
    values.append(.integer(Int64(bounded)))
    return try database.query(sql, values).compactMap { row in
      guard let descriptor = MemoryRowMapping.sessionDescriptor(row: row) else { return nil }
      return SessionSummaryRow(
        descriptor: descriptor,
        endedAt: MemoryRowMapping.real(row, 8).map { Date(timeIntervalSince1970: $0) },
        commandCount: MemoryRowMapping.int(row, 9) ?? 0,
        failureCount: MemoryRowMapping.int(row, 10) ?? 0,
        memoryTitle: MemoryRowMapping.optionalString(row, 11)
      )
    }
  }

  /// 单个 session 的完整明细：描述符 + 事件时间线 + 派生 Memory。
  public func sessionDetail(id: UUID) throws -> SessionDetail? {
    let sessionRows = try database.query(
      """
      SELECT id, project_path, shell, agent_provider, agent_session_id, started_at,
             task_id, git_branch, ended_at
      FROM sessions WHERE id = ?
      """,
      [.text(id.uuidString)]
    )
    guard let row = sessionRows.first,
      let descriptor = MemoryRowMapping.sessionDescriptor(row: row)
    else { return nil }
    let events = try database.query(
      """
      SELECT seq, at, kind, command, cwd, exit_status, output_excerpt, source, payload
      FROM events WHERE session_id = ? ORDER BY seq ASC
      """,
      [.text(id.uuidString)]
    ).compactMap { MemoryRowMapping.event(row: $0, sessionID: id) }
    let memory = try memories(projectPath: nil, sessionID: id, limit: 1).first
    return SessionDetail(
      descriptor: descriptor,
      endedAt: MemoryRowMapping.real(row, 8).map { Date(timeIntervalSince1970: $0) },
      events: events,
      memory: memory
    )
  }

  // MARK: - Memory

  /// Memory 列表。默认排除 disabled；UI 管理界面需要看全部时传 includeDisabled。
  public func memories(
    projectPath: String?, sessionID: UUID? = nil, taskID: UUID? = nil,
    includeDisabled: Bool = false, limit: Int = 50
  ) throws -> [MemoryRecord] {
    var sql = """
      SELECT id, project_path, session_id, task_id, type, title, content, summary,
             created_at, status, importance, confidence, extractor
      FROM memories WHERE 1 = 1
      """
    var values: [MemoryDatabase.Value] = []
    if !includeDisabled {
      sql += " AND status != 'disabled'"
    }
    if let projectPath, !projectPath.isEmpty {
      sql += " AND project_path = ?"
      values.append(.text(projectPath))
    }
    if let sessionID {
      sql += " AND session_id = ?"
      values.append(.text(sessionID.uuidString))
    }
    if let taskID {
      sql += " AND task_id = ?"
      values.append(.text(taskID.uuidString))
    }
    sql += " ORDER BY created_at DESC LIMIT ?"
    values.append(.integer(Int64(max(1, min(limit, 200)))))
    return try database.query(sql, values).compactMap(MemoryRowMapping.memory(row:))
  }

  /// 一条 Memory 的来源回链，供「View Source」跳回真实工作过程。
  public func memorySources(memoryID: UUID) throws -> [MemorySourceRef] {
    try database.query(
      "SELECT source_kind, source_id FROM memory_sources WHERE memory_id = ?",
      [.text(memoryID.uuidString)]
    ).compactMap { row in
      guard let kind = MemorySourceRef.Kind(rawValue: MemoryRowMapping.string(row, 0)) else {
        return nil
      }
      return MemorySourceRef(kind: kind, identifier: MemoryRowMapping.string(row, 1))
    }
  }

  // MARK: - Task

  /// 某项目下的 Task 列表，按更新时间倒序。
  public func tasks(projectPath: String?, limit: Int = 50) throws -> [TaskDescriptor] {
    var sql = """
      SELECT t.id, coalesce(p.path, ''), t.title, t.status, t.summary, t.created_at, t.updated_at
      FROM tasks t LEFT JOIN projects p ON p.id = t.project_id
      """
    var values: [MemoryDatabase.Value] = []
    if let projectPath, !projectPath.isEmpty {
      sql += " WHERE p.path = ?"
      values.append(.text(projectPath))
    }
    sql += " ORDER BY t.updated_at DESC LIMIT ?"
    values.append(.integer(Int64(max(1, min(limit, 200)))))
    return try database.query(sql, values).compactMap(MemoryRowMapping.task(row:))
  }

  /// 单个 Task 及其关联 session（PRD §63 Task 页面的数据源）。
  public func taskDetail(id: UUID) throws -> (task: TaskDescriptor, sessions: [SessionSummaryRow])? {
    let rows = try database.query(
      """
      SELECT t.id, coalesce(p.path, ''), t.title, t.status, t.summary, t.created_at, t.updated_at
      FROM tasks t LEFT JOIN projects p ON p.id = t.project_id WHERE t.id = ?
      """,
      [.text(id.uuidString)]
    )
    guard let task = rows.first.flatMap(MemoryRowMapping.task(row:)) else { return nil }
    let sessionRows = try database.query(
      """
      SELECT s.id, s.project_path, s.shell, s.agent_provider, s.agent_session_id, s.started_at,
             s.task_id, s.git_branch, s.ended_at,
             (SELECT count(*) FROM events e WHERE e.session_id = s.id AND e.kind = 'shell_command'),
             (SELECT count(*) FROM events e WHERE e.session_id = s.id
                AND e.kind = 'command_finished' AND e.exit_status != 0),
             (SELECT m.title FROM memories m WHERE m.session_id = s.id LIMIT 1)
      FROM sessions s WHERE s.task_id = ? ORDER BY s.started_at DESC
      """,
      [.text(id.uuidString)]
    ).compactMap { row -> SessionSummaryRow? in
      guard let descriptor = MemoryRowMapping.sessionDescriptor(row: row) else { return nil }
      return SessionSummaryRow(
        descriptor: descriptor,
        endedAt: MemoryRowMapping.real(row, 8).map { Date(timeIntervalSince1970: $0) },
        commandCount: MemoryRowMapping.int(row, 9) ?? 0,
        failureCount: MemoryRowMapping.int(row, 10) ?? 0,
        memoryTitle: MemoryRowMapping.optionalString(row, 11)
      )
    }
    return (task, sessionRows)
  }

  // MARK: - 项目上下文与 Receipt

  /// 项目概要：最近 session、活跃 memory 与未完成 task。
  public func projectContext(projectPath: String, sessionLimit: Int = 5, memoryLimit: Int = 10)
    throws -> ProjectContextSnapshot
  {
    let nameRows = try database.query(
      "SELECT name FROM projects WHERE path = ?", [.text(projectPath)])
    let name =
      nameRows.first.map { MemoryRowMapping.string($0, 0) }
      ?? (projectPath as NSString).lastPathComponent
    return ProjectContextSnapshot(
      projectPath: projectPath,
      projectName: name,
      sessions: try sessions(projectPath: projectPath, limit: sessionLimit),
      memories: try memories(projectPath: projectPath, limit: memoryLimit),
      tasks: try tasks(projectPath: projectPath, limit: 20)
    )
  }

  /// Context Receipt 列表：用户查看「Agent 拿到过哪些 Memory」。
  public func contextReceipts(projectPath: String?, limit: Int = 50) throws -> [ContextReceipt] {
    var sql = """
      SELECT id, project_path, session_id, task_id, at, trigger, query, memory_ids,
             token_estimate, delivery_method
      FROM context_receipts
      """
    var values: [MemoryDatabase.Value] = []
    if let projectPath, !projectPath.isEmpty {
      sql += " WHERE project_path = ?"
      values.append(.text(projectPath))
    }
    sql += " ORDER BY at DESC LIMIT ?"
    values.append(.integer(Int64(max(1, min(limit, 200)))))
    return try database.query(sql, values).compactMap { row in
      guard let id = UUID(uuidString: MemoryRowMapping.string(row, 0)),
        let at = MemoryRowMapping.real(row, 4)
      else { return nil }
      let ids =
        MemoryRowMapping.optionalString(row, 7)?
        .split(separator: ",").map(String.init) ?? []
      return ContextReceipt(
        id: id,
        projectPath: MemoryRowMapping.optionalString(row, 1),
        sessionID: MemoryRowMapping.optionalString(row, 2).flatMap(UUID.init(uuidString:)),
        taskID: MemoryRowMapping.optionalString(row, 3).flatMap(UUID.init(uuidString:)),
        timestamp: Date(timeIntervalSince1970: at),
        trigger: MemoryRowMapping.string(row, 5),
        query: MemoryRowMapping.optionalString(row, 6),
        memoryIDs: ids,
        tokenEstimate: MemoryRowMapping.int(row, 8) ?? 0,
        deliveryMethod: MemoryRowMapping.string(row, 9)
      )
    }
  }

  /// 读取 artifact 正文（命令输出全文）。文件缺失或已裁剪返回 nil。
  public func artifactContents(relativePath: String, maximumBytes: Int = 1_024 * 1_024) -> String? {
    let url = location.rootDirectory.appendingPathComponent(relativePath)
    guard let data = try? Data(contentsOf: url) else { return nil }
    let bounded = data.count > maximumBytes ? data.suffix(maximumBytes) : data
    return String(data: bounded, encoding: .utf8)
  }

  /// 某个 session 的 artifact 指针列表。
  public func artifacts(sessionID: UUID) throws -> [ArtifactRef] {
    try database.query(
      """
      SELECT id, kind, relative_path, byte_count, created_at FROM artifacts
      WHERE session_id = ? AND purged = 0 ORDER BY created_at ASC
      """,
      [.text(sessionID.uuidString)]
    ).compactMap { row in
      guard let id = UUID(uuidString: MemoryRowMapping.string(row, 0)),
        let kind = ArtifactRef.Kind(rawValue: MemoryRowMapping.string(row, 1))
      else { return nil }
      return ArtifactRef(
        id: id,
        sessionID: sessionID,
        kind: kind,
        relativePath: MemoryRowMapping.string(row, 2),
        byteCount: MemoryRowMapping.int(row, 3) ?? 0,
        createdAt: Date(timeIntervalSince1970: MemoryRowMapping.real(row, 4) ?? 0)
      )
    }
  }

  /// 把自由文本转成安全的 FTS5 MATCH 表达式：每个词加引号做 AND 前缀匹配，
  /// 避免用户输入中的 `-`/`:` 等被解析成 FTS 语法。
  public static func ftsQuery(from raw: String) -> String {
    let tokens = raw.split(whereSeparator: { $0.isWhitespace || $0 == "\"" })
    return
      tokens
      .prefix(8)
      .map { "\"\($0)\"*" }
      .joined(separator: " ")
  }
}
