import Foundation
import Testing

@testable import AsterCore

// 测 SSHBrokerProtocol：broker→App 的 JSON Lines 解码（`SshRuntime/PROTOCOL.md` §4.1）、
// App→broker 命令的编码、client 失败结构化错误行解析，以及 client 调用行的 argv 生成。

private func line(_ text: String) -> Data { Data(text.utf8) }

// MARK: - SSHBrokerEvent.decode（§4.1 broker → App）

/// 测：`ready` 事件解码。
@Test func sshBrokerProtocolDecodesReadyEvent() throws {
  let event = try SSHBrokerEvent.decode(
    line: line(#"{"type":"ready","socket":"/tmp/broker.sock","version":"0.1.0"}"#))
  #expect(event == .ready(socket: "/tmp/broker.sock", version: "0.1.0"))
}

/// 测：`auth.request`（password），hostID 分别为 null 与真实 UUID 两种取值。
@Test func sshBrokerProtocolDecodesPasswordAuthRequest() throws {
  let withoutHostID = try SSHBrokerEvent.decode(
    line: line(
      #"""
      {"type":"auth.request","id":"a1","endpoint":"deploy@10.0.0.5:22","kind":"password",
       "hostID":null,"keyFile":null,"keyDigest":null,
       "name":"","instruction":"","prompts":[{"text":"Password:","echo":false}],
       "attempt":1,"interactive":true}
      """#))
  guard case .authRequest(let request) = withoutHostID else {
    Issue.record("expected authRequest")
    return
  }
  #expect(request.id == "a1")
  #expect(request.endpoint == "deploy@10.0.0.5:22")
  #expect(request.kind == .password)
  #expect(request.hostID == nil)
  #expect(request.keyFile == nil)
  #expect(request.keyDigest == nil)
  #expect(request.prompts == [SSHAuthPrompt(text: "Password:", echo: false)])
  #expect(request.attempt == 1)
  #expect(request.interactive == true)

  let hostID = UUID()
  let withHostID = try SSHBrokerEvent.decode(
    line: line(
      #"""
      {"type":"auth.request","id":"a2","endpoint":"deploy@10.0.0.5:22","kind":"password",
       "hostID":"\#(hostID.uuidString)","keyFile":null,"keyDigest":null,
       "name":"","instruction":"","prompts":[{"text":"Password:","echo":false}],
       "attempt":2,"interactive":false}
      """#))
  guard case .authRequest(let request2) = withHostID else {
    Issue.record("expected authRequest")
    return
  }
  #expect(request2.hostID == hostID)
  #expect(request2.attempt == 2)
  #expect(request2.interactive == false)
}

/// 测：`auth.request`（passphrase），带 keyFile 与 keyDigest。
@Test func sshBrokerProtocolDecodesPassphraseAuthRequest() throws {
  let event = try SSHBrokerEvent.decode(
    line: line(
      #"""
      {"type":"auth.request","id":"p1","endpoint":"deploy@10.0.0.5:22","kind":"passphrase",
       "hostID":null,"keyFile":"/Users/me/.ssh/id_ed25519","keyDigest":"deadbeef",
       "name":"","instruction":"","prompts":[],
       "attempt":1,"interactive":true}
      """#))
  guard case .authRequest(let request) = event else {
    Issue.record("expected authRequest")
    return
  }
  #expect(request.kind == .passphrase)
  #expect(request.keyFile == "/Users/me/.ssh/id_ed25519")
  #expect(request.keyDigest == "deadbeef")
}

/// 测：`auth.request`（keyboardInteractive），多条 prompt。
@Test func sshBrokerProtocolDecodesKeyboardInteractiveAuthRequest() throws {
  let event = try SSHBrokerEvent.decode(
    line: line(
      #"""
      {"type":"auth.request","id":"k1","endpoint":"deploy@10.0.0.5:22","kind":"keyboardInteractive",
       "hostID":null,"keyFile":null,"keyDigest":null,
       "name":"otp","instruction":"Enter codes","prompts":[
         {"text":"Password:","echo":false},{"text":"OTP:","echo":true}],
       "attempt":1,"interactive":true}
      """#))
  guard case .authRequest(let request) = event else {
    Issue.record("expected authRequest")
    return
  }
  #expect(request.kind == .keyboardInteractive)
  #expect(request.name == "otp")
  #expect(request.instruction == "Enter codes")
  #expect(
    request.prompts == [
      SSHAuthPrompt(text: "Password:", echo: false), SSHAuthPrompt(text: "OTP:", echo: true),
    ])
}

/// 测：`auth.result`。
@Test func sshBrokerProtocolDecodesAuthResult() throws {
  let accepted = try SSHBrokerEvent.decode(line: line(#"{"type":"auth.result","id":"a1","accepted":true}"#))
  #expect(accepted == .authResult(id: "a1", accepted: true))
  let rejected = try SSHBrokerEvent.decode(line: line(#"{"type":"auth.result","id":"a1","accepted":false}"#))
  #expect(rejected == .authResult(id: "a1", accepted: false))
}

/// 测：`hostkey.confirm`，status 分别为 unknown 与 changed。
@Test func sshBrokerProtocolDecodesHostKeyConfirm() throws {
  let unknown = try SSHBrokerEvent.decode(
    line: line(
      #"""
      {"type":"hostkey.confirm","id":"h1","endpoint":"10.0.0.5:22","algorithm":"ssh-ed25519",
       "fingerprint":"SHA256:abc","status":"unknown","interactive":true}
      """#))
  guard case .hostKeyConfirm(let unknownRequest) = unknown else {
    Issue.record("expected hostKeyConfirm")
    return
  }
  #expect(unknownRequest.status == .unknown)
  #expect(unknownRequest.algorithm == "ssh-ed25519")
  #expect(unknownRequest.fingerprint == "SHA256:abc")

  let changed = try SSHBrokerEvent.decode(
    line: line(
      #"""
      {"type":"hostkey.confirm","id":"h2","endpoint":"10.0.0.5:22","algorithm":"ssh-ed25519",
       "fingerprint":"SHA256:def","status":"changed","interactive":false}
      """#))
  guard case .hostKeyConfirm(let changedRequest) = changed else {
    Issue.record("expected hostKeyConfirm")
    return
  }
  #expect(changedRequest.status == .changed)
  #expect(changedRequest.interactive == false)
}

/// 测：`link.state` 带 errorKind 的完整形态，以及省略全部可选字段的最简形态。
@Test func sshBrokerProtocolDecodesLinkStateWithAndWithoutOptionalFields() throws {
  let hostID = UUID()
  let full = try SSHBrokerEvent.decode(
    line: line(
      #"""
      {"type":"link.state","endpoint":"deploy@10.0.0.5:22","hostID":"\#(hostID.uuidString)",
       "target":"orb","state":"failed","attempt":2,"errorKind":"hostUnreachable",
       "detail":"connection refused"}
      """#))
  guard case .linkState(let fullEvent) = full else {
    Issue.record("expected linkState")
    return
  }
  #expect(fullEvent.hostID == hostID)
  #expect(fullEvent.target == "orb")
  #expect(fullEvent.state == .failed)
  #expect(fullEvent.attempt == 2)
  #expect(fullEvent.errorKind == .hostUnreachable)
  #expect(fullEvent.detail == "connection refused")

  let minimal = try SSHBrokerEvent.decode(
    line: line(
      #"""
      {"type":"link.state","endpoint":"deploy@10.0.0.5:22","hostID":null,
       "target":null,"state":"connecting"}
      """#))
  guard case .linkState(let minimalEvent) = minimal else {
    Issue.record("expected linkState")
    return
  }
  #expect(minimalEvent.hostID == nil)
  #expect(minimalEvent.target == nil)
  #expect(minimalEvent.state == .connecting)
  #expect(minimalEvent.attempt == nil)
  #expect(minimalEvent.errorKind == nil)
  #expect(minimalEvent.detail == nil)
}

/// 测：`log` 事件。
@Test func sshBrokerProtocolDecodesLogEvent() throws {
  let event = try SSHBrokerEvent.decode(line: line(#"{"type":"log","level":"info","message":"connected"}"#))
  #expect(event == .log(level: "info", message: "connected"))
}

/// 测：未知 `type` 解码成 `.unknown(type:)`，保证向前兼容。
@Test func sshBrokerProtocolDecodesUnknownTypeAsUnknownCase() throws {
  let event = try SSHBrokerEvent.decode(line: line(#"{"type":"future.feature","foo":1}"#))
  #expect(event == .unknown(type: "future.feature"))
}

/// 测：非法 JSON 抛错，不返回 `.unknown`。
@Test func sshBrokerProtocolDecodeThrowsOnInvalidJSON() {
  #expect(throws: (any Error).self) { try SSHBrokerEvent.decode(line: line("not json")) }
}

// MARK: - SSHBrokerCommand.encodedLine（§4.2 App → broker）

/// 从编码结果解析出字典，供结构化断言使用。
private func decodedObject(_ data: Data) throws -> [String: Any] {
  try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

/// 测：`profiles.sync` 编码成 `{"UUID":ResolvedSpec}` 的字典。
@Test func sshBrokerProtocolEncodesProfilesSync() throws {
  let id = UUID()
  let spec = SSHResolvedSpec(
    host: "10.0.0.5", port: 22, user: "deploy", auth: .auto, identityFiles: [],
    identitiesOnly: false, knownHostsFiles: [], agentForward: false, proxyCommand: nil, socksProxy: nil, httpProxy: nil, jump: nil,
    forwards: [], keepaliveInterval: 15, keepaliveCountMax: 3, connectTimeout: 10,
    verifyHostKeys: true)
  let data = try SSHBrokerCommand.profilesSync([id: spec]).encodedLine()
  let object = try decodedObject(data)

  #expect(object["type"] as? String == "profiles.sync")
  let profiles = try #require(object["profiles"] as? [String: Any])
  let encodedSpec = try #require(profiles[id.uuidString] as? [String: Any])
  #expect(encodedSpec["host"] as? String == "10.0.0.5")
  #expect(encodedSpec["port"] as? Int == 22)
  #expect(!String(decoding: data, as: UTF8.self).contains("\n"))
}

/// 测：`auth.answer` 取消（secret 为 nil）时，JSON 文本必须显式出现 `"secret":null` 与
/// `"responses":null`，而不是把字段省略掉——broker 用「显式 null」区分「取消」与「字段缺失」。
@Test func sshBrokerProtocolEncodesAuthAnswerCancelWithExplicitNulls() throws {
  let data = try SSHBrokerCommand.authAnswer(id: "a1", secret: nil, responses: nil).encodedLine()
  let text = String(decoding: data, as: UTF8.self)

  #expect(text.contains(#""secret":null"#))
  #expect(text.contains(#""responses":null"#))
  #expect(!text.contains("\n"))

  let object = try decodedObject(data)
  #expect(object["type"] as? String == "auth.answer")
  #expect(object["id"] as? String == "a1")
}

/// 测：`auth.answer` 带口令 secret 时正常编码；键盘交互用 `responses` 数组作答。
@Test func sshBrokerProtocolEncodesAuthAnswerWithSecretAndResponses() throws {
  let passwordData = try SSHBrokerCommand.authAnswer(
    id: "a1", secret: "hunter2", responses: nil).encodedLine()
  let passwordObject = try decodedObject(passwordData)
  #expect(passwordObject["secret"] as? String == "hunter2")
  #expect(passwordObject["responses"] is NSNull)

  let keyboardData = try SSHBrokerCommand.authAnswer(
    id: "k1", secret: nil, responses: ["one-time-code", "backup-code"]).encodedLine()
  let keyboardText = String(decoding: keyboardData, as: UTF8.self)
  #expect(keyboardText.contains(#""responses":["one-time-code","backup-code"]"#))
  let keyboardObject = try decodedObject(keyboardData)
  #expect(keyboardObject["responses"] as? [String] == ["one-time-code", "backup-code"])
  #expect(keyboardObject["secret"] is NSNull)
}

/// 测：`hostkey.answer` 编码。
@Test func sshBrokerProtocolEncodesHostKeyAnswer() throws {
  let accept = try decodedObject(try SSHBrokerCommand.hostKeyAnswer(id: "h1", accept: true).encodedLine())
  #expect(accept["type"] as? String == "hostkey.answer")
  #expect(accept["id"] as? String == "h1")
  #expect(accept["accept"] as? Bool == true)

  let reject = try decodedObject(try SSHBrokerCommand.hostKeyAnswer(id: "h1", accept: false).encodedLine())
  #expect(reject["accept"] as? Bool == false)
}

/// 测：`disconnect` 编码。
@Test func sshBrokerProtocolEncodesDisconnect() throws {
  let object = try decodedObject(
    try SSHBrokerCommand.disconnect(endpoint: "deploy@10.0.0.5:22").encodedLine())
  #expect(object["type"] as? String == "disconnect")
  #expect(object["endpoint"] as? String == "deploy@10.0.0.5:22")
}

/// 测：`shutdown` 编码。
@Test func sshBrokerProtocolEncodesShutdown() throws {
  let object = try decodedObject(try SSHBrokerCommand.shutdown.encodedLine())
  #expect(object["type"] as? String == "shutdown")
  #expect(object.count == 1)
}

// MARK: - NativeSSHErrorLine.parse

/// 测：从 stderr 里取最后一条结构化错误行，忽略前面的普通日志。
@Test func sshBrokerProtocolParsesLastStructuredErrorLine() {
  let stderr = """
    connecting to 10.0.0.5
    aster-ssh-error {"kind":"timeout","detail":"first"}
    retrying...
    aster-ssh-error {"kind":"hostUnreachable","detail":"second"}
    """
  let parsed = NativeSSHErrorLine.parse(standardError: stderr)
  #expect(parsed == NativeSSHErrorLine(kind: .hostUnreachable, detail: "second"))
}

/// 测：没有结构化行时返回 nil。
@Test func sshBrokerProtocolParseReturnsNilWithoutStructuredLine() {
  let stderr = "connection refused\nretrying...\n"
  #expect(NativeSSHErrorLine.parse(standardError: stderr) == nil)
}

/// 测：结构化前缀存在但 JSON 损坏时返回 nil（调用方回退到文本分类）。
@Test func sshBrokerProtocolParseReturnsNilOnMalformedJSON() {
  let stderr = #"aster-ssh-error {not valid json"#
  #expect(NativeSSHErrorLine.parse(standardError: stderr) == nil)
}

/// 测：`kind` 是未知取值时返回 nil。
@Test func sshBrokerProtocolParseReturnsNilOnUnknownKind() {
  let stderr = #"aster-ssh-error {"kind":"bogusKind","detail":"x"}"#
  #expect(NativeSSHErrorLine.parse(standardError: stderr) == nil)
}

// MARK: - NativeSSHClientInvocation.arguments()

private let testEndpoint = NativeSSHEndpoint(
  executablePath: "/usr/local/bin/aster-ssh", brokerSocketPath: "/tmp/broker.sock")

/// 测：目标是已保存主机（`--host-id`），默认参数下生成的 argv。
@Test func sshBrokerProtocolArgumentsForHostTargetWithDefaults() {
  let hostID = UUID()
  let invocation = NativeSSHClientInvocation(endpoint: testEndpoint, target: .host(hostID))
  #expect(
    invocation.arguments()
      == ["client", "--broker", "/tmp/broker.sock", "--host-id", hostID.uuidString, "--no-prompt"])
}

/// 测：目标是文本（`--target`），并组合 tty / 关闭 noPrompt / connectTimeout。
@Test func sshBrokerProtocolArgumentsForTextTargetWithOptions() {
  let invocation = NativeSSHClientInvocation(
    endpoint: testEndpoint, target: .text("deploy@10.0.0.5"), tty: true, noPrompt: false,
    connectTimeout: 5)
  #expect(
    invocation.arguments()
      == [
        "client", "--broker", "/tmp/broker.sock", "--target", "deploy@10.0.0.5", "--tty",
        "--connect-timeout", "5",
      ])
}

/// 测：`noPrompt` 默认值为 true。
@Test func sshBrokerProtocolNoPromptDefaultsToTrue() {
  let invocation = NativeSSHClientInvocation(endpoint: testEndpoint, target: .text("host"))
  #expect(invocation.arguments().contains("--no-prompt"))
}

/// 测：有远端命令时，argv 合成一段经单引号转义的字符串（含带单引号的参数）；
/// 没有远端命令时，argv 里不出现 `--`。
@Test func sshBrokerProtocolRemoteCommandIsShellQuotedIntoOneToken() {
  let withCommand = NativeSSHClientInvocation(
    endpoint: testEndpoint, target: .text("host"), remoteCommand: ["echo", "it's"])
  let argv = withCommand.arguments()
  #expect(argv.last == "'echo' 'it'\\''s'")
  #expect(argv.contains("--"))

  let withoutCommand = NativeSSHClientInvocation(endpoint: testEndpoint, target: .text("host"))
  #expect(!withoutCommand.arguments().contains("--"))
}
