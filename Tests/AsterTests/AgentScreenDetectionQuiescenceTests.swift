import AsterCore
import Testing
@testable import Aster

// Agent 屏幕检测的静止期：屏幕没变时不做固定轮询，由 PTY 输出事件叫醒。

/// 可计数的假屏幕：验证静止期内轮询器确实没有读屏。
@MainActor
private final class CountingAgentScreen {
  var text = ""
  var sequence: UInt64 = 0
  private(set) var readCount = 0

  var source: AgentScreenDetectionMonitor.Source {
    AgentScreenDetectionMonitor.Source(
      readScreen: { [unowned self] in
        self.readCount += 1
        return self.text
      },
      oscTitle: { "" }, oscProgress: { "" },
      contentSequence: { [unowned self] in self.sequence },
      processExited: { false })
  }
}

@MainActor
private func waitUntilTrue(timeout: Duration = .seconds(3), _ condition: () -> Bool) async -> Bool {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while ContinuousClock.now < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(10))
  }
  return condition()
}

@Test("屏幕检测在静止期停止固定轮询，PTY 输出事件立即叫醒")
@MainActor
func screenDetectionParksWhileQuiescentAndWakesOnContent() async throws {
  let manifest = try #require(AgentDetectionManifestStore.shared.manifest(for: "codex"))
  let screen = CountingAgentScreen()
  // 兜底间隔远大于测试时长：静止期内任何读屏都只能来自 contentDidChange()。
  let monitor = AgentScreenDetectionMonitor(
    manifest: manifest, source: screen.source,
    timing: .init(
      pollInterval: .milliseconds(20), pendingIdleRecheck: .milliseconds(10),
      startupGrace: .milliseconds(20), quiescentPollInterval: .seconds(60)))
  var published: [AgentScreenState] = []
  monitor.onPublish = { published.append($0.state) }
  monitor.start()
  defer { monitor.stop() }

  #expect(await waitUntilTrue { monitor.published.state == .idle })
  // 再等几个正常轮询周期，让循环真正进入静止期睡眠。
  try await Task.sleep(for: .milliseconds(120))
  let readsBeforeChange = screen.readCount

  // 屏幕变了但没有事件：静止期不应自己发现（证明固定轮询已停）。
  screen.text = "• Working (4s • esc to interrupt)\n"
  screen.sequence &+= 1
  try await Task.sleep(for: .milliseconds(200))
  #expect(screen.readCount == readsBeforeChange)
  #expect(monitor.published.state == .idle)

  // 输出事件到达：按正常节奏读屏并发布 working。
  monitor.contentDidChange()
  #expect(await waitUntilTrue { monitor.published.state == .working })
  #expect(published.last == .working)
}

@Test("未配置静止期间隔时沿用原轮询节奏，无事件也能发现变化")
@MainActor
func screenDetectionKeepsPollingWithoutQuiescentInterval() async throws {
  let manifest = try #require(AgentDetectionManifestStore.shared.manifest(for: "codex"))
  let screen = CountingAgentScreen()
  let monitor = AgentScreenDetectionMonitor(
    manifest: manifest, source: screen.source,
    timing: .init(
      pollInterval: .milliseconds(20), pendingIdleRecheck: .milliseconds(10),
      startupGrace: .milliseconds(20)))
  monitor.start()
  defer { monitor.stop() }
  #expect(await waitUntilTrue { monitor.published.state == .idle })

  screen.text = "• Working (4s • esc to interrupt)\n"
  screen.sequence &+= 1
  #expect(await waitUntilTrue { monitor.published.state == .working })
}

@Test("生产节奏带静止期兜底间隔")
func productionTimingHasQuiescentFallback() {
  #expect(AgentScreenDetectionMonitor.Timing.production.quiescentPollInterval == .seconds(2))
  #expect(
    AgentScreenDetectionMonitor.Timing.production.pollInterval
      == AgentScreenDetectionPublisher.pollInterval)
}
