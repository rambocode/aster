// 命名工作区注册表的维护逻辑测试：清理淘汰、与旧键对账、编解码往返。
import Foundation
import Testing

@testable import AsterCore

@Test("prune：丢弃非法 suite、去重，并按最近使用淘汰超额的已关闭条目")
func namedWorkspacePruneEvictsOldestClosed() throws {
  let invalid = NamedWorkspace(
    name: "bad", storage: .suite("com.example.foreign"), isPinned: true, isOpen: false,
    createdAt: namedWorkspaceT0, lastActiveAt: namedWorkspaceT0)
  let shared = namedWorkspaceSuite()
  let duplicateA = NamedWorkspace(
    name: "dup-a", storage: .suite(shared), isPinned: true, isOpen: true, createdAt: namedWorkspaceT0,
    lastActiveAt: namedWorkspaceT0)
  let duplicateB = NamedWorkspace(
    name: "dup-b", storage: .suite(shared), isPinned: true, isOpen: false, createdAt: namedWorkspaceT0,
    lastActiveAt: namedWorkspaceT0)
  let total = NamedWorkspaceRegistry.maximumRetained + 3
  let closed = (0..<total).map { index in
    NamedWorkspace(
      name: "c\(index)", storage: .suite(namedWorkspaceSuite()), isPinned: true, isOpen: false, createdAt: namedWorkspaceT0,
      lastActiveAt: namedWorkspaceT0.addingTimeInterval(Double(index)))
  }
  var registry = NamedWorkspaceRegistry(workspaces: [invalid, duplicateA, duplicateB] + closed)

  let dropped = registry.prune()

  #expect(!registry.workspaces.contains { $0.id == invalid.id })
  #expect(registry.workspaces.contains { $0.id == duplicateA.id })
  #expect(!registry.workspaces.contains { $0.id == duplicateB.id })
  // 最旧的 3 个已关闭条目被淘汰，调用方据返回值删除它们的 suite。
  let expected = closed.prefix(3).compactMap { entry -> String? in
    if case .suite(let name) = entry.storage { return name }
    return nil
  }
  #expect(Set(dropped) == Set(expected))
  #expect(registry.workspaces.filter { !$0.isOpen }.count == NamedWorkspaceRegistry.maximumRetained)
}

@Test("prune：只保留已知机器的远端活动记录")
func namedWorkspacePruneDropsUnknownMachines() {
  let known = UUID()
  var registry = NamedWorkspaceRegistry()
  registry.markRemoteActive(machineID: known, workspaceID: "w1", now: namedWorkspaceT0)
  registry.markRemoteActive(machineID: UUID(), workspaceID: "w2", now: namedWorkspaceT0)
  _ = registry.prune(knownMachineIDs: [known])
  #expect(registry.remoteActivity.keys.sorted() == [
    NamedWorkspaceRegistry.remoteActivityKey(machineID: known, workspaceID: "w1")
  ])
}

@Test("reconcile：旧键与注册表一致时不变；降级期间的开关窗按旧键修正")
func namedWorkspaceReconcileFollowsLegacyKey() throws {
  var registry = NamedWorkspaceRegistry.migrated(mainName: "主工作区", legacySuites: [], now: namedWorkspaceT0)
  let transient = namedWorkspaceSuite()
  let pinned = namedWorkspaceSuite()
  let pinnedClosed = namedWorkspaceSuite()
  try registry.create(name: "t", storage: .suite(transient), isPinned: false, now: namedWorkspaceT0)
  try registry.create(name: "p", storage: .suite(pinned), isPinned: true, now: namedWorkspaceT0)
  let reopened = try registry.create(
    name: "pc", storage: .suite(pinnedClosed), isPinned: true, now: namedWorkspaceT0)
  registry.markClosed(reopened.id)

  var unchanged = registry
  unchanged.reconcile(
    legacyOpenSuites: registry.openSuiteNames, mainName: "主工作区", now: namedWorkspaceT0,
    codename: namedWorkspaceFixedCodename)
  #expect(unchanged == registry)

  // 旧版本里：关掉了 transient 与 pinned，新开了 added，又恢复了 pinnedClosed。
  let added = namedWorkspaceSuite()
  registry.reconcile(
    legacyOpenSuites: [pinnedClosed, added, "com.example.foreign"], mainName: "主工作区", now: namedWorkspaceT0,
    codename: namedWorkspaceFixedCodename)
  #expect(registry.workspace(storage: .suite(transient)) == nil)
  #expect(registry.workspace(storage: .suite(pinned))?.isOpen == false)
  #expect(registry.workspace(storage: .suite(pinnedClosed))?.isOpen == true)
  let addedEntry = try #require(registry.workspace(storage: .suite(added)))
  #expect(addedEntry.isOpen && !addedEntry.isPinned && addedEntry.name == "quiet-otter")
}

@Test("reconcile：主工作区条目丢失时补回")
func namedWorkspaceReconcileRestoresMainEntry() {
  var registry = NamedWorkspaceRegistry()
  registry.reconcile(legacyOpenSuites: nil, mainName: "主工作区", now: namedWorkspaceT0)
  #expect(registry.workspace(storage: .standard)?.name == "主工作区")
  #expect(registry.workspace(storage: .standard)?.isPinned == true)
}

@Test("注册表可编解码往返")
func namedWorkspaceRegistryRoundTrips() throws {
  var registry = NamedWorkspaceRegistry.migrated(
    mainName: "主工作区", legacySuites: [namedWorkspaceSuite()], now: namedWorkspaceT0)
  registry.markRemoteActive(machineID: UUID(), workspaceID: "w", now: namedWorkspaceT0)
  let data = try JSONEncoder().encode(registry)
  #expect(try JSONDecoder().decode(NamedWorkspaceRegistry.self, from: data) == registry)
}
