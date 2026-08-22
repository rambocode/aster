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
