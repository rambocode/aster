import Foundation
import Testing

@testable import AsterCore

/// 生命周期用例共用的服务身份。
private func lifecycleServer(serverID: String = "server-a") -> SessionServerReference {
  SessionServerReference(
    machineProfileID: MachineProfile.localProfileID,
    serverID: serverID,
    sessionID: "session-a"
  )
}

/// 构造某个 epoch 下的结束状态。
private func lifecycleStatus(
  terminalID: String = "term-1",
  serverID: String = "server-a",
  serverEpoch: String? = "epoch-1",
  exitCode: Int32? = 0
) -> ManagedTerminalStatus {
  ManagedTerminalStatus(
    reference: ManagedTerminalReference(
      server: lifecycleServer(serverID: serverID), terminalID: terminalID),
    state: .exited,
    pid: nil,
    cwd: nil,
    exitCode: exitCode,
    serverEpoch: serverEpoch
  )
}

@Test func managedTerminalLifecycleDetachNeverRecordsEnd() throws {
  var tracker = ManagedTerminalLifecycleTracker()
  let reference = lifecycleStatus().reference

  let action = tracker.handle(.clientDetached(reference))

  // A08：分离只释放客户端资源，绝不写结束事件。
  #expect(action == .releaseClientResources(reference))
  if case .recordEnded = action { Issue.record("detach must never produce .recordEnded") }
  #expect(tracker.hasRecordedEnd(for: lifecycleStatus()) == false)
}

@Test func managedTerminalLifecycleRealEndAfterDetachStillRecords() throws {
  var tracker = ManagedTerminalLifecycleTracker()
  let status = lifecycleStatus(exitCode: 130)

  _ = tracker.handle(.clientDetached(status.reference))
  let action = tracker.handle(.serverReportedEnd(status))

  #expect(action == .recordEnded(status.reference, exitCode: 130))
  #expect(tracker.hasRecordedEnd(for: status))
}

@Test func managedTerminalLifecycleDuplicateServerEndIsIgnored() throws {
  var tracker = ManagedTerminalLifecycleTracker()
  let status = lifecycleStatus(exitCode: 1)

  #expect(tracker.handle(.serverReportedEnd(status)) == .recordEnded(status.reference, exitCode: 1))
  #expect(tracker.handle(.serverReportedEnd(status)) == .ignoreDuplicate(status.reference))
}

@Test func managedTerminalLifecycleSameTerminalIDUnderNewEpochRecordsAgain() throws {
  var tracker = ManagedTerminalLifecycleTracker()
  let first = lifecycleStatus(serverEpoch: "epoch-1", exitCode: 0)
  // 冷重启后的同名 terminalID 是另一个实例，两次结束都是真实事件。
  let second = lifecycleStatus(serverEpoch: "epoch-2", exitCode: 2)

  #expect(tracker.handle(.serverReportedEnd(first)) == .recordEnded(first.reference, exitCode: 0))
  #expect(tracker.handle(.serverReportedEnd(second)) == .recordEnded(second.reference, exitCode: 2))
  #expect(tracker.handle(.serverReportedEnd(second)) == .ignoreDuplicate(second.reference))
}

@Test func managedTerminalLifecycleHasRecordedEndReflectsState() throws {
  var tracker = ManagedTerminalLifecycleTracker()
  let status = lifecycleStatus(terminalID: "term-x")
  let untouched = lifecycleStatus(terminalID: "term-y")
  let otherServer = lifecycleStatus(terminalID: "term-x", serverID: "server-b")
  let otherEpoch = lifecycleStatus(terminalID: "term-x", serverEpoch: "epoch-9")

  #expect(tracker.hasRecordedEnd(for: status) == false)
  _ = tracker.handle(.serverReportedEnd(status))
  #expect(tracker.hasRecordedEnd(for: status))
  // 身份三元组任一维不同都算另一个实例。
  #expect(tracker.hasRecordedEnd(for: untouched) == false)
  #expect(tracker.hasRecordedEnd(for: otherServer) == false)
  #expect(tracker.hasRecordedEnd(for: otherEpoch) == false)
}
