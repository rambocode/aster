/// Agent 生命周期折叠后的稳定状态。它不包含 PID 或 IPC 连接等运行时对象。
public enum AgentTaskState: String, Codable, Equatable, Sendable {
  case processing
  case idle
  case awaitingInput

  /// awaiting-input 对用户最需要关注，即使 provider 同时尚未清掉 processing 标志，
  /// 也优先展示等待状态；其余情况才区分 processing 与 idle。
  public static func fold(processing: Bool, awaitingInput: Bool) -> AgentTaskState {
    if awaitingInput { return .awaitingInput }
    return processing ? .processing : .idle
  }
}

public enum AgentTaskStateSignal: Equatable, Sendable {
  case processing
  case idle
  case awaitingInput
  case inputSubmitted
}

/// Agent hook 通过所属 PTY 写入的私有 OSC 6974 指令。固定键值和受支持枚举避免把
/// 任意终端文本当成生命周期事件；Pane 归属由控制终端天然确定，不依赖 PID 猜测。
public struct AgentTerminalDirective: Equatable, Sendable {
  public static let maximumPayloadBytes = 256
  public static let maximumSessionIDBytes = 128

  public let provider: AgentProvider
  public let signal: AgentTaskStateSignal
  /// 只有 provider 明确提供稳定会话身份时才存在；不接受 prompt、tool 参数或输出。
  public let sessionID: String?

  public init(provider: AgentProvider, signal: AgentTaskStateSignal, sessionID: String? = nil) {
    self.provider = provider
    self.signal = signal
    self.sessionID = sessionID
  }

  public init?(payload: String) {
    guard payload.utf8.count <= Self.maximumPayloadBytes else { return nil }
    var values: [String: String] = [:]
    for field in payload.split(separator: ";", omittingEmptySubsequences: false) {
      guard let separator = field.firstIndex(of: "=") else { return nil }
      let key = String(field[..<separator])
      let value = String(field[field.index(after: separator)...])
      guard !key.isEmpty, !value.isEmpty, values.updateValue(value, forKey: key) == nil else {
        return nil
      }
    }
    guard (2...3).contains(values.count),
      let providerValue = values["Provider"],
      let provider = AgentProvider(rawValue: providerValue),
      let state = values["AgentState"],
      Set(values.keys).isSubset(of: ["AgentState", "Provider", "SessionID"])
    else { return nil }
    let sessionID: String?
    if let value = values["SessionID"] {
      guard value.utf8.count <= Self.maximumSessionIDBytes,
        value.utf8.allSatisfy({ byte in
          (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte) || [0x2D, 0x2E, 0x3A, 0x5F].contains(byte)
        })
      else { return nil }
      sessionID = value
    } else {
      sessionID = nil
    }
    let signal: AgentTaskStateSignal
    switch state {
    case "processing": signal = .processing
    case "idle": signal = .idle
    case "awaiting-input": signal = .awaitingInput
    default: return nil
    }
    self.init(provider: provider, signal: signal, sessionID: sessionID)
  }
}

/// sequence 由每个 session 的事件接收层单调递增；Reducer 利用它丢弃延迟到达的旧
/// IPC 信号，避免一个过期 idle 把仍在 processing 的任务错误标成完成。
public struct AgentTaskStateEvent: Equatable, Sendable {
  public let sequence: UInt64
  public let signal: AgentTaskStateSignal

  public init(sequence: UInt64, signal: AgentTaskStateSignal) {
    self.sequence = sequence
    self.signal = signal
  }
}

public struct AgentTaskStateReducer: Equatable, Sendable {
  public private(set) var state: AgentTaskState
  public private(set) var lastAcceptedSequence: UInt64?

  public init(initialState: AgentTaskState = .idle) {
    state = initialState
  }

  /// 返回折叠后的当前状态。重复或乱序事件不会改变状态，也不会回退 sequence。
  @discardableResult
  public mutating func consume(_ event: AgentTaskStateEvent) -> AgentTaskState {
    if let lastAcceptedSequence, event.sequence <= lastAcceptedSequence {
      return state
    }
    lastAcceptedSequence = event.sequence
    switch event.signal {
    case .processing, .inputSubmitted:
      state = .processing
    case .idle:
      state = .idle
    case .awaitingInput:
      state = .awaitingInput
    }
    return state
  }
}
