import Combine
import AsterCore
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// P4.3 / P4.5 / P4.7 的 App 侧定向测试。
///
/// 全部使用私有临时配置文件与假服务，绝不触碰用户真实配置目录或网络。
/// 与 MainActor 无关的固定夹具。放在隔离域之外，测试替身才能在 `async` 上下文里直接用。
enum MachineFleetFixtures {
  static let identity = SessionServerIdentity(
    reference: SessionServerReference(
      machineProfileID: UUID(), serverID: "srv", sessionID: "sess"),
    serverEpoch: "epoch-1", capabilities: ["terminal_control"], version: "0.1.0-dev")

  static let report = RemoteProbeReport(
    platform: RemotePlatform(os: "linux", architecture: "x86_64", homeDirectory: "/root"),
    candidates: [])

  /// 远端已有运行中服务与一个 PATH 候选的报告（更新服务用例）。
  static let runningReport = RemoteProbeReport(
    platform: RemotePlatform(os: "linux", architecture: "x86_64", homeDirectory: "/root"),
    candidates: [
      RemoteBinaryCandidate(
        path: "/usr/local/bin/aster-session", source: .path, releaseVersion: "0.1.0-dev",
        protocolMajor: 1, protocolMinor: 0)
    ],
    runningServer: identity)

  static let artifact = RemoteServiceArtifact(
    localPath: "/tmp/aster-session-linux-x86_64",
    manifest: RemoteReleaseManifest(
      version: "dev-0123456789ab", platform: "linux", architecture: "x86_64",
      sha256: String(repeating: "ab", count: 32), sizeBytes: 4096,
      artifactKind: .developmentBuild, protocolMajor: 1))

  static let installOutcome = RemoteInstallOutcome(
    installedPath: "/root/.local/share/aster/bin/aster-session",
    versionedPath: "/root/.local/share/aster/versions/dev-0123456789ab/aster-session",
    version: "dev-0123456789ab", previousVersion: nil, artifactKind: .developmentBuild)

  static func integrationReport(
    claudeIntegrated: Bool, includeScreenOnly: Bool = true
  ) -> RemoteAgentIntegrationReport {
    RemoteAgentIntegrationReport(
      homeDirectory: "/root",
      hookScriptPath: "/root/.local/share/aster/agent-integration/aster-agent-hook.sh",
      entries: [
        .init(
          provider: .claudeCode, installed: true, version: "2.1.0", supportsIntegration: true,
          integrated: claudeIntegrated, configurationPath: "~/.claude/settings.json"),
        .init(
          provider: .gemini, installed: includeScreenOnly, supportsIntegration: false,
          integrated: false),
        .init(provider: .codex, installed: false, supportsIntegration: true, integrated: false,
          configurationPath: "~/.codex/hooks.json"),
      ])
  }

  static let replaceOutcome = RemoteReplacementOutcome(
    affectedTerminalIDs: ["t1"], installOutcome: installOutcome, newServerIdentity: identity)
}

@Suite(.serialized)
@MainActor
struct MachineFleetTests {

  /// 假设置服务：按脚本返回成功、需要安装或失败。
  private final class FakeServices: MachineFleetServices, @unchecked Sendable {
    var setupOutcome: RemoteSetupOutcome?
    var setupError: (any Error)?
    /// 按调用顺序消费的设置事务结果；用完后回落到 `setupOutcome` / 默认成功。
    var setupQueue: [RemoteSetupOutcome] = []
    /// 本机产物；nil 表示没有可安装的产物。
    var artifact: RemoteServiceArtifact?
    var artifactError: (any Error)?
    var installOutcome: RemoteInstallOutcome?
    var replaceOutcome: RemoteReplacementOutcome?
    var remoteDigest: String?
    private(set) var installCalls: [(target: String, accept: Bool)] = []
    private(set) var replaceCalls: [(profileID: UUID, accept: Bool)] = []
    private(set) var setupCalls = 0

    func runSetup(rawTarget: String, label: String, sessionName: String, profileID: UUID)
      async throws -> RemoteSetupOutcome
    {
      setupCalls += 1
      if let setupError { throw setupError }
      if !setupQueue.isEmpty { return setupQueue.removeFirst() }
      if let setupOutcome { return setupOutcome }
      return .ready(
        profile: MachineProfile(
          id: profileID, label: label, sshTarget: rawTarget, sessionName: sessionName,
          remoteBinaryPath: "/usr/local/bin/aster-session",
          stateParentPath: "/root/.local/state/aster"),
        identity: MachineFleetFixtures.identity,
        report: MachineFleetFixtures.report)
    }

    func registry(for profile: MachineProfile) throws -> MachineRegistryAccess {
      throw ManagedSessionError.runtimeUnavailable("测试不提供注册表传输")
    }

    func serviceArtifact(for platform: RemotePlatform) throws -> RemoteServiceArtifact? {
      if let artifactError { throw artifactError }
      return artifact
    }

    func installService(
      rawTarget: String, report: RemoteProbeReport, artifact: RemoteServiceArtifact,
      acceptDevelopmentArtifact: Bool
    ) async throws -> RemoteInstallOutcome {
      installCalls.append((rawTarget, acceptDevelopmentArtifact))
      guard let installOutcome else {
        throw ManagedSessionError.runtimeUnavailable("测试未提供安装结果")
      }
      return installOutcome
    }

    func replaceService(
      profile: MachineProfile, report: RemoteProbeReport, artifact: RemoteServiceArtifact,
      acceptDevelopmentArtifact: Bool
    ) async throws -> RemoteReplacementOutcome {
      replaceCalls.append((profile.id, acceptDevelopmentArtifact))
      guard let replaceOutcome else {
        throw ManagedSessionError.runtimeUnavailable("测试未提供替换结果")
      }
      return replaceOutcome
    }

    func remoteBinaryDigest(rawTarget: String, path: String) async throws -> String? {
      remoteDigest
    }

    var catalog: RemoteAgentProbeResult?
    func remoteAgentCatalog(for profile: MachineProfile) async throws -> RemoteAgentProbeResult {
      guard let catalog else { throw ManagedSessionError.runtimeUnavailable("测试未提供清单") }
      return catalog
    }

    var integrationReport: RemoteAgentIntegrationReport?
    private(set) var integrationInstallCalls: [[AgentProvider]] = []

    func agentIntegration(for profile: MachineProfile, install: [AgentProvider]?) async throws
      -> RemoteAgentIntegrationReport
    {
      guard var report = integrationReport else {
        throw ManagedSessionError.runtimeUnavailable("测试未提供集成报告")
      }
      if let install {
        integrationInstallCalls.append(install)
        report.entries = report.entries.map { entry in
          var entry = entry
          if install.contains(entry.provider) { entry.integrated = true }
          return entry
        }
      }
      return report
    }
  }

  /// 一直在线的假驱动：连接立即成功，心跳永远响应。配合「等待即让出」的环境，
  /// 心跳循环会以极高频率刷新编排器侧的 `lastUpdatedAt`。
  private struct AlwaysOnlineDriver: MachineConnectionDriving {
    func connect(profile: MachineProfile, generation: UInt64) async -> MachineConnectionOutcome {
      .connected(MachineFleetFixtures.identity)
    }
    func heartbeat(profile: MachineProfile, generation: UInt64) async -> Bool { true }
    func confirmSnapshot(profile: MachineProfile, generation: UInt64) async -> Bool { true }
  }

  /// 假连接驱动：永不成功也永不真正等待，用来证明「即使连不上也能禁用/移除」。
  private struct SilentDriver: MachineConnectionDriving {
    func connect(profile: MachineProfile, generation: UInt64) async -> MachineConnectionOutcome {
      .needsExplicitSetup(kind: nil, reason: "测试驱动不连接")
    }
    func heartbeat(profile: MachineProfile, generation: UInt64) async -> Bool { false }
    func confirmSnapshot(profile: MachineProfile, generation: UInt64) async -> Bool { false }
  }

  private func makeFleet(
    _ services: FakeServices = FakeServices(),
    driver: any MachineConnectionDriving = SilentDriver()
  )
    -> (MachineFleetModel, URL, FakeServices)
  {
    let url = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("AsterMachineTests.\(UUID().uuidString)")
      .appendingPathComponent("machines.json")
    let fleet = MachineFleetModel(
      store: MachineProfileStore(fileURL: url),
      services: services,
      supervisor: MachineConnectionSupervisor(
        environment: MachineConnectionEnvironment(
          // 虚拟等待：退避与心跳立即返回，用例不等真实秒数。
          sleep: { _ in await Task.yield() }, jitter: { 0 }),
        driver: driver),
      localStateProvider: { .online },
      localErrorProvider: { nil })
    return (fleet, url, services)
  }

  private func cleanUp(_ fleet: MachineFleetModel, _ url: URL) {
    fleet.stop()
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  // MARK: - P4.3 添加机器

  @Test("添加机器：成功保存配置；Local 恒在最上并显示绑定的命名会话")
  func addMachineSavesProfile() async throws {
    let (fleet, url, _) = makeFleet()
    defer { cleanUp(fleet, url) }

    let result = await fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work", confirm: { _ in true })
    guard case .added(let profile) = result else {
      Issue.record("添加应成功，实际：\(result)")
      return
    }
    #expect(profile.sessionName == "work")
    #expect(fleet.rows.first?.isLocal == true)
    #expect(fleet.rows.count == 2)
    #expect(fleet.rows[1].subtitle == "root@ubuntu@orb · work")

    // 配置必须已经原子落盘，重新构造 store 也能读回同一份。
    let reread = try MachineProfileStore(fileURL: url).load()
    #expect(reread == .loaded([profile]))
  }

  @Test("添加机器：需要安装时用户取消，磁盘上不留下任何配置")
  func addMachineCancelledLeavesNothing() async throws {
    let services = FakeServices()
    services.setupOutcome = .installationRequired(report: MachineFleetFixtures.report, reason: "远端没有二进制")
    services.artifact = MachineFleetFixtures.artifact
    let (fleet, url, _) = makeFleet(services)
    defer { cleanUp(fleet, url) }

    var shown: MachineSetupConfirmation?
    let result = await fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work",
      confirm: { confirmation in
        shown = confirmation
        return false
      })
    #expect(result == .cancelled)
    // 确认框必须展示目标、平台、版本与进程影响。
    #expect(shown?.target == "root@ubuntu@orb")
    #expect(shown?.platform == "linux/x86_64")
    #expect(shown?.processImpact.isEmpty == false)
    #expect(shown?.reason == "远端没有二进制")
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(fleet.rows.count == 1)
  }

  @Test("添加机器：需要安装时装完再走一遍设置事务，只有 .ready 才保存配置")
  func addMachineInstallsThenSaves() async throws {
    let services = FakeServices()
    services.setupQueue = [
      .installationRequired(report: MachineFleetFixtures.report, reason: "远端没有二进制")
    ]
    services.artifact = MachineFleetFixtures.artifact
    services.installOutcome = MachineFleetFixtures.installOutcome
    let (fleet, url, _) = makeFleet(services)
    defer { cleanUp(fleet, url) }

    var shown: MachineSetupConfirmation?
    let result = await fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work",
      confirm: { confirmation in
        shown = confirmation
        return true
      })
    guard case .added(let profile) = result else {
      Issue.record("添加应成功，实际：\(result)")
      return
    }
    // 开发产物必须以 developmentArtifact 形态确认，并把接受结果传给安装事务。
    #expect(shown?.kind == .developmentArtifact)
    #expect(shown?.version.contains("开发产物") == true)
    #expect(services.installCalls.count == 1)
    #expect(services.installCalls.first?.accept == true)
    #expect(services.setupCalls == 2)
    #expect(profile.sshTarget == "root@ubuntu@orb")
    #expect(try MachineProfileStore(fileURL: url).load() == .loaded([profile]))
  }

  @Test("添加机器：本机没有该平台的产物时直接失败，不弹确认、不做任何远端写动作")
  func addMachineWithoutArtifactFails() async throws {
    let services = FakeServices()
    services.setupOutcome = .installationRequired(report: MachineFleetFixtures.report, reason: "远端没有二进制")
    let (fleet, url, _) = makeFleet(services)
    defer { cleanUp(fleet, url) }

    var confirmations = 0
    let result = await fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work",
      confirm: { _ in
        confirmations += 1
        return true
      })
    guard case .failed(let message) = result else {
      Issue.record("应失败，实际：\(result)")
      return
    }
    #expect(message.contains("linux/x86_64"))
    #expect(message.contains(RemoteEnvironmentKeys.remoteBinary))
    #expect(confirmations == 0)
    #expect(services.installCalls.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test("更新远端服务：确认后停止/安装/重启，配置里的二进制路径换成新活动路径")
  func updateServiceReplacesAndPersists() async throws {
    let services = FakeServices()
    services.artifact = MachineFleetFixtures.artifact
    services.replaceOutcome = MachineFleetFixtures.replaceOutcome
    services.remoteDigest = String(repeating: "cd", count: 32)
    let (fleet, url, _) = makeFleet(services)
    defer { cleanUp(fleet, url) }
    guard case .added(let profile) = await fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work", confirm: { _ in true })
    else {
      Issue.record("前置添加失败")
      return
    }
    services.setupOutcome = .ready(
      profile: profile, identity: MachineFleetFixtures.identity,
      report: MachineFleetFixtures.runningReport)

    var shown: MachineSetupConfirmation?
    let result = await fleet.updateService(
      profile.id,
      confirm: { confirmation in
        shown = confirmation
        return true
      })
    guard case .updated(let updated) = result else {
      Issue.record("应更新成功，实际：\(result)")
      return
    }
    #expect(shown?.kind == .developmentArtifact)
    #expect(shown?.processImpact.contains("停止") == true)
    #expect(shown?.processImpact.contains("work") == true)
    #expect(services.replaceCalls.map(\.profileID) == [profile.id])
    #expect(services.installCalls.isEmpty)
    #expect(updated.remoteBinaryPath == "/root/.local/share/aster/bin/aster-session")
    #expect(updated.stateParentPath == profile.stateParentPath)
    #expect(try MachineProfileStore(fileURL: url).load() == .loaded([updated]))
  }

  @Test("更新远端服务：远端已是同一份二进制时不停服务、不上传")
  func updateServiceSkipsWhenDigestMatches() async throws {
    let services = FakeServices()
    services.artifact = MachineFleetFixtures.artifact
    services.remoteDigest = MachineFleetFixtures.artifact.manifest.sha256
    let (fleet, url, _) = makeFleet(services)
    defer { cleanUp(fleet, url) }
    guard case .added(let profile) = await fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work", confirm: { _ in true })
    else {
      Issue.record("前置添加失败")
      return
    }
    services.setupOutcome = .ready(
      profile: profile, identity: MachineFleetFixtures.identity,
      report: MachineFleetFixtures.runningReport)

    var confirmations = 0
    let result = await fleet.updateService(
      profile.id,
      confirm: { _ in
        confirmations += 1
        return true
      })
    guard case .upToDate = result else {
      Issue.record("应报告无需更新，实际：\(result)")
      return
    }
    #expect(confirmations == 0)
    #expect(services.replaceCalls.isEmpty)
    #expect(services.installCalls.isEmpty)
  }

  @Test("更新远端服务：用户取消时什么也不做；Local 不提供该动作")
  func updateServiceCancelDoesNothing() async throws {
    let services = FakeServices()
    services.artifact = MachineFleetFixtures.artifact
    let (fleet, url, _) = makeFleet(services)
    defer { cleanUp(fleet, url) }
    guard case .added(let profile) = await fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work", confirm: { _ in true })
    else {
      Issue.record("前置添加失败")
      return
    }
    services.setupOutcome = .ready(
      profile: profile, identity: MachineFleetFixtures.identity,
      report: MachineFleetFixtures.runningReport)

    #expect(await fleet.updateService(profile.id, confirm: { _ in false }) == .cancelled)
    #expect(services.replaceCalls.isEmpty)
    guard case .failed = await fleet.updateService(MachineProfile.localProfileID, confirm: { _ in true })
    else {
      Issue.record("Local 应拒绝更新服务")
      return
    }
  }

  @Test("远端 Agent 集成：只对远端已装且有集成的 provider 确认并安装")
  func agentIntegrationInstallsPendingProviders() async throws {
    let services = FakeServices()
    services.integrationReport = MachineFleetFixtures.integrationReport(claudeIntegrated: false)
    let (fleet, url, _) = makeFleet(services)
    defer { cleanUp(fleet, url) }
    guard case .added(let profile) = await fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work", confirm: { _ in true })
    else {
      Issue.record("前置添加失败")
      return
    }

    var shown: RemoteAgentIntegrationReport?
    let result = await fleet.configureAgentIntegration(
      profile.id,
      confirm: { report in
        shown = report
        return true
      })
    guard case .installed(let report) = result else {
      Issue.record("应安装成功，实际：\(result)")
      return
    }
    // 确认框只列 claude；gemini 没有集成、codex 没装。
    #expect(shown?.pending.map(\.provider) == [.claudeCode])
    #expect(shown?.screenOnly.map(\.provider) == [.gemini])
    #expect(services.integrationInstallCalls == [[.claudeCode]])
    #expect(report.entries.first { $0.provider == .claudeCode }?.integrated == true)
  }

  @Test("远端 Agent 集成：全部就位时不弹确认；没有可集成 CLI 时说明原因；Local 拒绝")
  func agentIntegrationSkipsWhenNothingPending() async throws {
    let services = FakeServices()
    services.integrationReport = MachineFleetFixtures.integrationReport(claudeIntegrated: true)
    let (fleet, url, _) = makeFleet(services)
    defer { cleanUp(fleet, url) }
    guard case .added(let profile) = await fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work", confirm: { _ in true })
    else {
      Issue.record("前置添加失败")
      return
    }
    var confirmations = 0
    guard case .installed = await fleet.configureAgentIntegration(
      profile.id, confirm: { _ in confirmations += 1; return true })
    else {
      Issue.record("全部就位应直接返回 installed")
      return
    }
    #expect(confirmations == 0)
    #expect(services.integrationInstallCalls.isEmpty)

    services.integrationReport = RemoteAgentIntegrationReport(
      homeDirectory: "/root", hookScriptPath: "/root/hook.sh",
      entries: [.init(provider: .gemini, installed: true, supportsIntegration: false, integrated: false)])
    guard case .nothingToInstall(let message) = await fleet.configureAgentIntegration(
      profile.id, confirm: { _ in true })
    else {
      Issue.record("只有屏幕检测 CLI 时应报 nothingToInstall")
      return
    }
    #expect(message.contains("Gemini") || message.contains("gemini"))
    #expect(confirmations == 0)

    guard case .failed = await fleet.configureAgentIntegration(
      MachineProfile.localProfileID, confirm: { _ in true })
    else {
      Issue.record("Local 应拒绝")
      return
    }
  }

  @Test("远端 Agent 清单：只列远端已安装的 CLI，按 provider 固定顺序；Local 不适用")
  func remoteAgentCatalogListsInstalledProviders() async throws {
    let services = FakeServices()
    services.catalog = RemoteAgentProbeResult(entries: [
      .grokBuild: .init(installed: true, version: "grok 1.0.30"),
      .claudeCode: .init(installed: true, version: "2.1.0"),
      .codex: .init(installed: false),
    ])
    let (fleet, url, _) = makeFleet(services)
    defer { cleanUp(fleet, url) }
    guard case .added(let profile) = await fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work", confirm: { _ in true })
    else {
      Issue.record("前置添加失败")
      return
    }
    let catalog = try await fleet.remoteAgentCatalog(profile.id)
    #expect(catalog.map(\.provider) == [.claudeCode, .grokBuild])
    #expect(catalog.map(\.version) == ["2.1.0", "grok 1.0.30"])
    await #expect(throws: MachineFleetError.machineNotFound) {
      try await fleet.remoteAgentCatalog(MachineProfile.localProfileID)
    }
  }

  @Test("远端 Agent 清单写回侧栏行：探测前为 nil，探测后带版本；悬停提示与文案一致")
  func agentCatalogAppearsOnSidebarRow() async throws {
    let services = FakeServices()
    services.catalog = RemoteAgentProbeResult(entries: [
      .grokBuild: .init(installed: true, version: "grok 1.0.30 (04b7ffed98c6) [stable]"),
      .claudeCode: .init(installed: true, version: "2.1.0"),
    ])
    let (fleet, url, _) = makeFleet(services)
    defer { cleanUp(fleet, url) }
    guard case .added(let profile) = await fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work", confirm: { _ in true })
    else {
      Issue.record("前置添加失败")
      return
    }
    let before = try #require(fleet.rows.first { $0.id == profile.id })
    #expect(before.agents == nil)
    #expect(MachineRowButton.toolTip(before).contains("Agent：尚未探测"))

    _ = try await fleet.refreshAgentCatalog(profile.id)
    let after = try #require(fleet.rows.first { $0.id == profile.id })
    #expect(after.agents?.map(\.provider) == [.claudeCode, .grokBuild])
    // 版本去掉命令名前缀，只留数字部分；provider 用显示名。
    let text = MachineRowButton.agentsText(after.agents ?? [])
    #expect(text == "Claude Code 2.1.0、Grok Build 1.0.30 (04b7ffed98c6) [stable]")
    #expect(MachineRowButton.toolTip(after).contains("Agent：" + text))
    // Local 行不显示 Agent 探测信息。
    let local = try #require(fleet.rows.first)
    #expect(local.isLocal && local.agents == nil)
    #expect(!MachineRowButton.toolTip(local).contains("Agent"))
  }

  @Test("添加机器：设置事务失败不保存配置")
  func addMachineFailureLeavesNothing() async throws {
    let services = FakeServices()
    services.setupError = RemoteSetupFailure(
      stage: .authentication, requiresExplicitSetup: true, message: "无法非交互认证")
    let (fleet, url, _) = makeFleet(services)
    defer { cleanUp(fleet, url) }

    let result = await fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work", confirm: { _ in true })
    #expect(result == .failed("无法非交互认证"))
    #expect(!FileManager.default.fileExists(atPath: url.path))
  }

  @Test("添加机器：标签或会话名为空时在任何网络动作之前就拒绝")
  func addMachineRejectsEmptyInput() async throws {
    let (fleet, url, _) = makeFleet()
    defer { cleanUp(fleet, url) }
    #expect(
      await fleet.addMachine(
        label: "  ", sshTarget: "host", sessionName: "s", confirm: { _ in true })
        == .failed("机器标签不能为空。"))
    #expect(
      await fleet.addMachine(
        label: "x", sshTarget: "host", sessionName: " ", confirm: { _ in true })
        == .failed("必须指定要绑定的命名会话。"))
  }

  // MARK: - P4.3 / P4.7 重命名、禁用、移除

  @Test("重命名只改标签；禁用与移除即使离线也能操作，且当前机器回到 Local")
  func renameDisableRemove() async throws {
    let (fleet, url, _) = makeFleet()
    defer { cleanUp(fleet, url) }
    guard case .added(let profile) = await fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work", confirm: { _ in true })
    else {
      Issue.record("前置添加失败")
      return
    }
    #expect(fleet.selectMachine(profile.id) == nil)
    #expect(fleet.activeMachineID == profile.id)

    #expect(fleet.rename(profile.id, to: "orb-ubuntu") == nil)
    #expect(fleet.rows[1].label == "orb-ubuntu")
    // 重命名只是标签变化：Core 的差异集合里不应出现任何需要重连的项。
    var renamed = profile
    renamed.label = "orb-ubuntu"
    #expect(MachineProfileStore.reconnectRequiredProfileIDs(old: [profile], new: [renamed]).isEmpty)

    // 驱动永远连不上（attention），禁用与移除仍然必须可用。
    #expect(fleet.setEnabled(profile.id, false) == nil)
    #expect(fleet.rows[1].state == .disabled)
    #expect(fleet.activeMachineID == MachineProfile.localProfileID)
    #expect(fleet.selectMachine(profile.id) == "该机器已禁用。")

    #expect(fleet.setEnabled(profile.id, true) == nil)
    #expect(fleet.selectMachine(profile.id) == nil)
    #expect(fleet.remove(profile.id) == nil)
    #expect(fleet.rows.count == 1)
    #expect(fleet.activeMachineID == MachineProfile.localProfileID)
    #expect(try MachineProfileStore(fileURL: url).load() == .loaded([]))
  }

  @Test("Local 不能重命名、禁用或移除")
  func localIsNotAConfiguration() {
    let (fleet, url, _) = makeFleet()
    defer { cleanUp(fleet, url) }
    #expect(fleet.rename(MachineProfile.localProfileID, to: "x") != nil)
    #expect(fleet.setEnabled(MachineProfile.localProfileID, false) != nil)
    #expect(fleet.remove(MachineProfile.localProfileID) != nil)
  }

  @Test("离线展示：未连接的机器禁用输入与导航并标为 stale")
  func offlinePresentation() async throws {
    let (fleet, url, _) = makeFleet()
    defer { cleanUp(fleet, url) }
    guard case .added(let profile) = await fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work", confirm: { _ in true })
    else {
      Issue.record("前置添加失败")
      return
    }
    await fleet.refreshStatuses()
    let presentation = fleet.presentation(for: profile.id)
    #expect(presentation.isStale)
    #expect(!presentation.allowsInput)
    #expect(!presentation.allowsNavigation)

    // Local 在线时允许交互，且不受远端状态影响。
    let local = fleet.presentation(for: MachineProfile.localProfileID)
    #expect(local.allowsInput)
    #expect(!local.isStale)
  }

  // MARK: - P4.5 配置恢复

  @Test("配置文件损坏时保留最后一份有效配置，不清空已有机器")
  func corruptConfigurationKeepsLastValidSet() async throws {
    let (fleet, url, _) = makeFleet()
    defer { cleanUp(fleet, url) }
    guard case .added(let profile) = await fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work", confirm: { _ in true })
    else {
      Issue.record("前置添加失败")
      return
    }
    try Data("{ not json".utf8).write(to: url)
    fleet.reloadProfiles()
    #expect(fleet.configurationError != nil)
    #expect(fleet.profiles == [profile])
    #expect(fleet.rows.count == 2)
  }

  @Test("配置文件不存在是合法首次启动，不是损坏")
  func absentConfigurationIsNotCorruption() {
    let (fleet, url, _) = makeFleet()
    defer { cleanUp(fleet, url) }
    fleet.reloadProfiles()
    #expect(fleet.configurationError == nil)
    #expect(fleet.profiles.isEmpty)
    #expect(fleet.rows.count == 1)
  }

  // MARK: - 目标解析（R17）

  @Test("两个配置映射同一 hostname 时保持两份独立身份")
  func twoProfilesSameHostStayDistinct() async throws {
    let (fleet, url, _) = makeFleet()
    defer { cleanUp(fleet, url) }
    _ = await fleet.addMachine(
      label: "orb-a", sshTarget: "root@ubuntu@orb", sessionName: "a", confirm: { _ in true })
    _ = await fleet.addMachine(
      label: "orb-b", sshTarget: "root@ubuntu@orb", sessionName: "b", confirm: { _ in true })
    #expect(fleet.profiles.count == 2)
    #expect(Set(fleet.profiles.map(\.id)).count == 2)
    #expect(fleet.resolve(idOrLabel: "orb-a")?.sessionName == "a")
    #expect(fleet.resolve(idOrLabel: "orb-b")?.sessionName == "b")
  }

  @Test("按标签定位：标签重复时拒绝，不猜当前选中项")
  func ambiguousLabelIsRejected() async throws {
    let (fleet, url, _) = makeFleet()
    defer { cleanUp(fleet, url) }
    _ = await fleet.addMachine(
      label: "dup", sshTarget: "host-a", sessionName: "a", confirm: { _ in true })
    _ = await fleet.addMachine(
      label: "dup", sshTarget: "host-b", sessionName: "b", confirm: { _ in true })
    #expect(fleet.resolve(idOrLabel: "dup") == nil)
    #expect(fleet.resolve(idOrLabel: "local")?.id == MachineProfile.localProfileID)
    #expect(fleet.resolve(idOrLabel: UUID().uuidString) == nil)
  }

  // MARK: - 心跳不得重建工作区

  @Test("远端心跳只刷新编排器时间戳，机器行保持相等，不触发 rows 重新发布")
  func heartbeatDoesNotRepublishRows() async throws {
    let (fleet, url, _) = makeFleet(driver: AlwaysOnlineDriver())
    defer { cleanUp(fleet, url) }
    guard case .added(let profile) = await fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work", confirm: { _ in true })
    else {
      Issue.record("添加应成功")
      return
    }

    // 等到连接任务把机器推到 online。
    var online: MachineFleetRow?
    for _ in 0..<500 {
      await Task.yield()
      await fleet.refreshStatuses()
      if let row = fleet.rows.first(where: { $0.id == profile.id }), row.state == .online {
        online = row
        break
      }
    }
    let onlineRow = try #require(online)
    let stampBefore = try #require(onlineRow.lastUpdatedAt)

    // 在线之后心跳持续运行：编排器侧时间戳必须前进，行却必须保持不变、不再发布。
    var publishes = 0
    let subscription = fleet.$rows.dropFirst().sink { _ in publishes += 1 }
    defer { subscription.cancel() }
    var supervisorStampAdvanced = false
    for _ in 0..<300 {
      await Task.yield()
      await fleet.refreshStatuses()
      if let status = fleet.statuses[profile.id], status.lastUpdatedAt > stampBefore {
        supervisorStampAdvanced = true
      }
    }
    #expect(supervisorStampAdvanced, "心跳应持续刷新编排器侧的 lastUpdatedAt")
    #expect(publishes == 0, "心跳不得让 rows 重新发布")
    #expect(fleet.rows.first { $0.id == profile.id }?.lastUpdatedAt == stampBefore)
  }

  // MARK: - 侧栏文案

  @Test("侧栏状态文案与最后更新时间")
  func sidebarTextHelpers() {
    #expect(MachineRowButton.stateText(.attention) == "需要处理")
    #expect(MachineRowButton.stateText(.reconnecting) == "重连中")
    #expect(MachineRowButton.lastUpdatedText(nil) == "从未连接")
    let base = Date(timeIntervalSince1970: 1_000_000)
    #expect(
      MachineRowButton.lastUpdatedText(base, now: base.addingTimeInterval(90))
        == "最后更新 1 分钟前")
  }
}
