import Foundation

/// Session Recording 的事件类型（PRD §19 的 MVP 子集）。
///
/// 与 `ShellCommandTimeline` 刻意分离：timeline 是屏幕坐标上的无正文标记，
/// 本枚举描述的是要持久化的工程语义事件。原始输出正文不进事件流，只保留
/// 有界摘录；后续阶段的大块 transcript 走文件系统。
public enum MemoryEventKind: String, Codable, Sendable, CaseIterable {
  case sessionStarted = "session_started"
  case sessionEnded = "session_ended"
  /// 用户提交的一条命令（OSC 133 C 边界；命令文本来自用户输入重建，best-effort）。
  case shellCommand = "shell_command"
  /// 命令完成（OSC 133 D 边界；exitStatus 为 nil 表示 shell 未提供状态，不猜测成功）。
  case commandFinished = "command_finished"
  /// 一条命令的输出摘录（OSC 133 C…D 区间，脱敏后有界截取）。
  case commandOutput = "command_output"
  /// Agent lifecycle hook（OSC 6974）建立或更新了 provider / session 关联。
  case agentStateChanged = "agent_state_changed"
  /// Session 边界或失败命令后采集的 git 状态快照（branch / commit / dirty 统计）。
  case gitStateSnapshot = "git_state_snapshot"
  /// 由 provider transcript 补录的工具调用（Phase 2 摄取，source='transcript'）。
  case agentToolCall = "agent_tool_call"
  /// transcript 中可确认的文件读取与修改；不由终端输出猜测。
  case fileRead = "file_read"
  case fileModified = "file_modified"
}

/// 事件的来源通道。用于区分「终端实测」与「provider transcript 补录」，
/// 后者可能因格式漂移而缺失，展示与检索时需要标注。
public enum MemoryEventSource: String, Codable, Sendable {
  case terminal
  case shellIntegration = "shell_integration"
  case agentHook = "agent_hook"
  case transcript
  case git
}

/// 一条已决定要持久化的 Session 事件。字段在写入前均已通过脱敏与策略过滤，
/// 存储层不再做内容判断。
public struct RecordedEvent: Codable, Equatable, Sendable {
  public let sessionID: UUID
  /// Session 内单调递增序号；持久化后用于排序与完整性检查。
  public let sequence: Int
  public let timestamp: Date
  public let kind: MemoryEventKind
  public let command: String?
  public let workingDirectory: String?
  public let exitStatus: Int?
  /// 有界、已脱敏的输出摘录；只有 `commandOutput` 事件携带。
  public let outputExcerpt: String?
  /// 事件来源通道；nil 视为 `.terminal`（v1 数据无此字段）。
  public let source: MemoryEventSource?
  /// kind 专属的补充字段（JSON 字符串）：git 分支、工具名、文件路径等。
  public let payload: String?

  public init(
    sessionID: UUID,
    sequence: Int,
    timestamp: Date,
    kind: MemoryEventKind,
    command: String? = nil,
    workingDirectory: String? = nil,
    exitStatus: Int? = nil,
    outputExcerpt: String? = nil,
    source: MemoryEventSource? = nil,
    payload: String? = nil
  ) {
    self.sessionID = sessionID
    self.sequence = sequence
    self.timestamp = timestamp
    self.kind = kind
    self.command = command
    self.workingDirectory = workingDirectory
    self.exitStatus = exitStatus
    self.outputExcerpt = outputExcerpt
    self.source = source
    self.payload = payload
  }
}

/// 一次终端 Session 的可持久化描述。运行态（PTY、视图）不进入该结构。
public struct RecordedSessionDescriptor: Codable, Equatable, Sendable {
  public let id: UUID
  /// Session 启动目录；项目归属在 spike 阶段直接使用该路径。
  public let projectPath: String
  public let shell: String?
  public var agentProvider: String?
  public var agentSessionID: String?
  public let startedAt: Date
  /// 归属 Task（Phase 5）；未归属时为 nil，session 依然独立可用。
  public var taskID: UUID?
  /// Session 开始时的 git 分支，便于按分支回溯历史。
  public var gitBranch: String?

  public init(
    id: UUID,
    projectPath: String,
    shell: String?,
    agentProvider: String? = nil,
    agentSessionID: String? = nil,
    startedAt: Date,
    taskID: UUID? = nil,
    gitBranch: String? = nil
  ) {
    self.id = id
    self.projectPath = projectPath
    self.shell = shell
    self.agentProvider = agentProvider
    self.agentSessionID = agentSessionID
    self.startedAt = startedAt
    self.taskID = taskID
    self.gitBranch = gitBranch
  }
}

/// Recording 的三态（PRD §69）。Incognito 与 off 的差别只在语义与 UI：
/// 两者都零落盘，但 Incognito 表示「本次临时隐身」，退出 Pane 后回到全局设置。
public enum RecordingMode: String, Codable, Sendable, CaseIterable {
  case off
  case on
  case incognito

  /// 面向用户的中文名称，设置页与状态指示共用。
  public var displayName: String {
    switch self {
    case .off: "关闭"
    case .on: "记录中"
    case .incognito: "隐身"
    }
  }
}

/// Recording 的启停与排除策略。判定必须发生在事件产生源头：
/// 被排除的事件一开始就不进入写入管线，而不是落盘后再删。
public struct RecordingPolicy: Codable, Equatable, Sendable {
  public var mode: RecordingMode
  /// 前缀匹配的排除目录（按路径段边界比较，`/a/b` 不会误伤 `/a/bc`）。
  public var excludedPathPrefixes: [String]
  /// 命令前缀排除：首个 token 命中即整条命令（含其输出）不记录。
  public var excludedCommandPrefixes: [String]

  public init(
    mode: RecordingMode = .off,
    excludedPathPrefixes: [String] = [],
    excludedCommandPrefixes: [String] = []
  ) {
    self.mode = mode
    self.excludedPathPrefixes = excludedPathPrefixes
    self.excludedCommandPrefixes = excludedCommandPrefixes
  }

  /// 兼容旧调用点的布尔构造。
  public init(isEnabled: Bool, excludedPathPrefixes: [String] = []) {
    self.init(mode: isEnabled ? .on : .off, excludedPathPrefixes: excludedPathPrefixes)
  }

  // MARK: - 内置排除基线（零配置默认）

  /// 高敏目录基线（home 相对）。装配策略时始终并入用户列表：
  /// 用户配置只能追加排除项，不能移除基线 —— 与 Incognito「只能收紧」同一哲学。
  public static let baselineExcludedDirectoryNames: [String] = [
    ".ssh", ".gnupg", ".aws", ".kube", ".password-store",
  ]

  /// 秘密管理类 CLI 基线：这些命令的参数或输出几乎必然含 secret，
  /// 即使 redactor 能遮盖大部分，也不该让它们进入记录管线。
  public static let baselineExcludedCommandPrefixes: [String] = [
    "op", "vault", "pass", "gpg", "security",
  ]

  /// 把目录基线展开成给定 home 下的绝对路径。纯函数：home 由调用方传入，
  /// 测试可用假路径验证展开与边界语义。
  public static func baselineExcludedPathPrefixes(homeDirectory: String) -> [String] {
    let home = normalized(homeDirectory)
    guard !home.isEmpty, home != "/" else { return [] }
    return baselineExcludedDirectoryNames.map { "\(home)/\($0)" }
  }

  /// 判定某条命令是否应被记录。命令为空时只按目录判定（如 session 生命周期事件）。
  public func shouldRecord(command: String?, workingDirectory: String) -> Bool {
    guard shouldRecord(workingDirectory: workingDirectory) else { return false }
    guard let command, !command.isEmpty else { return true }
    let executable = ShellCommandTokenizer.tokenize(command).tokens.first ?? ""
    let name = (executable as NSString).lastPathComponent
    for prefix in excludedCommandPrefixes {
      let trimmed = prefix.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty else { continue }
      if name == trimmed || executable == trimmed { return false }
    }
    return true
  }

  /// 判定某个工作目录下的活动是否应被记录。cwd 为空（如远端 SSH）时保守拒绝，
  /// 避免把无法归属项目的敏感活动落盘。
  public func shouldRecord(workingDirectory: String) -> Bool {
    guard mode == .on else { return false }
    let normalized = Self.normalized(workingDirectory)
    guard !normalized.isEmpty else { return false }
    for prefix in excludedPathPrefixes {
      let excluded = Self.normalized(prefix)
      guard !excluded.isEmpty else { continue }
      if normalized == excluded || normalized.hasPrefix(excluded + "/") {
        return false
      }
    }
    return true
  }

  /// 去掉尾部斜杠，保证前缀比较落在路径段边界上。
  private static func normalized(_ path: String) -> String {
    var value = path
    while value.count > 1, value.hasSuffix("/") {
      value.removeLast()
    }
    return value
  }
}

/// 规则式 Session Memory 草稿（spike / 保底提炼层的输出）。
/// 后续阶段的 CLI Agent 提炼会补充叙述性字段，本结构保持为可离线计算的真值。
public struct SessionMemoryDraft: Codable, Equatable, Sendable {
  public let sessionID: UUID
  public let projectPath: String
  public let title: String
  /// 结构化 markdown 正文：命令统计、失败命令与摘录、agent 参与情况。
  public let content: String

  public init(sessionID: UUID, projectPath: String, title: String, content: String) {
    self.sessionID = sessionID
    self.projectPath = projectPath
    self.title = title
    self.content = content
  }
}

/// 规则式提炼器：从事件序列生成结构化 Session Memory。纯函数、零外发，
/// 是 CLI Agent 提炼不可用时的永久保底实现。
public enum RuleBasedSessionMemoryExtractor {
  /// 从一个 session 的事件序列提炼 Memory 草稿。事件不足以形成有效摘要
  ///（如没有任何命令）时返回 nil，避免制造噪音 Memory（PRD 风险 §97）。
  public static func extract(
    session: RecordedSessionDescriptor,
    events: [RecordedEvent]
  ) -> SessionMemoryDraft? {
    let commands = events.filter { $0.kind == .shellCommand }
    guard !commands.isEmpty else { return nil }

    let finished = events.filter { $0.kind == .commandFinished }
    // 失败命令按 sequence 就近配对前一条 shellCommand，输出摘录同理；
    // spike 只需要顺序近似配对，不追求跨嵌套 shell 的精确归属。
    let failures = finished.filter { ($0.exitStatus ?? 0) != 0 }
    var failureLines: [String] = []
    for failure in failures {
      let command = commands.last(where: { $0.sequence < failure.sequence })
      let text = command?.command ?? "(未知命令)"
      failureLines.append("- `\(text)` 退出码 \(failure.exitStatus ?? -1)")
      if let excerpt = events.first(where: {
        $0.kind == .commandOutput && $0.sequence > failure.sequence - 3
          && $0.sequence <= failure.sequence + 1 && ($0.exitStatus ?? 0) != 0
      })?.outputExcerpt, !excerpt.isEmpty {
        let tail = excerpt.suffix(400)
        failureLines.append("  ```\n  \(tail)\n  ```")
      }
    }

    let agentEvents = events.filter { $0.kind == .agentStateChanged }
    let provider = session.agentProvider
      ?? agentEvents.compactMap(\.command).last

    var lines: [String] = []
    lines.append("## 概要")
    lines.append("- 目录：`\(session.projectPath)`")
    lines.append("- 命令数：\(commands.count)，失败：\(failures.count)")
    if let provider { lines.append("- Agent：\(provider)") }
    lines.append("")
    lines.append("## 命令序列")
    for command in commands.prefix(50) {
      let status = finished.first(where: { $0.sequence > command.sequence })?.exitStatus
      let marker = (status ?? 0) == 0 ? "✓" : "✗"
      lines.append("- \(marker) `\(command.command ?? "")`")
    }
    if !failureLines.isEmpty {
      lines.append("")
      lines.append("## 失败命令")
      lines.append(contentsOf: failureLines)
    }

    let title: String
    if let provider {
      title = "\(provider) session：\(commands.count) 条命令，\(failures.count) 条失败"
    } else {
      title = "Shell session：\(commands.count) 条命令，\(failures.count) 条失败"
    }
    return SessionMemoryDraft(
      sessionID: session.id,
      projectPath: session.projectPath,
      title: title,
      content: lines.joined(separator: "\n")
    )
  }
}
