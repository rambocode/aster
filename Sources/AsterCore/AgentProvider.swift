import Foundation

/// Otty 深度集成的代码 Agent。该类型只描述 provider 的静态领域能力，既不查找
/// 可执行文件，也不读取或改写用户配置。
public enum AgentProvider: String, CaseIterable, Codable, Equatable, Sendable {
  case claudeCode
  case codex
  case openCode
  case cursorCLI
  case kimiCode
  case pi
  case omp

  /// provider 的原生 CLI 名称。自定义启动前缀可以在命令规划阶段覆盖此值。
  public var commandName: String {
    switch self {
    case .claudeCode: "claude"
    case .codex: "codex"
    case .openCode: "opencode"
    case .cursorCLI: "agent"
    case .kimiCode: "kimi"
    case .pi: "pi"
    case .omp: "omp"
    }
  }

  public var capabilities: AgentProviderCapabilities {
    var capabilities: AgentProviderCapabilities = [
      .lifecycleMonitoring, .history, .resumeSession,
    ]
    if self != .cursorCLI, self != .kimiCode {
      capabilities.insert(.forkSession)
    }
    return capabilities
  }

  /// 仅按可执行文件最后一个路径分量精确匹配，避免把 `codex-helper` 之类的普通
  /// 子进程误识别为 Agent。PATH 查找和符号链接解析属于基础设施层职责。
  public static func detect(executablePath: String) -> AgentProvider? {
    let executable = URL(fileURLWithPath: executablePath).lastPathComponent
    return allCases.first { $0.commandName == executable }
  }

  /// 只识别用户主目录下已知 provider 的会话根目录。扩展名相同但位于下载目录或
  /// 其它用户目录的文件必须继续按普通 JSON/JSONL 处理，不能获得 Resume 权限。
  public static func detect(
    sessionFileURL: URL,
    homeDirectory: URL
  ) -> AgentProvider? {
    guard sessionFileURL.isFileURL, homeDirectory.isFileURL else { return nil }
    let sessionComponents = sessionFileURL.standardizedFileURL.pathComponents
    let homeComponents = homeDirectory.standardizedFileURL.pathComponents
    guard sessionComponents.count > homeComponents.count,
      sessionComponents.prefix(homeComponents.count).elementsEqual(homeComponents)
    else { return nil }

    let relative = Array(sessionComponents.dropFirst(homeComponents.count))
    let fileExtension = sessionFileURL.pathExtension.lowercased()

    if relative.count >= 4,
      relative.starts(with: [".claude", "projects"]),
      fileExtension == "jsonl"
    {
      return .claudeCode
    }
    if relative.count >= 6,
      relative.starts(with: [".codex", "sessions"]),
      isCodexDatePath(Array(relative[2...4])),
      fileExtension == "jsonl"
    {
      return .codex
    }
    if relative.count >= 7,
      relative.starts(with: [".local", "share", "opencode", "storage", "session"]),
      fileExtension == "json"
    {
      return .openCode
    }
    if relative.count >= 5,
      relative.starts(with: [".cursor", "projects"]),
      relative.dropLast().contains("agent-transcripts"),
      fileExtension == "jsonl"
    {
      return .cursorCLI
    }
    if relative.count >= 3,
      relative.starts(with: [".kimi-code", "sessions"]),
      ["json", "jsonl"].contains(fileExtension)
    {
      return .kimiCode
    }
    // Pi/omp 通过 extension 上报真实 session path；官方契约未承诺固定历史根目录，
    // 因而不能仅凭一个看似合理的本地路径推断 provider。
    return nil
  }

  private static func isCodexDatePath(_ components: [String]) -> Bool {
    guard components.count == 3 else { return false }
    let expectedLengths = [4, 2, 2]
    return zip(components, expectedLengths).allSatisfy { component, length in
      component.count == length && component.allSatisfy(\.isNumber)
    }
  }
}

public struct AgentProviderCapabilities: OptionSet, Equatable, Sendable {
  public let rawValue: Int

  public init(rawValue: Int) {
    self.rawValue = rawValue
  }

  public static let lifecycleMonitoring = AgentProviderCapabilities(rawValue: 1 << 0)
  public static let history = AgentProviderCapabilities(rawValue: 1 << 1)
  public static let resumeSession = AgentProviderCapabilities(rawValue: 1 << 2)
  public static let forkSession = AgentProviderCapabilities(rawValue: 1 << 3)
}

public enum AgentConfigurationFormat: Equatable, Sendable {
  case json
  case toml
}

public enum AgentManagedArtifactKind: Equatable, Sendable {
  case plugin
  case `extension`
}

/// setup 检测层提供的事实快照。Planner 不自行访问磁盘，因而可由安全的配置读取层
/// 区分“文件存在”和“其中确有 Otty 管理项”，避免仅凭文件存在误报已安装。
public struct AgentSetupEvidence: Equatable, Sendable {
  public let executableAvailable: Bool
  public let managedIntegrationInstalled: Bool
  public let requiredFeatureEnabled: Bool?

  public init(
    executableAvailable: Bool,
    managedIntegrationInstalled: Bool,
    requiredFeatureEnabled: Bool? = nil
  ) {
    self.executableAvailable = executableAvailable
    self.managedIntegrationInstalled = managedIntegrationInstalled
    self.requiredFeatureEnabled = requiredFeatureEnabled
  }
}

/// setup 步骤是语义操作而不是替换文件或执行 shell 的指令。基础设施实现必须把
/// `mergeManagedHooks` 限定为 Otty 自有键，把 managed artifact 写入独立文件。
public enum AgentSetupStep: Equatable, Sendable {
  case mergeManagedHooks(path: String, format: AgentConfigurationFormat)
  case setBoolean(path: String, key: String, value: Bool)
  case installManagedArtifact(directory: String, kind: AgentManagedArtifactKind)
}

public enum AgentSetupBlocker: Equatable, Sendable {
  case executableUnavailable(command: String)
}

public struct AgentSetupPlan: Equatable, Sendable {
  public let provider: AgentProvider
  public let steps: [AgentSetupStep]
  public let blocker: AgentSetupBlocker?
  public let requiresAgentRestart: Bool
  /// plugin/extension provider 只有在下一次生命周期事件（通常是发送一条消息）后才
  /// 能把当前 pane 与 session 关联起来。
  public let linksAfterNextLifecycleEvent: Bool
}

/// 生成最小增量安装计划；已存在的 managed 项不会重复写入，也不会建议覆盖用户的
/// 完整配置文件。
public enum AgentSetupPlanner {
  public static func plan(
    for provider: AgentProvider,
    evidence: AgentSetupEvidence
  ) -> AgentSetupPlan {
    guard evidence.executableAvailable else {
      return AgentSetupPlan(
        provider: provider,
        steps: [],
        blocker: .executableUnavailable(command: provider.commandName),
        requiresAgentRestart: false,
        linksAfterNextLifecycleEvent: false
      )
    }

    var steps: [AgentSetupStep] = []
    if !evidence.managedIntegrationInstalled {
      steps.append(provider.installationStep)
    }
    if provider == .codex, evidence.requiredFeatureEnabled != true {
      steps.append(.setBoolean(path: "~/.codex/config.toml", key: "hooks", value: true))
    }

    return AgentSetupPlan(
      provider: provider,
      steps: steps,
      blocker: nil,
      requiresAgentRestart: !steps.isEmpty,
      linksAfterNextLifecycleEvent: provider.linksOnLifecycleEvent && !steps.isEmpty
    )
  }
}

extension AgentProvider {
  fileprivate var installationStep: AgentSetupStep {
    switch self {
    case .claudeCode:
      .mergeManagedHooks(path: "~/.claude/settings.json", format: .json)
    case .codex:
      .mergeManagedHooks(path: "~/.codex/hooks.json", format: .json)
    case .openCode:
      .installManagedArtifact(directory: "~/.config/opencode/plugins", kind: .plugin)
    case .cursorCLI:
      .mergeManagedHooks(path: "~/.cursor/hooks.json", format: .json)
    case .kimiCode:
      .mergeManagedHooks(path: "~/.kimi-code/config.toml", format: .toml)
    case .pi:
      .installManagedArtifact(directory: "~/.pi/agent/extensions", kind: .extension)
    case .omp:
      .installManagedArtifact(directory: "~/.omp/agent/extensions", kind: .extension)
    }
  }

  fileprivate var linksOnLifecycleEvent: Bool {
    switch self {
    case .openCode, .pi, .omp: true
    case .claudeCode, .codex, .cursorCLI, .kimiCode: false
    }
  }
}

/// 会话续接必须保持的有效 Agent 配置。`providerIdentifier` 指模型服务 provider，
/// 与执行 CLI 的 `provider` 分离，避免在 fork 时只保留模型名却切换了后端。
public struct AgentSessionConfiguration: Codable, Equatable, Sendable {
  public let provider: AgentProvider
  public let providerIdentifier: String?
  public let model: String?
  public let systemPrompt: String?

  public init(
    provider: AgentProvider,
    providerIdentifier: String? = nil,
    model: String? = nil,
    systemPrompt: String? = nil
  ) {
    self.provider = provider
    self.providerIdentifier = providerIdentifier
    self.model = model
    self.systemPrompt = systemPrompt
  }
}

public enum AgentContinuationKind: Equatable, Sendable {
  case resume
  case fork
}

public enum AgentLaunchPrefixError: Error, Equatable {
  case emptyExecutable
  case tooManyArguments(maximum: Int)
  case componentTooLarge(maximumBytes: Int)
  case containsNullByte
}

/// 结构化启动前缀替代 shell command 字符串。session ID 后续会作为单独参数追加，
/// 因而其中的分号、空格或 `$()` 不会被解释为 shell 语法。
public struct AgentLaunchPrefix: Equatable, Sendable {
  public static let maximumArguments = 128
  public static let maximumComponentBytes = 4_096

  public let executable: String
  public let arguments: [String]

  public init(executable: String, arguments: [String] = []) throws {
    guard !executable.isEmpty else { throw AgentLaunchPrefixError.emptyExecutable }
    guard arguments.count <= Self.maximumArguments else {
      throw AgentLaunchPrefixError.tooManyArguments(maximum: Self.maximumArguments)
    }
    let components = [executable] + arguments
    guard components.allSatisfy({ !$0.contains("\0") }) else {
      throw AgentLaunchPrefixError.containsNullByte
    }
    guard components.allSatisfy({ $0.utf8.count <= Self.maximumComponentBytes }) else {
      throw AgentLaunchPrefixError.componentTooLarge(maximumBytes: Self.maximumComponentBytes)
    }
    self.executable = executable
    self.arguments = arguments
  }
}

public struct AgentNativeCommandPlan: Equatable, Sendable {
  public let executable: String
  public let arguments: [String]
  public let continuation: AgentContinuationKind
  public let sessionID: String
  public let preservedConfiguration: AgentSessionConfiguration
}

public enum AgentSessionPlanError: Error, Equatable {
  case forkUnsupported(provider: AgentProvider)
  case invalidSessionIdentifier
}

/// 只规划 provider 原生命令，不启动进程。fork 依赖原会话本身保存 provider/model/
/// system prompt；`preservedConfiguration` 让后续运行层可以在启动前后校验该不变量。
public enum AgentSessionCommandPlanner {
  public static func plan(
    _ continuation: AgentContinuationKind,
    session: AgentSessionMetadata,
    launchPrefix: AgentLaunchPrefix? = nil
  ) throws -> AgentNativeCommandPlan {
    let provider = session.configuration.provider
    if continuation == .fork, !provider.capabilities.contains(.forkSession) {
      throw AgentSessionPlanError.forkUnsupported(provider: provider)
    }
    guard !session.id.isEmpty,
      session.id.utf8.count <= AgentLaunchPrefix.maximumComponentBytes,
      !session.id.contains("\0")
    else { throw AgentSessionPlanError.invalidSessionIdentifier }

    let prefix = try launchPrefix ?? AgentLaunchPrefix(executable: provider.commandName)
    let nativeArguments = provider.arguments(for: continuation, sessionID: session.id)
    return AgentNativeCommandPlan(
      executable: prefix.executable,
      arguments: prefix.arguments + nativeArguments,
      continuation: continuation,
      sessionID: session.id,
      preservedConfiguration: session.configuration
    )
  }
}

extension AgentProvider {
  fileprivate func arguments(for continuation: AgentContinuationKind, sessionID: String) -> [String]
  {
    switch (self, continuation) {
    case (.claudeCode, .resume): ["--resume", sessionID]
    case (.claudeCode, .fork): ["--resume", sessionID, "--fork-session"]
    case (.codex, .resume): ["resume", sessionID]
    case (.codex, .fork): ["fork", sessionID]
    case (.openCode, .resume): ["--session", sessionID]
    case (.openCode, .fork): ["--fork", "--session", sessionID]
    case (.cursorCLI, .resume): ["--resume", sessionID]
    case (.kimiCode, .resume): ["--session", sessionID]
    case (.pi, .resume), (.omp, .resume): ["--session", sessionID]
    case (.pi, .fork), (.omp, .fork): ["--fork", sessionID]
    case (.cursorCLI, .fork), (.kimiCode, .fork): []
    }
  }
}
