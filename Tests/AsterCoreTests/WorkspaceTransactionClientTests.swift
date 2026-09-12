import Foundation
import Testing

@testable import AsterCore

/// P4.2 布局事务：argv 形状、乐观并发与 `revision_conflict` 的两条恢复路径（A15.2）。

private let conflictPaneID = "55555555-5555-4555-8555-555555555555"
private let conflictTerminalID = "66666666-6666-4666-8666-666666666666"

private func transactionClient(_ responses: [P4ScriptedSessionClient.Response]) -> (
  WorkspaceTransactionClient, P4ScriptedSessionClient
) {
  let scripted = P4ScriptedSessionClient(responses: responses)
  return (
    WorkspaceTransactionClient(client: scripted, endpoint: P4Fixtures.endpoint), scripted
  )
}

private func splitResult() -> [String: Any] {
  [
    "pane": ["paneID": conflictPaneID, "terminalID": conflictTerminalID],
    "terminal": ["terminalID": conflictTerminalID, "state": "running", "cwd": "/srv", "pid": 77],
  ]
}

private func emptySnapshot(revision: UInt64) throws -> String {
  try P4Fixtures.sessionResponse(
    operation: "session.snapshot", revision: revision,
    result: ["workspaces": [], "terminals": []])
}

@Test func remoteWorkP4TransactionArgvCarriesExpectedRevision() {
  let endpoint = P4Fixtures.endpoint
  #expect(
    ManagedSessionCommand.workspaceCreate(
      endpoint, expectedRevision: 4, title: "Proj",
      terminal: RemoteTerminalSpec(cwd: "/srv", argv: ["/bin/zsh", "-l"]))
      == [
        "workspace", "create", "/tmp/aster-p4", "work", "--expected-revision", "4",
        "--title", "Proj", "--cwd", "/srv", "--", "/bin/zsh", "-l",
      ])
  #expect(
    ManagedSessionCommand.tabCreate(
      endpoint, workspaceID: "ws", expectedRevision: 7, title: "Main",
      terminal: RemoteTerminalSpec(cwd: "/srv", argv: ["/bin/zsh"]))
      == [
        "tab", "create", "/tmp/aster-p4", "work", "--workspace", "ws",
        "--expected-revision", "7", "--title", "Main", "--cwd", "/srv", "--", "/bin/zsh",
      ])
  #expect(
    ManagedSessionCommand.paneSplit(
      endpoint, paneID: conflictPaneID, direction: .right, expectedRevision: 9,
      terminal: RemoteTerminalSpec(cwd: "/srv", argv: ["/bin/zsh"]))
      == [
        "pane", "split", "/tmp/aster-p4", "work", "--pane", conflictPaneID,
        "--direction", "right", "--expected-revision", "9", "--cwd", "/srv", "--", "/bin/zsh",
      ])
  #expect(
    ManagedSessionCommand.paneClose(endpoint, paneID: conflictPaneID, expectedRevision: 2)
      == [
        "pane", "close", "/tmp/aster-p4", "work", "--expected-revision", "2",
        "--pane", conflictPaneID,
      ])
}

@Test func remoteWorkP4TransactionReturnsNewRevision() throws {
  let (client, _) = transactionClient([
    .output(try P4Fixtures.sessionResponse(operation: "pane.split", revision: 12, result: splitResult()))
  ])
  let result = try client.splitPane(
    paneID: conflictPaneID, direction: .down, expectedRevision: 11,
    terminal: RemoteTerminalSpec(cwd: "/srv", argv: ["/bin/zsh"]))

  #expect(result.revision == 12)
  #expect(result.value.pane.paneID == conflictPaneID)
  #expect(result.value.terminal.state == .running)
  #expect(result.value.terminal.reference.server == P4Fixtures.server)
}

@Test func remoteWorkP4TransactionSurfacesRevisionConflictWithCurrentRevision() throws {
  let (client, _) = transactionClient([
    .output(
      try P4Fixtures.errorEnvelope(
        operation: "pane.split", code: "revision_conflict", currentRevision: 20))
  ])
  #expect(throws: WorkspaceTransactionError.revisionConflict(currentRevision: 20)) {
    _ = try client.splitPane(
      paneID: conflictPaneID, direction: .up, expectedRevision: 3,
      terminal: RemoteTerminalSpec(cwd: "/srv", argv: ["/bin/zsh"]))
  }
}

@Test func remoteWorkP4TransactionSurfacesRevisionConflictWithoutCurrentRevision() throws {
  let (client, _) = transactionClient([
    .output(try P4Fixtures.errorEnvelope(operation: "pane.close", code: "revision_conflict"))
  ])
  // 服务端不带 currentRevision 时必须解成 nil，而不是编造一个数字。
  #expect(throws: WorkspaceTransactionError.revisionConflict(currentRevision: nil)) {
    _ = try client.closePane(paneID: conflictPaneID, expectedRevision: 3)
  }
}

@Test func remoteWorkP4TransactionRetryUsesServerProvidedRevision() throws {
  let (client, scripted) = transactionClient([
    .output(
      try P4Fixtures.errorEnvelope(
        operation: "pane.close", code: "revision_conflict", currentRevision: 42)),
    .output(
      try P4Fixtures.sessionResponse(
        operation: "pane.close", revision: 43, result: ["closed": true])),
  ])

  let result = try client.withConflictRetry(expectedRevision: 5) { revision in
    try client.closePane(paneID: conflictPaneID, expectedRevision: revision)
  }

  #expect(result.revision == 43)
  #expect(result.value)
  // 服务端带回 currentRevision 时**不**再取快照，只有两次调用。
  #expect(scripted.invocations.count == 2)
  #expect(scripted.invocations[1].contains("42"))
  #expect(!scripted.invocations.contains { $0.first == "session" })
}

@Test func remoteWorkP4TransactionRetryFallsBackToFreshSnapshot() throws {
  let (client, scripted) = transactionClient([
    .output(try P4Fixtures.errorEnvelope(operation: "pane.close", code: "revision_conflict")),
    .output(try emptySnapshot(revision: 99)),
    .output(
      try P4Fixtures.sessionResponse(
        operation: "pane.close", revision: 100, result: ["closed": true])),
  ])

  let result = try client.withConflictRetry(expectedRevision: 5) { revision in
    try client.closePane(paneID: conflictPaneID, expectedRevision: revision)
  }

  #expect(result.revision == 100)
  // 没有 currentRevision 时必须重新取快照拿新 revision。
  #expect(scripted.invocations.count == 3)
  #expect(scripted.invocations[1] == ["session", "snapshot", "/tmp/aster-p4", "work"])
  #expect(scripted.invocations[2].contains("99"))
}

@Test func remoteWorkP4TransactionRetryStopsAfterSecondConflict() throws {
  let (client, scripted) = transactionClient([
    .output(
      try P4Fixtures.errorEnvelope(
        operation: "pane.close", code: "revision_conflict", currentRevision: 7)),
    .output(
      try P4Fixtures.errorEnvelope(
        operation: "pane.close", code: "revision_conflict", currentRevision: 8)),
  ])

  // 只重试一次：第二次仍冲突就交回调用方，不在后台无限自旋。
  #expect(throws: WorkspaceTransactionError.conflictAfterRetry(currentRevision: 8)) {
    _ = try client.withConflictRetry(expectedRevision: 5) { revision in
      try client.closePane(paneID: conflictPaneID, expectedRevision: revision)
    }
  }
  #expect(scripted.invocations.count == 2)
}

@Test func remoteWorkP4TransactionRetryWithFreshSnapshotStartsFromSnapshot() throws {
  let (client, scripted) = transactionClient([
    .output(try emptySnapshot(revision: 30)),
    .output(
      try P4Fixtures.sessionResponse(
        operation: "tab.close", revision: 31, result: ["closed": true])),
  ])

  let result = try client.retryWithFreshSnapshot { revision in
    try client.closeTab(tabID: "tab-1", expectedRevision: revision)
  }
  #expect(result.revision == 31)
  #expect(scripted.invocations[0] == ["session", "snapshot", "/tmp/aster-p4", "work"])
  #expect(scripted.invocations[1].contains("30"))
}

@Test func remoteWorkP4TransactionPassesThroughOtherServiceErrors() throws {
  let (client, _) = transactionClient([
    .output(
      try P4Fixtures.errorEnvelope(
        operation: "tab.close", code: "tab_not_found", message: "no such tab", retry: "never"))
  ])
  #expect(
    throws: WorkspaceTransactionError.serviceError(code: "tab_not_found", message: "no such tab")
  ) {
    _ = try client.closeTab(tabID: "tab-1", expectedRevision: 1)
  }
}

@Test func remoteWorkP4TransactionSnapshotDecodesThroughClient() throws {
  let (client, _) = transactionClient([.output(try emptySnapshot(revision: 64))])
  #expect(try client.snapshot().revision == 64)
}

/// P6.4 客户端半边：`session restore` 的 argv 形状与结果解码（冷重启后失效窗格的恢复映射）。
@Test func remoteWorkSessionRestoreArgvAndDecoding() throws {
  #expect(
    ManagedSessionCommand.sessionRestore(P4Fixtures.endpoint, rows: 40, columns: 120)
      == ["session", "restore", "/tmp/aster-p4", "work", "--rows", "40", "--columns", "120"])

  let (client, scripted) = transactionClient([
    .output(
      try P4Fixtures.sessionResponse(
        operation: "session.restore", revision: 9,
        result: [
          "alreadyRestored": false,
          "entries": [
            [
              "paneID": conflictPaneID, "oldTerminalID": "old-1", "newTerminalID": "new-1",
              "path": "new_shell",
            ],
            [
              "paneID": "pane-2", "oldTerminalID": "old-2", "newTerminalID": "new-2",
              "path": "failed", "failureReason": "DirectoryUnavailable",
            ],
          ],
        ]))
  ])
  let result = try client.restoreSession(rows: 40, columns: 120)
  #expect(result.revision == 9)
  #expect(result.alreadyRestored == false)
  #expect(result.entries.count == 2)
  #expect(result.entries.first?.newTerminalID == "new-1")
  #expect(result.entries.last?.path == "failed")
  #expect(result.entries.last?.failureReason == "DirectoryUnavailable")
  #expect(scripted.invocations.last?.prefix(2) == ["session", "restore"])
}

/// 另一客户端已经恢复过：服务端只回 `alreadyRestored=true` 且 entries 为空，解码不得报错。
@Test func remoteWorkSessionRestoreAlreadyRestoredDecodes() throws {
  let (client, _) = transactionClient([
    .output(
      try P4Fixtures.sessionResponse(
        operation: "session.restore", revision: 10,
        result: ["alreadyRestored": true, "entries": []]))
  ])
  let result = try client.restoreSession(rows: 24, columns: 80)
  #expect(result.alreadyRestored)
  #expect(result.entries.isEmpty)
}
