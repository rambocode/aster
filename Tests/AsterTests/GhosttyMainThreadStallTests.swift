import AppKit
import Testing

@testable import Aster
@testable import AsterCore

/// 本文件独立的视图树展开工具;AppKitMigrationTests 里的同名扩展是 fileprivate。
extension NSView {
  fileprivate var stallTestDescendants: [NSView] {
    subviews + subviews.flatMap(\.stallTestDescendants)
  }
}

/// 复现「终端洪流输出时切换 tab / 新增 pane 造成主线程长时间阻塞」的反馈回路。
///
/// 心跳任务每 10ms 在 MainActor 上打点；任何单次 renderNow / surface 创建 / 焦点切换
/// 若同步占住主线程,心跳间隔就会拉大。阈值取 200ms:正常路径心跳抖动在几十毫秒内,
/// 用户可感知的"严重阻塞"至少是数百毫秒级。
@MainActor
private func maxHeartbeatGap(during body: @MainActor () async throws -> Void) async rethrows -> Duration {
  let heartbeat = Task { @MainActor () -> Duration in
    var maxGap: Duration = .zero
    var last = ContinuousClock.now
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: .milliseconds(10))
      } catch {
        break
      }
      let now = ContinuousClock.now
      let gap = now - last
      if gap > maxGap { maxGap = gap }
      last = now
    }
    return maxGap
  }
  do {
    try await body()
  } catch {
    // body 失败时也必须结束心跳；否则测试结束后会残留永久 MainActor task。
    heartbeat.cancel()
    _ = await heartbeat.value
    throw error
  }
  heartbeat.cancel()
  return await heartbeat.value
}

/// 在测试窗口中创建一个已运行 Shell 的 Ghostty surface,返回其 host 与 view。
@MainActor
private func makeRunningSurface(
  in window: NSWindow,
  preferences: AppPreferences,
  session: TerminalSession
) async throws -> GhosttySurfaceView {
  let host = session.makeTerminalHost(preferences: preferences)
  let view = try #require(
    ([host] + host.stallTestDescendants).compactMap { $0 as? GhosttySurfaceView }.first)
  host.frame = window.contentView?.bounds ?? .zero
  host.autoresizingMask = [.width, .height]
  window.contentView?.addSubview(host)
  window.layoutIfNeeded()
  view.createSurface()
  for _ in 0..<200 where !view.isProcessRunning {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(view.isProcessRunning)
  return view
}

@Test("洪流输出中切换 tab 与新增 pane 不得阻塞主线程")
@MainActor
func heavyOutputTabSwitchDoesNotStallMainThread() async throws {
  _ = NSApplication.shared
  let preferences = AppPreferences(defaults: {
    let suite = "AsterTests.stall.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }())
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
  )
  window.makeKeyAndOrderFront(nil)
  defer { window.orderOut(nil) }

  let sessionA = TerminalSession(workingDirectory: "/tmp")
  defer { sessionA.stop(immediately: true) }
  let viewA = try await makeRunningSurface(in: window, preferences: preferences, session: sessionA)

  // 洪流输出:base64 /dev/urandom 持续产出满宽文本,驱动 IO 线程持续持有 renderer mutex
  // 并高频派发 RENDER action。
  #expect(viewA.typeText("base64 < /dev/urandom | head -c 200000000\n"))
  try await Task.sleep(for: .milliseconds(500))

  let gap = try await maxHeartbeatGap {
    // 模拟切换 tab:当前 pane 失活并隐藏,再新建第二个 pane(新 surface + 新 shell)。
    for round in 0..<3 {
      viewA.setPaneActive(false)
      viewA.superview?.isHidden = true

      let sessionB = TerminalSession(workingDirectory: "/tmp")
      let viewB = try await makeRunningSurface(
        in: window, preferences: preferences, session: sessionB)
      viewB.setPaneActive(true)
      try await Task.sleep(for: .milliseconds(400))

      // 切回:隐藏 B,恢复 A。
      viewB.setPaneActive(false)
      sessionB.stop(immediately: true)
      viewA.superview?.isHidden = false
      viewA.setPaneActive(true)
      try await Task.sleep(for: .milliseconds(400))
      _ = round
    }
  }

  // 先把测量结果写到 stderr:teardown 路径(stop → surface_free → pthread_join)存在
  // 独立的挂死 bug,不能指望 defer 之后还有机会输出。
  FileHandle.standardError.write(Data("[DEBUG-stall] max heartbeat gap = \(gap)\n".utf8))

  // 结束洪流,避免 teardown 走「子进程未退 → Subprocess.stop 无限等待」的挂死路径。
  _ = viewA.typeText("\u{3}")
  try await Task.sleep(for: .milliseconds(800))

  #expect(
    gap < .milliseconds(200),
    "主线程最大停顿 \(gap) 超过 200ms:洪流输出 + tab 切换/新建 pane 阻塞了 UI")
}

/// 同一症状在真实工作区链路(AppModel + WorkspaceViewController)上的复现回路。
/// 裸 surface 层已经证明不卡;若此测试红,说明阻塞在标签切换/建 Pane 的工作区代码路径。
@Test("真实工作区在洪流输出中切换标签与新建标签不得阻塞主线程")
@MainActor
func workspaceTabSwitchUnderFloodDoesNotStallMainThread() async throws {
  _ = NSApplication.shared
  let suite = "AsterTests.stall.ws.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()

  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1000, height: 700),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.makeKeyAndOrderFront(nil)
  defer { window.orderOut(nil) }
  window.layoutIfNeeded()

  // 等首个终端 surface 起来并注入洪流输出。
  func activeGhosttyView() -> GhosttySurfaceView? {
    ([controller.view] + controller.view.stallTestDescendants)
      .compactMap { $0 as? GhosttySurfaceView }
      .first { $0.surface != nil }
  }
  var floodView: GhosttySurfaceView?
  for _ in 0..<200 {
    if let view = activeGhosttyView(), view.isProcessRunning { floodView = view; break }
    try await Task.sleep(for: .milliseconds(20))
  }
  let flood = try #require(floodView, "首个工作区终端未能启动")
  #expect(flood.typeText("base64 < /dev/urandom | head -c 200000000\n"))
  try await Task.sleep(for: .milliseconds(500))

  let firstTab = try #require(model.tabs.first)
  let gap = try await maxHeartbeatGap {
    for _ in 0..<3 {
      // 新建标签(新 surface + 新 shell),再切回洪流标签,来回若干次。
      model.newTab(workingDirectory: "/tmp")
      try await Task.sleep(for: .milliseconds(400))
      model.select(firstTab)
      try await Task.sleep(for: .milliseconds(300))
      if let latest = model.tabs.last, latest !== firstTab {
        model.select(latest)
        try await Task.sleep(for: .milliseconds(200))
        model.select(firstTab)
        try await Task.sleep(for: .milliseconds(200))
      }
    }
  }
  FileHandle.standardError.write(Data("[DEBUG-stall] workspace max gap = \(gap)\n".utf8))

  // 结束洪流,绕开 teardown 的 Subprocess.stop 挂死路径(独立 bug,另行修复)。
  _ = flood.typeText("\u{3}")
  try await Task.sleep(for: .milliseconds(800))

  #expect(
    gap < .milliseconds(200),
    "工作区主线程最大停顿 \(gap) 超过 200ms")
}
