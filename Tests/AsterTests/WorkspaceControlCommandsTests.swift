// `workspace.*` 控制协议方法的定向测试：列表形状与写门禁；替身依赖与夹具也供
// `WorkspaceControlActionTests` 共用。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 替身本地目录：记录 open / create 调用，不开任何窗口。
@MainActor
final class WorkspaceControlFakeDirectory: LocalWorkspaceDirectoryControlling {
  var workspaces: [NamedWorkspace]
  var opened: [UUID] = []
  var created: [String] = []

  init(_ workspaces: [NamedWorkspace]) { self.workspaces = workspaces }

  func open(_ id: UUID) -> Bool {
    opened.append(id)
    return true
  }

  func createLocalWorkspace(named rawName: String, errorWindow: NSWindow?) -> Bool {
    created.append(rawName)
    workspaces.insert(controlTestWorkspace(rawName, open: true), at: 0)
    return true
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
  let dispatcher: AsterControlDispatcher
  let client = ControlFakeClient()
  /// 依赖被取用的次数：写门禁拒绝时必须是 0。
  let contextReads: Box

  final class Box { var value = 0 }

  init(allowSendKeys: Bool = true, local: [NamedWorkspace]? = nil, extraMachines: [String] = []) {
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
    dispatcher.workspaceContextProvider = { [directory, keyWindow, otherWindow] in
      reads.value += 1
      return WorkspaceControlContext(
        directory: directory, machines: machines,
        loadedCoordinators: [keyWindow, otherWindow], targetCoordinator: { keyWindow })
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
  #expect(fixture.directory.created.isEmpty)
  #expect(fixture.keyWindow.created.isEmpty)
}
