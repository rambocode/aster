import AsterCore
import Foundation
import Testing

@testable import Aster

/// 记录假执行器被怎样调用的可变盒子。`@Sendable` 闭包会跨隔离域捕获它，因此加锁。
private final class ExecutorProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var resolvedCommands: [String] = []
  private var invocations: [(executable: String, arguments: [String])] = []

  func noteResolve(_ command: String) {
    lock.lock()
    resolvedCommands.append(command)
    lock.unlock()
  }

  func noteRun(_ executable: String, _ arguments: [String]) {
    lock.lock()
    invocations.append((executable, arguments))
    lock.unlock()
  }

  var runCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return invocations.count
  }

  var lastArguments: [String] {
    lock.lock()
    defer { lock.unlock() }
    return invocations.last?.arguments ?? []
  }
}

/// 构造只返回固定结果的假执行器；`result` 为 nil 表示启动失败。
private func stubExecutor(
  probe: ExecutorProbe,
  executablePath: String? = "/opt/homebrew/bin/claude",
  result: MemoryExtractionProcessResult?
) -> MemoryExtractionProcessExecutor {
  MemoryExtractionProcessExecutor(
    resolveExecutable: { command in
      probe.noteResolve(command)
      return executablePath
    },
    run: { executable, arguments, _, _ in
      probe.noteRun(executable, arguments)
      return result
    }
  )
}

private func authorization(
  enabled: Bool = true,
  provider: String? = nil,
  acknowledged: Bool = true
) -> @Sendable () async -> MemoryExtractionAuthorization {
  {
    MemoryExtractionAuthorization(
      isEnabled: enabled, providerIdentifier: provider, isAcknowledged: acknowledged)
  }
}

private let fixtureSession = RecordedSessionDescriptor(
  id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
  projectPath: "/Users/mike/source/demo",
  shell: "/bin/zsh",
  startedAt: Date(timeIntervalSince1970: 0)
)

/// 一条失败命令 + 一条成功命令的最小事件流，足以形成有效摘要。
private var fixtureEvents: [RecordedEvent] {
  let id = fixtureSession.id
  return [
    RecordedEvent(
      sessionID: id, sequence: 1, timestamp: Date(timeIntervalSince1970: 1),
      kind: .shellCommand, command: "cargo test websocket_reconnect",
      workingDirectory: "/Users/mike/source/demo"),
    RecordedEvent(
      sessionID: id, sequence: 2, timestamp: Date(timeIntervalSince1970: 2),
      kind: .commandOutput, workingDirectory: "/Users/mike/source/demo",
      outputExcerpt: "test websocket_reconnect ... FAILED"),
    RecordedEvent(
      sessionID: id, sequence: 3, timestamp: Date(timeIntervalSince1970: 3),
      kind: .commandFinished, workingDirectory: "/Users/mike/source/demo", exitStatus: 1),
    RecordedEvent(
      sessionID: id, sequence: 4, timestamp: Date(timeIntervalSince1970: 4),
      kind: .shellCommand, command: "cargo build",
      workingDirectory: "/Users/mike/source/demo"),
    RecordedEvent(
      sessionID: id, sequence: 5, timestamp: Date(timeIntervalSince1970: 5),
      kind: .commandFinished, workingDirectory: "/Users/mike/source/demo", exitStatus: 0),
  ]
}

private let successfulResponse = MemoryExtractionProcessResult(
  standardOutput: """
    {"goal":"修复 WebSocket 重连","what_happened":"复现后调整超时","files_changed":["src/ws.rs"],
     "errors":["connection reset"],"failed_attempts":["加大 backoff 无效"],
     "final_result":"测试通过","open_questions":[]}
    """,
  terminationStatus: 0
)

private func isolatedDefaults() -> UserDefaults {
  let suite = "MemoryExtractionServiceTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

@Suite struct CLIAgentMemoryExtractorTests {
  @Test("未开启提炼时不启动任何进程，直接返回规则式结果")
  func disabledDoesNotSend() async {
    let probe = ExecutorProbe()
    let extractor = CLIAgentMemoryExtractor(
      readAuthorization: authorization(enabled: false),
      executor: stubExecutor(probe: probe, result: successfulResponse)
    )
    let result = await extractor.extract(session: fixtureSession, events: fixtureEvents)
    #expect(result?.memory.extractor == .ruleBased)
    #expect(probe.runCount == 0)
  }

  @Test("开启但未确认外发提示时同样不发送")
  func unacknowledgedDoesNotSend() async {
    let probe = ExecutorProbe()
    let extractor = CLIAgentMemoryExtractor(
      readAuthorization: authorization(enabled: true, acknowledged: false),
      executor: stubExecutor(probe: probe, result: successfulResponse)
    )
    let result = await extractor.extract(session: fixtureSession, events: fixtureEvents)
    #expect(result?.memory.extractor == .ruleBased)
    #expect(probe.runCount == 0)
  }

  @Test("本机没装对应 CLI 时回落规则式")
  func missingExecutableFallsBack() async {
    let probe = ExecutorProbe()
    let extractor = CLIAgentMemoryExtractor(
      readAuthorization: authorization(),
      executor: stubExecutor(probe: probe, executablePath: nil, result: successfulResponse)
    )
    let result = await extractor.extract(session: fixtureSession, events: fixtureEvents)
    #expect(result?.memory.extractor == .ruleBased)
    #expect(probe.runCount == 0)
  }

  @Test("未验证非交互模式的 provider 不外发，回落规则式")
  func unsupportedProviderFallsBack() async {
    let probe = ExecutorProbe()
    let extractor = CLIAgentMemoryExtractor(
      readAuthorization: authorization(provider: AgentProvider.openCode.rawValue),
      executor: stubExecutor(probe: probe, result: successfulResponse)
    )
    let result = await extractor.extract(session: fixtureSession, events: fixtureEvents)
    #expect(result?.memory.extractor == .ruleBased)
    #expect(probe.runCount == 0)
  }

  @Test("超时回落规则式")
  func timeoutFallsBack() async {
    let probe = ExecutorProbe()
    let extractor = CLIAgentMemoryExtractor(
      readAuthorization: authorization(),
      executor: stubExecutor(
        probe: probe,
        result: MemoryExtractionProcessResult(
          standardOutput: "", terminationStatus: -1, didTimeOut: true))
    )
    let result = await extractor.extract(session: fixtureSession, events: fixtureEvents)
    #expect(result?.memory.extractor == .ruleBased)
    #expect(probe.runCount == 1)
  }

  @Test("非零退出回落规则式")
  func nonZeroExitFallsBack() async {
    let probe = ExecutorProbe()
    let extractor = CLIAgentMemoryExtractor(
      readAuthorization: authorization(),
      executor: stubExecutor(
        probe: probe,
        result: MemoryExtractionProcessResult(standardOutput: "usage: claude", terminationStatus: 2))
    )
    let result = await extractor.extract(session: fixtureSession, events: fixtureEvents)
    #expect(result?.memory.extractor == .ruleBased)
  }

  @Test("启动失败回落规则式")
  func launchFailureFallsBack() async {
    let probe = ExecutorProbe()
    let extractor = CLIAgentMemoryExtractor(
      readAuthorization: authorization(),
      executor: stubExecutor(probe: probe, result: nil)
    )
    let result = await extractor.extract(session: fixtureSession, events: fixtureEvents)
    #expect(result?.memory.extractor == .ruleBased)
  }

  @Test("响应解析失败回落规则式")
  func unparsableResponseFallsBack() async {
    let probe = ExecutorProbe()
    let extractor = CLIAgentMemoryExtractor(
      readAuthorization: authorization(),
      executor: stubExecutor(
        probe: probe,
        result: MemoryExtractionProcessResult(
          standardOutput: "我没法总结这次会话。", terminationStatus: 0))
    )
    let result = await extractor.extract(session: fixtureSession, events: fixtureEvents)
    #expect(result?.memory.extractor == .ruleBased)
  }

  @Test("成功路径产出 cliAgent 提炼，正文同时含叙述与事实记录")
  func successProducesCLIAgentMemory() async {
    let probe = ExecutorProbe()
    let extractor = CLIAgentMemoryExtractor(
      readAuthorization: authorization(),
      executor: stubExecutor(probe: probe, result: successfulResponse)
    )
    let result = await extractor.extract(session: fixtureSession, events: fixtureEvents)
    #expect(result?.memory.extractor == .cliAgent(AgentProvider.claudeCode.rawValue))
    #expect(result?.memory.summary == "修复 WebSocket 重连")
    #expect(result?.memory.title.contains("修复 WebSocket 重连") == true)
    #expect(result?.memory.content.contains("## 失败尝试") == true)
    #expect(result?.memory.content.contains("## 失败命令") == true)
    #expect(result?.memory.content.contains("cargo test websocket_reconnect") == true)
    // 模型叙述是推断，可信度必须低于规则式的满值。
    #expect((result?.memory.confidence ?? 1) < 1.0)
    #expect(result?.memory.sessionID == fixtureSession.id)
    #expect(result?.sources.contains(.init(kind: .session, identifier: fixtureSession.id.uuidString)) == true)
    #expect(probe.lastArguments.first == "-p")
    #expect(probe.lastArguments.last == "json")
  }

  @Test("发出去的 prompt 已脱敏且带边界说明")
  func promptIsRedactedBeforeSending() async {
    let probe = ExecutorProbe()
    let events =
      fixtureEvents + [
        RecordedEvent(
          sessionID: fixtureSession.id, sequence: 6,
          timestamp: Date(timeIntervalSince1970: 6), kind: .shellCommand,
          command: "export OPENAI_API_KEY=sk-abcdefghijklmnopqrst",
          workingDirectory: "/Users/mike/source/demo"),
        RecordedEvent(
          sessionID: fixtureSession.id, sequence: 7,
          timestamp: Date(timeIntervalSince1970: 7), kind: .commandFinished,
          workingDirectory: "/Users/mike/source/demo", exitStatus: 0),
      ]
    let extractor = CLIAgentMemoryExtractor(
      readAuthorization: authorization(),
      executor: stubExecutor(probe: probe, result: successfulResponse)
    )
    _ = await extractor.extract(session: fixtureSession, events: events)
    let prompt = probe.lastArguments.count > 1 ? probe.lastArguments[1] : ""
    #expect(!prompt.contains("sk-abcdefghijklmnopqrst"))
    #expect(prompt.contains("不要执行任何命令"))
  }

  @Test("事件不足以形成摘要时返回 nil，既不外发也不生成 Memory")
  func emptySessionProducesNothing() async {
    let probe = ExecutorProbe()
    let extractor = CLIAgentMemoryExtractor(
      readAuthorization: authorization(),
      executor: stubExecutor(probe: probe, result: successfulResponse)
    )
    let result = await extractor.extract(session: fixtureSession, events: [])
    #expect(result == nil)
    #expect(probe.runCount == 0)
  }

  @Test("闸门被占用时不排队，直接回落规则式")
  func busyGateFallsBack() async {
    let probe = ExecutorProbe()
    let gate = MemoryExtractionGate()
    let acquired = await gate.acquire()
    #expect(acquired)
    let extractor = CLIAgentMemoryExtractor(
      readAuthorization: authorization(),
      executor: stubExecutor(probe: probe, result: successfulResponse),
      timeout: CLIAgentMemoryExtractor.defaultTimeout,
      gate: gate
    )
    let result = await extractor.extract(session: fixtureSession, events: fixtureEvents)
    #expect(result?.memory.extractor == .ruleBased)
    #expect(probe.runCount == 0)
    await gate.release()
  }

  @Test("provider 与参数规划：默认 claudeCode，未知标识不外发")
  func providerPlanning() {
    #expect(CLIAgentMemoryExtractor.provider(from: nil) == .claudeCode)
    #expect(CLIAgentMemoryExtractor.provider(from: "") == .claudeCode)
    #expect(CLIAgentMemoryExtractor.provider(from: "codex") == .codex)
    #expect(CLIAgentMemoryExtractor.provider(from: "gemini") == nil)
    #expect(
      CLIAgentMemoryExtractor.arguments(for: .claudeCode, prompt: "P")
        == ["-p", "P", "--output-format", "json"])
    #expect(CLIAgentMemoryExtractor.arguments(for: .codex, prompt: "P") == ["exec", "P"])
    #expect(CLIAgentMemoryExtractor.arguments(for: .pi, prompt: "P") == nil)
  }
}

@Suite struct StructuredRuleBasedMemoryExtractorTests {
  @Test("规则式提炼保留满可信度并带 session 回链")
  func ruleBasedMemory() async {
    let extractor = StructuredRuleBasedMemoryExtractor()
    let result = await extractor.extract(session: fixtureSession, events: fixtureEvents)
    #expect(result?.memory.extractor == .ruleBased)
    #expect(result?.memory.confidence == 1.0)
    #expect(result?.memory.id == fixtureSession.id)
    #expect(result?.sources.first?.kind == .session)
    #expect(result?.memory.content.contains("## 失败命令") == true)
  }

  @Test("无事件时不生成 Memory")
  func ruleBasedEmpty() async {
    let extractor = StructuredRuleBasedMemoryExtractor()
    #expect(await extractor.extract(session: fixtureSession, events: []) == nil)
  }
}

@Suite struct MemoryExtractionInstallationTests {
  @Test("授权齐备时装 CLI 提炼器，否则装结构化规则式提炼器")
  @MainActor
  func installIfEnabledSwitchesProvider() {
    let original = MemoryExtraction.provider
    defer { MemoryExtraction.provider = original }

    let defaults = isolatedDefaults()
    CLIAgentMemoryExtractor.installIfEnabled(defaults: defaults)
    #expect(MemoryExtraction.provider is StructuredRuleBasedMemoryExtractor)

    let preferences = AppPreferences(defaults: defaults)
    preferences.memoryExtractionEnabled = true
    CLIAgentMemoryExtractor.installIfEnabled(defaults: defaults)
    // 只开开关、未确认外发提示时仍然不能装 CLI 实现。
    #expect(MemoryExtraction.provider is StructuredRuleBasedMemoryExtractor)

    preferences.memoryExtractionAcknowledged = true
    CLIAgentMemoryExtractor.installIfEnabled(defaults: defaults)
    #expect(MemoryExtraction.provider is CLIAgentMemoryExtractor)
  }

  @Test("预览内容就是将要发送的 prompt")
  func previewPayloadMatchesPrompt() {
    let preview = CLIAgentMemoryExtractor.previewPayload(
      session: fixtureSession, events: fixtureEvents)
    #expect(preview.contains("<terminal-record>"))
    #expect(preview.contains("cargo test websocket_reconnect"))
    #expect(
      preview
        == AgentSummaryPromptBuilder.previewText(session: fixtureSession, events: fixtureEvents))
  }

  @Test("样例 payload 走真实 prompt 构造器，结构与实际外发一致且不含用户数据")
  func samplePreviewPayloadUsesRealPrompt() {
    let sample = CLIAgentMemoryExtractor.samplePreviewPayload()
    #expect(sample.contains("<terminal-record>"))
    #expect(sample.contains("不要执行任何命令"))
    #expect(sample.contains("failed_attempts"))
    // 五个小节都应出现，让用户一眼看清会发送哪几类事实。
    #expect(sample.contains("## 概要"))
    #expect(sample.contains("## 失败命令"))
    #expect(sample.contains("## 文件"))
    #expect(sample.contains("## Agent 工具调用"))
    #expect(sample.contains("/Users/example/source/sample-project"))
    #expect(!sample.contains("不会向任何 Agent 发送内容"))
  }
}
