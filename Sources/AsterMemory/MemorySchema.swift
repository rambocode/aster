import Foundation

/// Session Memory 数据库 schema 与迁移。版本经 `PRAGMA user_version` 管理；
/// MCP server 打开数据库时以同一常量做握手，不匹配即返回结构化错误。
///
/// 迁移策略：每个版本一个 `if version < N` 分支，只做增量 DDL；已发布版本的分支
/// 不得修改（用户库里可能停在任意中间版本）。
public enum MemorySchema {
  /// 当前 schema 版本。任何 DDL 变化都必须递增并追加迁移分支。
  public static let currentVersion = 2

  /// 幂等迁移：从数据库当前版本逐级升级到 `currentVersion`。
  ///
  /// 整个升级包在一个事务里：`ALTER TABLE ADD COLUMN` 不可重复执行，若中途失败又没有回滚，
  /// user_version 会停在旧值，而部分列已经存在——下次打开重跑同一分支就会永久失败。
  /// SQLite 的 DDL 支持事务，因此回滚能把库还原到干净的旧版本状态。
  public static func migrate(_ database: MemoryDatabase) throws {
    let version = try database.userVersion()
    guard version < currentVersion else { return }
    try database.execute("BEGIN IMMEDIATE")
    do {
      if version < 1 {
        try database.execute(schemaV1)
      }
      if version < 2 {
        try database.execute(schemaV2)
      }
      try database.execute("PRAGMA user_version = \(currentVersion)")
      try database.execute("COMMIT")
    } catch {
      try? database.execute("ROLLBACK")
      throw error
    }
  }

  /// v1：spike 阶段的最小事件流（sessions/events/memories + FTS）。
  private static let schemaV1 = """
    CREATE TABLE IF NOT EXISTS sessions (
      id TEXT PRIMARY KEY,
      project_path TEXT NOT NULL,
      shell TEXT,
      agent_provider TEXT,
      agent_session_id TEXT,
      started_at REAL NOT NULL,
      ended_at REAL,
      exit_code INTEGER,
      status TEXT NOT NULL DEFAULT 'active'
    );
    CREATE TABLE IF NOT EXISTS events (
      id INTEGER PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(id),
      seq INTEGER NOT NULL,
      at REAL NOT NULL,
      kind TEXT NOT NULL,
      command TEXT,
      cwd TEXT,
      exit_status INTEGER,
      output_excerpt TEXT
    );
    CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id, seq);
    CREATE TABLE IF NOT EXISTS memories (
      id TEXT PRIMARY KEY,
      project_path TEXT NOT NULL,
      session_id TEXT,
      type TEXT NOT NULL,
      title TEXT NOT NULL,
      content TEXT NOT NULL,
      created_at REAL NOT NULL
    );
    CREATE VIRTUAL TABLE IF NOT EXISTS events_fts USING fts5(
      command, output_excerpt, content='events', content_rowid='id',
      tokenize='unicode61'
    );
    CREATE TRIGGER IF NOT EXISTS events_fts_insert AFTER INSERT ON events BEGIN
      INSERT INTO events_fts(rowid, command, output_excerpt)
      VALUES (new.id, coalesce(new.command, ''), coalesce(new.output_excerpt, ''));
    END;
    CREATE TRIGGER IF NOT EXISTS events_fts_delete AFTER DELETE ON events BEGIN
      INSERT INTO events_fts(events_fts, rowid, command, output_excerpt)
      VALUES ('delete', old.id, coalesce(old.command, ''), coalesce(old.output_excerpt, ''));
    END;
    CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
      title, content, content='memories', content_rowid='rowid',
      tokenize='unicode61'
    );
    CREATE TRIGGER IF NOT EXISTS memories_fts_insert AFTER INSERT ON memories BEGIN
      INSERT INTO memories_fts(rowid, title, content)
      VALUES (new.rowid, new.title, new.content);
    END;
    CREATE TRIGGER IF NOT EXISTS memories_fts_delete AFTER DELETE ON memories BEGIN
      INSERT INTO memories_fts(memories_fts, rowid, title, content)
      VALUES ('delete', old.rowid, old.title, old.content);
    END;
    """

  /// v2：Phase 1-5 的完整对象图。
  ///
  /// 设计取舍：
  /// - `projects` 以 git toplevel（无 git 则 cwd）为唯一键，sessions 冗余保留
  ///   `project_path` 便于旧数据与只读查询免 join。
  /// - `artifacts` 只存文件指针与字节数，正文落在 transcripts/ 目录，
  ///   避免大 blob 撑大主库影响 FTS 性能。
  /// - `memories` 补齐生命周期字段（status/importance/confidence/extractor），
  ///   `status='disabled'` 的条目对 MCP 检索不可见（用户可屏蔽污染上下文）。
  /// - `context_receipts` 由 MCP 侧写入，是唯一例外的写入面。
  private static let schemaV2 = """
    CREATE TABLE IF NOT EXISTS projects (
      id TEXT PRIMARY KEY,
      path TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL,
      git_remote TEXT,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL,
      last_opened_at REAL
    );
    CREATE TABLE IF NOT EXISTS tasks (
      id TEXT PRIMARY KEY,
      project_id TEXT REFERENCES projects(id),
      title TEXT NOT NULL,
      status TEXT NOT NULL DEFAULT 'open',
      summary TEXT,
      created_at REAL NOT NULL,
      updated_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_tasks_project ON tasks(project_id, updated_at DESC);
    CREATE TABLE IF NOT EXISTS artifacts (
      id TEXT PRIMARY KEY,
      session_id TEXT NOT NULL REFERENCES sessions(id),
      event_id INTEGER REFERENCES events(id),
      kind TEXT NOT NULL,
      relative_path TEXT NOT NULL,
      byte_count INTEGER NOT NULL,
      purged INTEGER NOT NULL DEFAULT 0,
      created_at REAL NOT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_artifacts_session ON artifacts(session_id);
    CREATE TABLE IF NOT EXISTS memory_sources (
      memory_id TEXT NOT NULL REFERENCES memories(id) ON DELETE CASCADE,
      source_kind TEXT NOT NULL,
      source_id TEXT NOT NULL,
      PRIMARY KEY (memory_id, source_kind, source_id)
    );
    CREATE TABLE IF NOT EXISTS context_receipts (
      id TEXT PRIMARY KEY,
      project_path TEXT,
      task_id TEXT,
      session_id TEXT,
      at REAL NOT NULL,
      trigger TEXT NOT NULL,
      query TEXT,
      memory_ids TEXT,
      token_estimate INTEGER NOT NULL DEFAULT 0,
      delivery_method TEXT NOT NULL DEFAULT 'mcp'
    );
    CREATE INDEX IF NOT EXISTS idx_receipts_project ON context_receipts(project_path, at DESC);

    ALTER TABLE sessions ADD COLUMN project_id TEXT REFERENCES projects(id);
    ALTER TABLE sessions ADD COLUMN task_id TEXT REFERENCES tasks(id);
    ALTER TABLE sessions ADD COLUMN git_branch TEXT;
    ALTER TABLE sessions ADD COLUMN git_commit_before TEXT;
    ALTER TABLE sessions ADD COLUMN git_commit_after TEXT;
    ALTER TABLE sessions ADD COLUMN summary TEXT;
    CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project_path, started_at DESC);

    ALTER TABLE events ADD COLUMN source TEXT;
    ALTER TABLE events ADD COLUMN payload TEXT;

    ALTER TABLE memories ADD COLUMN summary TEXT;
    ALTER TABLE memories ADD COLUMN importance INTEGER NOT NULL DEFAULT 0;
    ALTER TABLE memories ADD COLUMN confidence REAL NOT NULL DEFAULT 1.0;
    ALTER TABLE memories ADD COLUMN status TEXT NOT NULL DEFAULT 'active';
    ALTER TABLE memories ADD COLUMN extractor TEXT;
    ALTER TABLE memories ADD COLUMN task_id TEXT;
    ALTER TABLE memories ADD COLUMN updated_at REAL;
    ALTER TABLE memories ADD COLUMN last_accessed_at REAL;
    ALTER TABLE memories ADD COLUMN access_count INTEGER NOT NULL DEFAULT 0;
    CREATE INDEX IF NOT EXISTS idx_memories_project ON memories(project_path, created_at DESC);
    """
}
