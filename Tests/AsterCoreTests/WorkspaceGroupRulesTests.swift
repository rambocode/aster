import Foundation
import Testing

@testable import AsterCore

// 窗口内工作区纯规则：恢复整理、切换选中、删除后去向与默认名称。

@Test func workspaceGroupNormalizeCreatesDefaultGroupForLegacySnapshot() {
  let result = WorkspaceGroupRules.normalized(
    groups: nil, tabGroupIDs: [nil, nil], selectedGroupID: nil, defaultName: "默认")
  #expect(result.groups.count == 1)
  #expect(result.groups[0].name == "默认")
  #expect(result.assignments == [result.groups[0].id, result.groups[0].id])
  #expect(result.selectedGroupID == result.groups[0].id)
}

@Test func workspaceGroupNormalizeMovesOrphanTabsToFirstGroupAndDropsDuplicates() {
  let first = WorkspaceGroup(name: "A")
  let second = WorkspaceGroup(name: "B")
  let duplicate = WorkspaceGroup(id: second.id, name: "B copy")
  let result = WorkspaceGroupRules.normalized(
    groups: [first, second, duplicate], tabGroupIDs: [second.id, UUID(), nil],
    selectedGroupID: UUID(), defaultName: "默认")
  #expect(result.groups.map(\.name) == ["A", "B"])
  #expect(result.assignments == [second.id, first.id, first.id])
  #expect(result.selectedGroupID == first.id)
}

@Test func workspaceGroupNormalizeKeepsEmptyGroupsAndSelection() {
  let first = WorkspaceGroup(name: "A")
  let empty = WorkspaceGroup(name: "B")
  let result = WorkspaceGroupRules.normalized(
    groups: [first, empty], tabGroupIDs: [first.id], selectedGroupID: empty.id, defaultName: "默认")
  #expect(result.groups.count == 2)
  #expect(result.selectedGroupID == empty.id)
}

@Test func workspaceGroupTabToSelectPrefersRememberedMember() {
  let group = UUID()
  let other = UUID()
  let a = UUID(), b = UUID(), c = UUID()
  let members: [(tabID: UUID, groupID: UUID?)] = [(a, other), (b, group), (c, group)]
  #expect(WorkspaceGroupRules.tabToSelect(inGroup: group, tabGroupIDs: members, remembered: c) == c)
  #expect(WorkspaceGroupRules.tabToSelect(inGroup: group, tabGroupIDs: members, remembered: a) == b)
  #expect(WorkspaceGroupRules.tabToSelect(inGroup: UUID(), tabGroupIDs: members, remembered: nil) == nil)
}

@Test func workspaceGroupRemovalSelectsNextThenPrevious() {
  let groups = [WorkspaceGroup(name: "A"), WorkspaceGroup(name: "B"), WorkspaceGroup(name: "C")]
  #expect(WorkspaceGroupRules.groupToSelectAfterRemoving(groups[1].id, from: groups) == groups[2].id)
  #expect(WorkspaceGroupRules.groupToSelectAfterRemoving(groups[2].id, from: groups) == groups[1].id)
  #expect(WorkspaceGroupRules.groupToSelectAfterRemoving(groups[0].id, from: [groups[0]]) == nil)
}

@Test func workspaceGroupUniqueNameSkipsTakenNames() {
  #expect(WorkspaceGroupRules.uniqueName(base: "工作区", existing: ["默认"]) == "工作区 2")
  #expect(WorkspaceGroupRules.uniqueName(base: "工作区", existing: ["默认", "工作区 2"]) == "工作区 3")
}

@Test func workspaceSnapshotDecodesLegacyJSONWithoutGroups() throws {
  let tabID = UUID()
  let legacy = WorkspaceSnapshot(
    selectedTabID: tabID,
    tabs: [WorkspaceTabSnapshot(id: tabID, title: "t", layout: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")))])
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
  object.removeValue(forKey: "workspaceGroups")
  object.removeValue(forKey: "selectedWorkspaceGroupID")
  let decoded = try JSONDecoder().decode(
    WorkspaceSnapshot.self, from: JSONSerialization.data(withJSONObject: object))
  #expect(decoded.workspaceGroups == nil)
  #expect(decoded.tabs[0].workspaceGroupID == nil)
}
