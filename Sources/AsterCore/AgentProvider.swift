import Foundation

/// Otty 深度集成的代码 Agent。该类型只描述 provider 的静态领域能力，既不查找
/// 可执行文件，也不读取或改写用户配置。
///
/// rawValue 会写入用户配置与 hook 载荷，发布后不可更改；新 case 一律追加在末尾，
/// 设置页按 `allCases` 顺序展示。
public enum AgentProvider: String, CaseIterable, Codable, Equatable, Sendable {
  case claudeCode
  case codex
  case openCode
  case cursorCLI
  case kimiCode
  case pi
  case omp
  case grokBuild
  // 以下 provider 只有屏幕检测清单，没有 Aster hook 集成。
  case gemini
  case githubCopilot = "copilot"
  case amp
  case droid
  case devin
  case kiro = "kiro-cli"
  case qoder = "qodercli"
  case qwen
  case hermes
  case antigravity = "agy"
  case maki
  case muse
  case cline
  case kilo

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
    case .grokBuild: "grok"
    case .gemini: "gemini"
    case .githubCopilot: "copilot"
    case .amp: "amp"
    case .droid: "droid"
    case .devin: "devin"
    case .kiro: "kiro-cli"
    case .qoder: "qodercli"
    case .qwen: "qwen"
    case .hermes: "hermes"
    case .antigravity: "agy"
    case .maki: "maki"
    case .muse: "muse"
    case .cline: "cline"
    case .kilo: "kilo"
    }
  }

  /// 面向用户的产品名；只用于展示，不参与命令拼装或 provider 检测。
  public var displayName: String {
    switch self {
    case .claudeCode: "Claude Code"
    case .codex: "Codex"
    case .openCode: "OpenCode"
    case .cursorCLI: "Cursor CLI"
    case .kimiCode: "Kimi Code"
    case .pi: "Pi"
    case .omp: "omp"
    case .grokBuild: "Grok Build"
    case .gemini: "Gemini CLI"
    case .githubCopilot: "GitHub Copilot CLI"
    case .amp: "Amp"
    case .droid: "Droid"
    case .devin: "Devin CLI"
    case .kiro: "Kiro CLI"
    case .qoder: "Qoder CLI"
    case .qwen: "Qwen Code"
    case .hermes: "Hermes"
    case .antigravity: "Antigravity CLI"
    case .maki: "Maki"
    case .muse: "Muse"
    case .cline: "Cline"
    case .kilo: "Kilo Code"
    }
  }

  /// herdr 屏幕检测清单 id；没有清单的 provider（omp）返回 nil。
  public var detectionManifestID: String? {
    switch self {
    case .claudeCode: "claude"
    case .codex: "codex"
    case .openCode: "opencode"
    case .cursorCLI: "cursor"
    case .kimiCode: "kimi"
    case .pi: "pi"
    case .omp: nil
    case .grokBuild: "grok"
    case .gemini: "gemini"
    case .githubCopilot: "copilot"
    case .amp: "amp"
    case .droid: "droid"
    case .devin: "devin"
    case .kiro: "kiro"
    case .qoder: "qodercli"
    case .qwen: "qwen"
    case .hermes: "hermes"
    case .antigravity: "agy"
    case .maki: "maki"
    case .muse: "muse"
    case .cline: "cline"
    case .kilo: "kilo"
    }
  }

  /// provider 支持的 Aster 能力集合。有 hook 集成的旧 provider 拥有生命周期、历史与
  /// 续接能力；仅有屏幕检测清单的 provider 只声明 `.screenDetection`。
  public var capabilities: AgentProviderCapabilities {
    var capabilities: AgentProviderCapabilities = []
    if supportsManagedIntegration {
      capabilities.formUnion([.lifecycleMonitoring, .history, .resumeSession])
      if self != .cursorCLI, self != .kimiCode {
        capabilities.insert(.forkSession)
      }
    }
    if detectionManifestID != nil {
      capabilities.insert(.screenDetection)
    }
    // 对应 herdr `full_lifecycle_hook_authority`：这些 provider 的 hook 覆盖完整生命周期，
    // hook 权威后可以停止屏幕轮询。
    if [.openCode, .pi, .omp, .kimiCode].contains(self) {
      capabilities.insert(.fullLifecycleHooks)
    }
    return capabilities
  }

  /// 是否存在 Aster 受管 hook/plugin/extension 集成；无集成的 provider 只能靠屏幕检测。
  public var supportsManagedIntegration: Bool {
    installationStep != nil
  }

  /// 可执行文件别名表（全部小写），照抄 herdr `lookup_agent`；`detect(executablePath:)`
  /// 先做规范化再查表，因此这里不列 `.exe`/`.cmd` 之类的后缀变体。
  ///
  /// 风险：`pi`、`amp`、`muse`、`droid`、`cline`、`kilo` 等裸词与普通命令可能重名，
  /// 误判会让普通 pane 被当成 Agent 并启动屏幕检测。它们仍保留，因为就是各 provider
  /// 的官方 commandName（与 herdr 一致）；但有明确冲突的 `cursor`（Cursor 编辑器启动器，
  /// `cursor .` 极常见）不收，Cursor agent 只认 `agent`/`cursor-agent`。
  public var executableAliases: [String] {
    switch self {
    case .claudeCode: ["claude", "claude-code"]
    case .codex: ["codex"]
    case .openCode: ["opencode", "opencode2", "open-code"]
    case .cursorCLI: ["agent", "cursor-agent"]
    case .kimiCode: ["kimi", "kimi-code", "kimi code"]
    case .pi: ["pi"]
    case .omp: ["omp"]
    case .grokBuild: ["grok", "grok-build"]
    case .gemini: ["gemini"]
    case .githubCopilot: ["copilot", "github-copilot", "ghcs"]
    case .amp: ["amp", "amp-local"]
    case .droid: ["droid"]
    case .devin: ["devin", "devin-cli", "devin cli"]
    case .kiro: ["kiro", "kiro-cli"]
    case .qoder: ["qodercli", "qoderclicn", "qoder", "qodercn"]
    case .qwen: ["qwen", "qwen-code", "qwen code"]
    case .hermes: ["hermes", "hermes-agent"]
    case .antigravity: ["agy", "antigravity", "antigravity-cli"]
    case .maki: ["maki"]
    case .muse: ["muse", "muse-code", "muse-cli"]
    case .cline: ["cline"]
    case .kilo: ["kilo", "kilo-code", "kilo code"]
    }
  }

  /// 按可执行文件最后一个路径分量匹配别名表（大小写不敏感，忽略 `.exe/.cmd/.bat/.ps1/.js`
  /// 后缀），避免把 `codex-helper` 之类的普通子进程误识别为 Agent。PATH 查找和符号
  /// 链接解析属于基础设施层职责。
  public static func detect(executablePath: String) -> AgentProvider? {
    let name = AgentExecutableNameNormalizer.normalizedLookupName(AgentExecutableNameNormalizer.basename(executablePath))
    guard !name.isEmpty else { return nil }
    if let provider = allCases.first(where: { $0.executableAliases.contains(name) }) {
      return provider
    }
    return AgentExecutableNameNormalizer.isMuseVersionedBinary(name) ? .muse : nil
  }

  /// 从完整 argv 识别 Agent。argv[0] 是通用运行时或 shell（node/bun/python/sh/cmd/
  /// powershell）时按对应运行时的参数规则解包被包裹的脚本；tmux 不穿透；其余情况
  /// 直接按 argv[0] 识别。
  public static func detect(commandTokens: [String]) -> AgentProvider? {
    guard let executable = commandTokens.first else { return nil }
    let runtime = AgentExecutableNameNormalizer.normalizedLookupName(
      AgentExecutableNameNormalizer.basename(executable))
    if AgentExecutableNameNormalizer.isGenericRuntimeOrShell(runtime) {
      return AgentWrappedCommandDetector.wrappedProvider(runtime: runtime, argv: commandTokens)
    }
    return detect(executablePath: executable)
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
    // Pi/omp 通过 extension 上报真实 session path；Grok 的 ~/.grok/sessions 尚未接入
    // History。官方契约未承诺固定历史根目录时，不能仅凭看似合理的本地路径推断 provider。
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
  /// 有 herdr 屏幕检测清单，可通过读屏推断任务状态。
  public static let screenDetection = AgentProviderCapabilities(rawValue: 1 << 4)
  /// hook 覆盖完整生命周期（对应 herdr `full_lifecycle_hook_authority`），hook 权威后
  /// 屏幕检测可以停止。
  public static let fullLifecycleHooks = AgentProviderCapabilities(rawValue: 1 << 5)
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
  /// nil 表示该 provider 没有受管 statusLine（用量上报）；true/false 表示是否已指向 Aster 包装器。
  public let managedStatusLineInstalled: Bool?

  public init(
    executableAvailable: Bool,
    managedIntegrationInstalled: Bool,
    requiredFeatureEnabled: Bool? = nil,
    managedStatusLineInstalled: Bool? = nil
  ) {
    self.executableAvailable = executableAvailable
    self.managedIntegrationInstalled = managedIntegrationInstalled
    self.requiredFeatureEnabled = requiredFeatureEnabled
    self.managedStatusLineInstalled = managedStatusLineInstalled
  }
}

/// setup 步骤是语义操作而不是替换文件或执行 shell 的指令。基础设施实现必须把
/// `mergeManagedHooks` 限定为 Otty 自有键，把 managed artifact 写入独立文件。
public enum AgentSetupStep: Equatable, Sendable {
  case mergeManagedHooks(path: String, format: AgentConfigurationFormat)
  /// 启用 provider 的 `[features]` 开关；基础设施层同时负责清理 Aster 旧版本写入的
  /// 同名顶层布尔值，避免该值与当前 provider 的结构化配置表发生类型冲突。
  case enableFeature(path: String, key: String)
  case installManagedArtifact(directory: String, kind: AgentManagedArtifactKind)
  /// 把 provider 的 statusLine 命令替换成 Aster 包装器以上报用量；原值备份到 `sideFile`，
  /// 卸载时恢复。Claude 热读 statusLine，该步骤不需要重启 Agent。
  case manageStatusLine(path: String, sideFile: String)

  /// 只有 statusLine 步骤时 Agent 无需重启。
  public var requiresAgentRestart: Bool {
    if case .manageStatusLine = self { return false }
    return true
  }
}

public enum AgentSetupBlocker: Equatable, Sendable {
  case executableUnavailable(command: String)
  /// provider 没有 Aster 受管集成可安装，只能依赖屏幕检测。
  case integrationUnavailable
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

    // 没有 hook 集成的 provider 无步骤可做；用 blocker 说明原因而不是静默返回空计划。
    guard let installationStep = provider.installationStep else {
      return AgentSetupPlan(
        provider: provider,
        steps: [],
        blocker: .integrationUnavailable,
        requiresAgentRestart: false,
        linksAfterNextLifecycleEvent: false
      )
    }

    var steps: [AgentSetupStep] = []
    if !evidence.managedIntegrationInstalled {
      steps.append(installationStep)
    }
    if provider == .codex, evidence.requiredFeatureEnabled != true {
      steps.append(.enableFeature(path: "~/.codex/config.toml", key: "hooks"))
    }
    // `== false` 而不是 `!= true`：nil 表示该 provider 不适用 statusLine 上报。
    if provider == .claudeCode, evidence.managedStatusLineInstalled == false {
      steps.append(.manageStatusLine(
        path: AgentProvider.claudeStatusLineSettingsPath,
        sideFile: AgentProvider.claudeStatusLineSideFilePath))
    }

    return AgentSetupPlan(
      provider: provider,
      steps: steps,
      blocker: nil,
      requiresAgentRestart: steps.contains(where: \.requiresAgentRestart),
      linksAfterNextLifecycleEvent: provider.linksOnLifecycleEvent && !steps.isEmpty
    )
  }
}

extension AgentProvider {
  /// Claude Code 的 statusLine 所在设置文件，以及 Aster 备份原 statusLine 的 side file。
  public static let claudeStatusLineSettingsPath = "~/.claude/settings.json"
  public static let claudeStatusLineSideFilePath =
    "~/Library/Application Support/Aster/agent-integration/claude-statusline.json"

  /// Aster 受管集成的安装步骤；只有屏幕检测清单的 provider 返回 nil。
  fileprivate var installationStep: AgentSetupStep? {
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
    case .grokBuild:
      // Grok 只把用户级 hook 当作 Claude 兼容层来读，装进 ~/.claude/settings.json。
      .mergeManagedHooks(path: "~/.claude/settings.json", format: .json)
    case .gemini, .githubCopilot, .amp, .droid, .devin, .kiro, .qoder, .qwen, .hermes,
      .antigravity, .maki, .muse, .cline, .kilo:
      nil
    }
  }

  /// plugin/extension provider 要等下一次生命周期事件才把 pane 与 session 关联。
  fileprivate var linksOnLifecycleEvent: Bool {
    switch self {
    case .openCode, .pi, .omp: true
    case .claudeCode, .codex, .cursorCLI, .kimiCode, .grokBuild,
      .gemini, .githubCopilot, .amp, .droid, .devin, .kiro, .qoder, .qwen, .hermes,
      .antigravity, .maki, .muse, .cline, .kilo:
      false
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
  /// provider 没有原生 resume 命令（通常是仅屏幕检测的 provider）。
  case resumeUnsupported(provider: AgentProvider)
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
    try plan(
      continuation,
      sessionID: session.id,
      configuration: session.configuration,
      launchPrefix: launchPrefix
    )
  }

  /// 为已经绑定到当前终端 Pane 的实时会话规划原生 Resume/Fork 命令。实时 lifecycle
  /// 只保证提供 provider 与 session ID，不要求先扫描 transcript 文件；因此菜单动作
  /// 不能为了构造 `AgentSessionMetadata` 而伪造历史路径或时间戳。
  public static func plan(
    _ continuation: AgentContinuationKind,
    sessionID: String,
    configuration: AgentSessionConfiguration,
    launchPrefix: AgentLaunchPrefix? = nil
  ) throws -> AgentNativeCommandPlan {
    let provider = configuration.provider
    if !provider.capabilities.contains(.resumeSession) {
      throw AgentSessionPlanError.resumeUnsupported(provider: provider)
    }
    if continuation == .fork, !provider.capabilities.contains(.forkSession) {
      throw AgentSessionPlanError.forkUnsupported(provider: provider)
    }
    guard !sessionID.isEmpty,
      sessionID.utf8.count <= AgentLaunchPrefix.maximumComponentBytes,
      !sessionID.contains("\0")
    else { throw AgentSessionPlanError.invalidSessionIdentifier }

    let prefix = try launchPrefix ?? AgentLaunchPrefix(executable: provider.commandName)
    let nativeArguments = provider.arguments(for: continuation, sessionID: sessionID)
    return AgentNativeCommandPlan(
      executable: prefix.executable,
      arguments: prefix.arguments + nativeArguments,
      continuation: continuation,
      sessionID: sessionID,
      preservedConfiguration: configuration
    )
  }
}

extension AgentProvider {
  fileprivate func arguments(for continuation: AgentContinuationKind, sessionID: String) -> [String]
  {
    switch (self, continuation) {
    case (.claudeCode, .resume), (.grokBuild, .resume): ["--resume", sessionID]
    case (.claudeCode, .fork), (.grokBuild, .fork): ["--resume", sessionID, "--fork-session"]
    case (.codex, .resume): ["resume", sessionID]
    case (.codex, .fork): ["fork", sessionID]
    case (.openCode, .resume): ["--session", sessionID]
    case (.openCode, .fork): ["--fork", "--session", sessionID]
    case (.cursorCLI, .resume): ["--resume", sessionID]
    case (.kimiCode, .resume): ["--session", sessionID]
    case (.pi, .resume), (.omp, .resume): ["--session", sessionID]
    case (.pi, .fork), (.omp, .fork): ["--fork", sessionID]
    case (.cursorCLI, .fork), (.kimiCode, .fork): []
    // 仅屏幕检测的 provider 没有 resume 能力，Planner 在此之前已经抛出 resumeUnsupported。
    case (.gemini, _), (.githubCopilot, _), (.amp, _), (.droid, _), (.devin, _), (.kiro, _),
      (.qoder, _), (.qwen, _), (.hermes, _), (.antigravity, _), (.maki, _), (.muse, _),
      (.cline, _), (.kilo, _):
      []
    }
  }
}
