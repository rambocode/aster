import Foundation
import Testing

@testable import Aster

// skill 目录归 Agent 所有、可能已有用户手写的同名 skill。这组测试锁定：
// 只接管带标记的目录、符号链接一律拒绝、内容变化即过期、原子替换不留临时目录。

/// 临时 HOME + 一个假的 skill 源目录（SKILL.md + 一个附属文件）。
private struct SkillFixture {
  let root: URL
  let home: String
  let source: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aster-skill-install-\(UUID().uuidString)", isDirectory: true)
    home = root.appendingPathComponent("home", isDirectory: true).path
    source = root.appendingPathComponent("Resources/skills/aster", isDirectory: true)
    try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
    try Data("---\nname: aster\n---\nv1\n".utf8).write(to: source.appendingPathComponent("SKILL.md"))
    try Data("helper\n".utf8).write(to: source.appendingPathComponent("extra.txt"))
  }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

@Test("安装复制整个目录并写入版本标记，两种 Agent 落到各自的 skills 目录")
func skillInstallCopiesDirectoryAndMarker() throws {
  let fixture = try SkillFixture()
  defer { fixture.remove() }

  for target in AgentSkillInstallService.Target.allCases {
    let destination = try AgentSkillInstallService.install(
      for: target, home: fixture.home, source: fixture.source, version: "1.2.3")
    #expect(destination.path == fixture.home + "/" + target.skillsRoot + "/aster")
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("SKILL.md").path))
    #expect(FileManager.default.fileExists(atPath: destination.appendingPathComponent("extra.txt").path))
    let marker = try JSONDecoder().decode(
      AgentSkillInstallService.Marker.self,
      from: try Data(contentsOf: destination.appendingPathComponent(".aster-skill-version")))
    #expect(marker.version == "1.2.3")
    #expect(marker == (try AgentSkillInstallService.expectedMarker(source: fixture.source, version: "1.2.3")))
    #expect(
      AgentSkillInstallService.state(
        for: target, home: fixture.home, source: fixture.source, version: "1.2.3")
        == .installed(version: "1.2.3"))
  }
}

@Test("SKILL.md 内容或 App 版本变化后状态为 outdated，重装后恢复 installed 且无临时目录残留")
func skillInstallDetectsOutdated() throws {
  let fixture = try SkillFixture()
  defer { fixture.remove() }
  try AgentSkillInstallService.install(
    for: .claudeCode, home: fixture.home, source: fixture.source, version: "1.0.0")

  #expect(
    AgentSkillInstallService.state(
      for: .claudeCode, home: fixture.home, source: fixture.source, version: "1.1.0")
      == .outdated(installed: "1.0.0", expected: "1.1.0"))

  try Data("v2\n".utf8).write(to: fixture.source.appendingPathComponent("SKILL.md"))
  #expect(
    AgentSkillInstallService.state(
      for: .claudeCode, home: fixture.home, source: fixture.source, version: "1.0.0")
      == .outdated(installed: "1.0.0", expected: "1.0.0"))

  let destination = try AgentSkillInstallService.install(
    for: .claudeCode, home: fixture.home, source: fixture.source, version: "1.0.0")
  #expect(try String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8) == "v2\n")
  let siblings = try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path)
  #expect(siblings == ["aster"])
}

@Test("没有标记的同名目录视为 foreign：安装与卸载都拒绝，内容原样保留")
func skillInstallRefusesForeignDirectory() throws {
  let fixture = try SkillFixture()
  defer { fixture.remove() }
  let destination = AgentSkillInstallService.destination(for: .codex, home: fixture.home)
  try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
  try Data("mine\n".utf8).write(to: destination.appendingPathComponent("SKILL.md"))

  #expect(
    AgentSkillInstallService.state(for: .codex, home: fixture.home, source: fixture.source, version: "1")
      == .foreign(path: destination.path))
  #expect(throws: AgentSkillInstallService.ServiceError.foreignDestination(destination.path)) {
    try AgentSkillInstallService.install(for: .codex, home: fixture.home, source: fixture.source, version: "1")
  }
  #expect(throws: AgentSkillInstallService.ServiceError.foreignDestination(destination.path)) {
    try AgentSkillInstallService.uninstall(for: .codex, home: fixture.home)
  }
  #expect(try String(contentsOf: destination.appendingPathComponent("SKILL.md"), encoding: .utf8) == "mine\n")
}

@Test("目标是符号链接时一律视为 foreign，即使它指向我们自己安装的目录")
func skillInstallRejectsSymlinkDestination() throws {
  let fixture = try SkillFixture()
  defer { fixture.remove() }
  let real = try AgentSkillInstallService.install(
    for: .claudeCode, home: fixture.home, source: fixture.source, version: "1")
  let link = AgentSkillInstallService.destination(for: .codex, home: fixture.home)
  try FileManager.default.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

  #expect(
    AgentSkillInstallService.state(for: .codex, home: fixture.home, source: fixture.source, version: "1")
      == .foreign(path: link.path))
  #expect(throws: AgentSkillInstallService.ServiceError.foreignDestination(link.path)) {
    try AgentSkillInstallService.install(for: .codex, home: fixture.home, source: fixture.source, version: "1")
  }
}

@Test("卸载只删除带标记的目录；未安装时卸载是无操作")
func skillUninstallRemovesOwnedDirectoryOnly() throws {
  let fixture = try SkillFixture()
  defer { fixture.remove() }
  let destination = try AgentSkillInstallService.install(
    for: .claudeCode, home: fixture.home, source: fixture.source, version: "1")
  try AgentSkillInstallService.uninstall(for: .claudeCode, home: fixture.home)
  #expect(!FileManager.default.fileExists(atPath: destination.path))
  #expect(
    AgentSkillInstallService.state(for: .claudeCode, home: fixture.home, source: fixture.source, version: "1")
      == .notInstalled)
  try AgentSkillInstallService.uninstall(for: .claudeCode, home: fixture.home)
}

@Test("源资源缺失时安装返回明确错误")
func skillInstallReportsMissingSource() throws {
  let fixture = try SkillFixture()
  defer { fixture.remove() }
  let missing = fixture.root.appendingPathComponent("nowhere", isDirectory: true)
  #expect(throws: AgentSkillInstallService.ServiceError.sourceNotFound) {
    try AgentSkillInstallService.install(for: .codex, home: fixture.home, source: missing, version: "1")
  }
}
