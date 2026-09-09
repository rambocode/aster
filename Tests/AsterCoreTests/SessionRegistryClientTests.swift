import Foundation
import Testing

@testable import AsterCore

/// P4.1 客户端半边：命名会话注册表的 argv 形状、解码与错误语义（A13）。

@Test func remoteWorkP4RegistryEndpointHasNoSessionName() {
  let endpoint = P4Fixtures.registryEndpoint
  // 注册表作用域跨全部命名会话，因此 argv 里只有 state-parent，没有会话名。
  #expect(ManagedSessionCommand.sessionList(endpoint) == ["session", "list", "/tmp/aster-p4"])
  #expect(
    ManagedSessionCommand.sessionCreate(endpoint, name: "build")
      == ["session", "create", "/tmp/aster-p4", "build"])
  #expect(
    ManagedSessionCommand.sessionStop(endpoint, selector: .name("build"))
      == ["session", "stop", "/tmp/aster-p4", "build"])
  #expect(
    ManagedSessionCommand.sessionDelete(endpoint, selector: .sessionID(P4Fixtures.sessionID))
      == ["session", "delete", "/tmp/aster-p4", P4Fixtures.sessionID])
  #expect(
    ManagedSessionCommand.sessionAttach(endpoint, selector: .name("build"))
      == ["session", "attach", "/tmp/aster-p4", "build"])
}

@Test func remoteWorkP4RegistryListDecodesStableIdentities() throws {
  let output = try P4Fixtures.registryResponse(
    operation: "session.list",
    result: [
      "sessions": [
        [
          "sessionID": P4Fixtures.sessionID, "name": "work", "state": "running",
          "serverID": P4Fixtures.serverID, "serverEpoch": P4Fixtures.serverEpoch,
        ],
        // 已停止的会话没有运行实例，因此没有 serverID / serverEpoch。
        ["sessionID": "0f9a2f1e-2a1b-4c3d-8e5f-6a7b8c9d0e1f", "name": "idle", "state": "stopped"],
      ]
    ])
  let client = P4ScriptedSessionClient(outputs: [output])
  let sessions = try client.listSessions(P4Fixtures.registryEndpoint)

  #expect(sessions.count == 2)
  #expect(sessions[0].state == .running)
  #expect(sessions[0].serverID == P4Fixtures.serverID)
  #expect(sessions[1].state == .stopped)
  #expect(sessions[1].serverID == nil)
  #expect(client.invocations == [["session", "list", "/tmp/aster-p4"]])
}

@Test func remoteWorkP4RegistryRejectsUnknownSessionState() throws {
  let output = try P4Fixtures.registryResponse(
    operation: "session.list",
    result: [
      "sessions": [["sessionID": P4Fixtures.sessionID, "name": "work", "state": "future_state"]]
    ])
  let client = P4ScriptedSessionClient(outputs: [output])
  // 未知状态不能被猜成 running/stopped：猜错会导致误删或误报任务已完成。
  #expect(throws: ManagedSessionError.malformedReply("unknown session state")) {
    _ = try client.listSessions(P4Fixtures.registryEndpoint)
  }
}

@Test func remoteWorkP4RegistryStopAffectsOnlyRequestedSession() throws {
  let output = try P4Fixtures.registryResponse(
    operation: "session.stop",
    result: ["sessionID": P4Fixtures.sessionID, "name": "work", "state": "stopped"])
  let client = P4ScriptedSessionClient(outputs: [output])
  let stopped = try client.stopSession(P4Fixtures.registryEndpoint, selector: .name("work"))

  #expect(stopped.state == .stopped)
  // 只发出一条命令，且命令里只出现被停止的那个会话名。
  #expect(client.invocations.count == 1)
  #expect(client.invocations[0] == ["session", "stop", "/tmp/aster-p4", "work"])
}

@Test func remoteWorkP4RegistrySurfacesSessionRunningOnDelete() throws {
  let output = try P4Fixtures.errorEnvelope(
    operation: "session.delete", code: "session_running",
    message: "session is running", retry: "after_query")
  let client = P4ScriptedSessionClient(outputs: [output])

  do {
    _ = try client.deleteSession(P4Fixtures.registryEndpoint, selector: .name("work"))
    Issue.record("expected session_running")
  } catch let error as ManagedSessionError {
    // 必须原样暴露成可识别错误，不能降级成通用失败，也不能自动先停止再删除。
    #expect(error.isSessionRunning)
    #expect(error == .serviceError(code: "session_running", message: "session is running"))
  }
}

@Test func remoteWorkP4RegistryDeleteReturnsServerFlag() throws {
  let output = try P4Fixtures.registryResponse(
    operation: "session.delete", result: ["deleted": true])
  let client = P4ScriptedSessionClient(outputs: [output])
  #expect(try client.deleteSession(P4Fixtures.registryEndpoint, selector: .name("idle")))
}

@Test func remoteWorkP4RegistryCreateAndAttachDecodeDescriptor() throws {
  let created = try P4Fixtures.registryResponse(
    operation: "session.create",
    result: [
      "sessionID": P4Fixtures.sessionID, "name": "build", "state": "running",
      "serverID": P4Fixtures.serverID, "serverEpoch": P4Fixtures.serverEpoch,
    ])
  let attached = try P4Fixtures.registryResponse(
    operation: "session.attach",
    result: ["sessionID": P4Fixtures.sessionID, "name": "build", "state": "attention"])
  let client = P4ScriptedSessionClient(outputs: [created, attached])

  #expect(try client.createSession(P4Fixtures.registryEndpoint, name: "build").name == "build")
  #expect(
    try client.attachSession(P4Fixtures.registryEndpoint, selector: .name("build")).state
      == .attention)
}

@Test func remoteWorkP4RegistryEndpointDerivesSessionEndpoint() {
  let registry = P4Fixtures.registryEndpoint
  let session = registry.sessionEndpoint(name: "other")
  #expect(session.stateParentPath == registry.stateParentPath)
  #expect(session.binaryPath == registry.binaryPath)
  #expect(session.sessionName == "other")
  #expect(session.machineProfileID == registry.machineProfileID)
}
