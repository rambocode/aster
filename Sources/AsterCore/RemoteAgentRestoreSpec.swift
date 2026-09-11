import Foundation

/// 远端 Agent 原生恢复规格：校验 provider 的 resume argv 并构建远端执行命令。

/// 一条有效的远端 Agent 恢复指令。
public struct RemoteAgentRestoreCommand: Equatable, Sendable {
  public let provider: AgentProvider
  public let nativeSession: String
  /// 在远端执行的完整 argv（例如 ["grok", "--resume", "<session-id>"]）。
  public let argv: [String]
  /// 源 paneID。
  public let paneID: String
  /// 源 machineID。
  public let machineID: UUID

  public init(provider: AgentProvider, nativeSession: String, argv: [String], paneID: String, machineID: UUID) {
    self.provider = provider
    self.nativeSession = nativeSession
    self.argv = argv
    self.paneID = paneID
    self.machineID = machineID
  }
}

/// 构建并校验远端 Agent 恢复命令。
public enum RemoteAgentRestoreSpec {
  /// 为已校验的引用构建恢复 argv。不支持恢复的 provider 返回 nil。
  public static func buildRestoreCommand(
    provider: AgentProvider,
    nativeSession: String,
    paneID: String,
    machineID: UUID
  ) -> RemoteAgentRestoreCommand? {
    guard provider.capabilities.contains(.resumeSession) else { return nil }
    guard RemoteAgentSessionReference.validate(provider: provider, nativeSession: nativeSession, machineID: machineID) else { return nil }

    // 按 provider 拼装恢复 argv；未在此列出的 provider 只有屏幕检测清单，不支持恢复。
    let argv: [String]
    switch provider {
    case .claudeCode:
      argv = ["claude", "--resume", nativeSession]
    case .codex:
      argv = ["codex", "--resume", nativeSession]
    case .grokBuild:
      argv = ["grok", "--resume", nativeSession]
    case .openCode:
      argv = ["opencode", "--resume", nativeSession]
    case .kimiCode:
      argv = ["kimi", "--resume", nativeSession]
    case .pi:
      argv = ["pi", "--resume", nativeSession]
    case .omp:
      argv = ["omp", "--resume", nativeSession]
    case .cursorCLI:
      argv = ["agent", "--resume", nativeSession]
    default:
      // 仅有屏幕检测清单的 provider 不具备 resumeSession 能力。
      return nil
    }

    return RemoteAgentRestoreCommand(
      provider: provider,
      nativeSession: nativeSession,
      argv: argv,
      paneID: paneID,
      machineID: machineID
    )
  }

  /// 对一组引用去重：同一 (machineID, provider, nativeSession) 只保留第一个。
  public static func dedup(_ commands: [RemoteAgentRestoreCommand]) -> [RemoteAgentRestoreCommand] {
    var seen = Set<String>()
    return commands.filter { cmd in
      let key = "\(cmd.machineID):\(cmd.provider.rawValue):\(cmd.nativeSession)"
      return seen.insert(key).inserted
    }
  }

  /// 校验 restore argv 安全性：不含 shell 元字符、不含控制字符。
  public static func validateArgv(_ argv: [String]) -> Bool {
    let forbidden = CharacterSet.controlCharacters
    return argv.allSatisfy { arg in
      !arg.isEmpty &&
      arg.utf8.count <= 4096 &&
      !arg.unicodeScalars.contains(where: { forbidden.contains($0) })
    }
  }
}
