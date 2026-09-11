import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// P5.5 远端 Agent 事件桥接与通知的验收测试。
//
// 验证：agentChanged 事件流→TerminalSession.agentTaskState 桥接、
// 通知投递（blocked/done-unread）、重复事件不重复通知、stale 不伪造完成。

/// 可注入的通知记录器，不触碰系统通知中心。
@MainActor
private final class AgentNotificationRecorder: TerminalNotificationPosting {
  struct Record {
    let notification: TerminalNotification
    let category: TerminalNotificationCategory
  }

  private(set) var records: [Record] = []

  func post(
    _ notification: TerminalNotification,
    category: TerminalNotificationCategory,
    configuration: ShellConfiguration,
    sourceTabIsFocused: Bool
  ) {
    records.append(Record(notification: notification, category: category))
  }
}

@Suite("RemoteWorkP5AgentEvent")
struct RemoteWorkP5AgentEventTests {

  // MARK: - TerminalSession 远端 Agent 状态桥接

  @Test("applyRemoteAgentState 将 working 映射为 processing")
  @MainActor
  func remoteAgentWorkingMapsToProcessing() {
    let session = TerminalSession(workingDirectory: "/tmp")
    let info = RemoteAgentInfo(
      terminalID: "t-001", provider: .claudeCode, state: .working, source: .hook)
    session.applyRemoteAgentState(info)
    #expect(session.agentTaskState == .processing)
    #expect(session.activeAgentProvider == .claudeCode)
    // Claude Code 的 hook 不覆盖完整生命周期：hook 上报只在没有画面时兜底，不是权威
    #expect(session.remoteAgentStateIsAuthoritative == false)
  }

  @Test("完整生命周期 hook 的 provider 由服务端上报单独裁决")
  @MainActor
  func fullLifecycleHookProviderIsAuthoritative() {
    let session = TerminalSession(workingDirectory: "/tmp")
    session.applyRemoteAgentState(RemoteAgentInfo(
      terminalID: "t-002", provider: .kimiCode, state: .working, source: .hook))
    #expect(session.agentTaskState == .processing)
    #expect(session.remoteAgentStateIsAuthoritative == true)
  }

  @Test("applyRemoteAgentState 将 blocked 映射为 awaitingInput")
  @MainActor
  func remoteAgentBlockedMapsToAwaitingInput() {
    let session = TerminalSession(workingDirectory: "/tmp")
    let info = RemoteAgentInfo(
      terminalID: "t-001", provider: .grokBuild, state: .blocked, source: .screen)
    session.applyRemoteAgentState(info)
    #expect(session.agentTaskState == .awaitingInput)
    #expect(session.activeAgentProvider == .grokBuild)
  }

  @Test("applyRemoteAgentState 将 done+unread 映射为 idle+completionUnread")
  @MainActor
  func remoteAgentDoneUnreadMapsCorrectly() {
    let session = TerminalSession(workingDirectory: "/tmp")
    // 先进入 working 状态
    session.applyRemoteAgentState(RemoteAgentInfo(
      terminalID: "t-001", provider: .codex, state: .working, source: .hook))
    // 转为 done+unread
    session.applyRemoteAgentState(RemoteAgentInfo(
      terminalID: "t-001", provider: .codex, state: .done, unread: true))
    #expect(session.agentTaskState == .idle)
    #expect(session.agentTaskCompletionUnread == true)
  }

  @Test("applyRemoteAgentState: unknown 状态不改变当前状态（stale 不伪造完成）")
  @MainActor
  func remoteAgentUnknownPreservesCurrentState() {
    let session = TerminalSession(workingDirectory: "/tmp")
    session.applyRemoteAgentState(RemoteAgentInfo(
      terminalID: "t-001", provider: .claudeCode, state: .working, source: .hook))
    #expect(session.agentTaskState == .processing)
    // unknown (stale) 不改变状态
    session.applyRemoteAgentState(RemoteAgentInfo(
      terminalID: "t-001", provider: .claudeCode, state: .unknown))
    #expect(session.agentTaskState == .processing)
  }

  @Test("clearRemoteAgentState 清除权威标记")
  @MainActor
  func clearRemoteAgentStateResetsAuthority() {
    let session = TerminalSession(workingDirectory: "/tmp")
    session.applyRemoteAgentState(RemoteAgentInfo(
      terminalID: "t-001", provider: .kimiCode, state: .working))
    #expect(session.remoteAgentStateIsAuthoritative == true)
    session.clearRemoteAgentState()
    #expect(session.remoteAgentStateIsAuthoritative == false)
  }

  // MARK: - 协调器事件处理与通知

  @Test("handleAgentEvent 为 blocked 状态发送通知")
  @MainActor
  func coordinatorPostsNotificationForBlocked() {
    let recorder = AgentNotificationRecorder()
    let coordinator = RemoteWorkspaceCoordinator(model: AppModel())
    coordinator.agentNotificationPoster = recorder

    let machineID = UUID()
    let event = makeAgentEvent(
      terminalID: "t-001", provider: "claudeCode", state: "blocked",
      source: "hook", eventID: "ev-1", machineID: machineID)
    coordinator.handleAgentEvent(event, machineProfileID: machineID)

    #expect(recorder.records.count == 1)
    #expect(recorder.records.first?.notification.title.contains("等待输入") == true)
  }

  @Test("handleAgentEvent 为 done+unread 发送完成通知")
  @MainActor
  func coordinatorPostsNotificationForDoneUnread() {
    let recorder = AgentNotificationRecorder()
    let coordinator = RemoteWorkspaceCoordinator(model: AppModel())
    coordinator.agentNotificationPoster = recorder

    let machineID = UUID()
    let event = makeAgentEvent(
      terminalID: "t-002", provider: "codex", state: "done", unread: true,
      eventID: "ev-2", machineID: machineID)
    coordinator.handleAgentEvent(event, machineProfileID: machineID)

    #expect(recorder.records.count == 1)
    #expect(recorder.records.first?.notification.title.contains("已完成") == true)
  }

  @Test("handleAgentEvent 对 working 状态不发送通知")
  @MainActor
  func coordinatorNoNotificationForWorking() {
    let recorder = AgentNotificationRecorder()
    let coordinator = RemoteWorkspaceCoordinator(model: AppModel())
    coordinator.agentNotificationPoster = recorder

    let machineID = UUID()
    let event = makeAgentEvent(
      terminalID: "t-003", provider: "grokBuild", state: "working",
      eventID: "ev-3", machineID: machineID)
    coordinator.handleAgentEvent(event, machineProfileID: machineID)

    #expect(recorder.records.isEmpty)
  }

  @Test("重复事件只通知一次（按 serverID+epoch+eventID 去重）")
  @MainActor
  func coordinatorDeduplicatesEvents() {
    let recorder = AgentNotificationRecorder()
    let coordinator = RemoteWorkspaceCoordinator(model: AppModel())
    coordinator.agentNotificationPoster = recorder

    let machineID = UUID()
    let event = makeAgentEvent(
      terminalID: "t-004", provider: "claudeCode", state: "blocked",
      eventID: "ev-dup", machineID: machineID)
    coordinator.handleAgentEvent(event, machineProfileID: machineID)
    coordinator.handleAgentEvent(event, machineProfileID: machineID)

    #expect(recorder.records.count == 1)
  }

  @Test("done+unread=false 不发送完成通知")
  @MainActor
  func coordinatorNoNotificationForDoneRead() {
    let recorder = AgentNotificationRecorder()
    let coordinator = RemoteWorkspaceCoordinator(model: AppModel())
    coordinator.agentNotificationPoster = recorder

    let machineID = UUID()
    let event = makeAgentEvent(
      terminalID: "t-005", provider: "codex", state: "done", unread: false,
      eventID: "ev-5", machineID: machineID)
    coordinator.handleAgentEvent(event, machineProfileID: machineID)

    #expect(recorder.records.isEmpty)
  }

  @Test("staleAllForMachine 后不触发完成通知")
  @MainActor
  func staleAgentsDoNotTriggerNotification() {
    let recorder = AgentNotificationRecorder()
    let coordinator = RemoteWorkspaceCoordinator(model: AppModel())
    coordinator.agentNotificationPoster = recorder

    let machineID = UUID()
    // 先上报 working
    let workingEvent = makeAgentEvent(
      terminalID: "t-006", provider: "claudeCode", state: "working",
      eventID: "ev-6a", machineID: machineID)
    coordinator.handleAgentEvent(workingEvent, machineProfileID: machineID)
    #expect(recorder.records.isEmpty)

    // 断线：标记 stale
    coordinator.agentAggregator.staleAllForMachine(machineID: machineID)

    // 验证 aggregator 里状态已是 unknown
    let summaries = coordinator.agentAggregator.aggregate(machineID: UUID(), agents: [])
    let stale = summaries.first(where: { $0.machineID == machineID })
    #expect(stale?.agent.state == .unknown)
  }
}

// MARK: - 测试辅助

/// 构造一个 agentChanged 事件。
@MainActor
private func makeAgentEvent(
  terminalID: String,
  provider: String,
  state: String,
  source: String = "hook",
  unread: Bool = false,
  eventID: String,
  machineID: UUID,
  serverID: String = "srv-test",
  epoch: String = "ep-test",
  sessionID: String = "sess-test"
) -> RemoteSessionEvent {
  let body: [String: Any] = [
    "terminalID": terminalID,
    "provider": provider,
    "state": state,
    "source": source,
    "unread": unread,
  ]
  let bodyData = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
  return RemoteSessionEvent(
    kind: .agentChanged,
    eventID: eventID,
    target: RemoteSessionEventTarget(
      serverID: serverID, serverEpoch: epoch, sessionID: sessionID),
    sequence: 1,
    revision: 1,
    body: bodyData)
}
