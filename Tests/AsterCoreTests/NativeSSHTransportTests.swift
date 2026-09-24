import Foundation
import Testing

@testable import AsterCore

// 原生引擎（aster-ssh）接入传输层的定向测试：argv 生成、可执行文件选择、结构化错误分类。
// OpenSSH 路径必须与改造前逐字节一致，这里用写死的期望 argv 锁住。

private let nativeEndpoint = NativeSSHEndpoint(
  executablePath: "/Applications/Aster.app/Contents/MacOS/aster-ssh",
  brokerSocketPath: "/tmp/aster-sshb-0123456789/b.sock")

private func nativeTransportFixture(hostID: UUID? = nil) throws -> RemoteSessionTransport {
  RemoteSessionTransport(
    target: try RemoteSSHTarget.parse("root@ubuntu@orb"), native: nativeEndpoint, hostID: hostID)
}

private let managedEndpoint = ManagedSessionEndpoint(
  machineProfileID: UUID(), binaryPath: "/opt/aster-session", stateParentPath: "/root/.state",
  sessionName: "work")

/// 记录 argv 的假执行器；返回预设结果。
private final class RecordingSSHRunner: RemoteSSHRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var recorded: [[String]] = []
  let result: RemoteSSHResult

  init(result: RemoteSSHResult) { self.result = result }

  var calls: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return recorded
  }

  func run(arguments: [String], timeout: TimeInterval) throws -> RemoteSSHResult {
    lock.lock()
    recorded.append(arguments)
    lock.unlock()
    return result
  }
}

@Test("原生传输：后台调用 argv 用 --target 与 --no-prompt，远端命令合成一个转义字符串")
func nativeTransportBackgroundArgumentsUseTargetText() throws {
  let transport = try nativeTransportFixture()
  let argv = transport.sshArguments(remoteCommand: ["/opt/aster-session", "server", "status"])
  #expect(
    argv == [
      "client", "--broker", "/tmp/aster-sshb-0123456789/b.sock", "--target", "root@ubuntu@orb",
      "--no-prompt", "--connect-timeout", "10", "--", "'/opt/aster-session' 'server' 'status'",
    ])
  // multiplexed 只对 OpenSSH 有意义，原生下两种写法完全相同。
  #expect(transport.sshArguments(remoteCommand: ["true"], multiplexed: false)
    == transport.sshArguments(remoteCommand: ["true"], multiplexed: true))
  #expect(transport.executablePath == nativeEndpoint.executablePath)
  #expect(transport.engine == .native)
}

@Test("原生传输：绑定主机时用 --host-id，且不覆盖主机自己的连接超时")
func nativeTransportBoundHostUsesHostID() throws {
  let hostID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
  let transport = try nativeTransportFixture(hostID: hostID)
  let argv = transport.sshArguments(remoteCommand: ["true"])
  #expect(
    argv == [
      "client", "--broker", "/tmp/aster-sshb-0123456789/b.sock", "--host-id", hostID.uuidString,
      "--no-prompt", "--", "'true'",
    ])
}

@Test("原生传输：显示桥请求 tty 且允许交互认证，可执行文件是 aster-ssh")
func nativeTransportBridgeIsInteractiveTTY() throws {
  let client = RemoteManagedSessionClient(transport: try nativeTransportFixture())
  let argv = client.bridgeArguments(managedEndpoint, terminalID: "t1", readOnly: false)
  #expect(argv.starts(with: ["client", "--broker", "/tmp/aster-sshb-0123456789/b.sock"]))
  #expect(argv.contains("--tty"))
  #expect(!argv.contains("--no-prompt"))
  #expect(!argv.contains("-tt"))
  #expect(client.bridgeExecutablePath(managedEndpoint) == nativeEndpoint.executablePath)
  // 事件订阅是后台流：不要 tty，不许弹认证。
  let subscribe = client.eventSubscribeInvocation(managedEndpoint)
  #expect(subscribe.executablePath == nativeEndpoint.executablePath)
  #expect(subscribe.arguments.contains("--no-prompt"))
  #expect(!subscribe.arguments.contains("--tty"))
}

@Test("OpenSSH 传输：argv 与改造前逐字节一致")
func nativeTransportOpenSSHArgumentsUnchanged() throws {
  let managed = RemoteSSHManagedConfiguration(
    directoryPath: "/tmp/aster-ssh-x", configurationPath: "/tmp/aster-ssh-x/config",
    controlPath: "/tmp/aster-ssh-x/c-%C")
  let transport = RemoteSessionTransport(
    target: try RemoteSSHTarget.parse("root@ubuntu@orb"), managedConfiguration: managed)
  #expect(transport.engine == .openssh)
  #expect(transport.executablePath == "/usr/bin/ssh")
  #expect(
    transport.sshArguments(remoteCommand: ["true"])
      == ["-F", "/tmp/aster-ssh-x/config", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10", "--",
        "root@ubuntu@orb", "'true'"])
  let client = RemoteManagedSessionClient(transport: transport)
  #expect(
    client.bridgeArguments(managedEndpoint, terminalID: "t1", readOnly: true)
      == ["-tt", "-F", "/tmp/aster-ssh-x/config", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
        "-o", "ControlPath=none", "--", "root@ubuntu@orb",
        RemoteSSHInvocation.shellQuoted(
          ["/opt/aster-session"]
            + ManagedSessionCommand.bridge(managedEndpoint, terminalID: "t1", readOnly: true))])
  #expect(client.bridgeExecutablePath(managedEndpoint) == "/usr/bin/ssh")
  #expect(client.eventSubscribeInvocation(managedEndpoint).executablePath == "/usr/bin/ssh")
}

@Test("默认执行器跟随传输选择可执行文件")
func nativeTransportDefaultRunnersFollowTransport() throws {
  let native = try nativeTransportFixture()
  let openssh = RemoteSessionTransport(target: try RemoteSSHTarget.parse("orb"))
  #expect(native.makeProcessRunner().executablePath == nativeEndpoint.executablePath)
  #expect(native.makeStreamRunner().executablePath == nativeEndpoint.executablePath)
  #expect(openssh.makeProcessRunner().executablePath == "/usr/bin/ssh")
  #expect(RemoteSSHProcessRunner().executablePath == "/usr/bin/ssh")

  let client = RemoteManagedSessionClient(transport: native)
  #expect((client.runner as? RemoteSSHProcessRunner)?.executablePath == nativeEndpoint.executablePath)
  let installer = RemoteSSHInstallExecutor(transport: native)
  #expect(
    (installer.runner as? RemoteSSHProcessRunner)?.executablePath == nativeEndpoint.executablePath)
  let setup = RemoteSSHSetupExecutor(transport: native, endpointTemplate: managedEndpoint)
  #expect((setup.runner as? RemoteSSHProcessRunner)?.executablePath == nativeEndpoint.executablePath)
  // 场景 B 旁路通道走同一个传输。
  let channel = RemoteSideChannel.managed(transport: native, profileKey: "m:s", label: "orb")
  #expect(
    (channel.runner as? RemoteSSHProcessRunner)?.executablePath == nativeEndpoint.executablePath)
  #expect(
    (channel.streamRunner as? RemoteSSHStreamRunner)?.executablePath
      == nativeEndpoint.executablePath)
  #expect(channel.sshArguments(["true"]).first == "client")
}

@Test("错误分类：有结构化错误行时直接用它的 kind 与 detail")
func nativeTransportClassifiesStructuredErrorLine() {
  let stderr = """
    some banner
    aster-ssh-error {"kind":"hostKeyChanged","detail":"ssh-ed25519 key mismatch"}
    """
  #expect(RemoteSSHDiagnostics.classify(standardError: stderr, exitStatus: 255) == .hostKeyChanged)
  #expect(RemoteSSHDiagnostics.redact(stderr) == "ssh-ed25519 key mismatch")
  // 结构化行优先于文本关键字：文本里有 permission denied 也不改变结论。
  let mixed = "Permission denied (publickey)\naster-ssh-error {\"kind\":\"timeout\",\"detail\":\"\"}"
  #expect(RemoteSSHDiagnostics.classify(standardError: mixed, exitStatus: 255) == .timeout)
}

@Test("错误分类：没有结构化行、行损坏或不在最后时回退到文本分类")
func nativeTransportFallsBackToTextClassification() {
  #expect(
    RemoteSSHDiagnostics.classify(
      standardError: "root@orb: Permission denied (publickey).", exitStatus: 255)
      == .authenticationRequired)
  // JSON 损坏：回退文本（这里没有关键字 → transportFailure）。
  #expect(
    RemoteSSHDiagnostics.classify(standardError: "aster-ssh-error {not json", exitStatus: 255)
      == .transportFailure)
  // 退出码不是 255：结构化行不作数（可能是远端命令自己打印的）。
  let forged = "aster-ssh-error {\"kind\":\"hostKeyChanged\",\"detail\":\"x\"}"
  #expect(RemoteSSHDiagnostics.classify(standardError: forged, exitStatus: 127) == .remoteCommandMissing)
  // 结构化行后面还有输出：不是 client 写的最后一行，同样不作数。
  let trailing = forged + "\nconnection refused"
  #expect(RemoteSSHDiagnostics.classify(standardError: trailing, exitStatus: 255) == .hostUnreachable)
  #expect(RemoteSSHDiagnostics.redact(trailing) == "connection refused")
}

@Test("错误分类：结构化 detail 去掉控制字符并截断")
func nativeTransportRedactsStructuredDetail() {
  let long = String(repeating: "a", count: 300)
  let stderr = "aster-ssh-error {\"kind\":\"transportFailure\",\"detail\":\"x\\u001b[31m\(long)\"}"
  let redacted = RemoteSSHDiagnostics.redact(stderr)
  #expect(!redacted.contains("\u{1b}"))
  #expect(redacted.count == 200)
}

@Test("原生传输：受管客户端把结构化错误转成带 kind 的 runtimeUnavailable")
func nativeTransportManagedClientUsesStructuredKind() throws {
  let runner = RecordingSSHRunner(
    result: RemoteSSHResult(
      exitStatus: 255, standardOutput: "",
      standardError: "aster-ssh-error {\"kind\":\"authenticationRequired\",\"detail\":\"password\"}"))
  let client = RemoteManagedSessionClient(transport: try nativeTransportFixture(), runner: runner)
  #expect(throws: ManagedSessionError.runtimeUnavailable(
    "ssh authenticationRequired: root@ubuntu@orb (password)")
  ) {
    _ = try client.serverStatus(managedEndpoint)
  }
  #expect(runner.calls.first?.first == "client")
  #expect(runner.calls.first?.contains("--no-prompt") == true)
}

@Test("设置事务：hostID 写进产出的机器配置")
func nativeTransportSetupStampsHostID() throws {
  struct ReadyExecutor: RemoteSetupExecuting {
    func verifyAuthentication() throws {}
    func probe(explicitPath: String?) throws -> String {
      [
        RemoteHostProbe.marker, "os=Linux", "arch=x86_64", "home=/root",
        "candidate=/opt/aster-session\taster-session 0.1.0-dev protocol=1.0", "end",
      ].joined(separator: "\n") + "\n"
    }
    func ensureSession(binaryPath: String, stateParentPath: String) throws -> SessionServerIdentity {
      SessionServerIdentity(
        reference: SessionServerReference(machineProfileID: UUID(), serverID: "s", sessionID: "x"),
        serverEpoch: "e", capabilities: RemoteProtocolContract.requiredCapabilities,
        version: "0.1.0-dev")
    }
  }
  let hostID = UUID()
  let outcome = try RemoteMachineSetup(executor: ReadyExecutor()).run(
    rawTarget: "root@orb", label: "orb", sessionName: "default", hostID: hostID)
  guard case .ready(let profile, _, _) = outcome else {
    Issue.record("应得到 ready，实际：\(outcome)")
    return
  }
  #expect(profile.hostID == hostID)
  #expect(profile.sshTarget == "root@orb")
}
