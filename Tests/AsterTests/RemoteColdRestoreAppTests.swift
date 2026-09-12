import AsterCore
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 远端服务冷重启后的客户端冷恢复（P6.4 客户端半边）：
/// 快照里有窗格引用了已不存在的终端时自动请求 `session.restore` 并重取快照；
/// 同一批失效终端只请求一次；「重新启动 Shell」重新触发恢复，并把窗格运行态换绑到新终端。
@Suite(.serialized)
@MainActor
struct RemoteColdRestoreAppTests {

  /// 脚本化传输：按调用顺序返回预置输出并记录 argv，不启动服务、不连网络。
  private final class ScriptedClient: ManagedSessionClient, @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [String]
    private(set) var invocations: [[String]] = []

    init(_ scripted: [String]) { self.scripted = scripted }

    /// 追加后续脚本回复（用于「先失败、再重试成功」的两段式场景）。
    func append(_ more: [String]) {
      lock.lock()
      defer { lock.unlock() }
      scripted += more
    }

    func executeStructured(binaryPath: String, arguments: [String]) throws -> String {
      lock.lock()
      defer { lock.unlock() }
      invocations.append(arguments)
      guard !scripted.isEmpty else {
        throw ManagedSessionError.malformedReply("脚本已用尽：\(arguments.joined(separator: " "))")
      }
      return scripted.removeFirst()
    }

    func ensureServer(_ endpoint: ManagedSessionEndpoint) throws -> SessionServerReference {
      throw ManagedSessionError.runtimeUnavailable("unused")
    }
    func serverStatus(_ endpoint: ManagedSessionEndpoint) throws -> SessionServerIdentity {
      throw ManagedSessionError.runtimeUnavailable("unused")
    }
    func createTerminal(
      _ endpoint: ManagedSessionEndpoint, workingDirectory: String, argv: [String]
    ) throws -> ManagedTerminalStatus {
      throw ManagedSessionError.runtimeUnavailable("unused")
    }
    func listTerminals(_ endpoint: ManagedSessionEndpoint) throws -> [ManagedTerminalStatus] {
      throw ManagedSessionError.runtimeUnavailable("unused")
    }
    func terminateTerminal(_ endpoint: ManagedSessionEndpoint, terminalID: String) throws
      -> ManagedTerminalStatus
    {
      throw ManagedSessionError.runtimeUnavailable("unused")
    }
    func bridgeArguments(
      _ endpoint: ManagedSessionEndpoint, terminalID: String, readOnly: Bool
    ) -> [String] { [] }
  }

  private static let paneA = "11111111-1111-4111-8111-111111111111"
  private static let target =
    "\"target\":{\"serverID\":\"srv-1\",\"serverEpoch\":\"epoch-2\",\"sessionID\":\"sess-1\"}"

  private static func workspaceJSON(terminalID: String) -> String {
    "{\"workspaceID\":\"ws-1\",\"title\":\"~\",\"cwd\":\"/\",\"tabs\":[{\"tabID\":\"tab-1\",\"title\":\"~\",\"layout\":{\"kind\":\"leaf\",\"pane\":{\"paneID\":\"\(paneA)\",\"terminalID\":\"\(terminalID)\"}}}]}"
  }

  /// 冷重启后的快照：布局仍指向旧终端，但 `terminals` 里已经没有它。
  private static func staleSnapshot(revision: Int) -> String {
    "{\"type\":\"result\",\"revision\":\(revision),\(target),\"result\":{\"workspaces\":[\(workspaceJSON(terminalID: "term-old"))],\"terminals\":[]}}"
  }

  /// 恢复后的快照：同一 paneID 指向新终端，且新终端在运行。
  private static func restoredSnapshot(revision: Int) -> String {
    "{\"type\":\"result\",\"revision\":\(revision),\(target),\"result\":{\"workspaces\":[\(workspaceJSON(terminalID: "term-new"))],\"terminals\":[{\"terminalID\":\"term-new\",\"state\":\"running\",\"pid\":4243}]}}"
  }

  private static func restoreResult(revision: Int) -> String {
    "{\"type\":\"result\",\"revision\":\(revision),\(target),\"result\":{\"alreadyRestored\":false,\"entries\":[{\"paneID\":\"\(paneA)\",\"oldTerminalID\":\"term-old\",\"newTerminalID\":\"term-new\",\"path\":\"new_shell\"}]}}"
  }

  private static let restoreFailure =
    "{\"type\":\"error\",\"code\":\"transport\",\"message\":\"ssh exited 255\"}"

  private func makeCoordinator(scripted: [String], machineID: UUID)
    -> (RemoteWorkspaceCoordinator, ScriptedClient, AppModel)
  {
    let model = AppModel()
    model.switchMachine(to: machineID)
    let client = ScriptedClient(scripted)
    let server = SessionServerReference(
      machineProfileID: machineID, serverID: "srv-1", sessionID: "sess-1")
    let controller = RemoteWorkspaceController(
      clientID: "client-under-test", server: server,
      transactions: WorkspaceTransactionClient(
        client: client,
        endpoint: ManagedSessionEndpoint(
          machineProfileID: machineID, binaryPath: "/nonexistent/aster-session",
          stateParentPath: "/tmp", sessionName: "t")))
    let coordinator = RemoteWorkspaceCoordinator(model: model)
    coordinator.register(controller: controller, forMachine: machineID)
    return (coordinator, client, model)
  }

  /// 等待脚本化客户端累计到指定次数的调用；重试经通知异步触发，不能同步断言。
  private func waitForInvocations(_ client: ScriptedClient, count: Int) async {
    for _ in 0..<200 {
      if client.invocations.count >= count { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  private func boundTerminalID(_ model: AppModel) -> String? {
    model.tabs.first?.layout.allPanes.first?.managedTerminal?.terminalID
  }

  @Test("快照里的失效窗格自动触发 session.restore 并按恢复后的快照渲染")
  func staleSnapshotTriggersRestoreAndRerenders() async throws {
    let machineID = UUID()
    let (coordinator, client, model) = makeCoordinator(
      scripted: [
        Self.staleSnapshot(revision: 3), Self.restoreResult(revision: 4),
        Self.restoredSnapshot(revision: 4),
      ],
      machineID: machineID)

    #expect(await coordinator.refresh(machineProfileID: machineID))
    #expect(client.invocations.count == 3)
    let restore = try #require(client.invocations.dropFirst().first)
    #expect(
      restore == [
        "session", "restore", "/tmp", "t",
        "--rows", String(RemoteWorkspaceCoordinator.restoreGeometry.rows),
        "--columns", String(RemoteWorkspaceCoordinator.restoreGeometry.columns),
      ])
    #expect(Array(client.invocations.last?.prefix(2) ?? []) == ["session", "snapshot"])
    #expect(coordinator.lastError == nil)
    // 界面拿到的是恢复后的结构：同一 paneID 已经指向新终端。
    #expect(model.tabs.count == 1)
    #expect(boundTerminalID(model) == "term-new")
    let runtime = try #require(model.tabs.first?.runtime(for: UUID(uuidString: Self.paneA)!))
    #expect(runtime.descriptor.managedTerminal?.terminalID == "term-new")
  }

  @Test("同一批失效终端只请求一次恢复；失败后再次刷新不自旋")
  func restoreIsNotRepeatedForSameStaleSet() async throws {
    let machineID = UUID()
    let (coordinator, client, model) = makeCoordinator(
      scripted: [
        Self.staleSnapshot(revision: 3), Self.restoreFailure,
        Self.staleSnapshot(revision: 3),
      ],
      machineID: machineID)

    // 第一次：快照 → 恢复失败。结构照常显示，错误进入 lastError。
    #expect(await coordinator.refresh(machineProfileID: machineID) == false)
    #expect(client.invocations.count == 2)
    #expect(coordinator.lastError?.contains("冷恢复失败") == true)
    #expect(model.tabs.count == 1)
    #expect(boundTerminalID(model) == "term-old")

    // 第二次刷新（例如一条服务端事件）：失效集合没变，只取快照，不再请求恢复。
    #expect(await coordinator.refresh(machineProfileID: machineID))
    #expect(client.invocations.count == 3)
    #expect(Array(client.invocations.last?.prefix(2) ?? []) == ["session", "snapshot"])
  }

  @Test("「重新启动 Shell」重新触发恢复，并把窗格运行态换绑到新终端")
  func restartShellRetriesRestoreAndRebindsPane() async throws {
    let machineID = UUID()
    let (coordinator, client, model) = makeCoordinator(
      scripted: [Self.staleSnapshot(revision: 3), Self.restoreFailure],
      machineID: machineID)
    #expect(await coordinator.refresh(machineProfileID: machineID) == false)
    let paneID = try #require(UUID(uuidString: Self.paneA))
    let staleRuntime = try #require(model.tabs.first?.runtime(for: paneID))
    #expect(staleRuntime.descriptor.managedTerminal?.terminalID == "term-old")

    // 用户点「重新启动 Shell」：受管失败窗格不重建本地 surface，而是转发给协调器重试。
    client.append([
      Self.staleSnapshot(revision: 3), Self.restoreResult(revision: 4),
      Self.restoredSnapshot(revision: 4),
    ])
    let session = try #require(staleRuntime.terminalSession)
    NotificationCenter.default.post(name: TerminalSession.managedRetryRequested, object: session)
    await waitForInvocations(client, count: 5)
    try? await Task.sleep(for: .milliseconds(50))

    #expect(client.invocations.count == 5)
    #expect(Array(client.invocations[3].prefix(2)) == ["session", "restore"])
    #expect(coordinator.lastError == nil)
    // 同一 paneID 换了终端：旧运行态被换掉，新运行态绑定新 terminalID。
    let rebound = try #require(model.tabs.first?.runtime(for: paneID))
    #expect(rebound !== staleRuntime)
    #expect(rebound.descriptor.managedTerminal?.terminalID == "term-new")
    #expect(boundTerminalID(model) == "term-new")
  }
}
