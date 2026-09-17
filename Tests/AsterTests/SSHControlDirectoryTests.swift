import Foundation
import Testing

@testable import Aster

/// ControlMaster 目录准备：创建 0700、拒绝符号链接与过宽权限。
/// 属主校验无法在无 root 的测试里构造他人属主目录，由代码审查保证。

private func scratchPath(_ prefix: String) -> String {
  "/tmp/aster-cm-test-\(prefix)-\(UInt32.random(in: 0...999_999))"
}

@Test func sshControlDirectoryCreatesPrivateDirectory() throws {
  let path = scratchPath("new")
  defer { try? FileManager.default.removeItem(atPath: path) }

  #expect(SSHControlDirectory.prepare(path: path) == path)
  let attributes = try FileManager.default.attributesOfItem(atPath: path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.int16Value == 0o700)
}

@Test func sshControlDirectoryAcceptsExistingPrivateDirectory() throws {
  let path = scratchPath("existing")
  defer { try? FileManager.default.removeItem(atPath: path) }
  try FileManager.default.createDirectory(
    atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

  #expect(SSHControlDirectory.prepare(path: path) == path)
}

@Test func sshControlDirectoryRejectsSymlink() throws {
  let path = scratchPath("symlink")
  let target = scratchPath("symlink-target")
  defer {
    try? FileManager.default.removeItem(atPath: path)
    try? FileManager.default.removeItem(atPath: target)
  }
  try FileManager.default.createDirectory(
    atPath: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
  try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target)

  // 指向别处的诱饵不能被接受，也不能被删除或改写。
  #expect(SSHControlDirectory.prepare(path: path) == nil)
  #expect(FileManager.default.fileExists(atPath: target))
}

@Test func sshControlDirectoryRejectsLoosePermissions() throws {
  let path = scratchPath("loose")
  defer { try? FileManager.default.removeItem(atPath: path) }
  try FileManager.default.createDirectory(
    atPath: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])

  #expect(SSHControlDirectory.prepare(path: path) == nil)
}

@Test func sshControlDirectoryRejectsRegularFile() throws {
  let path = scratchPath("file")
  defer { try? FileManager.default.removeItem(atPath: path) }
  #expect(FileManager.default.createFile(atPath: path, contents: Data()))

  #expect(SSHControlDirectory.prepare(path: path) == nil)
}

@Test func sshControlDirectoryRejectsPathOutsidePolicy() {
  #expect(SSHControlDirectory.prepare(path: NSTemporaryDirectory() + "aster-cm") == nil)
}

@Test func sshControlDirectoryDefaultPathCarriesUID() {
  #expect(SSHControlDirectory.defaultPath == "/tmp/aster-cm-\(getuid())")
}
