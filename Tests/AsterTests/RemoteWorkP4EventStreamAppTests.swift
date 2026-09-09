import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// P4.2 事件流的**真实远端**验收（A15.1 的实时一致性部分）。
//
// 两个客户端连同一个命名会话：一个是 App 侧协调器（含它自己的事件订阅进程），
// 另一个是完全独立的真实 CLI 进程。CLI 侧提交一次真实 `pane.split`，App 侧必须
// **仅凭事件流**自动刷新出新结构——用例全程不调用 activate / refresh，也不提交
// 任何本地事务。同时断言订阅不抢焦点：活动机器、选中标签、活动 Pane 都不变。
//
// 默认关闭：需要 ASTER_P4_ORB=1 与全部远端环境变量；关闭时记 skipped，
// 绝不用替身冒充真实链路。

/// 真实远端事件流验收所需的环境。任一项缺失即视为「未开启」。
private struct RemoteWorkP4StreamEnvironment {
  let sshTarget: String
  let remoteBinary: String
  let stateDirectory: String
  let sessionName: String

  static var isEnabled: Bool { current() != nil }

  static func current() -> RemoteWorkP4StreamEnvironment? {
    let environment = ProcessInfo.processInfo.environment
    guard environment["ASTER_P4_ORB"] == "1",
      let sshTarget = environment[RemoteEnvironmentKeys.remoteTarget], !sshTarget.isEmpty,
      let remoteBinary = environment[RemoteEnvironmentKeys.remoteBinary] ?? environment[
        RemoteEnvironmentKeys.binary], !remoteBinary.isEmpty,
      let stateDirectory = environment[RemoteEnvironmentKeys.stateDirectory],
      !stateDirectory.isEmpty
    else { return nil }
    return RemoteWorkP4StreamEnvironment(
      sshTarget: sshTarget,
      remoteBinary: remoteBinary,
      stateDirectory: stateDirectory,
      sessionName: environment[RemoteEnvironmentKeys.sessionName] ?? "work2")
  }

  func coordinatorEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment[RemoteEnvironmentKeys.binary] = remoteBinary
    environment[RemoteEnvironmentKeys.stateDirectory] = stateDirectory
    environment[RemoteEnvironmentKeys.sessionName] = sessionName
    environment[RemoteEnvironmentKeys.remoteTarget] = sshTarget
    return environment
  }
}

/// 第二个客户端：一个完全独立的真实 CLI 进程。
///
/// 刻意不复用被测代码的传输：如果两侧共用同一条连接，就证明不了「另一个客户端
/// 改了共享工作区，本客户端通过事件流自动看见」。
@discardableResult
private func remoteCLI(
  _ environment: RemoteWorkP4StreamEnvironment, _ arguments: [String]
) throws -> [String: Any] {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
  // OpenSSH 必然把远端命令交给登录 Shell，因此逐参数做 POSIX 单引号转义；
  // 不转义的话 `while :; do sleep 1; done` 会被远端 bash 当成语法错误。
  process.arguments = [
    "-o", "BatchMode=yes", environment.sshTarget,
    RemoteSSHInvocation.shellQuoted([environment.remoteBinary] + arguments),
  ]
  let pipe = Pipe()
  let errors = Pipe()
  process.standardOutput = pipe
  process.standardError = errors
  try process.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  // 诊断必须留下来：远端命令失败时空 stdout 什么都说明不了。
  let diagnostics = errors.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard let line = String(decoding: data, as: UTF8.self).split(separator: "\n").last,
    let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
  else {
    throw RemoteWorkP4StreamError.unreadable(
      "argv=\(arguments) status=\(process.terminationStatus) "
        + "stdout=\(String(decoding: data, as: UTF8.self)) "
        + "stderr=\(String(decoding: diagnostics, as: UTF8.self))")
  }
  return object
}

private enum RemoteWorkP4StreamError: Error { case unreadable(String) }

/// 直接向服务端要一份权威快照（revision + 第一个 pane 的身份），绕开被测代码。
private func remoteStreamSnapshot(_ environment: RemoteWorkP4StreamEnvironment) throws
  -> (revision: UInt64, paneID: String, cwd: String, paneCount: Int)
{
  let object = try remoteCLI(
    environment, ["session", "snapshot", environment.stateDirectory, environment.sessionName])
  guard let revision = (object["revision"] as? NSNumber)?.uint64Value,
    let result = object["result"]
  else { throw RemoteWorkP4StreamError.unreadable("\(object)") }
  struct Body: Decodable { var workspaces: [RemoteWorkspace] }
  let body = try JSONDecoder().decode(
    Body.self, from: try JSONSerialization.data(withJSONObject: result))
  var panes: [String] = []
  func collect(_ node: RemoteLayoutNode) {
    switch node {
    case .leaf(let pane): panes.append(pane.paneID)
    case .split(_, _, let first, let second):
      collect(first)
      collect(second)
    }
  }
  for workspace in body.workspaces { for tab in workspace.tabs { collect(tab.layout) } }
  guard let first = panes.first, let cwd = body.workspaces.first?.cwd else {
    throw RemoteWorkP4StreamError.unreadable("共享会话里没有任何 pane，无法做事件流验收")
  }
  return (revision, first, cwd, panes.count)
}

@MainActor
private struct RemoteWorkP4StreamFixture {
  let window: NSWindow
  let controller: WorkspaceViewController
  let model: AppModel
  let machineProfileID: UUID
  let suiteName: String
  let defaults: UserDefaults

  func tearDown() {
    // 走 `loadedRemoteWorkspaces`：收尾路径不应该反过来现造一个协调器。
    controller.loadedRemoteWorkspaces?.stopAllEventSubscriptions()
    // 远端受管终端一律按**分离**收尾，绝不结束真实远端进程。
    for tab in model.tabs {
      for runtime in tab.runtimes.values { runtime.terminalSession?.detachManagedTerminal() }
    }
    window.orderOut(nil)
    ManagedTerminalCoordinatorRegistry.reset()
    defaults.removePersistentDomain(forName: suiteName)
  }
}

@MainActor
private func makeRemoteWorkP4StreamFixture(_ environment: RemoteWorkP4StreamEnvironment) throws
  -> RemoteWorkP4StreamFixture
{
  let suiteName = "RemoteWorkP4Stream.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  preferences.tabBarLayout = .vertical
  model.ensureInitialTab()

  let machineProfileID = UUID()
  ManagedTerminalCoordinatorRegistry.reset()
  ManagedTerminalCoordinatorRegistry.register(
    ManagedTerminalCoordinator(
      environment: environment.coordinatorEnvironment(), machineProfileID: machineProfileID),
    for: machineProfileID)

  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false)
  window.contentViewController = controller
  window.contentView?.layoutSubtreeIfNeeded()
  return RemoteWorkP4StreamFixture(
    window: window, controller: controller, model: model, machineProfileID: machineProfileID,
    suiteName: suiteName, defaults: defaults)
}

/// 轮询等待。真实远端是 SSH 往返 + 事件推送，不能用固定 sleep 假装同步。
@MainActor
private func waitForStream(
  timeout: Duration = .seconds(45),
  _ condition: () -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(120))
  }
  return condition()
}

@Test(
  "remoteWorkP4：另一个真实 CLI 客户端的 pane.split 通过事件流自动刷新本客户端，且不抢焦点",
  .enabled(if: RemoteWorkP4StreamEnvironment.isEnabled))
@MainActor
func remoteWorkP4EventStreamRefreshesFromAnotherClientWithoutStealingFocus() async throws {
  let environment = try #require(RemoteWorkP4StreamEnvironment.current())
  let fixture = try makeRemoteWorkP4StreamFixture(environment)
  defer { fixture.tearDown() }

  let coordinator = fixture.controller.remoteWorkspaces
  await coordinator.activate(machineProfileID: fixture.machineProfileID)
  let controller = try #require(coordinator.controller(forMachine: fixture.machineProfileID))
  // 事件订阅是独立于画面订阅的一条真实流；没有它，下面的自动刷新不可能发生。
  #expect(coordinator.hasEventSubscription(forMachine: fixture.machineProfileID))

  let before = try remoteStreamSnapshot(environment)
  #expect(controller.revision == before.revision)
  let beforePaneIDs = Set(fixture.model.tabs.flatMap { $0.layout.allPanes.map(\.id) })
  let beforeActiveMachine = fixture.model.activeMachineID
  let beforeSelectedTab = fixture.model.selectedTabID
  let beforeActivePane = fixture.model.selectedTab?.activePaneID

  // 第二个客户端：独立进程提交一次真实 pane.split。
  let split = try remoteCLI(
    environment,
    [
      "pane", "split", environment.stateDirectory, environment.sessionName,
      "--pane", before.paneID, "--direction", "right",
      "--expected-revision", String(before.revision),
      "--cwd", before.cwd, "--", "/bin/sh", "-c", "while :; do sleep 1; done",
    ])
  #expect(split["error"] == nil, "另一个客户端的事务必须成功：\(split)")
  let splitRevision = try #require((split["revision"] as? NSNumber)?.uint64Value)
  #expect(splitRevision > before.revision)

  // 关键断言：本用例不再调用 activate / refresh，也不提交任何本地事务。
  // 结构如果刷新了，唯一可能的来源就是事件流。
  let refreshed = await waitForStream {
    controller.revision == splitRevision
      && !Set(fixture.model.tabs.flatMap { $0.layout.allPanes.map(\.id) })
        .subtracting(beforePaneIDs).isEmpty
  }
  #expect(
    refreshed,
    "事件流必须让本客户端自动刷新：期望 revision \(splitRevision)，实际 \(controller.revision)，错误：\(coordinator.lastError ?? "无")"
  )

  let afterPaneIDs = Set(fixture.model.tabs.flatMap { $0.layout.allPanes.map(\.id) })
  let added = afterPaneIDs.subtracting(beforePaneIDs)
  #expect(added.count == 1, "另一个客户端的分屏应恰好新增一个 Pane")
  #expect(afterPaneIDs.count == before.paneCount + 1)

  // 订阅是被动的：既不切换活动机器，也不移动选中标签或活动 Pane。
  #expect(fixture.model.activeMachineID == beforeActiveMachine, "事件刷新不得改变当前活动机器")
  #expect(fixture.model.selectedTabID == beforeSelectedTab, "事件刷新不得改变选中标签")
  #expect(fixture.model.selectedTab?.activePaneID == beforeActivePane, "事件刷新不得抢焦点")

  // 收尾：同样由第二个客户端关掉这次新建的 Pane，本客户端仍然只靠事件流跟上。
  let closed = try remoteCLI(
    environment,
    [
      "pane", "close", environment.stateDirectory, environment.sessionName,
      "--pane", added.first!.uuidString.lowercased(),
      "--expected-revision", String(splitRevision),
    ])
  #expect(closed["error"] == nil, "收尾关闭必须成功：\(closed)")
  let cleaned = await waitForStream {
    !fixture.model.tabs.flatMap { $0.layout.allPanes.map(\.id) }.contains(added.first!)
  }
  #expect(cleaned, "验收新建的远端 Pane 必须被真实关闭，且本客户端通过事件流看到")
}
