import Foundation
import Testing

@testable import AsterCore

/// 可注入失败的假会话客户端，记录全部调用顺序以便断言回滚行为。
///
/// 用 `final class` + 锁而不是 struct：迁移事务按引用语义多次调用同一实例，
/// 需要在测试里读回累积的调用日志。
private final class FakeManagedSessionClient: ManagedSessionClient, @unchecked Sendable {
  enum Call: Equatable {
    case ensureServer
    case createTerminal(workingDirectory: String)
    case terminateTerminal(terminalID: String)
  }

  private let lock = NSLock()
  private var log: [Call] = []
  private var createdCount = 0

  /// ensureServer 抛出的错误；nil 表示成功。
  var ensureServerFailure: ManagedSessionError?
  /// 第几次 createTerminal 调用失败（1 基）；nil 表示全部成功。
  var failCreateOnCall: Int?

  let server = SessionServerReference(
    machineProfileID: MachineProfile.localProfileID,
    serverID: "server-a",
    sessionID: "session-a"
  )

  var calls: [Call] {
    lock.lock()
    defer { lock.unlock() }
    return log
  }

  func ensureServer(_ endpoint: ManagedSessionEndpoint) throws -> SessionServerReference {
    lock.lock()
    log.append(.ensureServer)
    lock.unlock()
    if let ensureServerFailure { throw ensureServerFailure }
    return server
  }

  func serverStatus(_ endpoint: ManagedSessionEndpoint) throws -> SessionServerIdentity {
    SessionServerIdentity(
      reference: server, serverEpoch: "epoch-1", capabilities: [], version: "test")
  }

  func createTerminal(
    _ endpoint: ManagedSessionEndpoint,
    workingDirectory: String,
    argv: [String]
  ) throws -> ManagedTerminalStatus {
    lock.lock()
    log.append(.createTerminal(workingDirectory: workingDirectory))
    createdCount += 1
    let index = createdCount
    lock.unlock()
    if let failCreateOnCall, index == failCreateOnCall {
      throw ManagedSessionError.serviceError(code: "create_failed", message: "injected")
    }
    return ManagedTerminalStatus(
      reference: ManagedTerminalReference(server: server, terminalID: "term-\(index)"),
      state: .running,
      pid: Int32(1000 + index),
      cwd: workingDirectory,
      exitCode: nil,
      serverEpoch: "epoch-1"
    )
  }

  func listTerminals(_ endpoint: ManagedSessionEndpoint) throws -> [ManagedTerminalStatus] { [] }

  func terminateTerminal(
    _ endpoint: ManagedSessionEndpoint,
    terminalID: String
  ) throws -> ManagedTerminalStatus {
    lock.lock()
    log.append(.terminateTerminal(terminalID: terminalID))
    lock.unlock()
    return ManagedTerminalStatus(
      reference: ManagedTerminalReference(server: server, terminalID: terminalID),
      state: .exited,
      serverEpoch: "epoch-1"
    )
  }

  func bridgeArguments(
    _ endpoint: ManagedSessionEndpoint,
    terminalID: String,
    readOnly: Bool
  ) -> [String] { [] }

  /// 迁移事务不使用结构化 CLI 原语；这里只满足协议要求，被调用即说明用法有误。
  func executeStructured(binaryPath: String, arguments: [String]) throws -> String {
    throw ManagedSessionError.runtimeUnavailable(binaryPath)
  }
}

private let migrationEndpoint = ManagedSessionEndpoint(
  binaryPath: "/nonexistent/aster-session",
  stateParentPath: "/tmp/aster-migration-test",
  sessionName: "default"
)

/// 构造一个混合布局：两个未托管终端、一个已托管终端、一个编辑器、一个 Web、一个文件浏览器。
private func migrationFixtureTabs() -> (tabs: [WorkspaceTabSnapshot], candidates: [UUID]) {
  let managedReference = ManagedTerminalReference(
    server: SessionServerReference(
      machineProfileID: MachineProfile.localProfileID,
      serverID: "server-a",
      sessionID: "session-a"
    ),
    terminalID: "already-managed"
  )

  let terminalA = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp/a")
  let editor = PaneDescriptor(kind: .editor, workingDirectory: "/tmp/e", resourcePath: "/tmp/e/f.txt")
  let terminalB = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp/b")
  let web = PaneDescriptor(kind: .web, workingDirectory: "/tmp/w", resourcePath: "https://example.com")
  let fileBrowser = PaneDescriptor(kind: .fileBrowser, workingDirectory: "/tmp/fb")
  let managed = PaneDescriptor(
    kind: .terminal, workingDirectory: "/tmp/m", managedTerminal: managedReference)

  let tab1 = WorkspaceTabSnapshot(
    id: UUID(),
    title: "one",
    layout: .split(axis: .horizontal, first: .leaf(terminalA), second: .leaf(editor), ratio: 0.5)
  )
  let tab2 = WorkspaceTabSnapshot(
    id: UUID(),
    title: "two",
    layout: .split(
      axis: .vertical,
      first: .split(axis: .horizontal, first: .leaf(terminalB), second: .leaf(web), ratio: 0.4),
      second: .split(
        axis: .horizontal, first: .leaf(fileBrowser), second: .leaf(managed), ratio: 0.6),
      ratio: 0.5
    )
  )
  return ([tab1, tab2], [terminalA.id, terminalB.id])
}

/// 临时目录，用于备份文件读写。
private func migrationTempDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-migration-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}

@Test func managedTerminalMigrationCandidatesOnlyIncludeUnmanagedTerminals() throws {
  let fixture = migrationFixtureTabs()
  let candidates = ManagedTerminalMigration.candidates(in: fixture.tabs)

  #expect(candidates.count == 2)
  #expect(Set(candidates.map(\.paneID)) == Set(fixture.candidates))
  #expect(Set(candidates.map(\.workingDirectory)) == ["/tmp/a", "/tmp/b"])
  // tabID 必须指向 Pane 真正所在的标签。
  #expect(candidates.first(where: { $0.workingDirectory == "/tmp/a" })?.tabID == fixture.tabs[0].id)
  #expect(candidates.first(where: { $0.workingDirectory == "/tmp/b" })?.tabID == fixture.tabs[1].id)
}

@Test func managedTerminalMigrationSuccessAssignsReferencesAndWritesRestorableBackup() throws {
  let fixture = migrationFixtureTabs()
  let directory = try migrationTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let backupURL = directory.appendingPathComponent("backup.json")
  let client = FakeManagedSessionClient()

  let outcome = ManagedTerminalMigration.migrate(
    tabs: fixture.tabs,
    endpoint: migrationEndpoint,
    client: client,
    shellArguments: ["/bin/zsh", "-l"],
    backupURL: backupURL
  )

  #expect(outcome.succeeded)
  #expect(outcome.failure == nil)
  #expect(outcome.created.count == 2)
  #expect(outcome.backupURL == backupURL)

  let panes = outcome.tabs.flatMap(\.layout.allPanes)
  for paneID in fixture.candidates {
    let pane = try #require(panes.first(where: { $0.id == paneID }))
    #expect(pane.managedTerminal != nil)
    #expect(pane.managedTerminal == outcome.created[paneID])
  }
  // 非终端 Pane 与已托管 Pane 保持原样。
  let originalPanes = fixture.tabs.flatMap(\.layout.allPanes)
  for original in originalPanes where !fixture.candidates.contains(original.id) {
    #expect(panes.first(where: { $0.id == original.id }) == original)
  }

  // 备份必须能还原成迁移前的原始布局。
  #expect(FileManager.default.fileExists(atPath: backupURL.path))
  let restored = try ManagedTerminalMigration.restore(from: backupURL)
  #expect(restored == fixture.tabs)
}

@Test func managedTerminalMigrationServerUnreachableLeavesTabsUnchanged() throws {
  let fixture = migrationFixtureTabs()
  let directory = try migrationTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let client = FakeManagedSessionClient()
  client.ensureServerFailure = .runtimeUnavailable("/nonexistent/aster-session")

  let outcome = ManagedTerminalMigration.migrate(
    tabs: fixture.tabs,
    endpoint: migrationEndpoint,
    client: client,
    shellArguments: ["/bin/zsh"],
    backupURL: directory.appendingPathComponent("backup.json")
  )

  guard case .serverUnreachable = try #require(outcome.failure) else {
    Issue.record("expected .serverUnreachable, got \(String(describing: outcome.failure))")
    return
  }
  #expect(outcome.tabs == fixture.tabs)
  #expect(outcome.created.isEmpty)
  #expect(client.calls == [.ensureServer])
}

@Test func managedTerminalMigrationRollsBackOnlyTerminalsItCreated() throws {
  let fixture = migrationFixtureTabs()
  let directory = try migrationTempDirectory()
  defer { try? FileManager.default.removeItem(at: directory) }
  let client = FakeManagedSessionClient()
  client.failCreateOnCall = 2

  let outcome = ManagedTerminalMigration.migrate(
    tabs: fixture.tabs,
    endpoint: migrationEndpoint,
    client: client,
    shellArguments: ["/bin/zsh"],
    backupURL: directory.appendingPathComponent("backup.json")
  )

  guard case .terminalCreationFailed(let paneID, _) = try #require(outcome.failure) else {
    Issue.record("expected .terminalCreationFailed, got \(String(describing: outcome.failure))")
    return
  }
  #expect(fixture.candidates.contains(paneID))
  #expect(outcome.tabs == fixture.tabs)
  #expect(outcome.created.isEmpty)
  // 只清理本次事务创建的第一个新终端，不碰任何旧资源。
  #expect(client.calls.filter { $0 == .terminateTerminal(terminalID: "term-1") }.count == 1)
  #expect(client.calls.filter { if case .terminateTerminal = $0 { return true } else { return false } }.count == 1)
}

@Test func managedTerminalMigrationBackupFailureSkipsAllServerCalls() throws {
  let fixture = migrationFixtureTabs()
  let client = FakeManagedSessionClient()
  // 目录不存在，写入必然失败；事务必须在接触服务之前中止。
  let unwritable = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-missing-\(UUID().uuidString)", isDirectory: true)
    .appendingPathComponent("backup.json")

  let outcome = ManagedTerminalMigration.migrate(
    tabs: fixture.tabs,
    endpoint: migrationEndpoint,
    client: client,
    shellArguments: ["/bin/zsh"],
    backupURL: unwritable
  )

  guard case .persistenceFailed = try #require(outcome.failure) else {
    Issue.record("expected .persistenceFailed, got \(String(describing: outcome.failure))")
    return
  }
  #expect(outcome.tabs == fixture.tabs)
  #expect(outcome.created.isEmpty)
  #expect(outcome.backupURL == nil)
  #expect(client.calls.isEmpty)
}
