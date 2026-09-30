// `workspace.*` 控制协议方法的定向测试：列表形状与写门禁；替身依赖与夹具也供
// `WorkspaceControlActionTests` 共用。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 替身本地窗口注册表：记录 open 调用，不开任何窗口。
@MainActor
final class WorkspaceControlFakeDirectory: LocalWorkspaceDirectoryControlling {
  var workspaces: [NamedWorkspace]
  var opened: [UUID] = []

  init(_ workspaces: [NamedWorkspace]) { self.workspaces = workspaces }

  func open(_ id: UUID) -> Bool {
    opened.append(id)
    return true
  }
}

/// 替身工作区窗口：记录选中与新建，行为与 `WorkspaceGroupNavigator` 的约定一致
/// （选中或新建后窗口切回本机，新建的工作区成为当前工作区）。
@MainActor
final class WorkspaceControlFakeGroupWindow: WorkspaceGroupWindowControlling {
  let windowID: Int
  let windowLabel: String?
  var isKeyWindow: Bool
  var isLocalMachineActive = true
  var workspaceGroups: [WorkspaceGroup]
  var selectedWorkspaceGroupID: UUID?
  var tabCounts: [UUID: Int] = [:]
  var selected: [UUID] = []
  var created: [String] = []

  init(id: Int, label: String?, key: Bool, groups: [String]) {
    windowID = id
    windowLabel = label
    isKeyWindow = key
    workspaceGroups = groups.map { WorkspaceGroup(name: $0) }
    selectedWorkspaceGroupID = workspaceGroups.first?.id
  }

  func group(_ name: String) -> WorkspaceGroup? { workspaceGroups.first { $0.name == name } }

  func localTabCount(inWorkspaceGroup groupID: UUID) -> Int? {
    isLocalMachineActive ? tabCounts[groupID, default: 0] : nil
  }

  func selectWorkspaceGroup(_ groupID: UUID) async {
    selected.append(groupID)
    isLocalMachineActive = true
    selectedWorkspaceGroupID = groupID
  }

  func createWorkspaceGroup(named name: String) async throws -> WorkspaceGroup {
    let group = WorkspaceGroup(name: try NamedWorkspaceRegistry.validatedName(name))
    created.append(group.name)
    workspaceGroups.append(group)
    isLocalMachineActive = true
    selectedWorkspaceGroupID = group.id
    return group
  }
}

/// 替身远端协调器：`cache` 为 nil 的机器视为「还没取过快照」。
@MainActor
final class WorkspaceControlFakeRemote: RemoteWorkspaceControlling {
  var cache: [UUID: [RemoteWorkspaceSummary]]
  var selected: [String] = []
  var created: [String] = []
  var selectError: (any Error)?

  init(_ cache: [UUID: [RemoteWorkspaceSummary]] = [:]) { self.cache = cache }

  func remoteWorkspaces(machineID: UUID) -> [RemoteWorkspaceSummary] { cache[machineID] ?? [] }
  func hasCachedRemoteProjection(machineID: UUID) -> Bool { cache[machineID] != nil }

  func selectRemoteWorkspace(machineID: UUID, workspaceID: String) async throws {
    if let selectError { throw selectError }
    selected.append("\(machineID.uuidString)/\(workspaceID)")
  }

  func createRemoteWorkspace(machineID: UUID, title: String) async throws -> String {
    created.append("\(machineID.uuidString)/\(title)")
    return "ws-created"
  }
}

/// 构造一条本地工作区；`main` 为 true 时是主工作区。
func controlTestWorkspace(
  _ name: String, open: Bool, main: Bool = false, lastActive: TimeInterval = 1_000
) -> NamedWorkspace {
  NamedWorkspace(
    name: name,
    storage: main ? .standard : .suite(NamedWorkspaceRegistry.suitePrefix + UUID().uuidString),
    isPinned: true, isOpen: open, createdAt: Date(timeIntervalSince1970: 0),
    lastActiveAt: Date(timeIntervalSince1970: lastActive))
}

/// 构造一条远端工作区摘要。
func controlTestSummary(_ id: String, _ title: String, tabs: Int = 1, selected: Bool = false)
  -> RemoteWorkspaceSummary
{
  RemoteWorkspaceSummary(
    workspaceID: id, title: title, tabCount: tabs, terminalCount: tabs, isSelected: selected,
    tabTitles: [])
}

/// 一套替身依赖与挂好它们的 dispatcher。
@MainActor
struct WorkspaceControlFixture {
  let orb = WorkspaceControlMachine(id: UUID(), label: "orb")
  let pi = WorkspaceControlMachine(id: UUID(), label: "pi")
  let directory: WorkspaceControlFakeDirectory
  let keyWindow: WorkspaceControlFakeRemote
  let otherWindow: WorkspaceControlFakeRemote
  /// key window（「主工作区」，工作区：默认、scratch）与另一个窗口（未登记，工作区：infra）。
  let keyGroups = WorkspaceControlFakeGroupWindow(
    id: 11, label: "主工作区", key: true, groups: ["默认", "scratch"])
  let otherGroups = WorkspaceControlFakeGroupWindow(id: 12, label: nil, key: false, groups: ["infra"])
  /// 没有工作区窗口时新开出来的窗口；`openedWindows` 记录新开次数。
  let newGroups = WorkspaceControlFakeGroupWindow(id: 99, label: nil, key: true, groups: ["默认"])
  let dispatcher: AsterControlDispatcher
  let client = ControlFakeClient()
  /// 依赖被取用的次数：写门禁拒绝时必须是 0。
  let contextReads: Box
  let openedWindows = Box()

  final class Box { var value = 0 }

  /// `groupWindows` 为 false 时模拟没有打开任何工作区窗口。
  init(
    allowSendKeys: Bool = true, local: [NamedWorkspace]? = nil, extraMachines: [String] = [],
    groupWindows: Bool = true
  ) {
    directory = WorkspaceControlFakeDirectory(
      local ?? [
        controlTestWorkspace("主工作区", open: true, main: true),
        controlTestWorkspace("dev", open: false),
      ])
    keyWindow = WorkspaceControlFakeRemote()
    otherWindow = WorkspaceControlFakeRemote()
    let bridge = AsterControlBridge(socketPath: "/tmp/test.sock", binaryPath: "/tmp/aster-cli")
    dispatcher = AsterControlDispatcher(bridge: bridge, version: "9.9.9") {
      AsterControlDispatcher.Policy(
        allowSendKeys: allowSendKeys, allowSensitiveSessions: false,
        shell: AsterConfiguration().shell)
    }
    let reads = Box()
    contextReads = reads
    let machines = [orb, pi] + extraMachines.map { WorkspaceControlMachine(id: UUID(), label: $0) }
    let windows: [any WorkspaceGroupWindowControlling] = groupWindows ? [keyGroups, otherGroups] : []
    dispatcher.workspaceContextProvider = {
      [directory, keyWindow, otherWindow, newGroups, openedWindows] in
      reads.value += 1
      return WorkspaceControlContext(
        directory: directory, machines: machines,
        loadedCoordinators: [keyWindow, otherWindow], targetCoordinator: { keyWindow },
        groupWindows: windows,
        openGroupWindow: {
          openedWindows.value += 1
          return newGroups
        })
    }
  }

  func call(_ method: String, _ params: JSONValue? = nil) async -> AsterControlResponse {
    await dispatcher.handle(controlRequest(method, params), client: client)
  }
}

@Test("workspace.list：本地条目与每台机器的缓存工作区，key window 的缓存优先，未缓存单独标出")
@MainActor
func workspaceControlListShape() async throws {
  let fixture = WorkspaceControlFixture(allowSendKeys: false)
  fixture.keyGroups.tabCounts[try #require(fixture.keyGroups.group("默认")).id] = 2
  // orb 两个窗口都有缓存：取 key window 的（它的选中项是 b）；pi 只有另一个窗口有缓存。
  fixture.keyWindow.cache[fixture.orb.id] = [
    controlTestSummary("a", "alpha", tabs: 2), controlTestSummary("b", "beta", selected: true),
  ]
  fixture.otherWindow.cache[fixture.orb.id] = [controlTestSummary("a", "alpha", selected: true)]
  fixture.otherWindow.cache[fixture.pi.id] = []

  let response = await fixture.call("workspace.list")
  #expect(response.error == nil, "只读列表不受写门禁影响")
  let result = try #require(response.result)
  let list = try result.decoded(as: WorkspaceListResult.self)

  // 窗口内工作区：key window 在前，窗口内按列表顺序，选中项只标各窗口当前显示的那一个。
  #expect(list.groups.map(\.name) == ["默认", "scratch", "infra"])
  #expect(list.groups.map(\.windowID) == [11, 11, 12])
  #expect(list.groups.map(\.windowLabel) == ["主工作区", "主工作区", nil])
  #expect(list.groups.map(\.isKeyWindow) == [true, true, false])
  #expect(list.groups.map(\.isSelected) == [true, false, true])
  #expect(list.groups.map(\.tabCount) == [2, 0, 0])
  #expect(list.groups.allSatisfy { $0.kind == "group" })
  #expect(list.local.allSatisfy { $0.kind == "window" })
  #expect(list.remote.flatMap(\.workspaces).allSatisfy { $0.kind == "remote" })

  #expect(list.local.map(\.name) == ["主工作区", "dev"])
  #expect(list.local.map(\.isOpen) == [true, false])
  #expect(list.local.map(\.isMain) == [true, false])
  #expect(list.local[0].lastActiveAtUnixMs == 1_000_000)

  #expect(list.remote.map(\.machineLabel) == ["orb", "pi"])
  #expect(list.remote[0].machineID == fixture.orb.id.uuidString)
  #expect(list.remote[0].cached)
  #expect(list.remote[0].workspaces.map(\.workspaceID) == ["a", "b"])
  #expect(list.remote[0].workspaces.map(\.isSelected) == [false, true])
  #expect(list.remote[0].workspaces[0].tabCount == 2)
  // pi 有快照但没有工作区：cached 为真、列表为空，和「未缓存」区分开。
  #expect(list.remote[1].cached)
  #expect(list.remote[1].workspaces.isEmpty)

  // JSON 键名是 CLI 渲染依赖的契约。
  let machine = try #require(result["remote"].flatMap { value -> JSONValue? in
    if case .array(let rows) = value { return rows.first }
    return nil
  })
  for key in ["machineID", "machineLabel", "cached", "workspaces"] {
    #expect(machine[key] != nil, "远端机器行缺少 \(key)")
  }
  let group = try #require(result["groups"].flatMap { value -> JSONValue? in
    if case .array(let rows) = value { return rows.first }
    return nil
  })
  for key in ["kind", "id", "name", "windowID", "windowLabel", "isKeyWindow", "isSelected", "tabCount"] {
    #expect(group[key] != nil, "窗口内工作区行缺少 \(key)")
  }
}

@Test("workspace.list：窗口正显示远端机器时，它的工作区照常列出，但不标选中、不给标签数")
@MainActor
func workspaceControlListGroupsOfRemoteActiveWindow() async throws {
  let fixture = WorkspaceControlFixture()
  fixture.otherGroups.isLocalMachineActive = false
  let list = try #require(await fixture.call("workspace.list").result)
    .decoded(as: WorkspaceListResult.self)
  let infra = try #require(list.groups.first { $0.name == "infra" })
  #expect(!infra.isSelected)
  #expect(infra.tabCount == nil)
}

@Test("workspace.list：没有任何窗口缓存过的机器标记为 cached=false")
@MainActor
func workspaceControlListMarksUncachedMachines() async throws {
  let fixture = WorkspaceControlFixture()
  let list = try #require(await fixture.call("workspace.list").result)
    .decoded(as: WorkspaceListResult.self)
  #expect(list.remote.map(\.cached) == [false, false])
}

@Test("workspace.open / new 遵守 IPC 写门禁，被拒时不取依赖、不动任何目录")
@MainActor
func workspaceControlWritesRequireAllowSendKeys() async throws {
  let fixture = WorkspaceControlFixture(allowSendKeys: false)
  let open = await fixture.call("workspace.open", ["workspace": "dev"])
  #expect(open.error?.code == .writeNotAllowed)
  let create = await fixture.call("workspace.new", ["name": "x"])
  #expect(create.error?.code == .writeNotAllowed)
  let remote = await fixture.call("workspace.new", ["name": "x", "machine": "orb"])
  #expect(remote.error?.code == .writeNotAllowed)
  #expect(fixture.contextReads.value == 0)
  #expect(fixture.directory.opened.isEmpty)
  #expect(fixture.keyGroups.created.isEmpty)
  #expect(fixture.openedWindows.value == 0)
  #expect(fixture.keyWindow.created.isEmpty)
}
