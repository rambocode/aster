import Foundation
import Testing

@testable import AsterCore

/// Memory 浏览层的纯函数真值表。时区与「现在」全部显式传入，
/// 保证断言不随运行机器的 locale 或运行时刻漂移。
@Suite("Memory 浏览纯函数")
struct MemoryBrowsingTests {
  /// 固定 UTC 日历：跨时区跑 CI 时分组边界仍然确定。
  private static var calendar: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
  }

  private static let now = Date(timeIntervalSince1970: 1_755_172_800)  // 2025-08-14 12:00 UTC

  private static func makeMemory(
    title: String,
    content: String = "",
    summary: String? = nil,
    type: MemoryType = .session,
    status: MemoryStatus = .active,
    extractor: MemoryExtractorKind = .ruleBased,
    createdAt: Date = MemoryBrowsingTests.now
  ) -> MemoryRecord {
    MemoryRecord(
      projectPath: "/tmp/project",
      type: type,
      title: title,
      content: content,
      summary: summary,
      status: status,
      extractor: extractor,
      createdAt: createdAt
    )
  }

  @Test("关键词命中标题、正文与摘要，忽略大小写")
  func matchesAcrossFields() {
    let record = Self.makeMemory(
      title: "WebSocket 重连", content: "cargo test failed", summary: "根因是超时")
    #expect(MemoryBrowsing.matches(record, query: "websocket"))
    #expect(MemoryBrowsing.matches(record, query: "CARGO"))
    #expect(MemoryBrowsing.matches(record, query: "根因"))
    #expect(!MemoryBrowsing.matches(record, query: "postgres"))
  }

  @Test("空查询命中全部条目")
  func emptyQueryMatchesEverything() {
    let record = Self.makeMemory(title: "任意")
    #expect(MemoryBrowsing.matches(record, query: ""))
    #expect(MemoryBrowsing.matches(record, query: "   "))
  }

  @Test("过滤按类型与禁用状态收窄")
  func filterNarrowsByTypeAndStatus() {
    let records = [
      Self.makeMemory(title: "会话一", type: .session),
      Self.makeMemory(title: "失败经验", type: .failure),
      Self.makeMemory(title: "被屏蔽的会话", type: .session, status: .disabled),
    ]
    #expect(MemoryBrowsing.filter(records).count == 3)
    #expect(MemoryBrowsing.filter(records, includeDisabled: false).count == 2)
    #expect(MemoryBrowsing.filter(records, type: .failure).map(\.title) == ["失败经验"])
    #expect(
      MemoryBrowsing.filter(records, query: "会话", includeDisabled: false).map(\.title)
        == ["会话一"])
  }

  @Test("列表项副标题包含类型、提炼来源与时间")
  func listItemSubtitle() {
    let record = Self.makeMemory(
      title: "重连失败", type: .failure, extractor: .cliAgent("claude"))
    let item = MemoryBrowsing.listItem(for: record, now: Self.now, calendar: Self.calendar)
    #expect(item.typeLabel == "失败经验")
    #expect(item.extractorLabel == "claude 提炼")
    #expect(item.timestampLabel == "12:00")
    #expect(item.subtitle == "失败经验 · claude 提炼 · 12:00")
    #expect(!item.isDisabled)
  }

  @Test("已禁用条目在副标题标注并置位标志")
  func disabledItemIsMarked() {
    let record = Self.makeMemory(title: "旧结论", status: .disabled)
    let item = MemoryBrowsing.listItem(for: record, now: Self.now, calendar: Self.calendar)
    #expect(item.isDisabled)
    #expect(item.subtitle.hasSuffix("已禁用"))
  }

  @Test("空标题回落为占位文本，列表不会出现空行")
  func emptyTitleFallsBack() {
    let item = MemoryBrowsing.listItem(
      for: Self.makeMemory(title: ""), now: Self.now, calendar: Self.calendar)
    #expect(item.title == "（无标题）")
  }

  @Test("按自然日分组，保留输入顺序且不产生空分组")
  func sectionsPreserveOrder() {
    let yesterday = Self.now.addingTimeInterval(-86_400)
    let older = Self.now.addingTimeInterval(-86_400 * 5)
    let records = [
      Self.makeMemory(title: "今天 A"),
      Self.makeMemory(title: "今天 B"),
      Self.makeMemory(title: "昨天", createdAt: yesterday),
      Self.makeMemory(title: "更早", createdAt: older),
    ]
    let sections = MemoryBrowsing.sections(
      for: records, now: Self.now, calendar: Self.calendar)
    #expect(sections.map(\.title) == ["今天", "昨天", "2025-08-09"])
    #expect(sections[0].items.map(\.title) == ["今天 A", "今天 B"])
    #expect(sections.allSatisfy { !$0.items.isEmpty })
  }

  @Test("空输入产生空分组列表")
  func emptySections() {
    #expect(MemoryBrowsing.sections(for: [], now: Self.now, calendar: Self.calendar).isEmpty)
  }

  @Test("跨年时间戳显示完整日期，同年显示月日时分")
  func timestampFormats() {
    let sameYear = Self.now.addingTimeInterval(-86_400 * 30)
    let lastYear = Self.now.addingTimeInterval(-86_400 * 400)
    #expect(
      MemoryBrowsing.timestampLabel(sameYear, now: Self.now, calendar: Self.calendar)
        == "07-15 12:00")
    #expect(
      MemoryBrowsing.timestampLabel(lastYear, now: Self.now, calendar: Self.calendar)
        == "2024-07-10")
  }

  @Test("Receipt 行展示查询、条数与 token 估算")
  func receiptItemSubtitle() {
    let receipt = ContextReceipt(
      projectPath: "/tmp/project",
      timestamp: Self.now,
      trigger: "search_memory",
      query: "reconnect",
      memoryIDs: ["a", "b", "c"],
      tokenEstimate: 420
    )
    let items = MemoryBrowsing.receiptItems(
      [receipt], now: Self.now, calendar: Self.calendar)
    #expect(items.count == 1)
    #expect(items[0].title == "reconnect")
    #expect(items[0].subtitle == "3 条 Memory · 约 420 token · mcp")
    #expect(items[0].memoryCount == 3)
  }

  @Test("无查询的 Receipt 回落显示 trigger 名称")
  func receiptWithoutQuery() {
    let receipt = ContextReceipt(
      projectPath: nil,
      timestamp: Self.now,
      trigger: "get_project_context",
      query: nil,
      memoryIDs: [],
      tokenEstimate: 0
    )
    let items = MemoryBrowsing.receiptItems(
      [receipt], now: Self.now, calendar: Self.calendar)
    #expect(items[0].title == "get_project_context")
    #expect(items[0].subtitle == "0 条 Memory · 约 0 token · mcp")
  }

  // MARK: - Task 状态流转

  @Test("状态流转写回新状态并顶起 updatedAt")
  func taskStatusTransitionUpdatesTimestamp() {
    let created = Self.now.addingTimeInterval(-86_400)
    let task = TaskDescriptor(
      projectPath: "/tmp/project", title: "修复重连", createdAt: created, updatedAt: created)
    let done = MemoryBrowsing.updating(task, status: .completed, now: Self.now)
    #expect(done.status == .completed)
    #expect(done.updatedAt == Self.now)
    // 列表按 updatedAt 倒序：不同步的话刚改过的 Task 会留在底部，看起来像没生效。
    #expect(done.updatedAt > task.updatedAt)
    #expect(done.id == task.id)
    #expect(done.title == task.title)
    #expect(done.createdAt == task.createdAt)
  }

  @Test("已完成的 Task 能重新打开")
  func completedTaskCanReopen() {
    let task = TaskDescriptor(
      projectPath: "/tmp/project", title: "旧任务", status: .completed)
    let reopened = MemoryBrowsing.updating(task, status: .open, now: Self.now)
    #expect(reopened.status == .open)
  }

  @Test("状态没变时原样返回，不产生无意义的写入")
  func unchangedStatusIsNoOp() {
    let task = TaskDescriptor(projectPath: "/tmp/project", title: "进行中的任务")
    let same = MemoryBrowsing.updating(task, status: .open, now: Self.now)
    #expect(same == task)
    #expect(same.updatedAt == task.updatedAt)
  }

  @Test("只有进行中的 Task 能吸附新会话")
  func onlyOpenTasksAreAssignable() {
    let tasks = [
      TaskDescriptor(projectPath: "/p", title: "进行中", status: .open),
      TaskDescriptor(projectPath: "/p", title: "已完成", status: .completed),
      TaskDescriptor(projectPath: "/p", title: "已放弃", status: .abandoned),
    ]
    #expect(MemoryBrowsing.assignableTasks(tasks).map(\.title) == ["进行中"])
  }

  @Test("Task 列表项副标题显示状态、会话数与 Memory 数")
  func taskItemShowsStatus() {
    let task = TaskDescriptor(
      projectPath: "/p", title: "修复重连", status: .completed, updatedAt: Self.now)
    let item = MemoryBrowsing.taskItem(
      for: task, sessionCount: 3, memoryCount: 2, now: Self.now, calendar: Self.calendar)
    #expect(item.subtitle == "已完成 · 3 个会话 · 2 条 Memory · 12:00")
    // 非进行中的 Task 在列表里降到次要层级，与「不能再吸附会话」的规则视觉一致。
    #expect(item.isDisabled)
  }

  @Test("详情正文按摘要、正文、来源顺序拼装")
  func detailTextComposition() {
    let record = Self.makeMemory(
      title: "标题", content: "正文内容", summary: "一句话摘要")
    let sources = [
      MemorySourceRef(kind: .session, identifier: "S1"),
      MemorySourceRef(kind: .gitCommit, identifier: "abc123"),
    ]
    let text = MemoryBrowsing.detailText(for: record, sources: sources)
    #expect(text == "一句话摘要\n\n正文内容\n\n来源\n· 会话：S1\n· Git 提交：abc123")
  }

  @Test("没有摘要与来源时详情只剩正文")
  func detailTextMinimal() {
    let record = Self.makeMemory(title: "标题", content: "只有正文")
    #expect(MemoryBrowsing.detailText(for: record, sources: []) == "只有正文")
  }
}
