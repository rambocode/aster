import Foundation

// Aster 控制协议（Unix socket + NDJSON）的线格式定义。
// 服务端（Sources/Aster/Control）、CLI（aster-cli）与测试共用本文件；所有键名 snake_case，
// 与 herdr socket API 的命名习惯一致，便于同一份 SKILL.md 语义迁移。

/// 协议版本与全局上限常量。客户端请求里的 `protocol` 与此不符时返回 `protocol_mismatch`。
public enum AsterControlProtocol {
  public static let version = 1
  /// 单行请求（含换行）上限；超限由 NDJSONFraming 抛错并回 `request_too_large`。
  public static let maximumRequestBytes = 1 * 1_024 * 1_024
  /// `agent.prompt` / `pane.send_text` 文本上限。
  public static let maximumTextBytes = 64 * 1_024
  /// `*.send_keys` 单次按键个数上限。
  public static let maximumKeys = 64
  /// `*.read` / `pane.wait_for_output` 行数上限（与 WorkflowCLIParser.maximumCaptureLines 对齐）。
  public static let maximumReadLines = 10_000
  /// 所有 `timeout_ms` 的上限（10 分钟）；超出即 clamp 到此值，避免连接永久挂起。
  public static let maximumTimeoutMilliseconds = 600_000
  /// `agent.start` 的 args 个数上限。
  public static let maximumStartArguments = 128
  /// `workflow.execute` argv 上限（与 WorkflowCLIParser.maximumArguments 对齐）。
  public static let maximumWorkflowArguments = 256
  /// `notification.show` 标题 / 正文字节上限。
  public static let maximumNotificationTitleBytes = 256
  public static let maximumNotificationBodyBytes = 1_024
  /// `events.subscribe` 订阅种类上限（枚举本身只有 6 种，留余量防重复灌入）。
  public static let maximumSubscriptionKinds = 32
  /// 单次 `pane.wait_for_output` 匹配串 / 正则长度上限。
  public static let maximumMatchPatternBytes = 1_024

  public static let socketPathOverrideKey = AsterControlSocketLocation.overrideEnvironmentKey
  public static let maximumSocketPathBytes = AsterControlSocketLocation.maximumPathBytes

  /// 兼容别名：见 `AsterControlSocketLocation.defaultPath`。
  public static func defaultSocketPath(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    homeDirectory: String = NSHomeDirectory()
  ) -> String {
    AsterControlSocketLocation.defaultPath(environment: environment, home: homeDirectory)
  }

  /// 把可选 `timeout_ms` 归一到 [0, maximumTimeoutMilliseconds]；nil 走调用方默认值。
  public static func clampedTimeout(_ milliseconds: Int?, default fallback: Int) -> Int {
    min(max(milliseconds ?? fallback, 0), maximumTimeoutMilliseconds)
  }
}

// MARK: - 信封

/// 请求信封：`{"id": ..., "method": "...", "params": {...}, "protocol": 1}`。
/// id 允许 string / number / null / 缺省，响应必须原样回传，因此用 JSONValue 透传。
public struct AsterControlRequest: Codable, Equatable, Sendable {
  public var id: JSONValue?
  public var method: String
  public var params: JSONValue?
  public var protocolVersion: Int?

  private enum CodingKeys: String, CodingKey {
    case id, method, params
    case protocolVersion = "protocol"
  }

  public init(
    id: JSONValue? = nil, method: String, params: JSONValue? = nil,
    protocolVersion: Int? = AsterControlProtocol.version
  ) {
    self.id = id
    self.method = method
    self.params = params
    self.protocolVersion = protocolVersion
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    // `id: null` 保留为 `.null`、缺省为 nil（decodeIfPresent 会把 null 吞成 nil，故显式判断）；
    // 响应侧两者都写回 null。
    id = container.contains(.id) ? try container.decode(JSONValue.self, forKey: .id) : Optional<JSONValue>.none  // 显式 .none：JSONValue 可由 nil 字面量构造，裸 nil 会被推成 .null
    method = try container.decode(String.self, forKey: .method)
    params = try container.decodeIfPresent(JSONValue.self, forKey: .params)
    protocolVersion = try container.decodeIfPresent(Int.self, forKey: .protocolVersion)
  }

  /// 把 params 解成强类型结构；缺省 params 视为空对象，方便无参方法。
  public func decodeParams<T: Decodable>(_ type: T.Type) throws -> T {
    do {
      return try (params ?? .object([:])).decoded(as: type)
    } catch let error as AsterControlError {
      throw error
    } catch {
      throw AsterControlError(code: .invalidParams, message: "params 无法解析: \(error)")
    }
  }

  /// 把 method 字符串解析成已知方法；未知方法抛 `method_not_found`。
  public func resolvedMethod() throws -> AsterControlMethod {
    guard let resolved = AsterControlMethod(rawValue: method) else {
      throw AsterControlError(code: .methodNotFound, message: "未知方法: \(method)")
    }
    return resolved
  }
}

/// 响应信封：`{"id": ..., "result": {...}}` 或 `{"id": ..., "error": {"code": "...", "message": "..."}}`。
public struct AsterControlResponse: Codable, Equatable, Sendable {
  public var id: JSONValue?
  public var result: JSONValue?
  public var error: AsterControlError?

  private enum CodingKeys: String, CodingKey { case id, result, error }

  public init(id: JSONValue?, result: JSONValue) {
    self.id = id
    self.result = result
    self.error = nil
  }

  public init(id: JSONValue?, error: AsterControlError) {
    self.id = id
    self.result = nil
    self.error = error
  }

  /// 便捷构造：把强类型结果编码进 result；编码失败降级为 internal_error 响应。
  public init<T: Encodable>(id: JSONValue?, encoding value: T) {
    do {
      self.init(id: id, result: try JSONValue(encoding: value))
    } catch {
      self.init(
        id: id, error: AsterControlError(code: .internalError, message: "结果编码失败: \(error)"))
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = container.contains(.id) ? try container.decode(JSONValue.self, forKey: .id) : Optional<JSONValue>.none  // 显式 .none：JSONValue 可由 nil 字面量构造，裸 nil 会被推成 .null
    result = try container.decodeIfPresent(JSONValue.self, forKey: .result)
    error = try container.decodeIfPresent(AsterControlError.self, forKey: .error)
  }

  // id 永远写出（缺省写 null），result/error 二选一，避免客户端同时收到两者。
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id ?? .null, forKey: .id)
    if let error {
      try container.encode(error, forKey: .error)
    } else {
      try container.encode(result ?? .null, forKey: .result)
    }
  }
}

/// 错误码：字符串而非整数，方便 CLI/skill 直接按语义分支（如 `agent_blocked` 先读屏再问用户）。
public enum AsterControlErrorCode: String, Codable, CaseIterable, Sendable {
  case parseError = "parse_error"
  case invalidRequest = "invalid_request"
  case methodNotFound = "method_not_found"
  case invalidParams = "invalid_params"
  case requestTooLarge = "request_too_large"
  case protocolMismatch = "protocol_mismatch"
  case notFound = "not_found"
  case paneNotTerminal = "pane_not_terminal"
  case paneNotRunning = "pane_not_running"
  case agentNotFound = "agent_not_found"
  case agentBlocked = "agent_blocked"
  case agentNotReady = "agent_not_ready"
  case agentPromptStalled = "agent_prompt_stalled"
  case agentNotRunning = "agent_not_running"
  case paneBusy = "pane_busy"
  case writeNotAllowed = "write_not_allowed"
  case sensitiveSessionNotAllowed = "sensitive_session_not_allowed"
  case writeRejected = "write_rejected"
  case timeout = "timeout"
  case tooManyWaits = "too_many_waits"
  case agentNameTaken = "agent_name_taken"
  case replayGap = "replay_gap"
  case internalError = "internal_error"
}

/// 协议错误对象；同时作为 Swift Error 在服务端逐层抛出，最终编码进响应信封。
public struct AsterControlError: Error, Codable, Equatable, Sendable {
  public var code: AsterControlErrorCode
  public var message: String

  public init(code: AsterControlErrorCode, message: String) {
    self.code = code
    self.message = message
  }

  /// 参数校验失败的统一构造。
  public static func invalidParams(_ message: String) -> AsterControlError {
    AsterControlError(code: .invalidParams, message: message)
  }
}

// MARK: - 方法

/// MVP 方法集。`isWrite` 标记会改变终端/UI 状态的方法，服务端据此走 IPC 写门禁。
public enum AsterControlMethod: String, CaseIterable, Codable, Sendable {
  case serverPing = "server.ping"
  case sessionSnapshot = "session.snapshot"
  case agentList = "agent.list"
  case agentGet = "agent.get"
  case agentRead = "agent.read"
  case agentPrompt = "agent.prompt"
  case agentWait = "agent.wait"
  case agentSendKeys = "agent.send_keys"
  case agentFocus = "agent.focus"
  case agentStart = "agent.start"
  case paneRead = "pane.read"
  case paneSendText = "pane.send_text"
  case paneSendKeys = "pane.send_keys"
  case paneFocus = "pane.focus"
  case paneWaitForOutput = "pane.wait_for_output"
  case eventsSubscribe = "events.subscribe"
  case eventsWait = "events.wait"
  case notificationShow = "notification.show"
  case workflowExecute = "workflow.execute"

  /// 写方法：向 PTY 写字节或启动进程，需要 IPC 写门禁。focus / notification 按 herdr 语义
  /// 不算写（只改 UI，不进 PTY）；`workflow.execute` 内部由旧 WorkflowCLI 自行做门禁。
  public var isWrite: Bool {
    switch self {
    case .serverPing, .sessionSnapshot, .agentList, .agentGet, .agentRead, .paneRead,
      .paneWaitForOutput, .eventsSubscribe, .eventsWait, .agentWait, .agentFocus, .paneFocus,
      .notificationShow, .workflowExecute:
      return false
    case .agentPrompt, .agentSendKeys, .agentStart, .paneSendText, .paneSendKeys:
      return true
    }
  }

  /// 等待类方法：会挂起连接直到条件满足或超时，服务端限制每连接待决数量。
  public var isWait: Bool {
    switch self {
    case .agentWait, .paneWaitForOutput, .eventsWait: return true
    case .agentPrompt: return true  // 带 wait 选项时挂起；不带时立即返回
    default: return false
    }
  }
}

// MARK: - 通用枚举

/// Agent 对外状态（herdr 语义）：done = 已完成但用户尚未看见（对应 agentTaskCompletionUnread）。
public enum AgentControlStatus: String, Codable, CaseIterable, Equatable, Sendable {
  case idle, working, blocked, done, unknown
}

/// 状态来源：hook 权威 / 屏幕扫描 / 静默启发式。
public enum AgentDetectionSource: String, Codable, CaseIterable, Equatable, Sendable {
  case hook, screen, heuristic
}

/// 读屏来源：visible = 当前可见屏幕；recent = 含回滚的最近 N 行。
public enum PaneReadSource: String, Codable, CaseIterable, Equatable, Sendable {
  case visible, recent
}

/// 通知紧急度。
public enum NotificationUrgency: String, Codable, CaseIterable, Equatable, Sendable {
  case low, normal, critical
}

/// 校验协议：所有 params 结构都实现，服务端在解码后统一调用。
public protocol AsterControlValidatable {
  func validate() throws
}

// MARK: - 参数

/// 只带 target 的 agent 方法参数（agent.get / agent.focus / agent.wait 之外的简单方法）。
/// target 是 selector 字符串：短 ID、`p_<UUID>`、UUID、`current` 或 agent name。
public struct AgentTargetParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var target: String

  public init(target: String) { self.target = target }

  public func validate() throws {
    try ControlSelectorValidation.validateSelector(target, field: "target")
  }
}

/// agent.read：读取目标 agent 所在 pane 的文本。
public struct AgentReadParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var target: String
  public var source: PaneReadSource
  public var lines: Int?

  public init(target: String, source: PaneReadSource = .visible, lines: Int? = nil) {
    self.target = target
    self.source = source
    self.lines = lines
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    target = try container.decode(String.self, forKey: .target)
    source = try container.decodeIfPresent(PaneReadSource.self, forKey: .source) ?? .visible
    lines = try container.decodeIfPresent(Int.self, forKey: .lines)
  }

  public func validate() throws {
    try ControlSelectorValidation.validateSelector(target, field: "target")
    try ControlSelectorValidation.validateLines(lines)
  }
}

/// agent.wait / agent.prompt 的等待选项；until 为空时服务端默认 [idle, done, blocked]。
public struct AgentWaitOptions: Codable, Equatable, Sendable, AsterControlValidatable {
  public var until: [AgentControlStatus]
  public var timeoutMs: Int?

  private enum CodingKeys: String, CodingKey {
    case until
    case timeoutMs = "timeout_ms"
  }

  public init(until: [AgentControlStatus] = [], timeoutMs: Int? = nil) {
    self.until = until
    self.timeoutMs = timeoutMs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    until = try container.decodeIfPresent([AgentControlStatus].self, forKey: .until) ?? []
    timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs)
  }

  public func validate() throws {
    try ControlSelectorValidation.validateTimeout(timeoutMs)
    // 等 unknown 没有意义：unknown 表示无法判定，永远不该作为「到达」条件。
    if until.contains(.unknown) {
      throw AsterControlError.invalidParams("until 不能包含 unknown")
    }
  }
}

/// agent.wait：等待目标 agent 到达指定状态。
public struct AgentWaitParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var target: String
  public var until: [AgentControlStatus]
  public var timeoutMs: Int?

  private enum CodingKeys: String, CodingKey {
    case target, until
    case timeoutMs = "timeout_ms"
  }

  public init(target: String, until: [AgentControlStatus] = [], timeoutMs: Int? = nil) {
    self.target = target
    self.until = until
    self.timeoutMs = timeoutMs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    target = try container.decode(String.self, forKey: .target)
    until = try container.decodeIfPresent([AgentControlStatus].self, forKey: .until) ?? []
    timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs)
  }

  public var waitOptions: AgentWaitOptions { AgentWaitOptions(until: until, timeoutMs: timeoutMs) }

  public func validate() throws {
    try ControlSelectorValidation.validateSelector(target, field: "target")
    try waitOptions.validate()
  }
}

/// agent.prompt：向 agent 提交一段 prompt（服务端按 bracketed-paste 包裹并回车）。
public struct AgentPromptParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var target: String
  public var text: String
  public var wait: AgentWaitOptions?

  public init(target: String, text: String, wait: AgentWaitOptions? = nil) {
    self.target = target
    self.text = text
    self.wait = wait
  }

  public func validate() throws {
    try ControlSelectorValidation.validateSelector(target, field: "target")
    try ControlSelectorValidation.validateText(text, field: "text", allowEmpty: false)
    try wait?.validate()
  }
}

/// agent.send_keys：向 agent pane 发送逻辑按键序列（键名见 AsterControlKeyEncoder）。
public struct AgentSendKeysParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var target: String
  public var keys: [String]

  public init(target: String, keys: [String]) {
    self.target = target
    self.keys = keys
  }

  public func validate() throws {
    try ControlSelectorValidation.validateSelector(target, field: "target")
    try ControlSelectorValidation.validateKeys(keys)
  }
}

/// agent.start：在空闲 shell pane 里启动一个 agent。kind 是 AgentProvider 的 rawValue。
public struct AgentStartParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var pane: String?
  public var kind: String
  public var name: String?
  public var args: [String]
  public var timeoutMs: Int?

  private enum CodingKeys: String, CodingKey {
    case pane, kind, name, args
    case timeoutMs = "timeout_ms"
  }

  public init(
    pane: String? = nil, kind: String, name: String? = nil, args: [String] = [],
    timeoutMs: Int? = nil
  ) {
    self.pane = pane
    self.kind = kind
    self.name = name
    self.args = args
    self.timeoutMs = timeoutMs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    pane = try container.decodeIfPresent(String.self, forKey: .pane)
    kind = try container.decode(String.self, forKey: .kind)
    name = try container.decodeIfPresent(String.self, forKey: .name)
    args = try container.decodeIfPresent([String].self, forKey: .args) ?? []
    timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs)
  }

  public func validate() throws {
    if let pane { try ControlSelectorValidation.validateSelector(pane, field: "pane") }
    guard !kind.isEmpty, kind.utf8.count <= 64 else {
      throw AsterControlError.invalidParams("kind 必须是 1-64 字节的 provider 标识")
    }
    if let name { try ControlSelectorValidation.validateAgentName(name) }
    guard args.count <= AsterControlProtocol.maximumStartArguments else {
      throw AsterControlError.invalidParams(
        "args 最多 \(AsterControlProtocol.maximumStartArguments) 个")
    }
    for argument in args {
      guard argument.utf8.count <= WorkflowCLIParser.maximumArgumentBytes else {
        throw AsterControlError.invalidParams("args 单个参数过长")
      }
    }
    try ControlSelectorValidation.validateTimeout(timeoutMs)
  }
}

/// pane.read：读取任意终端 pane 的文本。
public struct PaneReadParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var pane: String
  public var source: PaneReadSource
  public var lines: Int?

  public init(pane: String, source: PaneReadSource = .visible, lines: Int? = nil) {
    self.pane = pane
    self.source = source
    self.lines = lines
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    pane = try container.decode(String.self, forKey: .pane)
    source = try container.decodeIfPresent(PaneReadSource.self, forKey: .source) ?? .visible
    lines = try container.decodeIfPresent(Int.self, forKey: .lines)
  }

  public func validate() throws {
    try ControlSelectorValidation.validateSelector(pane, field: "pane")
    try ControlSelectorValidation.validateLines(lines)
  }
}

/// pane.send_text：写入可打印文本；enter=true 时追加回车。
public struct PaneSendTextParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var pane: String
  public var text: String
  public var enter: Bool

  public init(pane: String, text: String, enter: Bool = false) {
    self.pane = pane
    self.text = text
    self.enter = enter
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    pane = try container.decode(String.self, forKey: .pane)
    text = try container.decode(String.self, forKey: .text)
    enter = try container.decodeIfPresent(Bool.self, forKey: .enter) ?? false
  }

  public func validate() throws {
    try ControlSelectorValidation.validateSelector(pane, field: "pane")
    // 空文本 + enter 是合法用法（只按回车），所以允许空串。
    try ControlSelectorValidation.validateText(text, field: "text", allowEmpty: true)
  }
}

/// pane.send_keys：向 pane 发送逻辑按键序列。
public struct PaneSendKeysParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var pane: String
  public var keys: [String]

  public init(pane: String, keys: [String]) {
    self.pane = pane
    self.keys = keys
  }

  public func validate() throws {
    try ControlSelectorValidation.validateSelector(pane, field: "pane")
    try ControlSelectorValidation.validateKeys(keys)
  }
}

/// pane.focus：把窗口/标签/pane 切到目标并前置。
public struct PaneFocusParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var pane: String

  public init(pane: String) { self.pane = pane }

  public func validate() throws {
    try ControlSelectorValidation.validateSelector(pane, field: "pane")
  }
}

/// pane.wait_for_output：轮询读屏直到出现子串（match）或正则（regex）命中。
public struct PaneWaitForOutputParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var pane: String
  public var match: String?
  public var regex: String?
  public var source: PaneReadSource
  public var lines: Int?
  public var timeoutMs: Int?

  private enum CodingKeys: String, CodingKey {
    case pane, match, regex, source, lines
    case timeoutMs = "timeout_ms"
  }

  public init(
    pane: String, match: String? = nil, regex: String? = nil, source: PaneReadSource = .visible,
    lines: Int? = nil, timeoutMs: Int? = nil
  ) {
    self.pane = pane
    self.match = match
    self.regex = regex
    self.source = source
    self.lines = lines
    self.timeoutMs = timeoutMs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    pane = try container.decode(String.self, forKey: .pane)
    match = try container.decodeIfPresent(String.self, forKey: .match)
    regex = try container.decodeIfPresent(String.self, forKey: .regex)
    source = try container.decodeIfPresent(PaneReadSource.self, forKey: .source) ?? .visible
    lines = try container.decodeIfPresent(Int.self, forKey: .lines)
    timeoutMs = try container.decodeIfPresent(Int.self, forKey: .timeoutMs)
  }

  public func validate() throws {
    try ControlSelectorValidation.validateSelector(pane, field: "pane")
    // match / regex 恰好一个：两个都给无法定义优先级，都不给则永远等不到。
    switch (match, regex) {
    case (nil, nil):
      throw AsterControlError.invalidParams("match 与 regex 必须提供其一")
    case (.some, .some):
      throw AsterControlError.invalidParams("match 与 regex 只能提供其一")
    case (.some(let pattern), nil), (nil, .some(let pattern)):
      guard !pattern.isEmpty,
        pattern.utf8.count <= AsterControlProtocol.maximumMatchPatternBytes
      else {
        throw AsterControlError.invalidParams(
          "匹配模式需为 1-\(AsterControlProtocol.maximumMatchPatternBytes) 字节")
      }
    }
    if let regex {
      // 提前编译，避免把无效正则带进轮询循环后才报错。
      guard (try? NSRegularExpression(pattern: regex)) != nil else {
        throw AsterControlError.invalidParams("regex 无法编译")
      }
    }
    try ControlSelectorValidation.validateLines(lines)
    try ControlSelectorValidation.validateTimeout(timeoutMs)
  }
}

/// events.subscribe：kinds 为空表示订阅全部事件。
public struct EventsSubscribeParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var kinds: [AsterControlEventKind]

  public init(kinds: [AsterControlEventKind] = []) { self.kinds = kinds }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    kinds = try container.decodeIfPresent([AsterControlEventKind].self, forKey: .kinds) ?? []
  }

  public func validate() throws {
    guard kinds.count <= AsterControlProtocol.maximumSubscriptionKinds else {
      throw AsterControlError.invalidParams("kinds 过多")
    }
  }
}

/// events.wait：阻塞等待下一条匹配事件；after_sequence 用于断线重连后补漏。
public struct EventsWaitParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var kind: AsterControlEventKind?
  public var pane: String?
  public var afterSequence: UInt64?
  public var timeoutMs: Int?

  private enum CodingKeys: String, CodingKey {
    case kind, pane
    case afterSequence = "after_sequence"
    case timeoutMs = "timeout_ms"
  }

  public init(
    kind: AsterControlEventKind? = nil, pane: String? = nil, afterSequence: UInt64? = nil,
    timeoutMs: Int? = nil
  ) {
    self.kind = kind
    self.pane = pane
    self.afterSequence = afterSequence
    self.timeoutMs = timeoutMs
  }

  public func validate() throws {
    if let pane { try ControlSelectorValidation.validateSelector(pane, field: "pane") }
    try ControlSelectorValidation.validateTimeout(timeoutMs)
  }
}

/// notification.show：弹系统通知；服务端会剥离控制字符。
public struct NotificationShowParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var title: String
  public var body: String?
  public var urgency: NotificationUrgency

  public init(title: String, body: String? = nil, urgency: NotificationUrgency = .normal) {
    self.title = title
    self.body = body
    self.urgency = urgency
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    title = try container.decode(String.self, forKey: .title)
    body = try container.decodeIfPresent(String.self, forKey: .body)
    urgency = try container.decodeIfPresent(NotificationUrgency.self, forKey: .urgency) ?? .normal
  }

  public func validate() throws {
    guard !title.isEmpty,
      title.utf8.count <= AsterControlProtocol.maximumNotificationTitleBytes
    else {
      throw AsterControlError.invalidParams(
        "title 需为 1-\(AsterControlProtocol.maximumNotificationTitleBytes) 字节")
    }
    if let body, body.utf8.count > AsterControlProtocol.maximumNotificationBodyBytes {
      throw AsterControlError.invalidParams(
        "body 最多 \(AsterControlProtocol.maximumNotificationBodyBytes) 字节")
    }
  }
}

/// workflow.execute：把旧 `aster` sh 脚本语法（open/view/watch/pane run …）原样转交 WorkflowCLIParser。
public struct WorkflowExecuteParams: Codable, Equatable, Sendable, AsterControlValidatable {
  public var argv: [String]
  public var cwd: String
  public var stdinBase64: String?

  private enum CodingKeys: String, CodingKey {
    case argv, cwd
    case stdinBase64 = "stdin_base64"
  }

  public init(argv: [String], cwd: String, stdinBase64: String? = nil) {
    self.argv = argv
    self.cwd = cwd
    self.stdinBase64 = stdinBase64
  }

  public func validate() throws {
    guard !argv.isEmpty, argv.count <= AsterControlProtocol.maximumWorkflowArguments else {
      throw AsterControlError.invalidParams(
        "argv 需为 1-\(AsterControlProtocol.maximumWorkflowArguments) 个参数")
    }
    guard cwd.hasPrefix("/") else {
      throw AsterControlError.invalidParams("cwd 必须是绝对路径")
    }
    if let stdinBase64 {
      guard let data = Data(base64Encoded: stdinBase64) else {
        throw AsterControlError.invalidParams("stdin_base64 不是合法 base64")
      }
      guard data.count <= AsterControlProtocol.maximumRequestBytes else {
        throw AsterControlError.invalidParams("stdin 过大")
      }
    }
  }

  /// 解码后的 stdin 字节；未提供或非法时为 nil（validate 已拦截非法）。
  public var standardInput: Data? {
    stdinBase64.flatMap { Data(base64Encoded: $0) }
  }
}

// MARK: - 结果

/// server.ping 结果：协议版本 + App 版本 + pid，CLI 用来判断是否连到了正确的实例。
public struct ServerPingResult: Codable, Equatable, Sendable {
  public var protocolVersion: Int
  public var version: String
  public var pid: Int32

  private enum CodingKeys: String, CodingKey {
    case protocolVersion = "protocol"
    case version, pid
  }

  public init(protocolVersion: Int = AsterControlProtocol.version, version: String, pid: Int32) {
    self.protocolVersion = protocolVersion
    self.version = version
    self.pid = pid
  }
}

/// agent.list / agent.get 的条目。name 是用户可读的 agent 名（可用作 selector）。
public struct AgentInfo: Codable, Equatable, Sendable {
  public var paneID: String
  public var tabID: String
  public var windowID: String
  public var name: String?
  public var agent: String
  public var command: String?
  public var agentStatus: AgentControlStatus
  public var detection: AgentDetectionSource
  public var sessionID: String?
  public var title: String?
  public var cwd: String?
  public var focused: Bool
  public var stateChangeSeq: UInt64

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case tabID = "tab_id"
    case windowID = "window_id"
    case name, agent, command
    case agentStatus = "agent_status"
    case detection
    case sessionID = "session_id"
    case title, cwd, focused
    case stateChangeSeq = "state_change_seq"
  }

  public init(
    paneID: String, tabID: String, windowID: String, name: String? = nil, agent: String,
    command: String? = nil, agentStatus: AgentControlStatus, detection: AgentDetectionSource,
    sessionID: String? = nil, title: String? = nil, cwd: String? = nil, focused: Bool,
    stateChangeSeq: UInt64
  ) {
    self.paneID = paneID
    self.tabID = tabID
    self.windowID = windowID
    self.name = name
    self.agent = agent
    self.command = command
    self.agentStatus = agentStatus
    self.detection = detection
    self.sessionID = sessionID
    self.title = title
    self.cwd = cwd
    self.focused = focused
    self.stateChangeSeq = stateChangeSeq
  }
}

/// session.snapshot 与 pane.* 事件里的 pane 描述。kind 复用 WorkspaceLayout 的 PaneKind
/// （terminal/editor/fileBrowser/preview/web）；只有 terminal 能读写。agent 为 nil 表示没在跑 agent。
public struct PaneInfo: Codable, Equatable, Sendable {
  public var paneID: String
  public var tabID: String
  public var windowID: String
  public var kind: PaneKind
  public var title: String?
  public var cwd: String?
  public var command: String?
  public var focused: Bool
  public var running: Bool
  public var agent: AgentInfo?

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case tabID = "tab_id"
    case windowID = "window_id"
    case kind, title, cwd, command, focused, running, agent
  }

  public init(
    paneID: String, tabID: String, windowID: String, kind: PaneKind, title: String? = nil,
    cwd: String? = nil, command: String? = nil, focused: Bool, running: Bool,
    agent: AgentInfo? = nil
  ) {
    self.paneID = paneID
    self.tabID = tabID
    self.windowID = windowID
    self.kind = kind
    self.title = title
    self.cwd = cwd
    self.command = command
    self.focused = focused
    self.running = running
    self.agent = agent
  }
}

/// agent.read / pane.read 结果。lines 是实际返回的行数。
public struct PaneReadResult: Codable, Equatable, Sendable {
  public var paneID: String
  public var source: PaneReadSource
  public var lines: Int
  public var text: String

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case source, lines, text
  }

  public init(paneID: String, source: PaneReadSource, lines: Int, text: String) {
    self.paneID = paneID
    self.source = source
    self.lines = lines
    self.text = text
  }
}

/// pane.wait_for_output 结果：命中的片段与命中时的屏幕文本。
public struct PaneWaitForOutputResult: Codable, Equatable, Sendable {
  public var paneID: String
  public var matched: String
  public var text: String

  private enum CodingKeys: String, CodingKey {
    case paneID = "pane_id"
    case matched, text
  }

  public init(paneID: String, matched: String, text: String) {
    self.paneID = paneID
    self.matched = matched
    self.text = text
  }
}

/// agent.wait / agent.prompt(wait) 结果：到达时的 agent 快照。
public struct AgentWaitResult: Codable, Equatable, Sendable {
  public var agent: AgentInfo
  public var status: AgentControlStatus

  public init(agent: AgentInfo, status: AgentControlStatus) {
    self.agent = agent
    self.status = status
  }
}

/// agent.prompt 不带 wait 时的结果：确认已写入。
public struct AgentPromptResult: Codable, Equatable, Sendable {
  public var agent: AgentInfo
  public var submitted: Bool

  public init(agent: AgentInfo, submitted: Bool) {
    self.agent = agent
    self.submitted = submitted
  }
}

/// agent.start 结果。
public struct AgentStartResult: Codable, Equatable, Sendable {
  public var agent: AgentInfo

  public init(agent: AgentInfo) { self.agent = agent }
}

/// agent.list 结果。
public struct AgentListResult: Codable, Equatable, Sendable {
  public var agents: [AgentInfo]

  public init(agents: [AgentInfo]) { self.agents = agents }
}

/// workflow.execute 结果：旧 CLI 的 stdout/stderr/exit code 原样透传。
public struct WorkflowExecuteResult: Codable, Equatable, Sendable {
  public var stdout: String
  public var stderr: String
  public var exitCode: Int32

  private enum CodingKeys: String, CodingKey {
    case stdout, stderr
    case exitCode = "exit_code"
  }

  public init(stdout: String, stderr: String, exitCode: Int32) {
    self.stdout = stdout
    self.stderr = stderr
    self.exitCode = exitCode
  }
}

/// session.snapshot：窗口 → 标签 → pane 三级树。
public struct SessionSnapshot: Codable, Equatable, Sendable {
  public struct Window: Codable, Equatable, Sendable {
    public var windowID: String
    public var focused: Bool
    public var tabs: [Tab]

    private enum CodingKeys: String, CodingKey {
      case windowID = "window_id"
      case focused, tabs
    }

    public init(windowID: String, focused: Bool, tabs: [Tab]) {
      self.windowID = windowID
      self.focused = focused
      self.tabs = tabs
    }
  }

  public struct Tab: Codable, Equatable, Sendable {
    public var tabID: String
    public var title: String?
    public var focused: Bool
    public var panes: [PaneInfo]

    private enum CodingKeys: String, CodingKey {
      case tabID = "tab_id"
      case title, focused, panes
    }

    public init(tabID: String, title: String? = nil, focused: Bool, panes: [PaneInfo]) {
      self.tabID = tabID
      self.title = title
      self.focused = focused
      self.panes = panes
    }
  }

  public var windows: [Window]
  /// 当前事件序列号，客户端可据此用 events.wait(after_sequence:) 无缝接上。
  public var sequence: UInt64

  public init(windows: [Window], sequence: UInt64) {
    self.windows = windows
    self.sequence = sequence
  }
}

/// events.subscribe 结果：确认订阅的种类 + 当前序列号。之后事件以 AsterControlEvent 推送。
public struct EventsSubscribeResult: Codable, Equatable, Sendable {
  public var kinds: [AsterControlEventKind]
  public var sequence: UInt64

  public init(kinds: [AsterControlEventKind], sequence: UInt64) {
    self.kinds = kinds
    self.sequence = sequence
  }
}

/// 通用「已完成」结果（focus / send_keys / send_text / notification.show）。
public struct AsterControlOKResult: Codable, Equatable, Sendable {
  public var ok: Bool

  public init(ok: Bool = true) { self.ok = ok }
}

// MARK: - 事件

/// 事件种类。
public enum AsterControlEventKind: String, Codable, CaseIterable, Equatable, Sendable {
  case paneCreated = "pane.created"
  case paneUpdated = "pane.updated"
  case paneClosed = "pane.closed"
  case paneFocused = "pane.focused"
  case paneExited = "pane.exited"
  case paneAgentStatusChanged = "pane.agent_status_changed"
}

/// 推送信封：`{"sequence": n, "event": "pane.updated", "data": {...}}`。
/// 与响应信封的区别是没有 id，客户端按 `event` 键存在与否区分。
public struct AsterControlEvent: Codable, Equatable, Sendable {
  public var sequence: UInt64
  public var event: AsterControlEventKind
  public var data: JSONValue

  public init(sequence: UInt64, event: AsterControlEventKind, data: JSONValue) {
    self.sequence = sequence
    self.event = event
    self.data = data
  }

  /// 便捷构造：把强类型 payload 编码进 data。
  public init<T: Encodable>(sequence: UInt64, event: AsterControlEventKind, encoding value: T)
    throws
  {
    self.init(sequence: sequence, event: event, data: try JSONValue(encoding: value))
  }

  /// pane.agent_status_changed 的 data 结构。
  public struct AgentStatusChange: Codable, Equatable, Sendable {
    public var paneID: String
    public var previous: AgentControlStatus?
    public var status: AgentControlStatus
    public var detection: AgentDetectionSource
    public var stateChangeSeq: UInt64
    public var agent: AgentInfo?

    private enum CodingKeys: String, CodingKey {
      case paneID = "pane_id"
      case previous, status, detection
      case stateChangeSeq = "state_change_seq"
      case agent
    }

    public init(
      paneID: String, previous: AgentControlStatus?, status: AgentControlStatus,
      detection: AgentDetectionSource, stateChangeSeq: UInt64, agent: AgentInfo? = nil
    ) {
      self.paneID = paneID
      self.previous = previous
      self.status = status
      self.detection = detection
      self.stateChangeSeq = stateChangeSeq
      self.agent = agent
    }
  }
}

// MARK: - 校验辅助

/// 各 params 共用的字段校验；错误统一为 `invalid_params`。
public enum ControlSelectorValidation {
  public static let maximumSelectorBytes = 128

  public static func validateSelector(_ value: String, field: String) throws {
    guard !value.isEmpty, value.utf8.count <= maximumSelectorBytes else {
      throw AsterControlError.invalidParams("\(field) 需为 1-\(maximumSelectorBytes) 字节")
    }
    guard ControlTargetSelector(parsing: value) != nil else {
      throw AsterControlError.invalidParams("\(field) 不是合法的 pane/agent selector: \(value)")
    }
  }

  public static func validateAgentName(_ name: String) throws {
    guard ControlTargetSelector.isValidAgentName(name) else {
      throw AsterControlError.invalidParams("name 需匹配 [a-z][a-z0-9_-]{0,31}")
    }
  }

  public static func validateLines(_ lines: Int?) throws {
    guard let lines else { return }
    guard lines >= 1, lines <= AsterControlProtocol.maximumReadLines else {
      throw AsterControlError.invalidParams("lines 需在 1-\(AsterControlProtocol.maximumReadLines)")
    }
  }

  /// timeout 只拒绝负数；超上限由 clampedTimeout 收敛，而不是报错，让客户端「等久一点」也能用。
  public static func validateTimeout(_ timeoutMs: Int?) throws {
    guard let timeoutMs else { return }
    guard timeoutMs >= 0 else { throw AsterControlError.invalidParams("timeout_ms 不能为负") }
  }

  public static func validateText(_ text: String, field: String, allowEmpty: Bool) throws {
    if !allowEmpty, text.isEmpty {
      throw AsterControlError.invalidParams("\(field) 不能为空")
    }
    guard text.utf8.count <= AsterControlProtocol.maximumTextBytes else {
      throw AsterControlError.invalidParams(
        "\(field) 最多 \(AsterControlProtocol.maximumTextBytes) 字节")
    }
  }

  public static func validateKeys(_ keys: [String]) throws {
    guard !keys.isEmpty, keys.count <= AsterControlProtocol.maximumKeys else {
      throw AsterControlError.invalidParams("keys 需为 1-\(AsterControlProtocol.maximumKeys) 个")
    }
    for key in keys {
      guard AsterControlKeyEncoder.isKnown(key) else {
        throw AsterControlError.invalidParams("未知按键名: \(key)")
      }
    }
  }
}

/// socket 路径的唯一决策点：server 监听与 CLI（无 `ASTER_SOCKET_PATH` 时）连接都用它，
/// 保证覆盖变量与超长路径回退两端一致。
public enum AsterControlSocketLocation {
  /// `ASTER_CONTROL_SOCKET_PATH`（绝对路径）覆盖默认位置；pane 内注入的 `ASTER_SOCKET_PATH`
  /// 是 server 实际监听路径，优先级高于此默认值。
  public static let overrideEnvironmentKey = "ASTER_CONTROL_SOCKET_PATH"
  /// sun_path 104 字节，留余量给 NUL 与实现差异。
  public static let maximumPathBytes = 100
  public static let relativePath = "Library/Application Support/Aster/Control/aster.sock"
  public static let fallbackFileName = "aster-control.sock"

  /// 默认路径：`~/Library/Application Support/Aster/Control/aster.sock`；超过 sun_path 上限时
  /// 回退 `<tmpdir>/aster-control.sock`。
  public static func defaultPath(
    environment: [String: String] = ProcessInfo.processInfo.environment,
    home: String = NSHomeDirectory(),
    tmpdir: String? = nil
  ) -> String {
    if let override = environment[overrideEnvironmentKey], override.hasPrefix("/") { return override }
    let preferred = (home as NSString).appendingPathComponent(relativePath)
    if preferred.utf8.count <= maximumPathBytes { return preferred }
    let temporary = tmpdir ?? environment["TMPDIR"] ?? NSTemporaryDirectory()
    return (temporary as NSString).appendingPathComponent(fallbackFileName)
  }
}

/// 终端标题归一化：剥掉 agent TUI 的 spinner 前缀（herdr `terminal_title_stripped` 规则），
/// 让 Claude 的 ✳/盲文每秒翻转的标题不再制造一串 pane.updated 事件。
public enum AsterControlTitleNormalizer {
  private static let spinnerScalars: Set<Unicode.Scalar> = ["·", "✢", "✳", "✶", "✻", "✽", "◐", "◓", "◑", "◒"]

  /// 标题是否以 agent TUI 的 spinner 字符开头（盲文或 ✳/◐ 系列，且其后是空白或结尾）。
  /// 侧栏行与标题胶囊据此决定不再叠加自己的 Agent 图标，避免出现两个图标。
  public static func hasSpinnerPrefix(_ title: String) -> Bool {
    let scalars = Array(title.unicodeScalars)
    guard let first = scalars.first else { return false }
    let isSpinner = (0x2800...0x28FF).contains(first.value) || spinnerScalars.contains(first)
    guard isSpinner else { return false }
    return scalars.count == 1 || CharacterSet.whitespaces.contains(scalars[1])
  }

  /// 首字符为盲文（U+2800-28FF）或 spinner 符号，且其后是空白或结尾 → 剥掉该字符与后续空白。
  public static func stripped(_ title: String) -> String {
    guard hasSpinnerPrefix(title) else { return title }
    let scalars = Array(title.unicodeScalars)
    var index = 1
    while index < scalars.count, CharacterSet.whitespaces.contains(scalars[index]) { index += 1 }
    return String(String.UnicodeScalarView(scalars[index...]))
  }
}
