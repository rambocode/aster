import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// P4.2 的**真实远端**验收：一台真实机器上的服务端快照被投影成 AppKit 标签与递归分屏，
// 界面动作变成真实的服务端事务，切走机器真实取消画面订阅，切回后在快照确认前关闸。
//
// 默认关闭：需要 ASTER_P4_ORB=1 与全部远端环境变量。关闭时整条用例记 skipped，
// 绝不用替身冒充真实链路——P4 的验收标准是真实进程证据。

/// 真实远端验收所需的环境。任一项缺失即视为「未开启」。
private struct RemoteWorkP4MachineEnvironment {
  let sshTarget: String
  let remoteBinary: String
  let stateDirectory: String
  let sessionName: String

  /// 验收是否开启。默认关闭；关闭时 Swift Testing 把用例记为 skipped。
  static var isEnabled: Bool { current() != nil }

  /// 从进程环境读取；开关是 `ASTER_P4_ORB=1`，其余键与生产工厂读的是同一批。
  static func current() -> RemoteWorkP4MachineEnvironment? {
    let environment = ProcessInfo.processInfo.environment
    guard environment["ASTER_P4_ORB"] == "1",
      let sshTarget = environment[RemoteEnvironmentKeys.remoteTarget], !sshTarget.isEmpty,
      let remoteBinary = environment[RemoteEnvironmentKeys.remoteBinary] ?? environment[
        RemoteEnvironmentKeys.binary], !remoteBinary.isEmpty,
      let stateDirectory = environment[RemoteEnvironmentKeys.stateDirectory],
      !stateDirectory.isEmpty
    else { return nil }
    return RemoteWorkP4MachineEnvironment(
      sshTarget: sshTarget,
      remoteBinary: remoteBinary,
      stateDirectory: stateDirectory,
      sessionName: environment[RemoteEnvironmentKeys.sessionName] ?? "work2")
  }

  /// 生产工厂用的那份「只覆盖运行时四个键」的环境；测试不另造一套语义。
  func coordinatorEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    // 键名走 `RemoteEnvironmentKeys`（与 `ManagedTerminalCoordinator` 的常量同值），
    // 它不是 MainActor 隔离的，可以在测试的 nonisolated 上下文里读。
    environment[RemoteEnvironmentKeys.binary] = remoteBinary
    environment[RemoteEnvironmentKeys.stateDirectory] = stateDirectory
    environment[RemoteEnvironmentKeys.sessionName] = sessionName
    environment[RemoteEnvironmentKeys.remoteTarget] = sshTarget
    return environment
  }
}

/// 真实 AppKit 宿主 + 隔离 defaults 域。绝不碰用户的 io.local.aster-terminal。
@MainActor
private struct RemoteWorkP4Fixture {
  let window: NSWindow
  let controller: WorkspaceViewController
  let model: AppModel
  let machineProfileID: UUID
  let suiteName: String
  let defaults: UserDefaults

  func tearDown() {
    // 先停事件订阅：它是长命子进程，留着会变成孤儿 ssh，在途回调还会去动已经拆掉的窗口。
    controller.loadedRemoteWorkspaces?.stopAllEventSubscriptions()
    // 全部 Pane 按**分离**收尾：这些是远端受管终端，结束它们会杀掉真实远端进程。
    for tab in model.tabs {
      for runtime in tab.runtimes.values { runtime.terminalSession?.detachManagedTerminal() }
    }
    window.orderOut(nil)
    ManagedTerminalCoordinatorRegistry.reset()
    defaults.removePersistentDomain(forName: suiteName)
  }
}

@MainActor
private func makeRemoteWorkP4Fixture(_ environment: RemoteWorkP4MachineEnvironment) throws
  -> RemoteWorkP4Fixture
{
  let suiteName = "RemoteWorkP4Probe.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  preferences.tabBarLayout = .vertical
  model.ensureInitialTab()

  // 按机器注册一个真实 SSH 协调器。走 `register` 而不是让工厂现造：验收要的是
  // 确定的机器身份，不依赖用户机器配置文件里恰好存在哪台机器。
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
  return RemoteWorkP4Fixture(
    window: window, controller: controller, model: model, machineProfileID: machineProfileID,
    suiteName: suiteName, defaults: defaults)
}

/// 直接用 `ssh` 向真实服务端要一份权威快照，用来与界面渲染出的结构逐点比对。
///
/// 刻意绕开被测代码自己的传输与投影：拿被测对象的输出去证明被测对象正确等于什么都没证明。
private func remoteAuthoritativeSnapshot(_ environment: RemoteWorkP4MachineEnvironment) throws
  -> (revision: UInt64, workspaces: [RemoteWorkspace])
{
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
  process.arguments = [
    "-o", "BatchMode=yes", environment.sshTarget,
    environment.remoteBinary, "session", "snapshot",
    environment.stateDirectory, environment.sessionName,
  ]
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = FileHandle.nullDevice
  try process.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0,
    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
    let revision = (object["revision"] as? NSNumber)?.uint64Value,
    let result = object["result"]
  else {
    throw RemoteWorkP4SnapshotError.unreadable(String(decoding: data, as: UTF8.self))
  }
  struct Body: Decodable { var workspaces: [RemoteWorkspace] }
  let body = try JSONDecoder().decode(
    Body.self, from: try JSONSerialization.data(withJSONObject: result))
  return (revision, body.workspaces)
}

/// 权威快照取不到时的明确失败；不允许静默降级成「用被测代码自己的快照」。
private enum RemoteWorkP4SnapshotError: Error { case unreadable(String) }

/// 服务端布局节点的结构签名：只保留形状与身份，用来做「渲染结构 == 服务端结构」的比对。
private func remoteLayoutSignature(_ node: RemoteLayoutNode) -> String {
  switch node {
  case .leaf(let pane):
    return "leaf(\(pane.paneID.lowercased()):\(pane.terminalID))"
  case .split(let axis, let ratio, let first, let second):
    let rounded = (ratio * 1000).rounded() / 1000
    return
      "split(\(axis.rawValue):\(rounded),\(remoteLayoutSignature(first)),\(remoteLayoutSignature(second)))"
  }
}

/// 本地渲染布局的同形签名。两边必须逐字符相等。
private func localLayoutSignature(_ layout: PaneLayout) -> String {
  switch layout {
  case .leaf(let pane):
    return "leaf(\(pane.id.uuidString.lowercased()):\(pane.managedTerminal?.terminalID ?? "-"))"
  case .split(let axis, let first, let second, let ratio):
    let rounded = (ratio * 1000).rounded() / 1000
    return
      "split(\(axis.rawValue):\(rounded),\(localLayoutSignature(first)),\(localLayoutSignature(second)))"
  }
}

/// 轮询等待一个条件成立。真实远端是 SSH 往返，不能用固定 sleep 假装同步。
@MainActor
private func waitUntil(
  timeout: Duration = .seconds(30),
  _ condition: () -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(120))
  }
  return condition()
}

@Test("remoteWorkP4：真实远端快照投影成标签与递归分屏，结构一致且不含本地 resourcePath", .enabled(if: RemoteWorkP4MachineEnvironment.isEnabled))
@MainActor
func remoteWorkP4ProjectsRealMachineSnapshotIntoAppKitWorkspace() async throws {
  let environment = try #require(RemoteWorkP4MachineEnvironment.current())
  let fixture = try makeRemoteWorkP4Fixture(environment)
  defer { fixture.tearDown() }

  // 权威快照先取一次：之后所有断言都以它为准。
  let authoritative = try remoteAuthoritativeSnapshot(environment)
  let coordinator = fixture.controller.remoteWorkspaces
  await coordinator.activate(machineProfileID: fixture.machineProfileID)

  let controller = try #require(coordinator.controller(forMachine: fixture.machineProfileID))
  #expect(controller.revision == authoritative.revision)
  #expect(fixture.model.activeMachineID == fixture.machineProfileID)

  // 标签数量与顺序必须与服务端一致。
  let remoteTabs = authoritative.workspaces.flatMap(\.tabs)
  #expect(fixture.model.tabs.count == remoteTabs.count)
  #expect(fixture.model.tabs.map(\.remoteTabID) == remoteTabs.map { $0.tabID })

  for (index, remoteTab) in remoteTabs.enumerated() {
    let tab = fixture.model.tabs[index]
    #expect(tab.title == remoteTab.title)
    // 递归分屏树逐点相同：轴、比例、paneID、terminalID 一个都不能差。
    #expect(localLayoutSignature(tab.layout) == remoteLayoutSignature(remoteTab.layout))
    for pane in tab.layout.allPanes {
      #expect(pane.kind == .terminal, "共享结构的 leaf 必须都是受管终端")
      #expect(pane.managedTerminal != nil)
      #expect(pane.managedTerminal?.server.machineProfileID == fixture.machineProfileID)
      // P4.2a：混合布局里来源客户端的本地资源不得出现在其它客户端的渲染结果里。
      #expect(pane.resourcePath == nil, "渲染共享结构不得带任何本地 resourcePath")
    }
  }
}

@Test("remoteWorkP4：界面发起的结构变更是真实服务端事务，revision 递增且新终端有真实 PID", .enabled(if: RemoteWorkP4MachineEnvironment.isEnabled))
@MainActor
func remoteWorkP4UIStructureChangeCommitsRealTransaction() async throws {
  let environment = try #require(RemoteWorkP4MachineEnvironment.current())
  let fixture = try makeRemoteWorkP4Fixture(environment)
  defer { fixture.tearDown() }

  let coordinator = fixture.controller.remoteWorkspaces
  await coordinator.activate(machineProfileID: fixture.machineProfileID)
  let controller = try #require(coordinator.controller(forMachine: fixture.machineProfileID))
  let beforeRevision = controller.revision
  let beforePaneIDs = Set(fixture.model.tabs.flatMap { $0.layout.allPanes.map(\.id) })
  #expect(beforeRevision > 0)

  // 从 UI 侧发起：`splitSelectedTab` 是菜单/快捷键走的同一条路径，
  // 远端活动时它必须被 `remoteStructureHandler` 拦成 `pane.split` 事务。
  #expect(fixture.model.remoteStructureHandler != nil)
  fixture.model.splitSelectedTab(.right)

  // 等的是「新快照已经回灌到界面」，不能只等 revision：事务返回时就带回了新 revision，
  // 但那一刻结构刷新（重新取快照 → 投影 → setTabs）还没跑完。
  let committed = await waitUntil {
    controller.revision > beforeRevision
      && !Set(fixture.model.tabs.flatMap { $0.layout.allPanes.map(\.id) })
        .subtracting(beforePaneIDs).isEmpty
  }
  #expect(
    committed,
    "服务端 revision 必须递增并回灌界面：\(beforeRevision) → \(controller.revision)，错误：\(coordinator.lastError ?? "无")")

  // 服务端是权威：再独立取一次快照确认这次修改真的落盘了。
  let authoritative = try remoteAuthoritativeSnapshot(environment)
  #expect(authoritative.revision == controller.revision)

  let afterPaneIDs = Set(fixture.model.tabs.flatMap { $0.layout.allPanes.map(\.id) })
  let added = afterPaneIDs.subtracting(beforePaneIDs)
  #expect(added.count == 1, "分屏应恰好新增一个 Pane")

  // 新 Pane 背后必须是一个真实运行的远端进程，PID 由服务端实测给出。
  let projection = try #require(controller.projection)
  let newPaneID = try #require(added.first)
  let status = try #require(projection.terminalStatusByPaneID[newPaneID])
  #expect(status.pid ?? 0 > 0, "新终端必须有真实 PID，实际：\(String(describing: status.pid))")

  // 收尾：把这次为验收新建的远端 Pane 关掉，不给下一次运行留垃圾结构。
  if let tab = fixture.model.tabs.first(where: {
    $0.layout.allPanes.contains { $0.id == newPaneID }
  }) {
    coordinator.closePane(tabID: tab.id, paneID: newPaneID)
    let cleaned = await waitUntil {
      !fixture.model.tabs.flatMap { $0.layout.allPanes.map(\.id) }.contains(newPaneID)
    }
    #expect(cleaned, "验收新建的远端 Pane 必须被真实关闭，不给下一次运行留垃圾结构")
  }
}

@Test("remoteWorkP4：切走机器真实取消画面订阅，切回后快照确认前不接受输入", .enabled(if: RemoteWorkP4MachineEnvironment.isEnabled))
@MainActor
func remoteWorkP4SuspendsSurfacesAndGatesInputUntilSnapshot() async throws {
  let environment = try #require(RemoteWorkP4MachineEnvironment.current())
  let fixture = try makeRemoteWorkP4Fixture(environment)
  defer { fixture.tearDown() }

  let coordinator = fixture.controller.remoteWorkspaces
  await coordinator.activate(machineProfileID: fixture.machineProfileID)
  let controller = try #require(coordinator.controller(forMachine: fixture.machineProfileID))
  let terminalIDs = fixture.model.tabs
    .flatMap { $0.layout.allPanes }
    .compactMap { $0.managedTerminal?.terminalID }
  #expect(!terminalIDs.isEmpty)
  // 快照已确认：可见终端全部订阅，且允许交互。
  #expect(controller.interest.visibleSurfaces == Set(terminalIDs))
  for terminalID in terminalIDs { #expect(controller.allowsInput(terminalID: terminalID)) }

  // 切回 Local：被切走的机器必须真实取消全部画面订阅，并且整机关闸。
  await coordinator.activate(machineProfileID: MachineProfile.localProfileID)
  #expect(controller.interest.visibleSurfaces.isEmpty, "切走的机器必须零画面订阅")
  for terminalID in terminalIDs { #expect(!controller.allowsInput(terminalID: terminalID)) }
  #expect(fixture.model.remoteStructureHandler == nil)
  // 标签被强持有而不是关闭：A08 保活要求切走的机器仍然可以原样切回来。
  #expect(!fixture.model.tabs(forMachine: fixture.machineProfileID).isEmpty)

  // 切回：只跑同步前半程，停在「已可见、完整快照尚未确认」这个中间态上。
  #expect(coordinator.beginActivation(machineProfileID: fixture.machineProfileID))
  let visiblePanes = fixture.model.tabs.flatMap { $0.layout.allPanes }
  #expect(!visiblePanes.isEmpty)
  for terminalID in terminalIDs {
    #expect(!controller.allowsInput(terminalID: terminalID), "快照确认前必须关闸")
  }
  for tab in fixture.model.tabs {
    for pane in tab.layout.allPanes where pane.managedTerminal != nil {
      if let session = tab.runtime(for: pane.id)?.terminalSession {
        #expect(session.allowsInput == false, "关闸期间 Pane 不接受键盘输入")
      }
    }
  }

  // 完整快照到达后才放行。
  #expect(await coordinator.refresh(machineProfileID: fixture.machineProfileID))
  for terminalID in terminalIDs { #expect(controller.allowsInput(terminalID: terminalID)) }
}
