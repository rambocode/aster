import Foundation
import Testing

@testable import AsterCore

@Test("关闭的 Pane、Tab、Window 共用容量 12 的持久化 LIFO 历史")
func workflowRecoveryHistoryRestoresMixedItemsLastInFirstOut() {
  let windowID = UUID()
  let pane = WorkflowClosedItem(
    id: UUID(), kind: .pane, originWindowID: windowID,
    closedAt: Date(timeIntervalSince1970: 1)
  )
  let tab = WorkflowClosedItem(
    id: UUID(), kind: .tab, originWindowID: windowID,
    closedAt: Date(timeIntervalSince1970: 2)
  )
  let window = WorkflowClosedItem(
    id: UUID(), kind: .window, originWindowID: windowID,
    closedAt: Date(timeIntervalSince1970: 3)
  )
  var history = WorkflowRecoveryHistory()
  history.record(pane)
  history.record(tab)
  history.record(window)

  #expect(history.popMostRecent() == window)
  #expect(history.popMostRecent() == tab)
  #expect(history.popMostRecent() == pane)
  #expect(history.popMostRecent() == nil)

  for index in 0..<15 {
    history.record(
      WorkflowClosedItem(
        id: UUID(), kind: .pane, originWindowID: windowID,
        closedAt: Date(timeIntervalSince1970: Double(index))
      ))
  }
  #expect(history.entries.count == 12)
  #expect(history.entries.first?.closedAt == Date(timeIntervalSince1970: 3))
  #expect(history.entries.last?.closedAt == Date(timeIntervalSince1970: 14))
}

@Test("启动恢复按正常退出、崩溃、强退、更新和崩溃循环分类")
func workflowSessionRecoveryClassifiesLaunchReasonBeforeApplyingPreference() {
  #expect(
    WorkflowSessionRecoveryPlanner.plan(
      after: .cleanQuit,
      onLaunch: .newWindow,
      snapshotAvailable: true
    ) == .openNewWindow
  )
  #expect(
    WorkflowSessionRecoveryPlanner.plan(
      after: .crash,
      onLaunch: .newWindow,
      snapshotAvailable: true
    ) == .restoreSnapshot(reason: .crash)
  )
  #expect(
    WorkflowSessionRecoveryPlanner.plan(
      after: .forceQuit,
      onLaunch: .newWindow,
      snapshotAvailable: true
    ) == .restoreSnapshot(reason: .forceQuit)
  )
  #expect(
    WorkflowSessionRecoveryPlanner.plan(
      after: .inPlaceUpdate,
      onLaunch: .newWindow,
      snapshotAvailable: true
    ) == .restoreSnapshot(reason: .inPlaceUpdate)
  )
  #expect(
    WorkflowSessionRecoveryPlanner.plan(
      after: .crash,
      onLaunch: .restoreSession,
      snapshotAvailable: true,
      crashLoopDetected: true
    ) == .startFreshAfterCrashLoop
  )
}

@Test("进程恢复默认不执行，白名单按空白分隔 token 前缀匹配")
func workflowProcessRecoveryUsesWhitespaceDelimitedWhitelistPrefixes() {
  #expect(
    !WorkflowProcessRecoveryPolicy.shouldRerun(
      "npm run dev", mode: .none, whitelist: ["npm run dev"])
  )
  #expect(
    WorkflowProcessRecoveryPolicy.shouldRerun(
      "npm run dev --port 3000",
      mode: .whitelistedOnly,
      whitelist: ["npm run dev"]
    )
  )
  #expect(
    !WorkflowProcessRecoveryPolicy.shouldRerun(
      "npm run device",
      mode: .whitelistedOnly,
      whitelist: ["npm run dev"]
    )
  )
  #expect(
    WorkflowProcessRecoveryPolicy.shouldRerun(
      "make serve", mode: .allRunningProcesses, whitelist: []
    )
  )
}

@Test("外部恢复历史解码时丢弃非法时间并只保留最后 12 项")
func workflowRecoveryHistoryBoundsPersistedInput() throws {
  let windowID = UUID()
  let entries = (0..<15).map { index in
    WorkflowClosedItem(
      id: UUID(),
      kind: .tab,
      originWindowID: windowID,
      closedAt: Date(timeIntervalSince1970: Double(index))
    )
  }
  let data = try JSONEncoder().encode(["entries": entries])

  let restored = try JSONDecoder().decode(WorkflowRecoveryHistory.self, from: data)

  #expect(restored.entries.count == 12)
  #expect(restored.entries.first?.closedAt == Date(timeIntervalSince1970: 3))
  #expect(restored.entries.last?.closedAt == Date(timeIntervalSince1970: 14))
}

@Test("Pane 恢复分类默认恢复 multiplexer 和 agent，但进程默认回到干净 Shell")
func workflowPaneRecoveryAppliesCategorySpecificSettings() {
  let defaults = WorkflowPaneRecoverySettings()
  #expect(
    WorkflowPaneRecoveryPlanner.plan(
      category: .multiplexer(sessionIdentifier: "tmux-main"),
      settings: defaults
    ) == .reattachMultiplexer(sessionIdentifier: "tmux-main")
  )
  #expect(
    WorkflowPaneRecoveryPlanner.plan(
      category: .codeAgent(provider: "codex", sessionIdentifier: "session-1"),
      settings: defaults
    ) == .resumeCodeAgent(provider: "codex", sessionIdentifier: "session-1")
  )
  #expect(
    WorkflowPaneRecoveryPlanner.plan(
      category: .runningProcess(command: "npm run dev"),
      settings: defaults
    ) == .openCleanShell
  )

  let whitelisted = WorkflowPaneRecoverySettings(
    processMode: .whitelistedOnly,
    commandWhitelist: ["npm run dev"]
  )
  #expect(
    WorkflowPaneRecoveryPlanner.plan(
      category: .runningProcess(command: "npm run dev --port 3000"),
      settings: whitelisted
    ) == .rerunProcess(command: "npm run dev --port 3000")
  )
}
