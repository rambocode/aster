import AsterCore
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// P4.2 / P4.2a / P4.6 的 App 侧定向测试。
///
/// 用脚本化的 `ManagedSessionClient` 替身驱动真实的事务客户端与投影，不启动服务、不连网络。
@Suite(.serialized)
@MainActor
struct RemoteWorkspaceControllerTests {

  /// 脚本化传输：按调用顺序返回预置的结构化输出，并记录收到的 argv。
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

    // 以下动作在本用例里不使用；实现成明确失败，避免被误当成可用路径。
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

  private static let server = SessionServerReference(
    machineProfileID: UUID(), serverID: "srv-1", sessionID: "sess-1")

  private static let paneA = "11111111-1111-4111-8111-111111111111"
  private static let paneB = "22222222-2222-4222-8222-222222222222"

  /// 与 `SessionRuntime/src/workspace_store.zig` 的 `workspaceValue / layoutValue` 同形状。
  private static func snapshotJSON(revision: Int) -> String {
    """
    {"type":"result","revision":\(revision),\
    "target":{"serverID":"srv-1","serverEpoch":"epoch-1","sessionID":"sess-1"},\
    "result":{"workspaces":[{"workspaceID":"ws-1",\
    "title":"远端","cwd":"/srv/app","tabs":[{"tabID":"tab-1","title":"构建","layout":\
    {"kind":"split","axis":"horizontal","ratio":0.4,\
    "first":{"kind":"leaf","pane":{"paneID":"\(paneA)","terminalID":"term-a"}},\
    "second":{"kind":"leaf","pane":{"paneID":"\(paneB)","terminalID":"term-b"}}}}]}],\
    "terminals":[{"terminalID":"term-a","state":"running","pid":4242,"cwd":"/srv/app/api"},\
    {"terminalID":"term-b","state":"running","pid":4243}]}}
    """
  }

  private func makeController(_ scripted: [String]) -> (RemoteWorkspaceController, ScriptedClient) {
    let client = ScriptedClient(scripted)
    let controller = RemoteWorkspaceController(
      clientID: "client-under-test",
      server: Self.server,
      transactions: WorkspaceTransactionClient(
        client: client,
        endpoint: ManagedSessionEndpoint(
          machineProfileID: Self.server.machineProfileID,
          binaryPath: "/nonexistent/aster-session", stateParentPath: "/tmp", sessionName: "t")))
    return (controller, client)
  }

  // MARK: - P4.2 投影

  @Test("服务端快照投影成现有分屏树：leaf 是受管终端，paneID 与 cwd 来自服务端")
  func projectionMapsSnapshotToPaneLayout() async throws {
    let (controller, _) = makeController([Self.snapshotJSON(revision: 7)])
    let projected = try await controller.synchronize()

    #expect(projected.revision == 7)
    #expect(controller.revision == 7)
    #expect(!controller.needsResynchronization)
    let tab = try #require(projected.workspaces.first?.tabs.first)
    #expect(tab.tabID == "tab-1")

    guard case .split(let axis, let first, let second, let ratio) = tab.layout else {
      Issue.record("应投影成分屏")
      return
    }
    #expect(axis == .horizontal)
    #expect(abs(ratio - 0.4) < 0.0001)

    guard case .leaf(let left) = first, case .leaf(let right) = second else {
      Issue.record("两侧都应是叶节点")
      return
    }
    // paneID 直接复用服务端身份，刷新时不会被当成新 Pane 而重建终端视图。
    #expect(left.id.uuidString.lowercased() == Self.paneA)
    #expect(right.id.uuidString.lowercased() == Self.paneB)
    #expect(left.kind == .terminal)
    #expect(left.managedTerminal?.terminalID == "term-a")
    #expect(left.managedTerminal?.server == Self.server)
    // 远端 cwd 由执行机器给出；服务端没给的用工作区 cwd，不回落到本机目录。
    #expect(left.workingDirectory == "/srv/app/api")
    #expect(right.workingDirectory == "/srv/app")
    #expect(projected.terminalStatusByPaneID[left.id]?.pid == 4242)
  }

  @Test("投影的第二次快照保持同一 Pane 身份，界面不会重建终端")
  func projectionIsStableAcrossSnapshots() async throws {
    let (controller, _) = makeController([
      Self.snapshotJSON(revision: 7), Self.snapshotJSON(revision: 8),
    ])
    let first = try await controller.synchronize()
    let second = try await controller.synchronize()
    #expect(first.workspaces[0].tabs[0].layout.allPanes.map(\.id)
      == second.workspaces[0].tabs[0].layout.allPanes.map(\.id))
    #expect(controller.revision == 8)
  }

  @Test("revision 冲突：取新 revision 后重试同一意图，用户操作不丢失")
  func revisionConflictRetriesSameIntent() async throws {
    let conflict = """
      {"type":"error","currentRevision":9,\
      "error":{"code":"revision_conflict","message":"另一个客户端先提交了"}}
      """
    let success = """
      {"type":"result","revision":10,\
      "target":{"serverID":"srv-1","serverEpoch":"epoch-1","sessionID":"sess-1"},\
      "result":{"tabID":"tab-2","title":"新标签",\
      "layout":{"kind":"leaf","pane":{"paneID":"\(Self.paneB)","terminalID":"term-c"}}}}
      """
    let (controller, client) = makeController([
      Self.snapshotJSON(revision: 7), conflict, success,
    ])
    try await controller.synchronize()

    let tab = try await controller.createTab(
      workspaceID: "ws-1", title: "新标签",
      terminal: RemoteTerminalSpec(cwd: "/srv/app", argv: ["/bin/zsh", "-l", "-i"]))
    #expect(tab.tabID == "tab-2")
    #expect(controller.revision == 10)
    // 结构已变，必须重新取快照，不能就地猜测新树。
    #expect(controller.needsResynchronization)

    // 两次提交都必须是同一个意图（同一 workspace 与标题），只是 expectedRevision 不同。
    let submits = client.invocations.filter { $0.first == "tab" }
    #expect(submits.count == 2)
    #expect(submits[0].contains("ws-1") && submits[1].contains("ws-1"))
    #expect(submits[0] != submits[1])
  }

  // MARK: - 事件流

  @Test("事件序号：连续应用、重复丢弃、缺口要求重新取快照")
  func eventSequenceGapForcesResync() async throws {
    let (controller, _) = makeController([
      Self.snapshotJSON(revision: 7), Self.snapshotJSON(revision: 11),
    ])
    try await controller.synchronize()

    #expect(controller.consume(eventSequence: 1) == .applied)
    #expect(controller.consume(eventSequence: 2) == .applied)
    #expect(controller.consume(eventSequence: 2) == .duplicate)
    // 缺口：3 丢失。缓存不能再被当成最新。
    #expect(controller.consume(eventSequence: 4) == .gap)
    #expect(controller.needsResynchronization)
    // 缺口未解决之前，后续事件一律按 gap 处理。
    #expect(controller.consume(eventSequence: 5) == .gap)

    try await controller.synchronize()
    #expect(!controller.needsResynchronization)
  }

  // MARK: - P4.2a 混合布局

  @Test("只有受管终端进入共享结构；本地文件 Pane 留在来源客户端")
  func mixedLayoutSubmitsOnlyManagedTerminals() {
    let (controller, _) = makeController([])
    let managed = PaneDescriptor(
      kind: .terminal, workingDirectory: "/srv/app",
      managedTerminal: ManagedTerminalReference(server: Self.server, terminalID: "term-a"))
    let localFile = PaneDescriptor(
      kind: .editor, workingDirectory: "/Users/me/proj",
      resourcePath: "/Users/me/proj/README.md")
    let layout = PaneLayout.split(
      axis: .vertical, first: .leaf(managed), second: .leaf(localFile), ratio: 0.6)

    controller.captureLocalAssociations(from: layout)
    let submission = controller.submission(for: layout)

    // 共享结构只剩受管终端那一支；本地 Pane 的身份被单独保留在来源客户端。
    guard case .leaf(let remote)? = submission.layout else {
      Issue.record("共享结构应只剩一个受管叶节点")
      return
    }
    #expect(remote.terminalID == "term-a")
    #expect(submission.retainedLocalPaneIDs == [localFile.id])
    #expect(controller.localAssociations[localFile.id]?.resourcePath == "/Users/me/proj/README.md")
  }

  @Test("其他客户端只拿到终端共享结构，不会收到来源客户端的本地资源路径")
  func otherClientsNeverSeeLocalResources() {
    let (source, _) = makeController([])
    let (other, _) = makeController([])
    let managed = PaneDescriptor(
      id: UUID(uuidString: Self.paneA)!,
      kind: .terminal, workingDirectory: "/srv/app",
      resourcePath: "/Users/me/secret.txt",
      managedTerminal: ManagedTerminalReference(server: Self.server, terminalID: "term-a"))
    let layout = PaneLayout.leaf(managed)
    source.captureLocalAssociations(from: layout)

    let shared = PaneLayout.leaf(
      PaneDescriptor(
        id: managed.id, kind: .terminal, workingDirectory: "/srv/app",
        managedTerminal: ManagedTerminalReference(server: Self.server, terminalID: "term-a")))
    let projected = ProjectedRemoteTab(tabID: "tab-1", title: "t", layout: shared)

    // 来源客户端恢复自己的本地关联。
    #expect(source.displayLayout(for: projected).allPanes.first?.resourcePath
      == "/Users/me/secret.txt")
    // 其他客户端没有这份关联，因此拿到的结构里没有任何本机路径。
    #expect(other.displayLayout(for: projected).allPanes.first?.resourcePath == nil)
  }

  @Test("远端工作区禁用本机文件类动作并给出原因")
  func remoteWorkspaceDisablesLocalFileActions() {
    let (controller, _) = makeController([])
    for action in RemoteWorkspaceBoundary.LocalAction.allCases {
      #expect(!controller.allowsLocalAction(action))
      #expect(!controller.disabledReason(action, machineLabel: "orb").isEmpty)
    }
    #expect(controller.disabledReason(.openFilePane, machineLabel: "orb").contains("orb"))
  }

  // MARK: - P4.6 焦点与画面兴趣

  @Test("隐藏取消画面订阅；重新可见先快照后放行输入；焦点属于本客户端")
  func surfaceInterestLifecycle() {
    let (controller, _) = makeController([])
    let intents = controller.setVisibleTerminals(["term-a", "term-b"])
    #expect(intents.contains(.subscribe(terminalID: "term-a")))
    #expect(intents.contains(.requestSnapshot(terminalID: "term-a")))
    // 快照未确认之前不放行输入。
    #expect(!controller.allowsInput(terminalID: "term-a"))
    controller.confirmSnapshot(terminalID: "term-a")
    #expect(controller.allowsInput(terminalID: "term-a"))

    // 隐藏必须真实发出 unsubscribe，而不是「只是不画」。
    let hidden = controller.setVisibleTerminals(["term-b"])
    #expect(hidden == [.unsubscribe(terminalID: "term-a")])
    #expect(!controller.allowsInput(terminalID: "term-a"))

    // 整个客户端隐藏：全部画面订阅取消。
    let suspended = controller.suspendAllSurfaces()
    #expect(suspended.contains(.unsubscribe(terminalID: "term-b")))
    #expect(controller.interest.visibleSurfaces.isEmpty)

    // 焦点是本客户端事实。
    let paneID = UUID()
    controller.focus(paneID: paneID)
    #expect(controller.interest.focusedPaneID == paneID)
    let (other, _) = makeController([])
    #expect(other.interest.focusedPaneID == nil)
  }

  @Test("连接重建后订阅与事件游标全部作废，必须重新快照")
  func connectionLossInvalidatesEverything() async throws {
    let (controller, _) = makeController([Self.snapshotJSON(revision: 7)])
    try await controller.synchronize()
    _ = controller.setVisibleTerminals(["term-a"])
    controller.confirmSnapshot(terminalID: "term-a")
    #expect(controller.allowsInput(terminalID: "term-a"))
    #expect(controller.consume(eventSequence: 1) == .applied)

    _ = controller.connectionLost()
    #expect(controller.needsResynchronization)
    #expect(!controller.allowsInput(terminalID: "term-a"))
    // 新连接必须重置游标：旧连接的序号不能当基线。
    #expect(controller.consume(eventSequence: 2) == .gap)
  }

  @Test("尺寸更新只允许可见、持写租约且闸门已开的控制器")
  func resizeRequiresVisibleLeaseAndOpenGate() {
    let (controller, _) = makeController([])
    #expect(controller.resizeDecision(terminalID: "term-a") == .rejected(.notVisible))
    _ = controller.setVisibleTerminals(["term-a"])
    #expect(controller.resizeDecision(terminalID: "term-a") == .rejected(.noWriteLease))
    controller.acquireWriteLease(terminalID: "term-a")
    #expect(controller.resizeDecision(terminalID: "term-a") == .rejected(.gateNotOpen))
    controller.confirmSnapshot(terminalID: "term-a")
    #expect(controller.resizeDecision(terminalID: "term-a") == .allowed)
    controller.releaseWriteLease(terminalID: "term-a")
    #expect(controller.resizeDecision(terminalID: "term-a") == .rejected(.noWriteLease))
  }
}
