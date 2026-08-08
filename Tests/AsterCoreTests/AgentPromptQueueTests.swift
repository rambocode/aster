import Foundation
import Testing

@testable import AsterCore

@Test func promptQueueDispatchesOneAgentTurnAtATimeInFIFOOrder() throws {
  let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  var queue = AgentPromptQueue()
  try queue.enqueue(AgentQueuedPrompt(id: firstID, text: "build"))
  try queue.enqueue(AgentQueuedPrompt(id: secondID, text: "test"))

  #expect(queue.dispatchNext(when: .agent(.processing)) == nil)
  #expect(queue.dispatchNext(when: .agent(.idle))?.id == firstID)
  #expect(queue.dispatchNext(when: .agent(.idle)) == nil)
  #expect(queue.inFlight?.id == firstID)
  #expect(throws: AgentPromptQueueError.inFlightMismatch) {
    try queue.completeInFlight(id: secondID)
  }

  try queue.completeInFlight(id: firstID)
  #expect(queue.dispatchNext(when: .agent(.awaitingInput)) == nil)
  #expect(queue.dispatchNext(when: .agent(.idle))?.id == secondID)
}

@Test func promptQueueCompletesOnlyAfterObservedProcessingReturnsToIdle() throws {
  let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  var queue = AgentPromptQueue()
  try queue.enqueue(AgentQueuedPrompt(id: firstID, text: "first"))
  try queue.enqueue(AgentQueuedPrompt(id: secondID, text: "second"))

  #expect(queue.dispatchNext(when: .agent(.idle))?.id == firstID)
  // 入队时仍处于上一帧 idle，不能把它误认为第一条 prompt 已完成。
  #expect(queue.observeAgentState(.idle) == nil)
  #expect(queue.inFlight?.id == firstID)
  #expect(queue.dispatchNext(when: .agent(.idle)) == nil)

  #expect(queue.observeAgentState(.processing) == nil)
  #expect(queue.observeAgentState(.awaitingInput) == nil)
  #expect(queue.observeAgentState(.idle)?.id == firstID)
  #expect(queue.dispatchNext(when: .agent(.idle))?.id == secondID)
}

@Test func promptQueueRequiresAnIdleEmptyShellPromptOutsideFullScreenPrograms() throws {
  var queue = AgentPromptQueue()
  try queue.enqueue(AgentQueuedPrompt(text: "git status"))

  #expect(
    queue.dispatchNext(
      when: .shell(promptIsIdle: true, inputIsEmpty: true, isFullScreenProgram: true)
    ) == nil
  )
  #expect(
    queue.dispatchNext(
      when: .shell(promptIsIdle: true, inputIsEmpty: false, isFullScreenProgram: false)
    ) == nil
  )
  #expect(
    queue.dispatchNext(
      when: .shell(promptIsIdle: true, inputIsEmpty: true, isFullScreenProgram: false)
    )?.text == "git status"
  )
}

@Test func promptQueueSupportsEditingReorderingAndRemovingPendingItemsOnly() throws {
  let firstID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
  let secondID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
  var queue = AgentPromptQueue()
  try queue.enqueue(AgentQueuedPrompt(id: firstID, text: "first"))
  try queue.enqueue(AgentQueuedPrompt(id: secondID, text: "second"))

  try queue.move(id: secondID, to: 0)
  try queue.edit(id: secondID, text: "updated")
  #expect(queue.pending.map(\.text) == ["updated", "first"])
  #expect(queue.remove(id: firstID)?.text == "first")
  #expect(queue.pending.map(\.id) == [secondID])
}

@Test func promptQueueEnforcesEntryAndPromptBudgets() throws {
  var queue = AgentPromptQueue(maximumEntries: 1, maximumPromptBytes: 4)

  #expect(throws: AgentPromptQueueError.promptTooLarge(maximumBytes: 4)) {
    try queue.enqueue(AgentQueuedPrompt(text: "12345"))
  }
  try queue.enqueue(AgentQueuedPrompt(text: "1234"))
  #expect(throws: AgentPromptQueueError.queueFull(maximumEntries: 1)) {
    try queue.enqueue(AgentQueuedPrompt(text: "next"))
  }
}

@Test func promptQueueCountsTheInFlightPromptAgainstItsCapacity() throws {
  var queue = AgentPromptQueue(maximumEntries: 1, maximumPromptBytes: 16)
  try queue.enqueue(AgentQueuedPrompt(text: "first"))
  _ = queue.dispatchNext(when: .agent(.idle))

  #expect(throws: AgentPromptQueueError.queueFull(maximumEntries: 1)) {
    try queue.enqueue(AgentQueuedPrompt(text: "second"))
  }
}
