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
  #expect(AgentProvider.detect(executablePath: "codex-helper") == nil)

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
}

@Test func providerCapabilitiesMatchNativeAgentSupport() {
  #expect(AgentProvider.allCases.count == 7)
  #expect(AgentProvider.codex.capabilities.contains(.lifecycleMonitoring))
  #expect(AgentProvider.codex.capabilities.contains(.history))
  #expect(AgentProvider.codex.capabilities.contains(.resumeSession))
  #expect(AgentProvider.codex.capabilities.contains(.forkSession))
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
