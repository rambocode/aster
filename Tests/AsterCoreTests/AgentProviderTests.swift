import Foundation
import Testing

@testable import AsterCore

@Test func providerDetectionUsesExactExecutableNamesAndTrustedSessionRoots() {
  let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

  #expect(AgentProvider.detect(executablePath: "/opt/homebrew/bin/claude") == .claudeCode)
  #expect(AgentProvider.detect(executablePath: "codex") == .codex)
  #expect(AgentProvider.detect(executablePath: "/usr/local/bin/opencode") == .openCode)
  #expect(AgentProvider.detect(executablePath: "agent") == .cursorCLI)
  #expect(AgentProvider.detect(executablePath: "kimi") == .kimiCode)
  #expect(AgentProvider.detect(executablePath: "pi") == .pi)
  #expect(AgentProvider.detect(executablePath: "omp") == .omp)
  #expect(AgentProvider.detect(executablePath: "grok") == .grokBuild)
  #expect(AgentProvider.detect(executablePath: "/Users/tester/.local/bin/grok") == .grokBuild)
  #expect(AgentProvider.detect(executablePath: "codex-helper") == nil)
  #expect(AgentProvider.detect(executablePath: "/tmp/my-codex-helper") == nil)

  #expect(
    AgentProvider.detect(
      sessionFileURL: home.appendingPathComponent(".codex/sessions/2026/08/08/a.jsonl"),
      homeDirectory: home
    ) == .codex
  )
  #expect(
    AgentProvider.detect(
      sessionFileURL: home.appendingPathComponent("Downloads/a.jsonl"),
      homeDirectory: home
    ) == nil
  )
  #expect(
    AgentProvider.detect(
      sessionFileURL: URL(fileURLWithPath: "/Users/other/.codex/sessions/a.jsonl"),
      homeDirectory: home
    ) == nil
  )
  #expect(
    AgentProvider.detect(
      sessionFileURL: home.appendingPathComponent(
        ".grok/sessions/Users-tester-project/abc/updates.jsonl"),
      homeDirectory: home
    ) == nil
  )
}

@Test func providerDetectionAcceptsHerdrAliasesAndNormalizesExecutableNames() {
  let cases: [(String, AgentProvider?)] = [
    ("claude-code", .claudeCode),
    ("CLAUDE", .claudeCode),
    // `cursor` 是 Cursor 编辑器启动器（`cursor .`），不能当成 Cursor agent。
    ("cursor", nil),
    ("cursor-agent", .cursorCLI),
    ("cursor-agent.cmd", .cursorCLI),
    ("opencode.exe", .openCode),
    ("opencode2", .openCode),
    ("open-code", .openCode),
    ("Kimi Code", .kimiCode),
    ("grok-build", .grokBuild),
    ("gemini", .gemini),
    ("copilot", .githubCopilot),
    ("ghcs", .githubCopilot),
    ("/nix/store/example/bin/ghcs", .githubCopilot),
    ("github-copilot", .githubCopilot),
    ("amp-local", .amp),
    ("droid", .droid),
    ("devin-cli", .devin),
    ("kiro", .kiro),
    ("kiro-cli", .kiro),
    ("qoder", .qoder),
    ("qoderclicn", .qoder),
    ("qwen-code", .qwen),
    ("hermes-agent", .hermes),
    ("agy", .antigravity),
    ("antigravity-cli", .antigravity),
    ("maki", .maki),
    ("muse", .muse),
    ("muse-cli", .muse),
    ("muse-bin-0.1.0-R708.1", .muse),
    ("/opt/muse/releases/muse-bin-0.1.0-R708.1", .muse),
    ("cline", .cline),
    ("kilo-code", .kilo),
    ("codex.js", .codex),
    ("claude.ps1", .claudeCode),
    ("pi.bat", .pi),
    ("muse-binary", nil),
    ("muse-bin", nil),
    ("muse-bin-", nil),
    ("museum", nil),
    ("musescore", nil),
    ("node", nil),
    ("bash", nil),
    ("vim", nil),
    ("", nil),
  ]
  for (name, expected) in cases {
    #expect(AgentProvider.detect(executablePath: name) == expected, "\(name)")
  }

  for provider in AgentProvider.allCases {
    #expect(provider.executableAliases.contains(provider.commandName), "\(provider)")
    #expect(AgentProvider.detect(executablePath: provider.commandName) == provider)
  }
}

@Test func providerDetectionUnwrapsRuntimeAndShellWrappers() {
  let cases: [([String], AgentProvider?)] = [
    // 非运行时：直接按 argv[0] 识别。
    (["/opt/homebrew/bin/claude", "--resume", "x"], .claudeCode),
    (["codex"], .codex),
    // node/bun 脚本路径。
    (["node", "/home/user/.fnm/bin/qwen"], .qwen),
    (
      ["node.exe", #"C:\Users\user\AppData\Roaming\npm\node_modules\@qwen-code\qwen-code\dist\index.js"#],
      .qwen
    ),
    (
      ["node.exe", #"C:\Users\herdr\AppData\Roaming\npm\node_modules\@earendil-works\pi-coding-agent\dist\cli.js"#],
      .pi
    ),
    (
      ["node.exe", #"C:\Users\herdr\AppData\Roaming\npm\node_modules\@earendil-works\pi-coding-agent\scripts\build.js"#],
      nil
    ),
    (["node", "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js"], .claudeCode),
    (["node", "--import", "tsx", "/usr/local/lib/node_modules/@openai/codex/bin/codex.js"], .codex),
    (["bun", "/home/can/.bun/bin/omp"], .omp),
    (["bun", "--", "/home/can/.bun/bin/omp"], .omp),
    // Windows 版 Cursor：node.exe 与 index.js 同目录且位于 cursor-agent/versions/<v>/。
    (
      [
        #"C:\Users\user\AppData\Local\cursor-agent\versions\2026.08.11-e8db854\node.exe"#,
        #"C:\Users\user\AppData\Local\cursor-agent\versions\2026.08.11-e8db854\index.js"#,
      ],
      .cursorCLI
    ),
    (
      [
        #"C:\Users\user\AppData\Local\cursor-agent\versions\2026.08.11-e8db854\node.exe"#,
        #"C:\Users\user\AppData\Local\cursor-agent\versions\2026.08.11-e8db854\scripts\postinstall.js"#,
      ],
      nil
    ),
    // shell / python 脚本路径。
    (["/bin/sh", "/tmp/test-bin/pi"], .pi),
    (["python3", "/tmp/codex", "--model", "gpt-5"], .codex),
    (["python3.12", "/tmp/hermes"], .hermes),
    // eval/-c 形式一律忽略，后续位置参数不能当脚本。
    (["python3", "-c", "import time; time.sleep(60)", "/tmp/codex"], nil),
    (["python3", "-m", "codex"], nil),
    (["node", "-e", "setTimeout(() => {}, 60000)", "/tmp/codex"], nil),
    (["node", "--eval=1", "/tmp/codex"], nil),
    (["bash", "-c", "sleep 60", "/tmp/codex"], nil),
    (["bash", "-lc"], nil),
    // tmux 不穿透。
    (["tmux", "new", "-s", "work", "claude"], nil),
    // Windows cmd / powershell。
    (["cmd.exe", "/d", "/c", #""C:\tools\codex.cmd" --help"#], .codex),
    (["powershell.exe", "-NoProfile", "-File", #"C:\tools\claude.ps1"#], .claudeCode),
    (["pwsh", "-EncodedCommand", "AAAA"], nil),
    ([], nil),
  ]
  for (tokens, expected) in cases {
    #expect(AgentProvider.detect(commandTokens: tokens) == expected, "\(tokens)")
  }
}

@Test func providerCapabilitiesMatchNativeAgentSupport() {
  #expect(AgentProvider.allCases.count == 22)
  #expect(
    Array(AgentProvider.allCases.prefix(8)) == [
      .claudeCode, .codex, .openCode, .cursorCLI, .kimiCode, .pi, .omp, .grokBuild,
    ]
  )
  #expect(AgentProvider.githubCopilot.rawValue == "copilot")
  #expect(AgentProvider.kiro.rawValue == "kiro-cli")
  #expect(AgentProvider.qoder.rawValue == "qodercli")
  #expect(AgentProvider.antigravity.rawValue == "agy")
  #expect(AgentProvider.omp.detectionManifestID == nil)
  #expect(AgentProvider.cursorCLI.detectionManifestID == "cursor")
  #expect(AgentProvider.kiro.detectionManifestID == "kiro")
  #expect(!AgentProvider.omp.capabilities.contains(.screenDetection))
  #expect(AgentProvider.claudeCode.capabilities.contains(.screenDetection))
  #expect(AgentProvider.gemini.capabilities.contains(.screenDetection))
  #expect(AgentProvider.pi.capabilities.contains(.fullLifecycleHooks))
  #expect(AgentProvider.omp.capabilities.contains(.fullLifecycleHooks))
  #expect(!AgentProvider.claudeCode.capabilities.contains(.fullLifecycleHooks))
  #expect(!AgentProvider.kilo.capabilities.contains(.fullLifecycleHooks))
  #expect(AgentProvider.gemini.capabilities == [.screenDetection])
  #expect(!AgentProvider.gemini.supportsManagedIntegration)
  #expect(AgentProvider.grokBuild.supportsManagedIntegration)
  for provider in AgentProvider.allCases {
    #expect(provider.detectionManifestID != nil || provider == .omp)
    #expect(provider.capabilities.contains(.screenDetection) == (provider.detectionManifestID != nil))
    #expect(provider.capabilities.contains(.resumeSession) == provider.supportsManagedIntegration)
  }
  #expect(AgentProvider.codex.capabilities.contains(.lifecycleMonitoring))
  #expect(AgentProvider.codex.capabilities.contains(.history))
  #expect(AgentProvider.codex.capabilities.contains(.resumeSession))
  #expect(AgentProvider.codex.capabilities.contains(.forkSession))
  #expect(AgentProvider.grokBuild.capabilities.contains(.forkSession))
  #expect(AgentProvider.grokBuild.commandName == "grok")
  #expect(!AgentProvider.cursorCLI.capabilities.contains(.forkSession))
  #expect(!AgentProvider.kimiCode.capabilities.contains(.forkSession))
}

@Test func setupPlannerOnlyAddsMissingManagedIntegrationPieces() {
  let missing = AgentSetupPlanner.plan(
    for: .codex,
    evidence: AgentSetupEvidence(
      executableAvailable: true,
      managedIntegrationInstalled: false,
      requiredFeatureEnabled: false
    )
  )
  #expect(
    missing.steps == [
      .mergeManagedHooks(path: "~/.codex/hooks.json", format: .json),
      .enableFeature(path: "~/.codex/config.toml", key: "hooks"),
    ]
  )
  #expect(missing.requiresAgentRestart)
  #expect(missing.blocker == nil)

  let onlyFeatureMissing = AgentSetupPlanner.plan(
    for: .codex,
    evidence: AgentSetupEvidence(
      executableAvailable: true,
      managedIntegrationInstalled: true,
      requiredFeatureEnabled: false
    )
  )
  #expect(
    onlyFeatureMissing.steps == [
      .enableFeature(path: "~/.codex/config.toml", key: "hooks")
    ]
  )

  let complete = AgentSetupPlanner.plan(
    for: .codex,
    evidence: AgentSetupEvidence(
      executableAvailable: true,
      managedIntegrationInstalled: true,
      requiredFeatureEnabled: true
    )
  )
  #expect(complete.steps.isEmpty)
  #expect(!complete.requiresAgentRestart)
}

@Test func setupPlannerBlocksWithoutAnExecutableAndNeverSuggestsReplacementWrites() {
  let plan = AgentSetupPlanner.plan(
    for: .openCode,
    evidence: AgentSetupEvidence(
      executableAvailable: false,
      managedIntegrationInstalled: false
    )
  )

  #expect(plan.steps.isEmpty)
  #expect(plan.blocker == .executableUnavailable(command: "opencode"))
  #expect(!plan.requiresAgentRestart)

  let available = AgentSetupPlanner.plan(
    for: .openCode,
    evidence: AgentSetupEvidence(
      executableAvailable: true,
      managedIntegrationInstalled: false
    )
  )
  #expect(
    available.steps == [
      .installManagedArtifact(
        directory: "~/.config/opencode/plugins", kind: .plugin)
    ]
  )
  #expect(available.linksAfterNextLifecycleEvent)

  let grok = AgentSetupPlanner.plan(
    for: .grokBuild,
    evidence: AgentSetupEvidence(
      executableAvailable: true,
      managedIntegrationInstalled: false
    )
  )
  #expect(
    grok.steps == [
      .mergeManagedHooks(path: "~/.claude/settings.json", format: .json)
    ]
  )
  #expect(!grok.linksAfterNextLifecycleEvent)
}

@Test func setupPlannerReportsIntegrationUnavailableForScreenOnlyProviders() {
  let available = AgentSetupPlanner.plan(
    for: .gemini,
    evidence: AgentSetupEvidence(executableAvailable: true, managedIntegrationInstalled: false)
  )
  #expect(available.steps.isEmpty)
  #expect(available.blocker == .integrationUnavailable)
  #expect(!available.requiresAgentRestart)
  #expect(!available.linksAfterNextLifecycleEvent)

  // 可执行文件缺失优先于集成不可用，设置页先提示安装 CLI。
  let missing = AgentSetupPlanner.plan(
    for: .kiro,
    evidence: AgentSetupEvidence(executableAvailable: false, managedIntegrationInstalled: false)
  )
  #expect(missing.blocker == .executableUnavailable(command: "kiro-cli"))
}

@Test func nativeContinuationPlansPreserveConfigurationAndKeepSessionIDAsOneArgument() throws {
  let configuration = AgentSessionConfiguration(
    provider: .codex,
    providerIdentifier: "openai",
    model: "gpt-5.4",
    systemPrompt: "Keep changes focused."
  )
  let metadata = AgentSessionMetadata(
    id: "session; rm -rf /",
    configuration: configuration,
    projectDirectory: "/tmp/project",
    title: "Review",
    createdAt: Date(timeIntervalSince1970: 10),
    updatedAt: Date(timeIntervalSince1970: 20),
    transcriptFileURL: URL(fileURLWithPath: "/tmp/session.jsonl")
  )
  let prefix = try AgentLaunchPrefix(
    executable: "/opt/homebrew/bin/codex",
    arguments: ["--profile", "work"]
  )

  let plan = try AgentSessionCommandPlanner.plan(
    .fork,
    session: metadata,
    launchPrefix: prefix
  )

  #expect(plan.executable == "/opt/homebrew/bin/codex")
  #expect(plan.arguments == ["--profile", "work", "fork", "session; rm -rf /"])
  #expect(plan.preservedConfiguration == configuration)
  #expect(plan.arguments.last == metadata.id)
}

@Test func nativeContinuationArgumentsMatchEverySupportedProvider() throws {
  let cases: [(AgentProvider, AgentContinuationKind, [String])] = [
    (.claudeCode, .resume, ["--resume", "s1"]),
    (.claudeCode, .fork, ["--resume", "s1", "--fork-session"]),
    (.codex, .resume, ["resume", "s1"]),
    (.codex, .fork, ["fork", "s1"]),
    (.openCode, .resume, ["--session", "s1"]),
    (.openCode, .fork, ["--fork", "--session", "s1"]),
    (.cursorCLI, .resume, ["--resume", "s1"]),
    (.kimiCode, .resume, ["--session", "s1"]),
    (.pi, .resume, ["--session", "s1"]),
    (.pi, .fork, ["--fork", "s1"]),
    (.omp, .resume, ["--session", "s1"]),
    (.omp, .fork, ["--fork", "s1"]),
    (.grokBuild, .resume, ["--resume", "s1"]),
    (.grokBuild, .fork, ["--resume", "s1", "--fork-session"]),
  ]

  for (provider, kind, expectedArguments) in cases {
    let metadata = AgentSessionMetadata.stub(id: "s1", provider: provider)
    let plan = try AgentSessionCommandPlanner.plan(kind, session: metadata)
    #expect(plan.arguments == expectedArguments)
  }

  #expect(throws: AgentSessionPlanError.forkUnsupported(provider: .cursorCLI)) {
    try AgentSessionCommandPlanner.plan(
      .fork,
      session: AgentSessionMetadata.stub(id: "s1", provider: .cursorCLI)
    )
  }
  for provider in AgentProvider.allCases where !provider.supportsManagedIntegration {
    #expect(throws: AgentSessionPlanError.resumeUnsupported(provider: provider)) {
      try AgentSessionCommandPlanner.plan(
        .resume,
        session: AgentSessionMetadata.stub(id: "s1", provider: provider)
      )
    }
  }
}

@Test func liveSessionContinuationDoesNotRequireSyntheticHistoryMetadata() throws {
  let configuration = AgentSessionConfiguration(
    provider: .claudeCode,
    providerIdentifier: "anthropic",
    model: "opus"
  )

  let plan = try AgentSessionCommandPlanner.plan(
    .fork,
    sessionID: "live-session-1",
    configuration: configuration
  )

  #expect(plan.arguments == ["--resume", "live-session-1", "--fork-session"])
  #expect(plan.preservedConfiguration == configuration)
}

extension AgentSessionMetadata {
  fileprivate static func stub(id: String, provider: AgentProvider) -> AgentSessionMetadata {
    AgentSessionMetadata(
      id: id,
      configuration: AgentSessionConfiguration(provider: provider),
      projectDirectory: "/tmp/project",
      title: "Session",
      createdAt: Date(timeIntervalSince1970: 0),
      updatedAt: Date(timeIntervalSince1970: 1),
      transcriptFileURL: URL(fileURLWithPath: "/tmp/session.jsonl")
    )
  }
}
