import Testing

@testable import AsterCore

@Test("Agent 终端指令只接受受支持 Provider 与完整状态")
func agentTerminalDirectiveParsesBoundedLifecycleSignal() {
  #expect(
    AgentTerminalDirective(payload: "AgentState=processing;Provider=codex")
      == .init(provider: .codex, signal: .processing)
  )
  #expect(
    AgentTerminalDirective(payload: "AgentState=awaiting-input;Provider=claudeCode")
      == .init(provider: .claudeCode, signal: .awaitingInput)
  )
  #expect(AgentTerminalDirective(payload: "AgentState=idle;Provider=unknown") == nil)
  #expect(AgentTerminalDirective(payload: "AgentState=idle") == nil)
}

@Test func taskStateFoldingUsesAttentionFirstPriority() {
  #expect(AgentTaskState.fold(processing: false, awaitingInput: false) == .idle)
  #expect(AgentTaskState.fold(processing: true, awaitingInput: false) == .processing)
  #expect(AgentTaskState.fold(processing: false, awaitingInput: true) == .awaitingInput)
  #expect(AgentTaskState.fold(processing: true, awaitingInput: true) == .awaitingInput)
}

@Test func taskStateReducerIgnoresStaleSignalsAndReturnsToProcessingAfterInput() {
  var reducer = AgentTaskStateReducer()

  #expect(reducer.consume(AgentTaskStateEvent(sequence: 2, signal: .processing)) == .processing)
  #expect(reducer.consume(AgentTaskStateEvent(sequence: 1, signal: .idle)) == .processing)
  #expect(
    reducer.consume(AgentTaskStateEvent(sequence: 3, signal: .awaitingInput))
      == .awaitingInput
  )
  #expect(
    reducer.consume(AgentTaskStateEvent(sequence: 4, signal: .inputSubmitted))
      == .processing
  )
  #expect(reducer.consume(AgentTaskStateEvent(sequence: 5, signal: .idle)) == .idle)
  #expect(reducer.lastAcceptedSequence == 5)
}
