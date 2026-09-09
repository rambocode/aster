import AppKit
import Testing

@testable import Aster
@testable import AsterCore

/// P2.6 / A09 的真实链路验收：旧工作区兼容、显式托管迁移、失败回滚与备份恢复。
///
/// 关键约束：迁移只创建新的受管终端并追加新标签；旧的本地 Pane 与其 PTY 一律保留，
/// 由用户自行关闭。这里用真实后台服务与真实 PID 验证，不用布局比较冒充。

/// 构造一份缺少受管字段的旧工作区快照（模拟升级用户的已有数据）。
///
/// `PaneDescriptor` 在 `managedTerminal == nil` 时不写出该键，所以直接编码就是
/// 旧版本客户端会产生的字节，不需要手写 JSON。
private func legacySnapshotData(directory: String) throws -> Data {
  let pane = PaneDescriptor(kind: .terminal, workingDirectory: directory)
  let tab = WorkspaceTabSnapshot(id: UUID(), title: "旧标签", layout: .leaf(pane))
  return try JSONEncoder().encode(WorkspaceSnapshot(selectedTabID: tab.id, tabs: [tab]))
}

@Test("旧工作区可读且不被自动托管；显式迁移创建新受管标签并保留旧 PTY")
@MainActor
func managedMigrationKeepsLegacyPanesAndCreatesNewManagedTab() async throws {
  _ = NSApplication.shared
  let file = URL(fileURLWithPath: #filePath)
  let repository = file.deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  let binary = repository.appendingPathComponent("SessionRuntime/zig-out/bin/aster-session").path
  #expect(FileManager.default.isExecutableFile(atPath: binary), "缺少运行时二进制：\(binary)")
  guard FileManager.default.isExecutableFile(atPath: binary) else { return }

  let base = URL(fileURLWithPath: "/tmp/aster-p2-tests", isDirectory: true)
  try? FileManager.default.createDirectory(
    at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let stateParent = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(
    at: stateParent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

  let suiteName = "AsterTests.migration.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  defer { defaults.removePersistentDomain(forName: suiteName) }
  defaults.set(try legacySnapshotData(directory: "/tmp"), forKey: "aster.workspace.snapshot.v1")

  // —— 第一段：受管模式关闭时，旧数据按本地模式恢复 ——
  let disabled = ManagedTerminalCoordinator(environment: [:])
  let previous = ManagedTerminalCoordinator.shared
  ManagedTerminalCoordinator.shared = disabled
  defer { ManagedTerminalCoordinator.shared = previous }

  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let legacyTab = try #require(model.selectedTab)
  let legacySession = try #require(legacyTab.activeSession)
  #expect(!legacySession.isManagedTerminal, "旧 Pane 不得被自动托管")
  #expect(legacyTab.layout.allPanes.allSatisfy { $0.managedTerminal == nil })

  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.makeKeyAndOrderFront(nil)
  defer { window.orderOut(nil) }
  let legacyHost = legacySession.makeTerminalHost(preferences: preferences)
  legacyHost.frame = window.contentView?.bounds ?? .zero
  window.contentView?.addSubview(legacyHost)
  window.layoutIfNeeded()
  for _ in 0..<200 where legacySession.lifecycleState != .running {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(legacySession.isRunning, "旧本地 PTY 必须正常启动")

  // —— 第二段：服务不可达时迁移必须失败并回滚 ——
  let unreachable = ManagedTerminalCoordinator(
    environment: [
      ManagedTerminalCoordinator.binaryEnvironmentKey: binary,
      ManagedTerminalCoordinator.stateDirectoryEnvironmentKey: "/tmp/aster-p2-tests/does-not-exist",
      ManagedTerminalCoordinator.sessionNameEnvironmentKey: "p2migration",
    ])
  ManagedTerminalCoordinator.shared = unreachable
  let tabCountBefore = model.tabs.count
  let failed = try #require(model.migrateWorkspaceToManagedSession())
  #expect(!failed.succeeded, "服务不可达时迁移必须失败")
  #expect(model.tabs.count == tabCountBefore, "失败不得改变现有标签")
  #expect(legacySession.isRunning, "失败不得结束任何旧 PTY")

  // —— 第三段：成功路径 ——
  let coordinator = ManagedTerminalCoordinator(
    environment: [
      ManagedTerminalCoordinator.binaryEnvironmentKey: binary,
      ManagedTerminalCoordinator.stateDirectoryEnvironmentKey: stateParent.path,
      ManagedTerminalCoordinator.sessionNameEnvironmentKey: "p2migration",
    ])
  ManagedTerminalCoordinator.shared = coordinator
  _ = try #require(coordinator.connect())

  let outcome = try #require(model.migrateWorkspaceToManagedSession())
  #expect(outcome.succeeded, "迁移应成功：\(String(describing: outcome.failure))")
  #expect(model.tabs.count == tabCountBefore + 1, "迁移追加新的受管标签")
  #expect(legacySession.isRunning, "旧 PTY 必须保留到用户自行关闭")
  #expect(legacyTab.layout.allPanes.allSatisfy { $0.managedTerminal == nil }, "旧标签保持非受管")

  let migratedTab = try #require(model.tabs.last)
  let managedPanes = migratedTab.layout.allPanes.filter { $0.managedTerminal != nil }
  #expect(!managedPanes.isEmpty, "新标签必须持有受管引用")

  let live = try coordinator.liveTerminals()
  #expect(live.contains { $0.state == .running }, "迁移必须创建真实的新受管进程")

  // 备份可回滚到迁移前布局。
  let backup = try #require(outcome.backupURL)
  let restored = try ManagedTerminalMigration.restore(from: backup)
  #expect(restored.allSatisfy { $0.layout.allPanes.allSatisfy { $0.managedTerminal == nil } })

  legacySession.stop(immediately: true)
  for pane in managedPanes {
    if let reference = pane.managedTerminal { _ = coordinator.terminate(reference) }
  }
  let stop = Process()
  stop.executableURL = URL(fileURLWithPath: binary)
  stop.arguments = ["server", "stop", stateParent.path, "p2migration"]
  stop.standardOutput = FileHandle.nullDevice
  stop.standardError = FileHandle.nullDevice
  try? stop.run()
  stop.waitUntilExit()
}
