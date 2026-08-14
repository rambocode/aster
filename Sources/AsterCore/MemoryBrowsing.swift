import Foundation

/// Memory 浏览浮层的两个视图分段：Memory 管理与 Context Receipt 留痕。
/// 分段本身是纯值，AppKit 层只按它选择数据源与列表渲染器。
public enum MemoryBrowserTab: String, Codable, Equatable, Sendable, CaseIterable {
  case memories
  case tasks
  case receipts

  public var displayName: String {
    switch self {
    case .memories: "Memory"
    case .tasks: "Task"
    case .receipts: "Context 记录"
    }
  }
}

/// 列表中的一行 Memory 的渲染模型。AppKit 只负责把这些字符串放进 label，
/// 不再自己拼接类型、提炼来源与时间，保证浮层与测试看到同一份真值。
public struct MemoryListItem: Identifiable, Equatable, Sendable {
  public let id: UUID
  public let title: String
  /// 「会话 · 规则提炼 · 08-14 10:22」这类单行副标题。
  public let subtitle: String
  public let typeLabel: String
  public let extractorLabel: String
  public let timestampLabel: String
  /// 被用户屏蔽的 Memory 在列表里降到次要视觉层级，并且 MCP 检索不可见。
  public let isDisabled: Bool

  public init(
    id: UUID,
    title: String,
    subtitle: String,
    typeLabel: String,
    extractorLabel: String,
    timestampLabel: String,
    isDisabled: Bool
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.typeLabel = typeLabel
    self.extractorLabel = extractorLabel
    self.timestampLabel = timestampLabel
    self.isDisabled = isDisabled
  }
}

/// 按日期聚合后的列表分组。空分组永远不会产生，列表可以直接逐段渲染。
public struct MemoryListSection: Equatable, Sendable {
  public let title: String
  public let items: [MemoryListItem]

  public init(title: String, items: [MemoryListItem]) {
    self.title = title
    self.items = items
  }
}

/// Context Receipt 的一行渲染模型（PRD §89：用户必须能看到 Agent 拿到了哪些上下文）。
public struct ContextReceiptItem: Identifiable, Equatable, Sendable {
  public let id: UUID
  /// 查询文本；无查询（如整包项目上下文）时回落为 trigger 名称。
  public let title: String
  /// 「3 条 Memory · 约 420 token · mcp」。
  public let subtitle: String
  public let timestampLabel: String
  public let memoryCount: Int
  public let tokenEstimate: Int

  public init(
    id: UUID,
    title: String,
    subtitle: String,
    timestampLabel: String,
    memoryCount: Int,
    tokenEstimate: Int
  ) {
    self.id = id
    self.title = title
    self.subtitle = subtitle
    self.timestampLabel = timestampLabel
    self.memoryCount = memoryCount
    self.tokenEstimate = tokenEstimate
  }
}

/// Memory 浏览浮层的全部列表逻辑：过滤、分组与渲染字符串拼装。
///
/// 这些函数刻意留在 `AsterCore`：它们是本领域可断言的真值，AppKit 层只做布局与事件。
/// 全部函数都以显式 `now` / `calendar` 参数取代隐式当前时区，测试因此可完全确定。
public enum MemoryBrowsing {
  // MARK: - 标签文本

  /// Memory 类型的中文名。刻意不写成 `MemoryType` 的扩展属性：
  /// 领域模型由记录层拥有，浏览层不往里加展示用成员。
  public static func typeLabel(_ type: MemoryType) -> String {
    switch type {
    case .session: "会话"
    case .task: "Task"
    case .decision: "决策"
    case .failure: "失败经验"
    case .knowledge: "知识"
    }
  }

  /// Memory 状态的中文名，只在非 active 时进入副标题。
  public static func statusLabel(_ status: MemoryStatus) -> String {
    switch status {
    case .active: "生效中"
    case .archived: "已归档"
    case .superseded: "已被取代"
    case .disabled: "已禁用"
    }
  }

  /// 来源回链的中文名，用于详情页的「来源」段。
  public static func sourceLabel(_ kind: MemorySourceRef.Kind) -> String {
    switch kind {
    case .session: "会话"
    case .event: "事件"
    case .task: "Task"
    case .gitCommit: "Git 提交"
    }
  }

  // MARK: - 过滤

  /// 关键词是否命中一条 Memory。标题、正文与摘要都参与匹配，忽略大小写与变音符号，
  /// 与命令面板 `CommandPalette.filter` 保持同一套匹配语义。
  public static func matches(_ record: MemoryRecord, query: String) -> Bool {
    let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !needle.isEmpty else { return true }
    let haystacks = [record.title, record.content, record.summary ?? ""]
    return haystacks.contains { value in
      value.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
  }

  /// 列表过滤：可选类型筛选 + 关键词 + 是否显示已禁用项。
  ///
  /// `includeDisabled` 默认 false 与 `MemoryStoreReader.memories` 一致；管理界面显式传 true，
  /// 否则用户永远看不到自己屏蔽过的条目，也就无法再启用它们。
  public static func filter(
    _ records: [MemoryRecord],
    query: String = "",
    type: MemoryType? = nil,
    includeDisabled: Bool = true
  ) -> [MemoryRecord] {
    records.filter { record in
      if !includeDisabled, record.status == .disabled { return false }
      if let type, record.type != type { return false }
      return matches(record, query: query)
    }
  }

  // MARK: - 渲染模型

  /// 单条 Memory 的渲染模型。已禁用的条目在副标题里显式标注，
  /// 让「这条不会再进入 Agent 上下文」在列表层面就能读到。
  public static func listItem(
    for record: MemoryRecord,
    now: Date,
    calendar: Calendar = .current
  ) -> MemoryListItem {
    let type = typeLabel(record.type)
    let extractor = record.extractor.displayName
    let timestamp = timestampLabel(record.createdAt, now: now, calendar: calendar)
    var parts = [type, extractor, timestamp]
    if record.status != .active {
      parts.append(statusLabel(record.status))
    }
    return MemoryListItem(
      id: record.id,
      title: record.title.isEmpty ? "（无标题）" : record.title,
      subtitle: parts.joined(separator: " · "),
      typeLabel: type,
      extractorLabel: extractor,
      timestampLabel: timestamp,
      isDisabled: record.status == .disabled
    )
  }

  /// 按自然日分组的列表。输入顺序即展示顺序（reader 已按创建时间倒序），
  /// 这里不重新排序，避免与 SQL 的排序真值产生第二套规则。
  public static func sections(
    for records: [MemoryRecord],
    now: Date,
    calendar: Calendar = .current
  ) -> [MemoryListSection] {
    var order: [String] = []
    var buckets: [String: [MemoryListItem]] = [:]
    for record in records {
      let key = dayLabel(record.createdAt, now: now, calendar: calendar)
      if buckets[key] == nil {
        order.append(key)
        buckets[key] = []
      }
      buckets[key]?.append(listItem(for: record, now: now, calendar: calendar))
    }
    return order.map { MemoryListSection(title: $0, items: buckets[$0] ?? []) }
  }

  /// Context Receipt 的渲染模型列表。
  public static func receiptItems(
    _ receipts: [ContextReceipt],
    now: Date,
    calendar: Calendar = .current
  ) -> [ContextReceiptItem] {
    receipts.map { receipt in
      let query = receipt.query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
      let count = receipt.memoryIDs.count
      let subtitle = [
        "\(count) 条 Memory",
        "约 \(receipt.tokenEstimate) token",
        receipt.deliveryMethod,
      ].joined(separator: " · ")
      return ContextReceiptItem(
        id: receipt.id,
        title: query.isEmpty ? receipt.trigger : query,
        subtitle: subtitle,
        timestampLabel: timestampLabel(receipt.timestamp, now: now, calendar: calendar),
        memoryCount: count,
        tokenEstimate: receipt.tokenEstimate
      )
    }
  }

  /// 详情正文：摘要（若有）、正文与来源回链拼成可直接放进 TextView 的纯文本。
  public static func detailText(
    for record: MemoryRecord,
    sources: [MemorySourceRef]
  ) -> String {
    var blocks: [String] = []
    if let summary = record.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
      !summary.isEmpty
    {
      blocks.append(summary)
    }
    let content = record.content.trimmingCharacters(in: .whitespacesAndNewlines)
    if !content.isEmpty { blocks.append(content) }
    if !sources.isEmpty {
      let lines = sources.map { "· \(sourceLabel($0.kind))：\($0.identifier)" }
      blocks.append((["来源"] + lines).joined(separator: "\n"))
    }
    return blocks.joined(separator: "\n\n")
  }

  // MARK: - Task

  /// Task 状态的中文名。与 `TaskStatus.displayName` 相同，但保留在浏览层，
  /// 使这里的所有列表文案有单一出处（重载按参数类型区分，不会与 Memory 状态混淆）。
  public static func statusLabel(_ status: TaskStatus) -> String {
    status.displayName
  }

  /// 可以吸附新会话的 Task：只有进行中的。
  ///
  /// 已完成或已放弃的 Task 不该再接受新会话——那会让「这个 Task 到此为止」失去意义，
  /// 也会让 Memory 的 Task 归属变得不可信。
  public static func assignableTasks(_ tasks: [TaskDescriptor]) -> [TaskDescriptor] {
    tasks.filter { $0.status == .open }
  }

  /// 状态流转后的 Task。`updatedAt` 必须一起更新：列表按它倒序，
  /// 不同步的话用户刚改过的 Task 会留在列表底部，看起来像没生效。
  ///
  /// 状态相同时返回原值，避免一次无意义的写入把 Task 顶到列表最前。
  public static func updating(
    _ task: TaskDescriptor,
    status: TaskStatus,
    now: Date = Date()
  ) -> TaskDescriptor {
    guard task.status != status else { return task }
    var updated = task
    updated.status = status
    updated.updatedAt = now
    return updated
  }

  /// Task 列表项。副标题给出状态与规模，让用户不展开就能判断该继续哪一个。
  public static func taskItem(
    for task: TaskDescriptor,
    sessionCount: Int,
    memoryCount: Int,
    now: Date,
    calendar: Calendar = .current
  ) -> MemoryListItem {
    let status = statusLabel(task.status)
    let timestamp = timestampLabel(task.updatedAt, now: now, calendar: calendar)
    let subtitle = [
      status, "\(sessionCount) 个会话", "\(memoryCount) 条 Memory", timestamp,
    ].joined(separator: " · ")
    return MemoryListItem(
      id: task.id,
      title: task.title.isEmpty ? "（未命名 Task）" : task.title,
      subtitle: subtitle,
      typeLabel: status,
      extractorLabel: "",
      timestampLabel: timestamp,
      isDisabled: task.status != .open
    )
  }

  /// Task 关联的一次会话的可展示摘要。字段刻意全部是普通值：
  /// `AsterCore` 不依赖 `AsterMemory`，SQL 行到这里必须先降为纯数据。
  public struct TaskSessionSummary: Equatable, Sendable {
    public let startedAt: Date
    public let agentProvider: String?
    public let commandCount: Int
    public let failureCount: Int
    public let memoryTitle: String?

    public init(
      startedAt: Date,
      agentProvider: String? = nil,
      commandCount: Int = 0,
      failureCount: Int = 0,
      memoryTitle: String? = nil
    ) {
      self.startedAt = startedAt
      self.agentProvider = agentProvider
      self.commandCount = commandCount
      self.failureCount = failureCount
      self.memoryTitle = memoryTitle
    }
  }

  /// 「继续 Task」时展示的正文：状态、摘要、关联会话与已提炼 Memory。
  public static func taskDetailText(
    task: TaskDescriptor,
    sessions: [TaskSessionSummary],
    memoryTitles: [String],
    now: Date,
    calendar: Calendar = .current
  ) -> String {
    var blocks: [String] = []
    blocks.append("状态：\(statusLabel(task.status))　项目：\(task.projectPath)")
    if let summary = task.summary?.trimmingCharacters(in: .whitespacesAndNewlines),
      !summary.isEmpty
    {
      blocks.append(summary)
    }
    if sessions.isEmpty {
      blocks.append("关联会话\n· 尚未归入任何会话")
    } else {
      let lines = sessions.map { session -> String in
        var parts = [timestampLabel(session.startedAt, now: now, calendar: calendar)]
        if let provider = session.agentProvider, !provider.isEmpty { parts.append(provider) }
        parts.append("\(session.commandCount) 条命令")
        if session.failureCount > 0 { parts.append("\(session.failureCount) 次失败") }
        if let title = session.memoryTitle, !title.isEmpty { parts.append(title) }
        return "· " + parts.joined(separator: " · ")
      }
      blocks.append((["关联会话"] + lines).joined(separator: "\n"))
    }
    if !memoryTitles.isEmpty {
      blocks.append((["已提炼 Memory"] + memoryTitles.map { "· \($0)" }).joined(separator: "\n"))
    }
    return blocks.joined(separator: "\n\n")
  }

  // MARK: - 时间文本

  /// 日期分组标题：今天 / 昨天 / `yyyy-MM-dd`。
  public static func dayLabel(_ date: Date, now: Date, calendar: Calendar = .current) -> String {
    if calendar.isDate(date, inSameDayAs: now) { return "今天" }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(date, inSameDayAs: yesterday)
    {
      return "昨天"
    }
    let parts = calendar.dateComponents([.year, .month, .day], from: date)
    return String(
      format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
  }

  /// 行内时间戳：当天只显示时分，同年显示月日时分，跨年显示完整日期。
  /// 不使用 `DateFormatter`，避免 locale 与线程共享带来的不确定性。
  public static func timestampLabel(_ date: Date, now: Date, calendar: Calendar = .current)
    -> String
  {
    let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    let month = parts.month ?? 0
    let day = parts.day ?? 0
    let hour = parts.hour ?? 0
    let minute = parts.minute ?? 0
    if calendar.isDate(date, inSameDayAs: now) {
      return String(format: "%02d:%02d", hour, minute)
    }
    let currentYear = calendar.dateComponents([.year], from: now).year
    if parts.year == currentYear {
      return String(format: "%02d-%02d %02d:%02d", month, day, hour, minute)
    }
    return String(format: "%04d-%02d-%02d", parts.year ?? 0, month, day)
  }
}
