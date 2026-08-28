import AsterCore
import Foundation

/// 每条连接在 dispatcher 眼里的最小接口：推事件、计数待决等待。实现是 AsterControlConnection；
/// 测试用假实现，不需要真 socket。
@MainActor
protocol AsterControlClient: AnyObject {
  var clientID: UUID { get }
  var pendingWaits: Int { get set }
  func sendEvent(_ event: AsterControlEvent)
}

/// 控制协议方法分发（@MainActor）：把请求解析为强类型 params，经桥解析目标 pane，
/// 执行只读/写/等待方法并产出响应。socket 线程只负责分帧与写回。
@MainActor
final class AsterControlDispatcher {
  /// 写门禁与通知策略需要的配置快照；由 AppDelegate 每次从 AppPreferences 取。
  struct Policy {
    var allowSendKeys: Bool
    var allowSensitiveSessions: Bool
    var shell: ShellConfiguration
  }

  static let maximumPendingWaitsPerClient = 4
  static let defaultWaitTimeoutMilliseconds = 60_000
  static let defaultOutputWaitTimeoutMilliseconds = 30_000
  static let defaultStartTimeoutMilliseconds = 30_000
  static let startSettleMilliseconds = 3_000
  static let promptStallMilliseconds = 5_000
  static let outputPollMilliseconds = 200

  let bridge: AsterControlBridge
  let policyProvider: () -> Policy
  let version: String
  /// `notification.show` 的投递出口；测试注入记录器。
  var notificationPoster: (any TerminalNotificationPosting)?
  /// 时间注入：测试缩短 settle / stall 等待。
  var promptStallMilliseconds = AsterControlDispatcher.promptStallMilliseconds
  var startSettleMilliseconds = AsterControlDispatcher.startSettleMilliseconds

  init(
    bridge: AsterControlBridge, version: String,
    notificationPoster: (any TerminalNotificationPosting)? = nil,
    policyProvider: @escaping () -> Policy
  ) {
    self.bridge = bridge
    self.version = version
    self.notificationPoster = notificationPoster
    self.policyProvider = policyProvider
  }

  // MARK: - 入口

  func handle(_ request: AsterControlRequest, client: any AsterControlClient) async -> AsterControlResponse {
    do {
      if let protocolVersion = request.protocolVersion, protocolVersion != AsterControlProtocol.version {
        throw AsterControlError(
          code: .protocolMismatch,
          message: "协议版本 \(protocolVersion) 不受支持，服务端为 \(AsterControlProtocol.version)")
      }
      let method = try request.resolvedMethod()
      let result = try await dispatch(method, request: request, client: client)
      return AsterControlResponse(id: request.id, result: result)
    } catch let error as AsterControlError {
      return AsterControlResponse(id: request.id, error: error)
    } catch is CancellationError {
      return AsterControlResponse(id: request.id, error: AsterControlError(code: .internalError, message: "连接已关闭"))
    } catch {
      return AsterControlResponse(id: request.id, error: AsterControlError(code: .internalError, message: "\(error)"))
    }
  }

  private func dispatch(
    _ method: AsterControlMethod, request: AsterControlRequest, client: any AsterControlClient
  ) async throws -> JSONValue {
    switch method {
    case .serverPing:
      return try encode(ServerPingResult(version: version, pid: ProcessInfo.processInfo.processIdentifier))
    case .sessionSnapshot:
      return try encode(bridge.snapshot())
    case .agentList:
      return try encode(AgentListResult(agents: bridge.allPanes().compactMap(bridge.agentInfo)))
    case .agentGet:
      let params = try decode(AgentTargetParams.self, request)
      let (record, info) = try resolveAgent(params.target)
      _ = record
      return try encode(info)
    case .agentRead:
      let params = try decode(AgentReadParams.self, request)
      let (record, _) = try resolveAgent(params.target)
      return try encode(try readPane(record, source: params.source, lines: params.lines))
    case .paneRead:
      let params = try decode(PaneReadParams.self, request)
      let record = try bridge.resolve(selector: params.pane)
      return try encode(try readPane(record, source: params.source, lines: params.lines))
    case .agentFocus:
      let params = try decode(AgentTargetParams.self, request)
      let (record, _) = try resolveAgent(params.target)
      focus(record)
      // 焦点落到 agent 视为「用户看过结果」，done → idle。
      record.session?.markAgentCompletionSeen()
      return try encode(AsterControlOKResult())
    case .paneFocus:
      let params = try decode(PaneFocusParams.self, request)
      focus(try bridge.resolve(selector: params.pane))
      return try encode(AsterControlOKResult())
    case .paneSendText:
      let params = try decode(PaneSendTextParams.self, request)
      let record = try bridge.resolve(selector: params.pane)
      let session = try terminalSession(record)
      try gate(session)
      try Self.validatePlainText(params.text)
      let bytes = try Self.bytes(forSendText: params.text, enter: params.enter)
      guard bytes.isEmpty || session.sendAutomationBytes(bytes) else {
        throw AsterControlError(code: .writeRejected, message: "无法写入目标 pane")
      }
      return try encode(AsterControlOKResult())
    case .paneSendKeys:
      let params = try decode(PaneSendKeysParams.self, request)
      let record = try bridge.resolve(selector: params.pane)
      try sendKeys(params.keys, to: record)
      return try encode(AsterControlOKResult())
    case .agentSendKeys:
      let params = try decode(AgentSendKeysParams.self, request)
      let (record, _) = try resolveAgent(params.target)
      try sendKeys(params.keys, to: record)
      return try encode(AsterControlOKResult())
    case .agentPrompt:
      let params = try decode(AgentPromptParams.self, request)
      return try await prompt(params, client: client)
    case .agentWait:
      let params = try decode(AgentWaitParams.self, request)
      let (record, info) = try resolveAgent(params.target)
      return try await withWaitSlot(client) {
        try await self.waitForAgent(record, startingFrom: info, options: params.waitOptions)
      }
    case .paneWaitForOutput:
      let params = try decode(PaneWaitForOutputParams.self, request)
      let record = try bridge.resolve(selector: params.pane)
      return try await withWaitSlot(client) { try await self.waitForOutput(record, params: params) }
    case .eventsSubscribe:
      let params = try decode(EventsSubscribeParams.self, request)
      bridge.hub.subscribe(id: client.clientID, kinds: params.kinds) { [weak client] event in
        client?.sendEvent(event)
      }
      return try encode(EventsSubscribeResult(kinds: params.kinds, sequence: bridge.hub.sequence))
    case .eventsWait:
      let params = try decode(EventsWaitParams.self, request)
      return try await withWaitSlot(client) { try await self.waitForEvent(params) }
    case .notificationShow:
      let params = try decode(NotificationShowParams.self, request)
      showNotification(params)
      return try encode(AsterControlOKResult())
    case .agentStart:
      let params = try decode(AgentStartParams.self, request)
      return try await withWaitSlot(client) { try await self.startAgent(params) }
    case .workflowExecute:
      let params = try decode(WorkflowExecuteParams.self, request)
      return try encode(try await executeWorkflow(params))
    }
  }

  // MARK: - 辅助

  private func decode<T: Decodable & AsterControlValidatable>(_ type: T.Type, _ request: AsterControlRequest) throws -> T {
    let params = try request.decodeParams(type)
    try params.validate()
    return params
  }

  private func encode<T: Encodable>(_ value: T) throws -> JSONValue {
    do {
      return try JSONValue(encoding: value)
    } catch {
      throw AsterControlError(code: .internalError, message: "结果编码失败: \(error)")
    }
  }

  /// 解析 agent target：pane 必须正在跑 agent，否则 `agent_not_found`。
  private func resolveAgent(_ target: String) throws -> (AsterControlBridge.PaneRecord, AgentInfo) {
    let record = try bridge.resolve(selector: target)
    guard let info = bridge.agentInfo(record) else {
      throw AsterControlError(code: .agentNotFound, message: "\(record.paneID) 没有正在运行的 agent")
    }
    return (record, info)
  }

  private func terminalSession(_ record: AsterControlBridge.PaneRecord) throws -> TerminalSession {
    guard let session = record.session else {
      throw AsterControlError(code: .paneNotTerminal, message: "\(record.paneID) 不是终端 pane")
    }
    guard session.statusIsRunning else {
      throw AsterControlError(code: .paneNotRunning, message: "\(record.paneID) 的终端进程已退出")
    }
    return session
  }

  private func gate(_ session: TerminalSession) throws {
    let policy = policyProvider()
    if let blocker = AsterControlWriteGate.blocker(
      session: session, allowSendKeys: policy.allowSendKeys,
      allowSensitiveSessions: policy.allowSensitiveSessions)
    {
      throw blocker
    }
  }

  /// send_text 的字节：文本 UTF-8 + 可选 Enter。Enter 走键名表（CR 0x0D），与 send_keys 的 enter
  /// 一致；Ghostty `sendBytes` 原样进 PTY，LF 在 raw 模式的 TUI 里不会被当作回车。
  static func bytes(forSendText text: String, enter: Bool) throws -> [UInt8] {
    var bytes = Array(text.utf8)
    if enter { bytes += try AsterControlKeyEncoder.encode(["enter"]) }
    return bytes
  }

  /// `pane.send_text` 只接受可打印文本与 `\n` `\t`：控制序列必须走 send_keys，避免把 ESC 注入 TUI。
  static func validatePlainText(_ text: String) throws {
    for scalar in text.unicodeScalars {
      if scalar == "\n" || scalar == "\t" { continue }
      if scalar.value < 0x20 || scalar.value == 0x7F {
        throw AsterControlError.invalidParams("text 含控制字符，请改用 send_keys")
      }
    }
  }

  private func sendKeys(_ keys: [String], to record: AsterControlBridge.PaneRecord) throws {
    let session = try terminalSession(record)
    try gate(session)
    let bytes: [UInt8]
    do {
      bytes = try AsterControlKeyEncoder.encode(keys)
    } catch {
      throw AsterControlError.invalidParams("未知按键名")
    }
    guard session.sendAutomationBytes(bytes) else {
      throw AsterControlError(code: .writeRejected, message: "无法写入目标 pane")
    }
  }

  private func focus(_ record: AsterControlBridge.PaneRecord) {
    record.model.revealWorkspaceLocation(tabID: record.tab.id, paneID: record.runtime.id)
    record.model.onRequestWindowFocus?()
  }

  private func readPane(
    _ record: AsterControlBridge.PaneRecord, source: PaneReadSource, lines: Int?
  ) throws -> PaneReadResult {
    guard let session = record.session else {
      throw AsterControlError(code: .paneNotTerminal, message: "\(record.paneID) 不是终端 pane")
    }
    let limit = lines ?? AsterControlProtocol.maximumReadLines
    let text = session.readControlText(includeScrollback: source == .recent, maximumLines: limit) ?? ""
    let count = text.isEmpty ? 0 : text.components(separatedBy: "\n").count
    return PaneReadResult(paneID: record.paneID.description, source: source, lines: count, text: text)
  }

  private func showNotification(_ params: NotificationShowParams) {
    let urgency: TerminalNotificationUrgency = switch params.urgency {
    case .low: .low
    case .normal: .normal
    case .critical: .critical
    }
    let notification = TerminalNotification(
      title: Self.stripControlCharacters(params.title),
      body: Self.stripControlCharacters(params.body ?? ""), urgency: urgency)
    let poster = notificationPoster ?? TerminalNotificationService.shared
    poster.post(
      notification, category: .application, configuration: policyProvider().shell,
      sourceTabIsFocused: false)
  }

  static func stripControlCharacters(_ text: String) -> String {
    String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init))
  }

  // MARK: - 等待类

  /// 每连接最多 4 个待决等待，超出直接拒绝，避免单个客户端挂满主线程任务。
  private func withWaitSlot<T>(_ client: any AsterControlClient, _ body: () async throws -> T) async throws -> T {
    guard client.pendingWaits < Self.maximumPendingWaitsPerClient else {
      throw AsterControlError(code: .tooManyWaits, message: "同一连接最多 \(Self.maximumPendingWaitsPerClient) 个待决等待")
    }
    client.pendingWaits += 1
    defer { client.pendingWaits -= 1 }
    return try await body()
  }

  /// agent.wait：钉住 provider + sessionID；pane 关闭或 agent 换人 → `agent_not_running`。
  private func waitForAgent(
    _ record: AsterControlBridge.PaneRecord, startingFrom initial: AgentInfo, options: AgentWaitOptions
  ) async throws -> JSONValue {
    let until = AgentWaitCondition.resolvedUntil(options.until)
    if AgentWaitCondition.matches(status: initial.agentStatus, until: until) {
      return try encode(AgentWaitResult(agent: initial, status: initial.agentStatus))
    }
    let timeout = AsterControlProtocol.clampedTimeout(options.timeoutMs, default: Self.defaultWaitTimeoutMilliseconds)
    let deadline = ContinuousClock.now + .milliseconds(timeout)
    let paneID = initial.paneID
    let pinnedAgent = initial.agent
    let pinnedSession = initial.sessionID
    // cursor 随每条已消费事件前进：若固定用起始序列号，回放快路径会反复同步返回同一条
    // 非目标状态事件，形成主线程死循环。
    var cursor = bridge.hub.sequence
    while true {
      try Task.checkCancellation()
      let remaining = Int((deadline - ContinuousClock.now) / .milliseconds(1))
      guard remaining > 0 else { throw AsterControlError(code: .timeout, message: "等待 agent 状态超时") }
      let event = try await bridge.hub.waitForEvent(after: cursor, timeoutMilliseconds: remaining) { event in
        (event.event == .paneAgentStatusChanged || event.event == .paneClosed)
          && event.data["pane_id"]?.stringValue == paneID
      }
      cursor = event.sequence
      if event.event == .paneClosed {
        throw AsterControlError(code: .agentNotRunning, message: "pane 已关闭")
      }
      guard let agent = try? event.data["agent"].map({ try $0.decoded(as: AgentInfo.self) }) ?? nil else {
        throw AsterControlError(code: .agentNotRunning, message: "agent 已退出")
      }
      // sessionID 从 nil 变成有值属于同一会话首次上报，不算换人；有值→不同值才算。
      if agent.agent != pinnedAgent || (pinnedSession != nil && agent.sessionID != nil && agent.sessionID != pinnedSession) {
        throw AsterControlError(code: .agentNotRunning, message: "目标 agent 已被替换")
      }
      if AgentWaitCondition.matches(status: agent.agentStatus, until: until) {
        return try encode(AgentWaitResult(agent: agent, status: agent.agentStatus))
      }
    }
  }

  /// agent.prompt：blocked 不写；写入后若带 wait 则等待，起始非 working 且 5s 内无状态变化 → stalled。
  private func prompt(_ params: AgentPromptParams, client: any AsterControlClient) async throws -> JSONValue {
    let (record, info) = try resolveAgent(params.target)
    let session = try terminalSession(record)
    try gate(session)
    guard info.agentStatus != .blocked else {
      throw AsterControlError(code: .agentBlocked, message: "agent 正在等待确认或输入，先 agent.read 看看它在问什么")
    }
    guard session.submitPromptQueueText(params.text) else {
      throw AsterControlError(code: .writeRejected, message: "无法把 prompt 写入 agent")
    }
    guard let wait = params.wait else {
      return try encode(AgentPromptResult(agent: info, submitted: true))
    }
    return try await withWaitSlot(client) {
      let startSequence = self.bridge.hub.sequence
      if info.agentStatus != .working {
        // 先等 agent 动起来：状态序列无变化说明 prompt 没被吃掉（TUI 未聚焦输入框等）。
        do {
          _ = try await self.bridge.hub.waitForEvent(after: startSequence, timeoutMilliseconds: self.promptStallMilliseconds) {
            $0.event == .paneAgentStatusChanged && $0.data["pane_id"]?.stringValue == info.paneID
          }
        } catch let error as AsterControlError where error.code == .timeout {
          throw AsterControlError(code: .agentPromptStalled, message: "prompt 已写入，但 agent 状态 \(self.promptStallMilliseconds)ms 内没有变化")
        }
      }
      guard let current = self.bridge.agentInfo(record) else {
        throw AsterControlError(code: .agentNotRunning, message: "agent 已退出")
      }
      return try await self.waitForAgent(record, startingFrom: current, options: wait)
    }
  }

  /// pane.wait_for_output：200ms 轮询读屏直到命中。
  private func waitForOutput(_ record: AsterControlBridge.PaneRecord, params: PaneWaitForOutputParams) async throws -> JSONValue {
    guard let session = record.session else {
      throw AsterControlError(code: .paneNotTerminal, message: "\(record.paneID) 不是终端 pane")
    }
    let timeout = AsterControlProtocol.clampedTimeout(params.timeoutMs, default: Self.defaultOutputWaitTimeoutMilliseconds)
    let deadline = ContinuousClock.now + .milliseconds(timeout)
    let regex = try params.regex.map { try NSRegularExpression(pattern: $0) }
    let limit = params.lines ?? AsterControlProtocol.maximumReadLines
    while true {
      try Task.checkCancellation()
      let text = session.readControlText(includeScrollback: params.source == .recent, maximumLines: limit) ?? ""
      if let match = params.match, text.contains(match) {
        return try encode(PaneWaitForOutputResult(paneID: record.paneID.description, matched: match, text: text))
      }
      if let regex, let found = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
        let range = Range(found.range, in: text)
      {
        return try encode(PaneWaitForOutputResult(paneID: record.paneID.description, matched: String(text[range]), text: text))
      }
      guard ContinuousClock.now < deadline else {
        throw AsterControlError(code: .timeout, message: "等待输出超时")
      }
      try await Task.sleep(for: .milliseconds(Self.outputPollMilliseconds))
    }
  }

  private func waitForEvent(_ params: EventsWaitParams) async throws -> JSONValue {
    let timeout = AsterControlProtocol.clampedTimeout(params.timeoutMs, default: Self.defaultWaitTimeoutMilliseconds)
    let paneID = try params.pane.map { try bridge.resolve(selector: $0).paneID.description }
    // after_sequence 之后的事件已被环形缓冲挤掉：与其静默漏事件，不如让客户端拿 snapshot 重同步。
    if let after = params.afterSequence, bridge.hub.replayResult(after: after).truncated {
      throw AsterControlError(code: .replayGap, message: "序列号 \(after) 之后的事件已超出回放缓冲，请用 session.snapshot 重同步")
    }
    let event = try await bridge.hub.waitForEvent(after: params.afterSequence, timeoutMilliseconds: timeout) { event in
      if let kind = params.kind, event.event != kind { return false }
      if let paneID, event.data["pane_id"]?.stringValue != paneID { return false }
      return true
    }
    return try encode(event)
  }

  /// agent.start：需要空闲 shell pane；发送启动命令后等 provider 识别，再 settle 观察是否 blocked。
  private func startAgent(_ params: AgentStartParams) async throws -> JSONValue {
    let record = try bridge.resolve(selector: params.pane ?? "current")
    let session = try terminalSession(record)
    try gate(session)
    guard let provider = Self.provider(forKind: params.kind) else {
      throw AsterControlError.invalidParams("未知 agent kind: \(params.kind)")
    }
    if let name = params.name, let owner = bridge.paneOwningAgentName(name), owner != record.runtime.id {
      throw AsterControlError(code: .agentNameTaken, message: "名字 \(name) 已被其它 agent 使用")
    }
    guard session.activeAgentProvider == nil, !session.hasForegroundCommand else {
      throw AsterControlError(code: .paneBusy, message: "\(record.paneID) 有前台命令或 agent 正在运行")
    }
    let components = record.model.launchComponents(for: provider) + params.args
    let startSequence = bridge.hub.sequence
    session.send(WorkflowShellCommandEncoder.encode(components))
    let timeout = AsterControlProtocol.clampedTimeout(params.timeoutMs, default: Self.defaultStartTimeoutMilliseconds)
    let deadline = ContinuousClock.now + .milliseconds(timeout)
    // 等 provider 被识别（命令首 token / 标题 / hook 任一路径）。
    while session.activeAgentProvider != provider {
      guard ContinuousClock.now < deadline else {
        throw AsterControlError(code: .timeout, message: "agent 启动超时")
      }
      guard session.statusIsRunning else {
        throw AsterControlError(code: .paneNotRunning, message: "终端进程已退出")
      }
      try await Task.sleep(for: .milliseconds(Self.outputPollMilliseconds))
    }
    // settle：给 TUI 一点时间；期间若出现 blocked（信任目录、登录等）→ agent_not_ready。
    let settleDeadline = min(deadline, ContinuousClock.now + .milliseconds(startSettleMilliseconds))
    _ = startSequence
    while ContinuousClock.now < settleDeadline {
      if let info = bridge.agentInfo(record), info.agentStatus == .blocked {
        throw AsterControlError(code: .agentNotReady, message: "agent 启动后即等待输入，请先 agent.read 处理")
      }
      try await Task.sleep(for: .milliseconds(Self.outputPollMilliseconds))
    }
    guard bridge.agentInfo(record) != nil else {
      throw AsterControlError(code: .agentNotRunning, message: "agent 未能保持运行")
    }
    // 名字只在启动成功后登记；provider 退出/换人时由桥清除。
    if let name = params.name { bridge.setAgentName(name, paneUUID: record.runtime.id) }
    guard let info = bridge.agentInfo(record) else {
      throw AsterControlError(code: .agentNotRunning, message: "agent 未能保持运行")
    }
    return try encode(AgentStartResult(agent: info))
  }

  /// kind 接受 provider rawValue、命令名或可执行别名。
  static func provider(forKind kind: String) -> AgentProvider? {
    if let provider = AgentProvider(rawValue: kind) { return provider }
    let lowered = kind.lowercased()
    return AgentProvider.allCases.first {
      $0.commandName.lowercased() == lowered || $0.executableAliases.contains(lowered)
    }
  }

  // MARK: - 旧 CLI 桥接

  private func executeWorkflow(_ params: WorkflowExecuteParams) async throws -> WorkflowExecuteResult {
    let action: WorkflowCLIAction
    do {
      action = try WorkflowCLIParser(currentDirectory: params.cwd).parse(params.argv)
    } catch {
      // 旧脚本对参数错误的约定：stderr 说明 + exit 64。
      return WorkflowExecuteResult(stdout: "", stderr: "\(error)\n", exitCode: 64)
    }
    let model = bridge.activeModelProvider?() ?? bridge.attachedModels.first
    guard let model else {
      throw AsterControlError(code: .internalError, message: "没有可用的工作区窗口")
    }
    let policy = policyProvider()
    return await withCheckedContinuation { continuation in
      model.executeWorkflowCLI(
        action, standardInput: params.standardInput,
        allowSendKeys: policy.allowSendKeys, allowSensitiveSessions: policy.allowSensitiveSessions
      ) { response in
        continuation.resume(
          returning: WorkflowExecuteResult(
            stdout: response.standardOutput, stderr: response.standardError, exitCode: response.exitCode))
      }
    }
  }
}
