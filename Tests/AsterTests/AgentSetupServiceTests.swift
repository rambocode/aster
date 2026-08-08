import Darwin
import Foundation
import Testing

@testable import Aster
import AsterCore

@Test("七类 Agent 都按 Planner 完成检测与幂等安装")
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

  for provider in AgentProvider.allCases {
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

@Test("七类 Agent 卸载只移除 Aster 受管内容并保持幂等")
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

  for provider in AgentProvider.allCases {
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

  let codexConfig = try String(
    contentsOf: home.appendingPathComponent(".codex/config.toml"),
    encoding: .utf8
  )
  #expect(codexConfig.contains("hooks = true"))
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
  try "# user comment\nhooks = false\nmodel = \"gpt-user\"\n".write(
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
  #expect(codexText.contains("hooks = true"))
  #expect(!codexText.contains("hooks = false"))
  #expect(codexText.contains("model = \"gpt-user\""))
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
