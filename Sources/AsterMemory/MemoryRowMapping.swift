import AsterCore
import Foundation

/// SQLite 行 → 领域值类型的映射。读写两侧共用，保证列顺序约定只写一次。
/// 每个方法都要求调用方按注释里的 SELECT 列顺序取数。
enum MemoryRowMapping {
  /// 列序：seq, at, kind, command, cwd, exit_status, output_excerpt, source, payload
  static func event(row: [MemoryDatabase.Value?], sessionID: UUID) -> RecordedEvent? {
    guard let seq = int(row, 0),
      let at = real(row, 1),
      let kind = MemoryEventKind(rawValue: string(row, 2))
    else { return nil }
    return RecordedEvent(
      sessionID: sessionID,
      sequence: seq,
      timestamp: Date(timeIntervalSince1970: at),
      kind: kind,
      command: optionalString(row, 3),
      workingDirectory: optionalString(row, 4),
      exitStatus: int(row, 5),
      outputExcerpt: optionalString(row, 6),
      source: optionalString(row, 7).flatMap(MemoryEventSource.init(rawValue:)),
      payload: optionalString(row, 8)
    )
  }

  /// 列序：id, project_path, shell, agent_provider, agent_session_id, started_at,
  ///       task_id, git_branch
  static func sessionDescriptor(row: [MemoryDatabase.Value?]) -> RecordedSessionDescriptor? {
    guard let id = UUID(uuidString: string(row, 0)), let startedAt = real(row, 5) else {
      return nil
    }
    return RecordedSessionDescriptor(
      id: id,
      projectPath: string(row, 1),
      shell: optionalString(row, 2),
      agentProvider: optionalString(row, 3),
      agentSessionID: optionalString(row, 4),
      startedAt: Date(timeIntervalSince1970: startedAt),
      taskID: optionalString(row, 6).flatMap(UUID.init(uuidString:)),
      gitBranch: optionalString(row, 7)
    )
  }

  /// 列序：id, project_path, session_id, task_id, type, title, content, summary,
  ///       created_at, status, importance, confidence, extractor
  static func memory(row: [MemoryDatabase.Value?]) -> MemoryRecord? {
    guard let id = UUID(uuidString: string(row, 0)),
      let type = MemoryType(rawValue: string(row, 4)),
      let createdAt = real(row, 8)
    else { return nil }
    return MemoryRecord(
      id: id,
      projectPath: string(row, 1),
      sessionID: optionalString(row, 2).flatMap(UUID.init(uuidString:)),
      taskID: optionalString(row, 3).flatMap(UUID.init(uuidString:)),
      type: type,
      title: string(row, 5),
      content: string(row, 6),
      summary: optionalString(row, 7),
      status: MemoryStatus(rawValue: string(row, 9)) ?? .active,
      importance: int(row, 10) ?? 0,
      confidence: real(row, 11) ?? 1.0,
      extractor: MemoryExtractorKind(rawValue: string(row, 12)) ?? .ruleBased,
      createdAt: Date(timeIntervalSince1970: createdAt)
    )
  }

  /// 列序：id, project_path, title, status, summary, created_at, updated_at
  static func task(row: [MemoryDatabase.Value?]) -> TaskDescriptor? {
    guard let id = UUID(uuidString: string(row, 0)),
      let createdAt = real(row, 5), let updatedAt = real(row, 6)
    else { return nil }
    return TaskDescriptor(
      id: id,
      projectPath: string(row, 1),
      title: string(row, 2),
      status: TaskStatus(rawValue: string(row, 3)) ?? .open,
      summary: optionalString(row, 4),
      createdAt: Date(timeIntervalSince1970: createdAt),
      updatedAt: Date(timeIntervalSince1970: updatedAt)
    )
  }

  static func string(_ row: [MemoryDatabase.Value?], _ index: Int) -> String {
    optionalString(row, index) ?? ""
  }

  static func optionalString(_ row: [MemoryDatabase.Value?], _ index: Int) -> String? {
    guard index < row.count, case .text(let value)? = row[index] else { return nil }
    return value
  }

  static func int(_ row: [MemoryDatabase.Value?], _ index: Int) -> Int? {
    guard index < row.count, case .integer(let value)? = row[index] else { return nil }
    return Int(value)
  }

  static func real(_ row: [MemoryDatabase.Value?], _ index: Int) -> Double? {
    guard index < row.count else { return nil }
    switch row[index] {
    case .real(let value): return value
    case .integer(let value): return Double(value)
    default: return nil
    }
  }
}
