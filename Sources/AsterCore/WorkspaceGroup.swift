import Foundation

// 窗口内工作区（标签分组）：一个窗口可以有多个工作区，每个工作区是一组标签。
//
// 侧栏一次只显示当前工作区的标签；切走的工作区里的终端照常运行。分组只保存身份与名称，
// 标签归属记在各标签的 `workspaceGroupID` 上，所以窗口快照仍是一份扁平标签列表，
// 旧快照没有分组字段时整体落进一个默认工作区。

/// 窗口内的一个工作区。
public struct WorkspaceGroup: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var name: String
  public var createdAt: Date

  public init(id: UUID = UUID(), name: String, createdAt: Date = Date()) {
    self.id = id
    self.name = name
    self.createdAt = createdAt
  }
}

/// 窗口内工作区的纯规则：恢复整理、切换选中与关闭后的相邻标签。
public enum WorkspaceGroupRules {
  /// 恢复整理的结果。`assignments` 与输入的标签顺序一一对应。
  public struct Normalized: Equatable, Sendable {
    public var groups: [WorkspaceGroup]
    public var assignments: [UUID]
    public var selectedGroupID: UUID
  }

  /// 恢复时整理分组与标签归属。
  ///
  /// - 没有分组（旧快照）时建一个名为 `defaultName` 的分组；
  /// - 重复 id 只保留第一个；
  /// - 缺失或指向不存在分组的标签归到第一个分组，保证每个标签都有归属；
  /// - 选中分组不存在时回退到第一个分组。
  public static func normalized(
    groups: [WorkspaceGroup]?,
    tabGroupIDs: [UUID?],
    selectedGroupID: UUID?,
    defaultName: String,
    now: Date = Date()
  ) -> Normalized {
    var seen = Set<UUID>()
    var result = (groups ?? []).filter { seen.insert($0.id).inserted }
    if result.isEmpty { result = [WorkspaceGroup(name: defaultName, createdAt: now)] }
    let fallback = result[0].id
    let known = Set(result.map(\.id))
    let assignments = tabGroupIDs.map { id in id.flatMap { known.contains($0) ? $0 : nil } ?? fallback }
    let selected = selectedGroupID.flatMap { known.contains($0) ? $0 : nil } ?? fallback
    return Normalized(groups: result, assignments: assignments, selectedGroupID: selected)
  }

  /// 切到某个工作区时应选中的标签：优先该工作区上次选中的标签，否则取它的第一个标签。
  /// 工作区里没有标签时返回 nil，由调用方补一个新 Shell。
  public static func tabToSelect(
    inGroup groupID: UUID,
    tabGroupIDs: [(tabID: UUID, groupID: UUID?)],
    remembered: UUID?
  ) -> UUID? {
    let members = tabGroupIDs.filter { $0.groupID == groupID }.map(\.tabID)
    if let remembered, members.contains(remembered) { return remembered }
    return members.first
  }

  /// 删除某个工作区后应切到哪个工作区：优先它后面的一个，没有就取前面的一个。
  /// 只剩它自己时返回 nil（调用方应拒绝删除）。
  public static func groupToSelectAfterRemoving(_ groupID: UUID, from groups: [WorkspaceGroup]) -> UUID? {
    guard let index = groups.firstIndex(where: { $0.id == groupID }), groups.count > 1 else { return nil }
    let remaining = groups.filter { $0.id != groupID }
    return remaining[min(index, remaining.count - 1)].id
  }

  /// 在 `names` 之外生成一个不重名的默认名称，例如「工作区 2」。
  public static func uniqueName(base: String, existing names: [String]) -> String {
    let taken = Set(names)
    var index = names.count + 1
    while taken.contains("\(base) \(index)") { index += 1 }
    return "\(base) \(index)"
  }
}
