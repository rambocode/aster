import Foundation
import Testing

@testable import AsterCore

/// P2.2：会话客户端回复解码与显示桥 argv。
///
/// 这些用例只覆盖纯解码与 argv 构造；真实服务链路的进程证据由
/// `scripts/remote-work-p2-evidence.sh` 生成，不用单测冒充保活验证。

/// 样例 target 段。用函数而不是全局常量，避免非 Sendable 字典成为共享可变状态。
private func sampleTarget() -> [String: Any] {
  [
    "serverID": "bc2d4ef4-ca4e-435e-ab6d-409a79805fc8",
    "serverEpoch": "48922fa9-96c1-47ae-b68e-884fcc7bd272",
    "sessionID": "83dfae3a-991d-4f16-8e69-ddaca142b563",
  ]
}

private func envelopeLine(_ object: [String: Any]) throws -> String {
  String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

@Test func managedSessionDecoderReadsServerIdentity() throws {
  let line = try envelopeLine([
    "type": "response", "operation": "server.status", "target": sampleTarget(),
    "result": ["version": "0.1.0-dev", "capabilities": ["health_check", "terminal_control"]],
  ])
  let identity = try ManagedSessionReplyDecoder.serverIdentity(
    machineProfileID: MachineProfile.localProfileID,
    from: try ManagedSessionReplyDecoder.envelope(line)
  )
  #expect(identity.reference.serverID == sampleTarget()["serverID"] as? String)
  #expect(identity.serverEpoch == sampleTarget()["serverEpoch"] as? String)
  #expect(identity.capabilities.contains("terminal_control"))
}

@Test func managedSessionDecoderMapsTerminalStates() throws {
  let server = SessionServerReference(
    machineProfileID: MachineProfile.localProfileID, serverID: "s", sessionID: "n")
  let running = try ManagedSessionReplyDecoder.terminal(
    ["terminalID": "t", "state": "running", "pid": 4321, "cwd": "/tmp"],
    server: server, serverEpoch: "e")
  #expect(running.state == .running)
  #expect(running.pid == 4321)

  // terminating 仍在清理，不能当作已退出。
  let terminating = try ManagedSessionReplyDecoder.terminal(
    ["terminalID": "t", "state": "terminating"], server: server, serverEpoch: "e")
  #expect(terminating.state == .running)

  let exited = try ManagedSessionReplyDecoder.terminal(
    ["terminalID": "t", "state": "exited", "exit": ["code": 3]], server: server, serverEpoch: "e")
  #expect(exited.state == .exited)
  #expect(exited.exitCode == 3)

  // 未知状态不臆测运行中。
  let unknown = try ManagedSessionReplyDecoder.terminal(
    ["terminalID": "t", "state": "future_state"], server: server, serverEpoch: "e")
  #expect(unknown.state == .unavailable)
}

@Test func managedSessionDecoderSurfacesServiceErrors() throws {
  let line = try envelopeLine([
    "type": "error", "target": sampleTarget(),
    "error": ["code": "unknown_terminal", "message": "no such terminal"],
  ])
  #expect(throws: ManagedSessionError.serviceError(code: "unknown_terminal", message: "no such terminal")) {
    _ = try ManagedSessionReplyDecoder.envelope(line)
  }
  #expect(throws: ManagedSessionError.self) {
    _ = try ManagedSessionReplyDecoder.envelope("not json")
  }
}

@Test func managedSessionBridgeArgumentsSeparateWriteAndObserve() {
  let endpoint = ManagedSessionEndpoint(
    binaryPath: "/tmp/aster-session", stateParentPath: "/tmp/state", sessionName: "p2")
  let client = LocalManagedSessionClient()
  #expect(
    client.bridgeArguments(endpoint, terminalID: "t1", readOnly: false)
      == ["terminal", "attach", "/tmp/state", "p2", "t1"])
  #expect(
    client.bridgeArguments(endpoint, terminalID: "t1", readOnly: true)
      == ["terminal", "observe", "/tmp/state", "p2", "t1"])
}

@Test func managedSessionClientRejectsMissingRuntimeBinary() {
  let endpoint = ManagedSessionEndpoint(
    binaryPath: "/nonexistent/aster-session", stateParentPath: "/tmp", sessionName: "p2")
  #expect(throws: ManagedSessionError.runtimeUnavailable("/nonexistent/aster-session")) {
    _ = try LocalManagedSessionClient().serverStatus(endpoint)
  }
}
