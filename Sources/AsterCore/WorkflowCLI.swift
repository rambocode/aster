import Foundation

public enum WorkflowCLIOutputFormat: String, Codable, Equatable, Sendable {
  case text
  case json
}

public struct WorkflowCLIOpenAction: Equatable, Sendable {
  public let path: String
  public let command: String?
  public let title: String?

  public init(path: String, command: String? = nil, title: String? = nil) {
    self.path = path
    self.command = command
    self.title = title
  }
}

public enum WorkflowCLITarget: Equatable, Sendable {
  case localPath(String)
  case webURL(String)
  /// CLI 文档承诺的 `user@host:/path` 描述；解析层不建立 SSH 连接。
  case remotePath(String)
}

public enum WorkflowCLIFileMode: String, Codable, Equatable, Sendable {
  case view
  case edit
}

public enum WorkflowCLIPlacement: Equatable, Sendable {
  case newTab
  case newWindow
  case split(SplitDirection)
}

public struct WorkflowCLIOpenTargetAction: Equatable, Sendable {
  public let target: WorkflowCLITarget
  public let mode: WorkflowCLIFileMode
  public let placement: WorkflowCLIPlacement

  public init(target: WorkflowCLITarget, mode: WorkflowCLIFileMode, placement: WorkflowCLIPlacement)
  {
    self.target = target
    self.mode = mode
    self.placement = placement
  }
}

public struct WorkflowCLIWatchAction: Equatable, Sendable {
  public let command: [String]
  public let postsNotification: Bool

  public init(command: [String], postsNotification: Bool = true) {
    self.command = command
    self.postsNotification = postsNotification
  }
}

public struct WorkflowCLIJumpAction: Equatable, Sendable {
  public let query: String?
  public let noCD: Bool

  public init(query: String? = nil, noCD: Bool = false) {
    self.query = query
    self.noCD = noCD
  }
}

public struct WorkflowCLILearnAction: Equatable, Sendable {
  public let target: String?
  public let assumeYes: Bool

  public init(target: String? = nil, assumeYes: Bool = false) {
    self.target = target
    self.assumeYes = assumeYes
  }
}

public struct WorkflowCLIIgnoreAction: Equatable, Sendable {
  public let target: String

  public init(target: String) {
    self.target = target
  }
}

public enum WorkflowCLISendInput: Equatable, Sendable {
  /// C-style escapes remain encoded; only the delivery boundary may turn them into control bytes.
  case text(String)
  case keys([String])
  case file(String)
  case standardInput
}

public struct WorkflowCLISendAction: Equatable, Sendable {
  public let selector: String?
  public let input: WorkflowCLISendInput

  public init(selector: String? = nil, input: WorkflowCLISendInput) {
    self.selector = selector
    self.input = input
  }
}

public struct WorkflowCLIRunAction: Equatable, Sendable {
  public let selector: String?
  public let command: [String]
  public let format: WorkflowCLIOutputFormat

  public init(
    selector: String? = nil,
    command: [String],
    format: WorkflowCLIOutputFormat = .text
  ) {
    self.selector = selector
    self.command = command
    self.format = format
  }
}

public struct WorkflowCLIExecAction: Equatable, Sendable {
  public let selector: String?
  public let command: [String]
  public let format: WorkflowCLIOutputFormat

  public init(
    selector: String? = nil,
    command: [String],
    format: WorkflowCLIOutputFormat = .text
  ) {
    self.selector = selector
    self.command = command
    self.format = format
  }
}

public struct WorkflowCLICaptureAction: Equatable, Sendable {
  public let selector: String?
  public let lines: Int?
  public let format: WorkflowCLIOutputFormat

  public init(
    selector: String? = nil,
    lines: Int? = nil,
    format: WorkflowCLIOutputFormat = .text
  ) {
    self.selector = selector
    self.lines = lines
    self.format = format
  }
}

/// CLI 解析结果只描述意图；它不启动 App、发送按键、运行命令或读取 Pane。
public enum WorkflowCLIAction: Equatable, Sendable {
  case open(WorkflowCLIOpenAction)
  case openTarget(WorkflowCLIOpenTargetAction)
  case watch(WorkflowCLIWatchAction)
  case jump(WorkflowCLIJumpAction)
  case learn(WorkflowCLILearnAction)
  case ignore(WorkflowCLIIgnoreAction)
  case send(WorkflowCLISendAction)
  case run(WorkflowCLIRunAction)
  case exec(WorkflowCLIExecAction)
  case capture(WorkflowCLICaptureAction)

  /// 写 Pane 的动作必须先通过 `IPC Allow Send Keys`；Capture 只读，不需要该权限。
  public var requiresIPCAllowSendKeys: Bool {
    switch self {
    case .send, .run, .exec: true
    default: false
    }
  }

  /// 写入 SSH 或 sudo Pane 时，交付层还必须检查 `IPC Allow Sensitive Sessions`。
  public var requiresSensitiveSessionOptInWhenTargetIsSensitive: Bool {
    requiresIPCAllowSendKeys
  }
}

public enum WorkflowCLIParseError: Error, Equatable {
  case commandMissing
  case unsupportedCommand(String)
  case unsupportedOption(String)
  case missingValue(String)
  case duplicateOption(String)
  case unexpectedArgument(String)
  case commandRequired(String)
  case invalidValue(String)
  case valueOutOfRange(String)
  case conflictingPlacement
  case conflictingInput
  case tooManyArguments
  case argumentTooLong(Int)
  case inputTooLarge
  case invalidCurrentDirectory
}

/// Otty Workflows 稳定 CLI 子集的有界纯解析器。
public struct WorkflowCLIParser: Sendable {
  public static let maximumArguments = 256
  public static let maximumArgumentBytes = 4_096
  public static let maximumTotalBytes = 64 * 1_024
  public static let maximumCommandArguments = 128
  public static let maximumCaptureLines = 10_000

  public let currentDirectory: String

  public init(currentDirectory: String) {
    self.currentDirectory = currentDirectory
  }

  public func parse(_ rawArguments: [String]) throws -> WorkflowCLIAction {
    try validateArguments(rawArguments)
    var arguments = rawArguments
    if arguments.first == "otty" { arguments.removeFirst() }
    var globalFormat = WorkflowCLIOutputFormat.text
    var globalQuiet = false
    while let first = arguments.first {
      switch first {
      case "--format":
        arguments.removeFirst()
        globalFormat = try parseFormat(try takeValue(&arguments, for: "--format"))
      case "--json":
        arguments.removeFirst()
        globalFormat = .json
      case "-q", "--quiet":
        arguments.removeFirst()
        globalQuiet = true
      default:
        break
      }
      if arguments.first == first { break }
    }
    guard !arguments.isEmpty else { throw WorkflowCLIParseError.commandMissing }
    let command = arguments.removeFirst()
    switch command {
    case "open":
      return .open(try parseOpen(arguments))
    case "view":
      return .openTarget(try parseOpenTarget(arguments, defaultMode: .view))
    case "edit":
      return .openTarget(try parseOpenTarget(arguments, defaultMode: .edit))
    case "watch":
      return .watch(try parseWatch(arguments, globallyQuiet: globalQuiet))
    case "jump":
      return .jump(try parseJump(arguments))
    case "learn":
      return .learn(try parseLearn(arguments))
    case "ignore":
      return .ignore(try parseIgnore(arguments))
    case "pane":
      return try parsePane(arguments, globalFormat: globalFormat)
    default:
      throw WorkflowCLIParseError.unsupportedCommand(command)
    }
  }

  private func parseOpen(_ input: [String]) throws -> WorkflowCLIOpenAction {
    var arguments = input
    var path: String?
    var command: String?
    var title: String?
    while !arguments.isEmpty {
      let argument = arguments.removeFirst()
      switch argument {
      case "--command":
        guard command == nil else { throw WorkflowCLIParseError.duplicateOption(argument) }
        command = try takeValue(&arguments, for: argument)
      case "--title":
        guard title == nil else { throw WorkflowCLIParseError.duplicateOption(argument) }
        title = try takeValue(&arguments, for: argument)
      default:
        if argument.hasPrefix("-") { throw WorkflowCLIParseError.unsupportedOption(argument) }
        guard path == nil else { throw WorkflowCLIParseError.unexpectedArgument(argument) }
        path = argument
      }
    }
    if let command, command.isEmpty { throw WorkflowCLIParseError.commandRequired("open") }
    if let title, title.isEmpty { throw WorkflowCLIParseError.invalidValue("--title") }
    return WorkflowCLIOpenAction(
      path: try resolveLocalPath(path ?? currentDirectory),
      command: command,
      title: title
    )
  }

  private func parseOpenTarget(
    _ input: [String],
    defaultMode: WorkflowCLIFileMode
  ) throws -> WorkflowCLIOpenTargetAction {
    var arguments = input
    var target: String?
    var mode = defaultMode
    var placement = WorkflowCLIPlacement.newTab
    var placementWasSet = false
    while !arguments.isEmpty {
      let argument = arguments.removeFirst()
      switch argument {
      case "--mode":
        let rawMode = try takeValue(&arguments, for: argument)
        guard let parsed = WorkflowCLIFileMode(rawValue: rawMode) else {
          throw WorkflowCLIParseError.invalidValue(argument)
        }
        mode = parsed
      case "--new-tab":
        try setPlacement(.newTab, flag: argument, placement: &placement, wasSet: &placementWasSet)
      case "--new-window":
        try setPlacement(
          .newWindow, flag: argument, placement: &placement, wasSet: &placementWasSet)
      case "--left":
        try setPlacement(
          .split(.left), flag: argument, placement: &placement, wasSet: &placementWasSet)
      case "--right":
        try setPlacement(
          .split(.right), flag: argument, placement: &placement, wasSet: &placementWasSet)
      case "--top":
        try setPlacement(
          .split(.up), flag: argument, placement: &placement, wasSet: &placementWasSet)
      case "--bottom":
        try setPlacement(
          .split(.down), flag: argument, placement: &placement, wasSet: &placementWasSet)
      default:
        if argument.hasPrefix("-") { throw WorkflowCLIParseError.unsupportedOption(argument) }
        guard target == nil else { throw WorkflowCLIParseError.unexpectedArgument(argument) }
        target = argument
      }
    }
    guard let target else { throw WorkflowCLIParseError.missingValue("target") }
    return WorkflowCLIOpenTargetAction(
      target: try parseTarget(target),
      mode: mode,
      placement: placement
    )
  }

  private func parseWatch(
    _ input: [String],
    globallyQuiet: Bool
  ) throws -> WorkflowCLIWatchAction {
    var arguments = input
    var quiet = globallyQuiet
    while let first = arguments.first, first == "-q" || first == "--quiet" {
      quiet = true
      arguments.removeFirst()
    }
    if arguments.first == "--" { arguments.removeFirst() }
    try validateCommand(arguments, named: "watch")
    return WorkflowCLIWatchAction(command: arguments, postsNotification: !quiet)
  }

  private func parseJump(_ input: [String]) throws -> WorkflowCLIJumpAction {
    var query: String?
    var noCD = false
    for argument in input {
      if argument == "--no-cd" {
        guard !noCD else { throw WorkflowCLIParseError.duplicateOption(argument) }
        noCD = true
      } else if argument.hasPrefix("-") {
        throw WorkflowCLIParseError.unsupportedOption(argument)
      } else if query == nil {
        guard !argument.isEmpty else { throw WorkflowCLIParseError.invalidValue("query") }
        query = argument
      } else {
        throw WorkflowCLIParseError.unexpectedArgument(argument)
      }
    }
    return WorkflowCLIJumpAction(query: query, noCD: noCD)
  }

  private func parseLearn(_ input: [String]) throws -> WorkflowCLILearnAction {
    var target: String?
    var assumeYes = false
    for argument in input {
      if argument == "-y" || argument == "--yes" {
        guard !assumeYes else { throw WorkflowCLIParseError.duplicateOption(argument) }
        assumeYes = true
      } else if target == nil {
        guard !argument.isEmpty else { throw WorkflowCLIParseError.invalidValue("target") }
        target = argument
      } else {
        throw WorkflowCLIParseError.unexpectedArgument(argument)
      }
    }
    return WorkflowCLILearnAction(target: target, assumeYes: assumeYes)
  }

  private func parseIgnore(_ input: [String]) throws -> WorkflowCLIIgnoreAction {
    guard let target = input.first else { throw WorkflowCLIParseError.missingValue("target") }
    guard !target.isEmpty else { throw WorkflowCLIParseError.invalidValue("target") }
    guard input.count == 1 else {
      throw WorkflowCLIParseError.unexpectedArgument(input[1])
    }
    return WorkflowCLIIgnoreAction(target: target)
  }

  private func parsePane(
    _ input: [String],
    globalFormat: WorkflowCLIOutputFormat
  ) throws -> WorkflowCLIAction {
    var arguments = input
    guard let subcommand = arguments.first else { throw WorkflowCLIParseError.commandMissing }
    arguments.removeFirst()
    switch subcommand {
    case "send-text", "send-keys":
      return .send(try parseSend(arguments, sendsKeys: subcommand == "send-keys"))
    case "run":
      let parsed = try parsePaneCommand(arguments, named: "run", globalFormat: globalFormat)
      return .run(.init(selector: parsed.selector, command: parsed.command, format: parsed.format))
    case "exec":
      let parsed = try parsePaneCommand(arguments, named: "exec", globalFormat: globalFormat)
      return .exec(.init(selector: parsed.selector, command: parsed.command, format: parsed.format))
    case "capture":
      return .capture(try parseCapture(arguments, globalFormat: globalFormat))
    default:
      throw WorkflowCLIParseError.unsupportedCommand("pane \(subcommand)")
    }
  }

  private func parseSend(_ input: [String], sendsKeys: Bool) throws -> WorkflowCLISendAction {
    var arguments = input
    var selector: String?
    var explicitInput: WorkflowCLISendInput?
    var positional: [String] = []
    var afterSeparator = false
    while !arguments.isEmpty {
      let argument = arguments.removeFirst()
      if afterSeparator {
        positional.append(argument)
        continue
      }
      switch argument {
      case "--":
        afterSeparator = true
      case "--pane":
        guard selector == nil else { throw WorkflowCLIParseError.duplicateOption(argument) }
        selector = try validatedSelector(try takeValue(&arguments, for: argument))
      case "--from-file" where !sendsKeys:
        guard explicitInput == nil else { throw WorkflowCLIParseError.conflictingInput }
        explicitInput = .file(try resolveLocalPath(try takeValue(&arguments, for: argument)))
      case "--stdin" where !sendsKeys:
        guard explicitInput == nil else { throw WorkflowCLIParseError.conflictingInput }
        explicitInput = .standardInput
      default:
        if argument.hasPrefix("-"), !afterSeparator {
          throw WorkflowCLIParseError.unsupportedOption(argument)
        }
        positional.append(argument)
      }
    }
    if let explicitInput {
      guard positional.isEmpty else { throw WorkflowCLIParseError.conflictingInput }
      return WorkflowCLISendAction(selector: selector, input: explicitInput)
    }
    if sendsKeys {
      guard !positional.isEmpty else { throw WorkflowCLIParseError.missingValue("keys") }
      return WorkflowCLISendAction(selector: selector, input: .keys(positional))
    }
    guard positional.count == 1 else {
      if positional.isEmpty { throw WorkflowCLIParseError.missingValue("text") }
      throw WorkflowCLIParseError.unexpectedArgument(positional[1])
    }
    return WorkflowCLISendAction(selector: selector, input: .text(positional[0]))
  }

  private func parsePaneCommand(
    _ input: [String],
    named name: String,
    globalFormat: WorkflowCLIOutputFormat
  ) throws -> (selector: String?, command: [String], format: WorkflowCLIOutputFormat) {
    var arguments = input
    var selector: String?
    var format = globalFormat
    var command: [String] = []
    while !arguments.isEmpty {
      let argument = arguments.removeFirst()
      switch argument {
      case "--pane" where command.isEmpty:
        guard selector == nil else { throw WorkflowCLIParseError.duplicateOption(argument) }
        selector = try validatedSelector(try takeValue(&arguments, for: argument))
      case "--format" where command.isEmpty:
        format = try parseFormat(try takeValue(&arguments, for: argument))
      case "--json" where command.isEmpty:
        format = .json
      case "--" where command.isEmpty:
        command = arguments
        arguments.removeAll()
      default:
        if command.isEmpty, argument.hasPrefix("-") {
          throw WorkflowCLIParseError.unsupportedOption(argument)
        }
        command = [argument] + arguments
        arguments.removeAll()
      }
    }
    try validateCommand(command, named: name)
    return (selector, command, format)
  }

  private func parseCapture(
    _ input: [String],
    globalFormat: WorkflowCLIOutputFormat
  ) throws -> WorkflowCLICaptureAction {
    var arguments = input
    var selector: String?
    var lines: Int?
    var format = globalFormat
    while !arguments.isEmpty {
      let argument = arguments.removeFirst()
      switch argument {
      case "--pane":
        guard selector == nil else { throw WorkflowCLIParseError.duplicateOption(argument) }
        selector = try validatedSelector(try takeValue(&arguments, for: argument))
      case "--lines":
        guard lines == nil else { throw WorkflowCLIParseError.duplicateOption(argument) }
        guard let parsed = Int(try takeValue(&arguments, for: argument)) else {
          throw WorkflowCLIParseError.invalidValue(argument)
        }
        guard (1...Self.maximumCaptureLines).contains(parsed) else {
          throw WorkflowCLIParseError.valueOutOfRange(argument)
        }
        lines = parsed
      case "--format":
        format = try parseFormat(try takeValue(&arguments, for: argument))
      case "--json":
        format = .json
      default:
        throw WorkflowCLIParseError.unsupportedOption(argument)
      }
    }
    return WorkflowCLICaptureAction(selector: selector, lines: lines, format: format)
  }

  private func parseTarget(_ rawTarget: String) throws -> WorkflowCLITarget {
    guard !rawTarget.isEmpty else { throw WorkflowCLIParseError.invalidValue("target") }
    if let url = URL(string: rawTarget), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https"
    {
      guard url.host != nil else { throw WorkflowCLIParseError.invalidValue("target") }
      return .webURL(url.absoluteString)
    }
    if isRemotePath(rawTarget) { return .remotePath(rawTarget) }
    return .localPath(try resolveLocalPath(rawTarget))
  }

  private func isRemotePath(_ value: String) -> Bool {
    guard !value.hasPrefix("/"), let colon = value.firstIndex(of: ":") else { return false }
    let host = value[..<colon]
    let path = value[value.index(after: colon)...]
    return !host.isEmpty && !path.isEmpty && !host.contains("/")
  }

  private func resolveLocalPath(_ rawPath: String) throws -> String {
    guard currentDirectory.hasPrefix("/") else {
      throw WorkflowCLIParseError.invalidCurrentDirectory
    }
    let expanded = (rawPath as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
      return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
    return URL(
      fileURLWithPath: expanded,
      relativeTo: URL(fileURLWithPath: currentDirectory, isDirectory: true)
    ).standardizedFileURL.path
  }

  private func setPlacement(
    _ newValue: WorkflowCLIPlacement,
    flag: String,
    placement: inout WorkflowCLIPlacement,
    wasSet: inout Bool
  ) throws {
    guard !wasSet else { throw WorkflowCLIParseError.conflictingPlacement }
    placement = newValue
    wasSet = true
  }

  private func validatedSelector(_ selector: String) throws -> String {
    guard !selector.isEmpty, selector.utf8.count <= 256 else {
      throw WorkflowCLIParseError.invalidValue("--pane")
    }
    return selector
  }

  private func parseFormat(_ value: String) throws -> WorkflowCLIOutputFormat {
    guard let format = WorkflowCLIOutputFormat(rawValue: value) else {
      throw WorkflowCLIParseError.invalidValue("--format")
    }
    return format
  }

  private func validateCommand(_ command: [String], named name: String) throws {
    guard !command.isEmpty, command.allSatisfy({ !$0.isEmpty }) else {
      throw WorkflowCLIParseError.commandRequired(name)
    }
    guard command.count <= Self.maximumCommandArguments else {
      throw WorkflowCLIParseError.tooManyArguments
    }
    guard command.reduce(0, { $0 + $1.utf8.count }) <= Self.maximumTotalBytes else {
      throw WorkflowCLIParseError.inputTooLarge
    }
  }

  private func takeValue(_ arguments: inout [String], for flag: String) throws -> String {
    guard !arguments.isEmpty else { throw WorkflowCLIParseError.missingValue(flag) }
    return arguments.removeFirst()
  }

  private func validateArguments(_ arguments: [String]) throws {
    guard arguments.count <= Self.maximumArguments else {
      throw WorkflowCLIParseError.tooManyArguments
    }
    var totalBytes = 0
    for (index, argument) in arguments.enumerated() {
      guard argument.utf8.count <= Self.maximumArgumentBytes else {
        throw WorkflowCLIParseError.argumentTooLong(index)
      }
      guard
        !argument.unicodeScalars.contains(where: {
          CharacterSet.controlCharacters.contains($0)
        })
      else { throw WorkflowCLIParseError.invalidValue("argument \(index)") }
      totalBytes += argument.utf8.count
      guard totalBytes <= Self.maximumTotalBytes else {
        throw WorkflowCLIParseError.inputTooLarge
      }
    }
  }
}
