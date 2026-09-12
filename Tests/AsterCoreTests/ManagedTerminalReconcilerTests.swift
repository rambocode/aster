import Foundation
import Testing

@testable import AsterCore

/// 构造一个稳定的服务身份，便于各用例只改变需要验证的那一维。
private func managedTerminalServer(
  serverID: String = "server-a",
  sessionID: String = "session-a"
) -> SessionServerReference {
  SessionServerReference(
    machineProfileID: MachineProfile.localProfileID,
    serverID: serverID,
    sessionID: sessionID
  )
}

/// 构造持久化引用。
private func managedTerminalReference(
  server: SessionServerReference = managedTerminalServer(),
  terminalID: String = "term-1"
) -> ManagedTerminalReference {
  ManagedTerminalReference(server: server, terminalID: terminalID)
}

/// 构造服务端实测状态。
private func managedTerminalStatus(
  reference: ManagedTerminalReference,
  state: ManagedTerminalState,
  pid: Int32? = nil,
  exitCode: Int32? = nil,
  serverEpoch: String? = "epoch-1"
) -> ManagedTerminalStatus {
  ManagedTerminalStatus(
    reference: reference,
    state: state,
    pid: pid,
    cwd: "/tmp",
    exitCode: exitCode,
    serverEpoch: serverEpoch
  )
}

@Test func managedTerminalReconcilerAttachesSameServerSameEpochRunningTerminal() throws {
  let server = managedTerminalServer()
  let reference = managedTerminalReference(server: server)
  let live = managedTerminalStatus(reference: reference, state: .running, pid: 4242)

  let result = ManagedTerminalReconciler.reconcile(
    references: [reference],
    liveTerminals: [live],
    currentServer: server,
    currentServerEpoch: "epoch-1",
    persistedServerEpoch: "epoch-1"
  )

  guard case .attached(let status) = try #require(result[reference]) else {
    Issue.record("expected .attached, got \(String(describing: result[reference]))")
    return
  }
  #expect(status.pid == 4242)
  #expect(status.reference == reference)
}

@Test func managedTerminalReconcilerReportsExitedTerminalAsExitedNotAttached() throws {
  let server = managedTerminalServer()
  let reference = managedTerminalReference(server: server)
  let live = managedTerminalStatus(reference: reference, state: .exited, exitCode: 3)

  let result = ManagedTerminalReconciler.reconcile(
    references: [reference],
    liveTerminals: [live],
    currentServer: server,
    currentServerEpoch: "epoch-1",
    persistedServerEpoch: "epoch-1"
  )

  guard case .exited(let status) = try #require(result[reference]) else {
    Issue.record("expected .exited, got \(String(describing: result[reference]))")
    return
  }
  #expect(status.exitCode == 3)
  // 显式否证：退出的终端绝不能被当成仍可附加。
  if case .attached = result[reference]! { Issue.record("exited terminal reported as attached") }
}

@Test func managedTerminalReconcilerDetectsColdRestartByServerEpoch() throws {
  let server = managedTerminalServer()
  let reference = managedTerminalReference(server: server)
  // 冷重启后 terminalID 不复用，但这里故意让新实例列出同名 terminalID，
  // 验证对账不会因为名字撞车就宣称原进程仍存活。
  let live = managedTerminalStatus(
    reference: reference, state: .running, pid: 999, serverEpoch: "epoch-2")

  let result = ManagedTerminalReconciler.reconcile(
    references: [reference],
    liveTerminals: [live],
    currentServer: server,
    currentServerEpoch: "epoch-2",
    persistedServerEpoch: "epoch-1"
  )

  guard case .serverRestarted(let expected, let epoch) = try #require(result[reference]) else {
    Issue.record("expected .serverRestarted, got \(String(describing: result[reference]))")
    return
  }
  #expect(expected == reference)
  #expect(epoch == "epoch-2")
}

@Test func managedTerminalReconcilerTreatsDifferentServerIDAsRestarted() throws {
  let reference = managedTerminalReference(server: managedTerminalServer(serverID: "server-a"))
  let current = managedTerminalServer(serverID: "server-b")
  let live = managedTerminalStatus(
    reference: ManagedTerminalReference(server: current, terminalID: "term-1"), state: .running)

  let result = ManagedTerminalReconciler.reconcile(
    references: [reference],
    liveTerminals: [live],
    currentServer: current,
    currentServerEpoch: "epoch-1",
    persistedServerEpoch: "epoch-1"
  )

  guard case .serverRestarted(let expected, _) = try #require(result[reference]) else {
    Issue.record("expected .serverRestarted, got \(String(describing: result[reference]))")
    return
  }
  #expect(expected == reference)
}

@Test func managedTerminalReconcilerReportsUnreachableWithoutClaimingAttached() throws {
  let server = managedTerminalServer()
  let reference = managedTerminalReference(server: server)
  let live = managedTerminalStatus(reference: reference, state: .running, pid: 7)

  // 情况一：完全拿不到当前服务身份。
  let noServer = ManagedTerminalReconciler.reconcile(
    references: [reference],
    liveTerminals: [],
    currentServer: nil,
    currentServerEpoch: nil,
    persistedServerEpoch: "epoch-1"
  )
  guard case .unreachable(let ref1, let reason1) = try #require(noServer[reference]) else {
    Issue.record("expected .unreachable, got \(String(describing: noServer[reference]))")
    return
  }
  #expect(ref1 == reference)
  #expect(!reason1.isEmpty)

  // 情况二：拿到了身份和列表，但连接层已判定不可达；仍不得报告 attached。
  let degraded = ManagedTerminalReconciler.reconcile(
    references: [reference],
    liveTerminals: [live],
    currentServer: server,
    currentServerEpoch: "epoch-1",
    persistedServerEpoch: "epoch-1",
    unreachableReason: "socket timeout"
  )
  guard case .unreachable(let ref2, let reason2) = try #require(degraded[reference]) else {
    Issue.record("expected .unreachable, got \(String(describing: degraded[reference]))")
    return
  }
  #expect(ref2 == reference)
  #expect(reason2 == "socket timeout")
}

@Test func managedTerminalReconcilerReportsMissingTerminal() throws {
  let server = managedTerminalServer()
  let reference = managedTerminalReference(server: server, terminalID: "term-gone")
  let other = managedTerminalStatus(
    reference: ManagedTerminalReference(server: server, terminalID: "term-other"),
    state: .running
  )

  let result = ManagedTerminalReconciler.reconcile(
    references: [reference],
    liveTerminals: [other],
    currentServer: server,
    currentServerEpoch: "epoch-1",
    persistedServerEpoch: "epoch-1"
  )

  guard case .missing(let missing) = try #require(result[reference]) else {
    Issue.record("expected .missing, got \(String(describing: result[reference]))")
    return
  }
  #expect(missing == reference)
}
