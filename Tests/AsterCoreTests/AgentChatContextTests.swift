import Testing

@testable import AsterCore

@Test func sendToChatRedactsCommonSecretsAndRemovesTerminalControlCharacters() throws {
  var builder = AgentChatContextBuilder(
    budget: AgentChatContextBudget(
      maximumItems: 4,
      maximumTotalBytes: 2_048,
      maximumItemBytes: 2_048,
      reservedPromptBytes: 128
    )
  )
  let content = """
    Authorization: Bearer very-secret-token
    password=hunter2
    OPENAI_API_KEY=sk-abcdefghijklmnopqrstuvwxyz
    \u{001B}[31mfailed\u{0007}
    """

  let chip = try builder.add(source: .terminalSelection, content: content)

  #expect(chip.redactionCount == 3)
  #expect(!chip.content.contains("very-secret-token"))
  #expect(!chip.content.contains("hunter2"))
  #expect(!chip.content.contains("sk-abcdefghijklmnopqrstuvwxyz"))
  #expect(!chip.content.contains("\u{001B}"))
  #expect(!chip.content.contains("\u{0007}"))
  #expect(builder.renderedForPrompt.contains("untrusted-context"))
}

@Test func sendToChatBudgetsContextAfterRedactionAndTruncatesOnUTF8Boundaries() throws {
  var builder = AgentChatContextBuilder(
    budget: AgentChatContextBudget(
      maximumItems: 2,
      maximumTotalBytes: 128,
      maximumItemBytes: 16,
      reservedPromptBytes: 8
    )
  )

  let chip = try builder.add(
    source: .lastCommandOutput,
    content: "1234567890🙂abcdefghij"
  )

  #expect(chip.isTruncated)
  #expect(chip.content == "1234567890🙂ab")
  #expect(chip.content.utf8.count <= 16)
  #expect(builder.usedContextBytes <= 120)
}

@Test func sendToChatRejectsEmptyContentItemOverflowAndExhaustedBudgets() throws {
  var builder = AgentChatContextBuilder(
    budget: AgentChatContextBudget(
      maximumItems: 1,
      maximumTotalBytes: 128,
      maximumItemBytes: 8,
      reservedPromptBytes: 8
    )
  )

  #expect(throws: AgentChatContextError.emptyContent) {
    try builder.add(source: .fileSelection, content: "\u{001B}")
  }
  _ = try builder.add(source: .fileSelection, content: "12345678")
  #expect(throws: AgentChatContextError.tooManyItems(maximum: 1)) {
    try builder.add(source: .terminalSelection, content: "next")
  }

  var exhausted = AgentChatContextBuilder(
    budget: AgentChatContextBudget(
      maximumItems: 2,
      maximumTotalBytes: 8,
      maximumItemBytes: 8,
      reservedPromptBytes: 8
    )
  )
  #expect(throws: AgentChatContextError.contextBudgetExhausted) {
    try exhausted.add(source: .terminalSelection, content: "x")
  }
}
