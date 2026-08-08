import Foundation

public struct AgentQueuedPrompt: Identifiable, Equatable, Sendable {
  public let id: UUID
  public var text: String

  public init(id: UUID = UUID(), text: String) {
    self.id = id
    self.text = text
  }
}

/// Readiness 由 shell integration 或 Agent 生命周期层提供。普通 shell 必须同时满足
/// idle、输入区为空、非全屏 TUI；Agent 则仅在折叠状态为 idle 时可开始下一轮。
public enum AgentPromptDispatchReadiness: Equatable, Sendable {
  case agent(AgentTaskState)
  case shell(promptIsIdle: Bool, inputIsEmpty: Bool, isFullScreenProgram: Bool)

  public var canDispatch: Bool {
    switch self {
    case .agent(let state):
      state == .idle
    case .shell(let promptIsIdle, let inputIsEmpty, let isFullScreenProgram):
      promptIsIdle && inputIsEmpty && !isFullScreenProgram
    }
  }
}

public enum AgentPromptQueueError: Error, Equatable {
  case emptyPrompt
  case promptTooLarge(maximumBytes: Int)
  case queueFull(maximumEntries: Int)
  case duplicateIdentifier
  case pendingPromptNotFound
  case invalidDestinationIndex
  case inFlightMismatch
}

/// 严格单 in-flight 的串行队列。`dispatchNext` 只产生“应发送哪个 prompt”的领域
/// 决策；调用方完成真实发送后，必须等目标 turn 结束再调用 `completeInFlight`。
public struct AgentPromptQueue: Equatable, Sendable {
  public private(set) var pending: [AgentQueuedPrompt]
  public private(set) var inFlight: AgentQueuedPrompt?
  /// 只有目标 Agent 已明确离开 idle，后续 idle 才能代表当前 turn 完成。该位防止
  /// prompt 写入 PTY 与 lifecycle hook 之间的短窗口把下一条 prompt 提前发送。
  public private(set) var inFlightHasStarted = false
  public let maximumEntries: Int
  public let maximumPromptBytes: Int

  public init(
    maximumEntries: Int = 128,
    maximumPromptBytes: Int = 64 * 1_024
  ) {
    self.maximumEntries = max(maximumEntries, 1)
    self.maximumPromptBytes = max(maximumPromptBytes, 1)
    pending = []
  }

  public mutating func enqueue(_ prompt: AgentQueuedPrompt) throws {
    try validate(prompt.text)
    let occupiedCount = pending.count + (inFlight == nil ? 0 : 1)
    guard occupiedCount < maximumEntries else {
      throw AgentPromptQueueError.queueFull(maximumEntries: maximumEntries)
    }
    guard inFlight?.id != prompt.id, !pending.contains(where: { $0.id == prompt.id }) else {
      throw AgentPromptQueueError.duplicateIdentifier
    }
    pending.append(prompt)
  }

  public mutating func edit(id: UUID, text: String) throws {
    try validate(text)
    guard let index = pending.firstIndex(where: { $0.id == id }) else {
      throw AgentPromptQueueError.pendingPromptNotFound
    }
    pending[index].text = text
  }

  public mutating func move(id: UUID, to destinationIndex: Int) throws {
    guard pending.indices.contains(destinationIndex) else {
      throw AgentPromptQueueError.invalidDestinationIndex
    }
    guard let sourceIndex = pending.firstIndex(where: { $0.id == id }) else {
      throw AgentPromptQueueError.pendingPromptNotFound
    }
    let prompt = pending.remove(at: sourceIndex)
    pending.insert(prompt, at: destinationIndex)
  }

  @discardableResult
  public mutating func remove(id: UUID) -> AgentQueuedPrompt? {
    guard let index = pending.firstIndex(where: { $0.id == id }) else { return nil }
    return pending.remove(at: index)
  }

  /// Readiness 不满足、已有 in-flight 或队列为空时不改变状态。
  @discardableResult
  public mutating func dispatchNext(
    when readiness: AgentPromptDispatchReadiness
  ) -> AgentQueuedPrompt? {
    guard readiness.canDispatch, inFlight == nil, !pending.isEmpty else { return nil }
    let prompt = pending.removeFirst()
    inFlight = prompt
    inFlightHasStarted = false
    return prompt
  }

  /// 派发决策成立但真实写入失败时的回滚。prompt 回到队首而不是队尾，保持 FIFO 与
  /// 用户看到的顺序一致；没有 in-flight 时是空操作。
  @discardableResult
  public mutating func restoreInFlight() -> AgentQueuedPrompt? {
    guard let prompt = inFlight else { return nil }
    inFlight = nil
    inFlightHasStarted = false
    pending.insert(prompt, at: 0)
    return prompt
  }

  /// 消费 Agent 的折叠生命周期。返回值仅在观察到当前 in-flight 从非 idle 回到
  /// idle 时产生；调用方可随后安全派发下一项，而不能把发送前残留的 idle 当完成。
  @discardableResult
  public mutating func observeAgentState(_ state: AgentTaskState) -> AgentQueuedPrompt? {
    guard let inFlight else { return nil }
    switch state {
    case .processing, .awaitingInput:
      inFlightHasStarted = true
      return nil
    case .idle:
      guard inFlightHasStarted else { return nil }
      self.inFlight = nil
      inFlightHasStarted = false
      return inFlight
    }
  }

  /// ID 必须与当前 in-flight 一致，防止迟到的上一轮完成事件释放了新一轮锁。
  public mutating func completeInFlight(id: UUID) throws {
    guard inFlight?.id == id else { throw AgentPromptQueueError.inFlightMismatch }
    inFlight = nil
    inFlightHasStarted = false
  }

  private func validate(_ text: String) throws {
    guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw AgentPromptQueueError.emptyPrompt
    }
    guard text.utf8.count <= maximumPromptBytes else {
      throw AgentPromptQueueError.promptTooLarge(maximumBytes: maximumPromptBytes)
    }
  }
}
