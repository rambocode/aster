import Foundation

/// Session 事件流 → Inspector History 时间线可渲染行的纯函数投影。
///
/// 这里刻意不含任何 AppKit 类型与时钟：视图层只把行模型摆进 `NSTableView`，
/// 所有「哪些事件合并成一行、状态怎么判、标题取什么」的判断都留在 AsterCore，
/// 因此可以用真值表测试（CLAUDE.md：能写成纯函数的逻辑不留在 AppKit 层）。

/// 时间线行的语义类别。视图据此选图标与着色角色，不自己再判断事件 kind。
public enum SessionTimelineRowKind: String, Codable, Equatable, Sendable, CaseIterable {
  /// 一条命令（已吸收其完成事件与输出摘录）。
  case command
  /// 无法归属到某条命令的孤立输出摘录。
  case output
  case agentState
  case toolCall
  case fileRead
  case fileModified
  case gitSnapshot

  /// 行首 SF Symbol 名。放在领域层是为了让「图标随语义走」可被测试锁定，
  /// 避免视图层散落魔法字符串后与状态语义漂移。
  public var symbol: String {
    switch self {
    case .command: "chevron.right"
    case .output: "text.alignleft"
    case .agentState: "sparkles"
    case .toolCall: "wrench.and.screwdriver"
    case .fileRead: "doc.text.magnifyingglass"
    case .fileModified: "pencil.line"
    case .gitSnapshot: "arrow.triangle.branch"
    }
  }
}

/// 命令行的完成状态。
///
/// `finishedUnknown` 与 `succeeded` 必须分开：shell 未提供退出码时不得猜成功
///（`MemoryEventKind.commandFinished` 的约定），否则时间线会把失败显示成 ✓。
public enum SessionTimelineStatus: Equatable, Sendable {
  /// 非命令行，或该行没有完成语义。
  case none
  /// 只有 `.shellCommand` 没有 `.commandFinished`：命令未完成或记录被截断。
  case running
  case succeeded
  case failed(Int)
  case finishedUnknown

  /// 行尾状态标记。用符号而不是颜色表达成败，配色由视图另外叠加。
  public var displayText: String {
    switch self {
    case .none: ""
    case .running: "·"
    case .succeeded: "✓"
    case .failed(let code): "✗ \(code)"
    case .finishedUnknown: "—"
    }
  }

  public var isFailure: Bool {
    if case .failed = self { return true }
    return false
  }
}

/// 一行的可展开正文。摘录已随事件落库可直接展示；`artifactRelativePath`
/// 只有在调用方确认该 artifact 仍存在时才非空，视图据此决定是否提供「查看全文」。
public struct SessionTimelineDetail: Equatable, Sendable {
  public let excerpt: String
  public let artifactRelativePath: String?

  public init(excerpt: String, artifactRelativePath: String?) {
    self.excerpt = excerpt
    self.artifactRelativePath = artifactRelativePath
  }
}

/// 时间线上的一行。`id` 在同一 session 内稳定（seq 单调递增），可直接做展开态的键。
public struct SessionTimelineRow: Equatable, Sendable, Identifiable {
  public let id: String
  public let sequence: Int
  public let timestamp: Date
  public let kind: SessionTimelineRowKind
  public let title: String
  public let subtitle: String
  public let status: SessionTimelineStatus
  /// 事件来源通道。`.transcript` 表示来自 Agent 自己的记录而非终端实测，
  /// 视图必须给出可见标注（可能因格式漂移而缺失或不准）。
  public let source: MemoryEventSource
  public let detail: SessionTimelineDetail?

  public init(
    id: String,
    sequence: Int,
    timestamp: Date,
    kind: SessionTimelineRowKind,
    title: String,
    subtitle: String,
    status: SessionTimelineStatus = .none,
    source: MemoryEventSource = .terminal,
    detail: SessionTimelineDetail? = nil
  ) {
    self.id = id
    self.sequence = sequence
    self.timestamp = timestamp
    self.kind = kind
    self.title = title
    self.subtitle = subtitle
    self.status = status
    self.source = source
    self.detail = detail
  }

  public var symbol: String { kind.symbol }

  /// 是否由 provider transcript 补录。展示时需要与终端实测区分开。
  public var isTranscriptSourced: Bool { source == .transcript }
}

/// 事件流 → 行模型的投影器。
public enum SessionTimelineProjection {
  /// 单行标题的最大长度。命令与工具参数都可能是任意长的一行，超过后按字符截断
  /// 并加省略号；正文完整内容仍可经展开区查看。
  public static let maximumTitleLength = 200

  /// 把一个 session 的事件序列投影成时间线行。
  ///
  /// 合并规则（这是本投影存在的理由，视图不应重复实现）：
  /// - `.shellCommand` 吸收其后、下一条 `.shellCommand` 之前的首个 `.commandFinished`
  ///   与首个 `.commandOutput`，合成一行「命令 + 状态 + 可展开输出」。
  /// - `.sessionStarted` / `.sessionEnded` 不产生行：起止时间由页头展示，
  ///   重复出现在时间线里只是噪音。
  /// - 无法配对的 `.commandFinished` / `.commandOutput` 仍各自成行，
  ///   宁可显示一条来源不明的记录，也不静默丢弃已落库的事实。
  ///
  /// - Parameter artifactPaths: 调用方查到的、当前仍存在的 artifact 相对路径集合。
  ///   传空集时所有行都只有摘录、没有「查看全文」入口。
  public static func rows(
    for events: [RecordedEvent],
    artifactPaths: Set<String> = []
  ) -> [SessionTimelineRow] {
    let ordered = events.sorted { $0.sequence < $1.sequence }
    var rows: [SessionTimelineRow] = []
    // 已被某条命令吸收的事件序号，避免它们再单独成行。
    var absorbed: Set<Int> = []

    for (index, event) in ordered.enumerated() {
      guard event.kind == .shellCommand else { continue }
      // 命令的归属窗口止于下一条命令；跨越窗口配对会把后一条命令的结果记到前一条上。
      let windowEnd = ordered[(index + 1)...].first { $0.kind == .shellCommand }?.sequence
        ?? Int.max
      let window = ordered[(index + 1)...].prefix { $0.sequence < windowEnd }
      let finished = window.first { $0.kind == .commandFinished }
      let output = window.first { $0.kind == .commandOutput }
      if let finished { absorbed.insert(finished.sequence) }
      if let output { absorbed.insert(output.sequence) }
      rows.append(
        commandRow(
          anchor: event, command: event, finished: finished, output: output,
          artifactPaths: artifactPaths)
      )
    }

    for event in ordered {
      switch event.kind {
      case .sessionStarted, .sessionEnded, .shellCommand:
        continue
      case .commandFinished:
        guard !absorbed.contains(event.sequence) else { continue }
        rows.append(
          commandRow(
            anchor: event, command: nil, finished: event, output: nil,
            artifactPaths: artifactPaths))
      case .commandOutput:
        guard !absorbed.contains(event.sequence) else { continue }
        rows.append(outputRow(event, artifactPaths: artifactPaths))
      case .agentStateChanged:
        rows.append(agentStateRow(event))
      case .agentToolCall:
        rows.append(toolCallRow(event))
      case .fileRead, .fileModified:
        rows.append(fileRow(event))
      case .gitStateSnapshot:
        rows.append(gitRow(event))
      }
    }

    return rows.sorted { $0.sequence < $1.sequence }
  }

  /// 会话时长的展示文本。未结束时返回 nil，由视图显示「进行中」而不是编造一个时长。
  public static func durationText(from start: Date, to end: Date?) -> String? {
    guard let end else { return nil }
    let seconds = Int(end.timeIntervalSince(start).rounded())
    guard seconds >= 0 else { return nil }
    if seconds < 60 { return "\(seconds) 秒" }
    if seconds < 3_600 { return "\(seconds / 60) 分钟" }
    let hours = seconds / 3_600
    let minutes = (seconds % 3_600) / 60
    return minutes == 0 ? "\(hours) 小时" : "\(hours) 小时 \(minutes) 分"
  }

  // MARK: - 单行构造

  /// `anchor` 决定行的 id、序号与时间戳：有命令事件时用命令，孤立完成事件时用它自己。
  private static func commandRow(
    anchor: RecordedEvent,
    command: RecordedEvent?,
    finished: RecordedEvent?,
    output: RecordedEvent?,
    artifactPaths: Set<String>
  ) -> SessionTimelineRow {
    let text = sanitized(command?.command ?? finished?.command)
    return SessionTimelineRow(
      id: rowIdentifier(anchor),
      sequence: anchor.sequence,
      timestamp: anchor.timestamp,
      kind: .command,
      title: text.isEmpty ? "(未知命令)" : text,
      subtitle: sanitized(anchor.workingDirectory),
      status: status(for: finished, hasCommand: command != nil),
      source: anchor.source ?? .terminal,
      detail: output.flatMap { detail(for: $0, artifactPaths: artifactPaths) }
    )
  }

  /// 完成事件缺席时区分两种情况：有命令 = 仍在运行；连命令都没有 = 数据本身残缺，
  /// 按未知状态显示而不是伪造运行中。
  private static func status(for finished: RecordedEvent?, hasCommand: Bool)
    -> SessionTimelineStatus
  {
    guard let finished else { return hasCommand ? .running : .finishedUnknown }
    guard let code = finished.exitStatus else { return .finishedUnknown }
    return code == 0 ? .succeeded : .failed(code)
  }

  private static func outputRow(_ event: RecordedEvent, artifactPaths: Set<String>)
    -> SessionTimelineRow
  {
    let content = detail(for: event, artifactPaths: artifactPaths)
    return SessionTimelineRow(
      id: rowIdentifier(event),
      sequence: event.sequence,
      timestamp: event.timestamp,
      kind: .output,
      title: "输出摘录",
      subtitle: firstLine(of: content?.excerpt ?? ""),
      source: event.source ?? .terminal,
      detail: content
    )
  }

  private static func agentStateRow(_ event: RecordedEvent) -> SessionTimelineRow {
    let provider = sanitized(event.command)
    let sessionID = payloadValue(event.payload, keys: ["agent_session_id", "agentSessionID", "session_id"])
    return SessionTimelineRow(
      id: rowIdentifier(event),
      sequence: event.sequence,
      timestamp: event.timestamp,
      kind: .agentState,
      title: provider.isEmpty ? "Agent 状态更新" : provider,
      subtitle: sessionID.map { "session \($0)" } ?? "",
      source: event.source ?? .agentHook
    )
  }

  private static func toolCallRow(_ event: RecordedEvent) -> SessionTimelineRow {
    // transcript 补录的 payload 键名由摄取侧决定，这里对几种常见写法都容错：
    // 单一 key 缺失不该让整行退化成空标题。
    let tool = payloadValue(event.payload, keys: ["tool", "tool_name", "toolName", "name"])
      ?? sanitized(event.command)
    let target = payloadValue(event.payload, keys: ["target", "path", "file", "file_path"])
    return SessionTimelineRow(
      id: rowIdentifier(event),
      sequence: event.sequence,
      timestamp: event.timestamp,
      kind: .toolCall,
      title: tool.isEmpty ? "工具调用" : tool,
      subtitle: target.map(sanitized) ?? "",
      source: event.source ?? .transcript
    )
  }

  private static func fileRow(_ event: RecordedEvent) -> SessionTimelineRow {
    let path = payloadValue(event.payload, keys: ["path", "file", "file_path", "relative_path"])
      ?? sanitized(event.command)
    let cleaned = sanitized(path)
    let name = (cleaned as NSString).lastPathComponent
    return SessionTimelineRow(
      id: rowIdentifier(event),
      sequence: event.sequence,
      timestamp: event.timestamp,
      kind: event.kind == .fileModified ? .fileModified : .fileRead,
      title: name.isEmpty ? "(未知文件)" : name,
      subtitle: cleaned,
      source: event.source ?? .transcript
    )
  }

  private static func gitRow(_ event: RecordedEvent) -> SessionTimelineRow {
    let snapshot = event.payload.flatMap(GitSnapshotPayload.decode)
    let branch = snapshot?.branch.map(sanitized).flatMap { $0.isEmpty ? nil : $0 }
    var parts: [String] = []
    if let commit = snapshot?.commit, !commit.isEmpty {
      parts.append(String(sanitized(commit).prefix(7)))
    }
    if let dirty = snapshot?.dirtyFileCount, dirty > 0 { parts.append("\(dirty) 处改动") }
    return SessionTimelineRow(
      id: rowIdentifier(event),
      sequence: event.sequence,
      timestamp: event.timestamp,
      kind: .gitSnapshot,
      title: branch ?? "detached",
      subtitle: parts.joined(separator: " · "),
      source: event.source ?? .git
    )
  }

  // MARK: - 辅助

  private static func rowIdentifier(_ event: RecordedEvent) -> String {
    "\(event.sessionID.uuidString)#\(event.sequence)"
  }

  /// 只有调用方确认存在的 artifact 才给出「查看全文」路径：
  /// 配额轮转会真的删掉正文文件，指向不存在的文件只会让展开永远空白。
  private static func detail(for event: RecordedEvent, artifactPaths: Set<String>)
    -> SessionTimelineDetail?
  {
    let excerpt = event.outputExcerpt?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    let candidate = MemoryTranscriptLayout.relativePath(
      sessionID: event.sessionID, sequence: event.sequence)
    let artifact = artifactPaths.contains(candidate) ? candidate : nil
    guard !excerpt.isEmpty || artifact != nil else { return nil }
    return SessionTimelineDetail(excerpt: excerpt, artifactRelativePath: artifact)
  }

  /// 单行化 + 去控制字符 + 限长。命令文本与 transcript 路径都来自不可信来源，
  /// 未清洗的换行或 CSI 序列会直接破坏 AppKit 行渲染。
  private static func sanitized(_ raw: String?) -> String {
    guard let raw else { return "" }
    var scalars = String.UnicodeScalarView()
    for scalar in raw.unicodeScalars {
      if scalar == "\n" || scalar == "\t" || scalar == "\r" {
        scalars.append(" ")
      } else if CharacterSet.controlCharacters.contains(scalar) {
        continue
      } else {
        scalars.append(scalar)
      }
    }
    let collapsed = String(scalars)
      .split(separator: " ", omittingEmptySubsequences: true)
      .joined(separator: " ")
    guard collapsed.count > maximumTitleLength else { return collapsed }
    return String(collapsed.prefix(maximumTitleLength)) + "…"
  }

  private static func firstLine(of text: String) -> String {
    sanitized(text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init))
  }

  /// 从 payload JSON 顶层对象里按优先级取第一个非空字符串值。
  /// payload 缺失、非 JSON 或值类型不符都返回 nil，由调用方回落。
  private static func payloadValue(_ payload: String?, keys: [String]) -> String? {
    guard let payload, let data = payload.data(using: .utf8),
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    for key in keys {
      if let value = object[key] as? String, !value.isEmpty { return value }
    }
    return nil
  }
}
