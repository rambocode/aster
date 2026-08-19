import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

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
  #expect(NSApp.dockTile.contentView != nil)
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
