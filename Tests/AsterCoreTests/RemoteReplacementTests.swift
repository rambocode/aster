import Foundation
import Testing

@testable import AsterCore

/// P8.3：服务替换事务的编排顺序、失败回退与终端影响列表。

// MARK: - 替身

/// 记录调用序列的 `RemoteReplacementExecuting` 替身。
private final class FakeReplacementExecutor: RemoteReplacementExecuting, @unchecked Sendable {
  private let lock = NSLock()
  private(set) var steps: [String] = []

  var terminals: [ManagedTerminalStatus] = []
  var listError: Error?
  var stopError: Error?
  var startError: Error?
  var startIdentity: SessionServerIdentity = FakeReplacementExecutor.makeIdentity()
  /// 第二次 startServer 调用（回退时）的错误。nil 表示成功。
  var rollbackStartError: Error?
  private var startCallCount = 0

  static func makeIdentity(version: String = "1.0.0") -> SessionServerIdentity {
    SessionServerIdentity(
      reference: SessionServerReference(
        machineProfileID: MachineProfile.localProfileID,
        serverID: "new-server",
        sessionID: "new-session"),
      serverEpoch: "new-epoch",
      capabilities: ["terminal_control", "surface_interest", "health_check"],
      version: version)
  }

  func listTerminals() throws -> [ManagedTerminalStatus] {
    lock.lock()
    steps.append("listTerminals")
    lock.unlock()
    if let listError { throw listError }
    return terminals
  }

  func stopServer() throws {
    lock.lock()
    steps.append("stopServer")
    lock.unlock()
    if let stopError { throw stopError }
  }

  func startServer(binaryPath: String) throws -> SessionServerIdentity {
    lock.lock()
    startCallCount += 1
    let callNum = startCallCount
    steps.append("startServer(\(binaryPath))")
    lock.unlock()
    // 第一次 startServer 用 startError，第二次（回退）用 rollbackStartError
    if callNum == 1 {
      if let startError { throw startError }
    } else {
      if let rollbackStartError { throw rollbackStartError }
    }
    return startIdentity
  }
}

/// 记录调用序列的 `RemoteInstallExecuting` 替身（复用安装事务测试的模式）。
private final class FakeInstallForReplacement: RemoteInstallExecuting, @unchecked Sendable {
  var digestOutput: String = ""
  var sizeOutput: String = ""
  var uploadError: Error?

  func runRemote(_ argv: [String]) throws -> RemoteSSHResult {
    let script = argv.last ?? ""
    if script.contains("sha256sum") {
      return RemoteSSHResult(exitStatus: 0, standardOutput: digestOutput, standardError: "")
    }
    if script.contains("wc -c") {
      return RemoteSSHResult(exitStatus: 0, standardOutput: sizeOutput, standardError: "")
    }
    return RemoteSSHResult(exitStatus: 0, standardOutput: "", standardError: "")
  }

  func upload(localPath: String, remotePath: String) throws {
    if let uploadError { throw uploadError }
  }
}

// MARK: - 样例

private let sampleDigest = String(repeating: "ab", count: 32)

private func makeManifest(version: String = "1.0.0") -> RemoteReleaseManifest {
  RemoteReleaseManifest(
    version: version,
    platform: "linux",
    architecture: "x86_64",
    sha256: sampleDigest,
    sizeBytes: 1024,
    signature: "sig",
    artifactKind: .managedRelease,
    protocolMajor: 1,
    protocolMinor: 0)
}

private func makePlan(
  manifest: RemoteReleaseManifest,
  existingVersion: String? = "0.9.0"
) -> RemoteInstallPlan {
  RemoteInstallPlan(
    targetDescription: "orb",
    homeDirectory: "/home/mike",
    manifest: manifest,
    existingVersion: existingVersion,
    stagingID: "stage-r1")
}

private func makeTerminal(
  id: String, state: ManagedTerminalState = .running
) -> ManagedTerminalStatus {
  ManagedTerminalStatus(
    reference: ManagedTerminalReference(
      server: SessionServerReference(
        machineProfileID: MachineProfile.localProfileID,
        serverID: "old-server",
        sessionID: "old-session"),
      terminalID: id),
    state: state,
    pid: 1234,
    cwd: "/home/mike",
    exitCode: nil,
    serverEpoch: "old-epoch")
}

private func makeTransaction(
  replacementExecutor: FakeReplacementExecutor,
  installExecutor: FakeInstallForReplacement
) -> RemoteReplacementTransaction {
  let installTx = RemoteInstallTransaction(
    executor: installExecutor,
    remotePlatform: "linux",
    remoteArchitecture: "x86_64",
    signatureVerifier: { _ in true })
  return RemoteReplacementTransaction(
    executor: replacementExecutor,
    installTransaction: installTx)
}

// MARK: - 用例

@Test func replacementFlowExecutesInCorrectOrder() throws {
  let repExec = FakeReplacementExecutor()
  repExec.terminals = [makeTerminal(id: "t1"), makeTerminal(id: "t2")]
  let instExec = FakeInstallForReplacement()
  let manifest = makeManifest()
  instExec.digestOutput = "\(manifest.sha256)  staging\n"
  instExec.sizeOutput = "\(manifest.sizeBytes)\n"

  let transaction = makeTransaction(replacementExecutor: repExec, installExecutor: instExec)
  let outcome = try transaction.replace(
    plan: makePlan(manifest: manifest),
    manifest: manifest,
    localPath: "/tmp/aster-session",
    localDigest: manifest.sha256,
    localSize: manifest.sizeBytes)

  // 验证编排顺序：listTerminals → stopServer → (install steps in between) → startServer
  #expect(repExec.steps.first == "listTerminals")
  #expect(repExec.steps[1] == "stopServer")
  #expect(repExec.steps.last?.hasPrefix("startServer") == true)

  // 验证受影响终端
  #expect(outcome.affectedTerminalIDs == ["t1", "t2"])
  #expect(outcome.installOutcome.version == "1.0.0")
  #expect(outcome.installOutcome.previousVersion == "0.9.0")
}

@Test func replacementFilterOutExitedTerminals() throws {
  let repExec = FakeReplacementExecutor()
  repExec.terminals = [
    makeTerminal(id: "t1", state: .running),
    makeTerminal(id: "t2", state: .exited),
    makeTerminal(id: "t3", state: .running),
  ]
  let instExec = FakeInstallForReplacement()
  let manifest = makeManifest()
  instExec.digestOutput = "\(manifest.sha256)  staging\n"
  instExec.sizeOutput = "\(manifest.sizeBytes)\n"

  let transaction = makeTransaction(replacementExecutor: repExec, installExecutor: instExec)
  let outcome = try transaction.replace(
    plan: makePlan(manifest: manifest),
    manifest: manifest,
    localPath: "/tmp/aster-session",
    localDigest: manifest.sha256,
    localSize: manifest.sizeBytes)

  // 只有 running 的终端算受影响
  #expect(outcome.affectedTerminalIDs == ["t1", "t3"])
}

@Test func replacementStopFailureStopsEarly() {
  let repExec = FakeReplacementExecutor()
  repExec.terminals = [makeTerminal(id: "t1")]
  repExec.stopError = ManagedSessionError.commandFailed(status: 1, output: "busy")
  let instExec = FakeInstallForReplacement()

  let transaction = makeTransaction(replacementExecutor: repExec, installExecutor: instExec)
  do {
    _ = try transaction.replace(
      plan: makePlan(manifest: makeManifest()),
      manifest: makeManifest(),
      localPath: "/tmp/aster-session",
      localDigest: sampleDigest,
      localSize: 1024)
    Issue.record("expected stopServiceFailed")
  } catch let error as RemoteReplacementError {
    if case .stopServiceFailed = error {} else {
      Issue.record("expected stopServiceFailed, got \(error)")
    }
  } catch {
    Issue.record("unexpected: \(error)")
  }
  // install 和 startServer 不应该被调用
  #expect(repExec.steps == ["listTerminals", "stopServer"])
}

@Test func replacementInstallFailureKeepsOldVersion() {
  let repExec = FakeReplacementExecutor()
  repExec.terminals = []
  let instExec = FakeInstallForReplacement()
  instExec.uploadError = RemoteInstallError.insufficientSpace

  let transaction = makeTransaction(replacementExecutor: repExec, installExecutor: instExec)
  do {
    _ = try transaction.replace(
      plan: makePlan(manifest: makeManifest()),
      manifest: makeManifest(),
      localPath: "/tmp/aster-session",
      localDigest: sampleDigest,
      localSize: 1024)
    Issue.record("expected installFailed")
  } catch let error as RemoteReplacementError {
    if case .installFailed = error {} else {
      Issue.record("expected installFailed, got \(error)")
    }
  } catch {
    Issue.record("unexpected: \(error)")
  }
  // startServer 不应该被调用
  #expect(!repExec.steps.contains(where: { $0.hasPrefix("startServer") }))
}

@Test func replacementStartFailureTriesRollback() {
  let repExec = FakeReplacementExecutor()
  repExec.terminals = []
  repExec.startError = ManagedSessionError.launchFailed("new binary crashed")
  let instExec = FakeInstallForReplacement()
  let manifest = makeManifest()
  instExec.digestOutput = "\(manifest.sha256)  staging\n"
  instExec.sizeOutput = "\(manifest.sizeBytes)\n"

  let transaction = makeTransaction(replacementExecutor: repExec, installExecutor: instExec)
  do {
    _ = try transaction.replace(
      plan: makePlan(manifest: manifest, existingVersion: "0.9.0"),
      manifest: manifest,
      localPath: "/tmp/aster-session",
      localDigest: sampleDigest,
      localSize: 1024)
    Issue.record("expected startServiceFailed")
  } catch let error as RemoteReplacementError {
    if case .startServiceFailed = error {} else {
      Issue.record("expected startServiceFailed, got \(error)")
    }
  } catch {
    Issue.record("unexpected: \(error)")
  }
  // 应该尝试过两次 startServer：一次新版本，一次旧版本
  let startCalls = repExec.steps.filter { $0.hasPrefix("startServer") }
  #expect(startCalls.count == 2)
  // 第二次应该用旧版本路径
  #expect(startCalls[1].contains("0.9.0"))
}

@Test func replacementRollbackFailureReportsBothErrors() {
  let repExec = FakeReplacementExecutor()
  repExec.terminals = []
  repExec.startError = ManagedSessionError.launchFailed("new binary crashed")
  repExec.rollbackStartError = ManagedSessionError.launchFailed("old binary also crashed")
  let instExec = FakeInstallForReplacement()
  let manifest = makeManifest()
  instExec.digestOutput = "\(manifest.sha256)  staging\n"
  instExec.sizeOutput = "\(manifest.sizeBytes)\n"

  let transaction = makeTransaction(replacementExecutor: repExec, installExecutor: instExec)
  do {
    _ = try transaction.replace(
      plan: makePlan(manifest: manifest, existingVersion: "0.9.0"),
      manifest: manifest,
      localPath: "/tmp/aster-session",
      localDigest: sampleDigest,
      localSize: 1024)
    Issue.record("expected rollbackFailed")
  } catch let error as RemoteReplacementError {
    if case .rollbackFailed(let original, let rollback) = error {
      #expect(original.contains("new binary crashed"))
      #expect(rollback.contains("old binary also crashed"))
    } else {
      Issue.record("expected rollbackFailed, got \(error)")
    }
  } catch {
    Issue.record("unexpected: \(error)")
  }
}

@Test func replacementWithNoExistingVersionSkipsRollback() {
  let repExec = FakeReplacementExecutor()
  repExec.terminals = []
  repExec.startError = ManagedSessionError.launchFailed("crashed")
  let instExec = FakeInstallForReplacement()
  let manifest = makeManifest()
  instExec.digestOutput = "\(manifest.sha256)  staging\n"
  instExec.sizeOutput = "\(manifest.sizeBytes)\n"

  let transaction = makeTransaction(replacementExecutor: repExec, installExecutor: instExec)
  // existingVersion=nil → 没有旧版本可回退，直接抛 startServiceFailed
  do {
    _ = try transaction.replace(
      plan: makePlan(manifest: manifest, existingVersion: nil),
      manifest: manifest,
      localPath: "/tmp/aster-session",
      localDigest: sampleDigest,
      localSize: 1024)
    Issue.record("expected startServiceFailed")
  } catch let error as RemoteReplacementError {
    if case .startServiceFailed = error {} else {
      Issue.record("expected startServiceFailed, got \(error)")
    }
  } catch {
    Issue.record("unexpected: \(error)")
  }
  // 只有一次 startServer 调用（没有回退尝试）
  let startCalls = repExec.steps.filter { $0.hasPrefix("startServer") }
  #expect(startCalls.count == 1)
}
