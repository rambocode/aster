import AsterCore
import Foundation

// 窗口内工作区（标签分组）的模型操作：新建、切换、重命名、删除与移动标签。
//
// `tabs` 始终保存窗口的全部标签，工作区只是给每个本地标签打上 `workspaceGroupID`。
// 界面通过 `visibleTabs` 只显示当前工作区；Agent、通知、CLI 与持久化继续面向全部标签，
// 切走的工作区里的终端不会停。远端机器的标签由服务端的远端工作区管理，这里不参与。

extension AppModel {
  /// 新工作区的默认名称前缀，例如「工作区 2」。
  static var workspaceGroupNameBase: String { L("工作区") }
  /// 旧快照或全新窗口里第一个工作区的名称。
  static var defaultWorkspaceGroupName: String { L("默认") }

  /// 当前工作区的标签（保持 `tabs` 的相对顺序）。远端机器活动时返回全部标签。
  var visibleTabs: [TerminalTabItem] {
    guard isLocalMachineActive, let selectedWorkspaceGroupID else { return tabs }
    return tabs.filter { $0.workspaceGroupID == selectedWorkspaceGroupID }
  }

  /// 当前工作区；远端机器活动或还没有工作区时为 nil。
  var selectedWorkspaceGroup: WorkspaceGroup? {
    guard isLocalMachineActive else { return nil }
    return workspaceGroups.first { $0.id == selectedWorkspaceGroupID }
  }

  /// 某个工作区里的标签数，供侧栏行显示。
  func tabCount(inWorkspaceGroup groupID: UUID) -> Int {
    tabs.reduce(0) { $0 + ($1.workspaceGroupID == groupID ? 1 : 0) }
  }

  /// 新建名称唯一的默认名，供「新建工作区」表单预填。
  func suggestedWorkspaceGroupName() -> String {
    WorkspaceGroupRules.uniqueName(
      base: Self.workspaceGroupNameBase, existing: workspaceGroups.map(\.name))
  }

  // MARK: - 操作

  /// 新建一个工作区并切过去，里面先开一个主目录 Shell。名称非法时抛
  /// `NamedWorkspaceRegistryError`；远端机器活动时不能建本地工作区。
  @discardableResult
  func createWorkspaceGroup(named rawName: String) throws -> WorkspaceGroup {
    let name = try NamedWorkspaceRegistry.validatedName(rawName)
    guard isLocalMachineActive else { throw WorkspaceGroupError.remoteMachineActive }
    // 先保证已有标签都有归属，再加新工作区，避免旧标签被误认为属于新工作区。
    _ = ensureSelectedWorkspaceGroup()
    let group = WorkspaceGroup(name: name)
    workspaceGroups.append(group)
    selectedWorkspaceGroupID = group.id
    newTab(workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path, position: .end)
    return group
  }

  /// 切到某个工作区：恢复它上次选中的标签；工作区是空的就补一个新 Shell。
  func selectWorkspaceGroup(_ groupID: UUID) {
    guard isLocalMachineActive, workspaceGroups.contains(where: { $0.id == groupID }) else { return }
    let target = WorkspaceGroupRules.tabToSelect(
      inGroup: groupID,
      tabGroupIDs: tabs.map { ($0.id, $0.workspaceGroupID) },
      remembered: lastSelectedTabIDByWorkspaceGroup[groupID])
    selectedWorkspaceGroupID = groupID
    if let target, let tab = tabs.first(where: { $0.id == target }) {
      select(tab)
    } else {
      newTab(workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path, position: .end)
    }
  }

  /// 按列表顺序切到相邻工作区，`forward` 为 false 时向前。只有一个工作区时不动。
  func selectAdjacentWorkspaceGroup(forward: Bool) {
    guard workspaceGroups.count > 1,
      let index = workspaceGroups.firstIndex(where: { $0.id == selectedWorkspaceGroupID })
    else { return }
    let count = workspaceGroups.count
    selectWorkspaceGroup(workspaceGroups[(index + (forward ? 1 : count - 1)) % count].id)
  }

  /// 重命名工作区。名称非法时抛 `NamedWorkspaceRegistryError`。
  func renameWorkspaceGroup(_ groupID: UUID, to rawName: String) throws {
    let name = try NamedWorkspaceRegistry.validatedName(rawName)
    guard let index = workspaceGroups.firstIndex(where: { $0.id == groupID }) else { return }
    workspaceGroups[index].name = name
    persistWorkspace()
  }

  /// 能否删除该工作区：至少要留一个工作区。
  func canDeleteWorkspaceGroup(_ groupID: UUID) -> Bool {
    isLocalMachineActive && workspaceGroups.count > 1
      && workspaceGroups.contains(where: { $0.id == groupID })
  }

  /// 删除工作区并关闭其中全部标签（进入「最近关闭」，可以重新打开）。
  ///
  /// 调用方负责事先确认。未保存的文档仍由各标签自己询问；用户选择保留的标签移到
  /// 切过去的工作区，不会变成看不见的孤儿标签。返回是否删除。
  @discardableResult
  func deleteWorkspaceGroup(_ groupID: UUID) -> Bool {
    guard canDeleteWorkspaceGroup(groupID),
      let next = WorkspaceGroupRules.groupToSelectAfterRemoving(groupID, from: workspaceGroups)
    else { return false }
    let members = tabs.filter { $0.workspaceGroupID == groupID }
    // 先移除工作区并切走，再关标签：关标签时工作区已不存在，就不会为它补新 Shell，
    // 选中项也不会在将被删除的标签之间来回跳。
    workspaceGroups.removeAll { $0.id == groupID }
    lastSelectedTabIDByWorkspaceGroup[groupID] = nil
    selectWorkspaceGroup(next)
    for tab in members { closeTab(id: tab.id, confirm: false) }
    for tab in tabs where tab.workspaceGroupID == groupID { tab.workspaceGroupID = next }
    persistWorkspace()
    return true
  }

  /// 把标签移到另一个工作区。移走的是当前选中标签时，当前工作区改选相邻标签（关空则补 Shell）；
  /// 界面停留在当前工作区，不跟着标签跳走。
  func moveTab(_ tabID: UUID, toWorkspaceGroup groupID: UUID) {
    guard isLocalMachineActive, workspaceGroups.contains(where: { $0.id == groupID }),
      let tab = tabs.first(where: { $0.id == tabID }), tab.workspaceGroupID != groupID
    else { return }
    let sourceGroupID = tab.workspaceGroupID
    let wasSelected = selectedTabID == tabID
    tab.workspaceGroupID = groupID
    // 手动分隔线属于原工作区的排列，跟着标签过去会在新工作区里凭空多出一条。
    removeTabDivider(after: tabID)
    lastSelectedTabIDByWorkspaceGroup[groupID] = tabID
    guard wasSelected, let sourceGroupID else {
      persistWorkspace()
      return
    }
    let target = WorkspaceGroupRules.tabToSelect(
      inGroup: sourceGroupID, tabGroupIDs: tabs.map { ($0.id, $0.workspaceGroupID) }, remembered: nil)
    if let target, let next = tabs.first(where: { $0.id == target }) {
      select(next)
    } else {
      newTab(workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path, position: .end)
    }
  }

  // MARK: - 与 AppModel 主体的衔接

  /// 保证至少有一个工作区且选中其一，返回当前工作区 id。
  /// 已有但没有归属的本地标签（例如测试直接构造、旧路径插入）一并归到它名下。
  func ensureSelectedWorkspaceGroup() -> UUID {
    if workspaceGroups.isEmpty {
      workspaceGroups = [WorkspaceGroup(name: Self.defaultWorkspaceGroupName)]
    }
    if selectedWorkspaceGroupID == nil
      || !workspaceGroups.contains(where: { $0.id == selectedWorkspaceGroupID })
    {
      selectedWorkspaceGroupID = workspaceGroups[0].id
    }
    let groupID = selectedWorkspaceGroupID ?? workspaceGroups[0].id
    for tab in tabs where tab.workspaceGroupID == nil && tab.remoteTabID == nil {
      tab.workspaceGroupID = groupID
    }
    return groupID
  }

  /// 从快照恢复工作区列表与每个标签的归属。旧快照没有分组时全部落进默认工作区。
  func restoreWorkspaceGroups(from snapshot: WorkspaceSnapshot) {
    let normalized = WorkspaceGroupRules.normalized(
      groups: snapshot.workspaceGroups,
      tabGroupIDs: tabs.map(\.workspaceGroupID),
      selectedGroupID: snapshot.selectedWorkspaceGroupID,
      defaultName: Self.defaultWorkspaceGroupName)
    for (tab, groupID) in zip(tabs, normalized.assignments) { tab.workspaceGroupID = groupID }
    workspaceGroups = normalized.groups
    selectedWorkspaceGroupID = normalized.selectedGroupID
  }

  /// 重新打开的标签回到原工作区；原工作区已被删除时落进当前工作区。
  func assignWorkspaceGroupForReopenedTab(_ tab: TerminalTabItem) {
    guard isLocalMachineActive else { return }
    if let groupID = tab.workspaceGroupID, workspaceGroups.contains(where: { $0.id == groupID }) {
      return
    }
    tab.workspaceGroupID = ensureSelectedWorkspaceGroup()
  }

  /// 标签在自己工作区里的位置，用于关闭后选中同一工作区的相邻标签。
  func indexInWorkspaceGroup(of tab: TerminalTabItem) -> Int? {
    tabs.filter { $0.workspaceGroupID == tab.workspaceGroupID }.firstIndex { $0 === tab }
  }

  /// `selectedTabID` 变化后让当前工作区跟随选中标签，并记住该工作区最后选中的标签。
  func syncWorkspaceGroupWithSelectedTab() {
    guard isLocalMachineActive, let selectedTabID,
      let groupID = tabs.first(where: { $0.id == selectedTabID })?.workspaceGroupID
    else { return }
    lastSelectedTabIDByWorkspaceGroup[groupID] = selectedTabID
    if selectedWorkspaceGroupID != groupID { selectedWorkspaceGroupID = groupID }
  }
}

/// 窗口内工作区操作的失败原因。
enum WorkspaceGroupError: Error, Equatable {
  /// 当前显示的是远端机器，本地工作区操作不适用。
  case remoteMachineActive
}
