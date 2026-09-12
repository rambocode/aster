import Foundation

/// 远端机器上 Agent CLI 可用性的探测结果（P5）。
///
/// 对每个 `AgentProvider` 检查其 `commandName` 是否在远端 PATH 中存在，
/// 并记录版本、能力矩阵。探测通过 SSH 执行，复用 `RemoteManagedSessionClient`
/// 的传输模式。

/// 单个 provider 的探测条目。
public struct RemoteAgentProbeEntry: Equatable, Sendable {
  /// 该 provider 的 CLI 是否已安装在远端 PATH 中。
  public var installed: Bool
  /// `<cmd> --version` 的输出（超时或失败时为 nil）。
  public var version: String?
  /// provider 是否支持 Aster hook 集成（来自 `supportsManagedIntegration`）。
  public var hasHookIntegration: Bool
  /// provider 是否有 herdr 屏幕检测清单（`detectionManifestID != nil`）。
  public var hasScreenDetection: Bool
  /// provider 是否支持续接会话（来自 `capabilities.contains(.resumeSession)`）。
  public var supportsResumeSession: Bool

  public init(
    installed: Bool,
    version: String? = nil,
    hasHookIntegration: Bool = false,
    hasScreenDetection: Bool = false,
    supportsResumeSession: Bool = false
  ) {
    self.installed = installed
    self.version = version
    self.hasHookIntegration = hasHookIntegration
    self.hasScreenDetection = hasScreenDetection
    self.supportsResumeSession = supportsResumeSession
  }
}

/// 一次完整的远端 Agent 探测结果。
public struct RemoteAgentProbeResult: Equatable, Sendable {
  /// 按 provider 索引的探测条目。
  public var entries: [AgentProvider: RemoteAgentProbeEntry]

  public init(entries: [AgentProvider: RemoteAgentProbeEntry] = [:]) {
    self.entries = entries
  }
}

/// 远端 Agent CLI 探测。通过 SSH 在一次往返中检测所有已知 provider 的可执行文件。
public enum RemoteAgentProbe {
  /// 探测输出标记，与 `RemoteHostProbe` 隔离。
  public static let marker = "ASTER_AGENT_PROBE_V1"

  /// 生成探测脚本 argv。一次 SSH 往返检测所有 provider 的 commandName。
  public static func probeCommand() -> [String] {
    // 为每个 provider 生成 `command -v <cmd>` 和可选的 `<cmd> --version`
    var checks = ""
    for provider in AgentProvider.allCases {
      let cmd = provider.commandName
      let quoted = RemoteSSHInvocation.quote(cmd)
      checks += """
        found="$(command -v \(quoted) 2>/dev/null || true)"
        if [ -n "$found" ]; then
          ver="$(\(quoted) --version 2>/dev/null | head -n 1 || true)"
          printf 'agent=%s\\t%s\\n' \(quoted) "$ver"
        else
          printf 'agent=%s\\t\\n' \(quoted)
        fi

        """
    }
    let script = """
      set -u
      printf '%s\\n' \(RemoteSSHInvocation.quote(marker))
      \(checks)printf '%s\\n' 'end'
      """
    return ["/bin/sh", "-c", script]
  }

  /// 解析探测脚本输出，结合 `AgentProvider` 静态能力生成完整结果。
  public static func parse(_ output: String) -> RemoteAgentProbeResult? {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard lines.contains(where: { $0.trimmingCharacters(in: .whitespaces) == marker }) else {
      return nil
    }
    // 按 commandName 建索引以快速查找
    let commandToProvider: [String: AgentProvider] = Dictionary(
      uniqueKeysWithValues: AgentProvider.allCases.map { ($0.commandName, $0) }
    )
    var entries: [AgentProvider: RemoteAgentProbeEntry] = [:]
    for line in lines {
      guard line.hasPrefix("agent=") else { continue }
      let value = String(line.dropFirst("agent=".count))
      let parts = value.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
      let cmd = String(parts.first ?? "")
      guard let provider = commandToProvider[cmd] else { continue }
      let versionText = parts.count > 1 ? String(parts[1]) : ""
      let version = versionText.isEmpty ? nil : versionText
      // 二次确认身份：版本输出可能暴露 commandName 冲突（如 grok 安装器创建的
      // /usr/local/bin/agent 与 cursorCLI 的 commandName 相同）。
      let verified = verifyVersionIdentity(version: version, provider: provider)
      entries[provider] = RemoteAgentProbeEntry(
        installed: verified,
        version: verified ? version : nil,
        hasHookIntegration: provider.supportsManagedIntegration,
        hasScreenDetection: provider.detectionManifestID != nil,
        supportsResumeSession: provider.capabilities.contains(.resumeSession)
      )
    }
    // 对未出现在输出中的 provider 补充"未安装"条目
    for provider in AgentProvider.allCases where entries[provider] == nil {
      entries[provider] = RemoteAgentProbeEntry(
        installed: false,
        hasHookIntegration: provider.supportsManagedIntegration,
        hasScreenDetection: provider.detectionManifestID != nil,
        supportsResumeSession: provider.capabilities.contains(.resumeSession)
      )
    }
    return RemoteAgentProbeResult(entries: entries)
  }

  /// 用版本输出二次确认 CLI 身份，排除 commandName 冲突导致的误报。
  ///
  /// 规则：
  /// 1. 无版本输出 → 未安装（command -v 失败或 --version 无输出）。
  /// 2. provider 有 versionIdentityToken → 版本输出必须包含该 token（大小写不敏感）。
  /// 3. provider 无 token → 检查是否有其他 provider 的 token 出现；若有则冲突。
  static func verifyVersionIdentity(version: String?, provider: AgentProvider) -> Bool {
    guard let version, !version.isEmpty else { return false }
    let lowered = version.lowercased()
    if let token = provider.versionIdentityToken {
      return lowered.contains(token.lowercased())
    }
    // 无自身 token 时检查冲突：版本输出是否明确属于另一个 provider
    for other in AgentProvider.allCases where other != provider {
      if let otherToken = other.versionIdentityToken,
        lowered.contains(otherToken.lowercased())
      {
        return false
      }
    }
    return true
  }

  /// 通过 SSH 传输执行探测并返回结果。
  public static func probe(transport: RemoteSessionTransport) async throws
    -> RemoteAgentProbeResult
  {
    let runner = RemoteSSHProcessRunner()
    let result = try runner.run(
      arguments: transport.sshArguments(remoteCommand: probeCommand()),
      timeout: 30
    )
    guard let report = parse(result.standardOutput) else {
      throw ManagedSessionError.malformedReply("Agent 探测输出缺少标记")
    }
    return report
  }
}
