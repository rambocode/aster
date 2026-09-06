import Darwin
import Foundation
import Testing

@testable import Aster
import AsterCore

@Test("全部内置 Agent 都按 Planner 完成检测与幂等安装")
func agentSetupInstallsEveryPlannedProviderIdempotently() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-agent-setup-all")
  defer { try? FileManager.default.removeItem(at: root) }
  let home = root.appendingPathComponent("home", isDirectory: true)
  let bin = root.appendingPathComponent("bin", isDirectory: true)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  for provider in AgentProvider.allCases {
    try makeExecutable(named: provider.commandName, in: bin)
  }
  let service = AgentSetupService(
    homeDirectory: home,
    executableSearchDirectories: [bin]
  )

  // 仅屏幕检测的 provider 没有集成可装：状态为未集成、无步骤、blocker 说明原因，
  // install/uninstall 都是无操作且幂等。
  for provider in AgentProvider.allCases where !provider.supportsManagedIntegration {
    let status = try service.status(for: provider)
    #expect(status.executableAvailable)
    #expect(!status.managedIntegrationInstalled)
    #expect(status.requiredFeatureEnabled == nil)
    #expect(!status.integrationInstalled)
    #expect(status.plan.steps.isEmpty)
    #expect(status.plan.blocker == .integrationUnavailable)
    #expect(try service.install(provider) == status)
    #expect(try service.uninstall(provider) == status)
  }

  for provider in AgentProvider.allCases where provider.supportsManagedIntegration {
    let before = try service.status(for: provider)
    #expect(before.executableAvailable)
    #expect(!before.integrationInstalled)
    #expect(!before.plan.steps.isEmpty)

    let installed = try service.install(provider)
    #expect(installed.integrationInstalled)
    #expect(installed.plan.steps.isEmpty)

    let installedAgain = try service.install(provider)
    #expect(installedAgain == installed)
  }

  let kimiConfig = try String(
    contentsOf: home.appendingPathComponent(".kimi-code/config.toml"),
    encoding: .utf8
  )
  #expect(
    kimiConfig.components(separatedBy: AgentSetupService.managedTOMLStartMarker).count == 2
  )
}

@Test("全部内置 Agent 卸载只移除 Aster 受管内容并保持幂等")
func agentSetupUninstallsManagedContentWithoutRemovingUserConfiguration() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-agent-uninstall-all")
  defer { try? FileManager.default.removeItem(at: root) }
  let home = root.appendingPathComponent("home", isDirectory: true)
  let bin = root.appendingPathComponent("bin", isDirectory: true)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  for provider in AgentProvider.allCases {
    try makeExecutable(named: provider.commandName, in: bin)
  }
  let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
  try FileManager.default.createDirectory(at: claudeDirectory, withIntermediateDirectories: true)
  let claudeSettings = claudeDirectory.appendingPathComponent("settings.json")
  try "{\"theme\":\"user-dark\",\"hooks\":{\"Stop\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"user-stop\"}]}]}}"
    .write(to: claudeSettings, atomically: true, encoding: .utf8)
  let service = AgentSetupService(
    homeDirectory: home,
    executableSearchDirectories: [bin]
  )

  for provider in AgentProvider.allCases where provider.supportsManagedIntegration {
    #expect(try service.install(provider).managedIntegrationInstalled)
    let uninstalled = try service.uninstall(provider)
    #expect(!uninstalled.managedIntegrationInstalled)
    #expect(!uninstalled.integrationInstalled)
    #expect(try service.uninstall(provider) == uninstalled)
  }

  let decoded = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: claudeSettings)) as? [String: Any]
  )
  #expect(decoded["theme"] as? String == "user-dark")
  let hooks = try #require(decoded["hooks"] as? [String: Any])
  let stop = try #require(hooks["Stop"] as? [[String: Any]])
  let userCommands = try #require(stop.first?["hooks"] as? [[String: Any]])
  #expect(userCommands.first?["command"] as? String == "user-stop")

  // Codex hooks 默认启用；安装和卸载都不应仅为默认值创建 config.toml。
  #expect(!FileManager.default.fileExists(
    atPath: home.appendingPathComponent(".codex/config.toml").path
  ))
  for path in [
    ".config/opencode/plugins/\(AgentSetupService.managedArtifactFileName)",
    ".pi/agent/extensions/\(AgentSetupService.managedArtifactFileName)",
    ".omp/agent/extensions/\(AgentSetupService.managedArtifactFileName)",
  ] {
    #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(path).path))
  }
}

@Test("JSON Hook 安装只写 Aster managed 键并保留用户配置")
func agentSetupPreservesUserJSONConfiguration() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-agent-setup-json")
  defer { try? FileManager.default.removeItem(at: root) }
  let home = root.appendingPathComponent("home", isDirectory: true)
  let bin = root.appendingPathComponent("bin", isDirectory: true)
  try FileManager.default.createDirectory(
    at: home.appendingPathComponent(".claude", isDirectory: true),
    withIntermediateDirectories: true
  )
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  try makeExecutable(named: AgentProvider.claudeCode.commandName, in: bin)
  let settings = home.appendingPathComponent(".claude/settings.json")
  let originalUserHook: [String: Any] = [
    "matcher": "Write",
    "hooks": [["type": "command", "command": "audit-user-write"]],
  ]
  let original: [String: Any] = [
    "theme": "dark",
    "hooks": ["PreToolUse": [originalUserHook]],
  ]
  try JSONSerialization.data(withJSONObject: original, options: [.prettyPrinted])
    .write(to: settings)
  try FileManager.default.setAttributes(
    [.posixPermissions: NSNumber(value: 0o640)],
    ofItemAtPath: settings.path
  )
  let service = AgentSetupService(
    homeDirectory: home,
    executableSearchDirectories: [bin]
  )

  _ = try service.install(.claudeCode)

  let decoded = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
  )
  #expect(decoded["theme"] as? String == "dark")
  let hooks = try #require(decoded["hooks"] as? [String: Any])
  let userHooks = try #require(hooks["PreToolUse"] as? [[String: Any]])
  #expect(userHooks.first?["matcher"] as? String == "Write")
  let promptHooks = try #require(hooks["UserPromptSubmit"] as? [[String: Any]])
  let managed = try #require(promptHooks.first(where: { $0["_aster"] as? Bool == true }))
  let commands = try #require(managed["hooks"] as? [[String: Any]])
  #expect((commands.first?["command"] as? String)?.contains("processing claudeCode") == true)
  let permissionHooks = try #require(hooks["PermissionRequest"] as? [[String: Any]])
  #expect(permissionHooks.contains(where: { entry in
    let commands = entry["hooks"] as? [[String: Any]]
    return (commands?.first?["command"] as? String)?.contains("awaiting-input claudeCode") == true
  }))
  let attributes = try FileManager.default.attributesOfItem(atPath: settings.path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
}

@Test("Claude 与 Grok 共用 settings.json 时互不覆盖且可独立卸载")
func claudeAndGrokShareSettingsWithoutClobberingEachOther() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-agent-setup-claude-grok")
  defer { try? FileManager.default.removeItem(at: root) }
  let home = root.appendingPathComponent("home", isDirectory: true)
  let bin = root.appendingPathComponent("bin", isDirectory: true)
  try FileManager.default.createDirectory(
    at: home.appendingPathComponent(".claude", isDirectory: true),
    withIntermediateDirectories: true
  )
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  try makeExecutable(named: AgentProvider.claudeCode.commandName, in: bin)
  try makeExecutable(named: AgentProvider.grokBuild.commandName, in: bin)
  let settings = home.appendingPathComponent(".claude/settings.json")
  let original: [String: Any] = [
    "theme": "user-dark",
    "hooks": [
      "Stop": [
        ["hooks": [["type": "command", "command": "user-stop"]]]
      ]
    ],
  ]
  try JSONSerialization.data(withJSONObject: original, options: [.prettyPrinted])
    .write(to: settings)
  let service = AgentSetupService(
    homeDirectory: home,
    executableSearchDirectories: [bin]
  )

  #expect(try service.install(.claudeCode).integrationInstalled)
  #expect(try service.install(.grokBuild).integrationInstalled)
  #expect(try service.status(for: .claudeCode).integrationInstalled)
  #expect(try service.status(for: .grokBuild).integrationInstalled)

  let both = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
  )
  #expect(both["theme"] as? String == "user-dark")
  let bothHooks = try #require(both["hooks"] as? [String: Any])
  let stop = try #require(bothHooks["Stop"] as? [[String: Any]])
  #expect(stop.contains { $0["_asterProvider"] as? String == AgentProvider.claudeCode.rawValue })
  #expect(stop.contains { $0["_asterProvider"] as? String == AgentProvider.grokBuild.rawValue })
  #expect(stop.contains { entry in
    let commands = entry["hooks"] as? [[String: Any]]
    return commands?.first?["command"] as? String == "user-stop"
  })
  #expect(bothHooks["PermissionRequest"] != nil)
  let grokStop = try #require(
    stop.first { $0["_asterProvider"] as? String == AgentProvider.grokBuild.rawValue }
  )
  let grokCommands = try #require(grokStop["hooks"] as? [[String: Any]])
  #expect((grokCommands.first?["command"] as? String)?.contains("idle grokBuild") == true)

  let uninstalledGrok = try service.uninstall(.grokBuild)
  #expect(!uninstalledGrok.integrationInstalled)
  #expect(try service.status(for: .claudeCode).integrationInstalled)
  #expect(try service.status(for: .grokBuild).managedIntegrationInstalled == false)

  let afterGrok = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
  )
  let afterGrokHooks = try #require(afterGrok["hooks"] as? [String: Any])
  let afterGrokStop = try #require(afterGrokHooks["Stop"] as? [[String: Any]])
  #expect(
    afterGrokStop.contains { $0["_asterProvider"] as? String == AgentProvider.claudeCode.rawValue }
  )
  #expect(
    !afterGrokStop.contains { $0["_asterProvider"] as? String == AgentProvider.grokBuild.rawValue }
  )
  #expect(afterGrok["theme"] as? String == "user-dark")

  let uninstalledClaude = try service.uninstall(.claudeCode)
  #expect(!uninstalledClaude.integrationInstalled)
  let leftover = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any]
  )
  #expect(leftover["theme"] as? String == "user-dark")
  let leftoverHooks = try #require(leftover["hooks"] as? [String: Any])
  let leftoverStop = try #require(leftoverHooks["Stop"] as? [[String: Any]])
  #expect(leftoverStop.count == 1)
  let leftoverCommands = try #require(leftoverStop.first?["hooks"] as? [[String: Any]])
  #expect(leftoverCommands.first?["command"] as? String == "user-stop")
}

@Test("Codex Hook 安装保留已有 Otty lifecycle 条目")
func codexAgentSetupPreservesOttyHooks() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-agent-setup-codex-otty")
  defer { try? FileManager.default.removeItem(at: root) }
  let home = root.appendingPathComponent("home", isDirectory: true)
  let bin = root.appendingPathComponent("bin", isDirectory: true)
  let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
  try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  try makeExecutable(named: AgentProvider.codex.commandName, in: bin)
  try "[features]\nhooks = true\n".write(
    to: codexDirectory.appendingPathComponent("config.toml"),
    atomically: true,
    encoding: .utf8
  )
  let ottyEntry: [String: Any] = [
    "_otty": true,
    "hooks": [["type": "command", "command": "otty-session-start"]],
  ]
  let hooks: [String: Any] = ["hooks": ["SessionStart": [ottyEntry]]]
  let hooksURL = codexDirectory.appendingPathComponent("hooks.json")
  try JSONSerialization.data(withJSONObject: hooks, options: [.prettyPrinted]).write(to: hooksURL)
  let service = AgentSetupService(homeDirectory: home, executableSearchDirectories: [bin])

  let installed = try service.install(.codex)

  #expect(installed.integrationInstalled)
  let decoded = try #require(
    JSONSerialization.jsonObject(with: Data(contentsOf: hooksURL)) as? [String: Any]
  )
  let installedHooks = try #require(decoded["hooks"] as? [String: Any])
  let sessionStart = try #require(installedHooks["SessionStart"] as? [[String: Any]])
  #expect(sessionStart.contains { $0["_otty"] as? Bool == true })
  #expect(sessionStart.contains { $0[AgentSetupService.managedJSONKey] as? Bool == true })
}

@Test("Codex 安装迁移旧版顶层 hooks 布尔值并保留 features 配置")
func codexAgentSetupMigratesLegacyRootHooksBoolean() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-agent-setup-codex-hooks-migration")
  defer { try? FileManager.default.removeItem(at: root) }
  let home = root.appendingPathComponent("home", isDirectory: true)
  let bin = root.appendingPathComponent("bin", isDirectory: true)
  let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
  try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  try makeExecutable(named: AgentProvider.codex.commandName, in: bin)
  let config = codexDirectory.appendingPathComponent("config.toml")
  try """
    model = "gpt-user"
    hooks = true

    [features]
    hooks = true
    memories = true
    """.write(to: config, atomically: true, encoding: .utf8)
  let service = AgentSetupService(homeDirectory: home, executableSearchDirectories: [bin])

  let installed = try service.install(.codex)

  #expect(installed.integrationInstalled)
  let updated = try String(contentsOf: config, encoding: .utf8)
  #expect(!updated.hasPrefix("model = \"gpt-user\"\nhooks = true\n"))
  #expect(updated.hasPrefix("model = \"gpt-user\"\n\n[features]\n"))
  #expect(updated.contains("[features]\nhooks = true\nmemories = true"))
}

@Test("Codex 与 Kimi 的 TOML 增量保留用户字节并只更新计划键")
func agentSetupPreservesTOMLOutsideManagedValues() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-agent-setup-toml")
  defer { try? FileManager.default.removeItem(at: root) }
  let home = root.appendingPathComponent("home", isDirectory: true)
  let bin = root.appendingPathComponent("bin", isDirectory: true)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  for provider in [AgentProvider.codex, .kimiCode] {
    try makeExecutable(named: provider.commandName, in: bin)
  }
  let codexDirectory = home.appendingPathComponent(".codex", isDirectory: true)
  let kimiDirectory = home.appendingPathComponent(".kimi-code", isDirectory: true)
  try FileManager.default.createDirectory(at: codexDirectory, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: kimiDirectory, withIntermediateDirectories: true)
  let codexConfig = codexDirectory.appendingPathComponent("config.toml")
  let kimiConfig = kimiDirectory.appendingPathComponent("config.toml")
  try """
    # user comment
    model = "gpt-user"

    [features]
    hooks = false # user disabled before explicit install
    memories = true
    """.write(
    to: codexConfig,
    atomically: true,
    encoding: .utf8
  )
  try "# keep exactly\nmodel = \"kimi-user\"\n".write(
    to: kimiConfig,
    atomically: true,
    encoding: .utf8
  )
  let service = AgentSetupService(
    homeDirectory: home,
    executableSearchDirectories: [bin]
  )

  _ = try service.install(.codex)
  _ = try service.install(.kimiCode)

  let codexText = try String(contentsOf: codexConfig, encoding: .utf8)
  #expect(codexText.contains("# user comment"))
  #expect(codexText.contains("[features]\nhooks = true # user disabled before explicit install"))
  #expect(!codexText.contains("hooks = false"))
  #expect(codexText.contains("model = \"gpt-user\""))
  #expect(codexText.contains("memories = true"))
  let kimiText = try String(contentsOf: kimiConfig, encoding: .utf8)
  #expect(kimiText.hasPrefix("# keep exactly\nmodel = \"kimi-user\"\n"))
  #expect(kimiText.contains(AgentSetupService.managedTOMLStartMarker))
  #expect(kimiText.contains("event = \"UserPromptSubmit\""))
  #expect(kimiText.contains("processing kimiCode"))
}

@Test("检测和安装拒绝 symlink、FIFO 与超限配置且不改写目标")
func agentSetupRejectsUnsafeConfigurationFiles() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-agent-setup-unsafe")
  defer { try? FileManager.default.removeItem(at: root) }
  let home = root.appendingPathComponent("home", isDirectory: true)
  let bin = root.appendingPathComponent("bin", isDirectory: true)
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  for provider in [AgentProvider.claudeCode, .cursorCLI, .kimiCode] {
    try makeExecutable(named: provider.commandName, in: bin)
  }
  let external = root.appendingPathComponent("external.json")
  try "{\"keep\":true}".write(to: external, atomically: true, encoding: .utf8)
  let claudeDirectory = home.appendingPathComponent(".claude", isDirectory: true)
  let cursorDirectory = home.appendingPathComponent(".cursor", isDirectory: true)
  let kimiDirectory = home.appendingPathComponent(".kimi-code", isDirectory: true)
  for directory in [claudeDirectory, cursorDirectory, kimiDirectory] {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  let claudeSettings = claudeDirectory.appendingPathComponent("settings.json")
  try FileManager.default.createSymbolicLink(at: claudeSettings, withDestinationURL: external)
  let cursorHooks = cursorDirectory.appendingPathComponent("hooks.json")
  #expect(mkfifo(cursorHooks.path, 0o600) == 0)
  let kimiConfig = kimiDirectory.appendingPathComponent("config.toml")
  try Data(repeating: 0x61, count: AgentSetupService.maximumConfigurationBytes + 1)
    .write(to: kimiConfig)
  let service = AgentSetupService(
    homeDirectory: home,
    executableSearchDirectories: [bin]
  )

  #expect(throws: AgentSetupServiceError.unsupportedFile(claudeSettings.path)) {
    try service.status(for: .claudeCode)
  }
  #expect(throws: AgentSetupServiceError.unsupportedFile(cursorHooks.path)) {
    try service.install(.cursorCLI)
  }
  #expect(throws: AgentSetupServiceError.fileTooLarge(kimiConfig.path)) {
    try service.install(.kimiCode)
  }
  #expect(try String(contentsOf: external, encoding: .utf8) == "{\"keep\":true}")

  let linkedHome = root.appendingPathComponent("linked-home", isDirectory: true)
  try FileManager.default.createSymbolicLink(at: linkedHome, withDestinationURL: home)
  let linkedHomeService = AgentSetupService(
    homeDirectory: linkedHome,
    executableSearchDirectories: [bin]
  )
  #expect(throws: AgentSetupServiceError.unsupportedFile(linkedHome.path)) {
    try linkedHomeService.status(for: .openCode)
  }
}

@Test("独立 artifact 只覆写 Aster 自有文件并拒绝同名用户文件")
func agentSetupRefusesForeignManagedArtifact() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-agent-setup-artifact")
  defer { try? FileManager.default.removeItem(at: root) }
  let home = root.appendingPathComponent("home", isDirectory: true)
  let bin = root.appendingPathComponent("bin", isDirectory: true)
  let pluginDirectory = home.appendingPathComponent(
    ".config/opencode/plugins",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: pluginDirectory, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  try makeExecutable(named: AgentProvider.openCode.commandName, in: bin)
  let artifact = pluginDirectory.appendingPathComponent(
    AgentSetupService.managedArtifactFileName
  )
  let foreignContents = "export const UserPlugin = () => ({})\n"
  try foreignContents.write(to: artifact, atomically: true, encoding: .utf8)
  let service = AgentSetupService(
    homeDirectory: home,
    executableSearchDirectories: [bin]
  )

  #expect(throws: AgentSetupServiceError.managedEntryConflict(artifact.path)) {
    try service.install(.openCode)
  }
  #expect(try String(contentsOf: artifact, encoding: .utf8) == foreignContents)
}

@Test("PATH 中同名目录不会被误判为 Agent 可执行文件")
func agentSetupRequiresRegularExecutable() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-agent-setup-executable")
  defer { try? FileManager.default.removeItem(at: root) }
  let home = root.appendingPathComponent("home", isDirectory: true)
  let bin = root.appendingPathComponent("bin", isDirectory: true)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: bin.appendingPathComponent(AgentProvider.codex.commandName, isDirectory: true),
    withIntermediateDirectories: true
  )
  let service = AgentSetupService(
    homeDirectory: home,
    executableSearchDirectories: [bin]
  )

  let status = try service.status(for: .codex)
  #expect(!status.executableAvailable)
  #expect(status.plan.blocker == .executableUnavailable(command: "codex"))
}

@Test("GUI 精简 PATH 仍能发现用户目录与 nvm 中的 Agent CLI")
func agentSetupDiscoversCommonGUIInstallLocations() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-agent-setup-gui-path")
  defer { try? FileManager.default.removeItem(at: root) }
  let home = root.appendingPathComponent("home", isDirectory: true)
  let localBin = home.appendingPathComponent(".local/bin", isDirectory: true)
  let nvmBin = home.appendingPathComponent(
    ".nvm/versions/node/v20.19.5/bin",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: localBin, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: nvmBin, withIntermediateDirectories: true)
  try makeExecutable(named: AgentProvider.claudeCode.commandName, in: localBin)
  try makeExecutable(named: AgentProvider.openCode.commandName, in: nvmBin)
  let service = AgentSetupService(
    homeDirectory: home,
    environment: ["PATH": "/usr/bin:/bin"]
  )

  let claude = try service.status(for: .claudeCode)
  let openCode = try service.status(for: .openCode)
  #expect(claude.executablePath == localBin.appendingPathComponent("claude").path)
  #expect(openCode.executablePath == nvmBin.appendingPathComponent("opencode").path)
}

@Test("集成状态不因 CLI 暂时不可检测而丢失")
func agentSetupKeepsManagedIntegrationStatusWithoutExecutable() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-agent-setup-independent-status")
  defer { try? FileManager.default.removeItem(at: root) }
  let home = root.appendingPathComponent("home", isDirectory: true)
  let bin = root.appendingPathComponent("bin", isDirectory: true)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  let executable = bin.appendingPathComponent(AgentProvider.claudeCode.commandName)
  try makeExecutable(named: AgentProvider.claudeCode.commandName, in: bin)
  let service = AgentSetupService(
    homeDirectory: home,
    executableSearchDirectories: [bin]
  )
  #expect(try service.install(.claudeCode).integrationInstalled)

  try FileManager.default.removeItem(at: executable)

  let status = try service.status(for: .claudeCode)
  #expect(status.executablePath == nil)
  #expect(status.managedIntegrationInstalled)
  #expect(status.integrationInstalled)
}

@Test("旧 Aster TOML 区块原位升级且不移动后续用户配置")
func agentSetupReplacesManagedTOMLBlockInPlace() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-agent-setup-toml-upgrade")
  defer { try? FileManager.default.removeItem(at: root) }
  let home = root.appendingPathComponent("home", isDirectory: true)
  let bin = root.appendingPathComponent("bin", isDirectory: true)
  let directory = home.appendingPathComponent(".kimi-code", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  try makeExecutable(named: AgentProvider.kimiCode.commandName, in: bin)
  let config = directory.appendingPathComponent("config.toml")
  let staleManagedBlock = """
    \(AgentSetupService.managedTOMLStartMarker)
    [[hooks]]
    name = "aster-terminal"
    managed_by = "Aster"
    schema_version = 0
    provider = "kimiCode"
    transport = "aster-terminal"
    \(AgentSetupService.managedTOMLEndMarker)
    """
  let original = """
    model = "kimi-user"
    \(staleManagedBlock)
    [preferences]
    theme = "dark"
    """ + "\n"
  try original.write(to: config, atomically: true, encoding: .utf8)
  let service = AgentSetupService(
    homeDirectory: home,
    executableSearchDirectories: [bin]
  )

  _ = try service.install(.kimiCode)

  let updated = try String(contentsOf: config, encoding: .utf8)
  let marker = try #require(updated.range(of: AgentSetupService.managedTOMLStartMarker))
  let preferences = try #require(updated.range(of: "[preferences]"))
  #expect(marker.lowerBound < preferences.lowerBound)
  #expect(updated.hasPrefix("model = \"kimi-user\"\n"))
  #expect(updated.hasSuffix("[preferences]\ntheme = \"dark\"\n"))
  #expect(updated.contains("schema_version = 1"))
}

@Test("Agent 安装产物发送终端生命周期指令而不是仅写占位标识")
func agentSetupArtifactsEmitTerminalLifecycleSignals() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-agent-setup-runtime")
  defer { try? FileManager.default.removeItem(at: root) }
  let home = root.appendingPathComponent("home", isDirectory: true)
  let bin = root.appendingPathComponent("bin", isDirectory: true)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  for provider in [AgentProvider.openCode, .pi] {
    try makeExecutable(named: provider.commandName, in: bin)
  }
  let service = AgentSetupService(homeDirectory: home, executableSearchDirectories: [bin])

  _ = try service.install(.openCode)
  _ = try service.install(.pi)

  let openCode = try String(
    contentsOf: home.appendingPathComponent(
      ".config/opencode/plugins/\(AgentSetupService.managedArtifactFileName)"),
    encoding: .utf8
  )
  let pi = try String(
    contentsOf: home.appendingPathComponent(
      ".pi/agent/extensions/\(AgentSetupService.managedArtifactFileName)"),
    encoding: .utf8
  )
  for artifact in [openCode, pi] {
    #expect(artifact.contains("/dev/tty"))
    #expect(artifact.contains("AgentState="))
    #expect(artifact.contains("Provider="))
    #expect(artifact.contains("SessionID="))
  }
}

@Test("Codex command hook 从官方 stdin 载荷关联当前会话 ID")
func codexLifecycleHookExtractsSessionIDFromBoundedJSONInput() throws {
  let payload = """
    {"session_id":"repro-session-123","cwd":"/tmp/repro","hook_event_name":"SessionStart"}
    """
  let emitted = try runAgentLifecycleHook(payload: payload)

  #expect(emitted.contains("AgentState=idle;Provider=codex;SessionID=repro-session-123"))
}

@Test("Grok hook 只用 GROK_SESSION_ID，且在 Claude runner 下静默退出")
func grokLifecycleHookUsesInjectedSessionAndStandsDownForClaude() throws {
  let grok = try runAgentLifecycleHook(
    payload: "{\"sessionId\":\"ignored-camel-case\"}",
    provider: "grokBuild",
    environment: ["GROK_SESSION_ID": "grok-session-42", "GROK_HOOK_EVENT": "session_start"]
  )
  #expect(grok.contains("AgentState=idle;Provider=grokBuild;SessionID=grok-session-42"))

  let withoutGrokEnv = try runAgentLifecycleHook(
    payload: "{\"session_id\":\"should-not-emit\"}",
    provider: "grokBuild"
  )
  #expect(!withoutGrokEnv.contains("AgentState="))

  let claudeUnderGrok = try runAgentLifecycleHook(
    payload: "{\"session_id\":\"claude-session\"}",
    provider: "claudeCode",
    environment: ["GROK_HOOK_EVENT": "session_start", "GROK_SESSION_ID": "grok-session-42"]
  )
  #expect(!claudeUnderGrok.contains("AgentState="))
}

@Test("Agent command hook 拒绝非法或超限 session ID 载荷")
func agentLifecycleHookRejectsUnsafeSessionIDPayloads() throws {
  let invalid = try runAgentLifecycleHook(
    payload: "{\"session_id\":\"unsafe;OSC\",\"hook_event_name\":\"SessionStart\"}"
  )
  let wrongType = try runAgentLifecycleHook(
    payload: "{\"session_id\":123,\"hook_event_name\":\"SessionStart\"}"
  )
  let oversized = try runAgentLifecycleHook(
    payload: "{\"session_id\":\"must-not-pass\",\"padding\":\""
      + String(repeating: "x", count: 262_145)
      + "\"}"
  )

  #expect(invalid.contains("AgentState=idle;Provider=codex"))
  #expect(!invalid.contains("SessionID="))
  #expect(!wrongType.contains("SessionID="))
  #expect(oversized.contains("AgentState=idle;Provider=codex"))
  #expect(!oversized.contains("SessionID="))
}

/// fixture 文件模拟 Codex 关闭后的 stdin pipe；`script` 只负责提供真实伪终端，使写往
/// `/dev/tty` 的 OSC 可被捕获。这与 Aster Pane 内运行边界一致，不是只检查脚本文本。
/// 在伪终端里跑 lifecycle hook，可选覆盖 provider 与 Grok 注入的环境变量。
private func runAgentLifecycleHook(
  payload: String,
  provider: String = "codex",
  environment: [String: String] = [:]
) throws -> String {
  let hook = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("Resources/agent-integration/aster-agent-hook.sh")
  let payloadFile = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-agent-hook-payload-\(UUID().uuidString).json"
  )
  try payload.write(to: payloadFile, atomically: true, encoding: .utf8)
  defer { try? FileManager.default.removeItem(at: payloadFile) }

  let process = Process()
  let output = Pipe()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/script")
  process.arguments = [
    "-q", "/dev/null", "/bin/sh", "-c",
    "exec /bin/sh \"$1\" idle \"$3\" < \"$2\"",
    "aster-agent-hook-test", hook.path, payloadFile.path, provider,
  ]
  var processEnvironment = ProcessInfo.processInfo.environment
  processEnvironment.removeValue(forKey: "GROK_HOOK_EVENT")
  processEnvironment.removeValue(forKey: "GROK_SESSION_ID")
  for (key, value) in environment {
    processEnvironment[key] = value
  }
  process.environment = processEnvironment
  process.standardInput = FileHandle.nullDevice
  process.standardOutput = output
  process.standardError = output
  try process.run()
  process.waitUntilExit()
  let emitted = String(
    decoding: try output.fileHandleForReading.readToEnd() ?? Data(),
    as: UTF8.self
  )
  guard process.terminationStatus == 0 else {
    throw CocoaError(.executableRuntimeMismatch)
  }
  return emitted
}

private func agentSetupTemporaryDirectory(named prefix: String) throws -> URL {
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "\(prefix)-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  return directory
}

private func makeExecutable(named name: String, in directory: URL) throws {
  let executable = directory.appendingPathComponent(name)
  try "#!/bin/sh\nexit 0\n".write(to: executable, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.posixPermissions: NSNumber(value: 0o755)],
    ofItemAtPath: executable.path
  )
}

// MARK: - Claude statusLine 接管（用量上报）

@Test("接管 Claude statusLine：原值备份到 side file、包装器保留 padding、幂等；卸载恢复原值并删 side file")
func claudeStatusLineInstallBacksUpOriginalAndUninstallRestores() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-claude-statusline")
  defer { try? FileManager.default.removeItem(at: root) }
  let (home, service) = try makeClaudeSetupFixture(in: root)
  let settings = home.appendingPathComponent(".claude/settings.json")
  try #"{"theme":"dark","statusLine":{"type":"command","command":"bash ~/.claude/statusline-command.sh","padding":0}}"#
    .write(to: settings, atomically: true, encoding: .utf8)
  let sideFile = home.appendingPathComponent(
    "Library/Application Support/Aster/agent-integration/claude-statusline.json")

  let before = try service.status(for: .claudeCode)
  #expect(before.managedStatusLineInstalled == false)
  // hooks 与 statusLine 都改 settings.json：必须合并成一次写入而不是报 configurationChanged。
  #expect(before.plan.steps.count == 2)

  let installed = try service.install(.claudeCode)
  #expect(installed.integrationInstalled)
  #expect(installed.managedStatusLineInstalled == true)
  #expect(installed.plan.steps.isEmpty)
  let root1 = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
  let statusLine = try #require(root1["statusLine"] as? [String: Any])
  #expect(statusLine["type"] as? String == "command")
  #expect((statusLine["command"] as? String)?.hasSuffix("statusline claudeCode") == true)
  #expect(statusLine["padding"] as? Int == 0)
  #expect(root1["theme"] as? String == "dark")
  #expect(root1["hooks"] != nil)
  let side = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sideFile)) as? [String: Any])
  #expect(side["provider"] as? String == "claudeCode")
  #expect((side["statusLine"] as? [String: Any])?["command"] as? String == "bash ~/.claude/statusline-command.sh")

  // 幂等。
  let again = try service.install(.claudeCode)
  #expect(again == installed)
  #expect(try Data(contentsOf: sideFile) == JSONSerialization.data(withJSONObject: side, options: [.prettyPrinted, .sortedKeys]) + Data([0x0A]))

  // 卸载集成：hooks 移除 + statusLine 恢复，一次写入；side file 删除。
  let removed = try service.uninstall(.claudeCode)
  #expect(!removed.integrationInstalled)
  #expect(removed.managedStatusLineInstalled == false)
  let root2 = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
  #expect((root2["statusLine"] as? [String: Any])?["command"] as? String == "bash ~/.claude/statusline-command.sh")
  #expect(root2["hooks"] == nil)
  #expect(!FileManager.default.fileExists(atPath: sideFile.path))
}

@Test("没有原 statusLine 时 side file 记 null，只恢复 statusLine 的动作删键并保留 hooks")
func claudeStatusLineOnlyUninstallRemovesKeyAndKeepsHooks() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-claude-statusline-null")
  defer { try? FileManager.default.removeItem(at: root) }
  let (home, service) = try makeClaudeSetupFixture(in: root)
  let settings = home.appendingPathComponent(".claude/settings.json")
  let sideFile = home.appendingPathComponent(
    "Library/Application Support/Aster/agent-integration/claude-statusline.json")

  _ = try service.install(.claudeCode)
  let side = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sideFile)) as? [String: Any])
  #expect(side["statusLine"] is NSNull)

  let restored = try service.uninstallManagedStatusLine()
  #expect(restored.managedStatusLineInstalled == false)
  #expect(restored.integrationInstalled)
  let root1 = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
  #expect(root1["statusLine"] == nil)
  #expect(root1["hooks"] != nil)
  #expect(!FileManager.default.fileExists(atPath: sideFile.path))
  // 再次只装 statusLine（hooks 已装）：计划只剩一步且不要求重启。
  let plan = try service.status(for: .claudeCode).plan
  #expect(plan.steps.count == 1)
  #expect(!plan.requiresAgentRestart)
}

@Test("用户自行改掉 statusLine 后卸载不动它；Grok 卸载不触碰 Claude statusLine")
func claudeStatusLineUninstallLeavesUserReplacedValueUntouched() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-claude-statusline-user")
  defer { try? FileManager.default.removeItem(at: root) }
  let (home, service) = try makeClaudeSetupFixture(in: root)
  let settings = home.appendingPathComponent(".claude/settings.json")
  let sideFile = home.appendingPathComponent(
    "Library/Application Support/Aster/agent-integration/claude-statusline.json")
  _ = try service.install(.claudeCode)
  _ = try service.install(.grokBuild)

  _ = try service.uninstall(.grokBuild)
  #expect(try service.status(for: .claudeCode).managedStatusLineInstalled == true)
  #expect(FileManager.default.fileExists(atPath: sideFile.path))

  var root1 = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
  root1["statusLine"] = ["type": "command", "command": "my-own-statusline"]
  try JSONSerialization.data(withJSONObject: root1).write(to: settings)
  #expect(try service.status(for: .claudeCode).managedStatusLineInstalled == false)
  _ = try service.uninstall(.claudeCode)
  let root2 = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: settings)) as? [String: Any])
  #expect((root2["statusLine"] as? [String: Any])?["command"] as? String == "my-own-statusline")
  // side file 留着：用户可能还想手动找回原值。
  #expect(FileManager.default.fileExists(atPath: sideFile.path))
}

@Test("statusLine 不是对象时拒绝接管且不写任何文件")
func claudeStatusLineInstallRejectsNonObjectStatusLine() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-claude-statusline-bad")
  defer { try? FileManager.default.removeItem(at: root) }
  let (home, service) = try makeClaudeSetupFixture(in: root)
  let settings = home.appendingPathComponent(".claude/settings.json")
  try #"{"statusLine":"bash x.sh"}"#.write(to: settings, atomically: true, encoding: .utf8)
  let sideFile = home.appendingPathComponent(
    "Library/Application Support/Aster/agent-integration/claude-statusline.json")
  #expect(throws: AgentSetupServiceError.invalidConfiguration(settings.path)) {
    try service.install(.claudeCode)
  }
  #expect(try String(contentsOf: settings, encoding: .utf8) == #"{"statusLine":"bash x.sh"}"#)
  #expect(!FileManager.default.fileExists(atPath: sideFile.path))
}

@Test("statusline 子命令按 pane UUID 写用量文件并透传原命令输出，side file 缺失时输出空")
func statusLineWrapperWritesUsageFileAndPassesThroughOriginalCommand() throws {
  let root = try agentSetupTemporaryDirectory(named: "aster-statusline-script")
  defer { try? FileManager.default.removeItem(at: root) }
  let usageDirectory = root.appendingPathComponent("usage", isDirectory: true)
  try FileManager.default.createDirectory(at: usageDirectory, withIntermediateDirectories: true)
  let sideFile = root.appendingPathComponent("side.json")
  try #"{"schemaVersion":1,"provider":"claudeCode","statusLine":{"type":"command","command":"/bin/cat | /usr/bin/plutil -extract model.display_name raw -o - -"}}"#
    .write(to: sideFile, atomically: true, encoding: .utf8)
  let payload = #"{"model":{"display_name":"Opus"},"rate_limits":{"five_hour":{"used_percentage":42.5,"resets_at":1788748005}},"context_window":{"used_percentage":57.2}}"#
  let paneID = UUID()

  let output = try runStatusLineWrapper(
    payload: payload, sideFile: sideFile, usageDirectory: usageDirectory, paneID: paneID.uuidString)
  #expect(output.contains("Opus"))
  let usageFile = usageDirectory.appendingPathComponent("\(paneID.uuidString).usage")
  #expect(try String(contentsOf: usageFile, encoding: .utf8)
    == "AgentUsage=1;Provider=claudeCode;FiveHour=42:1788748005;Session=57\n")
  // 临时文件不残留。
  #expect(try FileManager.default.contentsOfDirectory(atPath: usageDirectory.path) == ["\(paneID.uuidString).usage"])

  let missing = try runStatusLineWrapper(
    payload: payload, sideFile: root.appendingPathComponent("none.json"),
    usageDirectory: usageDirectory, paneID: paneID.uuidString)
  #expect(!missing.contains("Opus"))

  // 不在 Aster 里（没有 pane UUID）或 UUID 不合法：不写文件。
  try FileManager.default.removeItem(at: usageFile)
  _ = try runStatusLineWrapper(payload: payload, sideFile: sideFile, usageDirectory: usageDirectory, paneID: "")
  _ = try runStatusLineWrapper(payload: payload, sideFile: sideFile, usageDirectory: usageDirectory, paneID: "../evil")
  #expect(try FileManager.default.contentsOfDirectory(atPath: usageDirectory.path).isEmpty)

  // 非 claudeCode provider：排空 stdin 后静默退出。
  let other = try runStatusLineWrapper(
    payload: payload, sideFile: sideFile, usageDirectory: usageDirectory, paneID: paneID.uuidString, provider: "codex")
  #expect(!other.contains("Opus"))
  #expect(try FileManager.default.contentsOfDirectory(atPath: usageDirectory.path).isEmpty)
}

/// Claude 夹具：临时 home + claude/grok 可执行文件 + 指向仓库 hook 脚本的服务。
private func makeClaudeSetupFixture(in root: URL) throws -> (URL, AgentSetupService) {
  let home = root.appendingPathComponent("home", isDirectory: true)
  let bin = root.appendingPathComponent("bin", isDirectory: true)
  try FileManager.default.createDirectory(at: home.appendingPathComponent(".claude"), withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  try makeExecutable(named: "claude", in: bin)
  try makeExecutable(named: "grok", in: bin)
  let hook = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/agent-integration/aster-agent-hook.sh")
  return (home, AgentSetupService(homeDirectory: home, executableSearchDirectories: [bin], integrationScriptURL: hook))
}

/// 像 Claude 那样在没有控制终端的环境里跑 `statusline` 子命令，只取 stdout。
private func runStatusLineWrapper(
  payload: String, sideFile: URL, usageDirectory: URL, paneID: String, provider: String = "claudeCode"
) throws -> String {
  let hook = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Resources/agent-integration/aster-agent-hook.sh")
  let payloadFile = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-statusline-payload-\(UUID().uuidString).json")
  try payload.write(to: payloadFile, atomically: true, encoding: .utf8)
  defer { try? FileManager.default.removeItem(at: payloadFile) }
  let process = Process()
  let output = Pipe()
  process.executableURL = URL(fileURLWithPath: "/bin/sh")
  process.arguments = [hook.path, "statusline", provider]
  var environment = ProcessInfo.processInfo.environment
  environment["ASTER_STATUSLINE_SIDE_FILE"] = sideFile.path
  environment["ASTER_AGENT_USAGE_DIR"] = usageDirectory.path
  environment["ASTER_SESSION_ID"] = paneID
  process.environment = environment
  process.standardInput = try FileHandle(forReadingFrom: payloadFile)
  process.standardOutput = output
  process.standardError = output
  try process.run()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { throw CocoaError(.executableRuntimeMismatch) }
  return String(decoding: try output.fileHandleForReading.readToEnd() ?? Data(), as: UTF8.self)
}
