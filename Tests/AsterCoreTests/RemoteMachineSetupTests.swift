import Foundation
import Testing

@testable import AsterCore

/// P3.3/P3.5/P3.6/P3.7（A10/A11/A12）：远端探测解析、兼容性判定、设置事务顺序与远端 Pane 边界。

// MARK: - 替身

/// 记录每一步是否被调用并可注入失败的 `RemoteSetupExecuting` 替身。
///
/// 用 class + 锁而不是 actor：被测协议是同步的，测试里也只在单线程使用，
/// 锁只为满足 `Sendable` 要求。“是否被调用”是本组用例的核心断言——
/// 例如非法 target 必须在**建立连接之前**就失败，认证步骤不能被触发。
private final class FakeSetupExecutor: RemoteSetupExecuting, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var authenticationCalls = 0
  private(set) var probeCalls = 0
  private(set) var ensureSessionCalls = 0
  private(set) var ensureSessionBinaryPaths: [String] = []

  /// 认证步骤抛出的错误；nil 表示成功。
  var authenticationError: RemoteSSHError?
  /// 探测步骤返回的 stdout。
  var probeOutput: String = ""
  /// 探测步骤抛出的错误；nil 表示成功。
  var probeError: RemoteSSHError?
  /// 会话准备返回的服务身份。
  var identity: SessionServerIdentity = FakeSetupExecutor.makeIdentity()
  /// 会话准备抛出的错误；nil 表示成功。
  var ensureSessionError: Error?

  static func makeIdentity(
    capabilities: [String] = ["terminal_control", "surface_interest", "health_check"]
  ) -> SessionServerIdentity {
    SessionServerIdentity(
      reference: SessionServerReference(
        machineProfileID: MachineProfile.localProfileID,
        serverID: "bc2d4ef4-ca4e-435e-ab6d-409a79805fc8",
        sessionID: "83dfae3a-991d-4f16-8e69-ddaca142b563"),
      serverEpoch: "48922fa9-96c1-47ae-b68e-884fcc7bd272",
      capabilities: capabilities,
      version: "0.1.0-dev")
  }

  func verifyAuthentication() throws {
    lock.lock()
    authenticationCalls += 1
    lock.unlock()
    if let authenticationError { throw authenticationError }
  }

  func probe(explicitPath: String?) throws -> String {
    lock.lock()
    probeCalls += 1
    lock.unlock()
    if let probeError { throw probeError }
    return probeOutput
  }

  private(set) var ensureSessionStateParentPaths: [String] = []

  func ensureSession(binaryPath: String, stateParentPath: String) throws -> SessionServerIdentity {
    lock.lock()
    ensureSessionCalls += 1
    ensureSessionBinaryPaths.append(binaryPath)
    ensureSessionStateParentPaths.append(stateParentPath)
    lock.unlock()
    if let ensureSessionError { throw ensureSessionError }
    return identity
  }
}

/// 构造一段带 marker 的探测输出。`candidates` 是 `(路径, 版本行)` 对。
private func probeOutput(
  os: String = "Linux",
  arch: String = "aarch64",
  home: String = "/root",
  candidates: [(String, String)]
) -> String {
  var lines = [RemoteHostProbe.marker, "os=\(os)", "arch=\(arch)", "home=\(home)"]
  for (path, version) in candidates { lines.append("candidate=\(path)\t\(version)") }
  lines.append("end")
  return lines.joined(separator: "\n") + "\n"
}

private let compatibleVersionLine = "aster-session 0.1.0-dev protocol=1.0"

// MARK: - 版本行解析

@Test func remoteHostProbeParsesVersionLine() {
  let parsed = RemoteHostProbe.parseVersionLine("aster-session 0.1.0-dev protocol=1.0")
  #expect(parsed.release == "0.1.0-dev")
  #expect(parsed.major == 1)
  #expect(parsed.minor == 0)
}

@Test func remoteHostProbeRejectsGarbageVersionLine() {
  for text in ["", "not-aster 1.2.3", "aster-session", "bash: aster-session: not found"] {
    let parsed = RemoteHostProbe.parseVersionLine(text)
    #expect(parsed.release == nil, "垃圾输入 \(text.debugDescription) 被当成版本")
    #expect(parsed.major == nil)
    #expect(parsed.minor == nil)
  }
}

// MARK: - 探测输出解析

@Test func remoteHostProbeParsesPlatformAndCandidates() throws {
  let output = probeOutput(
    os: "Linux",
    arch: "aarch64",
    home: "/root",
    candidates: [
      ("/opt/dev/aster-session", compatibleVersionLine),
      ("/usr/bin/aster-session", compatibleVersionLine),
      ("/root/.local/share/aster/bin/aster-session", compatibleVersionLine),
      ("/usr/local/bin/aster-session", compatibleVersionLine),
      // 同一路径重复出现（PATH 与显式覆盖指向同一个文件）必须去重。
      ("/usr/bin/aster-session", compatibleVersionLine),
    ])
  let report = try #require(
    RemoteHostProbe.parse(output, explicitPath: "/opt/dev/aster-session"))

  #expect(report.platform.os == "linux")
  #expect(report.platform.architecture == "arm64")
  #expect(report.platform.homeDirectory == "/root")

  #expect(
    report.candidates.map(\.path) == [
      "/opt/dev/aster-session",
      "/usr/bin/aster-session",
      "/root/.local/share/aster/bin/aster-session",
      "/usr/local/bin/aster-session",
    ])
  #expect(
    report.candidates.map(\.source) == [
      .explicitOverride, .path, .asterPrivateInstall, .packageManager,
    ])
  #expect(report.candidates.allSatisfy { $0.protocolMajor == 1 && $0.protocolMinor == 0 })
  #expect(report.candidates.allSatisfy { $0.releaseVersion == "0.1.0-dev" })
}

@Test func remoteHostProbeNormalizesKnownPlatformAliases() {
  #expect(RemotePlatform.normalizeOS("Linux") == "linux")
  #expect(RemotePlatform.normalizeOS("Darwin") == "macos")
  #expect(RemotePlatform.normalizeOS("FreeBSD") == "freebsd")
  #expect(RemotePlatform.normalizeArchitecture("aarch64") == "arm64")
  #expect(RemotePlatform.normalizeArchitecture("amd64") == "x86_64")
  #expect(RemotePlatform.normalizeArchitecture("x86_64") == "x86_64")
}

@Test func remoteHostProbeRejectsOutputWithoutMarker() {
  let output = """
    os=Linux
    arch=x86_64
    home=/root
    candidate=/usr/bin/aster-session\t\(compatibleVersionLine)
    """
  // 没有 marker 说明这不是探测脚本的输出，绝不能当成探测结果使用。
  #expect(RemoteHostProbe.parse(output, explicitPath: nil) == nil)
  #expect(RemoteHostProbe.parse("", explicitPath: nil) == nil)
}

// MARK: - 兼容性判定

@Test func remoteCompatibilityRejectsDifferentMajorBeforeCheckingCapabilities() {
  // 主版本不同就不该继续看能力：能力名在不同主版本之间没有可比性。
  let result = RemoteCompatibilityCheck.evaluate(
    protocolMajor: 2,
    capabilities: RemoteProtocolContract.requiredCapabilities
      + RemoteProtocolContract.optionalCapabilities)
  #expect(result == .incompatibleMajor(remote: 2, client: 1))
  #expect(!result.allowsBackgroundConnect)
}

@Test func remoteCompatibilityReportsMissingRequiredCapability() {
  let result = RemoteCompatibilityCheck.evaluate(
    protocolMajor: 1, capabilities: ["surface_interest", "health_check"])
  #expect(result == .missingRequiredCapability(["terminal_control"]))
  #expect(!result.allowsBackgroundConnect)
}

@Test func remoteCompatibilityAllowsConnectWithMissingOptionalCapabilities() {
  let capabilities = RemoteProtocolContract.requiredCapabilities + [
    "server_lifecycle", "terminal_observe", "session_snapshot", "workspace_mutation",
    "session_restore",
  ]
  let result = RemoteCompatibilityCheck.evaluate(protocolMajor: 1, capabilities: capabilities)
  guard case .compatible(let missingOptional) = result else {
    Issue.record("期望 compatible，实际 \(result)")
    return
  }
  #expect(missingOptional.sorted() == ["image_upload", "live_handoff"])
  #expect(result.allowsBackgroundConnect)
}

@Test func remoteCompatibilityKeepsUnknownWhenProtocolMissing() {
  let result = RemoteCompatibilityCheck.evaluate(
    protocolMajor: nil, capabilities: RemoteProtocolContract.requiredCapabilities)
  guard case .unknown = result else {
    Issue.record("期望 unknown，实际 \(result)")
    return
  }
  #expect(!result.allowsBackgroundConnect)
}

@Test func remoteCompatibilityDescribesDisabledActions() {
  #expect(RemoteCompatibilityCheck.unavailableActionMessage(missingOptional: []) == nil)
  let message = try? #require(
    RemoteCompatibilityCheck.unavailableActionMessage(missingOptional: ["live_handoff", "image_upload"]))
  #expect(message?.contains("实时交接") == true)
  #expect(message?.contains("图片上传") == true)
}

/// 可选能力名必须是服务端真实广播的字面量：最新服务的完整能力集合下不能再报"缺少可选能力"。
@Test func remoteCompatibilityReportsNothingMissingForCurrentServer() {
  // 与 SessionRuntime/src/service_server.zig 的 advertised_capabilities 同步。
  let advertised = [
    "health_check", "server_lifecycle", "terminal_control", "terminal_observe", "surface_interest",
    "session_snapshot", "workspace_mutation", "agent_state", "session_restore", "session_settings",
    "image_upload", "server_config", "custom_commands", "server_replace", "live_handoff",
  ]
  let result = RemoteCompatibilityCheck.evaluate(protocolMajor: 1, capabilities: advertised)
  #expect(result == .compatible(missingOptional: []))
  #expect(RemoteCompatibilityCheck.unavailableActionMessage(missingOptional: []) == nil)
}

// MARK: - 设置事务

@Test func remoteMachineSetupRejectsIllegalTargetBeforeConnecting() {
  for raw in ["-x", "host;rm -rf /", "", "host name"] {
    let executor = FakeSetupExecutor()
    let setup = RemoteMachineSetup(executor: executor)
    do {
      _ = try setup.run(rawTarget: raw, label: "orb", sessionName: "p3")
      Issue.record("非法 target \(raw.debugDescription) 未被拒绝")
    } catch let failure as RemoteSetupFailure {
      #expect(failure.stage == .targetValidation)
      #expect(failure.requiresExplicitSetup)
      // 连接前拒绝：认证步骤根本不该被触发。
      #expect(executor.authenticationCalls == 0)
      #expect(executor.probeCalls == 0)
    } catch {
      Issue.record("期望 RemoteSetupFailure，实际 \(error)")
    }
  }
}

@Test func remoteMachineSetupStopsAtAuthenticationFailure() {
  let executor = FakeSetupExecutor()
  executor.authenticationError = RemoteSSHError(
    kind: .authenticationRequired,
    target: "root@ubuntu@orb",
    detail: "permission denied",
    exitStatus: 255)
  let setup = RemoteMachineSetup(executor: executor)
  do {
    _ = try setup.run(rawTarget: "root@ubuntu@orb", label: "orb", sessionName: "p3")
    Issue.record("认证失败必须抛错")
  } catch let failure as RemoteSetupFailure {
    #expect(failure.stage == .authentication)
    #expect(failure.requiresExplicitSetup)
    #expect(failure.sshKind == .authenticationRequired)
    #expect(failure.message.contains("root@ubuntu@orb"))
    #expect(!failure.message.contains("publickey"))
    #expect(!failure.message.lowercased().contains("passphrase"))
    // 认证没过就不该继续探测远端。
    #expect(executor.probeCalls == 0)
  } catch {
    Issue.record("期望 RemoteSetupFailure，实际 \(error)")
  }
}

@Test func remoteMachineSetupRequiresInstallationWhenNoCandidateExists() throws {
  let executor = FakeSetupExecutor()
  executor.probeOutput = probeOutput(candidates: [])
  let setup = RemoteMachineSetup(executor: executor)
  let outcome = try setup.run(rawTarget: "root@ubuntu@orb", label: "orb", sessionName: "p3")

  guard case .installationRequired(let report, let reason) = outcome else {
    Issue.record("期望 installationRequired，实际 \(outcome)")
    return
  }
  #expect(report.candidates.isEmpty)
  #expect(reason.contains("需要显式安装"))
  // 没有可用二进制时不谈会话准备，更不产出机器配置。
  #expect(executor.ensureSessionCalls == 0)
}

@Test func remoteMachineSetupDoesNotStopIncompatibleRunningServer() throws {
  let executor = FakeSetupExecutor()
  executor.probeOutput = probeOutput(
    candidates: [("/usr/local/bin/aster-session", "aster-session 0.9.0 protocol=2.0")])
  let setup = RemoteMachineSetup(executor: executor)
  let outcome = try setup.run(rawTarget: "root@ubuntu@orb", label: "orb", sessionName: "p3")

  guard case .incompatibleServerRunning(_, let reason) = outcome else {
    Issue.record("期望 incompatibleServerRunning，实际 \(outcome)")
    return
  }
  #expect(reason.contains("不会停止它"))
  #expect(executor.ensureSessionCalls == 0)
}

@Test func remoteMachineSetupLeavesNoProfileWhenSessionPreparationFails() {
  let executor = FakeSetupExecutor()
  executor.probeOutput = probeOutput(
    candidates: [("/usr/local/bin/aster-session", compatibleVersionLine)])
  executor.ensureSessionError = ManagedSessionError.runtimeUnavailable("ssh cancelled: orb")
  let setup = RemoteMachineSetup(executor: executor)
  do {
    let outcome = try setup.run(rawTarget: "root@ubuntu@orb", label: "orb", sessionName: "p3")
    Issue.record("会话准备失败必须抛错，实际 \(outcome)")
  } catch let failure as RemoteSetupFailure {
    // P3.6 核心：取消或失败都不产出 MachineProfile，调用方无从保存。
    #expect(failure.stage == .sessionPreparation)
    #expect(failure.message.contains("p3"))
  } catch {
    Issue.record("期望 RemoteSetupFailure，实际 \(error)")
  }
}

@Test func remoteMachineSetupProducesProfileOnlyAfterFullSuccess() throws {
  let executor = FakeSetupExecutor()
  executor.probeOutput = probeOutput(
    candidates: [("/usr/local/bin/aster-session", compatibleVersionLine)])
  executor.identity = FakeSetupExecutor.makeIdentity(
    capabilities: RemoteProtocolContract.requiredCapabilities + ["terminal_observe"])
  let setup = RemoteMachineSetup(executor: executor)
  let outcome = try setup.run(rawTarget: "root@ubuntu@orb", label: "OrbStack", sessionName: "p3")

  guard case .ready(let profile, let identity, let report) = outcome else {
    Issue.record("期望 ready，实际 \(outcome)")
    return
  }
  // 保存的是 target 原文，不是拆解后的 user/host 重新拼装。
  #expect(profile.sshTarget == "root@ubuntu@orb")
  #expect(profile.label == "OrbStack")
  #expect(profile.sessionName == "p3")
  #expect(profile.enabled)
  #expect(identity.serverEpoch == "48922fa9-96c1-47ae-b68e-884fcc7bd272")
  #expect(report.runningServer != nil)
  #expect(report.runningCompatibility?.allowsBackgroundConnect == true)
  // 候选记录的是握手实测能力，而不是探测阶段的空集合。
  #expect(report.candidates.first?.capabilities == identity.capabilities)
  #expect(executor.ensureSessionBinaryPaths == ["/usr/local/bin/aster-session"])
  // 运行时位置随配置落盘：二进制取实测候选，状态目录默认按远端 $HOME 推导，
  // 后台连接与受管终端不再依赖 App 启动时的环境变量。
  #expect(executor.ensureSessionStateParentPaths == ["/root/.local/state/aster"])
  #expect(profile.remoteBinaryPath == "/usr/local/bin/aster-session")
  #expect(profile.stateParentPath == "/root/.local/state/aster")
}

@Test func remoteMachineSetupHonoursExplicitStateParentPath() throws {
  let executor = FakeSetupExecutor()
  executor.probeOutput = probeOutput(
    candidates: [("/usr/local/bin/aster-session", compatibleVersionLine)])
  executor.identity = FakeSetupExecutor.makeIdentity(
    capabilities: RemoteProtocolContract.requiredCapabilities)
  let setup = RemoteMachineSetup(
    executor: executor, explicitStateParentPath: "/srv/aster-state")
  let outcome = try setup.run(rawTarget: "root@ubuntu@orb", label: "OrbStack", sessionName: "p3")
  guard case .ready(let profile, _, _) = outcome else {
    Issue.record("期望 ready，实际 \(outcome)")
    return
  }
  #expect(executor.ensureSessionStateParentPaths == ["/srv/aster-state"])
  #expect(profile.stateParentPath == "/srv/aster-state")
}

@Test func remoteMachineSetupFailsWhenHomeUnknownAndNoExplicitStateParent() {
  let executor = FakeSetupExecutor()
  // 远端没报出 $HOME：不能猜一个相对路径当状态目录。
  executor.probeOutput = probeOutput(
    home: "", candidates: [("/usr/local/bin/aster-session", compatibleVersionLine)])
  let setup = RemoteMachineSetup(executor: executor)
  do {
    _ = try setup.run(rawTarget: "root@ubuntu@orb", label: "OrbStack", sessionName: "p3")
    Issue.record("期望失败")
  } catch let failure as RemoteSetupFailure {
    #expect(failure.stage == .sessionPreparation)
    #expect(failure.message.contains("ASTER_SESSION_STATE_DIR"))
    #expect(executor.ensureSessionCalls == 0)
  } catch {
    Issue.record("期望 RemoteSetupFailure，实际 \(error)")
  }
}

@Test func remoteHostProbeDerivesPrivateStateParentPath() {
  #expect(RemoteHostProbe.privateStateParentPath(homeDirectory: "/root") == "/root/.local/state/aster")
  #expect(RemoteHostProbe.privateStateParentPath(homeDirectory: "/home/u/") == "/home/u/.local/state/aster")
  #expect(RemoteHostProbe.privateStateParentPath(homeDirectory: "") == nil)
  #expect(RemoteHostProbe.privateStateParentPath(homeDirectory: "relative") == nil)
}

// MARK: - 远端工作区边界（A12）

@Test func remoteWorkspaceBoundaryDisablesEveryLocalAction() {
  for action in RemoteWorkspaceBoundary.LocalAction.allCases {
    #expect(
      !RemoteWorkspaceBoundary.isAllowedOnRemotePane(action),
      "本机动作 \(action.rawValue) 不应在远端 Pane 上放行")
    let reason = RemoteWorkspaceBoundary.disabledReason(action, machineLabel: "OrbStack")
    #expect(!reason.isEmpty)
    // 必须点名机器，避免用户以为是权限故障而不是「资源在另一台机器上」。
    #expect(reason.contains("OrbStack"), "\(action.rawValue) 的禁用原因未点名机器")
  }
}
