// 工作区切换器条目：本地与远端混排的最近使用顺序、按标签与机器名搜索、「连接到…」行、已打开标记与菜单。
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 固定时间基准，避免排序依赖当前时钟。
private let switcherT0 = Date(timeIntervalSince1970: 1_800_000_000)

/// 构造一个本地工作区条目。
private func localWorkspace(
  _ name: String, activeOffset: TimeInterval, isOpen: Bool, storage: NamedWorkspaceStorage? = nil
) -> NamedWorkspace {
  NamedWorkspace(
    name: name, storage: storage ?? .suite(NamedWorkspaceRegistry.makeSuiteName()), isPinned: true,
    isOpen: isOpen, createdAt: switcherT0, lastActiveAt: switcherT0.addingTimeInterval(activeOffset))
}

/// 构造一个远端工作区摘要。
private func remoteSummary(_ id: String, _ title: String, tabs: [String]) -> RemoteWorkspaceSummary {
  RemoteWorkspaceSummary(
    workspaceID: id, title: title, tabCount: tabs.count, terminalCount: tabs.count,
    isSelected: false, tabTitles: tabs)
}

/// 两个本地、一台有缓存的在线机器（两个工作区）、一台没缓存的机器。
@MainActor
private struct SwitcherFixture {
  let alpha = localWorkspace("alpha", activeOffset: 10, isOpen: true)
  let beta = localWorkspace("beta", activeOffset: 30, isOpen: false)
  let online = WorkspaceSwitcherMachine(id: UUID(), label: "orb-box", enabled: true, state: .online)
  let offline = WorkspaceSwitcherMachine(id: UUID(), label: "cold-box", enabled: true, state: .disconnected)

  var snapshot: WorkspaceSwitcherSnapshot {
    WorkspaceSwitcherSnapshot(
      localWorkspaces: [alpha, beta],
      localTabTitles: [alpha.id: ["vim notes"]],
      remoteActivity: [
        NamedWorkspaceRegistry.remoteActivityKey(machineID: online.id, workspaceID: "ws-1"):
          switcherT0.addingTimeInterval(20)
      ],
      machines: [online, offline],
      remoteWorkspaces: [
        online.id: [
          remoteSummary("ws-1", "api", tabs: ["server"]),
          remoteSummary("ws-2", "release", tabs: ["build", "logs"]),
        ]
      ])
  }

  var entries: [WorkspaceSwitcherEntry] { WorkspaceSwitcherCatalog.entries(from: snapshot) }

  /// 用 Open Quickly 的真实索引搜索「工作区」过滤器，返回命中的标题。
  func search(_ query: String) -> [String] {
    OpenQuicklyIndex(items: entries.map(\.item)).search(query: query, filter: .workspace).map(\.title)
  }
}

@MainActor
@Test("切换器：本地与远端按最近使用混排，从未用过的远端工作区与「连接到…」行垫底")
func workspaceSwitcherOrdersLocalAndRemoteByRecentUse() {
  let fixture = SwitcherFixture()
  let expected = ["beta", "api", "alpha", "release", L("连接到 cold-box…")]
  #expect(fixture.entries.map(\.item.title) == expected)
  // 空查询时 Open Quickly 索引给出同样的顺序：最近使用时间写进了 score。
  #expect(fixture.search("") == expected)
}

@MainActor
@Test("切换器：按标签标题与机器名都能搜到工作区")
func workspaceSwitcherMatchesTabTitlesAndMachineNames() {
  let fixture = SwitcherFixture()
  #expect(fixture.search("logs") == ["release"])
  #expect(fixture.search("vim notes") == ["alpha"])
  #expect(Set(fixture.search("orb-box")) == ["api", "release"])
  #expect(fixture.search(L("本机")).contains("alpha"))
  let release = fixture.entries.first { $0.item.title == "release" }
  #expect(release?.item.detail == "orb-box · build, logs")
}

@MainActor
@Test("切换器：没有缓存的机器只生成一行「连接到…」，已禁用的机器即使有缓存也只给连接行")
func workspaceSwitcherListsConnectRowForUncachedMachines() {
  let fixture = SwitcherFixture()
  let connect = fixture.entries.filter { $0.item.id.hasPrefix(WorkspaceSwitcherCatalog.connectPrefix) }
  #expect(connect.count == 1)
  #expect(connect.first?.primary == .connectMachine(fixture.offline.id))
  #expect(connect.first?.connectionState == .disconnected)
  #expect(connect.first?.menu.map(\.command) == [.setMachineEnabled(fixture.offline.id, false)])

  var snapshot = fixture.snapshot
  snapshot.machines[0].enabled = false
  snapshot.machines[0].state = .disabled
  let entries = WorkspaceSwitcherCatalog.entries(from: snapshot)
  #expect(!entries.contains { $0.item.id.hasPrefix(WorkspaceSwitcherCatalog.remotePrefix) })
  let disabled = entries.first { $0.item.id == WorkspaceSwitcherCatalog.connectPrefix + fixture.online.id.uuidString }
  #expect(disabled?.primary == .connectMachine(fixture.online.id))
  #expect(disabled?.menu.map(\.command) == [.setMachineEnabled(fixture.online.id, true)])
}

@MainActor
@Test("切换器：打开着的本地条目标记为已打开且不能删除；已关闭的可删除；主工作区永远不能删")
func workspaceSwitcherMarksOpenLocalWorkspaces() {
  let fixture = SwitcherFixture()
  let main = localWorkspace("主工作区", activeOffset: 0, isOpen: false, storage: .standard)
  var snapshot = fixture.snapshot
  snapshot.localWorkspaces.append(main)
  let entries = WorkspaceSwitcherCatalog.entries(from: snapshot)
  func entry(_ workspace: NamedWorkspace) -> WorkspaceSwitcherEntry? {
    entries.first { $0.item.id == WorkspaceSwitcherCatalog.localPrefix + workspace.id.uuidString }
  }

  let alpha = entry(fixture.alpha)
  #expect(alpha?.isOpen == true)
  #expect(alpha?.badge == L("已打开"))
  #expect(alpha?.connectionState == nil)
  #expect(alpha?.primary == .openLocal(fixture.alpha.id))
  #expect(alpha?.menu.map(\.command) == [
    .renameLocal(fixture.alpha.id, currentName: "alpha"), .openLocal(fixture.alpha.id),
  ])

  let beta = entry(fixture.beta)
  #expect(beta?.isOpen == false)
  #expect(beta?.badge == L("本机"))
  #expect(beta?.menu.last?.command == .removeLocal(fixture.beta.id, name: "beta"))

  #expect(entry(main)?.menu.contains { if case .removeLocal = $0.command { true } else { false } } == false)
}

@MainActor
@Test("切换器：远端条目按机器状态上色，主动作在当前窗口选中，菜单含改名、新窗口、关闭与断开")
func workspaceSwitcherRemoteEntryCommands() throws {
  let fixture = SwitcherFixture()
  let machineID = fixture.online.id
  let api = fixture.entries.first { $0.item.title == "api" }
  #expect(api?.connectionState == .online)
  #expect(api?.timestamp == switcherT0.addingTimeInterval(20))
  #expect(api?.primary == .selectRemote(machineID: machineID, workspaceID: "ws-1"))
  let summary = try #require(fixture.snapshot.remoteWorkspaces[machineID]?.first)
  #expect(api?.menu.map(\.command) == [
    .renameRemote(machineID: machineID, workspaceID: "ws-1", currentTitle: "api"),
    .openRemoteInNewWindow(machineID: machineID, workspaceID: "ws-1"),
    .closeRemote(machineID: machineID, summary: summary),
    .setMachineEnabled(machineID, false),
  ])
}

@MainActor
@Test("切换器：目录记录远端使用时间并通知，切换器据此排序")
func workspaceSwitcherDirectoryRecordsRemoteActivity() {
  let directory = NamedWorkspaceDirectory(defaults: nil, now: { switcherT0 })
  let machineID = UUID()
  var notified = 0
  let observer = NotificationCenter.default.addObserver(
    forName: NamedWorkspaceDirectory.didChangeNotification, object: directory, queue: nil
  ) { _ in notified += 1 }
  defer { NotificationCenter.default.removeObserver(observer) }

  directory.markRemoteActive(machineID: machineID, workspaceID: "ws-9")

  let key = NamedWorkspaceRegistry.remoteActivityKey(machineID: machineID, workspaceID: "ws-9")
  #expect(directory.remoteActivity[key] == switcherT0)
  #expect(notified == 1)
}

extension WorkspaceSwitcherEntry {
  /// 测试便利：行上显示的时间。
  fileprivate var timestamp: Date? { item.timestamp }
}
