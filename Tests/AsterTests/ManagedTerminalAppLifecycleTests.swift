import AppKit
import Testing

@testable import Aster
@testable import AsterCore

/// P2 的真实进程验收（A08 核心断言）。
///
/// 这些用例连接真实的 `aster-session` 后台服务、创建真实受管进程，并在真实 AppKit
/// 窗口里挂载 Ghostty surface 作为显示桥。判定标准全部基于服务端上报的真实 PID 与
/// 输出增长，不用“布局仍在”或“标题相同”冒充保活。

/// 本仓库构建出的运行时二进制。缺失即判失败，不静默跳过。
@MainActor
private func runtimeBinaryPath() -> String {
  let file = URL(fileURLWithPath: #filePath)
  let repository = file.deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  return repository.appendingPathComponent("SessionRuntime/zig-out/bin/aster-session").path
}

/// 为一次验收准备只对当前用户开放的私有状态父目录。
private func makeStateParent() throws -> URL {
  let base = URL(fileURLWithPath: "/tmp/aster-p2-tests", isDirectory: true)
  try? FileManager.default.createDirectory(
    at: base, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  let directory = base.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(
    at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
  return directory
}

/// 只记录调用次数的录制层替身：用来证明“分离不写 session ended”。
private final class RecordingSpy: TerminalEventRecording {
  private(set) var endedCalls: [Int32?] = []
  private(set) var startedCount = 0

  func sessionStarted(id: UUID, projectPath: String, shell: String?) { startedCount += 1 }
  func commandStarted(id: UUID, command: String?, workingDirectory: String) {}
  func commandFinished(id: UUID, command: String?, exitStatus: Int?) {}
  func agentChanged(id: UUID, provider: String?, agentSessionID: String?) {}
  func receivePTYOutput(id: UUID, bytes: ArraySlice<UInt8>) {}
  func sessionEnded(id: UUID, exitCode: Int32?) { endedCalls.append(exitCode) }
  func recordingMode(for id: UUID) -> RecordingMode { .off }
  func isRecording(id: UUID) -> Bool { false }
  func setIncognito(_ incognito: Bool, for id: UUID) {}
}

/// 进程是否仍存在（signal 0 探测），用于独立于服务端回复的第二重证据。
private func processAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

@Test("受管终端：分离保活、重新附加同一 PID、显式结束才终止进程")
@MainActor
func managedTerminalDetachKeepsProcessAliveAndReattachesSamePID() async throws {
  _ = NSApplication.shared
  let binary = runtimeBinaryPath()
  #expect(FileManager.default.isExecutableFile(atPath: binary), "缺少运行时二进制：\(binary)")
  guard FileManager.default.isExecutableFile(atPath: binary) else { return }

  let stateParent = try makeStateParent()
  let outputFile = stateParent.appendingPathComponent("counter.txt")
  let coordinator = ManagedTerminalCoordinator(
    environment: [
      ManagedTerminalCoordinator.binaryEnvironmentKey: binary,
      ManagedTerminalCoordinator.stateDirectoryEnvironmentKey: stateParent.path,
      ManagedTerminalCoordinator.sessionNameEnvironmentKey: "p2acceptance",
    ])
  let previous = ManagedTerminalCoordinator.shared
  ManagedTerminalCoordinator.shared = coordinator
  defer { ManagedTerminalCoordinator.shared = previous }

  let identity = try #require(coordinator.connect(), "后台会话服务未能启动")
  #expect(coordinator.connectionState == .online)

  // 持续输出的测试任务：判定保活只看这个文件是否继续增长与 PID 是否不变。
  let script = "i=0; while true; do i=$((i+1)); echo \"$i\" >> \(outputFile.path); sleep 0.2; done"
  let created = try coordinator.createTerminal(
    workingDirectory: "/tmp", argv: ["/bin/sh", "-c", script])
  let managedPID = try #require(created.pid)
  #expect(created.state == .running)

  let preferences = AppPreferences(defaults: {
    let suite = "AsterTests.managed.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }())
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.makeKeyAndOrderFront(nil)
  defer { window.orderOut(nil) }

  let recorder = RecordingSpy()
  let session = TerminalSession(workingDirectory: "/tmp")
  session.eventRecorder = recorder
  session.bindManagedTerminal(created.reference)
  let host = session.makeTerminalHost(preferences: preferences)
  host.frame = window.contentView?.bounds ?? .zero
  window.contentView?.addSubview(host)
  window.layoutIfNeeded()
  // 桥进程是 surface 的子进程；它运行起来才说明附加成功。
  for _ in 0..<200 where session.lifecycleState != .running {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(session.isManagedTerminal)

  try await Task.sleep(for: .milliseconds(800))
  let beforeDetach = try lineCount(of: outputFile)

  // —— 分离 ——
  #expect(session.detachManagedTerminal())
  #expect(session.lifecycleState == .detached)
  // A08 的硬性断言：分离不得写成 session ended。
  #expect(recorder.endedCalls.isEmpty)

  try await Task.sleep(for: .seconds(2))
  #expect(processAlive(managedPID), "分离后受管进程必须继续存在")
  let afterDetach = try lineCount(of: outputFile)
  #expect(afterDetach > beforeDetach, "无人订阅时任务必须继续产出")

  let live = try coordinator.liveTerminals()
  let stillRunning = try #require(
    live.first { $0.reference.terminalID == created.reference.terminalID })
  #expect(stillRunning.state == .running)
  #expect(stillRunning.pid == managedPID, "分离前后 PID 必须不变")
  #expect(stillRunning.serverEpoch == identity.serverEpoch)

  // —— 重新附加（模拟重开 App：新的 Session 对象 + 持久化引用对账） ——
  let resolution = coordinator.reconcile(
    references: [created.reference], persistedServerEpoch: identity.serverEpoch)[created.reference]
  guard case .attached(let reattachStatus) = resolution else {
    Issue.record("重开后对账结果应为 attached，实际为 \(String(describing: resolution))")
    return
  }
  #expect(reattachStatus.pid == managedPID)

  let reattached = TerminalSession(workingDirectory: "/tmp")
  let reattachedRecorder = RecordingSpy()
  reattached.eventRecorder = reattachedRecorder
  reattached.bindManagedTerminal(created.reference)
  let host2 = reattached.makeTerminalHost(preferences: preferences)
  host2.frame = window.contentView?.bounds ?? .zero
  window.contentView?.addSubview(host2)
  window.layoutIfNeeded()
  for _ in 0..<200 where reattached.lifecycleState != .running {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(processAlive(managedPID), "重新附加不得替换原进程")

  // —— 桥内分离（Ctrl+B q）：桥退出不等于任务结束 ——
  #expect(reattached.sendAutomationBytes([0x02, 0x71]))
  for _ in 0..<250 where reattached.lifecycleState != .detached {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(reattached.lifecycleState == .detached, "桥退出后必须是分离态，不是已结束")
  #expect(reattachedRecorder.endedCalls.isEmpty, "桥退出不得写成 session ended")
  #expect(processAlive(managedPID), "桥退出后受管进程必须继续运行")

  // —— 显式结束才终止进程 ——
  #expect(reattached.terminateManagedTerminal())
  for _ in 0..<100 where processAlive(managedPID) {
    try await Task.sleep(for: .milliseconds(50))
  }
  #expect(!processAlive(managedPID), "显式结束后受管进程必须退出")
  #expect(reattachedRecorder.endedCalls.count >= 1, "显式结束必须写一次结束事件")

  let afterEnd = try coordinator.liveTerminals()
    .first { $0.reference.terminalID == created.reference.terminalID }
  #expect(afterEnd?.state != .running)

  // 清理：停止本次验收启动的服务实例。
  stopServer(binary: binary, stateParent: stateParent.path, name: "p2acceptance")
}

@Test("受管终端不可用时只显示明确错误，不启动未标识的本地 Shell")
@MainActor
func managedTerminalFailureDoesNotFallBackToPlainLocalShell() async throws {
  _ = NSApplication.shared
  let preferences = AppPreferences(defaults: {
    let suite = "AsterTests.managed.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }())
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.makeKeyAndOrderFront(nil)
  defer { window.orderOut(nil) }

  let session = TerminalSession(workingDirectory: "/tmp")
  session.markManagedFailure("后台会话服务不可达")
  let host = session.makeTerminalHost(preferences: preferences)
  host.frame = window.contentView?.bounds ?? .zero
  window.contentView?.addSubview(host)
  window.layoutIfNeeded()
  try await Task.sleep(for: .milliseconds(200))

  #expect(session.lifecycleState == .startFailed)
  #expect(session.startupError?.contains("后台会话服务不可达") == true)
  #expect(!session.isRunning, "失败路径不得落地任何本地 Shell 进程")
  session.stop(immediately: true)
}

/// 统计计数文件行数；文件尚未创建时返回 0。
private func lineCount(of url: URL) throws -> Int {
  guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
  return text.split(separator: "\n").count
}

/// 停止本次验收启动的服务实例，避免残留后台进程。
@MainActor
private func stopServer(binary: String, stateParent: String, name: String) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: binary)
  process.arguments = ["server", "stop", stateParent, name]
  process.standardOutput = FileHandle.nullDevice
  process.standardError = FileHandle.nullDevice
  try? process.run()
  process.waitUntilExit()
}

@Test("退出 App 并重开后，受管任务的 PID 不变且引用被持久化")
@MainActor
func managedTerminalSurvivesAppTerminationAndRestoresSamePID() async throws {
  _ = NSApplication.shared
  let binary = runtimeBinaryPath()
  #expect(FileManager.default.isExecutableFile(atPath: binary), "缺少运行时二进制：\(binary)")
  guard FileManager.default.isExecutableFile(atPath: binary) else { return }

  let stateParent = try makeStateParent()
  let coordinator = ManagedTerminalCoordinator(
    environment: [
      ManagedTerminalCoordinator.binaryEnvironmentKey: binary,
      ManagedTerminalCoordinator.stateDirectoryEnvironmentKey: stateParent.path,
      ManagedTerminalCoordinator.sessionNameEnvironmentKey: "p2appquit",
    ])
  let previous = ManagedTerminalCoordinator.shared
  ManagedTerminalCoordinator.shared = coordinator
  defer { ManagedTerminalCoordinator.shared = previous }
  _ = try #require(coordinator.connect())

  let suiteName = "AsterTests.appquit.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  defer { defaults.removePersistentDomain(forName: suiteName) }

  // —— 第一次启动：新建标签会创建受管终端 ——
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  #expect(session.isManagedTerminal, "受管模式开启时新建 Pane 必须是受管终端")
  let reference = try #require(session.managedTerminal)
  let created = try #require(
    try coordinator.liveTerminals().first { $0.reference.terminalID == reference.terminalID })
  let managedPID = try #require(created.pid)
  #expect(tab.layout.allPanes.contains { $0.managedTerminal == reference }, "引用必须写回布局")

  // —— 退出 App：必须是分离语义 ——
  model.commitTermination()
  try await Task.sleep(for: .milliseconds(500))
  #expect(processAlive(managedPID), "退出 App 后受管任务必须继续运行")

  // —— 重开 App：从持久化快照恢复并查服务端真实状态 ——
  let reopened = AppModel(defaults: defaults)
  reopened.ensureInitialTab()
  let restoredTab = try #require(reopened.selectedTab)
  let restoredSession = try #require(restoredTab.activeSession)
  #expect(restoredSession.managedTerminal == reference, "重开后必须绑定同一受管终端引用")
  let afterReopen = try #require(
    try coordinator.liveTerminals().first { $0.reference.terminalID == reference.terminalID })
  #expect(afterReopen.state == .running)
  #expect(afterReopen.pid == managedPID, "退出/重开 App 后同一任务的 PID 必须不变")

  _ = coordinator.terminate(reference)
  stopServer(binary: binary, stateParent: stateParent.path, name: "p2appquit")
}
