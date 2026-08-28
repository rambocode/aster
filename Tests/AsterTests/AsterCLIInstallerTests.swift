import Foundation
import Testing

@testable import Aster

// `aster` 命令现在是指向 App 内 aster-cli 的 symlink。这组测试锁定：
// 目录选择与回退、symlink 原子替换、旧 sh 脚本被识别并覆盖、来历不明文件被拒绝、卸载只删自己的。

/// 临时根目录 + 假的 aster-cli 可执行文件 + 两个候选 bin 目录（都在临时根下，不碰真实 PATH）。
private struct InstallerFixture {
  let root: URL
  let executable: URL
  let primary: String
  let fallback: String

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("aster-cli-install-\(UUID().uuidString)", isDirectory: true)
    let bundle = root.appendingPathComponent("Aster.app/Contents/MacOS", isDirectory: true)
    try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
    executable = bundle.appendingPathComponent("aster-cli")
    try Data("#!/bin/sh\n".utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    primary = root.appendingPathComponent("usr-local-bin").path
    fallback = root.appendingPathComponent("home/.local/bin").path
  }

  var directories: [String] { [primary, fallback] }

  func remove() { try? FileManager.default.removeItem(at: root) }
}

/// 读 symlink 目标。
private func linkDestination(_ path: String) throws -> String {
  try FileManager.default.destinationOfSymbolicLink(atPath: path)
}

@Test("首选目录可写时安装到首选目录，状态为 installed")
func cliInstallerUsesPrimaryDirectory() throws {
  let fixture = try InstallerFixture()
  defer { fixture.remove() }
  try FileManager.default.createDirectory(atPath: fixture.primary, withIntermediateDirectories: true)

  let path = try AsterCLIInstaller.install(
    directories: fixture.directories, executableURL: fixture.executable)
  #expect(path == fixture.primary + "/aster")
  #expect(try linkDestination(path) == fixture.executable.standardizedFileURL.path)
  #expect(
    AsterCLIInstaller.state(directories: fixture.directories, executableURL: fixture.executable)
      == .installed(path: path))
}

@Test("首选目录不存在时回退到用户目录并自动创建")
func cliInstallerFallsBackToUserDirectory() throws {
  let fixture = try InstallerFixture()
  defer { fixture.remove() }

  let path = try AsterCLIInstaller.install(
    directories: fixture.directories, executableURL: fixture.executable)
  #expect(path == fixture.fallback + "/aster")
  #expect(FileManager.default.fileExists(atPath: fixture.fallback))
}

@Test("symlink 指向别处时状态为 outdated，重新安装原地修复")
func cliInstallerRepairsOutdatedLink() throws {
  let fixture = try InstallerFixture()
  defer { fixture.remove() }
  try FileManager.default.createDirectory(atPath: fixture.primary, withIntermediateDirectories: true)
  let path = fixture.primary + "/aster"
  try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: "/nonexistent/aster-cli")

  let before = AsterCLIInstaller.state(directories: fixture.directories, executableURL: fixture.executable)
  #expect(before == .outdated(path: path, expected: fixture.executable.standardizedFileURL.path))

  #expect(try AsterCLIInstaller.install(directories: fixture.directories, executableURL: fixture.executable) == path)
  #expect(try linkDestination(path) == fixture.executable.standardizedFileURL.path)
  // 临时链接不能残留在目录里。
  let leftovers = try FileManager.default.contentsOfDirectory(atPath: fixture.primary)
  #expect(leftovers == ["aster"])
}

@Test("旧版 sh 启动器被识别为 legacyScript，安装时被 symlink 覆盖")
func cliInstallerReplacesLegacyScript() throws {
  let fixture = try InstallerFixture()
  defer { fixture.remove() }
  try FileManager.default.createDirectory(atPath: fixture.primary, withIntermediateDirectories: true)
  let path = fixture.primary + "/aster"
  try AsterCLIScript.contents.write(toFile: path, atomically: true, encoding: .utf8)

  #expect(
    AsterCLIInstaller.state(directories: fixture.directories, executableURL: fixture.executable)
      == .legacyScript(path: path))
  try AsterCLIInstaller.install(directories: fixture.directories, executableURL: fixture.executable)
  #expect(try linkDestination(path) == fixture.executable.standardizedFileURL.path)
}

@Test("来历不明的普通文件不被覆盖，状态报 notInstalled 但安装报错")
func cliInstallerRefusesForeignFile() throws {
  let fixture = try InstallerFixture()
  defer { fixture.remove() }
  try FileManager.default.createDirectory(atPath: fixture.primary, withIntermediateDirectories: true)
  let path = fixture.primary + "/aster"
  try Data("#!/bin/sh\necho mine\n".utf8).write(to: URL(fileURLWithPath: path))

  #expect(
    AsterCLIInstaller.state(directories: fixture.directories, executableURL: fixture.executable)
      == .notInstalled)
  #expect(throws: AsterCLIInstaller.ServiceError.foreignTarget(path)) {
    try AsterCLIInstaller.install(directories: fixture.directories, executableURL: fixture.executable)
  }
  #expect(try String(contentsOfFile: path, encoding: .utf8).contains("echo mine"))
}

@Test("卸载只删除指向 aster-cli 的链接与旧脚本，保留用户自己的 aster")
func cliInstallerUninstallLeavesForeignAlone() throws {
  let fixture = try InstallerFixture()
  defer { fixture.remove() }
  try FileManager.default.createDirectory(atPath: fixture.primary, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(atPath: fixture.fallback, withIntermediateDirectories: true)
  let ours = fixture.primary + "/aster"
  let theirs = fixture.fallback + "/aster"
  try FileManager.default.createSymbolicLink(atPath: ours, withDestinationPath: fixture.executable.path)
  try FileManager.default.createSymbolicLink(atPath: theirs, withDestinationPath: "/usr/bin/true")

  try AsterCLIInstaller.uninstall(directories: fixture.directories)
  #expect(!FileManager.default.fileExists(atPath: ours))
  #expect(try linkDestination(theirs) == "/usr/bin/true")
  // 未安装时再卸载是无操作。
  try AsterCLIInstaller.uninstall(directories: [fixture.primary])
}

@Test("解析不到可执行文件时安装返回明确错误")
func cliInstallerReportsMissingExecutable() throws {
  let fixture = try InstallerFixture()
  defer { fixture.remove() }
  // 用一个空目录当 bundle：executableURL 为 nil，其余候选路径也都不存在，不会误命中 .build 产物。
  let bundleURL = fixture.root.appendingPathComponent("empty-bundle", isDirectory: true)
  try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
  let bundle = try #require(Bundle(url: bundleURL))
  #expect(throws: AsterCLIInstaller.ServiceError.executableNotFound) {
    try AsterCLIInstaller.install(directories: fixture.directories, executableURL: nil, bundle: bundle)
  }
}
