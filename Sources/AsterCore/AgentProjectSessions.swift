import Foundation

/// 某个项目目录里最近一次结束的 Agent 会话身份。只保留下一次 `--resume` 所需的
/// provider + session ID 与结束时间，不保存 pane、PID 等运行态。
/// `sessionID` 为 nil 表示「只知道该目录跑过这个 provider」：hook 与会话文件都没给出 ID，
/// 下次用 provider 的「续上最近一次」命令（`claude --continue` / `codex resume --last`）。
public struct AgentProjectSessionRecord: Codable, Equatable, Sendable {
  public let provider: AgentProvider
  public let sessionID: String?
  public let endedAt: Date

  public init(provider: AgentProvider, sessionID: String?, endedAt: Date) {
    self.provider = provider
    self.sessionID = sessionID
    self.endedAt = endedAt
  }
}

/// 「项目目录 → 最近一次 Agent 会话」的持久化注册表。
///
/// 目的：Agent 在某个项目里退出后，下次在该目录新开 Pane 时可以直接发送 provider 原生
/// resume 命令（Claude/Grok `--resume`、Codex `resume` 等）。同一目录只保留最新一条；
/// 没有原生 resume 能力的 provider 不记录，否则下次进入时无命令可发。
public struct AgentProjectSessionRegistry: Codable, Equatable, Sendable {
  public static let defaultCapacity = 200

  public private(set) var records: [String: AgentProjectSessionRecord]
  public let capacity: Int

  public init(capacity: Int = AgentProjectSessionRegistry.defaultCapacity) {
    self.capacity = min(max(capacity, 1), 10_000)
    records = [:]
  }

  private enum CodingKeys: String, CodingKey {
    case records
    case capacity
  }

  /// 解码时重新规范化路径并过滤非法 session ID；外部持久化数据不可信，超出容量
  /// 按结束时间只保留最近的条目。
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedCapacity =
      try container.decodeIfPresent(Int.self, forKey: .capacity) ?? Self.defaultCapacity
    let decoded =
      try container.decodeIfPresent([String: AgentProjectSessionRecord].self, forKey: .records)
      ?? [:]
    self.init(capacity: decodedCapacity)
    for (path, record) in decoded {
      guard let normalized = Self.normalizePath(path),
        Self.isRecordable(provider: record.provider, sessionID: record.sessionID)
      else { continue }
      if let existing = records[normalized], existing.endedAt >= record.endedAt { continue }
      records[normalized] = record
    }
    trimToCapacity()
  }

  /// 登记一次结束的会话。返回 false 表示未记录（路径非法、session ID 非法或 provider
  /// 不支持 resume；ID 为 nil 时 provider 还必须能「续上最近一次」），调用方无需持久化。
  @discardableResult
  public mutating func record(
    provider: AgentProvider,
    sessionID: String?,
    projectDirectory: String,
    endedAt: Date = Date()
  ) -> Bool {
    guard let path = Self.normalizePath(projectDirectory),
      Self.isRecordable(provider: provider, sessionID: sessionID)
    else { return false }
    records[path] = AgentProjectSessionRecord(
      provider: provider, sessionID: sessionID, endedAt: endedAt)
    trimToCapacity()
    return true
  }

  /// 该目录最近一次结束的会话；没有记录返回 nil。
  public func latest(for projectDirectory: String) -> AgentProjectSessionRecord? {
    guard let path = Self.normalizePath(projectDirectory) else { return nil }
    return records[path]
  }

  /// 移除目录记录（会话已被用户删除或 resume 失败时使用）。
  @discardableResult
  public mutating func remove(projectDirectory: String) -> Bool {
    guard let path = Self.normalizePath(projectDirectory) else { return false }
    return records.removeValue(forKey: path) != nil
  }

  /// 去掉尾部斜杠并折叠 `.`/`..`；只接受绝对路径，避免相对路径在不同 cwd 下指向不同项目。
  public static func normalizePath(_ raw: String) -> String? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.hasPrefix("/"), !trimmed.contains("\0") else { return nil }
    let standardized = (trimmed as NSString).standardizingPath
    return standardized.isEmpty ? nil : standardized
  }

  /// 有 ID 时要求 provider 支持 resume 且 ID 合法；没有 ID 时要求 provider 有原生的
  /// 「续上最近一次」命令，否则登记了也发不出任何命令。
  static func isRecordable(provider: AgentProvider, sessionID: String?) -> Bool {
    guard let sessionID else { return provider.continueLatestSessionArguments != nil }
    return isValidSessionID(sessionID) && provider.capabilities.contains(.resumeSession)
  }

  /// 与 `AgentSessionCommandPlanner` 相同的 session ID 约束，保证登记的 ID 一定能规划成命令。
  private static func isValidSessionID(_ sessionID: String) -> Bool {
    !sessionID.isEmpty && sessionID.utf8.count <= AgentLaunchPrefix.maximumComponentBytes
      && !sessionID.contains("\0")
  }

  /// 超出容量时淘汰结束时间最早的记录。
  private mutating func trimToCapacity() {
    guard records.count > capacity else { return }
    let ordered = records.sorted { lhs, rhs in
      if lhs.value.endedAt != rhs.value.endedAt { return lhs.value.endedAt > rhs.value.endedAt }
      return lhs.key < rhs.key
    }
    records = Dictionary(uniqueKeysWithValues: ordered.prefix(capacity).map { ($0.key, $0.value) })
  }
}

/// 注册表的 JSON 编解码入口，与 `FrequentFolderStore` 一致：解码前先按字节限长。
public enum AgentProjectSessionStore {
  public static let maximumBytes = 1 * 1_024 * 1_024

  public static func encode(_ registry: AgentProjectSessionRegistry) throws -> Data {
    try JSONEncoder().encode(registry)
  }

  public static func decode(_ data: Data) throws -> AgentProjectSessionRegistry {
    guard data.count <= maximumBytes else {
      throw AgentProjectSessionStoreError.fileTooLarge(maximumBytes: maximumBytes)
    }
    return try JSONDecoder().decode(AgentProjectSessionRegistry.self, from: data)
  }
}

public enum AgentProjectSessionStoreError: Error, Equatable {
  case fileTooLarge(maximumBytes: Int)
}
