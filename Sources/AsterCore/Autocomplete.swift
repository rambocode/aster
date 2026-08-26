import Foundation

// MARK: - Shell tokenization

/// Shell 命令的轻量分词结果。它只建模交互补全需要的引号和反斜杠语义，
/// 不执行变量展开、命令替换或 glob，因此处理不可信命令行时不会产生副作用。
public struct ShellCommandTokenization: Equatable, Sendable {
  public let tokens: [String]
  public let currentToken: String
  /// 当前 token 在命令行中的 Character 偏移，而不是 UTF-8 字节偏移。
  public let currentTokenStart: Int
}

public enum ShellCommandTokenizer {
  fileprivate struct Token {
    let value: String
    let raw: String
    let start: Int
  }

  public static func tokenize(_ line: String) -> ShellCommandTokenization {
    let tokens = lex(line)
    let hasTrailingSeparator = line.last?.isWhitespace == true
    return ShellCommandTokenization(
      tokens: tokens.map(\.value),
      currentToken: hasTrailingSeparator ? "" : (tokens.last?.value ?? ""),
      currentTokenStart: hasTrailingSeparator ? line.count : (tokens.last?.start ?? line.count)
    )
  }

  fileprivate static func lex(_ line: String) -> [Token] {
    let characters = Array(line)
    var result: [Token] = []
    var index = 0

    while index < characters.count {
      while index < characters.count, characters[index].isWhitespace { index += 1 }
      guard index < characters.count else { break }

      let start = index
      var value = ""
      var quote: Character?
      var escaped = false

      while index < characters.count {
        let character = characters[index]
        if escaped {
          value.append(character)
          escaped = false
          index += 1
          continue
        }
        if character == "\\", quote != "'" {
          escaped = true
          index += 1
          continue
        }
        if let activeQuote = quote {
          if character == activeQuote {
            quote = nil
          } else {
            value.append(character)
          }
          index += 1
          continue
        }
        if character == "'" || character == "\"" {
          quote = character
          index += 1
          continue
        }
        if character.isWhitespace { break }
        value.append(character)
        index += 1
      }
      if escaped { value.append("\\") }
      let raw = String(characters[start..<index])
      result.append(Token(value: value, raw: raw, start: start))
    }
    return result
  }
}

// MARK: - Completion specifications

/// 命令描述的双语文本。JSON 里既接受纯字符串(仅英文)也接受 `{english, chinese}` 对象;
/// 编码时中文为空则只写字符串,让 700 多个命令的嵌套规格文件保持紧凑。
public struct LocalizedAutocompleteDescription: Codable, Equatable, Sendable {
  public var english: String
  public var chinese: String

  public init(english: String = "", chinese: String = "") {
    self.english = english
    self.chinese = chinese
  }

  private enum CodingKeys: String, CodingKey { case english, chinese }

  public init(from decoder: Decoder) throws {
    if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
      english = text
      chinese = ""
      return
    }
    let container = try decoder.container(keyedBy: CodingKeys.self)
    english = try container.decodeIfPresent(String.self, forKey: .english) ?? ""
    chinese = try container.decodeIfPresent(String.self, forKey: .chinese) ?? ""
  }

  public func encode(to encoder: Encoder) throws {
    if chinese.isEmpty {
      var single = encoder.singleValueContainer()
      try single.encode(english)
      return
    }
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(english, forKey: .english)
    try container.encode(chinese, forKey: .chinese)
  }

  public func text(for language: AutocompleteDescriptionLanguage) -> String {
    switch language {
    case .chinese:
      return chinese.isEmpty ? english : chinese
    case .english, .system:
      return english.isEmpty ? chinese : english
    }
  }
}

/// 最简单的“名称 + 描述”条目,用于参数的静态候选值。
public struct AutocompleteSpecItem: Codable, Equatable, Sendable {
  public var name: String
  public var description: String

  public init(name: String, description: String = "") {
    self.name = name
    self.description = description
  }

  private enum CodingKeys: String, CodingKey { case name, description }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    if !description.isEmpty { try container.encode(description, forKey: .description) }
  }
}

/// 位置参数或选项参数。`template` 指示文件/目录补全,`suggestions` 是静态候选,
/// `generatorScripts` 保留 Fig 里的静态脚本(如 `git branch`)供后续动态候选使用。
public struct AutocompleteArgumentSpec: Codable, Equatable, Sendable {
  public var name: String
  public var description: String
  public var template: [String]
  public var suggestions: [AutocompleteSpecItem]
  public var generatorScripts: [[String]]
  public var isOptional: Bool
  public var isVariadic: Bool

  public init(
    name: String,
    description: String = "",
    template: [String] = [],
    suggestions: [AutocompleteSpecItem] = [],
    generatorScripts: [[String]] = [],
    isOptional: Bool = false,
    isVariadic: Bool = false
  ) {
    self.name = name
    self.description = description
    self.template = template
    self.suggestions = suggestions
    self.generatorScripts = generatorScripts
    self.isOptional = isOptional
    self.isVariadic = isVariadic
  }

  /// 是否期望文件路径(目录模板也接受文件系统候选)。
  public var wantsFilesystemCandidates: Bool { !template.isEmpty }
  public var wantsFoldersOnly: Bool { template == ["folders"] }

  private enum CodingKeys: String, CodingKey {
    case name, description, template, suggestions, generatorScripts, isOptional, isVariadic
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    template = try container.decodeIfPresent([String].self, forKey: .template) ?? []
    suggestions = try container.decodeIfPresent([AutocompleteSpecItem].self, forKey: .suggestions) ?? []
    generatorScripts = try container.decodeIfPresent([[String]].self, forKey: .generatorScripts) ?? []
    isOptional = try container.decodeIfPresent(Bool.self, forKey: .isOptional) ?? false
    isVariadic = try container.decodeIfPresent(Bool.self, forKey: .isVariadic) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    if !description.isEmpty { try container.encode(description, forKey: .description) }
    if !template.isEmpty { try container.encode(template, forKey: .template) }
    if !suggestions.isEmpty { try container.encode(suggestions, forKey: .suggestions) }
    if !generatorScripts.isEmpty { try container.encode(generatorScripts, forKey: .generatorScripts) }
    if isOptional { try container.encode(true, forKey: .isOptional) }
    if isVariadic { try container.encode(true, forKey: .isVariadic) }
  }
}

/// 一个选项及其全部别名(如 `-p` / `--paginate`);`args` 非空表示选项后跟参数。
public struct AutocompleteOptionSpec: Codable, Equatable, Sendable {
  public var names: [String]
  public var description: String
  public var args: [AutocompleteArgumentSpec]
  public var isRequired: Bool
  public var isRepeatable: Bool
  public var hidden: Bool

  public init(
    names: [String],
    description: String = "",
    args: [AutocompleteArgumentSpec] = [],
    isRequired: Bool = false,
    isRepeatable: Bool = false,
    hidden: Bool = false
  ) {
    self.names = names
    self.description = description
    self.args = args
    self.isRequired = isRequired
    self.isRepeatable = isRepeatable
    self.hidden = hidden
  }

  public init(name: String, description: String = "") {
    self.init(names: [name], description: description)
  }

  /// 主名称:优先长选项,便于面板展示和学习库比对。
  public var name: String { names.first(where: { $0.hasPrefix("--") }) ?? names.first ?? "" }

  private enum CodingKeys: String, CodingKey {
    case names, description, args, isRequired, isRepeatable, hidden
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    names = try container.decode([String].self, forKey: .names)
    description = try container.decodeIfPresent(String.self, forKey: .description) ?? ""
    args = try container.decodeIfPresent([AutocompleteArgumentSpec].self, forKey: .args) ?? []
    isRequired = try container.decodeIfPresent(Bool.self, forKey: .isRequired) ?? false
    isRepeatable = try container.decodeIfPresent(Bool.self, forKey: .isRepeatable) ?? false
    hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(names, forKey: .names)
    if !description.isEmpty { try container.encode(description, forKey: .description) }
    if !args.isEmpty { try container.encode(args, forKey: .args) }
    if isRequired { try container.encode(true, forKey: .isRequired) }
    if isRepeatable { try container.encode(true, forKey: .isRepeatable) }
    if hidden { try container.encode(true, forKey: .hidden) }
  }
}

/// 命令或子命令规格。子命令递归嵌套,与 Fig 规格树同构;`aliases` 是同一子命令的别名。
public struct AutocompleteCommandSpec: Codable, Equatable, Sendable {
  public var name: String
  public var description: LocalizedAutocompleteDescription
  public var aliases: [String]
  public var hidden: Bool
  public var subcommands: [AutocompleteCommandSpec]
  public var options: [AutocompleteOptionSpec]
  public var arguments: [AutocompleteArgumentSpec]

  public init(
    name: String,
    description: LocalizedAutocompleteDescription = .init(),
    aliases: [String] = [],
    hidden: Bool = false,
    subcommands: [AutocompleteCommandSpec] = [],
    options: [AutocompleteOptionSpec] = [],
    arguments: [AutocompleteArgumentSpec] = []
  ) {
    self.name = name
    self.description = description
    self.aliases = aliases
    self.hidden = hidden
    self.subcommands = subcommands
    self.options = options
    self.arguments = arguments
  }

  /// 按名称或别名查找直接子命令。
  public func subcommand(named token: String) -> AutocompleteCommandSpec? {
    subcommands.first { $0.name == token || $0.aliases.contains(token) }
  }

  /// 按任一名称查找选项。
  public func option(named token: String) -> AutocompleteOptionSpec? {
    options.first { $0.names.contains(token) }
  }

  /// 是否存在任何可补全的子项;仅有名称的占位规格返回 false。
  public var hasDetails: Bool { !subcommands.isEmpty || !options.isEmpty || !arguments.isEmpty }

  private enum CodingKeys: String, CodingKey {
    case name, description, aliases, hidden, subcommands, options, arguments
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    name = try container.decode(String.self, forKey: .name)
    description = try container.decodeIfPresent(LocalizedAutocompleteDescription.self, forKey: .description)
      ?? .init()
    aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
    hidden = try container.decodeIfPresent(Bool.self, forKey: .hidden) ?? false
    subcommands = try container.decodeIfPresent([AutocompleteCommandSpec].self, forKey: .subcommands) ?? []
    options = try container.decodeIfPresent([AutocompleteOptionSpec].self, forKey: .options) ?? []
    arguments = try container.decodeIfPresent([AutocompleteArgumentSpec].self, forKey: .arguments) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(name, forKey: .name)
    if !description.english.isEmpty || !description.chinese.isEmpty {
      try container.encode(description, forKey: .description)
    }
    if !aliases.isEmpty { try container.encode(aliases, forKey: .aliases) }
    if hidden { try container.encode(true, forKey: .hidden) }
    if !subcommands.isEmpty { try container.encode(subcommands, forKey: .subcommands) }
    if !options.isEmpty { try container.encode(options, forKey: .options) }
    if !arguments.isEmpty { try container.encode(arguments, forKey: .arguments) }
  }
}

/// 整个规格库。`sourceRevision` 是上游版本标识,`sourceDate` 是上游发布日期(设置页展示)。
public struct AutocompleteSpecDatabase: Codable, Equatable, Sendable {
  public static let currentSchemaVersion = 2

  public var schemaVersion: Int
  public var sourceRevision: String
  public var sourceDate: String?
  public var commands: [AutocompleteCommandSpec]

  public init(
    schemaVersion: Int = AutocompleteSpecDatabase.currentSchemaVersion,
    sourceRevision: String,
    sourceDate: String? = nil,
    commands: [AutocompleteCommandSpec]
  ) {
    self.schemaVersion = schemaVersion
    self.sourceRevision = sourceRevision
    self.sourceDate = sourceDate
    self.commands = commands
  }

  /// 顶层命令查找(含别名)。
  public func command(named token: String) -> AutocompleteCommandSpec? {
    commands.first { $0.name == token || $0.aliases.contains(token) }
  }
}

public enum AutocompleteStoreError: Error, Equatable {
  case fileTooLarge
  case unsupportedSchema
  case invalidData
}

/// 规格文件的唯一解码边界。先限制编码大小,再递归校验节点数量和字段长度,避免导入文件
/// 通过巨大数组、深层嵌套或超长字符串放大内存占用。
public enum AutocompleteSpecStore {
  public static let maximumEncodedBytes = 32 * 1_024 * 1_024
  public static let maximumCommands = 5_000
  /// 单个顶层命令(含全部嵌套子命令/选项/参数)允许的节点总数。
  public static let maximumNodesPerCommand = 20_000
  public static let maximumChildrenPerNode = 2_000
  public static let maximumDepth = 16

  public static func decode(_ data: Data) throws -> AutocompleteSpecDatabase {
    guard data.count <= maximumEncodedBytes else { throw AutocompleteStoreError.fileTooLarge }
    guard let database = try? JSONDecoder().decode(AutocompleteSpecDatabase.self, from: data)
    else { throw AutocompleteStoreError.invalidData }
    guard database.schemaVersion == AutocompleteSpecDatabase.currentSchemaVersion else {
      throw AutocompleteStoreError.unsupportedSchema
    }
    guard !database.sourceRevision.isEmpty,
      database.sourceRevision.utf8.count <= 128,
      !containsControlCharacters(database.sourceRevision),
      (database.sourceDate ?? "").utf8.count <= 32,
      !containsControlCharacters(database.sourceDate ?? ""),
      database.commands.count <= maximumCommands,
      Set(database.commands.map(\.name)).count == database.commands.count,
      database.commands.allSatisfy({ validCommandName($0.name) && isValid($0) })
    else { throw AutocompleteStoreError.invalidData }
    return database
  }

  public static func encode(_ database: AutocompleteSpecDatabase) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(database)
    guard data.count <= maximumEncodedBytes else { throw AutocompleteStoreError.fileTooLarge }
    _ = try decode(data)
    return data
  }

  /// 顶层入口:为每个命令单独计数节点,任何一层超限都拒绝整个文件。
  private static func isValid(_ command: AutocompleteCommandSpec) -> Bool {
    var budget = maximumNodesPerCommand
    return isValid(command, depth: 0, budget: &budget)
  }

  private static func isValid(_ command: AutocompleteCommandSpec, depth: Int, budget: inout Int) -> Bool {
    budget -= 1
    guard budget >= 0, depth <= maximumDepth,
      validItemName(command.name),
      validText(command.description.english), validText(command.description.chinese),
      command.aliases.count <= 32, command.aliases.allSatisfy(validItemName),
      command.subcommands.count <= maximumChildrenPerNode,
      command.options.count <= maximumChildrenPerNode,
      command.arguments.count <= maximumChildrenPerNode
    else { return false }
    for option in command.options {
      budget -= 1
      guard budget >= 0, !option.names.isEmpty, option.names.count <= 32,
        option.names.allSatisfy(validItemName), validText(option.description),
        option.args.count <= 64, option.args.allSatisfy(isValid)
      else { return false }
    }
    guard command.arguments.allSatisfy(isValid) else { return false }
    for subcommand in command.subcommands {
      guard isValid(subcommand, depth: depth + 1, budget: &budget) else { return false }
    }
    return true
  }

  /// 参数名只是展示文本,允许空格和尖括号;静态候选会被插入命令行,必须是合法 token。
  private static func isValid(_ argument: AutocompleteArgumentSpec) -> Bool {
    !argument.name.isEmpty && argument.name.utf8.count <= 512 && validText(argument.name)
      && validText(argument.description)
      && argument.template.count <= 4
      && argument.template.allSatisfy { $0 == "filepaths" || $0 == "folders" }
      && argument.suggestions.count <= maximumChildrenPerNode
      && argument.suggestions.allSatisfy { validItemName($0.name) && validText($0.description) }
      && argument.generatorScripts.count <= 8
      && argument.generatorScripts.allSatisfy { script in
        !script.isEmpty && script.count <= 32
          && script.allSatisfy { $0.utf8.count <= 512 && !containsControlCharacters($0) }
      }
  }

  private static func validText(_ value: String) -> Bool {
    value.utf8.count <= 1_024 && !containsControlCharacters(value)
  }

  fileprivate static func validCommandName(_ value: String) -> Bool {
    validShellToken(
      value,
      maximumBytes: 128,
      punctuation: CharacterSet(charactersIn: "._+@-")
    )
  }

  fileprivate static func validItemName(_ value: String) -> Bool {
    validShellToken(
      value,
      maximumBytes: 512,
      punctuation: CharacterSet(charactersIn: "._+@%/=:,-")
    )
  }

  private static func validShellToken(
    _ value: String,
    maximumBytes: Int,
    punctuation: CharacterSet
  ) -> Bool {
    let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
      .union(punctuation)
    return !value.isEmpty && value.utf8.count <= maximumBytes
      && value.unicodeScalars.allSatisfy(allowed.contains)
  }

  private static func containsControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
  }
}

/// 手动更新的解析边界。远端文件就是 `scripts/build-fig-specs.mjs` 生成的同一份 schema v2
/// JSON;这里只做完整解码校验、最小命令数保护,并保留现有中文描述(远端缺失时)。
public enum FigAutocompleteUpdateParser {
  public static func database(
    from data: Data,
    preserving existing: AutocompleteSpecDatabase,
    minimumCommandCount: Int = 100
  ) throws -> AutocompleteSpecDatabase {
    var updated = try AutocompleteSpecStore.decode(data)
    guard updated.commands.count >= max(1, minimumCommandCount) else {
      throw AutocompleteStoreError.invalidData
    }
    let existingByName = Dictionary(existing.commands.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    updated.commands = updated.commands.map { command in
      guard command.description.chinese.isEmpty,
        let previous = existingByName[command.name], !previous.description.chinese.isEmpty
      else { return command }
      var merged = command
      merged.description.chinese = previous.description.chinese
      return merged
    }
    return updated
  }
}

/// 将常见 `--help` 文本转换为本地规格。解析器只识别明确的 Commands/Options 分区，
/// 且限制输入与候选数量；它不会执行命令，进程沙箱与超时由应用基础设施层负责。
public enum HelpAutocompleteSpecParser {
  private enum Section { case none, commands, options }

  public static func parse(command: String, output: String) -> AutocompleteCommandSpec? {
    guard !command.isEmpty, command.utf8.count <= 128,
      !command.contains(where: \.isWhitespace),
      output.utf8.count <= 128 * 1_024
    else { return nil }

    var section = Section.none
    var subcommands: [AutocompleteCommandSpec] = []
    var options: [AutocompleteOptionSpec] = []
    for sourceLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = sourceLine.trimmingCharacters(in: .whitespacesAndNewlines)
      let header = line.lowercased()
      if ["commands:", "available commands:", "subcommands:"].contains(header) {
        section = .commands
        continue
      }
      if ["options:", "flags:", "global options:"].contains(header) {
        section = .options
        continue
      }
      if line.isEmpty { continue }
      guard let (signature, description) = columns(in: line) else { continue }

      switch section {
      case .commands where subcommands.count < 1_000:
        guard let name = signature.split(whereSeparator: \.isWhitespace).first.map(String.init),
          isValidItemName(name), !name.hasPrefix("-")
        else { continue }
        if !subcommands.contains(where: { $0.name == name }) {
          subcommands.append(
            AutocompleteCommandSpec(
              name: name, description: LocalizedAutocompleteDescription(english: description)))
        }
      case .options where options.count < 1_000:
        let names = signature.split { $0.isWhitespace || $0 == "," }.map(String.init)
        guard let name = names.first(where: { $0.hasPrefix("--") })
          ?? names.first(where: { $0.hasPrefix("-") }),
          isValidItemName(name)
        else { continue }
        if !options.contains(where: { $0.names.contains(name) }) {
          options.append(AutocompleteOptionSpec(name: name, description: description))
        }
      default:
        continue
      }
    }
    guard !subcommands.isEmpty || !options.isEmpty else { return nil }
    return AutocompleteCommandSpec(name: command, subcommands: subcommands, options: options)
  }

  /// 两个或更多连续空格是 help 输出最稳定的“签名 / 描述”分隔；只有签名的行也
  /// 接受为空描述，以兼容极简 CLI。
  private static func columns(in line: String) -> (String, String)? {
    let characters = Array(line)
    if characters.count >= 2 {
      for index in 0..<(characters.count - 1) where characters[index].isWhitespace
        && characters[index + 1].isWhitespace
      {
        let signature = String(characters[..<index]).trimmingCharacters(in: .whitespaces)
        let description = String(characters[(index + 2)...])
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return signature.isEmpty ? nil : (signature, description)
      }
    }
    return line.isEmpty ? nil : (line, "")
  }

  private static func isValidItemName(_ name: String) -> Bool {
    AutocompleteSpecStore.validItemName(name)
  }
}

// MARK: - Local learning

public struct AutocompleteLearnedEntry: Codable, Equatable, Sendable {
  public var command: String
  public var directory: String
  public var useCount: Int
  public var pinCount: Int
  public var lastUsedAt: Date
  public var lastSessionIdentifier: String?
}

public struct AutocompleteLearnedSuggestion: Equatable, Sendable {
  public let command: String
  public let score: Double

  public init(command: String, score: Double) {
    self.command = command
    self.score = score
  }
}

/// 本地命令学习数据库。记录的是清理后的命令文本、目录和统计量；不会保存命令输出、
/// secret 参数值或环境变量。调用方可在功能关闭时完全跳过该类型。
public struct AutocompleteLearningDatabase: Codable, Equatable, Sendable {
  public private(set) var entries: [AutocompleteLearnedEntry]
  public private(set) var capacity: Int

  public init(capacity: Int = 5_000) {
    self.capacity = min(max(capacity, 1), 5_000)
    entries = []
  }

  /// 完成一次命令后更新统计。返回 false 表示命令因隐私规则、失败纠错规则或非法输入
  /// 未被记录；失败命令若已存在，也会从学习结果中移除。
  @discardableResult
  public mutating func complete(
    command: String,
    directory: String,
    exitStatus: Int,
    ignorePatterns: [String],
    knownOptions: Set<String>,
    sessionIdentifier: String,
    at date: Date = Date()
  ) -> Bool {
    guard let directory = Self.normalizedDirectory(directory),
      let sanitized = Self.sanitizedCommand(command),
      !ignorePatterns.prefix(64).contains(where: { ShellGlob.matches(command, pattern: $0) })
    else { return false }

    if exitStatus == 127
      || !knownOptions.isEmpty
        && Self.hasUnknownLongOption(sanitized, knownOptions: knownOptions) && exitStatus != 0
    {
      entries.removeAll { $0.command == sanitized && $0.directory == directory }
      return false
    }

    if let index = entries.firstIndex(where: { $0.command == sanitized && $0.directory == directory }) {
      entries[index].useCount = min(entries[index].useCount + 1, Int.max / 2)
      entries[index].lastUsedAt = date
      entries[index].lastSessionIdentifier = Self.normalizedSessionIdentifier(sessionIdentifier)
    } else {
      entries.append(
        AutocompleteLearnedEntry(
          command: sanitized,
          directory: directory,
          useCount: 1,
          pinCount: 0,
          lastUsedAt: date,
          lastSessionIdentifier: Self.normalizedSessionIdentifier(sessionIdentifier)
        ))
    }
    trimToCapacity()
    return true
  }

  /// 将命令固定到目录。重复固定会提高其排序权重，但计数有上限，避免整数溢出。
  @discardableResult
  public mutating func pin(command: String, directory: String, at date: Date = Date()) -> Bool {
    guard let directory = Self.normalizedDirectory(directory),
      let sanitized = Self.sanitizedCommand(command)
    else { return false }

    if let index = entries.firstIndex(where: { $0.command == sanitized && $0.directory == directory }) {
      entries[index].pinCount = min(entries[index].pinCount + 1, 10_000)
      entries[index].lastUsedAt = date
    } else {
      entries.append(
        AutocompleteLearnedEntry(
          command: sanitized,
          directory: directory,
          useCount: 0,
          pinCount: 1,
          lastUsedAt: date,
          lastSessionIdentifier: nil
        ))
    }
    trimToCapacity()
    return true
  }

  /// 清除普通学习历史但保留固定命令。固定项的使用次数归零，避免旧 frecency 继续
  /// 影响排序；仅有历史、没有 pin 的条目直接移除。
  public mutating func clearHistory() {
    entries = entries.compactMap { entry in
      guard entry.pinCount > 0 else { return nil }
      var pinned = entry
      pinned.useCount = 0
      pinned.lastSessionIdentifier = nil
      return pinned
    }
  }

  /// 清除固定状态但保留真实使用历史。只通过 pin 创建、从未执行的条目同步移除。
  public mutating func clearPinnedCommands() {
    entries = entries.compactMap { entry in
      guard entry.useCount > 0 else { return nil }
      var learned = entry
      learned.pinCount = 0
      return learned
    }
  }

  public func suggestions(
    prefix: String,
    directory: String,
    sessionIdentifier: String,
    now: Date = Date()
  ) -> [AutocompleteLearnedSuggestion] {
    guard let directory = Self.normalizedDirectory(directory) else { return [] }
    let normalizedSession = Self.normalizedSessionIdentifier(sessionIdentifier)
    return entries.lazy
      .filter { $0.directory == directory && $0.command.hasPrefix(prefix) }
      .map { entry in
        let age = max(0, now.timeIntervalSince(entry.lastUsedAt))
        let recency = 10_000 / (1 + age / 86_400)
        let pinned = Double(entry.pinCount) * 1_000_000
        let session = entry.lastSessionIdentifier == normalizedSession ? 100_000.0 : 0
        let frequency = Double(entry.useCount) * 1_000
        return AutocompleteLearnedSuggestion(
          command: entry.command,
          score: pinned + session + frequency + recency
        )
      }
      .sorted {
        if $0.score != $1.score { return $0.score > $1.score }
        return $0.command.localizedStandardCompare($1.command) == .orderedAscending
      }
  }

  fileprivate func validated() throws -> AutocompleteLearningDatabase {
    guard (1...5_000).contains(capacity), entries.count <= capacity,
      entries.allSatisfy({ entry in
        Self.sanitizedCommand(entry.command) == entry.command
          && Self.normalizedDirectory(entry.directory) == entry.directory
          && entry.useCount >= 0 && entry.useCount <= Int.max / 2
          && (0...10_000).contains(entry.pinCount)
          && entry.lastUsedAt.timeIntervalSinceReferenceDate.isFinite
          && (entry.lastSessionIdentifier.map {
            Self.normalizedSessionIdentifier($0) == $0
          } ?? true)
      })
    else { throw AutocompleteStoreError.invalidData }
    return self
  }

  private mutating func trimToCapacity() {
    guard entries.count > capacity else { return }
    entries.sort {
      if $0.pinCount != $1.pinCount { return $0.pinCount > $1.pinCount }
      if $0.lastUsedAt != $1.lastUsedAt { return $0.lastUsedAt > $1.lastUsedAt }
      return $0.command < $1.command
    }
    entries.removeLast(entries.count - capacity)
  }

  private static func normalizedDirectory(_ directory: String) -> String? {
    guard directory.hasPrefix("/"), directory.utf8.count <= 4_096,
      !directory.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return URL(fileURLWithPath: directory).standardizedFileURL.path
  }

  private static func normalizedSessionIdentifier(_ identifier: String) -> String? {
    guard !identifier.isEmpty, identifier.utf8.count <= 128,
      !identifier.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return identifier
  }

  private static let secretOptionNames: Set<String> = [
    "--access-key", "--access-token", "--api-key", "--auth-token", "--client-secret",
    "--password", "--passwd", "--secret", "--token",
  ]

  private static func sanitizedCommand(_ command: String) -> String? {
    guard !command.isEmpty, command.utf8.count <= 4_096,
      !command.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0) && $0.value != 0x09
      })
    else { return nil }

    let tokens = ShellCommandTokenizer.lex(command)
    guard !tokens.isEmpty else { return nil }
    var kept: [String] = []
    var index = 0
    while index < tokens.count {
      let value = tokens[index].value
      let optionName = value.split(separator: "=", maxSplits: 1).first.map(String.init)?.lowercased() ?? ""
      if secretOptionNames.contains(optionName) {
        let hasInlineValue = value.contains("=")
        index += hasInlineValue ? 1 : min(2, tokens.count - index)
        continue
      }
      kept.append(tokens[index].raw)
      index += 1
    }
    let result = kept.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? nil : result
  }

  private static func hasUnknownLongOption(_ command: String, knownOptions: Set<String>) -> Bool {
    let normalizedKnown = Set(knownOptions.map { $0.split(separator: "=", maxSplits: 1).first.map(String.init) ?? $0 })
    return ShellCommandTokenizer.lex(command).contains { token in
      guard token.value.hasPrefix("--") else { return false }
      let name = token.value.split(separator: "=", maxSplits: 1).first.map(String.init) ?? token.value
      return !normalizedKnown.contains(name)
    }
  }
}

public enum AutocompleteLearningStore {
  public static let maximumEncodedBytes = 2 * 1_024 * 1_024

  public static func decode(_ data: Data) throws -> AutocompleteLearningDatabase {
    guard data.count <= maximumEncodedBytes else { throw AutocompleteStoreError.fileTooLarge }
    guard let database = try? JSONDecoder().decode(AutocompleteLearningDatabase.self, from: data)
    else { throw AutocompleteStoreError.invalidData }
    return try database.validated()
  }

  public static func encode(_ database: AutocompleteLearningDatabase) throws -> Data {
    _ = try database.validated()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(database)
    guard data.count <= maximumEncodedBytes else { throw AutocompleteStoreError.fileTooLarge }
    return data
  }
}

private enum ShellGlob {
  static func matches(_ value: String, pattern: String) -> Bool {
    guard !pattern.isEmpty, pattern.utf8.count <= 256 else { return false }
    let input = Array(value)
    let glob = Array(pattern)
    var inputIndex = 0
    var patternIndex = 0
    var starIndex: Int?
    var backtrackInputIndex = 0

    // 只支持设置页承诺的 `*` 和 `?`。贪心星号回溯保持线性空间，并避免长命令与
    // 多个忽略模式组合时构造大型递归 memo 表。
    while inputIndex < input.count {
      if patternIndex < glob.count,
        glob[patternIndex] == "?" || glob[patternIndex] == input[inputIndex]
      {
        inputIndex += 1
        patternIndex += 1
      } else if patternIndex < glob.count, glob[patternIndex] == "*" {
        starIndex = patternIndex
        patternIndex += 1
        backtrackInputIndex = inputIndex
      } else if let starIndex {
        backtrackInputIndex += 1
        inputIndex = backtrackInputIndex
        patternIndex = starIndex + 1
      } else {
        return false
      }
    }
    while patternIndex < glob.count, glob[patternIndex] == "*" { patternIndex += 1 }
    return patternIndex == glob.count
  }
}

// MARK: - README and corrections

public enum ReadmeCommandScanner {
  private static let shellLanguages: Set<String> = [
    "bash", "console", "fish", "sh", "shell", "terminal", "zsh",
  ]

  /// 仅解析 Markdown shell fenced blocks。console/terminal 块只接受带提示符的行，
  /// 避免把命令输出学习成可执行候选。
  public static func commands(in markdown: String) -> [String] {
    guard markdown.utf8.count <= 2 * 1_024 * 1_024 else { return [] }
    var activeLanguage: String?
    var result: [String] = []

    for sourceLine in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = sourceLine.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
        if activeLanguage == nil {
          let marker = trimmed.hasPrefix("```") ? "```" : "~~~"
          let language = String(trimmed.dropFirst(marker.count))
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
          activeLanguage = shellLanguages.contains(language) ? language : "ignored"
        } else {
          activeLanguage = nil
        }
        continue
      }
      guard let language = activeLanguage, language != "ignored", result.count < 200 else { continue }
      guard let command = command(from: trimmed, requiresPrompt: language == "console" || language == "terminal")
      else { continue }
      if !result.contains(command) { result.append(command) }
    }
    return result
  }

  private static func command(from line: String, requiresPrompt: Bool) -> String? {
    guard !line.isEmpty else { return nil }
    let prefixes = ["$ ", "% ", "> "]
    let prompt = prefixes.first(where: { line.hasPrefix($0) })
    if requiresPrompt && prompt == nil { return nil }
    let command = prompt.map { String(line.dropFirst($0.count)) } ?? line
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), trimmed.utf8.count <= 4_096,
      !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return trimmed
  }
}

public enum CommandCorrectionParser {
  public static func suggestion(
    command: String,
    output: String,
    knownCommands: Set<String>
  ) -> String? {
    guard command.utf8.count <= 4_096, output.utf8.count <= 128 * 1_024 else { return nil }
    let tokens = ShellCommandTokenizer.tokenize(command).tokens
    guard let executable = tokens.first else { return nil }

    if output.localizedCaseInsensitiveContains("most similar command") {
      let lines = output.split(separator: "\n").map {
        $0.trimmingCharacters(in: .whitespacesAndNewlines)
      }
      if let marker = lines.firstIndex(where: { $0.localizedCaseInsensitiveContains("most similar command") }),
        marker + 1 < lines.count,
        !lines[marker + 1].isEmpty,
        tokens.count >= 2
      {
        var corrected = tokens
        corrected[1] = lines[marker + 1]
        return corrected.joined(separator: " ")
      }
    }

    if tokens.count >= 2, let subcommand = suggestedSubcommand(in: output) {
      var corrected = tokens
      corrected[1] = subcommand
      return corrected.joined(separator: " ")
    }

    guard output.localizedCaseInsensitiveContains("command not found") else { return nil }
    let normalizedExecutable = executable.lowercased()
    let maximumDistance = max(1, min(3, executable.count / 3 + 1))
    let distances: [(command: String, distance: Int)] = knownCommands.map { candidate in
      (candidate, levenshtein(normalizedExecutable, candidate.lowercased()))
    }
    let closest = distances
      .filter { $0.distance <= maximumDistance }
      .sorted { left, right in
        left.distance == right.distance ? left.command < right.command : left.distance < right.distance
      }
      .first?.command
    guard let closest else { return nil }
    return ([closest] + tokens.dropFirst()).joined(separator: " ")
  }

  private static func suggestedSubcommand(in output: String) -> String? {
    let patterns = [
      #"(?i)did you mean(?: this)?\??\s*(?:\r?\n)+\s*(?:(?:npm|cargo|pip|brew|rustup|git)\s+)?([A-Za-z0-9._-]+)"#,
      #"(?i)(?:similar name exists|maybe you meant)\s*:?\s*[`'\"]?([A-Za-z0-9._-]+)"#,
    ]
    let range = NSRange(output.startIndex..<output.endIndex, in: output)
    for pattern in patterns {
      guard let expression = try? NSRegularExpression(pattern: pattern),
        let match = expression.firstMatch(in: output, range: range),
        match.numberOfRanges >= 2,
        let capture = Range(match.range(at: 1), in: output)
      else { continue }
      let candidate = String(output[capture])
      if !candidate.isEmpty, candidate.utf8.count <= 128 { return candidate }
    }
    return nil
  }

  private static func levenshtein(_ left: String, _ right: String) -> Int {
    let lhs = Array(left)
    let rhs = Array(right)
    var previous = Array(0...rhs.count)
    for (leftIndex, leftCharacter) in lhs.enumerated() {
      var current = [leftIndex + 1]
      for (rightIndex, rightCharacter) in rhs.enumerated() {
        current.append(
          min(
            current[rightIndex] + 1,
            previous[rightIndex + 1] + 1,
            previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
          ))
      }
      previous = current
    }
    return previous.last ?? 0
  }
}

// MARK: - Candidate engine

public enum AutocompleteCandidateKind: String, Codable, Equatable, Sendable {
  case command
  case subcommand
  case option
  case argument
  case file
  case folder
  case alias
  case snippet
  case learnedCommand
  case readmeCommand
  case correction
}

public struct AutocompleteCandidate: Equatable, Sendable {
  public let insertText: String
  public let displayText: String
  public let description: String
  public let kind: AutocompleteCandidateKind
  public let score: Double

  public init(
    insertText: String,
    displayText: String? = nil,
    description: String = "",
    kind: AutocompleteCandidateKind,
    score: Double = 0
  ) {
    self.insertText = insertText
    self.displayText = displayText ?? insertText
    self.description = description
    self.kind = kind
    self.score = score
  }
}

public struct AutocompleteQuery: Equatable, Sendable {
  public let line: String
  public let directory: String

  public init(line: String, directory: String) {
    self.line = line
    self.directory = directory
  }
}

public struct AutocompleteResult: Equatable, Sendable {
  public let candidates: [AutocompleteCandidate]
  public let ghostText: String?
  public let replacementStart: Int

  public init(
    candidates: [AutocompleteCandidate],
    ghostText: String?,
    replacementStart: Int
  ) {
    self.candidates = candidates
    self.ghostText = ghostText
    self.replacementStart = replacementStart
  }
}

public struct AutocompleteEngine: Sendable {
  public let specDatabase: AutocompleteSpecDatabase

  public init(specDatabase: AutocompleteSpecDatabase) {
    self.specDatabase = specDatabase
  }

  public func suggestions(
    for query: AutocompleteQuery,
    learned: [AutocompleteLearnedSuggestion],
    pinned: [AutocompleteLearnedSuggestion],
    readmeCommands: [String],
    aliases: [String] = [],
    language: AutocompleteDescriptionLanguage = .system
  ) -> AutocompleteResult {
    // 空 prompt 不产生任何候选。没有输入就没有用户意图，把整个命令库和全部历史列出来
    // 只是噪音，而且面板一旦弹出就会吞掉回车，让用户以为终端卡住了。只有空白字符的
    // 行同样按空处理；`git ` 这种尾随空格的行 trim 后仍非空，不受影响。
    guard !query.line.trimmingCharacters(in: .whitespaces).isEmpty else {
      return AutocompleteResult(candidates: [], ghostText: nil, replacementStart: 0)
    }
    let parsed = ShellCommandTokenizer.tokenize(query.line)
    var candidates: [AutocompleteCandidate] = []
    // 固定、历史与 README 候选均保存完整命令行，任何输入阶段都可按完整前缀参与；
    // 规格候选则只替换当前 token。UI 接受时据此选择发送“整行后缀”或“token 后缀”。
    candidates += pinned.filter { $0.command.hasPrefix(query.line) && $0.command != query.line }.map {
      AutocompleteCandidate(insertText: $0.command, kind: .snippet, score: $0.score + 2_000_000)
    }
    candidates += learned.filter { $0.command.hasPrefix(query.line) && $0.command != query.line }.map {
      AutocompleteCandidate(
        insertText: $0.command, kind: .learnedCommand, score: $0.score + 1_000_000)
    }
    candidates += readmeCommands.filter { $0.hasPrefix(query.line) && $0 != query.line }.map {
      AutocompleteCandidate(insertText: $0, kind: .readmeCommand, score: 500_000)
    }
    if parsed.tokens.count <= 1, !query.line.contains(where: \.isWhitespace) {
      candidates += aliases.filter { $0.hasPrefix(parsed.currentToken) && $0 != parsed.currentToken }.map {
        AutocompleteCandidate(insertText: $0, description: "Shell 别名", kind: .alias, score: 110_000)
      }
    }

    // 上面的空行 guard 已经排除了 tokens 为空的情况，这里只处理“正在输入命令名”和
    // “已经有命令名、在补子命令/选项/参数”两种真实输入状态。
    if parsed.tokens.count <= 1, !query.line.contains(where: \.isWhitespace) {
      candidates += specDatabase.commands
        .filter { $0.name.hasPrefix(parsed.currentToken) && $0.name != parsed.currentToken }
        .map {
          AutocompleteCandidate(
            insertText: $0.name,
            description: $0.description.text(for: language),
            kind: .command,
            score: 100_000
          )
        }
    } else if let commandName = parsed.tokens.first,
      let root = specDatabase.command(named: commandName)
    {
      // 已完成的 token 不含正在输入的那个:行尾有空格时 currentToken 为空,全部 token
      // 都算完成;否则最后一个 token 就是正在输入的前缀,要从路径推进中排除。
      let completed = parsed.currentToken.isEmpty
        ? Array(parsed.tokens.dropFirst()) : Array(parsed.tokens.dropFirst().dropLast())
      candidates += Self.specCandidates(
        root: root, completed: completed, current: parsed.currentToken, language: language)
    }

    var seen: Set<String> = []
    let unique = candidates
      .filter { seen.insert($0.insertText).inserted }
      .sorted { left, right in
        if left.score != right.score { return left.score > right.score }
        return left.insertText.localizedStandardCompare(right.insertText) == .orderedAscending
      }
    let fullLineKinds: Set<AutocompleteCandidateKind> = [
      .snippet, .learnedCommand, .readmeCommand, .correction,
    ]
    let firstCandidateUsesFullLine: Bool
    if let first = unique.first {
      firstCandidateUsesFullLine = first.insertText.hasPrefix(query.line)
        && first.insertText.count > query.line.count
        && fullLineKinds.contains(first.kind)
    } else {
      firstCandidateUsesFullLine = false
    }
    let ghostText = unique.first.flatMap { candidate -> String? in
      if firstCandidateUsesFullLine {
        return String(candidate.insertText.dropFirst(query.line.count))
      }
      guard candidate.insertText.hasPrefix(parsed.currentToken),
        candidate.insertText.count > parsed.currentToken.count
      else { return nil }
      return String(candidate.insertText.dropFirst(parsed.currentToken.count))
    }
    return AutocompleteResult(
      candidates: Array(unique.prefix(200)),
      ghostText: ghostText,
      replacementStart: firstCandidateUsesFullLine ? 0 : parsed.currentTokenStart
    )
  }
}

extension AutocompleteEngine {
  /// 沿着已完成的 token 在规格树上前进:子命令下钻、带参数的选项吞掉下一个 token、
  /// 其余当作位置参数;最后按“正在输入什么”决定给出选项、子命令还是参数候选。
  fileprivate static func specCandidates(
    root: AutocompleteCommandSpec,
    completed: [String],
    current: String,
    language: AutocompleteDescriptionLanguage
  ) -> [AutocompleteCandidate] {
    var command = root
    var pendingOptionArguments: [AutocompleteArgumentSpec] = []
    var positionalIndex = 0
    for token in completed {
      if !pendingOptionArguments.isEmpty {
        pendingOptionArguments.removeFirst()
        continue
      }
      if token.hasPrefix("-"), token.count > 1 {
        // `--key=value` 已经自带参数;其它带参选项让后续 token 成为它的参数。
        if let option = command.option(named: token), !token.contains("=") {
          pendingOptionArguments = option.args
        }
        continue
      }
      if positionalIndex == 0, let subcommand = command.subcommand(named: token) {
        command = subcommand
        continue
      }
      positionalIndex += 1
    }

    var result: [AutocompleteCandidate] = []
    func addArgument(_ argument: AutocompleteArgumentSpec) {
      result += argument.suggestions
        .filter { $0.name.hasPrefix(current) && $0.name != current }
        .map {
          AutocompleteCandidate(
            insertText: $0.name, description: $0.description, kind: .argument, score: 100_000)
        }
    }
    if let argument = pendingOptionArguments.first {
      addArgument(argument)
      return result
    }
    if current.hasPrefix("-") {
      for option in command.options where !option.hidden {
        guard let insert = option.names.first(where: { $0.hasPrefix(current) && $0 != current })
        else { continue }
        result.append(
          AutocompleteCandidate(
            insertText: insert,
            displayText: option.names.joined(separator: ", "),
            description: option.description,
            kind: .option,
            score: 100_000
          ))
      }
      return result
    }
    if positionalIndex == 0 {
      result += command.subcommands
        .filter { !$0.hidden && $0.name.hasPrefix(current) && $0.name != current }
        .map {
          AutocompleteCandidate(
            insertText: $0.name,
            description: $0.description.text(for: language),
            kind: .subcommand,
            score: 100_000
          )
        }
    }
    // 位置参数:超出声明数量时,最后一个 variadic 参数继续接收。
    if !command.arguments.isEmpty {
      let index = min(positionalIndex, command.arguments.count - 1)
      let argument = command.arguments[index]
      if positionalIndex < command.arguments.count || argument.isVariadic {
        addArgument(argument)
      }
    }
    return result
  }
}

// MARK: - Prompt input model

/// 根据用户发送到 PTY 的字节重建当前 prompt 文本。遇到 Up/Down 等依赖 Shell 内部
/// 历史状态的操作时标记为不可靠，调用方应隐藏补全，直到下一次 OSC 133 prompt 标记。
public final class PromptInputTracker {
  private var characters: [Character] = []
  private var cursor = 0
  private var pendingEscapeBytes: [UInt8] = []
  private var decoder = UTF8StreamDecoder()
  private var suppressNextLineFeed = false
  public private(set) var isReliable = true

  public init() {}

  public var line: String { String(characters) }
  /// 候选后缀只能安全插入行尾；光标位于命令中间时继续让 Shell 处理导航和编辑。
  public var isCursorAtEnd: Bool { cursor == characters.count }

  public func beginPrompt() {
    characters.removeAll(keepingCapacity: true)
    cursor = 0
    pendingEscapeBytes.removeAll(keepingCapacity: true)
    decoder = UTF8StreamDecoder()
    suppressNextLineFeed = false
    isReliable = true
  }

  /// 追加键盘字节并返回本轮提交的命令。支持常见 Emacs 编辑键和 CSI 光标操作；
  /// 无法安全重建的控制序列会使当前 prompt 失效，而不会猜测 Shell 状态。
  public func receive(_ bytes: [UInt8]) -> [String] {
    let input = pendingEscapeBytes + bytes
    pendingEscapeBytes.removeAll(keepingCapacity: true)
    var index = 0
    var submitted: [String] = []

    while index < input.count {
      let byte = input[index]
      if byte == 0x1B {
        guard let consumed = consumeEscape(in: input, from: index) else {
          pendingEscapeBytes = Array(input[index...])
          break
        }
        index += consumed
        continue
      }

      switch byte {
      case 0x0A where suppressNextLineFeed:
        suppressNextLineFeed = false
      case 0x0A:
        submitted.append(line)
        characters.removeAll(keepingCapacity: true)
        cursor = 0
      case 0x0D:
        submitted.append(line)
        characters.removeAll(keepingCapacity: true)
        cursor = 0
        suppressNextLineFeed = true
      case 0x01: cursor = 0  // Ctrl-A
      case 0x05: cursor = characters.count  // Ctrl-E
      case 0x0B:  // Ctrl-K
        if cursor < characters.count { characters.removeSubrange(cursor...) }
      case 0x15:  // Ctrl-U
        if cursor > 0 {
          characters.removeSubrange(0..<cursor)
          cursor = 0
        }
      case 0x17: deletePreviousWord()  // Ctrl-W
      case 0x7F, 0x08:
        if cursor > 0 {
          characters.remove(at: cursor - 1)
          cursor -= 1
        }
      case 0x20...0x7E, 0x80...0xFF:
        appendDecoded(byte)
      default:
        isReliable = false
      }
      if byte != 0x0D && byte != 0x0A { suppressNextLineFeed = false }
      index += 1
    }
    return submitted
  }

  private func appendDecoded(_ byte: UInt8) {
    let text = decoder.append(Data([byte]))
    guard !text.isEmpty else { return }
    characters.insert(contentsOf: text, at: cursor)
    cursor += text.count
  }

  private func consumeEscape(in bytes: [UInt8], from start: Int) -> Int? {
    guard start + 1 < bytes.count else { return nil }
    if bytes[start + 1] != 0x5B {
      switch bytes[start + 1] {
      case 0x62: moveByWord(direction: -1)  // Option-Left / Esc-b
      case 0x66: moveByWord(direction: 1)  // Option-Right / Esc-f
      case 0x64: deleteNextWord()  // Esc-d
      default: isReliable = false
      }
      return 2
    }

    guard start + 2 < bytes.count else { return nil }
    var finalIndex = start + 2
    while finalIndex < bytes.count, !(0x40...0x7E).contains(bytes[finalIndex]) {
      finalIndex += 1
    }
    guard finalIndex < bytes.count else { return nil }
    let final = bytes[finalIndex]
    let parameters = String(decoding: bytes[(start + 2)..<finalIndex], as: UTF8.self)
    switch final {
    case 0x44: cursor = max(0, cursor - 1)  // Left
    case 0x43: cursor = min(characters.count, cursor + 1)  // Right
    case 0x48: cursor = 0  // Home
    case 0x46: cursor = characters.count  // End
    case 0x7E where parameters == "3":
      if cursor < characters.count { characters.remove(at: cursor) }
    case 0x41, 0x42: isReliable = false  // Up/Down depend on Shell history.
    default: isReliable = false
    }
    return finalIndex - start + 1
  }

  private func deletePreviousWord() {
    while cursor > 0, characters[cursor - 1].isWhitespace {
      characters.remove(at: cursor - 1)
      cursor -= 1
    }
    while cursor > 0, !characters[cursor - 1].isWhitespace {
      characters.remove(at: cursor - 1)
      cursor -= 1
    }
  }

  private func deleteNextWord() {
    while cursor < characters.count, characters[cursor].isWhitespace { characters.remove(at: cursor) }
    while cursor < characters.count, !characters[cursor].isWhitespace { characters.remove(at: cursor) }
  }

  private func moveByWord(direction: Int) {
    if direction < 0 {
      while cursor > 0, characters[cursor - 1].isWhitespace { cursor -= 1 }
      while cursor > 0, !characters[cursor - 1].isWhitespace { cursor -= 1 }
    } else {
      while cursor < characters.count, !characters[cursor].isWhitespace { cursor += 1 }
      while cursor < characters.count, characters[cursor].isWhitespace { cursor += 1 }
    }
  }
}

/// 一条由 OSC 133 C/D 明确界定的命令输出。文本不持久化，只供本轮纠错解析。
public struct ShellCapturedCommandOutput: Equatable, Sendable {
  public let text: String
  public let exitStatus: Int?

  public init(text: String, exitStatus: Int?) {
    self.text = text
    self.exitStatus = exitStatus
  }
}

/// 从任意 PTY 分片中提取 OSC 133 C（输出开始）和 D（命令完成）之间的字节。
/// OSC 控制串本身不会进入文本；普通 CSI 保留给 `ANSICleaner` 后续清理。
public struct ShellCommandOutputCapture: Sendable {
  private enum State: Sendable {
    case text
    case escape
    case osc
    case oscEscape
  }

  private let maximumOutputBytes: Int
  private var state = State.text
  private var oscPayload: [UInt8] = []
  private var output: [UInt8] = []
  private var outputStart = 0
  private var isCapturing = false

  public init(maximumOutputBytes: Int = 128 * 1_024) {
    self.maximumOutputBytes = max(1, maximumOutputBytes)
  }

  public mutating func consume(_ bytes: ArraySlice<UInt8>) -> [ShellCapturedCommandOutput] {
    var completed: [ShellCapturedCommandOutput] = []
    for byte in bytes {
      switch state {
      case .text:
        if byte == 0x1B {
          state = .escape
        } else if isCapturing {
          appendOutput(byte)
        }
      case .escape:
        if byte == 0x5D {  // ESC ] starts OSC.
          oscPayload.removeAll(keepingCapacity: true)
          state = .osc
        } else {
          if isCapturing {
            appendOutput(0x1B)
            appendOutput(byte)
          }
          state = .text
        }
      case .osc:
        if byte == 0x07 {
          finishOSC(into: &completed)
          state = .text
        } else if byte == 0x1B {
          state = .oscEscape
        } else if oscPayload.count < 4_096 {
          oscPayload.append(byte)
        }
      case .oscEscape:
        if byte == 0x5C {  // ESC \ is String Terminator.
          finishOSC(into: &completed)
          state = .text
        } else {
          // OSC payload 中的异常 ESC 不是终止符；保留有限 payload 后继续寻找终止字节。
          if oscPayload.count < 4_095 {
            oscPayload.append(0x1B)
            oscPayload.append(byte)
          }
          state = .osc
        }
      }
    }
    return completed
  }

  private mutating func finishOSC(into completed: inout [ShellCapturedCommandOutput]) {
    guard let payload = String(bytes: oscPayload, encoding: .ascii), payload.hasPrefix("133;")
    else {
      oscPayload.removeAll(keepingCapacity: true)
      return
    }
    let eventPayload = String(payload.dropFirst(4))
    if eventPayload == "C" {
      resetOutput()
      isCapturing = true
    } else if case .commandFinished(let status)? = ShellIntegrationEvent(payload: eventPayload),
      isCapturing
    {
      completed.append(
        ShellCapturedCommandOutput(
          text: String(decoding: orderedOutput(), as: UTF8.self),
          exitStatus: status
        ))
      resetOutput()
      isCapturing = false
    }
    oscPayload.removeAll(keepingCapacity: true)
  }

  private mutating func appendOutput(_ byte: UInt8) {
    if output.count < maximumOutputBytes {
      output.append(byte)
      return
    }
    // 固定容量环形缓冲保留错误输出的末尾，避免持续输出时 Array.removeFirst 退化为
    // 每字节一次的线性搬移。
    output[outputStart] = byte
    outputStart = (outputStart + 1) % maximumOutputBytes
  }

  private mutating func resetOutput() {
    output.removeAll(keepingCapacity: true)
    outputStart = 0
  }

  private func orderedOutput() -> [UInt8] {
    guard output.count == maximumOutputBytes, outputStart != 0 else { return output }
    return Array(output[outputStart...]) + Array(output[..<outputStart])
  }
}
