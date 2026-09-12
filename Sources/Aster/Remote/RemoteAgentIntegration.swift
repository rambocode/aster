import AsterCore
import Foundation

/// 远端机器上 Aster Agent 集成（hook）的探测与安装（对齐 herdrm：连上机器后 Agent 状态、
/// 等待输入与完成通知应和本机一样出现，而不是只给一个 SSH Shell）。
///
/// 做法与本机完全同一套规则：`AgentSetupService` 只换文件系统实现（SSH）与可执行文件来源
/// （远端探测），hook 脚本本身上传到远端私有目录 `<home>/.local/share/aster/agent-integration/`。
/// 远端 Agent 触发 hook 后把 OSC 6974 写进自己的 PTY，服务端 VT 解析成 `agent.changed`
/// 事件，客户端沿既有 P5 通道显示状态与通知。
struct RemoteAgentIntegrationReport: Equatable, Sendable {
  struct Entry: Equatable, Sendable {
    var provider: AgentProvider
    /// 远端 PATH 上有该 CLI。
    var installed: Bool
    var version: String?
    /// provider 有 Aster 受管集成可装（否则只能靠屏幕检测）。
    var supportsIntegration: Bool
    /// 远端配置里已存在完整、带 Aster 所有权标记的集成。
    var integrated: Bool
    /// 本次安装该 provider 的失败原因；nil 表示未尝试或成功。
    var failure: String?
    /// 会被修改的远端配置路径（`~` 相对远端 home），用于确认文案。
    var configurationPath: String?
  }

  var homeDirectory: String
  var hookScriptPath: String
  var entries: [Entry]

  /// 远端已装 CLI 且有集成可装的 provider。
  var candidates: [Entry] { entries.filter { $0.installed && $0.supportsIntegration } }
  /// 其中尚未集成的。
  var pending: [Entry] { candidates.filter { !$0.integrated } }
  /// 远端已装但没有集成可装（只能屏幕检测）的 provider。
  var screenOnly: [Entry] { entries.filter { $0.installed && !$0.supportsIntegration } }
}

/// 远端 Agent 集成安装器：一次 SSH 会话内完成探测、上传 hook 脚本、按 provider 合并配置。
struct RemoteAgentIntegrationInstaller: Sendable {
  let transport: RemoteSessionTransport
  let runner: any RemoteSSHRunning
  /// 本机 bundle 内的 hook 脚本；上传到远端后由远端 Agent 执行。
  let localHookScriptURL: URL

  init(
    transport: RemoteSessionTransport,
    localHookScriptURL: URL,
    runner: any RemoteSSHRunning = RemoteSSHProcessRunner()
  ) {
    self.transport = transport
    self.localHookScriptURL = localHookScriptURL
    self.runner = runner
  }

  /// hook 脚本在远端的固定位置（私有安装目录下，与服务二进制并列）。
  static func hookScriptPath(homeDirectory: String) -> String {
    let home = homeDirectory.count > 1 && homeDirectory.hasSuffix("/")
      ? String(homeDirectory.dropLast()) : homeDirectory
    return home + "/.local/share/aster/agent-integration/aster-agent-hook.sh"
  }

  /// 只读探测：远端 home、各 CLI 是否安装、集成是否已就位。不写任何东西。
  func inspect() throws -> RemoteAgentIntegrationReport {
    let home = try remoteHome()
    let probe = try probeAgents()
    return try report(home: home, probe: probe, failures: [:])
  }

  /// 安装：上传 hook 脚本，再对给定 provider 逐个合并远端配置。
  /// 单个 provider 失败不阻断其它 provider；失败原因进入报告，由界面展示。
  func install(providers: [AgentProvider]) throws -> RemoteAgentIntegrationReport {
    let home = try remoteHome()
    let probe = try probeAgents()
    try uploadHookScript(home: home)
    let service = makeService(home: home, probe: probe)
    var failures: [AgentProvider: String] = [:]
    for provider in providers {
      do { _ = try service.install(provider) } catch {
        failures[provider] = (error as? LocalizedError)?.errorDescription
          ?? String(describing: error)
      }
    }
    return try report(home: home, probe: probe, failures: failures)
  }

  // MARK: - 步骤

  private func remoteHome() throws -> String {
    let result = try runner.run(
      arguments: transport.sshArguments(remoteCommand: ["/bin/sh", "-c", "printf %s \"$HOME\""]),
      timeout: TimeInterval(transport.policy.connectTimeout + 5))
    let home = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard result.exitStatus == 0, home.hasPrefix("/") else {
      throw ManagedSessionError.runtimeUnavailable("远端未报告 $HOME，无法安装 Agent 集成。")
    }
    return home
  }

  private func probeAgents() throws -> RemoteAgentProbeResult {
    let result = try runner.run(
      arguments: transport.sshArguments(remoteCommand: RemoteAgentProbe.probeCommand()),
      timeout: 30)
    guard let probe = RemoteAgentProbe.parse(result.standardOutput) else {
      throw ManagedSessionError.malformedReply("Agent 探测输出缺少标记")
    }
    return probe
  }

  /// 上传 hook 脚本到远端私有目录并置为 0755。每次安装都重传：App 升级后脚本可能变化。
  private func uploadHookScript(home: String) throws {
    let target = Self.hookScriptPath(homeDirectory: home)
    let directory = (target as NSString).deletingLastPathComponent
    let mkdir = try runner.run(
      arguments: transport.sshArguments(
        remoteCommand: ["/bin/sh", "-c", "umask 077; mkdir -p -- \"$1\"", "sh", directory]),
      timeout: TimeInterval(transport.policy.connectTimeout + 5))
    guard mkdir.exitStatus == 0 else {
      throw ManagedSessionError.runtimeUnavailable(
        "无法创建远端目录 \(directory)：\(RemoteSSHDiagnostics.redact(mkdir.standardError))")
    }
    let staging = target + ".upload"
    try RemoteSSHInstallExecutor(transport: transport, runner: runner)
      .upload(localPath: localHookScriptURL.path, remotePath: staging)
    let activate = try runner.run(
      arguments: transport.sshArguments(
        remoteCommand: [
          "/bin/sh", "-c", "chmod 755 -- \"$1\" && mv -f -- \"$1\" \"$2\"", "sh", staging, target,
        ]),
      timeout: TimeInterval(transport.policy.connectTimeout + 5))
    guard activate.exitStatus == 0 else {
      throw ManagedSessionError.runtimeUnavailable(
        "无法安装远端 hook 脚本：\(RemoteSSHDiagnostics.redact(activate.standardError))")
    }
  }

  private func makeService(home: String, probe: RemoteAgentProbeResult) -> AgentSetupService {
    AgentSetupService(
      homeDirectory: URL(fileURLWithPath: home, isDirectory: true),
      integrationScriptURL: URL(fileURLWithPath: Self.hookScriptPath(homeDirectory: home)),
      fileSystem: RemoteAgentSetupFileSystem(transport: transport, runner: runner),
      executableResolver: { provider in
        probe.entries[provider]?.installed == true ? provider.commandName : nil
      })
  }

  private func report(
    home: String, probe: RemoteAgentProbeResult, failures: [AgentProvider: String]
  ) throws -> RemoteAgentIntegrationReport {
    let service = makeService(home: home, probe: probe)
    var entries: [RemoteAgentIntegrationReport.Entry] = []
    for provider in AgentProvider.allCases {
      let entry = probe.entries[provider]
      let installed = entry?.installed == true
      var integrated = false
      if installed, provider.supportsManagedIntegration {
        // hook 脚本尚未上传时 TOML 类 provider 的检测会报资源缺失：视为未集成，不是错误。
        integrated = (try? service.status(for: provider).managedIntegrationInstalled) ?? false
      }
      entries.append(
        RemoteAgentIntegrationReport.Entry(
          provider: provider,
          installed: installed,
          version: entry?.version,
          supportsIntegration: provider.supportsManagedIntegration,
          integrated: integrated,
          failure: failures[provider],
          configurationPath: Self.configurationPath(for: provider)))
    }
    return RemoteAgentIntegrationReport(
      homeDirectory: home,
      hookScriptPath: Self.hookScriptPath(homeDirectory: home),
      entries: entries)
  }

  /// 各 provider 的受管配置位置；与 `AgentSetupService` 内的表一致，只用于确认文案。
  static func configurationPath(for provider: AgentProvider) -> String? {
    switch provider.installationStep {
    case .mergeManagedHooks(let path, _)?: path
    case .enableFeature(let path, _)?: path
    case .installManagedArtifact(let directory, _)?:
      directory + "/" + AgentSetupService.managedArtifactFileName
    case nil: nil
    }
  }
}
