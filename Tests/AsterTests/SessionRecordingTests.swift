import AsterCore
import AsterMemory
import Foundation
import Testing

@testable import Aster

/// 独立 UserDefaults suite：记录设置是全局键，绝不能污染 `.standard`。
private func isolatedDefaults() -> (suite: String, defaults: UserDefaults) {
  let suite = "SessionRecordingTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return (suite, defaults)
}

/// 一套自带临时 Memory 根目录与隔离设置的记录服务夹具。
@MainActor
private struct RecordingFixture {
  let location: MemoryStoreLocation
  let service: SessionRecordingService
  let defaults: UserDefaults
  let suiteName: String
  let projectRoot: String

  init(
    mode: RecordingMode,
    excludedPaths: [String] = [],
    excludedCommands: [String] = [],
    projectRoot: String = "/tmp/aster-recording-project",
    git: GitStatusSummary = GitStatusSummary(branch: "main", objectID: "abc123def")
  ) {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("AsterMemoryTests-\(UUID().uuidString)", isDirectory: true)
    location = MemoryStoreLocation(rootDirectory: root)
    let isolated = isolatedDefaults()
    suiteName = isolated.suite
    defaults = isolated.defaults
    let preferences = AppPreferences(defaults: defaults)
    preferences.memoryRecordingMode = mode
    preferences.memoryExcludedPaths = excludedPaths
    preferences.memoryExcludedCommands = excludedCommands
    self.projectRoot = projectRoot
    // git 与项目解析都注入桩：测试不允许 fork 子进程，也不依赖机器上的仓库状态。
    // writer 也必须注入——生产单写者指向真实用户目录，测试绝不能碰。
    service = SessionRecordingService(
      location: location,
      writer: EventWriter(location: location),
      defaults: defaults,
      resolveProject: { _ in ProjectIdentity.make(path: projectRoot, gitRemote: "git@example:x") },
      inspectGit: { _ in git },
      // 生产要等 provider 刷盘（2 秒）；测试没有真实 transcript，等待只会拖慢用例。
      transcriptIngestionDelay: .zero
    )
  }

  /// 跑完一个最小 Session：启动 → 一条命令 → 输出 → 完成 → 结束，并等待管线排空。
  func runSession(
    id: UUID,
    workingDirectory: String,
    command: String,
    output: String,
    exitStatus: Int
  ) async {
    service.sessionStarted(id: id, projectPath: workingDirectory, shell: "/bin/zsh")
    service.commandStarted(id: id, command: command, workingDirectory: workingDirectory)
    service.receivePTYOutput(id: id, bytes: Array(Self.commandOutputBytes(output, exit: exitStatus))[...])
    service.commandFinished(id: id, command: command, exitStatus: exitStatus)
    service.sessionEnded(id: id, exitCode: 0)
    await service.waitForCompletion(id: id)
  }

  /// 构造一段带 OSC 133 C/D 边界的 PTY 字节流，让 `ShellCommandOutputCapture` 能闭合。
  static func commandOutputBytes(_ text: String, exit: Int) -> [UInt8] {
    Array("\u{1B}]133;C\u{07}\(text)\u{1B}]133;D;\(exit)\u{07}".utf8)
  }

  func reader() throws -> MemoryStoreReader {
    try MemoryStoreReader(location: location)
  }

  /// 数据库文件是否存在。零落盘断言用它，而不是查表——库根本不该被创建。
  var databaseExists: Bool {
    FileManager.default.fileExists(atPath: location.databaseURL.path)
  }

  func cleanUp() {
    try? FileManager.default.removeItem(at: location.rootDirectory)
    defaults.removePersistentDomain(forName: suiteName)
  }
}

/// 轮询等待条件成立。git 快照走独立 detached task，与 session 结束没有先后保证。
private func waitUntil(
  timeout: TimeInterval = 5,
  _ condition: @Sendable () async -> Bool
) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return await condition()
}

// MARK: - 三态与零落盘

@Test("记录关闭时完全不落盘")
@MainActor
func recordingOffWritesNothing() async {
  let fixture = RecordingFixture(mode: .off)
  defer { fixture.cleanUp() }
  await fixture.runSession(
    id: UUID(), workingDirectory: fixture.projectRoot,
    command: "swift build", output: "ok", exitStatus: 0)
  #expect(fixture.databaseExists == false)
}

@Test("隐身模式与关闭同样零落盘")
@MainActor
func incognitoWritesNothing() async {
  let fixture = RecordingFixture(mode: .incognito)
  defer { fixture.cleanUp() }
  await fixture.runSession(
    id: UUID(), workingDirectory: fixture.projectRoot,
    command: "swift build", output: "ok", exitStatus: 0)
  #expect(fixture.databaseExists == false)
}

@Test("排除目录下的 Session 在源头被拦截，不创建任何记录")
@MainActor
func excludedDirectoryIsInterceptedAtSource() async {
  let fixture = RecordingFixture(mode: .on, excludedPaths: ["/tmp/secret"])
  defer { fixture.cleanUp() }
  await fixture.runSession(
    id: UUID(), workingDirectory: "/tmp/secret/work",
    command: "swift build", output: "ok", exitStatus: 0)
  #expect(fixture.databaseExists == false)
}

@Test("空工作目录（如远端 SSH）保守拒绝记录")
@MainActor
func emptyWorkingDirectoryIsRejected() async {
  let fixture = RecordingFixture(mode: .on)
  defer { fixture.cleanUp() }
  await fixture.runSession(
    id: UUID(), workingDirectory: "",
    command: "swift build", output: "ok", exitStatus: 0)
  #expect(fixture.databaseExists == false)
}

// MARK: - 命令排除

@Test("被排除的命令连同它的输出都不进事件流")
@MainActor
func excludedCommandDropsItsOutput() async throws {
  let fixture = RecordingFixture(mode: .on, excludedCommands: ["op"])
  defer { fixture.cleanUp() }
  let id = UUID()
  fixture.service.sessionStarted(
    id: id, projectPath: fixture.projectRoot, shell: "/bin/zsh")

  // 被排除的命令：命令事件、完成事件与输出正文都必须消失。
  fixture.service.commandStarted(
    id: id, command: "op item get github", workingDirectory: fixture.projectRoot)
  fixture.service.receivePTYOutput(
    id: id,
    bytes: Array(RecordingFixture.commandOutputBytes("SUPER-SECRET-TOKEN", exit: 0))[...])
  fixture.service.commandFinished(id: id, command: "op item get github", exitStatus: 0)

  // 未被排除的命令照常记录，证明拦截是逐命令而不是整会话。
  fixture.service.commandStarted(
    id: id, command: "swift build", workingDirectory: fixture.projectRoot)
  fixture.service.receivePTYOutput(
    id: id, bytes: Array(RecordingFixture.commandOutputBytes("Build complete", exit: 0))[...])
  fixture.service.commandFinished(id: id, command: "swift build", exitStatus: 0)

  fixture.service.sessionEnded(id: id, exitCode: 0)
  await fixture.service.waitForCompletion(id: id)

  let detail = try #require(try fixture.reader().sessionDetail(id: id))
  let commands = detail.events.filter { $0.kind == .shellCommand }.compactMap(\.command)
  #expect(commands == ["swift build"])
  let excerpts = detail.events.compactMap(\.outputExcerpt).joined(separator: "\n")
  #expect(excerpts.contains("SUPER-SECRET-TOKEN") == false)
  #expect(excerpts.contains("Build complete"))
  // 被排除命令的正文也不能出现在 artifact 文件里。
  let artifacts = try fixture.reader().artifacts(sessionID: id)
  let bodies = artifacts.compactMap {
    try? String(
      contentsOf: fixture.location.rootDirectory.appendingPathComponent($0.relativePath),
      encoding: .utf8)
  }
  #expect(bodies.contains { $0.contains("SUPER-SECRET-TOKEN") } == false)
}

// MARK: - 项目归属

@Test("Session 的项目归属使用解析出的 git toplevel，并写入 projects 表")
@MainActor
func sessionUsesResolvedProjectPath() async throws {
  let fixture = RecordingFixture(mode: .on, projectRoot: "/tmp/aster-repo-root")
  defer { fixture.cleanUp() }
  let id = UUID()
  // Session 在子目录里启动，归属仍应落到仓库根。
  await fixture.runSession(
    id: id, workingDirectory: "/tmp/aster-repo-root/Sources/Deep",
    command: "swift build", output: "ok", exitStatus: 0)

  let detail = try #require(try fixture.reader().sessionDetail(id: id))
  #expect(detail.descriptor.projectPath == "/tmp/aster-repo-root")
  let context = try fixture.reader().projectContext(projectPath: "/tmp/aster-repo-root")
  #expect(context.projectName == "aster-repo-root")
  #expect(context.sessions.contains { $0.descriptor.id == id })
}

// MARK: - 输出正文落盘

@Test("完整输出写 artifact 文件（0600），events 只留有界摘录")
@MainActor
func outputBodyGoesToArtifactFile() async throws {
  let fixture = RecordingFixture(mode: .on)
  defer { fixture.cleanUp() }
  let id = UUID()
  // 远超 4KiB 摘录上限，确保「全文落盘、摘录截断」两条路径都被覆盖。
  let body = String(repeating: "line of build output\n", count: 1_000)
  await fixture.runSession(
    id: id, workingDirectory: fixture.projectRoot,
    command: "swift build", output: body, exitStatus: 0)

  let detail = try #require(try fixture.reader().sessionDetail(id: id))
  let excerpt = try #require(detail.events.first(where: { $0.kind == .commandOutput })?.outputExcerpt)
  #expect(excerpt.utf8.count <= MemoryOutputExcerpt.maximumBytes)
  #expect(excerpt.utf8.count < body.utf8.count)

  let artifacts = try fixture.reader().artifacts(sessionID: id)
  #expect(artifacts.count == 1)
  let artifact = try #require(artifacts.first)
  #expect(artifact.relativePath.hasPrefix("transcripts/\(id.uuidString)/"))
  #expect(artifact.byteCount > MemoryOutputExcerpt.maximumBytes)

  let fileURL = fixture.location.rootDirectory.appendingPathComponent(artifact.relativePath)
  let stored = try String(contentsOf: fileURL, encoding: .utf8)
  #expect(stored.hasPrefix("line of build output"))
  let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
  #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
  let directoryAttributes = try FileManager.default.attributesOfItem(
    atPath: fileURL.deletingLastPathComponent().path)
  #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
}

// MARK: - git 快照

@Test("Session 开始时采集 git 快照并回写 sessions 行")
@MainActor
func gitSnapshotIsRecordedAtSessionStart() async throws {
  let fixture = RecordingFixture(
    mode: .on,
    git: GitStatusSummary(
      branch: "feature/memory", objectID: "0123456789abcdef",
      changes: [GitChange(path: "a.swift", status: "M.")])
  )
  defer { fixture.cleanUp() }
  let id = UUID()
  await fixture.runSession(
    id: id, workingDirectory: fixture.projectRoot,
    command: "swift build", output: "ok", exitStatus: 1)

  let location = fixture.location
  let found = await waitUntil {
    guard let reader = try? MemoryStoreReader(location: location),
      let detail = try? reader.sessionDetail(id: id)
    else { return false }
    return detail.events.contains { $0.kind == .gitStateSnapshot }
      && detail.descriptor.gitBranch == "feature/memory"
  }
  #expect(found)

  let detail = try #require(try fixture.reader().sessionDetail(id: id))
  let snapshot = try #require(
    detail.events.first(where: { $0.kind == MemoryEventKind.gitStateSnapshot }))
  #expect(snapshot.source == MemoryEventSource.git)
  let payload = try #require(snapshot.payload.flatMap(GitSnapshotPayload.decode))
  #expect(payload.branch == "feature/memory")
  #expect(payload.commit == "0123456789abcdef")
  #expect(payload.dirtyFileCount == 1)
}

// MARK: - 提炼

@Test("Session 结束后经 seam 生成 Memory 并回链来源")
@MainActor
func sessionEndProducesMemoryThroughSeam() async throws {
  let fixture = RecordingFixture(mode: .on)
  defer { fixture.cleanUp() }
  let id = UUID()
  await fixture.runSession(
    id: id, workingDirectory: fixture.projectRoot,
    command: "swift test", output: "1 test failed", exitStatus: 1)

  let memory = try #require(try fixture.reader().memories(projectPath: nil, sessionID: id).first)
  #expect(memory.sessionID == id)
  #expect(memory.projectPath == fixture.projectRoot)
  #expect(memory.status == .active)
  #expect(memory.extractor == .ruleBased)
  let sources = try fixture.reader().memorySources(memoryID: memory.id)
  #expect(sources.contains(MemorySourceRef(kind: .session, identifier: id.uuidString)))
}

// MARK: - Agent 归属

@Test("Agent 归属写入 sessions 行，并在结束时供 transcript 补录使用")
@MainActor
func agentAttributionIsPersisted() async throws {
  let fixture = RecordingFixture(mode: .on)
  defer { fixture.cleanUp() }
  let id = UUID()
  fixture.service.sessionStarted(
    id: id, projectPath: fixture.projectRoot, shell: "/bin/zsh")
  fixture.service.agentChanged(
    id: id, provider: AgentProvider.claudeCode.rawValue,
    agentSessionID: "agent-session-1")
  fixture.service.commandStarted(
    id: id, command: "claude", workingDirectory: fixture.projectRoot)
  fixture.service.commandFinished(id: id, command: "claude", exitStatus: 0)
  // 补录在 sessionEnded 的排空任务里执行；本机没有对应 transcript 文件时静默降级，
  // 这里断言的是「归属已落库 + 补录不影响正常收尾」。
  fixture.service.sessionEnded(id: id, exitCode: 0)
  await fixture.service.waitForCompletion(id: id)

  let detail = try #require(try fixture.reader().sessionDetail(id: id))
  #expect(detail.descriptor.agentProvider == AgentProvider.claudeCode.rawValue)
  #expect(detail.descriptor.agentSessionID == "agent-session-1")
  #expect(detail.events.contains { $0.kind == .agentStateChanged })
  #expect(detail.endedAt != nil)
}

// MARK: - Per-pane 隐身

@Test("Per-pane 隐身立刻停止落盘，且不改动全局设置")
@MainActor
func perPaneIncognitoStopsRecording() async throws {
  let fixture = RecordingFixture(mode: .on)
  defer { fixture.cleanUp() }
  let id = UUID()
  fixture.service.sessionStarted(
    id: id, projectPath: fixture.projectRoot, shell: "/bin/zsh")
  fixture.service.commandStarted(
    id: id, command: "swift build", workingDirectory: fixture.projectRoot)
  fixture.service.commandFinished(id: id, command: "swift build", exitStatus: 0)
  #expect(fixture.service.recordingMode(for: id) == .on)
  #expect(fixture.service.isRecording(id: id))

  fixture.service.setIncognito(true, for: id)
  #expect(fixture.service.recordingMode(for: id) == .incognito)
  #expect(fixture.service.isRecording(id: id) == false)
  // 全局设置不受 per-pane 隐身影响。
  #expect(AppPreferences.memoryRecordingPolicy(from: fixture.defaults).mode == .on)

  fixture.service.commandStarted(
    id: id, command: "cat ~/.ssh/id_rsa", workingDirectory: fixture.projectRoot)
  fixture.service.commandFinished(id: id, command: "cat ~/.ssh/id_rsa", exitStatus: 0)
  fixture.service.sessionEnded(id: id, exitCode: 0)
  await fixture.service.waitForCompletion(id: id)

  let detail = try #require(try fixture.reader().sessionDetail(id: id))
  let commands = detail.events.compactMap(\.command)
  #expect(commands.contains("swift build"))
  #expect(commands.contains { $0.contains("id_rsa") } == false)
}

@Test("退出隐身后同一 Session 继续记录到同一行")
@MainActor
func leavingIncognitoResumesRecording() async throws {
  let fixture = RecordingFixture(mode: .on)
  defer { fixture.cleanUp() }
  let id = UUID()
  fixture.service.sessionStarted(
    id: id, projectPath: fixture.projectRoot, shell: "/bin/zsh")
  fixture.service.setIncognito(true, for: id)
  fixture.service.commandStarted(
    id: id, command: "op signin", workingDirectory: fixture.projectRoot)
  fixture.service.commandFinished(id: id, command: "op signin", exitStatus: 0)

  fixture.service.setIncognito(false, for: id)
  #expect(fixture.service.isRecording(id: id))
  fixture.service.commandStarted(
    id: id, command: "swift test", workingDirectory: fixture.projectRoot)
  fixture.service.commandFinished(id: id, command: "swift test", exitStatus: 0)
  fixture.service.sessionEnded(id: id, exitCode: 0)
  await fixture.service.waitForCompletion(id: id)

  let sessions = try fixture.reader().sessions(projectPath: nil)
  #expect(sessions.filter { $0.descriptor.id == id }.count == 1)
  let detail = try #require(try fixture.reader().sessionDetail(id: id))
  let commands = detail.events.compactMap(\.command)
  #expect(commands.contains("swift test"))
  #expect(commands.contains("op signin") == false)
}
