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
  /// 该命中来自项目过滤之外（federation 回落）。渲染时必须向 Agent 标明，
  /// 跨项目的历史结论未必适用于当前项目。
  public let isCrossProject: Bool

  public init(
    kind: String, identifier: String = "", title: String, detail: String,
    projectPath: String, timestamp: Date, isCrossProject: Bool = false
  ) {
    self.kind = kind
    self.identifier = identifier
    self.title = title
    self.detail = detail
    self.projectPath = projectPath
    self.timestamp = timestamp
    self.isCrossProject = isCrossProject
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

/// 库级状态概览：MCP 零命中时用于区分「记录未开启/库为空」与「真的没发生过」，
/// 也让 Agent 知道数据截至何时（写端有批量延迟，读端可能落后数百毫秒）。
public struct MemoryStoreStatus: Equatable, Sendable {
  public let sessionCount: Int
  public let eventCount: Int
  /// 活跃 memory 数（不含 disabled）。
  public let memoryCount: Int
  /// 最后一条事件的时间；库为空时为 nil。
  public let latestEventAt: Date?

  public init(sessionCount: Int, eventCount: Int, memoryCount: Int, latestEventAt: Date?) {
    self.sessionCount = sessionCount
    self.eventCount = eventCount
    self.memoryCount = memoryCount
    self.latestEventAt = latestEventAt
  }
}

/// 项目级上下文包（MCP `get_project_context` 的数据源）。
public struct ProjectContextSnapshot: Equatable, Sendable {
  public let projectPath: String
  public let projectName: String
  public let sessions: [SessionSummaryRow]
  public let memories: [MemoryRecord]
  public let tasks: [TaskDescriptor]
  /// PINNED memory：无条件随项目上下文交付，不参与任何排名竞争。
  public let pinned: [MemoryRecord]

  public init(
    projectPath: String, projectName: String, sessions: [SessionSummaryRow],
    memories: [MemoryRecord], tasks: [TaskDescriptor], pinned: [MemoryRecord] = []
  ) {
    self.projectPath = projectPath
    self.projectName = projectName
    self.sessions = sessions
    self.memories = memories
    self.tasks = tasks
    self.pinned = pinned
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

  /// memory 命中的 bm25 加权系数。bm25 越负代表越相关，乘以 >1 的系数即整体前移：
  /// 同等相关度下，一条已提炼的结论比单条历史命令对 Agent 更有价值。
  /// 注：两个 FTS 索引的 bm25 不严格同尺度（语料统计不同），该系数是工程近似。
  private static let memoryRankBoost = 1.5

  /// 弱池门控（zero-mem 的教训：「没有记忆」好过「混乱记忆」，PRD §98 Context 污染）。
  ///
  /// 我们的 MATCH 是 AND 前缀语义，多词命中天然覆盖全部查询词，弱池只剩一种形态：
  /// **查询词全是本库的"停用词"级高频词**。FTS5 对超半数文档都含有的词把负 idf
  /// clamp 成极小值——实测：稀有词 rank ≈ -3.56，clamp 词 rank ≈ -1e-6，量级差 6 个
  /// 数量级，是完美的二元判据。池内最优 rank 落在 clamp 区 ⇒ 命中毫无区分度，整池丢弃。
  ///
  /// 小库豁免：微型语料里合法词也容易超半数触发 clamp（3 条记录里 2 条含目标词），
  /// 且小库没什么可污染的——语料低于 `minimumGatedCorpus` 时不启用门控
  ///（zero-mem 的 corpus-size-aware anchor 针对同一个坑）。
  static let clampDetectionThreshold = -1e-4
  static let minimumGatedCorpus = 10

  /// 对一个已按分数升序（越小越相关）的池应用弱池门控。
  static func gate(
    _ scored: [(hit: MemorySearchHit, score: Double)], corpusSize: Int
  ) -> [(hit: MemorySearchHit, score: Double)] {
    guard corpusSize >= minimumGatedCorpus else { return scored }
    guard let best = scored.first?.score else { return scored }
    return best <= clampDetectionThreshold ? scored : []
  }

  /// `ftsQuery` 使用的原始 token 序列。
  static func queryTokens(from raw: String) -> [String] {
    raw.split(whereSeparator: { $0.isWhitespace || $0 == "\"" })
      .prefix(8)
      .map(String.init)
  }

  /// FTS 检索 memories 与历史命令事件的混合结果，按 bm25 相关度排序
  ///（相关度相同才回落到时间倒序），总量不超过 limit。
  /// `status='disabled'` 的 memory 被排除：用户屏蔽即代表不应再进入任何 Agent 上下文。
  ///
  /// - `applyRelevanceGate`：默认开启弱池门控（供 MCP——弱结果宁可不给 Agent）。
  ///   浏览器 UI 检索时可关闭，让用户看到全部命中自行判断。
  /// - `fallbackAcrossProjects`：项目内（含门控后）零命中时自动放宽到全部项目重查一次，
  ///   命中标注 `isCrossProject`。项目内有任何命中时绝不触发，避免跨项目结论泄漏。
  public func search(
    query: String, projectPath: String? = nil, limit: Int = 10,
    applyRelevanceGate: Bool = true,
    fallbackAcrossProjects: Bool = false
  ) throws -> [MemorySearchHit] {
    let hits = try searchOnce(
      query: query, projectPath: projectPath, limit: limit,
      applyRelevanceGate: applyRelevanceGate)
    if hits.isEmpty, fallbackAcrossProjects, let projectPath, !projectPath.isEmpty {
      return try searchOnce(
        query: query, projectPath: nil, limit: limit,
        applyRelevanceGate: applyRelevanceGate
      ).map { hit in
        MemorySearchHit(
          kind: hit.kind, identifier: hit.identifier, title: hit.title, detail: hit.detail,
          projectPath: hit.projectPath, timestamp: hit.timestamp, isCrossProject: true)
      }
    }
    return hits
  }

  /// 单次检索（不含 federation 回落）。
  private func searchOnce(
    query: String, projectPath: String?, limit: Int, applyRelevanceGate: Bool
  ) throws -> [MemorySearchHit] {
    let match = Self.ftsQuery(from: query)
    guard !match.isEmpty else { return [] }
    let bounded = max(1, min(limit, 50))
    // (hit, bm25 加权分)：分数越小越相关，最终统一排序后再截断到 limit。
    var scored: [(hit: MemorySearchHit, score: Double)] = []

    // `f.rank` 是 FTS5 的隐藏列（默认即 bm25）；先按 rank 取各自 top-N，
    // 高相关但年代久远的结果才不会被新的噪音命令挤出窗口。
    var memorySQL = """
      SELECT m.id, m.title, m.content, m.project_path, m.created_at, f.rank
      FROM memories_fts f JOIN memories m ON m.rowid = f.rowid
      WHERE memories_fts MATCH ? AND m.status != 'disabled'
      """
    var memoryValues: [MemoryDatabase.Value] = [.text(match)]
    if let projectPath, !projectPath.isEmpty {
      memorySQL += " AND m.project_path = ?"
      memoryValues.append(.text(projectPath))
    }
    memorySQL += " ORDER BY f.rank LIMIT ?"
    memoryValues.append(.integer(Int64(bounded)))

    for row in try database.query(memorySQL, memoryValues) {
      let hit = MemorySearchHit(
        kind: "memory",
        identifier: MemoryRowMapping.string(row, 0),
        title: MemoryRowMapping.string(row, 1),
        detail: MemoryRowMapping.string(row, 2),
        projectPath: MemoryRowMapping.string(row, 3),
        timestamp: Date(timeIntervalSince1970: MemoryRowMapping.real(row, 4) ?? 0)
      )
      scored.append((hit, (MemoryRowMapping.real(row, 5) ?? 0) * Self.memoryRankBoost))
    }

    var eventSQL = """
      SELECT e.session_id, e.command, e.exit_status, e.output_excerpt, s.project_path, e.at, f.rank
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
    eventSQL += " ORDER BY f.rank LIMIT ?"
    eventValues.append(.integer(Int64(bounded)))

    for row in try database.query(eventSQL, eventValues) {
      let excerpt = MemoryRowMapping.string(row, 3)
      let exit = MemoryRowMapping.int(row, 2)
      var detail = exit.map { "exit \($0)" } ?? ""
      if !excerpt.isEmpty {
        detail += detail.isEmpty ? "" : "\n"
        detail += String(excerpt.suffix(500))
      }
      let hit = MemorySearchHit(
        kind: "command",
        identifier: MemoryRowMapping.string(row, 0),
        title: MemoryRowMapping.string(row, 1),
        detail: detail,
        projectPath: MemoryRowMapping.string(row, 4),
        timestamp: Date(timeIntervalSince1970: MemoryRowMapping.real(row, 5) ?? 0)
      )
      scored.append((hit, MemoryRowMapping.real(row, 6) ?? 0))
    }

    var ordered = scored.sorted { lhs, rhs in
      if lhs.score != rhs.score { return lhs.score < rhs.score }
      return lhs.hit.timestamp > rhs.hit.timestamp
    }
    if applyRelevanceGate {
      ordered = Self.gate(ordered, corpusSize: try searchableCorpusSize())
    }
    return ordered.prefix(bounded).map(\.hit)
  }

  /// 参与检索的语料规模（可检索事件 + 未禁用 memory），供门控的小库豁免判定。
  private func searchableCorpusSize() throws -> Int {
    let rows = try database.query(
      """
      SELECT (SELECT count(*) FROM events WHERE kind IN ('shell_command', 'command_output'))
           + (SELECT count(*) FROM memories WHERE status != 'disabled')
      """, [])
    return rows.first.flatMap { MemoryRowMapping.int($0, 0) } ?? 0
  }

  /// 库级状态概览：三张核心表的计数 + 最后事件时间，一次查询完成。
  public func storeStatus() throws -> MemoryStoreStatus {
    let rows = try database.query(
      """
      SELECT (SELECT count(*) FROM sessions),
             (SELECT count(*) FROM events),
             (SELECT count(*) FROM memories WHERE status != 'disabled'),
             (SELECT max(at) FROM events)
      """, [])
    guard let row = rows.first else {
      return MemoryStoreStatus(sessionCount: 0, eventCount: 0, memoryCount: 0, latestEventAt: nil)
    }
    return MemoryStoreStatus(
      sessionCount: MemoryRowMapping.int(row, 0) ?? 0,
      eventCount: MemoryRowMapping.int(row, 1) ?? 0,
      memoryCount: MemoryRowMapping.int(row, 2) ?? 0,
      latestEventAt: MemoryRowMapping.real(row, 3).map { Date(timeIntervalSince1970: $0) }
    )
  }

  /// 与某个文件路径或关键词相关的历史：命令、失败与 memory 混合，按时间倒序。
  /// 供 MCP `get_related_history`：Agent 进入某模块时可主动查询过往经验。
  public func relatedHistory(
    keyword: String, projectPath: String?, limit: Int = 20,
    fallbackAcrossProjects: Bool = false
  ) throws -> [MemorySearchHit] {
    // 文件路径带 `/` 与 `.`，FTS unicode61 会切成多个 token；
    // 只取末段文件名做匹配，命中率比整路径高得多。
    let leaf = (keyword as NSString).lastPathComponent
    let effective = leaf.isEmpty ? keyword : leaf
    return try search(
      query: effective, projectPath: projectPath, limit: limit,
      fallbackAcrossProjects: fallbackAcrossProjects)
  }

  /// 项目的 PINNED memory（zero-mem 五个 live bug 的教训：关键事实不该依赖检索排名）。
  /// `get_project_context` 无条件带上这批，绕过弱池门控、federation 与一切排序竞争。
  public func pinnedMemories(projectPath: String, limit: Int = 20) throws -> [MemoryRecord] {
    try database.query(
      """
      SELECT id, project_path, session_id, task_id, type, title, content, summary,
             created_at, status, importance, confidence, extractor
      FROM memories WHERE project_path = ? AND status = 'pinned'
      ORDER BY importance DESC, created_at DESC LIMIT ?
      """,
      [.text(projectPath), .integer(Int64(max(1, min(limit, 50))))]
    ).compactMap(MemoryRowMapping.memory(row:))
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
      tasks: try tasks(projectPath: projectPath, limit: 20),
      pinned: try pinnedMemories(projectPath: projectPath)
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
  /// token 切分复用 `queryTokens(from:)`，保证与弱池门控的覆盖计算完全一致。
  public static func ftsQuery(from raw: String) -> String {
    queryTokens(from: raw)
      .map { "\"\($0)\"*" }
      .joined(separator: " ")
  }
}
