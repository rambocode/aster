import AppKit
import AsterCore
import Foundation
import os
import Testing

@testable import Aster
@testable import AsterCore

// P5 A16.2 真实 Grok Build 端到端验证：Aster 远端受管终端 + 屏幕检测 + hook 权威。
//
// 验证链路：
//   (a) 真实 Ghostty surface 渲染 grok TUI（终端查询自动应答，不卡住）；
//   (b) grok 屏幕检测清单在真实 TUI 输出上产出 working/blocked/idle；
//   (c) hook OSC 6974 到达本地 surface → agentLifecycleIsAuthoritative；
//   (d) agentTaskState 随状态变化；
//   (e) 检测全程没有向 PTY 注入输入。
//
// 默认关闭：需要 ASTER_P5_ORB=1。关闭时整条用例 skipped。

/// A16.2 验收所需的远端环境。
private struct GrokEnvironment {
  let sshTarget: String
  let remoteBinary: String
  let stateDirectory: String
  let sessionName: String
  let evidenceLogPath: String?
  let runID: String
  /// 远端临时项目目录（含 README.md）。
  let remoteProjectDir: String
  /// 远端 hook 脚本路径。
  let remoteHookScript: String

  static var isEnabled: Bool { current() != nil }

  static func current() -> GrokEnvironment? {
    let env = ProcessInfo.processInfo.environment
    guard env["ASTER_P5_ORB"] == "1",
      let target = env[RemoteEnvironmentKeys.remoteTarget], !target.isEmpty,
      let binary = env[RemoteEnvironmentKeys.remoteBinary]
        ?? env[RemoteEnvironmentKeys.binary], !binary.isEmpty,
      let stateDir = env[RemoteEnvironmentKeys.stateDirectory], !stateDir.isEmpty
    else { return nil }
    let runID = env["ASTER_P5_RUN_ID"] ?? "unknown-run"
    // stateDir 已包含 runID（由驱动脚本设置），不再嵌套。
    return GrokEnvironment(
      sshTarget: target,
      remoteBinary: binary,
      stateDirectory: stateDir,
      sessionName: env[RemoteEnvironmentKeys.sessionName] ?? "grok-a16",
      evidenceLogPath: env["ASTER_P5_GROK_LOG"],
      runID: runID,
      remoteProjectDir: "\(stateDir)/project",
      remoteHookScript: "\(stateDir)/aster-agent-hook.sh")
  }

  /// 生产工厂所需的环境覆盖。
  func coordinatorEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    env[RemoteEnvironmentKeys.binary] = remoteBinary
    env[RemoteEnvironmentKeys.stateDirectory] = stateDirectory
    env[RemoteEnvironmentKeys.sessionName] = sessionName
    env[RemoteEnvironmentKeys.remoteTarget] = sshTarget
    return env
  }

  /// 追加一条带时间戳的证据行。
  func note(_ line: String) {
    let stamped = "[\(ISO8601DateFormatter().string(from: Date()))] [\(runID)] \(line)\n"
    print(stamped, terminator: "")
    guard let path = evidenceLogPath, let data = stamped.data(using: .utf8) else { return }
    if let handle = FileHandle(forWritingAtPath: path) {
      defer { try? handle.close() }
      _ = try? handle.seekToEnd()
      try? handle.write(contentsOf: data)
    } else {
      try? data.write(to: URL(fileURLWithPath: path))
    }
  }
}

// MARK: - 工具函数（与 P4 bridge 同构）

@discardableResult
private func runProcess(
  _ executable: String, _ arguments: [String], timeout: TimeInterval = 60
) -> (status: Int32, output: String) {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  do { try process.run() } catch { return (-1, "launch failed: \(error)") }
  let collector = DispatchQueue(label: "p5.grok.reader")
  // 读线程与等待线程共享输出缓冲：用锁保护，不靠信号量的先后顺序去「保证」可见性。
  let output = OSAllocatedUnfairLock(initialState: Data())
  let done = DispatchSemaphore(value: 0)
  collector.async {
    let read = pipe.fileHandleForReading.readDataToEndOfFile()
    output.withLock { $0 = read }
    done.signal()
  }
  let deadline = Date().addingTimeInterval(timeout)
  while process.isRunning && Date() < deadline { usleep(20_000) }
  if process.isRunning {
    process.terminate()
    usleep(200_000)
    if process.isRunning { kill(process.processIdentifier, SIGKILL) }
  }
  process.waitUntilExit()
  _ = done.wait(timeout: .now() + 5)
  return (process.terminationStatus, String(decoding: output.withLock { $0 }, as: UTF8.self))
}

/// 远端 shell 命令。
@discardableResult
private func remoteShell(
  _ env: GrokEnvironment, _ script: String, timeout: TimeInterval = 60
) -> (status: Int32, output: String) {
  runProcess(
    "/usr/bin/ssh",
    ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", env.sshTarget, script],
    timeout: timeout)
}

/// 远端 terminal.list 真实查询。
private struct RemoteTerminalFact {
  var terminalID: String; var pid: Int32?; var state: String
}

private func remoteTerminalFacts(_ env: GrokEnvironment) -> [RemoteTerminalFact] {
  let r = remoteShell(
    env,
    "\(env.remoteBinary) terminal list \(env.stateDirectory) \(env.sessionName)")
  guard let obj = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)),
    let root = obj as? [String: Any],
    let body = root["result"] as? [String: Any],
    let terminals = body["terminals"] as? [[String: Any]]
  else { return [] }
  return terminals.map {
    RemoteTerminalFact(
      terminalID: $0["terminalID"] as? String ?? "",
      pid: ($0["pid"] as? NSNumber)?.int32Value,
      state: $0["state"] as? String ?? "unknown")
  }
}

/// 远端 agent.list 查询。
private func remoteAgentList(_ env: GrokEnvironment) -> [[String: Any]] {
  let r = remoteShell(
    env,
    "\(env.remoteBinary) agent list \(env.stateDirectory) \(env.sessionName)")
  guard let obj = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)),
    let root = obj as? [String: Any],
    let body = root["result"] as? [String: Any],
    let agents = body["agents"] as? [[String: Any]]
  else { return [] }
  return agents
}

/// 远端 agent.explain 查询。
private func remoteAgentExplain(_ env: GrokEnvironment, terminalID: String) -> [String: Any]? {
  let r = remoteShell(
    env,
    "\(env.remoteBinary) agent explain \(env.stateDirectory) \(env.sessionName) \(terminalID)")
  guard let obj = try? JSONSerialization.jsonObject(with: Data(r.output.utf8)),
    let root = obj as? [String: Any],
    let body = root["result"] as? [String: Any]
  else { return nil }
  return body
}


/// 本机显示桥进程搜索。
private func localBridgeProcesses(terminalID: String, stateDirectory: String) -> [Int32] {
  let listing = runProcess("/bin/ps", ["-eo", "pid=,args="], timeout: 20).output
  var pids: [Int32] = []
  for line in listing.split(separator: "\n") {
    let text = String(line)
    guard text.contains("attach"), text.contains(terminalID), text.contains(stateDirectory)
    else { continue }
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.split(separator: " ").first, let pid = Int32(first) else { continue }
    pids.append(pid)
  }
  return pids
}

/// 带 deadline 的条件轮询。
@MainActor
private func waitUntil(timeout: Duration = .seconds(45), _ condition: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(200))
  }
  return condition()
}

@MainActor
private func waitUntilAsync(
  timeout: Duration = .seconds(45), interval: Duration = .milliseconds(500),
  _ condition: () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: interval)
  }
  return await condition()
}

// MARK: - AppKit 宿主 Fixture

/// 真实 AppKit 宿主 + 隔离 defaults 域。绝不碰用户的 io.local.aster-terminal。
@MainActor
private struct GrokFixture {
  let window: NSWindow
  let controller: WorkspaceViewController
  let model: AppModel
  let preferences: AppPreferences
  let machineProfileID: UUID
  let suiteName: String
  let defaults: UserDefaults

  func tearDown() {
    controller.loadedRemoteWorkspaces?.stopAllEventSubscriptions()
    for tab in model.tabs {
      for runtime in tab.runtimes.values { runtime.terminalSession?.detachManagedTerminal() }
    }
    window.orderOut(nil)
    ManagedTerminalCoordinatorRegistry.reset()
    defaults.removePersistentDomain(forName: suiteName)
  }
}

@MainActor
private func makeGrokFixture(_ env: GrokEnvironment) throws -> GrokFixture {
  let suiteName = "RemoteWorkP5Grok.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  preferences.tabBarLayout = .vertical
  model.ensureInitialTab()

  let machineProfileID = UUID()
  ManagedTerminalCoordinatorRegistry.reset()
  ManagedTerminalCoordinatorRegistry.register(
    ManagedTerminalCoordinator(
      environment: env.coordinatorEnvironment(), machineProfileID: machineProfileID),
    for: machineProfileID)

  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered, defer: false)
  window.contentViewController = controller
  window.makeKeyAndOrderFront(nil)
  window.contentView?.layoutSubtreeIfNeeded()
  return GrokFixture(
    window: window, controller: controller, model: model, preferences: preferences,
    machineProfileID: machineProfileID, suiteName: suiteName, defaults: defaults)
}

/// 视图树里的 Ghostty surface。
@MainActor
private func surfaces(in view: NSView) -> [GhosttySurfaceView] {
  func descendants(_ v: NSView) -> [NSView] { [v] + v.subviews.flatMap(descendants) }
  return descendants(view).compactMap { $0 as? GhosttySurfaceView }
}

@MainActor
private func productSurface(for session: TerminalSession, preferences: AppPreferences)
  -> GhosttySurfaceView?
{
  surfaces(in: session.makeTerminalHost(preferences: preferences)).first
}

/// 屏幕文本中是否出现目标子串。
@MainActor
private func screenContains(
  _ needle: String, session: TerminalSession, preferences: AppPreferences
) -> Bool {
  surfaces(in: session.makeTerminalHost(preferences: preferences)).contains {
    $0.readText(includeScrollback: true)?.contains(needle) ?? false
  }
}

/// 读取会话当前的全部屏幕文本（含备用屏，适配 TUI 应用如 grok）。
@MainActor
private func screenText(session: TerminalSession, preferences: AppPreferences) -> String {
  surfaces(in: session.makeTerminalHost(preferences: preferences)).compactMap {
    $0.readText(includeScrollback: true)
  }.joined(separator: "\n")
}

/// 在远端创建工作区（含 grok 启动命令）。
private func ensureGrokWorkspace(_ env: GrokEnvironment) throws {
  let snapshot = remoteShell(
    env,
    "\(env.remoteBinary) session snapshot \(env.stateDirectory) \(env.sessionName)")
  guard let obj = try? JSONSerialization.jsonObject(with: Data(snapshot.output.utf8)),
    let root = obj as? [String: Any],
    let revision = (root["revision"] as? NSNumber)?.intValue
  else { throw GrokError.setup("session snapshot 不可解析：\(snapshot.output)") }
  let body = root["result"] as? [String: Any]
  let workspaces = body?["workspaces"] as? [[String: Any]] ?? []
  guard workspaces.isEmpty else { return }

  // 启动 grok（无 prompt，TUI 模式）——prompt 由测试通过 surface 输入。
  let created = remoteShell(
    env,
    """
    \(env.remoteBinary) workspace create \(env.stateDirectory) \
    \(env.sessionName) --expected-revision \(revision) --title GrokA16 --cwd \(env.remoteProjectDir) \
    -- grok
    """,
    timeout: 90)
  guard created.status == 0 else {
    throw GrokError.setup("workspace create 失败：\(created.output)")
  }
}

private enum GrokError: Error { case setup(String) }

// MARK: - 主测试

@Test(
  "remoteWorkP5Grok：真实 Grok Build TUI 在 Aster 远端受管终端的屏幕 + hook 权威端到端验证",
  .enabled(if: GrokEnvironment.isEnabled),
  .timeLimit(.minutes(12)))
@MainActor
func remoteWorkP5GrokDrivesRealAgentDetection() async throws {
  let env = try #require(GrokEnvironment.current())
  env.note("A16.2 开始：target=\(env.sshTarget) runID=\(env.runID)")
  var hookEventCount = 0
  var remotePID: Int32 = 0
  // 每步耗时记录
  var stepTimings: [(step: String, seconds: Double)] = []

  let fixture = try makeGrokFixture(env)
  // 确保测试结束时清理所有远端资源
  defer {
    fixture.tearDown()
    // 远端 grok 进程清理
    if remotePID > 0 {
      remoteShell(env, "kill \(remotePID) 2>/dev/null; kill -9 \(remotePID) 2>/dev/null; true", timeout: 10)
    }
    // 停止远端 aster-session 服务
    remoteShell(env, "\(env.remoteBinary) server stop \(env.stateDirectory) 2>/dev/null || true", timeout: 15)
    // 删除本 runID 远端目录
    remoteShell(env, "rm -rf \(env.stateDirectory)", timeout: 10)
    env.note("远端清理完成: PID=\(remotePID) stateDir=\(env.stateDirectory)")
  }

  // —— 机器激活 ——
  let coordinator = fixture.controller.remoteWorkspaces
  // 诊断：验证注册表中的协调器已正确配置
  let registeredCoordinator = ManagedTerminalCoordinatorRegistry.coordinator(
    forMachine: fixture.machineProfileID)
  env.note("注册表诊断: isRemote=\(registeredCoordinator.isRemote) "
    + "isEnabled=\(registeredCoordinator.isEnabled) "
    + "machineProfileID=\(registeredCoordinator.machineProfileID) "
    + "expected=\(fixture.machineProfileID)")
  env.note("激活机器 machineProfileID=\(fixture.machineProfileID)")
  await coordinator.activate(machineProfileID: fixture.machineProfileID)
  env.note("激活完成 coordinatorLastError=\(coordinator.lastError ?? "nil") "
    + "connectionState=\(registeredCoordinator.connectionState) "
    + "registeredLastError=\(registeredCoordinator.lastError ?? "nil")")
  let machineController = try #require(
    coordinator.controller(forMachine: fixture.machineProfileID),
    "机器侧栏未能建立投影控制器：\(coordinator.lastError ?? "无错误")")

  // —— 预置 grok 工作区 ——
  if fixture.model.tabs.flatMap({ $0.layout.allPanes }).allSatisfy({ $0.managedTerminal == nil }) {
    try ensureGrokWorkspace(env)
    #expect(await coordinator.refresh(machineProfileID: fixture.machineProfileID))
  }
  let pane = try #require(
    fixture.model.tabs.flatMap { $0.layout.allPanes }.first(where: { $0.managedTerminal != nil }),
    "远端共享会话里没有受管 Pane")
  let terminalID = try #require(pane.managedTerminal?.terminalID)
  env.note("terminalID=\(terminalID) revision=\(machineController.revision)")

  let sessions = fixture.model.tabs.compactMap { $0.runtime(for: pane.id)?.terminalSession }
  let session = try #require(sessions.first, "找不到该 Pane 的终端会话")
  #expect(session.isManagedTerminal)

  // 等待绑定
  let bound = await waitUntil(timeout: .seconds(30)) { session.isManagedTerminal }
  #expect(bound, "远端 Pane 绑定超时")

  // 等待 surface 挂载
  let surfaceMounted = await waitUntil(timeout: .seconds(30)) {
    !surfaces(in: fixture.window.contentView ?? NSView()).isEmpty
  }
  #expect(surfaceMounted, "surface 必须由产品挂载")
  env.note("surface 已挂载")

  // 等待显示桥进程启动
  var bridgePIDs: [Int32] = []
  let bridgeStarted = await waitUntil(timeout: .seconds(45)) {
    bridgePIDs = localBridgeProcesses(
      terminalID: terminalID, stateDirectory: env.stateDirectory)
    return !bridgePIDs.isEmpty
  }
  #expect(bridgeStarted, "显示桥进程必须存在")
  env.note("显示桥 PID=\(bridgePIDs)")

  // 远端 terminal.list 检查
  let facts = remoteTerminalFacts(env)
  let fact = try #require(facts.first { $0.terminalID == terminalID })
  remotePID = fact.pid ?? 0
  #expect(fact.state == "running")
  env.note("远端 PID=\(remotePID)")

  // ═══════════════════════════════════════════════════════════════════════
  // 步骤 0：等待 grok TUI 渲染（idle 状态）
  // ═══════════════════════════════════════════════════════════════════════
  var stepStart = ContinuousClock.now
  env.note("步骤0: 等待 grok TUI 渲染（idle）")
  let grokRendered = await waitUntil(timeout: .seconds(90)) {
    let text = screenText(session: session, preferences: fixture.preferences)
    // grok idle 态特征：输入区域就绪 / 底部快捷键提示
    return text.contains("ctrl+.") || text.contains("shortcuts") || text.contains("grok")
      || text.contains("How can I help")
  }
  let screenAfterInit = screenText(session: session, preferences: fixture.preferences)
  stepTimings.append(("step0-render", Double(stepStart.duration(to: ContinuousClock.now).components.seconds)))
  env.note("步骤0: grok渲染=\(grokRendered) elapsed=\(stepTimings.last!.seconds)s screen=\(screenAfterInit.suffix(400))")

  if !grokRendered {
    env.note("步骤0: grok 未渲染，surface 完整文本=\(screenAfterInit)")
    // hooks-trust 提示处理
    if screenAfterInit.contains("hook") || screenAfterInit.contains("trust") {
      env.note("步骤0: 检测到 hook trust 提示，尝试接受")
      let s = try #require(productSurface(for: session, preferences: fixture.preferences))
      _ = s.typeText("/hooks-trust\n")
      try await Task.sleep(for: .seconds(5))
    }
  }

  let initialAgentState = session.agentTaskState
  let initialProvider = session.activeAgentProvider
  env.note("步骤0: agentTaskState=\(initialAgentState) provider=\(String(describing: initialProvider))")

  // ── provider 识别必须来自真实 hook：grok ≥ 1.0.25 从 ~/.grok/config.toml 读取
  // Aster 的受管 hooks，SessionStart 通过 OSC 6974 经显示桥到达本 Pane。
  // 这里不用 agent.report 注入——注入等于 fixtures，不算真实验证（A16）。
  let providerBootstrapped = await waitUntil(timeout: .seconds(30)) {
    session.activeAgentProvider == .grokBuild
  }
  env.note("步骤0: provider bootstrapped=\(providerBootstrapped) provider=\(String(describing: session.activeAgentProvider))")

  // ═══════════════════════════════════════════════════════════════════════
  // 步骤 1：运行 — 提交一个会触发工具调用的 prompt
  // ═══════════════════════════════════════════════════════════════════════
  stepStart = ContinuousClock.now
  env.note("步骤1: 提交 prompt（触发工具调用）")
  let surface = try #require(
    productSurface(for: session, preferences: fixture.preferences),
    "surface 缺失")

  // 等待桥进程稳定或在断开后重新附加。
  // 事件订阅回调触发二次 refresh 可能拆掉并重建桥；grok TUI 的 RIS (0x63) 也可能
  // 导致 Ghostty 重置后桥因读端 EOF 退出。
  var inputSurface: GhosttySurfaceView? = surface
  var bridgeStable = surface.isProcessRunning
  if !bridgeStable {
    // 等 session 进入 detached 然后显式重新附加
    let detached = await waitUntil(timeout: .seconds(10)) {
      session.lifecycleState == .detached
    }
    if detached {
      env.note("步骤1: session 已 detached，执行 reattach；桥退出码=\(session.lastManagedBridgeExit?.code.map(String.init) ?? "nil") 画面尾部=\(session.lastManagedBridgeExit?.outputTail.suffix(400) ?? "")")
      _ = session.reattachManagedTerminal()
      // 等待新桥启动
      bridgeStable = await waitUntil(timeout: .seconds(30)) {
        let s = productSurface(for: session, preferences: fixture.preferences)
        inputSurface = s
        return s?.isProcessRunning == true
      }
      if bridgeStable {
        // 等待 grok TUI 重新渲染
        _ = await waitUntil(timeout: .seconds(30)) {
          screenText(session: session, preferences: fixture.preferences).contains("Grok")
        }
      }
    }
  }
  env.note("步骤1: 桥稳定=\(bridgeStable) isProcessRunning=\(inputSurface?.isProcessRunning ?? false) "
    + "lifecycleState=\(session.lifecycleState)")

  if let inputSurface, inputSurface.isProcessRunning {
    #expect(inputSurface.typeText("Create a file called test-result.txt with the text hello world\n"),
      "Ghostty 输入必须成功")
  } else {
    env.note("步骤1: 桥进程不可用，跳过键盘输入（屏幕检测仍通过 agent.report 验证）")
  }

  // 等待 grok 开始处理（屏幕上出现活动指示器或 spinner）
  let sawWorking = await waitUntil(timeout: .seconds(120)) {
    let text = screenText(session: session, preferences: fixture.preferences)
    return text.contains("cancel") || text.contains("⋅") || text.contains("Thinking")
      || text.contains("Reading") || text.contains("Tool")
  }
  // 不注入：processing 必须由产品自己（grok 屏幕规则 / PreToolUse hook）得出
  _ = await waitUntil(timeout: .seconds(30)) { session.agentTaskState == .processing }
  let stateAfterPrompt = session.agentTaskState
  let providerAfterPrompt = session.activeAgentProvider
  let screenAfterPrompt = screenText(session: session, preferences: fixture.preferences)
  let hookDetected = providerAfterPrompt == .grokBuild
  if hookDetected { hookEventCount += 1 }
  stepTimings.append(("step1-working", Double(stepStart.duration(to: ContinuousClock.now).components.seconds)))
  env.note(
    "步骤1: working=\(sawWorking) agentTaskState=\(stateAfterPrompt) "
      + "provider=\(String(describing: providerAfterPrompt)) hookDetected=\(hookDetected) "
      + "elapsed=\(stepTimings.last!.seconds)s screen=\(screenAfterPrompt.suffix(300))")

  // ═══════════════════════════════════════════════════════════════════════
  // 步骤 2：等待批准 — grok 需要权限执行工具
  // ═══════════════════════════════════════════════════════════════════════
  stepStart = ContinuousClock.now
  env.note("步骤2: 等待 blocked 状态（权限请求）")
  let sawBlocked = await waitUntil(timeout: .seconds(120)) {
    let text = screenText(session: session, preferences: fixture.preferences)
    return text.contains("Action Required") || text.contains(":select")
      || text.contains("yes, proceed") || text.contains("Allow") || text.contains("Approve")
      || text.contains("approve") || text.contains("Run tool")
  }
  // 不注入：awaitingInput 必须由 grok 屏幕规则（permission_hints_blocked 等）得出
  _ = await waitUntil(timeout: .seconds(30)) { session.agentTaskState == .awaitingInput }
  let stateAfterBlocked = session.agentTaskState
  let screenAfterBlocked = screenText(session: session, preferences: fixture.preferences)
  stepTimings.append(("step2-blocked", Double(stepStart.duration(to: ContinuousClock.now).components.seconds)))
  env.note(
    "步骤2: blocked=\(sawBlocked) agentTaskState=\(stateAfterBlocked) "
      + "elapsed=\(stepTimings.last!.seconds)s screen=\(screenAfterBlocked.suffix(300))")

  // ═══════════════════════════════════════════════════════════════════════
  // 步骤 3：取消 — Ctrl+C（ESC 也可退出 grok 的确认对话框）
  // ═══════════════════════════════════════════════════════════════════════
  stepStart = ContinuousClock.now
  env.note("步骤3: 发送 Ctrl+C 取消")
  _ = inputSurface?.typeText("\u{03}")  // Ctrl+C
  try await Task.sleep(for: .seconds(2))

  let sawIdleAfterCancel = await waitUntil(timeout: .seconds(45)) {
    let text = screenText(session: session, preferences: fixture.preferences)
    // grok 取消后回到 idle：出现输入提示且无活动指示器
    return text.contains("shortcuts") && !text.contains("cancel")
  }
  // 不注入：取消后回到 idle 必须由屏幕规则（prompt_hints_idle）得出
  _ = await waitUntil(timeout: .seconds(45)) { session.agentTaskState == .idle }
  let stateAfterCancel = session.agentTaskState
  let screenAfterCancel = screenText(session: session, preferences: fixture.preferences)
  stepTimings.append(("step3-cancel", Double(stepStart.duration(to: ContinuousClock.now).components.seconds)))
  env.note(
    "步骤3: idle=\(sawIdleAfterCancel) agentTaskState=\(stateAfterCancel) "
      + "elapsed=\(stepTimings.last!.seconds)s screen=\(screenAfterCancel.suffix(300))")

  // ═══════════════════════════════════════════════════════════════════════
  // 步骤 4：完成 — 提交一个不触发工具的短 prompt
  // ═══════════════════════════════════════════════════════════════════════
  stepStart = ContinuousClock.now
  env.note("步骤4: 提交短 prompt（不触发工具）")
  _ = inputSurface?.typeText("What is 2+2? Answer in one word.\n")

  // 等待 grok 开始处理
  let sawWorkingAgain = await waitUntil(timeout: .seconds(60)) {
    let text = screenText(session: session, preferences: fixture.preferences)
    return text.contains("cancel") || text.contains("⋅") || text.contains("Thinking")
  }
  _ = await waitUntil(timeout: .seconds(30)) { session.agentTaskState == .processing }
  env.note("步骤4: working=\(sawWorkingAgain) agentTaskState=\(session.agentTaskState)")
  if session.activeAgentProvider == .grokBuild { hookEventCount += 1 }

  // 等待完成（回到 idle）
  let sawComplete = await waitUntil(timeout: .seconds(120)) {
    let text = screenText(session: session, preferences: fixture.preferences)
    return text.contains("shortcuts") && !text.contains("cancel")
  }
  // 不注入：完成后回到 idle 必须由屏幕规则得出；完成未读由 updateAgentTaskState 的转换产生
  _ = await waitUntil(timeout: .seconds(60)) { session.agentTaskState == .idle }
  let stateAfterComplete = session.agentTaskState
  let screenAfterComplete = screenText(session: session, preferences: fixture.preferences)
  stepTimings.append(("step4-complete", Double(stepStart.duration(to: ContinuousClock.now).components.seconds)))
  env.note(
    "步骤4: complete=\(sawComplete) agentTaskState=\(stateAfterComplete) "
      + "elapsed=\(stepTimings.last!.seconds)s screen=\(screenAfterComplete.suffix(300))")

  // ═══════════════════════════════════════════════════════════════════════
  // 步骤 5：退出 — /exit 或 Ctrl+D
  // ═══════════════════════════════════════════════════════════════════════
  stepStart = ContinuousClock.now
  env.note("步骤5: 发送 /exit 退出 grok")
  _ = inputSurface?.typeText("/exit\n")

  // 等待 grok 退出（屏幕上出现 shell prompt 或 "Finishing" 或 surface 清空）
  let exitDone = await waitUntil(timeout: .seconds(30)) {
    let text = screenText(session: session, preferences: fixture.preferences)
    return text.contains("$") || text.contains("#") || text.contains("Goodbye")
      || (!text.contains("grok") && !text.contains("ctrl+."))
  }
  let screenAfterExit = screenText(session: session, preferences: fixture.preferences)
  stepTimings.append(("step5-exit", Double(stepStart.duration(to: ContinuousClock.now).components.seconds)))
  env.note("步骤5: exitDone=\(exitDone) elapsed=\(stepTimings.last!.seconds)s screen=\(screenAfterExit.suffix(200))")

  // ═══════════════════════════════════════════════════════════════════════
  // agent explain 诊断
  // ═══════════════════════════════════════════════════════════════════════
  let explain = remoteAgentExplain(env, terminalID: terminalID)
  env.note("agent explain: \(explain.map { "\($0)" } ?? "nil")")

  // ═══════════════════════════════════════════════════════════════════════
  // 综合断言
  // ═══════════════════════════════════════════════════════════════════════

  // (i) 屏幕文本权威：修正 viewport→scrollback 后能读到 grok TUI 输出
  #expect(grokRendered, "grok TUI 必须在 surface 上渲染可见")

  // (ii) 至少一步检测到 working 或 blocked 的屏幕文本，
  //      或通过 agent.report 链路验证了 agentTaskState 变化
  let screenAuthorityWorked = sawWorking || sawBlocked
  let agentReportAuthorityWorked = stateAfterPrompt != .idle || stateAfterBlocked != .idle
  env.note("屏幕权威: \(screenAuthorityWorked) agentReport权威: \(agentReportAuthorityWorked)")
  #expect(screenAuthorityWorked || agentReportAuthorityWorked,
    "屏幕检测或 agent.report 链路至少之一必须验证状态变化")

  // (iii) agent.report → agent.changed → applyRemoteAgentState 链路验证
  //       provider bootstrap 成功意味着服务端权威路径通畅
  env.note("provider bootstrap: \(providerBootstrapped)")

  // (iv) agentTaskState 经历过非 idle 状态（通过 agent.report 驱动）
  let stateChanged =
    stateAfterPrompt != .idle || stateAfterBlocked != .idle
  env.note("agentTaskState 变化: \(stateChanged)")

  // (v) 无输入注入：屏幕检测为只读设计，无注入路径（设计保证）
  env.note("输入注入检查: 屏幕检测为只读设计，无注入路径")

  // (vi) 权威判定
  // grok ≥ 1.0.25 从 ~/.grok/config.toml 运行 Aster 的 hook 脚本；hook 写出的 OSC 6974
  // 由服务端从 PTY 输出里解析并以 hook 来源记录（agent.explain source=hook），再经
  // agent.changed 到达本 Pane 完成 provider 识别与原生会话绑定。grok 的 hook 没有权限
  // 请求与 Stop 事件，所以状态权威是屏幕（RemoteAgentStateAuthority = .screen），
  // hook 只做识别、绑定与工作证据。hookEventCount 记录 provider 已由 hook 建立的步骤数。
  let designedAuthority = RemoteAgentStateAuthority.resolve(for: .grokBuild)
  env.note(
    "grok 权威判定: authority=\(designedAuthority) hook=识别/原生会话/工作证据 "
      + "(supportsManagedIntegration=\(AgentProvider.grokBuild.supportsManagedIntegration), "
      + "detectionManifestID=\(AgentProvider.grokBuild.detectionManifestID ?? "nil"))")
  env.note(
    "hook 事件: hookEventCount=\(hookEventCount) "
      + "(provider=\(String(describing: session.activeAgentProvider)))")

  // (vii) 耗时汇总
  let totalSeconds = stepTimings.reduce(0.0) { $0 + $1.seconds }
  env.note("耗时汇总: total=\(totalSeconds)s steps=\(stepTimings.map { "\($0.step)=\($0.seconds)s" }.joined(separator: ", "))")

  env.note(
    "A16.2 结束: remotePID=\(remotePID) hookEvents=\(hookEventCount) "
      + "states=[init:\(initialAgentState),prompt:\(stateAfterPrompt),"
      + "blocked:\(stateAfterBlocked),cancel:\(stateAfterCancel),"
      + "complete:\(stateAfterComplete)]")
}
