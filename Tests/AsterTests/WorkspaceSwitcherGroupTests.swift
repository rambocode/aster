// 工作区切换器里的窗口内工作区条目：排序规则、副标题与搜索、菜单与删除限制。
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 两个窗口：窗口 7 是发起切换器的当前窗口（三个工作区，选中第二个），窗口 3 在它前面
/// （两个工作区）；另有一个已关闭的旧窗口和一个远端工作区，用来确认窗口内工作区排在最前。
@MainActor
private struct GroupSwitcherFixture {
  let a = WorkspaceSwitcherGroup(id: UUID(), name: "alpha", tabTitles: ["vim", "logs"])
  let b = WorkspaceSwitcherGroup(id: UUID(), name: "beta", tabTitles: ["build"])
  let c = WorkspaceSwitcherGroup(id: UUID(), name: "gamma", tabTitles: [])
  let x = WorkspaceSwitcherGroup(id: UUID(), name: "xray", tabTitles: ["server"])
  let y = WorkspaceSwitcherGroup(id: UUID(), name: "yank", tabTitles: [])
  let machine = WorkspaceSwitcherMachine(id: UUID(), label: "orb-box", enabled: true, state: .online)
  let closed = NamedWorkspace(
    name: "old-window", storage: .suite(NamedWorkspaceRegistry.makeSuiteName()), isPinned: true,
    isOpen: false, createdAt: Date(timeIntervalSince1970: 0),
    lastActiveAt: Date(timeIntervalSince1970: 1_800_000_000))

  var other: WorkspaceSwitcherWindow {
    WorkspaceSwitcherWindow(
      windowNumber: 3, label: "主工作区", isCurrent: false, isLocalActive: true,
      selectedGroupID: y.id, groups: [x, y])
  }

  var current: WorkspaceSwitcherWindow {
    WorkspaceSwitcherWindow(
      windowNumber: 7, label: "quiet-otter", isCurrent: true, isLocalActive: true,
      selectedGroupID: b.id, groups: [a, b, c])
  }

  var snapshot: WorkspaceSwitcherSnapshot {
    WorkspaceSwitcherSnapshot(
      windows: [other, current], localWorkspaces: [closed],
      remoteActivity: [
        NamedWorkspaceRegistry.remoteActivityKey(machineID: machine.id, workspaceID: "ws-1"):
          Date(timeIntervalSince1970: 1_900_000_000)
      ],
      machines: [machine],
      remoteWorkspaces: [
        machine.id: [
          RemoteWorkspaceSummary(
            workspaceID: "ws-1", title: "api", tabCount: 1, terminalCount: 1, isSelected: false,
            tabTitles: ["tail"])
        ]
      ])
  }

  func entries(_ snapshot: WorkspaceSwitcherSnapshot? = nil) -> [WorkspaceSwitcherEntry] {
    WorkspaceSwitcherCatalog.entries(from: snapshot ?? self.snapshot)
  }

  func entry(_ group: WorkspaceSwitcherGroup, in snapshot: WorkspaceSwitcherSnapshot? = nil)
    -> WorkspaceSwitcherEntry?
  {
    entries(snapshot).first { $0.item.id.hasSuffix(group.id.uuidString) }
  }

  func search(_ query: String) -> [String] {
    OpenQuicklyIndex(items: entries().map(\.item)).search(query: query, filter: .workspace).map(\.title)
  }
}

/// 与实现同一个本地化键（`%@ 个标签`），界面语言不是中文时也能对上。
private func tabs(_ count: Int) -> String { L("\(String(count)) 个标签") }

@MainActor
@Test("切换器：当前窗口的当前工作区第一，其余按列表顺序，窗口内工作区排在旧窗口与远端之前")
func workspaceSwitcherOrdersGroupsBeforeOtherEntries() {
  let fixture = GroupSwitcherFixture()
  let expected = ["beta", "alpha", "gamma", "xray", "yank", "api", "old-window"]
  #expect(fixture.entries().map(\.item.title) == expected)
  // 空查询时 Open Quickly 索引给出同样的顺序。
  #expect(fixture.search("") == expected)
}

@MainActor
@Test("切换器：窗口内工作区副标题带窗口名与标签，按标签标题和窗口名都能搜到")
func workspaceSwitcherGroupDetailAndSearch() {
  let fixture = GroupSwitcherFixture()
  #expect(
    fixture.entry(fixture.a)?.item.detail
      == "\(L("本机")) · quiet-otter · \(tabs(2)) · vim, logs")
  #expect(fixture.entry(fixture.c)?.item.detail == "\(L("本机")) · quiet-otter · \(tabs(0))")
  #expect(fixture.search("logs") == ["alpha"])
  #expect(Set(fixture.search("主工作区")) == ["xray", "yank"])

  // 只有一个窗口时不带窗口名；窗口显示远端时拿不到标签，只剩「本机」。
  #expect(
    WorkspaceSwitcherCatalog.groupDetail(windowLabel: nil, tabTitles: ["vim"])
      == "\(L("本机")) · \(tabs(1)) · vim")
  #expect(WorkspaceSwitcherCatalog.groupDetail(windowLabel: nil, tabTitles: nil) == L("本机"))
}

@MainActor
@Test("切换器：窗口内工作区主动作是切过去，菜单有重命名与删除，只有当前工作区标「当前」")
func workspaceSwitcherGroupCommands() {
  let fixture = GroupSwitcherFixture()
  let beta = fixture.entry(fixture.b)
  #expect(beta?.primary == .selectGroup(windowNumber: 7, groupID: fixture.b.id))
  #expect(beta?.badge == L("当前"))
  #expect(beta?.isOpen == true)
  #expect(beta?.connectionState == nil)
  #expect(beta?.item.id == "\(WorkspaceSwitcherCatalog.groupPrefix)7:\(fixture.b.id.uuidString)")
  #expect(beta?.menu.map(\.command) == [
    .renameGroup(windowNumber: 7, groupID: fixture.b.id),
    .deleteGroup(windowNumber: 7, groupID: fixture.b.id),
  ])
  // 其它窗口的选中项对用户不是「当前」。
  #expect(fixture.entry(fixture.y)?.badge == L("本机"))
  #expect(fixture.entry(fixture.y)?.primary == .selectGroup(windowNumber: 3, groupID: fixture.y.id))
}

@MainActor
@Test("切换器：窗口只剩一个工作区或正显示远端时不提供删除，窗口显示远端时不把任何工作区当成当前")
func workspaceSwitcherGroupDeleteRestrictions() {
  let fixture = GroupSwitcherFixture()
  var snapshot = fixture.snapshot
  snapshot.windows[0].groups = [fixture.x]
  snapshot.windows[1].isLocalActive = false
  snapshot.windows[1].groups = [
    WorkspaceSwitcherGroup(id: fixture.a.id, name: "alpha", tabTitles: nil),
    WorkspaceSwitcherGroup(id: fixture.b.id, name: "beta", tabTitles: nil),
  ]
  let x = fixture.entry(fixture.x, in: snapshot)
  #expect(x?.menu.map(\.command) == [.renameGroup(windowNumber: 3, groupID: fixture.x.id)])
  let beta = fixture.entry(fixture.b, in: snapshot)
  #expect(beta?.menu.map(\.command) == [.renameGroup(windowNumber: 7, groupID: fixture.b.id)])
  #expect(beta?.badge == L("本机"))
  #expect(beta?.item.detail == "\(L("本机")) · quiet-otter")
  // 显示远端时不把选中项提前：保持列表顺序。
  #expect(fixture.entries(snapshot).prefix(3).map(\.item.title) == ["alpha", "beta", "xray"])
}
