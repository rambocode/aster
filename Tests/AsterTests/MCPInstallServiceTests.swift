import Foundation
import Testing

@testable import Aster

// `.mcp.json` 是用户的项目文件：可能已注册别的 MCP server、可能被恶意替换成符号链接。
// 这组测试锁定「只管我们那一项、原子替换、拒绝非普通文件」三条不变量。

/// 造一个临时项目目录 + 一个假的可执行文件（安装只写路径，不执行它）。
private func makeProjectFixture() throws -> (project: URL, executable: URL) {
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-mcp-install-\(UUID().uuidString)", isDirectory: true)
  let project = root.appendingPathComponent("project", isDirectory: true)
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  let executable = root.appendingPathComponent("aster-memory-mcp", isDirectory: false)
  try Data("#!/bin/sh\n".utf8).write(to: executable)
  try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
  return (project, executable)
}

/// 读回 `.mcp.json` 的根对象。
private func readConfiguration(_ project: URL) throws -> [String: Any] {
  let url = MCPInstallService.configurationURL(projectDirectory: project)
  let data = try Data(contentsOf: url)
  return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

@Test("安装写入 aster-memory 条目并保留用户已有的其它 server")
func mcpInstallPreservesExistingServers() throws {
  let fixture = try makeProjectFixture()
  defer { try? FileManager.default.removeItem(at: fixture.project.deletingLastPathComponent()) }
  let url = MCPInstallService.configurationURL(projectDirectory: fixture.project)
  let existing: [String: Any] = [
    "mcpServers": [
      "playwright": ["command": "npx", "args": ["@playwright/mcp"]]
    ],
    // 顶层未知键也必须原样保留：别的工具可能在同一文件里放配置。
    "customSetting": true,
  ]
  try JSONSerialization.data(withJSONObject: existing).write(to: url)

  let command = try MCPInstallService.install(
    projectDirectory: fixture.project, executableURL: fixture.executable)
  #expect(command == fixture.executable.standardizedFileURL.path)

  let root = try readConfiguration(fixture.project)
  #expect(root["customSetting"] as? Bool == true)
  let servers = try #require(root["mcpServers"] as? [String: Any])
  #expect(servers.count == 2)
  #expect((servers["playwright"] as? [String: Any])?["command"] as? String == "npx")
  #expect((servers["aster-memory"] as? [String: Any])?["command"] as? String == command)
}

@Test("文件不存在时安装会新建 .mcp.json，重复安装保持幂等")
func mcpInstallIsIdempotent() throws {
  let fixture = try makeProjectFixture()
  defer { try? FileManager.default.removeItem(at: fixture.project.deletingLastPathComponent()) }
  try MCPInstallService.install(
    projectDirectory: fixture.project, executableURL: fixture.executable)
  let first = try Data(
    contentsOf: MCPInstallService.configurationURL(projectDirectory: fixture.project))
  try MCPInstallService.install(
    projectDirectory: fixture.project, executableURL: fixture.executable)
  let second = try Data(
    contentsOf: MCPInstallService.configurationURL(projectDirectory: fixture.project))
  #expect(first == second)

  let state = try MCPInstallService.state(
    projectDirectory: fixture.project, executableURL: fixture.executable)
  #expect(state == .installed(commandPath: fixture.executable.standardizedFileURL.path))
}

@Test("安装保留用户在 aster-memory 条目里自加的字段")
func mcpInstallKeepsUserFieldsInOwnEntry() throws {
  let fixture = try makeProjectFixture()
  defer { try? FileManager.default.removeItem(at: fixture.project.deletingLastPathComponent()) }
  let url = MCPInstallService.configurationURL(projectDirectory: fixture.project)
  let existing: [String: Any] = [
    "mcpServers": [
      "aster-memory": ["command": "/stale/path", "env": ["ASTER_MEMORY_DIR": "/custom"]]
    ]
  ]
  try JSONSerialization.data(withJSONObject: existing).write(to: url)

  // 路径过期时状态是 outdated，UI 据此提示「修复」。
  let before = try MCPInstallService.state(
    projectDirectory: fixture.project, executableURL: fixture.executable)
  #expect(
    before
      == .outdated(
        commandPath: "/stale/path", expected: fixture.executable.standardizedFileURL.path))

  try MCPInstallService.install(
    projectDirectory: fixture.project, executableURL: fixture.executable)
  let entry = try #require(
    (try readConfiguration(fixture.project)["mcpServers"] as? [String: Any])?["aster-memory"]
      as? [String: Any])
  #expect(entry["command"] as? String == fixture.executable.standardizedFileURL.path)
  #expect((entry["env"] as? [String: Any])?["ASTER_MEMORY_DIR"] as? String == "/custom")
}

@Test("卸载只移除自己那一项，其余 server 与顶层键保持不变")
func mcpUninstallKeepsOtherServers() throws {
  let fixture = try makeProjectFixture()
  defer { try? FileManager.default.removeItem(at: fixture.project.deletingLastPathComponent()) }
  let url = MCPInstallService.configurationURL(projectDirectory: fixture.project)
  try JSONSerialization.data(
    withJSONObject: ["mcpServers": ["playwright": ["command": "npx"]]]
  ).write(to: url)
  try MCPInstallService.install(
    projectDirectory: fixture.project, executableURL: fixture.executable)

  try MCPInstallService.uninstall(projectDirectory: fixture.project)
  let servers = try #require(try readConfiguration(fixture.project)["mcpServers"] as? [String: Any])
  #expect(servers.keys.sorted() == ["playwright"])
  #expect(
    try MCPInstallService.state(
      projectDirectory: fixture.project, executableURL: fixture.executable) == .notInstalled)
}

@Test("卸载后文件只剩空的 mcpServers 时删除文件，未安装时卸载是无操作")
func mcpUninstallRemovesEmptyConfiguration() throws {
  let fixture = try makeProjectFixture()
  defer { try? FileManager.default.removeItem(at: fixture.project.deletingLastPathComponent()) }
  let url = MCPInstallService.configurationURL(projectDirectory: fixture.project)

  // 未安装时卸载不得抛错，也不得凭空创建文件。
  try MCPInstallService.uninstall(projectDirectory: fixture.project)
  #expect(FileManager.default.fileExists(atPath: url.path) == false)

  try MCPInstallService.install(
    projectDirectory: fixture.project, executableURL: fixture.executable)
  #expect(FileManager.default.fileExists(atPath: url.path))
  try MCPInstallService.uninstall(projectDirectory: fixture.project)
  #expect(FileManager.default.fileExists(atPath: url.path) == false)
}

@Test("替换文件时保留用户收紧过的权限位")
func mcpInstallPreservesFileMode() throws {
  let fixture = try makeProjectFixture()
  defer { try? FileManager.default.removeItem(at: fixture.project.deletingLastPathComponent()) }
  let url = MCPInstallService.configurationURL(projectDirectory: fixture.project)
  try Data("{}".utf8).write(to: url)
  try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)

  try MCPInstallService.install(
    projectDirectory: fixture.project, executableURL: fixture.executable)
  let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
  #expect((mode as? NSNumber)?.intValue == 0o600)
}

@Test("拒绝符号链接形态的 .mcp.json")
func mcpInstallRejectsSymbolicLink() throws {
  let fixture = try makeProjectFixture()
  defer { try? FileManager.default.removeItem(at: fixture.project.deletingLastPathComponent()) }
  let target = fixture.project.deletingLastPathComponent()
    .appendingPathComponent("elsewhere.json", isDirectory: false)
  try Data("{}".utf8).write(to: target)
  let url = MCPInstallService.configurationURL(projectDirectory: fixture.project)
  try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)

  #expect(throws: MCPInstallService.ServiceError.unsafeConfigurationFile(url.path)) {
    try MCPInstallService.install(
      projectDirectory: fixture.project, executableURL: fixture.executable)
  }
  // 被指向的文件必须原封不动。
  #expect(try Data(contentsOf: target) == Data("{}".utf8))
}

@Test("非 JSON 对象的 .mcp.json 报错而不是被覆盖")
func mcpInstallRejectsMalformedConfiguration() throws {
  let fixture = try makeProjectFixture()
  defer { try? FileManager.default.removeItem(at: fixture.project.deletingLastPathComponent()) }
  let url = MCPInstallService.configurationURL(projectDirectory: fixture.project)
  try Data("[1, 2, 3]".utf8).write(to: url)

  #expect(throws: MCPInstallService.ServiceError.malformedConfiguration(url.path)) {
    try MCPInstallService.install(
      projectDirectory: fixture.project, executableURL: fixture.executable)
  }
  #expect(try Data(contentsOf: url) == Data("[1, 2, 3]".utf8))
}

@Test("解析不到可执行文件时安装返回明确错误")
func mcpInstallReportsMissingExecutable() throws {
  let fixture = try makeProjectFixture()
  defer { try? FileManager.default.removeItem(at: fixture.project.deletingLastPathComponent()) }
  // 用一个孤立的空目录当 bundle：它的父目录与自身都没有 aster-memory-mcp。
  let isolated = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-mcp-nobundle-\(UUID().uuidString)/inner", isDirectory: true)
  try FileManager.default.createDirectory(at: isolated, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: isolated.deletingLastPathComponent()) }
  let empty = try #require(Bundle(url: isolated))
  #expect(MCPInstallService.resolveExecutableURL(bundle: empty) == nil)
  #expect(throws: MCPInstallService.ServiceError.executableNotFound) {
    try MCPInstallService.install(
      projectDirectory: fixture.project, executableURL: nil, bundle: empty)
  }
}

@Test("Codex 提示文本给出可直接粘贴的 TOML 片段")
func mcpCodexInstructions() throws {
  let fixture = try makeProjectFixture()
  defer { try? FileManager.default.removeItem(at: fixture.project.deletingLastPathComponent()) }
  let text = MCPInstallService.codexInstructions(executableURL: fixture.executable)
  #expect(text.contains("[mcp_servers.aster-memory]"))
  #expect(text.contains("command = \"\(fixture.executable.standardizedFileURL.path)\""))
  #expect(text.contains("~/.codex/config.toml"))
}
