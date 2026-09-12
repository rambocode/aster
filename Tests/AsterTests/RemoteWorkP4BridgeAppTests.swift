import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// P4 §6.8 的闭环用例：**真实 App → ssh → 远端受管终端**的显示桥完整链路。
//
// 与 `RemoteWorkP4MachineAppTests` 的分工：那批用例证明「结构投影与事务」是真的，
// 但它们断言的是 `interest.visibleSurfaces` / `allowsInput` 这类闸门状态，显示桥进程
// （`ssh -tt … terminal attach`）在那批用例里**从未启动过**（用 ps 高频采样实测确认）。
// 本用例专门驱动显示桥本身，判定标准全部是进程级与字节级证据：
//   (a) 本机确实存在 `ssh … terminal attach <terminalID>` 进程且持续存活；
//   (b) 远端 `terminal.list` 该终端 running 且 PID 存在；
//   (c) 远端产生的字节出现在**真实 Ghostty surface** 的屏幕文本里；
//   (d) 从真实 Ghostty 输入路径打进去的一行命令，在远端文件里留下内容；
//   (e) 分离后桥进程退出、远端 PID 不变，重新附加后再次可见。
//
// 默认关闭：需要 `ASTER_P4_ORB=1` 与全部远端环境变量。关闭时整条用例记 skipped，
// 绝不用替身冒充真实链路。

/// 显示桥验收所需的环境。任一项缺失即视为「未开启」。
private struct RemoteWorkP4BridgeEnvironment {
  let sshTarget: String
  let remoteBinary: String
  let stateDirectory: String
  let sessionName: String
  /// 证据日志路径（本机）。缺省时不写盘，只在测试输出里体现。
  let evidenceLogPath: String?
  /// 本次运行的标识，写进日志与远端 marker，便于按 runID 清理。
  let runID: String

  static var isEnabled: Bool { current() != nil }

  static func current() -> RemoteWorkP4BridgeEnvironment? {
    let environment = ProcessInfo.processInfo.environment
    guard environment["ASTER_P4_ORB"] == "1",
      let sshTarget = environment[RemoteEnvironmentKeys.remoteTarget], !sshTarget.isEmpty,
      let remoteBinary = environment[RemoteEnvironmentKeys.remoteBinary]
        ?? environment[RemoteEnvironmentKeys.binary], !remoteBinary.isEmpty,
      let stateDirectory = environment[RemoteEnvironmentKeys.stateDirectory],
      !stateDirectory.isEmpty
    else { return nil }
    return RemoteWorkP4BridgeEnvironment(
      sshTarget: sshTarget,
      remoteBinary: remoteBinary,
      stateDirectory: stateDirectory,
      sessionName: environment[RemoteEnvironmentKeys.sessionName] ?? "bridge",
      evidenceLogPath: environment["ASTER_P4_BRIDGE_LOG"],
      runID: environment["ASTER_P4_RUN_ID"] ?? "unknown-run")
  }

  /// 生产工厂用的那份「只覆盖运行时四个键」的环境；测试不另造一套语义。
  func coordinatorEnvironment() -> [String: String] {
    var environment = ProcessInfo.processInfo.environment
    environment[RemoteEnvironmentKeys.binary] = remoteBinary
    environment[RemoteEnvironmentKeys.stateDirectory] = stateDirectory
    environment[RemoteEnvironmentKeys.sessionName] = sessionName
    environment[RemoteEnvironmentKeys.remoteTarget] = sshTarget
    return environment
  }

  /// 追加一条证据行。日志是本用例唯一的持久产物，失败时也要留下已知事实。
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

/// 带硬超时的子进程执行。任何一次 SSH 往返都可能挂住，绝不允许无限等待。
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
  // 先在后台把管道读空再等退出：输出超过管道缓冲时 waitUntilExit 会死锁。
  let collector = DispatchQueue(label: "p4.bridge.reader")
  var data = Data()
  let done = DispatchSemaphore(value: 0)
  collector.async {
    data = pipe.fileHandleForReading.readDataToEndOfFile()
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
  return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

/// 在远端跑一段 POSIX sh。所有远端副作用都走这里，便于按 runID 复查。
@discardableResult
private func remoteShell(
  _ environment: RemoteWorkP4BridgeEnvironment, _ script: String, timeout: TimeInterval = 60
) -> (status: Int32, output: String) {
  runProcess(
    "/usr/bin/ssh",
    ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10", environment.sshTarget, script],
    timeout: timeout)
}

/// 远端受管终端的实测状态（`terminal.list` 的权威结果）。
private struct RemoteTerminalFact {
  var terminalID: String
  var pid: Int32?
  var state: String
}

/// 直接用 ssh 向真实服务端要 `terminal.list`，绕开被测代码自己的传输。
private func remoteTerminalFacts(_ environment: RemoteWorkP4BridgeEnvironment)
  -> [RemoteTerminalFact]
{
  let result = remoteShell(
    environment,
    "\(environment.remoteBinary) terminal list \(environment.stateDirectory) \(environment.sessionName)"
  )
  guard let object = try? JSONSerialization.jsonObject(with: Data(result.output.utf8)),
    let root = object as? [String: Any],
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

/// 本机进程表里属于本次运行的显示桥进程。
///
/// 判定用 terminalID + 本次 runID 的状态目录双重匹配：`ssh` 进程遍地都是，只按可执行
/// 文件名匹配会把用户自己的连接算进来，也会误杀。
private func localBridgeProcesses(terminalID: String, stateDirectory: String) -> [Int32] {
  let listing = runProcess("/bin/ps", ["-eo", "pid=,args="], timeout: 20).output
  var pids: [Int32] = []
  for line in listing.split(separator: "\n") {
    let text = String(line)
    // 桥的 argv 是逐参数加引号交给远端 shell 的（`'terminal' 'attach' …`），
    // 所以不能按 "terminal attach" 这个连写子串匹配；用 attach + terminalID + 本次
    // runID 的状态目录三重匹配，既不漏也不会误伤用户自己的 ssh。
    guard text.contains("attach"), text.contains(terminalID), text.contains(stateDirectory)
    else { continue }
    let trimmed = text.trimmingCharacters(in: .whitespaces)
    guard let first = trimmed.split(separator: " ").first, let pid = Int32(first) else { continue }
    pids.append(pid)
  }
  return pids
}

/// 进程是否仍存在（signal 0 探测）。
private func processAlive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

/// 轮询等待条件成立。真实链路是 SSH 往返，不能用固定 sleep 假装同步；一律带 deadline。
@MainActor
private func waitUntil(timeout: Duration = .seconds(45), _ condition: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(150))
  }
  return condition()
}

/// 异步条件版（远端查询要跑子进程，不能放在同步闭包里反复阻塞主线程太久）。
@MainActor
private func waitUntilAsync(
  timeout: Duration = .seconds(45), interval: Duration = .milliseconds(400),
  _ condition: () async -> Bool
) async -> Bool {
  let deadline = ContinuousClock.now + timeout
  while ContinuousClock.now < deadline {
    if await condition() { return true }
    try? await Task.sleep(for: interval)
  }
  return await condition()
}

/// 真实 AppKit 宿主 + 隔离 defaults 域。绝不碰用户的 io.local.aster-terminal。
@MainActor
private struct RemoteWorkP4BridgeFixture {
  let window: NSWindow
  let controller: WorkspaceViewController
  let model: AppModel
  let preferences: AppPreferences
  let machineProfileID: UUID
  let suiteName: String
  let defaults: UserDefaults

  func tearDown() {
    controller.loadedRemoteWorkspaces?.stopAllEventSubscriptions()
    // 远端受管终端一律按**分离**收尾：结束它们会杀掉真实远端进程。
    for tab in model.tabs {
      for runtime in tab.runtimes.values { runtime.terminalSession?.detachManagedTerminal() }
    }
    window.orderOut(nil)
    ManagedTerminalCoordinatorRegistry.reset()
    defaults.removePersistentDomain(forName: suiteName)
  }
}

@MainActor
private func makeBridgeFixture(_ environment: RemoteWorkP4BridgeEnvironment) throws
  -> RemoteWorkP4BridgeFixture
{
  let suiteName = "RemoteWorkP4Bridge.\(UUID().uuidString)"
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
      environment: environment.coordinatorEnvironment(), machineProfileID: machineProfileID),
    for: machineProfileID)

  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false)
  window.contentViewController = controller
  // 显示桥是 Ghostty surface 的子进程；surface 只有在真实挂进可见窗口后才会创建。
  // 这正是既有 P4 用例从未拉起过桥的原因：它们没有让窗口上屏。
  window.makeKeyAndOrderFront(nil)
  window.contentView?.layoutSubtreeIfNeeded()
  return RemoteWorkP4BridgeFixture(
    window: window, controller: controller, model: model, preferences: preferences,
    machineProfileID: machineProfileID, suiteName: suiteName, defaults: defaults)
}

/// 视图子树里的全部 Ghostty surface。
@MainActor
private func surfaces(in view: NSView) -> [GhosttySurfaceView] {
  func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
  return descendants(view).compactMap { $0 as? GhosttySurfaceView }
}

/// 取某个会话**产品路径上**的 Ghostty surface。
///
/// `makeTerminalHost` 就是 `WorkspaceViewController.makeTerminalPane` 用的同一个入口：
/// 已经建好时返回原容器，没建时才建——因此这里既不会绕过产品逻辑，也不会造出第二个桥。
@MainActor
private func productSurface(for session: TerminalSession, preferences: AppPreferences)
  -> GhosttySurfaceView?
{
  surfaces(in: session.makeTerminalHost(preferences: preferences)).first
}

/// 该会话**当前**屏幕文本里是否出现了某段文字。
///
/// 每次都重新取 surface 并遍历容器内全部 surface：重新附加会在同一个容器里换一个新的
/// Ghostty surface，旧的在退休期间可能还挂着；抓着第一次拿到的引用不放会读到已经没有
/// 字节流的那一个。
@MainActor
private func screenContains(
  _ needle: String, session: TerminalSession, preferences: AppPreferences
) -> Bool {
  surfaces(in: session.makeTerminalHost(preferences: preferences)).contains {
    $0.readText(includeScrollback: true)?.contains(needle) ?? false
  }
}

/// 确保远端共享会话里至少有一个可交互的受管终端。
///
/// 刻意让用例自己预置：P4 §6.3 记录的「用例依赖外部 CLI 预置结构」是取证前置条件，
/// 显示桥用例必须能独立跑，否则每次取证都要先手工造结构。
/// **必须在机器已激活之后调用**：服务实例由产品路径（`connectAsync` → `ensureServer`）
/// 拉起，这里只补结构，不代替产品去启动服务。
private func ensureInteractiveRemoteWorkspace(_ environment: RemoteWorkP4BridgeEnvironment) throws {
  let snapshot = remoteShell(
    environment,
    "\(environment.remoteBinary) session snapshot \(environment.stateDirectory) \(environment.sessionName)"
  )
  guard let object = try? JSONSerialization.jsonObject(with: Data(snapshot.output.utf8)),
    let root = object as? [String: Any],
    let revision = (root["revision"] as? NSNumber)?.intValue
  else { throw RemoteWorkP4BridgeError.setupFailed("session snapshot 不可解析：\(snapshot.output)") }
  let body = root["result"] as? [String: Any]
  let workspaces = body?["workspaces"] as? [[String: Any]] ?? []
  guard workspaces.isEmpty else { return }

  // argv 与产品路径同形：`/bin/sh -lc 'exec "${SHELL:-/bin/sh}" -l -i'`，
  // 保证这是一个真正的交互 Shell，能被键入并回显。
  let created = remoteShell(
    environment,
    """
    \(environment.remoteBinary) workspace create \(environment.stateDirectory) \
    \(environment.sessionName) --expected-revision \(revision) --title P4Bridge --cwd "$HOME" \
    -- /bin/sh -lc 'exec "${SHELL:-/bin/sh}" -l -i'
    """,
    timeout: 90)
  guard created.status == 0 else {
    throw RemoteWorkP4BridgeError.setupFailed("workspace create 失败：\(created.output)")
  }
}

private enum RemoteWorkP4BridgeError: Error { case setupFailed(String) }

@Test(
  "remoteWorkP4Bridge：真实 App → ssh → 远端受管终端的显示桥完整链路（双向字节 + 分离/重连）",
  .enabled(if: RemoteWorkP4BridgeEnvironment.isEnabled))
@MainActor
func remoteWorkP4BridgeDrivesRealDisplayBridgeEndToEnd() async throws {
  let environment = try #require(RemoteWorkP4BridgeEnvironment.current())
  environment.note("bridge e2e 开始：target=\(environment.sshTarget) state=\(environment.stateDirectory) session=\(environment.sessionName)")

  let fixture = try makeBridgeFixture(environment)
  defer { fixture.tearDown() }

  // —— 机器侧栏入口：选中这台机器 —— 与用户点侧栏走的是同一条路径。
  // 这一步同时完成真实握手与服务实例启动（`connectAsync` → `ensureServer`）。
  let coordinator = fixture.controller.remoteWorkspaces
  await coordinator.activate(machineProfileID: fixture.machineProfileID)
  let controller = try #require(
    coordinator.controller(forMachine: fixture.machineProfileID),
    "机器侧栏未能建立投影控制器：\(coordinator.lastError ?? "无错误")")
  // 服务已在跑但会话可能是空的：补一个交互 Shell 结构，再让界面重新取快照。
  if fixture.model.tabs.flatMap({ $0.layout.allPanes }).allSatisfy({ $0.managedTerminal == nil }) {
    try ensureInteractiveRemoteWorkspace(environment)
    #expect(await coordinator.refresh(machineProfileID: fixture.machineProfileID))
  }
  let pane = try #require(
    fixture.model.tabs.flatMap { $0.layout.allPanes }.first(where: { $0.managedTerminal != nil }),
    "远端共享会话里没有受管 Pane")
  let terminalID = try #require(pane.managedTerminal?.terminalID)
  environment.note("terminalID=\(terminalID) revision=\(controller.revision)")

  // 该 Pane 的真实终端会话。显示桥是**它的** surface 的子进程，不是窗口里随便哪一个。
  let sessions = fixture.model.tabs.compactMap { $0.runtime(for: pane.id)?.terminalSession }
  let session = try #require(sessions.first, "找不到该 Pane 的终端会话")
  #expect(session.isManagedTerminal, "该 Pane 必须绑定受管终端")

  // 绑定是异步的（`ManagedTerminalBinder` 要先向服务端对账）。必须等它完成再碰视图：
  // 在绑定之前调用 `makeTerminalHost` 会给这个远端 Pane 建一个**本机** Shell surface。
  let bound = await waitUntil(timeout: .seconds(30)) { session.isManagedTerminal }
  #expect(bound, "远端 Pane 的会话必须绑定受管终端，实测 lifecycle=\(session.lifecycleState)")

  // 视图树需要主线程往返：`WorkspaceViewController` 的刷新是合并到下一轮 runloop 的。
  // 这一步刻意**只观察**产品自己的视图树，不代它建 Pane——「产品真的挂了 surface」
  // 正是本用例要证明的东西。
  let mountedByProduct = await waitUntil(timeout: .seconds(30)) {
    !surfaces(in: fixture.window.contentView ?? NSView()).isEmpty
  }
  #expect(mountedByProduct, "真实窗口里必须由产品视图树挂载出 Ghostty surface")
  let paneSurface = try #require(
    productSurface(for: session, preferences: fixture.preferences), "该 Pane 必须有 surface")
  environment.note(
    "surface 已挂载：inWindow=\(paneSurface.window != nil) lifecycle=\(session.lifecycleState) "
      + "windowSurfaces=\(surfaces(in: fixture.window.contentView ?? NSView()).count)")

  // 诊断：桥命令文本 + 进程表里与本次 runID 相关的行。断言失败时这两条决定去哪儿查。
  let reference = try #require(pane.managedTerminal)
  let bridgeText = ManagedTerminalCoordinatorRegistry.coordinator(for: reference)
    .bridgeCommandText(for: reference) ?? "<nil>"
  environment.note("bridge 命令文本：\(bridgeText)")
  let psDump = runProcess("/bin/ps", ["-eo", "pid=,args="], timeout: 20).output
    .split(separator: "\n").map(String.init)
    .filter { $0.contains(environment.stateDirectory) || $0.contains(terminalID) }
  environment.note("ps 相关行(\(psDump.count))：\(psDump.prefix(6).joined(separator: " | "))")

  // —— 断言 (a)：本机确实有 `ssh … terminal attach <terminalID>` 进程 ——
  var bridgePIDs: [Int32] = []
  let bridgeStarted = await waitUntil(timeout: .seconds(45)) {
    bridgePIDs = localBridgeProcesses(
      terminalID: terminalID, stateDirectory: environment.stateDirectory)
    return !bridgePIDs.isEmpty
  }
  if !bridgeStarted {
    // 失败现场：屏幕上写着 surface 的子进程到底是什么，进程表说明它是不是 ssh。
    let views = surfaces(in: session.makeTerminalHost(preferences: fixture.preferences))
    for (index, view) in views.enumerated() {
      let text = (view.readText(includeScrollback: true) ?? "<nil>")
        .replacingOccurrences(of: "\n", with: " / ")
      environment.note(
        "(a诊断) surface[\(index)] running=\(view.isProcessRunning) text=\(text.suffix(400))")
    }
    let dump = runProcess("/bin/ps", ["-eo", "pid=,ppid=,args="], timeout: 20).output
      .split(separator: "\n").map(String.init)
      .filter { $0.contains("ssh") || $0.contains("aster-session") }
    environment.note("(a诊断) ssh 进程(\(dump.count))：\(dump.prefix(8).joined(separator: " | "))")
    environment.note("(a诊断) lifecycle=\(session.lifecycleState) startupError=\(session.startupError ?? "-")")
  }
  #expect(bridgeStarted, "本机必须存在显示桥进程 `ssh … terminal attach \(terminalID)`")
  let bridgePID = try #require(bridgePIDs.first)
  environment.note("(a) 本机显示桥 PID=\(bridgePID) argv 匹配 terminal attach \(terminalID)")
  // 桥必须**持续存活**：一闪即退的 ssh 不算链路通。
  try await Task.sleep(for: .seconds(3))
  #expect(processAlive(bridgePID), "显示桥进程必须持续存活，实测 PID \(bridgePID) 已退出")

  // —— 断言 (b)：远端 terminal.list 显示 running 且有真实 PID ——
  let facts = remoteTerminalFacts(environment)
  let fact = try #require(facts.first { $0.terminalID == terminalID }, "远端 terminal.list 找不到该终端")
  #expect(fact.state == "running", "远端终端状态应为 running，实测 \(fact.state)")
  let remotePID = try #require(fact.pid, "远端终端必须有真实 PID")
  #expect(remotePID > 0)
  environment.note("(b) 远端 terminal.list state=\(fact.state) pid=\(remotePID)")

  // —— 断言 (c)：远端产生的字节出现在本机 surface 的屏幕文本里 ——
  // 完全由远端发起：ssh 写 marker 文件，再由远端把它 cat 进这个终端自己的 PTY
  // （`/proc/<pid>/fd/1` 就是该终端的从设备）。本机一个字节都没输入。
  let inboundMarker = "ASTER-P4-BRIDGE-IN-\(UUID().uuidString.prefix(8))"
  let markerFile = "/tmp/aster-p4-bridge-\(environment.runID)-in.txt"
  let inbound = remoteShell(
    environment,
    "printf '%s\\n' '\(inboundMarker)' > '\(markerFile)' && cat '\(markerFile)' > /proc/\(remotePID)/fd/1")
  #expect(inbound.status == 0, "远端注入 marker 失败：\(inbound.output)")
  let inboundVisible = await waitUntil(timeout: .seconds(30)) {
    screenContains(inboundMarker, session: session, preferences: fixture.preferences)
  }
  #expect(inboundVisible, "远端 marker \(inboundMarker) 必须出现在本机 surface 屏幕文本里")
  environment.note("(c) 远端→本机 marker=\(inboundMarker) file=\(markerFile) 可见=\(inboundVisible)")

  // —— 断言 (d)：本机 surface 输入一行命令，远端文件出现对应内容 ——
  let outboundMarker = "ASTER-P4-BRIDGE-OUT-\(UUID().uuidString.prefix(8))"
  let outboundFile = "/tmp/aster-p4-bridge-\(environment.runID)-out.txt"
  #expect(paneSurface.isProcessRunning, "surface 的显示桥子进程必须在运行")
  #expect(
    paneSurface.typeText("printf '%s\\n' '\(outboundMarker)' > '\(outboundFile)'\n"),
    "Ghostty 输入路径必须接受这行命令（闸门未开或 surface 未就绪）")
  let outboundLanded = await waitUntilAsync(timeout: .seconds(30)) {
    remoteShell(environment, "cat '\(outboundFile)' 2>/dev/null || true", timeout: 20)
      .output.contains(outboundMarker)
  }
  #expect(outboundLanded, "本机键入的命令必须在远端文件 \(outboundFile) 里留下 \(outboundMarker)")
  environment.note("(d) 本机→远端 marker=\(outboundMarker) file=\(outboundFile) 落地=\(outboundLanded)")

  // —— 断言 (e)：分离 → 桥退出、远端 PID 不变；重新附加 → 再次可见 ——
  #expect(session.detachManagedTerminal(), "分离必须成功")
  let bridgeGone = await waitUntil(timeout: .seconds(30)) {
    localBridgeProcesses(terminalID: terminalID, stateDirectory: environment.stateDirectory)
      .isEmpty
  }
  #expect(bridgeGone, "分离后显示桥进程必须退出，残留 PID=\(localBridgeProcesses(terminalID: terminalID, stateDirectory: environment.stateDirectory))")
  let afterDetach = remoteTerminalFacts(environment).first { $0.terminalID == terminalID }
  #expect(afterDetach?.pid == remotePID, "分离不得动远端进程：PID 必须仍是 \(remotePID)")
  #expect(afterDetach?.state == "running")
  // 分离后远端是否留下孤儿 attach 进程：它会一直用 5 秒空输入心跳续租写租约，
  // 导致重新附加被 `lease_busy retry=never` 拒绝。这条诊断是判定的直接证据。
  let orphans = remoteShell(
    environment, "ps -eo pid,ppid,etimes,args | grep 'terminal attach' | grep -v grep || true",
    timeout: 20).output.split(separator: "\n").map(String.init)
  environment.note("(e1诊断) 分离后远端 attach 进程(\(orphans.count))：\(orphans.joined(separator: " | "))")
  environment.note("(e1) 分离后本机桥已退出，远端 pid=\(String(describing: afterDetach?.pid)) state=\(afterDetach?.state ?? "-")")

  #expect(session.reattachManagedTerminal(), "重新附加必须成功")
  var reattachPIDs: [Int32] = []
  let reattached = await waitUntil(timeout: .seconds(45)) {
    fixture.window.contentView?.layoutSubtreeIfNeeded()
    reattachPIDs = localBridgeProcesses(
      terminalID: terminalID, stateDirectory: environment.stateDirectory)
    return !reattachPIDs.isEmpty
  }
  #expect(reattached, "重新附加后必须重建显示桥进程")
  environment.note("(e2) 重新附加后本机桥 PID=\(reattachPIDs)")

  // 重新附加后画面必须再次真的可见：换一个 marker，避免旧屏幕内容冒充。
  let secondMarker = "ASTER-P4-BRIDGE-RE-\(UUID().uuidString.prefix(8))"
  // 反复注入而不是只注入一次：新的 ssh 桥要先完成 attach 握手才会把字节转发过来，
  // 在那之前写进 PTY 的内容不属于新桥的重放范围。同一个 marker 重复写是幂等的。
  let secondVisible = await waitUntilAsync(timeout: .seconds(60), interval: .seconds(2)) {
    _ = remoteShell(
      environment,
      "printf '%s\\n' '\(secondMarker)' > '\(markerFile)' && cat '\(markerFile)' > /proc/\(remotePID)/fd/1",
      timeout: 20)
    try? await Task.sleep(for: .milliseconds(500))
    return screenContains(secondMarker, session: session, preferences: fixture.preferences)
  }
  #expect(secondVisible, "重新附加后远端 marker \(secondMarker) 必须再次出现在 surface 上")
  if !secondVisible {
    // 失败时把现场留在证据里：屏幕上通常写着服务端拒绝的原因。
    let views = surfaces(in: session.makeTerminalHost(preferences: fixture.preferences))
    for (index, view) in views.enumerated() {
      let text = (view.readText(includeScrollback: true) ?? "<nil>")
        .replacingOccurrences(of: "\n", with: " / ")
      environment.note(
        "(e3诊断) surface[\(index)] running=\(view.isProcessRunning) text=\(text.suffix(400))")
    }
    environment.note("(e3诊断) lifecycle=\(session.lifecycleState) 远端=\(remoteTerminalFacts(environment).map { "\($0.terminalID.prefix(8))/\($0.state)/\(String(describing: $0.pid))" })")
  }
  environment.note("(e3) 重新附加后可见 marker=\(secondMarker) 可见=\(secondVisible)")

  // 收尾只清本 runID 的临时文件；远端终端与结构留给驱动脚本按 runID 整体删除。
  remoteShell(environment, "rm -f '\(markerFile)' '\(outboundFile)'", timeout: 20)
  environment.note("bridge e2e 结束：本机桥 PID=\(bridgePID)/\(reattachPIDs) 远端 PID=\(remotePID)")
}
