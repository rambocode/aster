// 命名工作区注册表的纯模型测试：迁移、增删改、关闭语义、打开上限、名称与代号。
import Foundation
import Testing

@testable import AsterCore

/// 固定时间起点。
let namedWorkspaceT0 = Date(timeIntervalSince1970: 1_000_000)

/// 生成一个合法的附加窗口 suite 名（两个注册表测试文件共用）。
func namedWorkspaceSuite() -> String { NamedWorkspaceRegistry.makeSuiteName() }

/// 固定代号，断言不受随机数影响。
func namedWorkspaceFixedCodename() -> String { "quiet-otter" }

@Test("迁移：主窗口成为固定保留的主工作区，旧 suite 成为不保留的已打开代号工作区")
func namedWorkspaceMigrationBuildsMainAndLegacyEntries() {
  let a = namedWorkspaceSuite()
  let b = namedWorkspaceSuite()
  let registry = NamedWorkspaceRegistry.migrated(
    mainName: "主工作区", legacySuites: [a, "com.example.foreign", a, b], now: namedWorkspaceT0,
    codename: namedWorkspaceFixedCodename)

  #expect(registry.workspaces.count == 3)
  let main = registry.workspaces[0]
  #expect(main.storage == .standard && main.isPinned && main.isOpen && main.name == "主工作区")
  #expect(registry.workspaces[1].storage == .suite(a))
  #expect(registry.workspaces[2].storage == .suite(b))
  #expect(registry.workspaces.dropFirst().allSatisfy { !$0.isPinned && $0.isOpen })
  #expect(registry.workspaces[1].name == "quiet-otter")
  #expect(registry.openSuiteNames == [a, b])
}

@Test("迁移：旧版最多恢复 16 个附加窗口，迁移后同样全部保留为打开")
func namedWorkspaceMigrationKeepsAllSixteenLegacyWindows() {
  let legacy = (0..<20).map { _ in namedWorkspaceSuite() }
  let registry = NamedWorkspaceRegistry.migrated(
    mainName: "主工作区", legacySuites: legacy, now: namedWorkspaceT0, codename: namedWorkspaceFixedCodename)

  #expect(registry.openSuiteNames == Array(legacy.prefix(16)))
  #expect(registry.workspaces.count == NamedWorkspaceRegistry.maximumOpen)
}

@Test("create / rename / remove：重命名自动固定保留，主工作区不能删")
func namedWorkspaceCreateRenameRemove() throws {
  var registry = NamedWorkspaceRegistry.migrated(mainName: "主工作区", legacySuites: [], now: namedWorkspaceT0)
  let name = namedWorkspaceSuite()
  let created = try registry.create(name: "  api  ", storage: .suite(name), isPinned: false, now: namedWorkspaceT0)
  #expect(created.name == "api" && created.isOpen && !created.isPinned)

  try registry.rename(created.id, to: "backend")
  #expect(registry.workspace(created.id)?.name == "backend")
  #expect(registry.workspace(created.id)?.isPinned == true)

  let removed = try registry.remove(created.id)
  #expect(removed.storage == .suite(name))
  #expect(registry.workspace(created.id) == nil)

  let main = try #require(registry.workspace(storage: .standard))
  let snapshot = registry
  #expect(throws: NamedWorkspaceRegistryError.cannotRemoveStandard) {
    var copy = snapshot
    try copy.remove(main.id)
  }
  #expect(throws: NamedWorkspaceRegistryError.unknownWorkspace(created.id)) {
    var copy = snapshot
    try copy.rename(created.id, to: "x")
  }
}

@Test("markClosed：不保留的条目删除并要求删 suite，固定保留与主工作区只标记关闭")
func namedWorkspaceMarkClosedHonoursPinning() throws {
  var registry = NamedWorkspaceRegistry.migrated(mainName: "主工作区", legacySuites: [], now: namedWorkspaceT0)
  let transient = try registry.create(name: "a", storage: .suite(namedWorkspaceSuite()), isPinned: false, now: namedWorkspaceT0)
  let pinned = try registry.create(name: "b", storage: .suite(namedWorkspaceSuite()), isPinned: true, now: namedWorkspaceT0)
  let main = try #require(registry.workspace(storage: .standard))

  let removeTransient = registry.markClosed(transient.id)
  #expect(removeTransient)
  #expect(registry.workspace(transient.id) == nil)

  let removePinned = registry.markClosed(pinned.id)
  #expect(!removePinned)
  #expect(registry.workspace(pinned.id)?.isOpen == false)

  let removeMain = registry.markClosed(main.id)
  #expect(!removeMain)
  #expect(registry.workspace(main.id)?.isOpen == false)

  // 重新打开固定保留的条目。
  try registry.markOpened(pinned.id, now: namedWorkspaceT0.addingTimeInterval(5))
  #expect(registry.workspace(pinned.id)?.isOpen == true)
  #expect(registry.recentFirst.first?.id == pinned.id)
}

@Test("打开数量上限：create 与 markOpened 超限抛 tooManyOpen，markActive 不受限")
func namedWorkspaceOpenLimit() throws {
  var registry = NamedWorkspaceRegistry.migrated(mainName: "主工作区", legacySuites: [], now: namedWorkspaceT0)
  let closed = try registry.create(name: "later", storage: .suite(namedWorkspaceSuite()), isPinned: true, now: namedWorkspaceT0)
  registry.markClosed(closed.id)
  while registry.workspaces.filter(\.isOpen).count < NamedWorkspaceRegistry.maximumOpen {
    try registry.create(name: "w", storage: .suite(namedWorkspaceSuite()), isPinned: false, now: namedWorkspaceT0)
  }
  // 闭包不能捕获可变的 registry，断言在副本上执行。
  let full = registry
  #expect(throws: NamedWorkspaceRegistryError.tooManyOpen) {
    var copy = full
    try copy.create(name: "x", storage: .suite(namedWorkspaceSuite()), isPinned: false, now: namedWorkspaceT0)
  }
  #expect(throws: NamedWorkspaceRegistryError.tooManyOpen) {
    var copy = full
    try copy.markOpened(closed.id, now: namedWorkspaceT0)
  }
  var active = full
  active.markActive(closed.id, now: namedWorkspaceT0)
  #expect(active.workspace(closed.id)?.isOpen == true)
}

@Test("名称校验：去首尾空白，空名与超长名被拒")
func namedWorkspaceNameValidation() throws {
  #expect(try NamedWorkspaceRegistry.validatedName("  demo \n") == "demo")
  #expect(throws: NamedWorkspaceRegistryError.emptyName) {
    try NamedWorkspaceRegistry.validatedName("   ")
  }
  let longest = String(repeating: "工", count: NamedWorkspaceRegistry.maximumNameLength)
  #expect(try NamedWorkspaceRegistry.validatedName(longest) == longest)
  #expect(throws: NamedWorkspaceRegistryError.nameTooLong) {
    try NamedWorkspaceRegistry.validatedName(longest + "作")
  }
}

@Test("suite 名校验只接受前缀 + UUID")
func namedWorkspaceSuiteNameValidation() {
  #expect(NamedWorkspaceRegistry.isValidSuiteName(NamedWorkspaceRegistry.makeSuiteName()))
  #expect(!NamedWorkspaceRegistry.isValidSuiteName("com.example.foreign"))
  #expect(!NamedWorkspaceRegistry.isValidSuiteName(NamedWorkspaceRegistry.suitePrefix + "nope"))
}

@Test("代号格式为「形容词-动物」，全小写 ASCII")
func workspaceCodenameFormat() {
  for _ in 0..<50 {
    let codename = WorkspaceCodename.generate()
    let parts = codename.split(separator: "-")
    #expect(parts.count == 2)
    #expect(WorkspaceCodename.adjectives.contains(String(parts[0])))
    #expect(WorkspaceCodename.animals.contains(String(parts[1])))
    #expect(codename.allSatisfy { $0.isASCII && ($0.isLowercase || $0 == "-") })
  }
}
