// 远端命名工作区测试的共享替身与快照样例：脚本化传输 + 记录 terminate 调用，不连网络。
import AsterCore
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 脚本化传输：结构化命令按顺序返回预置输出并记录 argv；`terminateTerminal` 只记录不执行。
///
/// 同一个替身既做事务客户端，也登记成该机器的受管终端协调器的传输：分离 / 关闭路径
/// 只要调用了 terminate，就一定落进 `terminatedTerminalIDs`，测试据此断言「隐藏不结束进程」。
final class NamedWorkspaceScriptedClient: ManagedSessionClient, @unchecked Sendable {
  private let lock = NSLock()
  private var scripted: [String]
  private var recordedInvocations: [[String]] = []
  private var recordedTerminations: [String] = []

  init(_ scripted: [String]) { self.scripted = scripted }

  /// 已收到的结构化命令 argv。
  var invocations: [[String]] {
    lock.lock()
    defer { lock.unlock() }
    return recordedInvocations
  }

  /// 已收到的 terminate 请求（terminalID）。
  var terminatedTerminalIDs: [String] {
    lock.lock()
    defer { lock.unlock() }
    return recordedTerminations
  }

  /// 追加后续脚本回复。
  func append(_ more: [String]) {
    lock.lock()
    defer { lock.unlock() }
    scripted += more
  }

  func executeStructured(binaryPath: String, arguments: [String]) throws -> String {
    lock.lock()
    defer { lock.unlock() }
    recordedInvocations.append(arguments)
    guard !scripted.isEmpty else {
      throw ManagedSessionError.malformedReply("脚本已用尽：\(arguments.joined(separator: " "))")
    }
    return scripted.removeFirst()
  }

  func terminateTerminal(_ endpoint: ManagedSessionEndpoint, terminalID: String) throws
    -> ManagedTerminalStatus
  {
    lock.lock()
    recordedTerminations.append(terminalID)
    lock.unlock()
    throw ManagedSessionError.runtimeUnavailable("terminate 不应在命名工作区切换中发生")
  }

  // 以下动作在本组用例里不使用；实现成明确失败，避免被误当成可用路径。
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
  func bridgeArguments(
    _ endpoint: ManagedSessionEndpoint, terminalID: String, readOnly: Bool, takeover: Bool
  ) -> [String] { [] }
}

/// 快照样例：ws-1（一个标签）与 ws-2（两个标签），与服务端 `workspaceValue` 同形状。
enum NamedWorkspaceSamples {
  static let paneA = "11111111-1111-4111-8111-111111111111"
  static let paneB = "22222222-2222-4222-8222-222222222222"
  static let paneC = "33333333-3333-4333-8333-333333333333"
  static let paneD = "44444444-4444-4444-8444-444444444444"
  static let target =
    "\"target\":{\"serverID\":\"srv-1\",\"serverEpoch\":\"epoch-1\",\"sessionID\":\"sess-1\"}"

  static func leafTab(_ tabID: String, title: String, pane: String, terminal: String) -> String {
    "{\"tabID\":\"\(tabID)\",\"title\":\"\(title)\",\"layout\":{\"kind\":\"leaf\",\"pane\":{\"paneID\":\"\(pane)\",\"terminalID\":\"\(terminal)\"}}}"
  }

  static let workspace1 =
    "{\"workspaceID\":\"ws-1\",\"title\":\"主工作区\",\"cwd\":\"/srv/one\",\"tabs\":[\(leafTab("tab-1", title: "api", pane: paneA, terminal: "term-a"))]}"
  static let workspace2 =
    "{\"workspaceID\":\"ws-2\",\"title\":\"发布\",\"cwd\":\"/srv/two\",\"tabs\":[\(leafTab("tab-2", title: "build", pane: paneB, terminal: "term-b")),\(leafTab("tab-3", title: "logs", pane: paneC, terminal: "term-c"))]}"
  static let workspace3 =
    "{\"workspaceID\":\"ws-3\",\"title\":\"实验\",\"cwd\":\"/\",\"tabs\":[\(leafTab("tab-4", title: "实验", pane: paneD, terminal: "term-d"))]}"

  static func terminals(_ ids: [String]) -> String {
    ids.map { "{\"terminalID\":\"\($0)\",\"state\":\"running\",\"pid\":4242}" }
      .joined(separator: ",")
  }

  /// 按给定工作区 JSON 拼出 `session.snapshot` 回复。
  static func snapshot(revision: Int, workspaces: [String], terminalIDs: [String]) -> String {
    "{\"type\":\"result\",\"revision\":\(revision),\(target),\"result\":{\"workspaces\":[\(workspaces.joined(separator: ","))],\"terminals\":[\(terminals(terminalIDs))]}}"
  }

  /// 两个工作区都在的快照。
  static func twoWorkspaces(revision: Int) -> String {
    snapshot(
      revision: revision, workspaces: [workspace1, workspace2],
      terminalIDs: ["term-a", "term-b", "term-c"])
  }

  /// 事务回复：`result` 是给定 JSON。
  static func result(revision: Int, _ body: String) -> String {
    "{\"type\":\"result\",\"revision\":\(revision),\(target),\"result\":\(body)}"
  }
}

/// 一组命名工作区用例的环境：协调器、替身、模型与独立 UserDefaults suite。
@MainActor
struct NamedWorkspaceFixture {
  let machineID: UUID
  let coordinator: RemoteWorkspaceCoordinator
  let client: NamedWorkspaceScriptedClient
  /// 协调器只弱引用模型，测试期间必须由这里持有。
  let model: AppModel
  let defaults: UserDefaults
  let suiteName: String
  /// `machineSelector` 被调用时收到的机器 ID。
  let selectorCalls: SelectorRecorder

  /// 记录 `machineSelector` 调用的盒子（闭包需要引用语义）。
  final class SelectorRecorder {
    var machineIDs: [UUID] = []
  }

  /// 建环境。`machineID` / `suiteName` 可复用以验证持久化跨协调器恢复。
  init(
    scripted: [String], active: Bool, machineID: UUID = UUID(),
    suiteName: String = "RemoteNamedWorkspace.\(UUID().uuidString)"
  ) throws {
    self.machineID = machineID
    self.suiteName = suiteName
    defaults = try #require(UserDefaults(suiteName: suiteName))
    model = AppModel()
    if active { model.switchMachine(to: machineID) }
    client = NamedWorkspaceScriptedClient(scripted)
    let endpoint = ManagedSessionEndpoint(
      machineProfileID: machineID, binaryPath: "/nonexistent/aster-session",
      stateParentPath: "/tmp", sessionName: "t")
    // 该机器的受管终端协调器也走同一个替身：任何 terminate 都会被记录下来。
    ManagedTerminalCoordinatorRegistry.register(
      ManagedTerminalCoordinator(
        client: client,
        environment: [
          ManagedTerminalCoordinator.binaryEnvironmentKey: endpoint.binaryPath,
          ManagedTerminalCoordinator.stateDirectoryEnvironmentKey: endpoint.stateParentPath,
          ManagedTerminalCoordinator.sessionNameEnvironmentKey: endpoint.sessionName,
        ],
        machineProfileID: machineID),
      for: machineID)
    let controller = RemoteWorkspaceController(
      clientID: "client-under-test",
      server: SessionServerReference(
        machineProfileID: machineID, serverID: "srv-1", sessionID: "sess-1"),
      transactions: WorkspaceTransactionClient(client: client, endpoint: endpoint))
    coordinator = RemoteWorkspaceCoordinator(
      model: model, selectionStore: RemoteWorkspaceSelectionStore(defaults: defaults))
    let recorder = SelectorRecorder()
    selectorCalls = recorder
    coordinator.machineSelector = { id in
      recorder.machineIDs.append(id)
      return nil
    }
    coordinator.register(controller: controller, forMachine: machineID)
  }

  /// 清理：停止协调器、删掉独立 suite 与注册的协调器。
  func tearDown() {
    coordinator.stopAllEventSubscriptions()
    defaults.removePersistentDomain(forName: suiteName)
    ManagedTerminalCoordinatorRegistry.reset(machineProfileID: machineID)
  }

  /// 标签栏上显示的远端 tabID。
  var shownRemoteTabIDs: [String?] { model.tabs(forMachine: machineID).map(\.remoteTabID) }

  /// 当前真实发出画面订阅的终端集合。
  var visibleTerminals: Set<String> {
    coordinator.controller(forMachine: machineID)?.interest.visibleSurfaces ?? []
  }

  /// 某个远端标签的本地实例（含隐藏工作区里的）。
  func tabInstance(_ remoteTabID: String) -> TerminalTabItem? {
    coordinator.workspaces[machineID]?.tabsByRemoteID[remoteTabID]
  }

  /// 等待替身累计到指定次数的结构化调用；事务在独立 Task 里提交，不能同步断言。
  func waitForInvocations(count: Int) async {
    for _ in 0..<200 {
      if client.invocations.count >= count { return }
      try? await Task.sleep(for: .milliseconds(10))
    }
  }

  /// 在 argv 里取某个选项后面的值。
  static func value(of option: String, in argv: [String]) -> String? {
    argv.firstIndex(of: option).flatMap { $0 + 1 < argv.count ? argv[$0 + 1] : nil }
  }
}
