import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

// 窗口内工作区的模型行为：新建、切换、关闭、移动、删除与快照恢复。

/// 独立 UserDefaults suite 里的窗口模型，避免污染真实工作区快照。
@MainActor
private func makeGroupModel(suite: String = "AsterWorkspaceGroupTests.\(UUID().uuidString)")
  throws -> (model: AppModel, defaults: UserDefaults, suite: String)
{
  let defaults = try #require(UserDefaults(suiteName: suite))
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  return (model, defaults, suite)
}

@MainActor
@Test func workspaceGroupFreshWindowHasOneDefaultGroupContainingAllTabs() throws {
  let (model, defaults, suite) = try makeGroupModel()
  defer { defaults.removePersistentDomain(forName: suite) }
  #expect(model.workspaceGroups.count == 1)
  let group = try #require(model.selectedWorkspaceGroup)
  #expect(model.tabs.allSatisfy { $0.workspaceGroupID == group.id })
  #expect(model.visibleTabs.count == model.tabs.count)
}

@MainActor
@Test func workspaceGroupCreateSwitchesAndShowsOnlyItsTabs() throws {
  let (model, defaults, suite) = try makeGroupModel()
  defer { defaults.removePersistentDomain(forName: suite) }
  let first = try #require(model.selectedWorkspaceGroupID)
  let firstTab = try #require(model.selectedTabID)
  let created = try model.createWorkspaceGroup(named: "  服务端  ")
  #expect(created.name == "服务端")
  #expect(model.selectedWorkspaceGroupID == created.id)
  #expect(model.visibleTabs.count == 1)
  #expect(model.tabs.count == 2)
  model.newTab()
  #expect(model.visibleTabs.count == 2)
  #expect(model.visibleTabs.allSatisfy { $0.workspaceGroupID == created.id })

  // 切回第一个工作区恢复它上次选中的标签；再切回来也恢复。
  let createdSelected = try #require(model.selectedTabID)
  model.selectWorkspaceGroup(first)
  #expect(model.selectedTabID == firstTab)
  #expect(model.visibleTabs.map(\.id) == [firstTab])
  model.selectWorkspaceGroup(created.id)
  #expect(model.selectedTabID == createdSelected)
}

@MainActor
@Test func workspaceGroupRejectsInvalidNames() throws {
  let (model, defaults, suite) = try makeGroupModel()
  defer { defaults.removePersistentDomain(forName: suite) }
  #expect(throws: NamedWorkspaceRegistryError.emptyName) { try model.createWorkspaceGroup(named: "   ") }
  let group = try #require(model.selectedWorkspaceGroupID)
  #expect(throws: NamedWorkspaceRegistryError.nameTooLong) {
    try model.renameWorkspaceGroup(group, to: String(repeating: "x", count: 200))
  }
  try model.renameWorkspaceGroup(group, to: "前端")
  #expect(model.selectedWorkspaceGroup?.name == "前端")
}

@MainActor
@Test func workspaceGroupSelectingTabInOtherGroupFollowsIt() throws {
  let (model, defaults, suite) = try makeGroupModel()
  defer { defaults.removePersistentDomain(forName: suite) }
  let first = try #require(model.selectedWorkspaceGroupID)
  let firstTab = try #require(model.selectedTab)
  _ = try model.createWorkspaceGroup(named: "B")
  model.select(firstTab)
  #expect(model.selectedWorkspaceGroupID == first)
}

@MainActor
@Test func workspaceGroupClosingSelectedTabStaysInSameGroup() throws {
  let (model, defaults, suite) = try makeGroupModel()
  defer { defaults.removePersistentDomain(forName: suite) }
  let first = try #require(model.selectedWorkspaceGroupID)
  model.newTab(position: .end)
  let created = try model.createWorkspaceGroup(named: "B")
  model.newTab(position: .end)
  let before = model.visibleTabs.map(\.id)
  model.closeSelectedTab()
  #expect(model.selectedWorkspaceGroupID == created.id)
  #expect(model.visibleTabs.count == before.count - 1)
  // 关掉当前工作区的最后一个标签：补一个新 Shell，仍留在该工作区。
  model.closeSelectedTab()
  #expect(model.selectedWorkspaceGroupID == created.id)
  #expect(model.visibleTabs.count == 1)
  #expect(model.tabCount(inWorkspaceGroup: first) == 2)
}

@MainActor
@Test func workspaceGroupMoveTabKeepsViewOnCurrentGroup() throws {
  let (model, defaults, suite) = try makeGroupModel()
  defer { defaults.removePersistentDomain(forName: suite) }
  let first = try #require(model.selectedWorkspaceGroupID)
  model.newTab(position: .end)
  let moving = try #require(model.selectedTabID)
  let second = try model.createWorkspaceGroup(named: "B")
  model.selectWorkspaceGroup(first)
  #expect(model.selectedTabID == moving)
  model.moveTab(moving, toWorkspaceGroup: second.id)
  #expect(model.selectedWorkspaceGroupID == first)
  #expect(model.visibleTabs.count == 1)
  #expect(model.selectedTabID != moving)
  #expect(model.tabCount(inWorkspaceGroup: second.id) == 2)
}

@MainActor
@Test func workspaceGroupDeleteClosesItsTabsAndKeepsLastGroup() throws {
  let (model, defaults, suite) = try makeGroupModel()
  defer { defaults.removePersistentDomain(forName: suite) }
  let first = try #require(model.selectedWorkspaceGroupID)
  #expect(!model.canDeleteWorkspaceGroup(first))
  #expect(!model.deleteWorkspaceGroup(first))
  let second = try model.createWorkspaceGroup(named: "B")
  model.newTab()
  let doomed = Set(model.visibleTabs.map(\.id))
  #expect(model.deleteWorkspaceGroup(second.id))
  #expect(model.workspaceGroups.map(\.id) == [first])
  #expect(model.selectedWorkspaceGroupID == first)
  #expect(model.tabs.allSatisfy { !doomed.contains($0.id) })
  #expect(model.recentlyClosedSnapshots.contains { doomed.contains($0.id) })
  // 被删工作区的标签重新打开后落进现存的工作区，不会变成看不见的孤儿。
  #expect(model.reopenLastClosedTab())
  #expect(model.selectedTab?.workspaceGroupID == first)
}

@MainActor
@Test func workspaceGroupsSurviveSnapshotRestore() throws {
  let suite = "AsterWorkspaceGroupTests.restore.\(UUID().uuidString)"
  let (model, defaults, _) = try makeGroupModel(suite: suite)
  defer { defaults.removePersistentDomain(forName: suite) }
  let first = try #require(model.selectedWorkspaceGroupID)
  let second = try model.createWorkspaceGroup(named: "B")
  model.newTab()
  model.selectWorkspaceGroup(first)
  model.persistWorkspace()
  let tabGroups = Dictionary(uniqueKeysWithValues: model.tabs.map { ($0.id, $0.workspaceGroupID) })
  for tab in model.tabs { tab.stop(immediately: true, disposition: .detached) }

  let restored = AppModel(defaults: defaults)
  restored.ensureInitialTab()
  #expect(restored.workspaceGroups.map(\.name) == model.workspaceGroups.map(\.name))
  #expect(restored.selectedWorkspaceGroupID == first)
  #expect(restored.tabCount(inWorkspaceGroup: second.id) == 2)
  for tab in restored.tabs { #expect(tab.workspaceGroupID == tabGroups[tab.id] ?? nil) }
}
