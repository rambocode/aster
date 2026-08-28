import AsterCore
import Darwin
import Foundation

// 把解析好的 `AsterCLICommand` 映射成控制协议请求，并把结果渲染到 stdout。
// 本地 TTY 命令（watch / tab badge）在这里先被拦截，不连 socket。

/// 单次 CLI 调用的执行器。
struct CommandRunner {
  let arguments: AsterCLIArguments
  let environment: [String: String]

  /// 执行并返回进程退出码。参数类错误抛 `ControlClientError.usage`，服务端错误抛 `AsterControlError`。
  func run() throws -> Int32 {
    if case .legacy(let argv) = arguments.command, let code = LocalTTYCommands.run(argv) {
      return code
    }
    let client = ControlClient(
      socketPath: try ControlClient.resolveSocketPath(
        explicit: arguments.socketPath, environment: environment),
      environment: environment)

    switch arguments.command {
    case .help, .version, .skill:
      // main.swift 已处理，不会走到这里。
      return AsterCLIExitCode.success

    case .sessionSnapshot:
      let result = try client.call(.sessionSnapshot, params: nil)
      try emit(result, text: renderSnapshot)

    case .agentList:
      let result = try client.call(.agentList, params: nil)
      try emit(result, text: renderAgentList)

    case .agentGet(var params):
      params.target = resolveTarget(params.target)
      let result = try client.call(.agentGet, params: try encode(params))
      try emit(result, text: renderAgentGet)

    case .agentRead(var params):
      params.target = resolveTarget(params.target)
      let result = try client.call(.agentRead, params: try encode(params))
      try emit(result, text: renderReadText)

    case .agentPrompt(let target, let text, let wait):
      let body = try text ?? readStandardInputText()
      let params = AgentPromptParams(target: resolveTarget(target), text: body, wait: wait)
      let result = try client.call(
        .agentPrompt, params: try encode(params), timeout: waitTimeout(wait?.timeoutMs))
      try emit(result, text: renderAgentOutcome)

    case .agentWait(var params):
      params.target = resolveTarget(params.target)
      let result = try client.call(
        .agentWait, params: try encode(params), timeout: waitTimeout(params.timeoutMs))
      try emit(result, text: renderAgentOutcome)

    case .agentSendKeys(var params):
      params.target = resolveTarget(params.target)
      let result = try client.call(.agentSendKeys, params: try encode(params))
      try emit(result, text: renderOK)

    case .agentFocus(var params):
      params.target = resolveTarget(params.target)
      let result = try client.call(.agentFocus, params: try encode(params))
      try emit(result, text: renderOK)

    case .agentStart(var params):
      params.pane = params.pane.map(resolveTarget)
      let result = try client.call(
        .agentStart, params: try encode(params), timeout: waitTimeout(params.timeoutMs ?? 30_000))
      try emit(result, text: renderAgentOutcome)

    case .paneRead(let pane, let source, let lines):
      let params = PaneReadParams(pane: try resolvePane(pane), source: source, lines: lines)
      let result = try client.call(.paneRead, params: try encode(params))
      try emit(result, text: renderReadText)

    case .paneSendText(let pane, let text, let enter):
      let params = PaneSendTextParams(pane: try resolvePane(pane), text: text, enter: enter)
      let result = try client.call(.paneSendText, params: try encode(params))
      try emit(result, text: renderOK)

    case .paneSendKeys(let pane, let keys):
      let params = PaneSendKeysParams(pane: try resolvePane(pane), keys: keys)
      let result = try client.call(.paneSendKeys, params: try encode(params))
      try emit(result, text: renderOK)

    case .paneFocus(let pane):
      let params = PaneFocusParams(pane: try resolvePane(pane))
      let result = try client.call(.paneFocus, params: try encode(params))
      try emit(result, text: renderOK)

    case .paneWaitForOutput(let pane, let match, let regex, let source, let lines, let timeoutMs):
      let params = PaneWaitForOutputParams(
        pane: try resolvePane(pane), match: match, regex: regex, source: source, lines: lines,
        timeoutMs: timeoutMs)
      let result = try client.call(
        .paneWaitForOutput, params: try encode(params), timeout: waitTimeout(timeoutMs))
      try emit(result, text: renderReadText)

    case .eventsSubscribe(let params):
      // 订阅是长连接：确认行与每条事件都按 NDJSON 逐行输出，text/json 格式相同，便于 `while read` 消费。
      try client.stream(
        .eventsSubscribe, params: try encode(params),
        onResult: { result in
          if arguments.format == .json { printLine(try compactJSON(result)) }
        },
        onEvent: { event in printLine(try compactJSON(try JSONValue(encoding: event))) })

    case .eventsWait(var params):
      params.pane = params.pane.map(resolveTarget)
      let result = try client.call(
        .eventsWait, params: try encode(params), timeout: waitTimeout(params.timeoutMs))
      try emit(result, text: { try compactJSON($0) })

    case .notificationShow(let params):
      let result = try client.call(.notificationShow, params: try encode(params))
      try emit(result, text: renderOK)

    case .legacy(let argv):
      return try runLegacy(argv, client: client)
    }
    return AsterCLIExitCode.success
  }

  // MARK: - legacy 桥接

  /// 旧语法原样交给 App 内的 WorkflowCLIParser；stdout/stderr 原样回放，退出码透传。
  /// 旧脚本只在 `pane send-text --stdin` 时读 stdin，这里沿用同一判定而不是「非 tty 就读」：
  /// agent 工具里 stdin 常是永不关闭的管道，无条件读会让 `aster open .` 挂死。
  private func runLegacy(_ argv: [String], client: ControlClient) throws -> Int32 {
    var stdinBase64: String?
    if legacyReadsStandardInput(argv), isatty(STDIN_FILENO) == 0 {
      let data = FileHandle.standardInput.readDataToEndOfFile()
      guard data.count <= AsterControlProtocol.maximumRequestBytes else {
        throw ControlClientError.usage(
          "aster: standard input exceeds \(AsterControlProtocol.maximumRequestBytes) bytes")
      }
      stdinBase64 = data.base64EncodedString()
    }
    let params = WorkflowExecuteParams(
      argv: argv, cwd: FileManager.default.currentDirectoryPath, stdinBase64: stdinBase64)
    // 旧脚本等响应最长 300s（3000 × 0.1s）；`pane run` 之类命令可能较慢，保持同样上限。
    let result = try client.call(.workflowExecute, params: try encode(params), timeout: 300)
    let outcome = try result.decoded(as: WorkflowExecuteResult.self)
    FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
    FileHandle.standardError.write(Data(outcome.stderr.utf8))
    return outcome.exitCode
  }

  /// 复刻旧脚本的扫描：跳过全局选项后，只有 `pane send-text … --stdin` 消费 stdin。
  private func legacyReadsStandardInput(_ argv: [String]) -> Bool {
    var state = "global"
    var skipValue = false
    for argument in argv {
      if skipValue {
        skipValue = false
        continue
      }
      switch (state, argument) {
      case ("global", "--format"): skipValue = true
      case ("global", "--json"), ("global", "-q"), ("global", "--quiet"): break
      case ("global", "pane"): state = "pane"
      case ("global", _): state = "other"
      case ("pane", "send-text"): state = "send-text"
      case ("pane", _): state = "other"
      case ("send-text", "--stdin"): return true
      default: break
      }
    }
    return false
  }

  // MARK: - 参数辅助

  /// pane 缺省或为 `current` 时取 `$ASTER_PANE_ID`；既没有环境变量又没给 pane 才报错。
  private func resolvePane(_ explicit: String?) throws -> String {
    if let explicit { return resolveTarget(explicit) }
    if let paneID = currentPaneID { return paneID }
    throw ControlClientError.usage(
      "aster: no pane given and ASTER_PANE_ID is unset; pass --pane <id> or --current")
  }

  /// App 注入的调用者 pane 短 ID（`ASTER_PANE_ID`）；不在 Aster 内运行时为 nil。
  private var currentPaneID: String? {
    guard let value = environment["ASTER_PANE_ID"], !value.isEmpty else { return nil }
    return value
  }

  /// `current` 在服务端解析为「焦点 pane」，未必是调用者自己的 pane（用户可能已切到别处）。
  /// 因此只要有 `$ASTER_PANE_ID`，客户端就把 `current` 替换成调用者的短 ID 再发；其它 selector 原样透传。
  private func resolveTarget(_ selector: String) -> String {
    guard selector == "current", let paneID = currentPaneID else { return selector }
    return paneID
  }

  /// `agent prompt --stdin`：整段 stdin 作为 prompt 正文。
  private func readStandardInputText() throws -> String {
    let data = FileHandle.standardInput.readDataToEndOfFile()
    guard let text = String(data: data, encoding: .utf8) else {
      throw ControlClientError.usage("aster: standard input is not valid UTF-8")
    }
    guard !text.isEmpty else {
      throw ControlClientError.usage("aster: standard input is empty")
    }
    return text
  }

  /// wait 类方法的客户端超时 = 服务端 timeout_ms（clamp 后）+ 5s 余量，避免比服务端先放弃。
  private func waitTimeout(_ timeoutMs: Int?) -> TimeInterval {
    let serverMs = AsterControlProtocol.clampedTimeout(
      timeoutMs, default: AsterControlProtocol.maximumTimeoutMilliseconds)
    return TimeInterval(serverMs) / 1_000 + 5
  }

  private func encode<T: Encodable>(_ value: T) throws -> JSONValue {
    try JSONValue(encoding: value)
  }

  // MARK: - 输出

  /// `--json` 打印排序 + 缩进的原始 result；text 走各命令的渲染器。
  private func emit(_ result: JSONValue, text render: (JSONValue) throws -> String) throws {
    switch arguments.format {
    case .json: printLine(try prettyJSON(result))
    case .text: printLine(try render(result))
    }
  }

  private func renderOK(_ result: JSONValue) throws -> String { "ok" }

  private func renderReadText(_ result: JSONValue) throws -> String {
    result["text"]?.stringValue ?? ""
  }

  private func renderAgentList(_ result: JSONValue) throws -> String {
    let agents = try result.decoded(as: AgentListResult.self).agents
    guard !agents.isEmpty else { return "(no agents)" }
    var rows = [["PANE", "NAME", "AGENT", "STATUS", "DETECTION", "CWD"]]
    for agent in agents {
      rows.append([
        agent.paneID + (agent.focused ? "*" : ""), agent.name ?? "-", agent.agent,
        agent.agentStatus.rawValue, agent.detection.rawValue, agent.cwd ?? "-",
      ])
    }
    return table(rows)
  }

  private func renderAgentGet(_ result: JSONValue) throws -> String {
    describe(try result.decoded(as: AgentInfo.self))
  }

  /// agent.prompt / agent.wait / agent.start 结果都带 `agent`；wait 结果额外带到达的 `status`。
  private func renderAgentOutcome(_ result: JSONValue) throws -> String {
    guard let agentValue = result["agent"] else { return try prettyJSON(result) }
    let agent = try agentValue.decoded(as: AgentInfo.self)
    var lines: [String] = []
    if let status = result["status"]?.stringValue { lines.append("status: \(status)") }
    if let submitted = result["submitted"]?.boolValue { lines.append("submitted: \(submitted)") }
    lines.append(describe(agent))
    return lines.joined(separator: "\n")
  }

  private func renderSnapshot(_ result: JSONValue) throws -> String {
    let snapshot = try result.decoded(as: SessionSnapshot.self)
    var lines: [String] = []
    for window in snapshot.windows {
      lines.append("window \(window.windowID)\(window.focused ? " *" : "")")
      for tab in window.tabs {
        lines.append("  tab \(tab.tabID)\(tab.focused ? " *" : "")  \(tab.title ?? "")")
        for pane in tab.panes {
          var detail = "    pane \(pane.paneID)\(pane.focused ? " *" : "")  \(pane.kind.rawValue)"
          if let command = pane.command { detail += "  cmd=\(command)" }
          if let agent = pane.agent { detail += "  agent=\(agent.agent):\(agent.agentStatus.rawValue)" }
          if let cwd = pane.cwd { detail += "  \(cwd)" }
          lines.append(detail)
        }
      }
    }
    lines.append("sequence: \(snapshot.sequence)")
    return lines.joined(separator: "\n")
  }

  private func describe(_ agent: AgentInfo) -> String {
    var lines = [
      "pane: \(agent.paneID)",
      "tab: \(agent.tabID)",
      "window: \(agent.windowID)",
      "agent: \(agent.agent)",
      "status: \(agent.agentStatus.rawValue) (\(agent.detection.rawValue))",
      "focused: \(agent.focused)",
    ]
    if let name = agent.name { lines.insert("name: \(name)", at: 1) }
    if let command = agent.command { lines.append("command: \(command)") }
    if let title = agent.title { lines.append("title: \(title)") }
    if let cwd = agent.cwd { lines.append("cwd: \(cwd)") }
    if let session = agent.sessionID { lines.append("session: \(session)") }
    return lines.joined(separator: "\n")
  }

  /// 左对齐等宽表格；最后一列不补空格。
  private func table(_ rows: [[String]]) -> String {
    let columns = rows.map(\.count).max() ?? 0
    var widths = [Int](repeating: 0, count: columns)
    for row in rows {
      for (index, cell) in row.enumerated() { widths[index] = max(widths[index], cell.count) }
    }
    return rows.map { row in
      row.enumerated().map { index, cell in
        index == row.count - 1 ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0)
      }.joined(separator: "  ")
    }.joined(separator: "\n")
  }
}

/// 排序键 + 缩进的 JSON 文本，供 `--json` 输出。
func prettyJSON(_ value: JSONValue) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
  return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// 单行 JSON，供事件流逐行输出。
func compactJSON(_ value: JSONValue) throws -> String {
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
  return String(decoding: try encoder.encode(value), as: UTF8.self)
}

/// 写 stdout 并立即刷出：事件流场景下管道对端要能实时读到每一行。
func printLine(_ text: String) {
  FileHandle.standardOutput.write(Data((text + "\n").utf8))
}
