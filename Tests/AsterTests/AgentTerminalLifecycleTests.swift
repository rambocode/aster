import AppKit
import Foundation
import Testing

@testable import Aster
// 恢复重连测试需要 AgentConfiguration 的 internal memberwise init 来构造配置。
@testable import AsterCore

@Test("权威 Agent 等待输入在用户提交后回到处理中并保持序列单调")
@MainActor
func authoritativeAgentAwaitingInputConsumesUserSubmission() throws {
  let suiteName = "AgentTerminalLifecycleTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  defer { defaults.removePersistentDomain(forName: suiteName) }

  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.appearance.cursorStyle = .bar
  preferences.configuration.appearance.cursorBlinkMode = .alwaysOn
  let session = TerminalSession(workingDirectory: "/tmp")
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  defer { session.stop(immediately: true) }

  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .awaitingInput)
  )
  let awaitingSequence = try agentLifecycleSequence(of: session)
  #expect(session.agentTaskState == .awaitingInput)
  #expect(terminalView.getTerminal().options.cursorStyle == .blinkBar)

  // 直接触发终端视图已经安装的用户输入回调，覆盖真实输入链路而不依赖键盘 UI 自动化。
  terminalView.onTerminalUserInput?()
  let submittedSequence = try agentLifecycleSequence(of: session)
  #expect(session.agentTaskState == .processing)
  // Codex 输出期间输入框仍保留用户设置的竖线，但暂停闪烁；回到等待输入后再恢复。
  #expect(terminalView.getTerminal().options.cursorStyle == .steadyBar)
  #expect(submittedSequence == awaitingSequence + 1)

  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .idle)
  )
  #expect(session.agentTaskState == .idle)
  #expect(terminalView.getTerminal().options.cursorStyle == .blinkBar)
  #expect(try agentLifecycleSequence(of: session) == submittedSequence + 1)
}

@Test("Agent lifecycle 只在首次等待输入与本轮完成时请求通知")
@MainActor
func agentLifecycleRequestsAwaitingAndCompletionNotificationsOnce() throws {
  let (suiteName, defaults) = try agentLifecycleDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.agents.notifyAwaitingInput = true
  preferences.configuration.agents.notifyTaskComplete = true
  let recorder = TerminalNotificationRecorder()
  let session = TerminalSession(workingDirectory: "/tmp", notificationPoster: recorder)
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  defer { session.stop(immediately: true) }

  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .processing)
  )
  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .awaitingInput)
  )
  // 重复 hook 不能产生第二条系统通知。
  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .awaitingInput)
  )
  terminalView.onTerminalUserInput?()
  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .idle)
  )

  #expect(recorder.records.map(\.notification.title) == ["Agent 等待输入", "Agent 任务已完成"])
  #expect(recorder.records.map(\.category) == [.commandFinish, .commandFinish])
  #expect(recorder.records.allSatisfy { $0.notification.body.contains("codex") })
}

@Test("无输出 Agent CLI 停留在输入界面后不再显示运行中徽章")
@MainActor
func silentAgentCLIStopsShowingProcessingBadge() async throws {
  let (suiteName, defaults) = try agentLifecycleDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.agents.badgeProcessing = true

  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-silent-agent-\(UUID().uuidString)",
    isDirectory: true
  )
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let executable = directory.appendingPathComponent("codex", isDirectory: false)
  try Data("#!/bin/sh\n/bin/sleep 2\n".utf8).write(to: executable, options: .atomic)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o700],
    ofItemAtPath: executable.path
  )

  let session = TerminalSession(
    workingDirectory: directory.path,
    fallbackAgentIdleDelay: .milliseconds(100)
  )
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  defer { session.stop(immediately: true) }
  session.send(executable.path)

  let startDeadline = ContinuousClock.now.advanced(by: .seconds(2))
  while session.agentTaskState != .processing, ContinuousClock.now < startDeadline {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(session.activeAgentProvider == .codex)
  #expect(session.agentTaskState == .processing)
  #expect(session.agentActivityBadge == .running(percent: nil))
  #expect(!session.hasAuthoritativeAgentLifecycle)
  #expect(session.progressState == .clear)

  // CLI 进程仍在前台，但连续无输出表示已停在输入界面；不应因
  // 为长寿命 TUI 进程未退出，让侧栏 tab 的 spinner 永久运行。
  try await Task.sleep(for: .milliseconds(250))
  #expect(session.hasRunningCommand)
  #expect(session.agentTaskState == .idle)
  #expect(session.agentActivityBadge == TerminalBadgeState.none)

  // 后续 PTY 输出会重新进入回退 processing；若同时收到权威 hook，
  // 超时任务必须取消，不得把真实的静默推理误清为 idle。
  terminalView.onTerminalOutputActivity?("thinking")
  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .processing)
  )
  try await Task.sleep(for: .milliseconds(250))
  #expect(session.hasAuthoritativeAgentLifecycle)
  #expect(session.agentTaskState == .processing)
  #expect(session.agentActivityBadge == .running(percent: nil))
}

@Test("Agent 与显式错误状态驱动 Dock icon 聚合变化")
@MainActor
func dockIconStateTracksAgentLifecycleAndExplicitError() async throws {
  let (suiteName, defaults) = try agentLifecycleDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.appearance.animateDockIconOnProgress = true
  preferences.configuration.appearance.redDockIconOnError = true
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let session = try #require(model.selectedTab?.activeSession)
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  let coordinator = DockActivityCoordinator(model: model, preferences: preferences)
  coordinator.start()
  defer {
    coordinator.stop()
    session.stop(immediately: true)
  }

  #expect(coordinator.currentState == .idle)
  #expect(NSApp.dockTile.contentView == nil)
  #expect(NSApp.dockTile.badgeLabel == nil)
  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .processing)
  )
  try await Task.sleep(for: .milliseconds(50))
  #expect(coordinator.currentState == .working)
  let dockContentView = try #require(NSApp.dockTile.contentView)
  let animatedIconView = try #require(dockContentView.subviews.first as? NSImageView)
  #expect(animatedIconView.frame.width < dockContentView.bounds.width)
  #expect(animatedIconView.frame.height < dockContentView.bounds.height)
  #expect(abs(animatedIconView.frame.midX - dockContentView.bounds.midX) < 0.01)
  #expect(abs(animatedIconView.frame.midY - dockContentView.bounds.midY) < 0.01)
  #expect(NSApp.dockTile.badgeLabel == nil)
  // 一圈最多生成 12 个离散角度；完成一圈后继续动画只能复用缓存帧。
  try await Task.sleep(for: .seconds(3))
  let renderedIconCount = coordinator.renderedIconCount
  try await Task.sleep(for: .milliseconds(500))
  #expect(renderedIconCount <= 12)
  #expect(coordinator.renderedIconCount == renderedIconCount)

  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .idle)
  )
  try await Task.sleep(for: .milliseconds(50))
  #expect(coordinator.currentState == .idle)
  #expect(NSApp.dockTile.contentView == nil)
  #expect(NSApp.dockTile.badgeLabel == nil)

  terminalView.onTerminalBadgeDirective?(.set(.error))
  try await Task.sleep(for: .milliseconds(50))
  #expect(coordinator.currentState == .error)
  #expect(NSApp.dockTile.contentView != nil)
  #expect(NSApp.dockTile.badgeLabel == "!")

  terminalView.onTerminalBadgeDirective?(.clear)
  try await Task.sleep(for: .milliseconds(50))
  #expect(coordinator.currentState == .idle)
  #expect(NSApp.dockTile.contentView == nil)
  #expect(NSApp.dockTile.badgeLabel == nil)
}

@MainActor
private final class TerminalNotificationRecorder: TerminalNotificationPosting {
  struct Record {
    let notification: TerminalNotification
    let category: TerminalNotificationCategory
  }

  private(set) var records: [Record] = []

  func post(
    _ notification: TerminalNotification,
    category: TerminalNotificationCategory,
    configuration: ShellConfiguration,
    sourceTabIsFocused: Bool
  ) {
    records.append(Record(notification: notification, category: category))
  }
}

@MainActor
private func agentLifecycleDefaults() throws -> (String, UserDefaults) {
  let suiteName = "AgentTerminalLifecycleTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  return (suiteName, defaults)
}

/// sequence 是 `TerminalSession` 的私有实现细节；测试只读反射既能验证单调性，也不会
/// 为测试向生产类型新增接口。字段改名会明确要求同步审视这条生命周期约束。
private func agentLifecycleSequence(of session: TerminalSession) throws -> UInt64 {
  let sequence = Mirror(reflecting: session).children.first {
    $0.label == "agentLifecycleSequence"
  }?.value as? UInt64
  return try #require(sequence)
}

// 「恢复时重连会话」的命令构造是纯函数：锁定默认前缀、自定义前缀与非法会话 ID 三种路径。
@Test("恢复重连命令沿用自定义启动前缀并拒绝非法会话 ID")
func restoredAgentResumeCommandHonorsLaunchPrefix() {
  var agents = AgentConfiguration()
  #expect(
    TerminalSession.restoredAgentResumeCommand(
      provider: .claudeCode, sessionID: "abc-123", agents: agents
    ) == "'claude' '--resume' 'abc-123'"
  )

  agents.customLaunchCommands = ["codex": ["codex", "--profile", "dev env"]]
  #expect(
    TerminalSession.restoredAgentResumeCommand(
      provider: .codex, sessionID: "s1", agents: agents
    ) == "'codex' '--profile' 'dev env' 'resume' 's1'"
  )

  #expect(
    TerminalSession.restoredAgentResumeCommand(
      provider: .claudeCode, sessionID: "", agents: agents
    ) == nil
  )
}

@Test("恢复重连在首个 prompt 处消费，用户提前输入则取消")
@MainActor
func restoredAgentResumeConsumesOnPromptAndCancelsOnUserInput() throws {
  let suiteName = "AgentTerminalLifecycleTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)

  // 场景一：prompt 到来时 pending 被一次性消费，后续 prompt 不会再触发。
  let session = TerminalSession(workingDirectory: "/tmp")
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  defer { session.stop(immediately: true) }
  session.scheduleRestoredAgentResume(provider: .claudeCode, sessionID: "abc-123")
  #expect(session.hasPendingRestoredAgentResume)
  terminalView.onShellIntegrationEvent?(.promptStart)
  #expect(!session.hasPendingRestoredAgentResume)

  // 场景二：用户在 prompt 之前输入任何内容都放弃自动重连。
  let interrupted = TerminalSession(workingDirectory: "/tmp")
  let interruptedView = try #require(
    interrupted.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  defer { interrupted.stop(immediately: true) }
  interrupted.scheduleRestoredAgentResume(provider: .codex, sessionID: "s1")
  interruptedView.onTerminalUserInput?()
  #expect(!interrupted.hasPendingRestoredAgentResume)
}

// 端到端：真实 shell 中 prompt 信号触发后，resume 命令必须真正写入 PTY 并被执行。
// 启动前缀换成 echo，验证完整链路（调度 → prompt → send → shell 执行）而不真启动 Agent。
@Test("恢复重连在真实 shell 的 prompt 后把 resume 命令写入 PTY")
@MainActor
func restoredAgentResumeWritesCommandIntoLiveShell() async throws {
  let suiteName = "AgentTerminalLifecycleTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.agents.customLaunchCommands = [
    "claudeCode": ["echo", "__ASTER_RESUME_TEST__"]
  ]

  let session = TerminalSession(workingDirectory: "/tmp")
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  defer { session.stop(immediately: true) }

  session.scheduleRestoredAgentResume(provider: .claudeCode, sessionID: "test-1")
  terminalView.onShellIntegrationEvent?(.promptStart)
  #expect(!session.hasPendingRestoredAgentResume)

  // echo 执行后 marker 出现在真实终端 grid 上，证明命令抵达 PTY 而不是停在回调层。
  var joined = ""
  for _ in 0..<80 {
    joined = session.textSnapshot().lines.joined(separator: "\n")
    if joined.contains("__ASTER_RESUME_TEST__"), joined.contains("--resume") { break }
    try await Task.sleep(for: .milliseconds(25))
  }
  #expect(joined.contains("__ASTER_RESUME_TEST__"))
  #expect(joined.contains("--resume"))
  #expect(joined.contains("test-1"))
}

@Test("恢复命令在缺少 OSC 133 时由启动兜底投递,用户输入则取消")
@MainActor
func restoredCommandDeliversViaFallbackAndCancelsOnInput() async throws {
  let suiteName = "AgentTerminalLifecycleTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.shell.restoreProcesses = true
  preferences.configuration.shell.restoreProcessesScope = .all

  // 场景一：进程就绪后,普通会话没有 promptStart,兜底在延时后把命令写入 PTY。
  let session = TerminalSession(workingDirectory: "/tmp")
  let view = try #require(session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }
  session.scheduleRestoredCommand(
    .init(paneID: UUID(), command: "echo FALLBACK_OK", source: .process))
  #expect(session.hasPendingRestoredCommand)
  try await Task.sleep(for: .milliseconds(1_900))
  #expect(!session.hasPendingRestoredCommand)  // 已被兜底消费

  // 场景二：用户在兜底触发前输入,取消恢复投递。
  let interrupted = TerminalSession(workingDirectory: "/tmp")
  let interruptedView = try #require(
    interrupted.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { interrupted.stop(immediately: true) }
  interrupted.scheduleRestoredCommand(
    .init(paneID: UUID(), command: "echo SHOULD_NOT_RUN", source: .process))
  interruptedView.onTerminalUserInput?()
  #expect(!interrupted.hasPendingRestoredCommand)
}

// MARK: - 屏幕检测接线（计划 A6）

/// 假屏幕：测试用它替代 Ghostty 读屏，直接喂检测引擎。
@MainActor
private final class FakeAgentScreen {
  var text = ""
  var title = ""
  var progress = ""
  var sequence: UInt64 = 0
  var processExited = false

  /// 每次改屏幕都递增序号，否则 idle 时轮询会因序号未变而跳过读屏。
  func show(_ text: String, title: String? = nil) {
    self.text = text
    if let title { self.title = title }
    sequence &+= 1
  }

  var source: AgentScreenDetectionMonitor.Source {
    AgentScreenDetectionMonitor.Source(
      readScreen: { [unowned self] in self.text },
      oscTitle: { [unowned self] in self.title },
      oscProgress: { [unowned self] in self.progress },
      contentSequence: { [unowned self] in self.sequence },
      processExited: { [unowned self] in self.processExited }
    )
  }
}

/// 测试用的快节奏：20ms 轮询、60ms 启动宽限。
private let fastScreenDetectionTiming = AgentScreenDetectionMonitor.Timing(
  pollInterval: .milliseconds(20),
  pendingIdleRecheck: .milliseconds(10),
  startupGrace: .milliseconds(60)
)

/// 用 OSC 133 A/B/C 让 SwiftTerm 视图进入「有前台命令在跑」；标题补识别只在此状态下生效。
@MainActor
private func startForegroundCommand(_ view: AsterTerminalView, _ command: String = "wrapper") {
  view.dataReceived(
    slice: Array("\u{1B}]133;A\u{07}\u{1B}]133;B\u{07}\(command)\u{1B}]133;C\u{07}".utf8)[...])
}

/// 轮询等待条件成立，最多 `timeout`。
@MainActor
private func waitUntil(
  _ timeout: Duration = .seconds(2), _ condition: @MainActor () -> Bool
) async throws {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while !condition(), ContinuousClock.now < deadline {
    try await Task.sleep(for: .milliseconds(10))
  }
}

@Test("屏幕上的阻塞表单覆盖 partial hook 的 processing，清除后回到 processing")
@MainActor
func screenBlockerOverridesPartialHookProcessing() async throws {
  let (suiteName, defaults) = try agentLifecycleDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.agents.notifyAwaitingInput = true
  preferences.configuration.agents.notifyTaskComplete = true
  let recorder = TerminalNotificationRecorder()
  let screen = FakeAgentScreen()
  let session = TerminalSession(
    workingDirectory: "/tmp",
    notificationPoster: recorder,
    agentScreenDetectionTiming: fastScreenDetectionTiming
  )
  session.agentScreenDetectionSourceOverride = screen.source
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  defer { session.stop(immediately: true) }

  // codex 是 partial hook provider：hook 权威后屏幕轮询继续跑。
  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .processing)
  )
  #expect(session.hasAuthoritativeAgentLifecycle)
  #expect(session.isAgentScreenMonitorRunning)
  #expect(session.agentTaskState == .processing)

  screen.show("› 1. Yes, proceed\nAllow command?\n")
  try await waitUntil { session.agentTaskState == .awaitingInput }
  #expect(session.agentTaskState == .awaitingInput)
  #expect(recorder.records.map(\.notification.title) == ["Agent 等待输入"])

  // 表单消失：hook 仍说 processing，屏幕无阻塞证据 → 回到 processing，不算任务完成。
  screen.show("• Working (4s • esc to interrupt)\n")
  try await waitUntil { session.agentTaskState == .processing }
  #expect(session.agentTaskState == .processing)
  #expect(!session.agentTaskCompletionUnread)
  #expect(recorder.records.count == 1)

  // 关闭「屏幕阻塞覆盖 hook」后，同样的表单不再改变 hook 结论。
  preferences.configuration.agents.screenDetectionOverridesHook = false
  screen.show("› 1. Yes, proceed\nAllow command?\n")
  try await Task.sleep(for: .milliseconds(150))
  #expect(session.agentTaskState == .processing)

  // hook 收尾：processing → idle 仍走原有的完成通知。
  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .idle)
  )
  #expect(session.agentTaskState == .idle)
  #expect(session.agentTaskCompletionUnread)
  #expect(recorder.records.map(\.notification.title) == ["Agent 等待输入", "Agent 任务已完成"])
}

@Test("无 hook 的清单 provider 完全由屏幕检测驱动，启动宽限视为处理中")
@MainActor
func screenDetectionDrivesHooklessManifestProvider() async throws {
  let (suiteName, defaults) = try agentLifecycleDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.agents.notifyTaskComplete = true
  let recorder = TerminalNotificationRecorder()
  let screen = FakeAgentScreen()
  let session = TerminalSession(
    workingDirectory: "/tmp",
    fallbackAgentIdleDelay: .milliseconds(50),
    notificationPoster: recorder,
    agentScreenDetectionTiming: fastScreenDetectionTiming
  )
  session.agentScreenDetectionSourceOverride = screen.source
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  defer { session.stop(immediately: true) }

  // 经标题补识别 devin（别名前缀匹配），没有任何 hook；必须先有前台命令。
  screen.show("Devin CLI\n")
  startForegroundCommand(terminalView)
  try await waitUntil { session.hasRunningCommand }
  terminalView.onObservedTitleUpdate?(0, "Devin CLI")
  // 标题回调经 Task 异步转发到 Session，需要等它落地。
  try await waitUntil { session.activeAgentProvider != nil }
  #expect(session.activeAgentProvider == .devin)
  #expect(!session.hasAuthoritativeAgentLifecycle)
  #expect(session.isAgentScreenMonitorRunning)
  // 启动宽限内暂定 processing。
  #expect(session.agentTaskState == .processing)

  // 宽限结束后屏幕只是一个空闲提示框 → idle，且不能被当作「任务完成」通知。
  screen.show(
    "─────────────────────────────────────────────────────\n❭ Ask Devin to build features, fix bugs, or work on\n  your code\n─────────────────────────────────────────────────────\nSWE-1.6               Context: 16k / 200k tokens (7%)"
  )
  try await waitUntil { session.agentTaskState == .idle }
  #expect(session.agentTaskState == .idle)
  #expect(!session.agentTaskCompletionUnread)
  #expect(recorder.records.isEmpty)

  // 5 秒静默兜底已被屏幕检测取代：输出活动不再把状态抖成 processing。
  terminalView.onTerminalOutputActivity?("some output")
  try await Task.sleep(for: .milliseconds(120))
  #expect(session.agentTaskState == .idle)

  // 真正开始工作 → processing；随后回到提示框 → idle + 完成通知。
  screen.show("◔ Reading shell 91b655\n\n⠀⡆ Running tools · 27s (esc to interrupt)\n─────\n❭ Guide Devin while it works")
  try await waitUntil { session.agentTaskState == .processing }
  #expect(session.agentTaskState == .processing)
  screen.show(
    "Done.\n\n────────────────────────────────────────────────── (bypass permissions on) ─\n❭\n────────────────────────────────────────────────────────────────────────────\nClaude Opus 4.6 Thinking                                    Context: 38k / 200k tokens (18%)"
  )
  try await waitUntil { session.agentTaskState == .idle }
  #expect(session.agentTaskState == .idle)
  #expect(session.agentTaskCompletionUnread)
  #expect(recorder.records.map(\.notification.title) == ["Agent 任务已完成"])

  // 屏幕解释可用，且命中 devin 的实时提示框规则。
  let explain = try #require(session.explainAgentDetection())
  #expect(explain.agentID == "devin")
  #expect(explain.matchedRule?.id == "live_prompt_footer")
}

@Test("完整生命周期 hook 权威后停止屏幕轮询；无清单 provider 保持 5 秒兜底")
@MainActor
func fullLifecycleHookStopsMonitorAndManifestlessProviderKeepsFallback() async throws {
  let (suiteName, defaults) = try agentLifecycleDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)

  // opencode（fullLifecycleHooks）：先由标题识别启动屏幕轮询，hook 一到就停。
  // `pi` 别名太通用（`ssh pi`），已从标题识别里排除，因此用 opencode 演示同一路径。
  let piScreen = FakeAgentScreen()
  let pi = TerminalSession(
    workingDirectory: "/tmp", agentScreenDetectionTiming: fastScreenDetectionTiming)
  pi.agentScreenDetectionSourceOverride = piScreen.source
  let piView = try #require(pi.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { pi.stop(immediately: true) }
  startForegroundCommand(piView)
  try await waitUntil { pi.hasRunningCommand }
  piView.onObservedTitleUpdate?(0, "opencode — ~/src")
  try await waitUntil { pi.activeAgentProvider != nil }
  #expect(pi.activeAgentProvider == .openCode)
  #expect(pi.isAgentScreenMonitorRunning)
  piView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .openCode, signal: .processing))
  #expect(pi.hasAuthoritativeAgentLifecycle)
  #expect(!pi.isAgentScreenMonitorRunning)
  #expect(pi.agentTaskState == .processing)

  // omp：没有清单，屏幕来源就绪也不启动轮询，仍走活动探针的短暂 processing → idle。
  // omp 的别名在标题排除表里，这里走真实 shell 的 commandStart 首 token 识别。
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-omp-fallback-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let executable = directory.appendingPathComponent("omp", isDirectory: false)
  try Data("#!/bin/sh\n/bin/sleep 2\n".utf8).write(to: executable, options: .atomic)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
  let ompScreen = FakeAgentScreen()
  let omp = TerminalSession(
    workingDirectory: directory.path,
    fallbackAgentIdleDelay: .milliseconds(80),
    agentScreenDetectionTiming: fastScreenDetectionTiming
  )
  omp.agentScreenDetectionSourceOverride = ompScreen.source
  _ = try #require(omp.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { omp.stop(immediately: true) }
  omp.send(executable.path)
  try await waitUntil { omp.activeAgentProvider != nil }
  #expect(omp.activeAgentProvider == .omp)
  #expect(!omp.isAgentScreenMonitorRunning)
  #expect(omp.agentTaskState == .processing)
  try await waitUntil { omp.agentTaskState == .idle }
  #expect(omp.agentTaskState == .idle)

  // 设置关闭屏幕检测：有清单的 provider 也回到旧行为。
  preferences.configuration.agents.screenDetectionEnabled = false
  let disabledScreen = FakeAgentScreen()
  let disabled = TerminalSession(
    workingDirectory: "/tmp",
    fallbackAgentIdleDelay: .milliseconds(80),
    agentScreenDetectionTiming: fastScreenDetectionTiming
  )
  disabled.agentScreenDetectionSourceOverride = disabledScreen.source
  let disabledView = try #require(
    disabled.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { disabled.stop(immediately: true) }
  startForegroundCommand(disabledView)
  try await waitUntil { disabled.hasRunningCommand }
  disabledView.onObservedTitleUpdate?(0, "✳ Claude Code")
  try await waitUntil { disabled.activeAgentProvider != nil }
  #expect(disabled.activeAgentProvider == .claudeCode)
  #expect(!disabled.isAgentScreenMonitorRunning)
  try await waitUntil { disabled.agentTaskState == .idle }
  #expect(disabled.agentTaskState == .idle)
}

@Test("Shell Controlled 标题关闭时 OSC 标题仍进入检测输入")
@MainActor
func oscTitleFeedsDetectionWhenShellControlledTitleIsOff() throws {
  let (suiteName, defaults) = try agentLifecycleDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.shell.titleShellControlled = false
  let screen = FakeAgentScreen()
  let session = TerminalSession(
    workingDirectory: "/tmp", agentScreenDetectionTiming: fastScreenDetectionTiming)
  session.agentScreenDetectionSourceOverride = AgentScreenDetectionMonitor.Source(
    readScreen: { [unowned screen] in screen.text },
    // 标题来自 Session 自己记录的 OSC 原文，而不是假屏幕。
    oscTitle: { [unowned session] in session.agentOSCTitle },
    oscProgress: { [unowned session] in session.agentOSCProgress },
    contentSequence: { [unowned screen] in screen.sequence },
    processExited: { false }
  )
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  defer { session.stop(immediately: true) }
  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .processing)
  )

  // 与 Ghostty 路径一致：OSC 0/2 原文在标题开关之前记录，窗口标题本身不受影响。
  session.receiveAgentOSCTitle("[ . ] Action Required | llm-proxy")
  session.receiveAgentOSCProgress("9;4;3;")
  #expect(session.terminalTitle == "Shell")
  #expect(session.agentOSCProgress == "4;3;")
  let explain = try #require(session.explainAgentDetection())
  #expect(explain.state == .blocked)
  #expect(explain.matchedRule?.id == "osc_title_blocked")
  #expect(explain.visibleBlocker)

  session.receiveAgentOSCTitle("llm-proxy")
  #expect(session.explainAgentDetection()?.matchedRule?.id == "osc_title_idle")
}

@Test("标题补识别只认别名前缀与 Claude glyph，不吃普通 shell 标题")
func agentProviderFromTitleMatchesAliasPrefixOnly() {
  #expect(TerminalSession.agentProvider(fromTitle: "✳ Claude Code") == .claudeCode)
  #expect(TerminalSession.agentProvider(fromTitle: "⠋ project") == .claudeCode)
  #expect(TerminalSession.agentProvider(fromTitle: "◐ Initial conversation") == .claudeCode)
  #expect(TerminalSession.agentProvider(fromTitle: "codex") == .codex)
  #expect(TerminalSession.agentProvider(fromTitle: "  Codex: ~/src  ") == .codex)
  #expect(TerminalSession.agentProvider(fromTitle: "Devin CLI") == .devin)
  #expect(TerminalSession.agentProvider(fromTitle: "kimi code — repo") == .kimiCode)
  #expect(TerminalSession.agentProvider(fromTitle: "opencode — ~/src") == .openCode)
  // 普通 shell 标题：路径、命令行、ssh 目标都不能被当成 Agent。
  for title in [
    "mike@mac: ~/src/agent", "vim agent.py", "ssh pi", "cd ~/muse", "man amp", "omp",
    "pip install", "example.com", "codex-helper", "codex.py", "~/codex", "cursor", "droid",
    "kilo", "cline", "maki", "",
  ] {
    #expect(TerminalSession.agentProvider(fromTitle: title) == nil, Comment(rawValue: title))
  }
}

@Test("提示符下的标题不识别；弱证据 provider 在标题变化后被撤销")
@MainActor
func titleEvidenceProviderRequiresRunningCommandAndIsRevoked() async throws {
  let (suiteName, defaults) = try agentLifecycleDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  let screen = FakeAgentScreen()
  let session = TerminalSession(
    workingDirectory: "/tmp", agentScreenDetectionTiming: fastScreenDetectionTiming)
  session.agentScreenDetectionSourceOverride = screen.source
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }

  // 纯提示符：即使标题完全匹配也不识别。
  terminalView.onObservedTitleUpdate?(0, "codex")
  try await Task.sleep(for: .milliseconds(50))
  #expect(session.activeAgentProvider == nil)
  #expect(!session.isAgentScreenMonitorRunning)

  // 前台命令运行中：识别为弱证据 provider 并启动读屏。
  startForegroundCommand(terminalView)
  try await waitUntil { session.hasRunningCommand }
  terminalView.onObservedTitleUpdate?(0, "codex")
  try await waitUntil { session.activeAgentProvider != nil }
  #expect(session.activeAgentProvider == .codex)
  #expect(session.isAgentScreenMonitorRunning)

  // 标题变成普通路径，且屏幕没给过 working/blocked 证据 → 撤销。
  terminalView.onObservedTitleUpdate?(0, "mike@mac: ~/src/agent")
  try await waitUntil { session.activeAgentProvider == nil }
  #expect(session.activeAgentProvider == nil)
  #expect(!session.isAgentScreenMonitorRunning)
  #expect(session.agentTaskState == .idle)

  // 再次识别后屏幕出现 working 证据 → 标题变化不再撤销。
  terminalView.onObservedTitleUpdate?(0, "codex")
  try await waitUntil { session.activeAgentProvider == .codex }
  screen.show("• Working (4s • esc to interrupt)\n")
  try await waitUntil { session.agentTaskState == .processing && session.screenDetectionPublished != nil }
  terminalView.onObservedTitleUpdate?(0, "mike@mac: ~/src")
  try await Task.sleep(for: .milliseconds(80))
  #expect(session.activeAgentProvider == .codex)
}

@Test("Claude 启动宽限中收到 hook idle 不通知也不置未读")
@MainActor
func startupGraceHookIdleDoesNotReportCompletion() async throws {
  let (suiteName, defaults) = try agentLifecycleDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.agents.notifyTaskComplete = true
  let recorder = TerminalNotificationRecorder()
  let screen = FakeAgentScreen()
  // 宽限放长，确保 hook idle 落在宽限期内（此时状态暂定 processing）。
  let session = TerminalSession(
    workingDirectory: "/tmp",
    notificationPoster: recorder,
    agentScreenDetectionTiming: .init(
      pollInterval: .milliseconds(20), pendingIdleRecheck: .milliseconds(10),
      startupGrace: .seconds(2))
  )
  session.agentScreenDetectionSourceOverride = screen.source
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }

  // 由 commandStart 首 token 识别 claude → 进入宽限 → processing。
  startForegroundCommand(terminalView)
  try await waitUntil { session.hasRunningCommand }
  terminalView.onObservedTitleUpdate?(0, "✳ Claude Code")
  try await waitUntil { session.activeAgentProvider == .claudeCode }
  #expect(session.agentTaskState == .processing)

  // SessionStart hook 直接报 idle：这不是一轮任务的完成。
  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .claudeCode, signal: .idle))
  #expect(session.agentTaskState == .idle)
  #expect(!session.agentTaskCompletionUnread)
  #expect(recorder.records.isEmpty)

  // 真的处理过一轮再 idle 才算完成。
  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .claudeCode, signal: .processing))
  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .claudeCode, signal: .idle))
  #expect(session.agentTaskCompletionUnread)
  #expect(recorder.records.map(\.notification.title) == ["Agent 任务已完成"])
}

@Test("清单未命中任何规则时，旧的等待输入启发式仍可把兜底 idle 提升为等待输入")
@MainActor
func fallbackIdleKeepsAwaitingInputHeuristic() async throws {
  let (suiteName, defaults) = try agentLifecycleDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)

  // 真实 shell 里跑一个叫 devin 的脚本：打印 `[y/N]` 提示后停住，光标停在提示行上。
  let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-fallback-idle-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: directory) }
  let executable = directory.appendingPathComponent("devin", isDirectory: false)
  try Data("#!/bin/sh\nprintf 'Overwrite config.json? [y/N] '\n/bin/sleep 8\n".utf8)
    .write(to: executable, options: .atomic)
  try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)

  let screen = FakeAgentScreen()
  let session = TerminalSession(
    workingDirectory: directory.path, agentScreenDetectionTiming: fastScreenDetectionTiming)
  session.agentScreenDetectionSourceOverride = screen.source
  _ = try #require(session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }

  // devin 清单没有任何规则覆盖这个提示 → 兜底 idle。
  screen.show("Overwrite config.json? [y/N] ")
  session.send(executable.path)
  try await waitUntil { session.activeAgentProvider == .devin }
  #expect(session.isAgentScreenMonitorRunning)
  try await waitUntil { session.screenDetectionPublished?.isFallbackIdle == true }
  #expect(session.explainAgentDetection()?.fallbackReason == AgentDetectionExplain.defaultKnownAgentIdleFallback)

  // 光标行停在 [y/N] 静默 1.5s 后，启发式补位为等待输入。
  try await waitUntil(.seconds(4)) { session.agentTaskState == .awaitingInput }
  #expect(session.agentTaskState == .awaitingInput)

  // 规则命中的 idle（devin 提示框）以规则为准，启发式不再抬升。
  screen.show(
    "─────────────────────────────────────────────────────\n❭ Ask Devin to build features, fix bugs, or work on\n  your code\n─────────────────────────────────────────────────────\nSWE-1.6               Context: 16k / 200k tokens (7%)")
  try await waitUntil { session.screenDetectionPublished?.isFallbackIdle == false }
  #expect(session.screenDetectionPublished?.isFallbackIdle == false)
  #expect(session.agentTaskState == .idle)
}

@Test("monitor.stop() 解除回调，不再因闭包保留环泄漏")
@MainActor
func monitorStopBreaksRetainCycle() throws {
  let manifest = try #require(AgentDetectionManifestStore.shared.manifest(for: "codex"))
  weak var weakMonitor: AgentScreenDetectionMonitor?
  do {
    let monitor = AgentScreenDetectionMonitor(
      manifest: manifest,
      source: .init(
        readScreen: { "" }, oscTitle: { "" }, oscProgress: { "" },
        contentSequence: { 0 }, processExited: { false }),
      timing: fastScreenDetectionTiming)
    weakMonitor = monitor
    // 模拟旧写法：闭包强捕获 monitor 自身。stop() 必须能切断这条环。
    monitor.onPublish = { _ in _ = monitor }
    monitor.onStartupGraceEnded = { _ = monitor }
    monitor.start()
    monitor.stop()
  }
  #expect(weakMonitor == nil)
}

// hook 一条信号都没到（Claude Code 2.1.x 的常态）：靠 Claude 自己写的会话文件在运行中
// 补绑定 session ID（驱动标题、Fork、结束登记），结束时登记的也是这个 ID。
@Test("没有 hook 时从会话文件绑定 session ID，并在结束时登记 resume")
@MainActor
func agentSessionIsBoundFromSessionFileWithoutHooks() async throws {
  let (suiteName, defaults) = try agentLifecycleDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  let home = FileManager.default.temporaryDirectory
    .appendingPathComponent("AgentLifecycleHome.\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: home) }
  session.agentUsageHomeDirectory = home
  let terminal = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }
  let directory = session.resolvedCurrentWorkingDirectory()

  // 用户敲 `claude` 回车：只有命令首词，没有任何 hook。
  terminal.onShellIntegrationEvent?(.promptStart)
  terminal.onShellIntegrationEvent?(.inputStart)
  terminal.onAutocompleteInput?(Array("claude\n".utf8)[...])
  terminal.onShellIntegrationEvent?(.commandStart)
  #expect(session.activeAgentProvider == .claudeCode)
  #expect(session.activeAgentSessionID == nil)

  // Claude 在首条 prompt 后写出会话文件。
  let projectDirectory = home.appendingPathComponent(
    ".claude/projects/\(AgentSessionFileLocator.claudeProjectDirectoryName(for: directory))",
    isDirectory: true)
  try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
  try "{}".write(
    to: projectDirectory.appendingPathComponent("file-sess-1.jsonl"), atomically: true, encoding: .utf8)
  // 后台任务首次重试在 3s 后。
  for _ in 0..<80 where session.activeAgentSessionID == nil {
    try await Task.sleep(for: .milliseconds(100))
  }
  #expect(session.activeAgentSessionID == "file-sess-1")

  terminal.onShellIntegrationEvent?(.commandFinished(exitStatus: 0))
  #expect(model.latestProjectAgentSession(for: directory)?.sessionID == "file-sess-1")
  #expect(model.projectAgentResumeSuggestion(for: directory)?.command == "claude --resume file-sess-1")
}

// 目录里有旧会话但本次运行没写新文件（例如 `claude --version`）：登记为「续上最近一次」。
@Test("本次运行没有新会话文件时退化为 claude --continue")
@MainActor
func agentSessionFallsBackToContinueLatest() throws {
  let (suiteName, defaults) = try agentLifecycleDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  let home = FileManager.default.temporaryDirectory
    .appendingPathComponent("AgentLifecycleHome.\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: home) }
  session.agentUsageHomeDirectory = home
  let terminal = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }
  let directory = session.resolvedCurrentWorkingDirectory()
  let projectDirectory = home.appendingPathComponent(
    ".claude/projects/\(AgentSessionFileLocator.claudeProjectDirectoryName(for: directory))",
    isDirectory: true)
  try FileManager.default.createDirectory(at: projectDirectory, withIntermediateDirectories: true)
  let old = projectDirectory.appendingPathComponent("old-sess.jsonl")
  try "{}".write(to: old, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.modificationDate: Date().addingTimeInterval(-3_600)], ofItemAtPath: old.path)

  terminal.onShellIntegrationEvent?(.promptStart)
  terminal.onShellIntegrationEvent?(.inputStart)
  terminal.onAutocompleteInput?(Array("claude\n".utf8)[...])
  terminal.onShellIntegrationEvent?(.commandStart)
  terminal.onShellIntegrationEvent?(.commandFinished(exitStatus: 0))
  let record = try #require(model.latestProjectAgentSession(for: directory))
  #expect(record.sessionID == nil)
  #expect(model.projectAgentResumeSuggestion(for: directory)?.command == "claude --continue")
  #expect(model.notice?.contains("claude --continue") == true)
}

// 用户最常见的「结束」是直接关掉 Pane：没有 commandFinished，也没有 child-exited 回调。
// stop() 必须在拆 surface 前登记会话，且只登记一次。
@Test("关闭仍在运行 Agent 的 Pane 也登记项目会话")
@MainActor
func closingPaneWithRunningAgentRecordsProjectSession() throws {
  let (suiteName, defaults) = try agentLifecycleDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  let terminal = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  let directory = session.resolvedCurrentWorkingDirectory()
  var endedCount = 0
  let upstream = session.onAgentSessionEnded
  session.onAgentSessionEnded = { provider, sessionID in
    endedCount += 1
    upstream?(provider, sessionID)
  }

  terminal.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .claudeCode, signal: .processing, sessionID: "sess-close"))
  #expect(model.latestProjectAgentSession(for: directory) == nil)
  session.stop(immediately: true)
  #expect(model.latestProjectAgentSession(for: directory)?.sessionID == "sess-close")
  #expect(endedCount == 1)
}

// Agent 结束 → 登记项目最近会话并提示 resume 命令 → 同目录补全首选项就是这条命令。
@Test("Agent 结束后登记项目会话，同目录补全首选 resume 命令")
@MainActor
func endedAgentSessionIsRecordedAndSuggestedForProject() throws {
  let (suiteName, defaults) = try agentLifecycleDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  // 空 home：本机真实的 ~/.claude 里有该目录的会话文件，会让「无 ID」分支走到文件定位。
  let home = FileManager.default.temporaryDirectory
    .appendingPathComponent("AgentLifecycleHome.\(UUID().uuidString)", isDirectory: true)
  defer { try? FileManager.default.removeItem(at: home) }
  session.agentUsageHomeDirectory = home
  let terminal = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }
  let directory = session.resolvedCurrentWorkingDirectory()

  // 没有 session ID、也没有任何会话文件的结束不登记：无 ID 可 resume，也无「最近一次」可续。
  terminal.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .claudeCode, signal: .processing, sessionID: nil))
  terminal.onShellIntegrationEvent?(.commandFinished(exitStatus: 0))
  #expect(model.latestProjectAgentSession(for: directory) == nil)
  #expect(model.projectAgentResumeSuggestion(for: directory) == nil)

  terminal.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .claudeCode, signal: .processing, sessionID: "sess-42"))
  terminal.onShellIntegrationEvent?(.commandFinished(exitStatus: 0))
  let record = try #require(model.latestProjectAgentSession(for: directory))
  #expect(record.provider == .claudeCode)
  #expect(record.sessionID == "sess-42")
  let notice = try #require(model.notice)
  #expect(notice.contains("--resume"), "notice: \(notice)")
  #expect(notice.contains("sess-42"), "notice: \(notice)")

  // 补全首选项：整条 resume 命令 + provider 描述；其它目录没有。
  let suggestion = try #require(model.projectAgentResumeSuggestion(for: directory))
  #expect(suggestion.command == "claude --resume sess-42")
  #expect(suggestion.description.contains("Claude Code"))
  #expect(model.projectAgentResumeSuggestion(for: "/private/tmp") == nil)
  // 终端 Pane 的提供者链路已接通（Tab → Session）。
  #expect(session.projectCommandSuggestionProvider?(directory) == suggestion)

  // 记录随 defaults 持久化，新 AppModel 也能读到。
  let reloaded = AppModel(defaults: defaults)
  #expect(reloaded.latestProjectAgentSession(for: directory)?.sessionID == "sess-42")
}
