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

  // 直接触发终端视图已经安装的用户输入回调，覆盖真实输入链路而不依赖键盘 UI 自动化。
  terminalView.onTerminalUserInput?()
  let submittedSequence = try agentLifecycleSequence(of: session)
  #expect(session.agentTaskState == .processing)
  #expect(submittedSequence == awaitingSequence + 1)

  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .idle)
  )
  #expect(session.agentTaskState == .idle)
  #expect(try agentLifecycleSequence(of: session) == submittedSequence + 1)
}

/// sequence 是 `TerminalSession` 的私有实现细节；测试只读反射既能验证单调性，也不会
/// 为测试向生产类型新增接口。字段改名会明确要求同步审视这条生命周期约束。
private func agentLifecycleSequence(of session: TerminalSession) throws -> UInt64 {
  let sequence = Mirror(reflecting: session).children.first {
    $0.label == "agentLifecycleSequence"
  }?.value as? UInt64
  return try #require(sequence)
}
