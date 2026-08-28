import Foundation

// `aster-cli` 的参数解析（手写，不引 ArgumentParser）。只描述意图，不连 socket。
// 新语法（agent/pane/events/notification/session）在此解析；旧 sh 脚本语法
// （open/view/edit/watch/jump/learn/ignore/pane run|exec|capture …）原样落到 `.legacy(argv)`，
// 由 CLI 经 `workflow.execute` 转交 App 内的 WorkflowCLIParser，保证旧命令零改动可用。

/// CLI 输出格式。
public enum AsterCLIOutputFormat: String, Equatable, Sendable {
  case text, json
}

/// 解析后的子命令。字段尽量复用协议层 params，CLI 运行时可直接编码发出。
public enum AsterCLICommand: Equatable, Sendable {
  case help
  case version
  /// 打印内置 SKILL.md。
  case skill
  case sessionSnapshot
  case agentList
  case agentGet(AgentTargetParams)
  case agentRead(AgentReadParams)
  /// text 为 nil 表示从 stdin 读取 prompt。
  case agentPrompt(target: String, text: String?, wait: AgentWaitOptions?)
  case agentWait(AgentWaitParams)
  case agentSendKeys(AgentSendKeysParams)
  case agentFocus(AgentTargetParams)
  case agentStart(AgentStartParams)
  /// pane 为 nil 表示由运行时用 `$ASTER_PANE_ID` 兜底。
  case paneRead(pane: String?, source: PaneReadSource, lines: Int?)
  case paneSendText(pane: String?, text: String, enter: Bool)
  case paneSendKeys(pane: String?, keys: [String])
  case paneFocus(pane: String?)
  case paneWaitForOutput(
    pane: String?, match: String?, regex: String?, source: PaneReadSource, lines: Int?,
    timeoutMs: Int?)
  case eventsSubscribe(EventsSubscribeParams)
  case eventsWait(EventsWaitParams)
  case notificationShow(NotificationShowParams)
  /// 旧语法，原样转交 `workflow.execute`。
  case legacy([String])
}

/// 解析错误；`message` 直接打到 stderr，进程以 exit 2 退出。
public struct AsterCLIArgumentError: Error, Equatable, Sendable, CustomStringConvertible {
  public let message: String

  public init(_ message: String) { self.message = message }

  public var description: String { message }
}

/// 解析结果：全局选项 + 子命令。
public struct AsterCLIArguments: Equatable, Sendable {
  public static let maximumArguments = WorkflowCLIParser.maximumArguments
  public static let maximumArgumentBytes = WorkflowCLIParser.maximumArgumentBytes

  public var format: AsterCLIOutputFormat
  /// `--socket <abs path>`；nil 走 `ASTER_SOCKET_PATH` 或默认路径。
  public var socketPath: String?
  /// `--allow-outside`：允许在非 Aster 终端里调用 agent/events/notification 命令。
  public var allowOutside: Bool
  public var command: AsterCLICommand

  public init(
    format: AsterCLIOutputFormat = .text, socketPath: String? = nil, allowOutside: Bool = false,
    command: AsterCLICommand
  ) {
    self.format = format
    self.socketPath = socketPath
    self.allowOutside = allowOutside
    self.command = command
  }

  /// agent.* / events.* / notification.* 只对运行在 Aster 内的进程开放（需 `ASTER_ENV=1`），
  /// 其余命令（open/view/pane read 等）任意终端可用。
  public var requiresAsterEnv: Bool {
    switch command {
    case .agentList, .agentGet, .agentRead, .agentPrompt, .agentWait, .agentSendKeys, .agentFocus,
      .agentStart, .eventsSubscribe, .eventsWait, .notificationShow:
      return true
    case .help, .version, .skill, .sessionSnapshot, .paneRead, .paneSendText, .paneSendKeys,
      .paneFocus, .paneWaitForOutput, .legacy:
      return false
    }
  }

  /// 旧 WorkflowCLIParser 认识的顶层命令；`pane` 下的旧子命令单独判定。
  private static let legacyTopLevelCommands: Set<String> = [
    "open", "view", "edit", "watch", "jump", "learn", "ignore", "tab",
  ]
  private static let legacyPaneSubcommands: Set<String> = ["run", "exec", "capture"]
  /// 新语法命令组；只写组名等同 `--help`。
  private static let newSyntaxGroups: Set<String> = ["agent", "pane", "events", "notification", "session"]

  /// 入口：argv 不含程序名（若含 `aster`/`aster-cli` 会被剥掉）。
  public static func parse(_ rawArguments: [String]) throws -> AsterCLIArguments {
    guard rawArguments.count <= maximumArguments else {
      throw AsterCLIArgumentError("参数过多（最多 \(maximumArguments) 个）")
    }
    for argument in rawArguments where argument.utf8.count > maximumArgumentBytes {
      throw AsterCLIArgumentError("单个参数过长（最多 \(maximumArgumentBytes) 字节）")
    }
    var arguments = rawArguments
    if let first = arguments.first, first == "aster" || first == "aster-cli" {
      arguments.removeFirst()
    }

    var format = AsterCLIOutputFormat.text
    var socketPath: String?
    var allowOutside = false
    // 全局选项只在子命令之前识别；出现在子命令之后的 `--json` 由各子命令自己处理，
    // 以便旧语法 `aster pane capture --json` 也能整体落到 legacy。
    var legacyGlobalPrefix: [String] = []
    while let first = arguments.first {
      switch first {
      case "--json":
        arguments.removeFirst()
        format = .json
        legacyGlobalPrefix.append(first)
      case "--format":
        arguments.removeFirst()
        let value = try takeValue(&arguments, for: "--format")
        guard let parsed = AsterCLIOutputFormat(rawValue: value) else {
          throw AsterCLIArgumentError("--format 只支持 text 或 json")
        }
        format = parsed
        legacyGlobalPrefix.append(contentsOf: [first, value])
      case "--socket":
        arguments.removeFirst()
        let value = try takeValue(&arguments, for: "--socket")
        guard value.hasPrefix("/") else {
          throw AsterCLIArgumentError("--socket 必须是绝对路径")
        }
        socketPath = value
      case "--allow-outside":
        arguments.removeFirst()
        allowOutside = true
      case "-h", "--help", "help":
        return AsterCLIArguments(
          format: format, socketPath: socketPath, allowOutside: allowOutside, command: .help)
      case "--version", "version":
        return AsterCLIArguments(
          format: format, socketPath: socketPath, allowOutside: allowOutside, command: .version)
      case "--skill", "skill":
        return AsterCLIArguments(
          format: format, socketPath: socketPath, allowOutside: allowOutside, command: .skill)
      case "-q", "--quiet":
        // 旧脚本的全局静默选项：新语法不用，保留给 legacy。
        arguments.removeFirst()
        legacyGlobalPrefix.append(first)
      default:
        break
      }
      if arguments.first == first { break }
    }

    guard let group = arguments.first else {
      // 无参数等同 `--help`（与 herdr 不同：Aster 的 `aster` 无参不打开 App）。
      return AsterCLIArguments(
        format: format, socketPath: socketPath, allowOutside: allowOutside, command: .help)
    }
    arguments.removeFirst()
    // SKILL.md 教 agent 用「只写命令组」（`aster agent` / `aster pane` …）学语法：等同打印帮助，
    // 而不是报参数错——它是探索动作，不该以 exit 2 收场。
    if arguments.isEmpty, newSyntaxGroups.contains(group) {
      return AsterCLIArguments(
        format: format, socketPath: socketPath, allowOutside: allowOutside, command: .help)
    }

    let legacy = AsterCLIArguments(
      format: format, socketPath: socketPath, allowOutside: allowOutside,
      command: .legacy(legacyGlobalPrefix + [group] + arguments))
    // 新语法允许 `--json` / `--format` 写在子命令之后（SKILL.md 的习惯写法 `aster agent list --json`）；
    // legacy 上面已经拿到原始 argv，这里的剥离只影响新语法分支。`--` 之后属于 agent 自己的参数，不动。
    if newSyntaxGroups.contains(group) {
      format = try extractTrailingFormat(&arguments) ?? format
    }
    func make(_ command: AsterCLICommand) -> AsterCLIArguments {
      AsterCLIArguments(
        format: format, socketPath: socketPath, allowOutside: allowOutside, command: command)
    }

    switch group {
    case "agent":
      return make(try parseAgent(arguments))
    case "pane":
      guard let subcommand = arguments.first else {
        throw AsterCLIArgumentError("pane 需要子命令：read | send-text | send-keys | focus | wait-output")
      }
      if legacyPaneSubcommands.contains(subcommand) { return legacy }
      // send-text / send-keys 新旧语法重叠：旧写法带 `--from-file` / `--stdin` / `--` 时交回旧解析器。
      if subcommand == "send-text" || subcommand == "send-keys",
        arguments.contains(where: { $0 == "--from-file" || $0 == "--stdin" || $0 == "--" })
      {
        return legacy
      }
      return make(try parsePane(Array(arguments.dropFirst()), subcommand: subcommand))
    case "events":
      return make(try parseEvents(arguments))
    case "notification":
      return make(try parseNotification(arguments))
    case "session":
      guard arguments == ["snapshot"] else {
        throw AsterCLIArgumentError("session 只支持子命令 snapshot")
      }
      return make(.sessionSnapshot)
    default:
      if legacyTopLevelCommands.contains(group) { return legacy }
      throw AsterCLIArgumentError("未知命令: \(group)。运行 `aster --help` 查看用法")
    }
  }

  // MARK: agent

  private static func parseAgent(_ input: [String]) throws -> AsterCLICommand {
    guard let subcommand = input.first else {
      throw AsterCLIArgumentError(
        "agent 需要子命令：list | get | read | prompt | wait | send-keys | focus | start")
    }
    let arguments = Array(input.dropFirst())
    switch subcommand {
    case "list":
      try expectNoArguments(arguments, command: "agent list")
      return .agentList
    case "get":
      let parsed = try parseOptions(
        arguments, command: "agent get", flags: ["--current"], valued: [])
      let target = try requiredTarget(parsed, command: "agent get")
      return .agentGet(AgentTargetParams(target: target))
    case "focus":
      let parsed = try parseOptions(
        arguments, command: "agent focus", flags: ["--current"], valued: [])
      let target = try requiredTarget(parsed, command: "agent focus")
      return .agentFocus(AgentTargetParams(target: target))
    case "read":
      let parsed = try parseOptions(
        arguments, command: "agent read", flags: ["--current"], valued: ["--source", "--lines"])
      let target = try requiredTarget(parsed, command: "agent read")
      return .agentRead(
        AgentReadParams(
          target: target, source: try parsed.source(), lines: try parsed.int("--lines")))
    case "prompt":
      let parsed = try parseOptions(
        arguments, command: "agent prompt", flags: ["--current", "--wait", "--stdin"],
        valued: ["--until", "--timeout"])
      let target = try requiredTarget(parsed, command: "agent prompt")
      // `--current` 时 target 不占位置参数，正文从 positionals[0] 起。
      let body = parsed.positionals.dropFirst(parsed.flags.contains("--current") ? 0 : 1)
      let text: String?
      if parsed.flags.contains("--stdin") {
        guard body.isEmpty else {
          throw AsterCLIArgumentError("--stdin 与文本参数不能同时给出")
        }
        text = nil
      } else {
        guard !body.isEmpty else {
          throw AsterCLIArgumentError("agent prompt 需要 <target> <text>（或 --stdin）")
        }
        // 多段正文用空格拼接，方便不加引号地写短 prompt。
        text = body.joined(separator: " ")
      }
      let until = try parsed.statuses("--until")
      let timeout = try parsed.int("--timeout")
      // `--until` / `--timeout` 隐含 `--wait`。
      let wait: AgentWaitOptions? =
        (parsed.flags.contains("--wait") || !until.isEmpty || timeout != nil)
        ? AgentWaitOptions(until: until, timeoutMs: timeout) : nil
      return .agentPrompt(target: target, text: text, wait: wait)
    case "wait":
      let parsed = try parseOptions(
        arguments, command: "agent wait", flags: ["--current"], valued: ["--until", "--timeout"])
      let target = try requiredTarget(parsed, command: "agent wait")
      return .agentWait(
        AgentWaitParams(
          target: target, until: try parsed.statuses("--until"), timeoutMs: try parsed.int("--timeout")))
    case "send-keys":
      let parsed = try parseOptions(
        arguments, command: "agent send-keys", flags: ["--current"], valued: [])
      let target = try requiredTarget(parsed, command: "agent send-keys")
      let keys = Array(parsed.positionals.dropFirst(parsed.flags.contains("--current") ? 0 : 1))
      guard !keys.isEmpty else {
        throw AsterCLIArgumentError("agent send-keys 需要至少一个按键名")
      }
      try validateKeys(keys)
      return .agentSendKeys(AgentSendKeysParams(target: target, keys: keys))
    case "start":
      // `agent start <name> --kind <kind> [--pane id|--current] [--timeout ms] [-- args...]`
      // 与 SKILL.md / herdr 语法一致：name 是位置参数（agent 之后按名引用），kind 走 `--kind`。
      var head = arguments
      var extra: [String] = []
      if let separator = head.firstIndex(of: "--") {
        extra = Array(head[(separator + 1)...])
        head = Array(head[..<separator])
      }
      let parsed = try parseOptions(
        head, command: "agent start", flags: ["--current"], valued: ["--pane", "--kind", "--timeout"])
      guard parsed.positionals.count == 1 else {
        throw AsterCLIArgumentError("agent start 需要且只需要一个 <name>（如 reviewer），kind 用 --kind 指定")
      }
      guard let rawKind = parsed.values["--kind"] else {
        throw AsterCLIArgumentError("agent start 需要 --kind <kind>（如 codex、claude）")
      }
      guard let provider = resolveAgentKind(rawKind) else {
        throw AsterCLIArgumentError(
          "未知 agent kind: \(rawKind)。可用: " + AgentProvider.allCases.map(\.commandName).joined(separator: " | "))
      }
      let pane: String?
      if parsed.flags.contains("--current") {
        guard parsed.values["--pane"] == nil else {
          throw AsterCLIArgumentError("--current 与 --pane 不能同时给出")
        }
        pane = "current"
      } else {
        pane = parsed.values["--pane"]
      }
      let name = parsed.positionals[0]
      guard ControlTargetSelector.isValidAgentName(name) else {
        throw AsterCLIArgumentError("agent 名需匹配 [a-z][a-z0-9_-]{0,31}")
      }
      // kind 归一为 provider rawValue：服务端也接受命令名/别名，但统一形态便于日志与测试比对。
      let params = AgentStartParams(
        pane: pane, kind: provider.rawValue, name: name, args: extra,
        timeoutMs: try parsed.int("--timeout"))
      try mapValidation { try params.validate() }
      return .agentStart(params)
    default:
      throw AsterCLIArgumentError("未知子命令: agent \(subcommand)")
    }
  }

  // MARK: pane

  private static func parsePane(_ arguments: [String], subcommand: String) throws -> AsterCLICommand {
    switch subcommand {
    case "read":
      let parsed = try parseOptions(
        arguments, command: "pane read", flags: ["--current"], valued: ["--pane", "--source", "--lines"])
      return .paneRead(
        pane: try paneSelector(parsed, allowPositional: true, command: "pane read"),
        source: try parsed.source(), lines: try parsed.int("--lines"))
    case "focus":
      let parsed = try parseOptions(
        arguments, command: "pane focus", flags: ["--current"], valued: ["--pane"])
      return .paneFocus(pane: try paneSelector(parsed, allowPositional: true, command: "pane focus"))
    case "send-text":
      let parsed = try parseOptions(
        arguments, command: "pane send-text", flags: ["--current", "--enter"], valued: ["--pane"])
      // SKILL.md 写法 `pane send-text <pane> "text"`：两个位置参数时首个是 pane；
      // 一个位置参数时是纯文本（pane 走 --pane/--current/环境变量），与旧脚本兼容。
      var options = parsed
      var positionalPane: String?
      if options.positionals.count == 2, options.values["--pane"] == nil, !options.flags.contains("--current") {
        positionalPane = options.positionals.removeFirst()
        if ControlTargetSelector(parsing: positionalPane!) == nil {
          throw AsterCLIArgumentError("非法 pane: \(positionalPane!)")
        }
      }
      let pane = try positionalPane ?? paneSelector(options, allowPositional: false, command: "pane send-text")
      // 空文本 + --enter 合法（只按回车）；其它情况必须有正文。
      guard options.positionals.count <= 1 else {
        throw AsterCLIArgumentError("pane send-text 只接受一个文本参数（请加引号）")
      }
      let text = options.positionals.first ?? ""
      guard !text.isEmpty || options.flags.contains("--enter") else {
        throw AsterCLIArgumentError("pane send-text 需要文本参数或 --enter")
      }
      return .paneSendText(pane: pane, text: text, enter: options.flags.contains("--enter"))
    case "send-keys":
      let parsed = try parseOptions(
        arguments, command: "pane send-keys", flags: ["--current"], valued: ["--pane"])
      let pane = try paneSelector(parsed, allowPositional: false, command: "pane send-keys")
      guard !parsed.positionals.isEmpty else {
        throw AsterCLIArgumentError("pane send-keys 需要至少一个按键名")
      }
      try validateKeys(parsed.positionals)
      return .paneSendKeys(pane: pane, keys: parsed.positionals)
    case "wait-output":
      let parsed = try parseOptions(
        arguments, command: "pane wait-output", flags: ["--current"],
        valued: ["--pane", "--match", "--regex", "--source", "--lines", "--timeout"])
      let pane = try paneSelector(parsed, allowPositional: true, command: "pane wait-output")
      let match = parsed.values["--match"]
      let regex = parsed.values["--regex"]
      switch (match, regex) {
      case (nil, nil): throw AsterCLIArgumentError("pane wait-output 需要 --match 或 --regex")
      case (.some, .some): throw AsterCLIArgumentError("--match 与 --regex 只能给一个")
      default: break
      }
      if let regex, (try? NSRegularExpression(pattern: regex)) == nil {
        throw AsterCLIArgumentError("--regex 无法编译")
      }
      return .paneWaitForOutput(
        pane: pane, match: match, regex: regex, source: try parsed.source(),
        lines: try parsed.int("--lines"), timeoutMs: try parsed.int("--timeout"))
    default:
      throw AsterCLIArgumentError("未知子命令: pane \(subcommand)")
    }
  }

  // MARK: events / notification

  private static func parseEvents(_ input: [String]) throws -> AsterCLICommand {
    guard let subcommand = input.first else {
      throw AsterCLIArgumentError("events 需要子命令：subscribe | wait")
    }
    let arguments = Array(input.dropFirst())
    switch subcommand {
    case "subscribe":
      let parsed = try parseOptions(
        arguments, command: "events subscribe", flags: [], valued: ["--kind"], repeatable: ["--kind"])
      try expectNoPositionals(parsed, command: "events subscribe")
      return .eventsSubscribe(EventsSubscribeParams(kinds: try parsed.eventKinds("--kind")))
    case "wait":
      let parsed = try parseOptions(
        arguments, command: "events wait", flags: ["--current"],
        valued: ["--kind", "--pane", "--after-sequence", "--timeout"])
      try expectNoPositionals(parsed, command: "events wait")
      let kinds = try parsed.eventKinds("--kind")
      let pane: String?
      if parsed.flags.contains("--current") {
        guard parsed.values["--pane"] == nil else {
          throw AsterCLIArgumentError("--current 与 --pane 不能同时给出")
        }
        pane = "current"
      } else {
        pane = parsed.values["--pane"]
      }
      let after = try parsed.int("--after-sequence")
      if let after, after < 0 { throw AsterCLIArgumentError("--after-sequence 不能为负") }
      return .eventsWait(
        EventsWaitParams(
          kind: kinds.first, pane: pane, afterSequence: after.map(UInt64.init),
          timeoutMs: try parsed.int("--timeout")))
    default:
      throw AsterCLIArgumentError("未知子命令: events \(subcommand)")
    }
  }

  private static func parseNotification(_ input: [String]) throws -> AsterCLICommand {
    guard input.first == "show" else {
      throw AsterCLIArgumentError("notification 只支持子命令 show")
    }
    let parsed = try parseOptions(
      Array(input.dropFirst()), command: "notification show", flags: [],
      valued: ["--body", "--urgency"])
    guard parsed.positionals.count == 1 else {
      throw AsterCLIArgumentError("notification show 需要且只需要一个 <title>")
    }
    var urgency = NotificationUrgency.normal
    if let raw = parsed.values["--urgency"] {
      guard let value = NotificationUrgency(rawValue: raw) else {
        throw AsterCLIArgumentError("--urgency 只支持 low | normal | critical")
      }
      urgency = value
    }
    let params = NotificationShowParams(
      title: parsed.positionals[0], body: parsed.values["--body"], urgency: urgency)
    try mapValidation { try params.validate() }
    return .notificationShow(params)
  }

  // MARK: 通用选项扫描

  /// 一次扫描得到的选项集合。
  private struct ParsedOptions {
    var flags: Set<String> = []
    var values: [String: String] = [:]
    var repeated: [String: [String]] = [:]
    var positionals: [String] = []

    func int(_ option: String) throws -> Int? {
      guard let raw = values[option] else { return nil }
      guard let value = Int(raw), value >= 0 else {
        throw AsterCLIArgumentError("\(option) 需要非负整数")
      }
      return value
    }

    func source() throws -> PaneReadSource {
      guard let raw = values["--source"] else { return .visible }
      guard let value = PaneReadSource(rawValue: raw) else {
        throw AsterCLIArgumentError("--source 只支持 visible | recent")
      }
      return value
    }

    /// `--until idle,done,blocked`：逗号分隔，unknown 不接受。
    func statuses(_ option: String) throws -> [AgentControlStatus] {
      guard let raw = values[option] else { return [] }
      return try raw.split(separator: ",").map { piece in
        let name = piece.trimmingCharacters(in: .whitespaces)
        guard let status = AgentControlStatus(rawValue: name), status != .unknown else {
          throw AsterCLIArgumentError("\(option) 只支持 idle | working | blocked | done")
        }
        return status
      }
    }

    func eventKinds(_ option: String) throws -> [AsterControlEventKind] {
      var raws = repeated[option] ?? []
      if let single = values[option] { raws.append(single) }
      return try raws.flatMap { $0.split(separator: ",") }.map { piece in
        let name = piece.trimmingCharacters(in: .whitespaces)
        guard let kind = AsterControlEventKind(rawValue: name) else {
          throw AsterCLIArgumentError(
            "\(option) 只支持 "
              + AsterControlEventKind.allCases.map(\.rawValue).joined(separator: " | "))
        }
        return kind
      }
    }
  }

  /// 通用扫描：`flags` 是布尔选项，`valued` 是带值选项；`repeatable` 里的带值选项允许重复。
  /// `--opt=value` 与 `--opt value` 都接受；其它 `-` 开头的参数报未知选项。
  private static func parseOptions(
    _ arguments: [String], command: String, flags: Set<String>, valued: Set<String>,
    repeatable: Set<String> = []
  ) throws -> ParsedOptions {
    var result = ParsedOptions()
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      if argument == "-" || !argument.hasPrefix("-") {
        result.positionals.append(argument)
        continue
      }
      var name = argument
      var inlineValue: String?
      if let equals = argument.firstIndex(of: "="), argument.hasPrefix("--") {
        name = String(argument[..<equals])
        inlineValue = String(argument[argument.index(after: equals)...])
      }
      if flags.contains(name) {
        guard inlineValue == nil else { throw AsterCLIArgumentError("\(name) 不接受值") }
        guard result.flags.insert(name).inserted else {
          throw AsterCLIArgumentError("\(name) 重复给出")
        }
        continue
      }
      if valued.contains(name) {
        let value: String
        if let inlineValue {
          value = inlineValue
        } else {
          guard index < arguments.count else {
            throw AsterCLIArgumentError("\(name) 缺少值")
          }
          value = arguments[index]
          index += 1
        }
        if repeatable.contains(name) {
          result.repeated[name, default: []].append(value)
        } else {
          guard result.values[name] == nil else {
            throw AsterCLIArgumentError("\(name) 重复给出")
          }
          result.values[name] = value
        }
        continue
      }
      throw AsterCLIArgumentError("\(command) 不支持选项 \(name)")
    }
    return result
  }

  /// agent 命令的 target：`--current` 或第一个位置参数。
  private static func requiredTarget(_ parsed: ParsedOptions, command: String) throws -> String {
    if parsed.flags.contains("--current") {
      guard parsed.positionals.isEmpty || command == "agent prompt" || command == "agent send-keys"
      else {
        throw AsterCLIArgumentError("\(command) 不能同时给出 <target> 与 --current")
      }
      return "current"
    }
    guard let target = parsed.positionals.first else {
      throw AsterCLIArgumentError("\(command) 需要 <target>（短 ID、agent 名或 --current）")
    }
    guard ControlTargetSelector(parsing: target) != nil else {
      throw AsterCLIArgumentError("非法 target: \(target)")
    }
    return target
  }

  /// pane 命令的 selector：`--current` / `--pane <id>` / 可选的首个位置参数；都没有则 nil。
  private static func paneSelector(
    _ parsed: ParsedOptions, allowPositional: Bool, command: String
  ) throws -> String? {
    var candidates: [String] = []
    if parsed.flags.contains("--current") { candidates.append("current") }
    if let explicit = parsed.values["--pane"] { candidates.append(explicit) }
    guard candidates.count <= 1 else {
      throw AsterCLIArgumentError("--current 与 --pane 不能同时给出")
    }
    if candidates.isEmpty, allowPositional, let positional = parsed.positionals.first {
      guard parsed.positionals.count == 1 else {
        throw AsterCLIArgumentError("\(command) 只接受一个 pane 参数")
      }
      candidates.append(positional)
    } else if allowPositional, !parsed.positionals.isEmpty {
      throw AsterCLIArgumentError("\(command) 不能同时给出位置参数与 --pane/--current")
    }
    guard let selector = candidates.first else { return nil }
    guard ControlTargetSelector(parsing: selector) != nil else {
      throw AsterCLIArgumentError("非法 pane: \(selector)")
    }
    return selector
  }

  /// kind 接受 provider rawValue、命令名或可执行别名（不区分大小写），与服务端解析一致。
  public static func resolveAgentKind(_ kind: String) -> AgentProvider? {
    if let provider = AgentProvider(rawValue: kind) { return provider }
    let lowered = kind.lowercased()
    return AgentProvider.allCases.first {
      $0.rawValue.lowercased() == lowered || $0.commandName.lowercased() == lowered
        || $0.executableAliases.contains(lowered)
    }
  }

  private static func validateKeys(_ keys: [String]) throws {
    guard keys.count <= AsterControlProtocol.maximumKeys else {
      throw AsterCLIArgumentError("按键最多 \(AsterControlProtocol.maximumKeys) 个")
    }
    for key in keys where !AsterControlKeyEncoder.isKnown(key) {
      throw AsterCLIArgumentError("未知按键名: \(key)")
    }
  }

  private static func expectNoArguments(_ arguments: [String], command: String) throws {
    guard arguments.isEmpty else {
      throw AsterCLIArgumentError("\(command) 不接受参数: \(arguments[0])")
    }
  }

  private static func expectNoPositionals(_ parsed: ParsedOptions, command: String) throws {
    guard parsed.positionals.isEmpty else {
      throw AsterCLIArgumentError("\(command) 不接受位置参数: \(parsed.positionals[0])")
    }
  }

  /// 从子命令参数里摘走 `--json` / `--format <v>` / `--format=<v>`（只扫到 `--` 为止），返回指定的格式。
  private static func extractTrailingFormat(_ arguments: inout [String]) throws -> AsterCLIOutputFormat? {
    var format: AsterCLIOutputFormat?
    var kept: [String] = []
    var index = 0
    while index < arguments.count {
      let argument = arguments[index]
      index += 1
      if argument == "--" {
        kept.append(contentsOf: arguments[(index - 1)...])
        break
      }
      if argument == "--json" {
        format = .json
        continue
      }
      var value: String?
      if argument == "--format" {
        guard index < arguments.count else { throw AsterCLIArgumentError("--format 缺少值") }
        value = arguments[index]
        index += 1
      } else if argument.hasPrefix("--format=") {
        value = String(argument.dropFirst("--format=".count))
      }
      if let value {
        guard let parsed = AsterCLIOutputFormat(rawValue: value) else {
          throw AsterCLIArgumentError("--format 只支持 text 或 json")
        }
        format = parsed
        continue
      }
      kept.append(argument)
    }
    arguments = kept
    return format
  }

  private static func takeValue(_ arguments: inout [String], for option: String) throws -> String {
    guard !arguments.isEmpty else { throw AsterCLIArgumentError("\(option) 缺少值") }
    return arguments.removeFirst()
  }

  /// 把协议层 validate 的 invalid_params 转成 CLI 错误，保持 exit 2 语义。
  private static func mapValidation(_ body: () throws -> Void) throws {
    do {
      try body()
    } catch let error as AsterControlError {
      throw AsterCLIArgumentError(error.message)
    }
  }

  /// `--help` 文本；CLI 与 SKILL.md 都引用它，语法只在此处维护一份。
  public static let usage = """
    用法: aster [--json|--format text|json] [--socket <path>] [--allow-outside] <命令>

    Agent（需在 Aster 终端内运行，ASTER_ENV=1）:
      agent list
      agent get <target>|--current
      agent read <target>|--current [--source visible|recent] [--lines N]
      agent prompt <target>|--current <text...>|--stdin [--wait] [--until idle,done,blocked] [--timeout ms]
      agent wait <target>|--current [--until idle,done,blocked] [--timeout ms]
      agent send-keys <target>|--current <key>...
      agent focus <target>|--current
      agent start <name> --kind <kind> [--pane <id>|--current] [--timeout ms] [-- <args>...]

    Pane:
      pane read [<pane>|--pane <id>|--current] [--source visible|recent] [--lines N]
      pane send-text [<pane>|--pane <id>|--current] <text> [--enter]
      pane send-keys [--pane <id>|--current] <key>...
      pane focus [<pane>|--pane <id>|--current]
      pane wait-output [<pane>|--pane <id>|--current] (--match <text>|--regex <re>) [--source ...] [--lines N] [--timeout ms]

    事件与通知（需 ASTER_ENV=1）:
      events subscribe [--kind <kind>]...
      events wait [--kind <kind>] [--pane <id>|--current] [--after-sequence N] [--timeout ms]
      notification show <title> [--body <text>] [--urgency low|normal|critical]

    其它:
      session snapshot
      --skill        打印 Aster skill 文档
      --version      打印版本
      --help         本帮助

    旧命令（open/view/edit/watch/jump/learn/ignore/pane run|exec|capture）继续可用。
    target/pane 形态：w1:p5 短 ID、agent 名、current、p_<UUID>。
    只写命令组（如 `aster agent`）等同本帮助。
    """
}
