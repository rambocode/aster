import Foundation
import Testing

@testable import AsterCore

/// P3.4：安装事务的校验顺序、原子切换命令与失败回滚。
///
/// 这些用例只覆盖纯逻辑与命令生成；真实 SSH 上传的进程证据由 P3 证据脚本产生，
/// 不用单测冒充“已在真机安装成功”。

// MARK: - 替身

/// 记录调用序列并可注入失败的 `RemoteInstallExecuting` 替身。
///
/// 用 class + 锁而不是 actor：被测协议是同步的，测试里也只在单线程使用，
/// 锁只为满足 `Sendable` 要求。
private final class FakeInstallExecutor: RemoteInstallExecuting, @unchecked Sendable {
  /// 每一步的记录：`mkdir` / `upload` / `digest` / `size` / `activate` / `rollback` 由命令内容推断。
  private(set) var commands: [[String]] = []
  private(set) var uploads: [(local: String, remote: String)] = []

  /// 远端摘要命令返回值。
  var digestOutput: String = ""
  /// 远端大小命令返回值。
  var sizeOutput: String = ""
  /// 多次复核（二进制 + 集成压缩包）时按顺序消费；空时退回单值。
  var digestOutputs: [String] = []
  var sizeOutputs: [String] = []
  /// 上传时抛出的错误；nil 表示成功。
  var uploadError: Error?
  /// 让 activate 步骤返回的 stderr（用于空间不足场景）。
  var activateStandardError: String?
  var activateExitStatus: Int32 = 0

  func runRemote(_ argv: [String]) throws -> RemoteSSHResult {
    commands.append(argv)
    let script = argv.last ?? ""
    if script.contains("sha256sum") {
      let output = digestOutputs.isEmpty ? digestOutput : digestOutputs.removeFirst()
      return RemoteSSHResult(exitStatus: 0, standardOutput: output, standardError: "")
    }
    if script.contains("wc -c") {
      let output = sizeOutputs.isEmpty ? sizeOutput : sizeOutputs.removeFirst()
      return RemoteSSHResult(exitStatus: 0, standardOutput: output, standardError: "")
    }
    if script.contains("ln -sfn") && script.contains("chmod 755") {
      return RemoteSSHResult(
        exitStatus: activateExitStatus,
        standardOutput: "",
        standardError: activateStandardError ?? "")
    }
    return RemoteSSHResult(exitStatus: 0, standardOutput: "", standardError: "")
  }

  func upload(localPath: String, remotePath: String) throws {
    if let uploadError {
      throw uploadError
    }
    uploads.append((localPath, remotePath))
  }

  /// 记录里是否出现过某一步（按命令内容的特征串判断）。
  func containsCommand(_ needle: String) -> Bool {
    commands.contains { ($0.last ?? "").contains(needle) }
  }

  /// 命令顺序的可读标签序列。
  var stepLabels: [String] {
    commands.map { argv in
      let script = argv.last ?? ""
      if script.contains("tar -xzf") { return "integration" }
      if script.contains("mkdir -p") && script.contains("umask") { return "mkdir" }
      if script.contains("sha256sum") { return "digest" }
      if script.contains("wc -c") { return "size" }
      if script.contains("chmod 755") { return "activate" }
      if script.contains("rm -f") { return "rollback" }
      return "other"
    }
  }
}

// MARK: - 样例

private let sampleDigest = String(repeating: "ab", count: 32)

private func makeManifest(
  kind: RemoteArtifactKind = .managedRelease,
  signature: String? = "sig",
  platform: String = "linux",
  architecture: String = "x86_64",
  version: String = "0.5.0",
  size: Int = 1024,
  digest: String = sampleDigest
) -> RemoteReleaseManifest {
  RemoteReleaseManifest(
    version: version,
    platform: platform,
    architecture: architecture,
    sha256: digest,
    sizeBytes: size,
    signature: signature,
    artifactKind: kind)
}

private func makePlan(
  manifest: RemoteReleaseManifest,
  existingVersion: String? = nil
) -> RemoteInstallPlan {
  RemoteInstallPlan(
    targetDescription: "orb",
    homeDirectory: "/home/mike",
    manifest: manifest,
    existingVersion: existingVersion,
    stagingID: "stage-1")
}

private func makeExecutorAndTransaction(
  manifest: RemoteReleaseManifest,
  remotePlatform: String = "linux",
  remoteArchitecture: String = "x86_64",
  acceptDevelopmentArtifact: Bool = false,
  signatureValid: Bool = true
) -> (FakeInstallExecutor, RemoteInstallTransaction) {
  let executor = FakeInstallExecutor()
  executor.digestOutput = "\(manifest.sha256)  /tmp/staging\n"
  executor.sizeOutput = "\(manifest.sizeBytes)\n"
  let transaction = RemoteInstallTransaction(
    executor: executor,
    remotePlatform: remotePlatform,
    remoteArchitecture: remoteArchitecture,
    acceptDevelopmentArtifact: acceptDevelopmentArtifact,
    signatureVerifier: { _ in signatureValid })
  return (executor, transaction)
}

/// 断言抛出的是期望的校验错误。
private func expectValidationError(
  _ expected: RemoteInstallValidationError,
  _ body: () throws -> Void
) {
  do {
    try body()
    Issue.record("expected validation error \(expected)")
  } catch let error as RemoteInstallError {
    #expect(error == .validation(expected))
  } catch {
    Issue.record("unexpected error \(error)")
  }
}

// MARK: - 用例

@Test func remoteInstallRejectsPlatformMismatchBeforeUpload() throws {
  let manifest = makeManifest(platform: "macos")
  let (executor, transaction) = makeExecutorAndTransaction(
    manifest: manifest, remotePlatform: "linux")
  expectValidationError(.platformMismatch(expected: "macos", actual: "linux")) {
    _ = try transaction.install(
      plan: makePlan(manifest: manifest),
      manifest: manifest,
      localPath: "/tmp/aster-session",
      localDigest: manifest.sha256,
      localSize: manifest.sizeBytes)
  }
  #expect(executor.uploads.isEmpty)
  #expect(executor.commands.isEmpty)
}

@Test func remoteInstallRejectsArchitectureMismatchBeforeUpload() throws {
  let manifest = makeManifest(architecture: "arm64")
  let (executor, transaction) = makeExecutorAndTransaction(
    manifest: manifest, remoteArchitecture: "x86_64")
  expectValidationError(.architectureMismatch(expected: "arm64", actual: "x86_64")) {
    _ = try transaction.install(
      plan: makePlan(manifest: manifest),
      manifest: manifest,
      localPath: "/tmp/aster-session",
      localDigest: manifest.sha256,
      localSize: manifest.sizeBytes)
  }
  #expect(executor.uploads.isEmpty)
  #expect(executor.commands.isEmpty)
}

@Test func remoteInstallDetectsRemoteDigestMismatchAndRollsBack() throws {
  let manifest = makeManifest()
  let (executor, transaction) = makeExecutorAndTransaction(manifest: manifest)
  let other = String(repeating: "cd", count: 32)
  executor.digestOutput = "\(other)  /tmp/staging\n"
  expectValidationError(.digestMismatch(expected: manifest.sha256, actual: other)) {
    _ = try transaction.install(
      plan: makePlan(manifest: manifest),
      manifest: manifest,
      localPath: "/tmp/aster-session",
      localDigest: manifest.sha256,
      localSize: manifest.sizeBytes)
  }
  #expect(executor.stepLabels.contains("rollback"))
  #expect(executor.stepLabels.contains("activate") == false)
}

@Test func remoteInstallRejectsManagedReleaseWithoutSignature() throws {
  let manifest = makeManifest(signature: nil)
  let (executor, transaction) = makeExecutorAndTransaction(manifest: manifest)
  expectValidationError(.missingSignature) {
    _ = try transaction.install(
      plan: makePlan(manifest: manifest),
      manifest: manifest,
      localPath: "/tmp/aster-session",
      localDigest: manifest.sha256,
      localSize: manifest.sizeBytes)
  }
  #expect(executor.uploads.isEmpty)
}

@Test func remoteInstallRejectsInvalidSignature() throws {
  let manifest = makeManifest()
  let (executor, transaction) = makeExecutorAndTransaction(
    manifest: manifest, signatureValid: false)
  expectValidationError(.signatureInvalid) {
    _ = try transaction.install(
      plan: makePlan(manifest: manifest),
      manifest: manifest,
      localPath: "/tmp/aster-session",
      localDigest: manifest.sha256,
      localSize: manifest.sizeBytes)
  }
  #expect(executor.uploads.isEmpty)
}

@Test func remoteInstallAcceptsUnsignedTestArtifactAndLabelsIt() throws {
  let manifest = makeManifest(kind: .testArtifact, signature: nil)
  let (_, transaction) = makeExecutorAndTransaction(manifest: manifest)
  let plan = makePlan(manifest: manifest)
  let outcome = try transaction.install(
    plan: plan,
    manifest: manifest,
    localPath: "/tmp/aster-session",
    localDigest: manifest.sha256,
    localSize: manifest.sizeBytes)
  #expect(outcome.artifactKind == .testArtifact)
  #expect(manifest.isOfficialRelease == false)
  #expect(manifest.displaySummary.contains("测试产物"))
  #expect(plan.impactSummary.contains("测试产物"))
}

@Test func remoteInstallRequiresExplicitAcceptanceForDevelopmentBuild() throws {
  let manifest = makeManifest(kind: .developmentBuild, signature: nil)
  let (executor, transaction) = makeExecutorAndTransaction(manifest: manifest)
  expectValidationError(.developmentArtifactNotAccepted) {
    _ = try transaction.install(
      plan: makePlan(manifest: manifest),
      manifest: manifest,
      localPath: "/tmp/aster-session",
      localDigest: manifest.sha256,
      localSize: manifest.sizeBytes)
  }
  #expect(executor.uploads.isEmpty)
  #expect(manifest.displaySummary.contains("开发产物，未签名"))

  let (_, accepting) = makeExecutorAndTransaction(
    manifest: manifest, acceptDevelopmentArtifact: true)
  let outcome = try accepting.install(
    plan: makePlan(manifest: manifest),
    manifest: manifest,
    localPath: "/tmp/aster-session",
    localDigest: manifest.sha256,
    localSize: manifest.sizeBytes)
  #expect(outcome.artifactKind == .developmentBuild)
}

@Test func remoteInstallUploadInterruptionRollsBackWithoutActivating() throws {
  let manifest = makeManifest()
  let (executor, transaction) = makeExecutorAndTransaction(manifest: manifest)
  executor.uploadError = RemoteSSHError(
    kind: .transportFailure, target: "orb", detail: "connection closed by remote host")
  do {
    _ = try transaction.install(
      plan: makePlan(manifest: manifest),
      manifest: manifest,
      localPath: "/tmp/aster-session",
      localDigest: manifest.sha256,
      localSize: manifest.sizeBytes)
    Issue.record("expected uploadFailed")
  } catch let error as RemoteInstallError {
    #expect(error == .uploadFailed("connection closed by remote host"))
  }
  #expect(executor.stepLabels.contains("rollback"))
  #expect(executor.stepLabels.contains("activate") == false)
}

@Test func remoteInstallClassifiesNoSpaceLeftAsInsufficientSpace() throws {
  let manifest = makeManifest()
  let (executor, transaction) = makeExecutorAndTransaction(manifest: manifest)
  executor.activateExitStatus = 1
  executor.activateStandardError = "mv: write error: No space left on device"
  do {
    _ = try transaction.install(
      plan: makePlan(manifest: manifest),
      manifest: manifest,
      localPath: "/tmp/aster-session",
      localDigest: manifest.sha256,
      localSize: manifest.sizeBytes)
    Issue.record("expected insufficientSpace")
  } catch let error as RemoteInstallError {
    #expect(error == .insufficientSpace)
  }
  #expect(executor.stepLabels.contains("rollback"))
}

@Test func remoteInstallSuccessKeepsPreviousVersionDirectory() throws {
  let manifest = makeManifest(version: "0.5.0")
  let (executor, transaction) = makeExecutorAndTransaction(manifest: manifest)
  let plan = makePlan(manifest: manifest, existingVersion: "0.4.0")
  let outcome = try transaction.install(
    plan: plan,
    manifest: manifest,
    localPath: "/tmp/aster-session",
    localDigest: manifest.sha256,
    localSize: manifest.sizeBytes)

  #expect(executor.stepLabels == ["mkdir", "digest", "size", "activate"])
  #expect(executor.uploads.count == 1)
  #expect(executor.uploads[0].remote == plan.stagingPath)
  #expect(outcome.installedPath == "/home/mike/.local/share/aster/bin/aster-session")
  #expect(outcome.versionedPath == "/home/mike/.local/share/aster/versions/0.5.0/aster-session")
  #expect(outcome.previousVersion == "0.4.0")

  // 旧版本目录在任何命令里都不能被删除，否则一次安装失败会毁掉唯一可用二进制。
  let oldPath = "/home/mike/.local/share/aster/versions/0.4.0"
  for argv in executor.commands {
    let script = argv.last ?? ""
    #expect(!(script.contains("rm") && script.contains(oldPath)))
  }
}

@Test func remoteInstallRollbackRelinksActivePathToPreviousVersion() throws {
  let manifest = makeManifest(version: "0.5.0")
  let plan = makePlan(manifest: manifest, existingVersion: "0.4.0")
  let script = plan.rollbackCommand().last ?? ""
  #expect(plan.rollbackCommand().first == "/bin/sh")
  #expect(script.contains("'/home/mike/.local/share/aster/staging/stage-1.part'"))
  #expect(script.contains("'/home/mike/.local/share/aster/versions/0.4.0/aster-session'"))
  #expect(script.contains("mv -f"))
  // 回滚只能删除本次新建的版本目录，不能碰旧版本目录。
  #expect(script.contains("rm -rf '/home/mike/.local/share/aster/versions/0.5.0'"))
  #expect(!script.contains("rm -rf '/home/mike/.local/share/aster/versions/0.4.0'"))
}

@Test func remoteInstallPlanImpactSummaryStatesRunningServiceIsUntouched() throws {
  let manifest = makeManifest(version: "0.5.0")
  let plan = makePlan(manifest: manifest, existingVersion: "0.4.0")
  let summary = plan.impactSummary
  #expect(summary.contains("orb"))
  #expect(summary.contains("/home/mike/.local/share/aster/versions/0.5.0/aster-session"))
  #expect(summary.contains("0.5.0"))
  #expect(summary.contains("受管发布"))
  #expect(summary.contains("替换现有版本：是"))
  #expect(summary.contains("不会被本次安装停止"))
}

@Test func remoteInstallCommandsUseQuotedPathsAndDigestFallback() throws {
  let manifest = makeManifest()
  let plan = makePlan(manifest: manifest)
  let mkdir = plan.makeDirectoriesCommand()
  #expect(mkdir[0] == "/bin/sh")
  #expect(mkdir[1] == "-c")
  #expect(mkdir[2].hasPrefix("umask 077; mkdir -p "))
  #expect(mkdir[2].contains("'/home/mike/.local/share/aster/bin'"))

  let digest = plan.digestCommand(path: plan.stagingPath)
  #expect(digest[2].contains("command -v sha256sum"))
  #expect(digest[2].contains("shasum -a 256"))

  let size = plan.sizeCommand(path: plan.stagingPath)
  #expect(size[2].contains("wc -c < '/home/mike/.local/share/aster/staging/stage-1.part'"))

  // 活动 symlink 必须经 `.new` + rename 原子切换，不能直接 ln 覆盖活动路径。
  let activate = plan.activateCommand()[2]
  #expect(activate.contains("'/home/mike/.local/share/aster/bin/aster-session.new'"))
  #expect(activate.contains("mv -f '/home/mike/.local/share/aster/bin/aster-session.new'"))
}

@Test func remoteInstallRejectsMalformedManifest() throws {
  let manifest = makeManifest(size: 0, digest: "ABC")
  #expect(throws: RemoteInstallValidationError.self) {
    try RemoteInstallValidation.validateShape(manifest)
  }
  do {
    try RemoteInstallValidation.validateShape(manifest)
  } catch let error as RemoteInstallValidationError {
    #expect(error == .malformedManifest("sizeBytes"))
  }
}

@Test func remoteReleaseManifestRoundTripsThroughJSON() throws {
  let manifest = makeManifest(kind: .testArtifact, signature: nil)
  let data = try JSONEncoder().encode(manifest)
  let decoded = try JSONDecoder().decode(RemoteReleaseManifest.self, from: data)
  #expect(decoded == manifest)
  #expect(String(decoding: data, as: UTF8.self).contains("testArtifact"))
}


@Test("清单声明 shell 集成压缩包时：上传、复核、解到版本目录，都在 activate 之前")
func remoteInstallShipsShellIntegrationPayloadBeforeActivate() throws {
  let executor = FakeInstallExecutor()
  let payloadDigest = String(repeating: "cd", count: 32)
  var manifest = makeManifest()
  manifest.shellIntegration = RemoteReleasePayload(
    fileName: "shell-integration.tar.gz", sha256: payloadDigest, sizeBytes: 4)
  // 两次 digest/size 复核：先二进制，后压缩包。假执行器按调用顺序返回。
  executor.digestOutputs = [sampleDigest + "  staging", payloadDigest + "  staging.tgz"]
  executor.sizeOutputs = ["\(manifest.sizeBytes)\n", "4\n"]
  let plan = RemoteInstallPlan(
    targetDescription: "dev@host", homeDirectory: "/home/dev", manifest: manifest,
    existingVersion: nil, stagingID: "stage")
  let transaction = RemoteInstallTransaction(
    executor: executor, remotePlatform: manifest.platform,
    remoteArchitecture: manifest.architecture, acceptDevelopmentArtifact: true,
    signatureVerifier: { _ in true })
  _ = try transaction.install(
    plan: plan, manifest: manifest, localPath: "/local/aster-session",
    localDigest: sampleDigest, localSize: manifest.sizeBytes,
    shellIntegrationPath: "/local/shell-integration.tar.gz")
  #expect(executor.stepLabels == ["mkdir", "digest", "size", "digest", "size", "integration", "activate"])
  #expect(executor.uploads.map(\.remote) == [plan.stagingPath, plan.shellIntegrationStagingPath])
  #expect(plan.installShellIntegrationCommand()[2].contains("-C '\(plan.versionDirectory)'"))
  #expect(plan.versionedShellIntegrationDirectory == plan.versionDirectory + "/shell-integration")
  // 回滚也清理集成压缩包的临时文件。
  #expect(plan.rollbackCommand()[2].contains(plan.shellIntegrationStagingPath))

  // 清单声明了压缩包但本地缺文件：不能装出一个没有集成的版本。
  let missing = FakeInstallExecutor()
  missing.digestOutputs = [sampleDigest + "  staging"]
  missing.sizeOutputs = ["\(manifest.sizeBytes)\n"]
  let missingTransaction = RemoteInstallTransaction(
    executor: missing, remotePlatform: manifest.platform,
    remoteArchitecture: manifest.architecture, acceptDevelopmentArtifact: true,
    signatureVerifier: { _ in true })
  #expect(throws: RemoteInstallError.self) {
    try missingTransaction.install(
      plan: plan, manifest: manifest, localPath: "/local/aster-session",
      localDigest: sampleDigest, localSize: manifest.sizeBytes)
  }
  #expect(missing.stepLabels.contains("activate") == false)
  #expect(missing.stepLabels.last == "rollback")
}
