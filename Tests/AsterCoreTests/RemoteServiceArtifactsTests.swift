import Foundation
import Testing

@testable import AsterCore

/// 远端服务产物目录：文件头识别、包内清单选择与 `ASTER_REMOTE_BINARY` 覆盖。

private func elfHeader(machine: UInt16) -> Data {
  var bytes = [UInt8](repeating: 0, count: 64)
  bytes[0] = 0x7f; bytes[1] = 0x45; bytes[2] = 0x4c; bytes[3] = 0x46
  bytes[4] = 2  // 64 位
  bytes[5] = 1  // 小端
  bytes[18] = UInt8(machine & 0xff)
  bytes[19] = UInt8(machine >> 8)
  return Data(bytes)
}

private func machOHeader(cpuType: UInt32) -> Data {
  var bytes = [UInt8](repeating: 0, count: 64)
  bytes[0] = 0xcf; bytes[1] = 0xfa; bytes[2] = 0xed; bytes[3] = 0xfe
  bytes[4] = UInt8(cpuType & 0xff)
  bytes[5] = UInt8((cpuType >> 8) & 0xff)
  bytes[6] = UInt8((cpuType >> 16) & 0xff)
  bytes[7] = UInt8((cpuType >> 24) & 0xff)
  return Data(bytes)
}

private func temporaryDirectory() -> URL {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("aster-remote-service-\(UUID().uuidString)", isDirectory: true)
  try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@Test func remoteBinaryFormatDetectsElfAndMachO() {
  #expect(
    RemoteBinaryFormat.detect(header: elfHeader(machine: 0x3E))
      == .init(platform: "linux", architecture: "x86_64"))
  #expect(
    RemoteBinaryFormat.detect(header: elfHeader(machine: 0xB7))
      == .init(platform: "linux", architecture: "arm64"))
  #expect(
    RemoteBinaryFormat.detect(header: machOHeader(cpuType: 0x0100_000C))
      == .init(platform: "macos", architecture: "arm64"))
  #expect(
    RemoteBinaryFormat.detect(header: machOHeader(cpuType: 0x0100_0007))
      == .init(platform: "macos", architecture: "x86_64"))
  #expect(RemoteBinaryFormat.detect(header: Data("#!/bin/sh\necho hi\n".utf8)) == nil)
  #expect(RemoteBinaryFormat.detect(header: Data([0x7f, 0x45])) == nil)
}

@Test func remoteServiceCatalogPicksBundledArtifactByPlatform() throws {
  let root = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appendingPathComponent("linux-x86_64", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let binary = directory.appendingPathComponent("aster-session")
  try elfHeader(machine: 0x3E).write(to: binary)
  let manifest = RemoteReleaseManifest(
    version: "1.2.3", platform: "linux", architecture: "x86_64",
    sha256: String(repeating: "0a", count: 32), sizeBytes: 64,
    artifactKind: .developmentBuild, protocolMajor: 1)
  try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"))

  let catalog = RemoteServiceArtifactCatalog(bundledDirectory: root, environment: [:])
  let found = try catalog.artifact(forPlatform: "linux", architecture: "x86_64")
  #expect(found?.localPath == binary.path)
  #expect(found?.manifest == manifest)
  // 没有对应目录：明确 nil，而不是拿别的平台凑数。
  #expect(try catalog.artifact(forPlatform: "linux", architecture: "arm64") == nil)
  #expect(try catalog.artifact(forPlatform: "macos", architecture: "arm64") == nil)
}

@Test func remoteServiceCatalogRejectsBundledManifestDeclaringAnotherPlatform() throws {
  let root = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let directory = root.appendingPathComponent("linux-arm64", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  try elfHeader(machine: 0xB7).write(to: directory.appendingPathComponent("aster-session"))
  let wrong = RemoteReleaseManifest(
    version: "1.2.3", platform: "linux", architecture: "x86_64",
    sha256: String(repeating: "0a", count: 32), sizeBytes: 64, artifactKind: .developmentBuild)
  try JSONEncoder().encode(wrong).write(to: directory.appendingPathComponent("manifest.json"))
  let catalog = RemoteServiceArtifactCatalog(bundledDirectory: root, environment: [:])
  #expect(throws: RemoteServiceArtifactError.self) {
    try catalog.artifact(forPlatform: "linux", architecture: "arm64")
  }
}

@Test func remoteServiceCatalogOverrideBuildsDevelopmentManifestFromBinary() throws {
  let root = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let binary = root.appendingPathComponent("custom-aster-session")
  let bytes = elfHeader(machine: 0x3E)
  try bytes.write(to: binary)
  let catalog = RemoteServiceArtifactCatalog(
    bundledDirectory: nil, environment: ["ASTER_REMOTE_BINARY": binary.path])

  let artifact = try #require(try catalog.artifact(forPlatform: "linux", architecture: "x86_64"))
  #expect(artifact.localPath == binary.path)
  #expect(artifact.manifest.artifactKind == .developmentBuild)
  #expect(artifact.manifest.platform == "linux")
  #expect(artifact.manifest.architecture == "x86_64")
  #expect(artifact.manifest.sizeBytes == bytes.count)
  #expect(RemoteInstallValidation.isLowercaseHexDigest(artifact.manifest.sha256))
  // 版本化目录名按摘要区分，不同构建不会互相覆盖。
  #expect(artifact.manifest.version == "dev-" + artifact.manifest.sha256.prefix(12))
  #expect(artifact.manifest.signature == nil)

  // 平台不符必须在任何上传之前拒绝，并说清两边是什么。
  #expect(throws: RemoteServiceArtifactError.overridePlatformMismatch(
    expected: "linux/arm64", actual: "linux/x86_64")) {
    try catalog.artifact(forPlatform: "linux", architecture: "arm64")
  }
}

@Test func remoteServiceCatalogOverrideRejectsUnreadableOrUnknownFiles() throws {
  let root = temporaryDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let missing = RemoteServiceArtifactCatalog(
    bundledDirectory: nil, environment: ["ASTER_REMOTE_BINARY": root.path + "/nope"])
  #expect(throws: RemoteServiceArtifactError.overrideUnreadable(root.path + "/nope")) {
    try missing.artifact(forPlatform: "linux", architecture: "x86_64")
  }
  let script = root.appendingPathComponent("script")
  try Data("#!/bin/sh\nexit 0\n".utf8).write(to: script)
  let unknown = RemoteServiceArtifactCatalog(
    bundledDirectory: nil, environment: ["ASTER_REMOTE_BINARY": script.path])
  #expect(throws: RemoteServiceArtifactError.overrideUnrecognized(script.path)) {
    try unknown.artifact(forPlatform: "linux", architecture: "x86_64")
  }
}
