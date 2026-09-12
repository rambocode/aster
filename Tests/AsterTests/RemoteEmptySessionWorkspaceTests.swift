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

  @Test("以 Agent 身份新建标签：登录 Shell exec 该 CLI，标题是 provider 名，PATH 交给远端")
  func createAgentTabExecsProviderInLoginShell() async throws {
    let machineID = UUID()
    let (coordinator, client, model) = makeCoordinator(
      scripted: [
        Self.filledSnapshot(revision: 4),
        // tab create 结果 + 事后快照
        "{\"type\":\"result\",\"revision\":5,\(Self.target),\"result\":{\"tabID\":\"tab-2\",\"title\":\"Grok Build\",\"layout\":{\"kind\":\"leaf\",\"pane\":{\"paneID\":\"\(Self.paneA)\",\"terminalID\":\"term-b\"}}}}",
        Self.filledSnapshot(revision: 5),
      ],
      machineID: machineID, active: true)
    #expect(await coordinator.refresh(machineProfileID: machineID))
    #expect(model.tabs.count == 1)

    // 命令面板 / 菜单都走 AppModel.launchAgent：活动机器是远端时必须转成服务端事务。
    // 真实流程里 `remoteStructureHandler` 由 beginActivation 挂上；这里直接注入协调器。
    model.remoteStructureHandler = coordinator
    model.launchAgent(.grokBuild)
    await waitForInvocations(client, count: 3)

    let create = try #require(client.invocations.dropFirst().first)
    #expect(Array(create.prefix(2)) == ["tab", "create"])
    #expect(create.firstIndex(of: "--title").map { create[$0 + 1] } == "Grok Build")
    // cwd 来自服务端快照里的工作区目录，不是本机目录。
    #expect(create.firstIndex(of: "--cwd").map { create[$0 + 1] } == "/")
    let separator = try #require(create.firstIndex(of: "--"))
    #expect(
      Array(create[(separator + 1)...])
        == ["/bin/sh", "-lc", "'grok'; exec \"${SHELL:-/bin/sh}\" -l -i"])
  }

  @Test("远端 Agent argv：命令名按单引号编码；没有服务端 cwd 时先 cd \"$HOME\"")
  func remoteAgentArgvQuotesAndLandsInHome() {
    let tail = "; exec \"${SHELL:-/bin/sh}\" -l -i"
    #expect(
      ManagedTerminalLaunchSpec.remoteAgentArgv(command: "claude", landsInHome: false)
        == ["/bin/sh", "-lc", "'claude'" + tail])
    #expect(
      ManagedTerminalLaunchSpec.remoteAgentArgv(
        command: "it's", arguments: ["--flag", "a b"], landsInHome: true)
        == ["/bin/sh", "-lc", "cd \"$HOME\" 2>/dev/null; 'it'\\''s' '--flag' 'a b'" + tail])
  }

  @Test("对已结束的受管窗格点「重新启动 Shell」：只重启该窗格，并用 --force 绕过一次性守卫")
  func retryEndedManagedPaneRestoresOnlyThatPane() async throws {
    let machineID = UUID()
    let restoreResult =
      "{\"type\":\"result\",\"revision\":5,\(Self.target),\"result\":{\"entries\":[{\"paneID\":\"\(Self.paneA)\",\"oldTerminalID\":\"term-a\",\"newTerminalID\":\"term-c\",\"path\":\"new_shell\"}],\"alreadyRestored\":false}}"
    // 终端"已退出但仍在快照里"（state=exited）：常规冷恢复不算它失效。
    let exitedSnapshot = Self.filledSnapshot(revision: 4)
      .replacingOccurrences(of: "\"state\":\"running\"", with: "\"state\":\"exited\",\"exitCode\":0")
    let (coordinator, client, model) = makeCoordinator(
      scripted: [exitedSnapshot, exitedSnapshot, restoreResult, Self.filledSnapshot(revision: 5)],
      machineID: machineID, active: true)
    #expect(await coordinator.refresh(machineProfileID: machineID))
    let tab = try #require(model.tabs.first)
    let pane = try #require(tab.layout.allPanes.first)
    let session = try #require(tab.runtime(for: pane.id)?.terminalSession)
    // 模拟远端进程结束后的本地状态：结束卡就是在这个状态下出现的。
    session.markManagedFailure("受管终端已退出（exit 0）。")
    session.simulateManagedExitForTesting(code: 0)

    await coordinator.retryStalePanes(for: session)

    // 顺序：常规刷新（快照）→ 只对该窗格 force 恢复 → 再取快照。
    #expect(client.invocations.count == 4)
    let restore = client.invocations[2]
    #expect(Array(restore.prefix(2)) == ["session", "restore"])
    #expect(restore.contains("--force"))
    #expect(restore.firstIndex(of: "--pane").map { restore[$0 + 1] } == Self.paneA)
    #expect(coordinator.lastError == nil)
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
