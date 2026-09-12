import AsterCore
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 空远端会话（服务端没有任何工作区）的首个工作区创建：
/// 活动机器刷新到空快照时自动建第一个工作区；「新建标签」在没有 workspaceID 时走 `workspace create`。
@Suite(.serialized)
@MainActor
struct RemoteEmptySessionWorkspaceTests {

  /// 脚本化传输：按调用顺序返回预置输出并记录 argv，不启动服务、不连网络。
  private final class ScriptedClient: ManagedSessionClient, @unchecked Sendable {
    private let lock = NSLock()
    private var scripted: [String]
    private(set) var invocations: [[String]] = []

    init(_ scripted: [String]) { self.scripted = scripted }

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
    "\"target\":{\"serverID\":\"srv-1\",\"serverEpoch\":\"epoch-1\",\"sessionID\":\"sess-1\"}"

  private static func emptySnapshot(revision: Int) -> String {
    "{\"type\":\"result\",\"revision\":\(revision),\(target),\"result\":{\"workspaces\":[],\"terminals\":[]}}"
  }

  private static let workspaceJSON =
    "{\"workspaceID\":\"ws-1\",\"title\":\"~\",\"cwd\":\"/\",\"tabs\":[{\"tabID\":\"tab-1\",\"title\":\"~\",\"layout\":{\"kind\":\"leaf\",\"pane\":{\"paneID\":\"\(paneA)\",\"terminalID\":\"term-a\"}}}]}"

  private static func createResult(revision: Int) -> String {
    "{\"type\":\"result\",\"revision\":\(revision),\(target),\"result\":\(workspaceJSON)}"
  }

  private static func filledSnapshot(revision: Int) -> String {
    "{\"type\":\"result\",\"revision\":\(revision),\(target),\"result\":{\"workspaces\":[\(workspaceJSON)],\"terminals\":[{\"terminalID\":\"term-a\",\"state\":\"running\",\"pid\":4242}]}}"
  }

  private func makeCoordinator(scripted: [String], machineID: UUID, active: Bool)
    -> (RemoteWorkspaceCoordinator, ScriptedClient, AppModel)
  {
    let model = AppModel()
    if active { model.switchMachine(to: machineID) }
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

  /// 等待脚本化客户端累计到指定次数的调用；事务在独立 Task 里提交，不能同步断言。
  private func waitForInvocations(_ client: ScriptedClient, count: Int) async {
    for _ in 0..<200 {
      if client.invocations.count >= count { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  @Test("活动机器刷新到空会话时自动创建第一个工作区，Shell 落在远端 $HOME")
  func activeMachineEmptySessionCreatesInitialWorkspace() async throws {
    let machineID = UUID()
    let (coordinator, client, model) = makeCoordinator(
      scripted: [
        Self.emptySnapshot(revision: 3), Self.createResult(revision: 4),
        Self.filledSnapshot(revision: 4),
      ],
      machineID: machineID, active: true)

    #expect(await coordinator.refresh(machineProfileID: machineID))
    await waitForInvocations(client, count: 3)

    let create = try #require(client.invocations.dropFirst().first)
    #expect(Array(create.prefix(2)) == ["workspace", "create"])
    #expect(create.contains("--expected-revision"))
    #expect(create.firstIndex(of: "--expected-revision").map { create[$0 + 1] } == "3")
    // cwd 用 POSIX 保证存在的 `/`，落脚点交给远端 Shell 自己 cd "$HOME"。
    #expect(create.firstIndex(of: "--cwd").map { create[$0 + 1] } == "/")
    #expect(create.last?.contains("cd \"$HOME\"") == true)
    // 成功后重新取快照并把新工作区渲染成标签。
    #expect(client.invocations.count == 3)
    #expect(model.tabs.count == 1)
    #expect(model.tabs.first?.remoteTabID == "tab-1")
  }

  @Test("后台机器的空会话不自动创建工作区")
  func backgroundMachineEmptySessionDoesNotCreateWorkspace() async throws {
    let machineID = UUID()
    // 协调器只弱引用模型，测试期间必须自己持有它，否则任何事务都会因模型已释放而被放弃。
    let (coordinator, client, model) = makeCoordinator(
      scripted: [Self.emptySnapshot(revision: 3)], machineID: machineID, active: false)
    #expect(await coordinator.refresh(machineProfileID: machineID))
    try? await Task.sleep(for: .milliseconds(100))
    #expect(client.invocations.count == 1)
    #expect(model.activeMachineID == MachineProfile.localProfileID)
  }

  @Test("首个工作区创建失败后不自动重试，避免刷新循环")
  func failedInitialWorkspaceIsNotRetried() async throws {
    let machineID = UUID()
    let (coordinator, client, model) = makeCoordinator(
      scripted: [
        Self.emptySnapshot(revision: 3),
        // workspace create 失败（脚本给出非法回复），随后刷新仍是空会话。
        "{\"type\":\"error\",\"code\":\"cwd_unavailable\",\"message\":\"no\"}",
        Self.emptySnapshot(revision: 3),
      ],
      machineID: machineID, active: true)
    #expect(await coordinator.refresh(machineProfileID: machineID))
    await waitForInvocations(client, count: 3)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(client.invocations.count == 3)
    #expect(coordinator.lastError != nil)
    #expect(model.tabs.isEmpty)
  }
}
