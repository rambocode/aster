import Foundation
import Testing

@testable import AsterCore

/// P3.2 / P3.2a / A10：SSH 失败分类与脱敏、私有临时配置、SSH 传输的受管会话客户端。

// MARK: - 替身

/// 记录收到的 argv 并返回预置结果的 `RemoteSSHRunning` 替身。
///
/// 用 class + 锁而不是 actor：被测协议是同步的，测试里也只在单线程使用，
/// 锁只为满足 `Sendable` 要求。
private final class FakeSSHRunner: RemoteSSHRunning, @unchecked Sendable {
  private let lock = NSLock()
  private var invocations: [[String]] = []

  /// 预置的返回结果。
  var result: RemoteSSHResult

  init(result: RemoteSSHResult) { self.result = result }

  func run(arguments: [String], timeout: TimeInterval) throws -> RemoteSSHResult {
    lock.lock()
    invocations.append(arguments)
    lock.unlock()
    return result
  }

  var lastArguments: [String] {
    lock.lock()
    defer { lock.unlock() }
    return invocations.last ?? []
  }
}

private func envelopeText(_ object: [String: Any]) throws -> String {
  String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
}

// MARK: - 失败分类

@Test func remoteSSHDiagnosticsClassifiesKnownFailures() {
  #expect(
    RemoteSSHDiagnostics.classify(standardError: "Host key verification failed.", exitStatus: 255)
      == .hostKeyUnknown)
  #expect(
    RemoteSSHDiagnostics.classify(
      standardError: "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@", exitStatus: 255)
      == .hostKeyChanged)
  #expect(
    RemoteSSHDiagnostics.classify(standardError: "Permission denied (publickey).", exitStatus: 255)
      == .authenticationRequired)
  #expect(
    RemoteSSHDiagnostics.classify(
      standardError: "ssh: connect to host x port 22: Connection refused", exitStatus: 255)
      == .hostUnreachable)
  #expect(
    RemoteSSHDiagnostics.classify(
      standardError: "ssh: Could not resolve hostname nope: nodename nor servname provided",
      exitStatus: 255) == .hostUnreachable)
  #expect(
    RemoteSSHDiagnostics.classify(
      standardError: "ssh: connect to host x port 22: Operation timed out", exitStatus: 255)
      == .timeout)
  #expect(
    RemoteSSHDiagnostics.classify(
      standardError: "sh: aster-session: command not found", exitStatus: 127)
      == .remoteCommandMissing)
}

@Test func remoteSSHDiagnosticsPrefersHostKeyOverPermissionDenied() {
  // OpenSSH 主机密钥失败时常常同时打印 permission denied；顺序写反会把
  // “需要确认指纹”误报成“认证失败”，用户就会去查密钥而不是查 known_hosts。
  let stderr = """
    Permission denied (publickey).
    Host key verification failed.
    """
  #expect(RemoteSSHDiagnostics.classify(standardError: stderr, exitStatus: 255) == .hostKeyUnknown)

  let changed = """
    @@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@
    Permission denied (publickey).
    """
  #expect(RemoteSSHDiagnostics.classify(standardError: changed, exitStatus: 255) == .hostKeyChanged)
}

@Test func remoteSSHFailureKindMarksSetupRequiringCases() {
  #expect(RemoteSSHFailureKind.authenticationRequired.requiresExplicitSetup)
  #expect(RemoteSSHFailureKind.hostKeyUnknown.requiresExplicitSetup)
  #expect(RemoteSSHFailureKind.hostKeyChanged.requiresExplicitSetup)
  #expect(RemoteSSHFailureKind.remoteCommandMissing.requiresExplicitSetup)
  #expect(!RemoteSSHFailureKind.hostUnreachable.requiresExplicitSetup)
  #expect(!RemoteSSHFailureKind.timeout.requiresExplicitSetup)
  #expect(!RemoteSSHFailureKind.cancelled.requiresExplicitSetup)
  #expect(!RemoteSSHFailureKind.transportFailure.requiresExplicitSetup)
}

@Test func remoteSSHDiagnosticsRedactsPathsAndPrompts() {
  let stderr = """
    Enter passphrase for key '/Users/x/.ssh/id_ed25519':
    debug1: Offering public key: /Users/x/.ssh/id_ed25519 ED25519
    Permission denied (publickey).
    """
  let redacted = RemoteSSHDiagnostics.redact(stderr)
  #expect(!redacted.contains("/Users/x/.ssh/id_ed25519"))
  #expect(!redacted.lowercased().contains("passphrase"))
  #expect(!redacted.contains("id_ed25519"))
  #expect(redacted == "permission denied")
  #expect(RemoteSSHDiagnostics.redact("debug1: something totally unknown").isEmpty)
}

// MARK: - 私有临时 SSH 配置

@Test func remoteSSHConfigurationIncludesUserConfigBeforeHostBlock() {
  let text = RemoteSSHConfigurationManager.configurationText(
    userConfigurationPath: "/Users/x/.ssh/config",
    controlPath: "/tmp/aster-ssh-abc/c-%C",
    policy: RemoteSSHPolicy())
  let include = text.range(of: "Include /Users/x/.ssh/config")
  let hostBlock = text.range(of: "Host *")
  let includeRange = include
  #expect(includeRange != nil)
  #expect(hostBlock != nil)
  if let includeRange, let hostBlock {
    // OpenSSH 对同一关键字取首次出现的值，用户配置必须排在补充值之前。
    #expect(includeRange.lowerBound < hostBlock.lowerBound)
  }
  #expect(text.contains("ServerAliveInterval 15"))
  #expect(text.contains("ControlMaster auto"))
  #expect(text.contains("ControlPath /tmp/aster-ssh-abc/c-%C"))
  #expect(text.contains("ControlPersist"))
}

@Test func remoteSSHConfigurationOmitsIncludeWithoutUserConfig() {
  let text = RemoteSSHConfigurationManager.configurationText(
    userConfigurationPath: nil, controlPath: "/tmp/aster-ssh-abc/c-%C", policy: RemoteSSHPolicy())
  #expect(!text.contains("Include"))
  #expect(text.contains("Host *"))
}

@Test func remoteSSHPrivateConfigurationUsesRestrictivePermissions() throws {
  let fileManager = FileManager.default
  // 传空串而不是 nil：nil 会去读真实用户 ~/.ssh/config，让用例依赖运行环境。
  let configuration = try RemoteSSHConfigurationManager.makePrivateConfiguration(
    userConfigurationPath: "", policy: RemoteSSHPolicy(), fileManager: fileManager)
  defer { try? fileManager.removeItem(atPath: configuration.directoryPath) }

  let directoryAttributes = try fileManager.attributesOfItem(
    atPath: configuration.directoryPath)
  let fileAttributes = try fileManager.attributesOfItem(atPath: configuration.configurationPath)
  #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.int16Value == 0o700)
  #expect((fileAttributes[.posixPermissions] as? NSNumber)?.int16Value == 0o600)

  // `%C` 由 OpenSSH 展开成连接哈希；按最长 64 字符估算仍必须短于 sockaddr_un 的 104。
  let expanded = configuration.controlPath.replacingOccurrences(
    of: "%C", with: String(repeating: "a", count: 64))
  #expect(configuration.controlPath.utf8.count < 104)
  #expect(expanded.utf8.count < 104)
}

// MARK: - 策略开关

@Test func remoteSSHPolicyReadsManageConfigSwitchFromEnvironment() {
  #expect(RemoteSSHPolicy.fromEnvironment([:]).manageSSHConfig)
  #expect(
    RemoteSSHPolicy.fromEnvironment([RemoteSSHPolicy.manageSSHConfigEnvironmentKey: "1"])
      .manageSSHConfig)
  for value in ["0", "false", "FALSE", "no", "No"] {
    #expect(
      !RemoteSSHPolicy.fromEnvironment([RemoteSSHPolicy.manageSSHConfigEnvironmentKey: value])
        .manageSSHConfig, "值 \(value) 未关闭 SSH 配置管理")
  }
}

// MARK: - SSH 传输的受管会话客户端

private func sampleEndpoint() -> ManagedSessionEndpoint {
  ManagedSessionEndpoint(
    binaryPath: "/usr/local/bin/aster-session",
    stateParentPath: "/root/.local/state/aster-test",
    sessionName: "p3")
}

private func sampleClient(_ runner: FakeSSHRunner) throws -> RemoteManagedSessionClient {
  RemoteManagedSessionClient(
    transport: RemoteSessionTransport(target: try RemoteSSHTarget.parse("root@ubuntu@orb")),
    runner: runner)
}

@Test func remoteManagedSessionClientDecodesServerStatusOverSSH() throws {
  let stdout = try envelopeText([
    "type": "response", "operation": "server.status",
    "target": [
      "serverID": "bc2d4ef4-ca4e-435e-ab6d-409a79805fc8",
      "serverEpoch": "48922fa9-96c1-47ae-b68e-884fcc7bd272",
      "sessionID": "83dfae3a-991d-4f16-8e69-ddaca142b563",
    ],
    "result": [
      "version": "0.1.0-dev",
      "capabilities": ["terminal_control", "surface_interest", "health_check"],
    ],
  ])
  let runner = FakeSSHRunner(
    result: RemoteSSHResult(exitStatus: 0, standardOutput: stdout, standardError: ""))
  let identity = try sampleClient(runner).serverStatus(sampleEndpoint())

  #expect(identity.reference.serverID == "bc2d4ef4-ca4e-435e-ab6d-409a79805fc8")
  #expect(identity.serverEpoch == "48922fa9-96c1-47ae-b68e-884fcc7bd272")
  #expect(identity.reference.sessionID == "83dfae3a-991d-4f16-8e69-ddaca142b563")
  #expect(identity.capabilities == ["terminal_control", "surface_interest", "health_check"])
}

@Test func remoteManagedSessionClientSendsRemoteCommandAsOneQuotedArgument() throws {
  let stdout = try envelopeText([
    "type": "response",
    "target": ["serverID": "s", "serverEpoch": "e", "sessionID": "n"],
    "result": ["capabilities": ["health_check"]],
  ])
  let runner = FakeSSHRunner(
    result: RemoteSSHResult(exitStatus: 0, standardOutput: stdout, standardError: ""))
  _ = try sampleClient(runner).serverStatus(sampleEndpoint())

  let argv = runner.lastArguments
  let remote = try #require(argv.last)
  #expect(argv[argv.count - 3] == "--")
  #expect(argv[argv.count - 2] == "root@ubuntu@orb")
  #expect(remote.contains("'server' 'status'"))
  // 远端命令只能是一个元素；分开传会被登录 Shell 重新分词。
  #expect(argv.filter { $0.contains("aster-session") }.count == 1)
}

@Test func remoteManagedSessionClientMapsAuthenticationFailureWithoutLeakingCredentials() throws {
  let runner = FakeSSHRunner(
    result: RemoteSSHResult(
      exitStatus: 255,
      standardOutput: "",
      standardError: """
        Enter passphrase for key '/Users/x/.ssh/id_ed25519':
        Permission denied (publickey).
        """))
  do {
    _ = try sampleClient(runner).serverStatus(sampleEndpoint())
    Issue.record("认证失败必须抛错")
  } catch let error as ManagedSessionError {
    guard case .runtimeUnavailable(let message) = error else {
      Issue.record("期望 runtimeUnavailable，实际 \(error)")
      return
    }
    #expect(message.contains("authenticationRequired"))
    #expect(message.contains("root@ubuntu@orb"))
    #expect(!message.contains("id_ed25519"))
    #expect(!message.lowercased().contains("passphrase"))
    #expect(!message.contains("publickey"))
  }
}

@Test func remoteManagedSessionClientBridgeRunsSSHWithForcedTTY() throws {
  let runner = FakeSSHRunner(result: RemoteSSHResult(exitStatus: 0, standardOutput: "", standardError: ""))
  let client = try sampleClient(runner)
  let endpoint = sampleEndpoint()
  #expect(client.bridgeExecutablePath(endpoint) == "/usr/bin/ssh")

  let argv = client.bridgeArguments(endpoint, terminalID: "t1", readOnly: false)
  #expect(argv.first == "-tt")
  #expect(argv.contains("--"))
  let attachCommand = try #require(argv.last)
  #expect(attachCommand.contains("'terminal' 'attach'"))

  let observe = client.bridgeArguments(endpoint, terminalID: "t1", readOnly: true)
  let observeCommand = try #require(observe.last)
  #expect(observeCommand.contains("'terminal' 'observe'"))
}
