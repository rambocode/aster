import Testing

@testable import AsterCore

/// 内部任务状态 → 对外状态的映射矩阵与等待条件。
struct AgentControlStatusTests {
  @Test("状态矩阵：processing/awaitingInput/idle × unread × 来源")
  func mappingMatrix() {
    typealias M = AgentControlStatusMapper
    #expect(M.map(taskState: .processing, completionUnread: false, authoritative: true, screenDetected: false) == .init(status: .working, source: .hook))
    #expect(M.map(taskState: .processing, completionUnread: true, authoritative: false, screenDetected: true) == .init(status: .working, source: .screen))
    #expect(M.map(taskState: .processing, completionUnread: false, authoritative: false, screenDetected: false) == .init(status: .working, source: .heuristic))

    #expect(M.map(taskState: .awaitingInput, completionUnread: false, authoritative: true, screenDetected: true) == .init(status: .blocked, source: .hook))
    #expect(M.map(taskState: .awaitingInput, completionUnread: false, authoritative: false, screenDetected: true) == .init(status: .blocked, source: .screen))
    #expect(M.map(taskState: .awaitingInput, completionUnread: false, authoritative: false, screenDetected: false) == .init(status: .blocked, source: .heuristic))

    #expect(M.map(taskState: .idle, completionUnread: true, authoritative: true, screenDetected: false) == .init(status: .done, source: .hook))
    #expect(M.map(taskState: .idle, completionUnread: true, authoritative: false, screenDetected: false) == .init(status: .done, source: .heuristic))
    #expect(M.map(taskState: .idle, completionUnread: false, authoritative: true, screenDetected: false) == .init(status: .idle, source: .hook))
    #expect(M.map(taskState: .idle, completionUnread: false, authoritative: false, screenDetected: true) == .init(status: .idle, source: .screen))
    // 纯启发式的 idle 不可信 → unknown。
    #expect(M.map(taskState: .idle, completionUnread: false, authoritative: false, screenDetected: false) == .init(status: .unknown, source: .heuristic))
  }

  @Test("等待条件：默认集合、显式集合、unknown 永不匹配")
  func waitCondition() {
    #expect(AgentWaitCondition.matches(status: .idle, until: []))
    #expect(AgentWaitCondition.matches(status: .done, until: []))
    #expect(AgentWaitCondition.matches(status: .blocked, until: []))
    #expect(!AgentWaitCondition.matches(status: .working, until: []))
    #expect(!AgentWaitCondition.matches(status: .unknown, until: []))
    #expect(AgentWaitCondition.matches(status: .working, until: [.working]))
    #expect(!AgentWaitCondition.matches(status: .idle, until: [.done]))
    #expect(!AgentWaitCondition.matches(status: .unknown, until: [.unknown]))
    #expect(AgentWaitCondition.resolvedUntil([.done, .done, .idle]) == [.done, .idle])
    #expect(AgentWaitCondition.resolvedUntil([]) == [.idle, .done, .blocked])
  }
}
