import Foundation

/// 项目身份：Session Memory 的隔离边界（PRD §15）。
/// 归属解析优先 git toplevel，无仓库时回落到工作目录本身。
public struct ProjectIdentity: Codable, Equatable, Sendable {
  public let id: UUID
  public let path: String
  public let name: String
  public let gitRemote: String?

  public init(id: UUID = UUID(), path: String, name: String, gitRemote: String? = nil) {
    self.id = id
    self.path = path
    self.name = name
    self.gitRemote = gitRemote
  }

  /// 从（可能来自 git toplevel 的）路径构造身份。路径去尾斜杠，name 取末段；
  /// 根目录等无末段的情况回落到完整路径，避免出现空名项目。
  public static func make(path: String, gitRemote: String? = nil) -> ProjectIdentity? {
    var normalized = path.trimmingCharacters(in: .whitespacesAndNewlines)
    while normalized.count > 1, normalized.hasSuffix("/") { normalized.removeLast() }
    guard normalized.hasPrefix("/") else { return nil }
    let candidate = (normalized as NSString).lastPathComponent
    let name = candidate.isEmpty ? normalized : candidate
    return ProjectIdentity(path: normalized, name: name, gitRemote: gitRemote)
  }
}

/// Task 状态（PRD §16）。MVP 只做手动流转，不做自动归组。
public enum TaskStatus: String, Codable, Sendable, CaseIterable {
  case open
  case completed
  case abandoned

  public var displayName: String {
    switch self {
    case .open: "进行中"
    case .completed: "已完成"
    case .abandoned: "已放弃"
    }
  }
}

/// 一个跨 Agent、跨 Session 的工作单元。
public struct TaskDescriptor: Codable, Equatable, Sendable {
  public let id: UUID
  public var projectPath: String
  public var title: String
  public var status: TaskStatus
  public var summary: String?
  public let createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    projectPath: String,
    title: String,
    status: TaskStatus = .open,
    summary: String? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.id = id
    self.projectPath = projectPath
    self.title = title
    self.status = status
    self.summary = summary
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  /// 标题清洗：去控制字符并限长，保证进入 UI 与 MCP 输出时不破坏渲染。
  public static func sanitizedTitle(_ raw: String) -> String? {
    let cleaned = raw.unicodeScalars
      .filter { !CharacterSet.controlCharacters.contains($0) }
      .reduce(into: "") { $0.unicodeScalars.append($1) }
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleaned.isEmpty else { return nil }
    return String(cleaned.prefix(200))
  }
}

/// Memory 的分类（PRD §28 的 MVP 子集）。
public enum MemoryType: String, Codable, Sendable, CaseIterable {
  case session
  case task
  case decision
  case failure
  case knowledge
}

/// Memory 生命周期状态（PRD §29）。`disabled` 由用户主动屏蔽，
/// 对 MCP 检索不可见，用于切断错误历史造成的上下文污染（PRD §98）。
/// `pinned` 是关键事实的固定席位（PRD §47 PINNED 模式）：`get_project_context`
/// 无条件带上，不与普通检索排名竞争——关键决策不该依赖每次都被搜出来。
public enum MemoryStatus: String, Codable, Sendable, CaseIterable {
  case active
  case pinned
  case archived
  case superseded
  case disabled
}

/// 提炼来源：规则式还是某个 CLI Agent。展示时据此标注可信度。
public enum MemoryExtractorKind: Codable, Equatable, Sendable {
  case ruleBased
  case cliAgent(String)

  /// 持久化用的稳定字符串。
  public var rawValue: String {
    switch self {
    case .ruleBased: "ruleBased"
    case .cliAgent(let provider): "cliAgent:\(provider)"
    }
  }

  public init?(rawValue: String) {
    if rawValue == "ruleBased" {
      self = .ruleBased
    } else if rawValue.hasPrefix("cliAgent:") {
      self = .cliAgent(String(rawValue.dropFirst("cliAgent:".count)))
    } else {
      return nil
    }
  }

  public var displayName: String {
    switch self {
    case .ruleBased: "规则提炼"
    case .cliAgent(let provider): "\(provider) 提炼"
    }
  }
}

/// 一条已持久化的 Memory。
public struct MemoryRecord: Codable, Equatable, Sendable {
  public let id: UUID
  public var projectPath: String
  public var sessionID: UUID?
  public var taskID: UUID?
  public var type: MemoryType
  public var title: String
  public var content: String
  public var summary: String?
  public var status: MemoryStatus
  public var importance: Int
  public var confidence: Double
  public var extractor: MemoryExtractorKind
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    projectPath: String,
    sessionID: UUID? = nil,
    taskID: UUID? = nil,
    type: MemoryType = .session,
    title: String,
    content: String,
    summary: String? = nil,
    status: MemoryStatus = .active,
    importance: Int = 0,
    confidence: Double = 1.0,
    extractor: MemoryExtractorKind = .ruleBased,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.projectPath = projectPath
    self.sessionID = sessionID
    self.taskID = taskID
    self.type = type
    self.title = title
    self.content = content
    self.summary = summary
    self.status = status
    self.importance = importance
    self.confidence = confidence
    self.extractor = extractor
    self.createdAt = createdAt
  }
}

/// Memory 的来源回链（PRD §31）：任何一条 Memory 都能回到产生它的真实工作过程。
public struct MemorySourceRef: Codable, Equatable, Sendable, Hashable {
  public enum Kind: String, Codable, Sendable {
    case session
    case event
    case task
    case gitCommit = "git_commit"
  }

  public let kind: Kind
  public let identifier: String

  public init(kind: Kind, identifier: String) {
    self.kind = kind
    self.identifier = identifier
  }
}

/// Context Receipt（PRD §50）：每次把 Memory 交给 Agent 都留痕，
/// 让用户能看到「Agent 拿到了什么」。MVP 由 MCP 工具调用产生。
public struct ContextReceipt: Codable, Equatable, Sendable {
  public let id: UUID
  public let projectPath: String?
  public let sessionID: UUID?
  public let taskID: UUID?
  public let timestamp: Date
  public let trigger: String
  public let query: String?
  public let memoryIDs: [String]
  public let tokenEstimate: Int
  public let deliveryMethod: String

  public init(
    id: UUID = UUID(),
    projectPath: String?,
    sessionID: UUID? = nil,
    taskID: UUID? = nil,
    timestamp: Date = Date(),
    trigger: String,
    query: String?,
    memoryIDs: [String],
    tokenEstimate: Int,
    deliveryMethod: String = "mcp"
  ) {
    self.id = id
    self.projectPath = projectPath
    self.sessionID = sessionID
    self.taskID = taskID
    self.timestamp = timestamp
    self.trigger = trigger
    self.query = query
    self.memoryIDs = memoryIDs
    self.tokenEstimate = tokenEstimate
    self.deliveryMethod = deliveryMethod
  }

  /// 粗略 token 估算：按 UTF-8 字节 / 4，够用于 UI 的量级提示，不做精确计费。
  public static func estimateTokens(_ text: String) -> Int {
    max(1, text.utf8.count / 4)
  }
}

/// 落在文件系统上的大块内容指针（命令输出正文、transcript 片段）。
public struct ArtifactRef: Codable, Equatable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case commandOutput = "command_output"
    case transcriptChunk = "transcript_chunk"
  }

  public let id: UUID
  public let sessionID: UUID
  public let kind: Kind
  /// 相对 Memory 根目录的路径，避免绝对路径随家目录迁移失效。
  public let relativePath: String
  public let byteCount: Int
  public let createdAt: Date

  public init(
    id: UUID = UUID(),
    sessionID: UUID,
    kind: Kind,
    relativePath: String,
    byteCount: Int,
    createdAt: Date = Date()
  ) {
    self.id = id
    self.sessionID = sessionID
    self.kind = kind
    self.relativePath = relativePath
    self.byteCount = byteCount
    self.createdAt = createdAt
  }
}

/// Session 的完整视图：描述符 + 事件 + 可选 Memory。Timeline UI 与 MCP 共用。
public struct SessionDetail: Codable, Equatable, Sendable {
  public let descriptor: RecordedSessionDescriptor
  public let endedAt: Date?
  public let events: [RecordedEvent]
  public let memory: MemoryRecord?

  public init(
    descriptor: RecordedSessionDescriptor,
    endedAt: Date?,
    events: [RecordedEvent],
    memory: MemoryRecord?
  ) {
    self.descriptor = descriptor
    self.endedAt = endedAt
    self.events = events
    self.memory = memory
  }
}
