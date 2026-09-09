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

  // 分离后视图树仍会重建（布局写回、标签切换、主题刷新）。重建不得顺手新建 surface，
  // 否则会立刻拉起新的显示桥，把刚完成的分离自动撤销。
  let rebuilt = session.makeTerminalHost(preferences: preferences)
  #expect(rebuilt === host, "分离后应复用原容器")
  try await Task.sleep(for: .milliseconds(500))
  #expect(session.lifecycleState == .detached, "重建视图树不得把分离态自动改回附着")

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
  // 绑定在 P3 起是异步的（远端传输每次都是 SSH 往返，不能阻塞主线程），
  // 因此这里等待绑定完成，而不是假设它在 ensureInitialTab 返回时已经发生。
  for _ in 0..<250 where !session.isManagedTerminal {
    try await Task.sleep(for: .milliseconds(20))
  }
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
  // 恢复绑定同样是异步的（要向服务端查真实状态），等待对账结果落地再断言。
  for _ in 0..<250 where restoredSession.managedTerminal == nil {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(restoredSession.managedTerminal == reference, "重开后必须绑定同一受管终端引用")
  let afterReopen = try #require(
    try coordinator.liveTerminals().first { $0.reference.terminalID == reference.terminalID })
  #expect(afterReopen.state == .running)
  #expect(afterReopen.pid == managedPID, "退出/重开 App 后同一任务的 PID 必须不变")

  _ = coordinator.terminate(reference)
  stopServer(binary: binary, stateParent: stateParent.path, name: "p2appquit")
}

/// 找出正在附着某个受管终端的显示桥进程 PID（`aster-session terminal attach <id>`）。
/// 用命令行精确匹配而不是猜测前台 PID，避免误杀无关进程。
private func bridgeProcessIdentifier(terminalID: String) -> Int32? {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/bin/ps")
  process.arguments = ["-axo", "pid=,command="]
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = FileHandle.nullDevice
  guard (try? process.run()) != nil else { return nil }
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  let text = String(decoding: data, as: UTF8.self)
  for line in text.split(separator: "\n") {
    guard line.contains("terminal attach"), line.contains(terminalID) else { continue }
    let trimmed = line.drop { $0 == " " }
    guard let pid = Int32(trimmed.prefix { $0.isNumber }) else { continue }
    return pid
  }
  return nil
}

@Test("显示桥被杀后以服务端状态为准：仍可经控制协议分离与结束")
@MainActor
func managedTerminalBridgeCrashKeepsCLIDetachAndEndUsable() async throws {
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
      ManagedTerminalCoordinator.sessionNameEnvironmentKey: "p2bridgecrash",
    ])
  let previous = ManagedTerminalCoordinator.shared
  ManagedTerminalCoordinator.shared = coordinator
  defer {
    ManagedTerminalCoordinator.shared = previous
    stopServer(binary: binary, stateParent: stateParent.path, name: "p2bridgecrash")
  }
  _ = try #require(coordinator.connect(), "后台会话服务未能启动")

  let script = "i=0; while true; do i=$((i+1)); echo \"$i\" >> \(outputFile.path); sleep 0.2; done"
  let created = try coordinator.createTerminal(
    workingDirectory: "/tmp", argv: ["/bin/sh", "-c", script])
  let managedPID = try #require(created.pid)

  // 控制协议侧夹具：真实 AppModel + 真实 pane，session.detach/end 走完整分发路径。
  let workspace = try ControlTestWorkspace()
  defer { workspace.tearDown() }
  let bridge = AsterControlBridge(socketPath: "/tmp/aster-p2-bridge-crash.sock", binaryPath: "/tmp/aster-cli")
  bridge.activeModelProvider = { [weak model = workspace.model] in model }
  bridge.attach(model: workspace.model)
  let policy = AsterControlDispatcher.Policy(
    allowSendKeys: true, allowSensitiveSessions: false, shell: AsterConfiguration().shell)
  let dispatcher = AsterControlDispatcher(bridge: bridge, version: "9.9.9") { policy }
  let client = ControlFakeClient()

  let session = try #require(workspace.model.selectedTab?.activeSession)
  // `ControlTestWorkspace` 会真的建一个 Pane，受管模式下它自己也会异步创建一个受管终端。
  // P3 起绑定是异步的，必须等那次自动绑定落地并把它结束掉，否则它会在本用例显式绑定
  // 之后才覆盖引用，导致后面的 end 结束错误的终端。
  for _ in 0..<250 where session.managedTerminal == nil {
    try await Task.sleep(for: .milliseconds(20))
  }
  if let autoCreated = session.managedTerminal, autoCreated != created.reference {
    _ = coordinator.terminate(autoCreated)
  }
  session.bindManagedTerminal(created.reference)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 800, height: 480),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.makeKeyAndOrderFront(nil)
  defer { window.orderOut(nil) }
  let host = session.makeTerminalHost(preferences: workspace.preferences)
  host.frame = window.contentView?.bounds ?? .zero
  window.contentView?.addSubview(host)
  window.layoutIfNeeded()
  // 真实 Ghostty surface 的 PTY 会上报带余数的像素尺寸；桥必须能通过 surface.subscribe。
  for _ in 0..<250 where session.lifecycleState != .running {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(session.lifecycleState == .running, "真实 surface 下显示桥必须附着成功")

  // —— 人为杀掉显示桥进程（模拟桥崩溃，而不是用户主动分离） ——
  var bridgePID: Int32?
  for _ in 0..<100 where bridgePID == nil {
    bridgePID = bridgeProcessIdentifier(terminalID: created.reference.terminalID)
    if bridgePID == nil { try await Task.sleep(for: .milliseconds(50)) }
  }
  let killed = try #require(bridgePID, "找不到显示桥进程")
  #expect(killed != managedPID, "只允许杀桥进程，绝不能杀受管进程")
  kill(killed, SIGKILL)
  for _ in 0..<250 where session.lifecycleState != .detached {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(session.lifecycleState == .detached, "桥崩溃后必须按服务端真实状态进入分离态")
  #expect(processAlive(managedPID), "桥崩溃不得影响受管进程")

  // —— 桥已死，但 session.detach / session.end 仍必须可用 ——
  let before = try lineCount(of: outputFile)
  let detach = await dispatcher.handle(
    controlRequest("session.detach", ["pane": "w1:p1"]), client: client)
  #expect(detach.error == nil, "桥退出不得让 detach 被判成「终端进程已退出」：\(String(describing: detach.error))")
  #expect(detach.result?["disposition"]?.stringValue == "detached")
  try await Task.sleep(for: .seconds(1))
  #expect(processAlive(managedPID), "detach 之后受管进程仍须存活")
  #expect(try lineCount(of: outputFile) > before, "detach 之后任务必须继续产出")

  let end = await dispatcher.handle(
    controlRequest("session.end", ["pane": "w1:p1"]), client: client)
  #expect(end.error == nil, "桥退出不得让 end 被判成「终端进程已退出」：\(String(describing: end.error))")
  #expect(end.result?["disposition"]?.stringValue == "terminated")
  for _ in 0..<100 where processAlive(managedPID) {
    try await Task.sleep(for: .milliseconds(50))
  }
  #expect(!processAlive(managedPID), "显式结束后受管进程必须退出")
}
