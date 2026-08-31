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

  /// 把本机 `--help` 探测出的规格并进内置规格，而不是整个替换掉。
  ///
  /// 覆盖式合并会造成真实退化：内置 Fig 规格里 `docker` 有 58 个子命令，而
  /// `docker --help` 只列出 40 个常用的，覆盖之后 `docker compose` 这类就补不出来了。
  /// 反过来，内置规格的顶层选项常常是 0 个，只有 help 探测能补上。因此按字段并集：
  /// 子命令与选项取并集，冲突时保留结构更完整的一方（内置规格带嵌套子命令、参数
  /// 模板和 generatorScripts，help 解析器给不出这些）。
  public func merging(probed local: AutocompleteCommandSpec) -> AutocompleteCommandSpec {
    var mergedSubcommands = subcommands
    var index: [String: Int] = [:]
    for (offset, item) in subcommands.enumerated() { index[item.name] = offset }
    for item in local.subcommands {
      if let existing = index[item.name] {
        // 同名子命令递归合并，而不是只借个描述就丢掉 help 的内容。上游 Fig 规格里
        // 有大量“只有名字”的壳子（`docker compose` 就是），只保留内置结构等于把
        // `docker compose --help` 探测出来的子命令和选项全部扔掉。
        mergedSubcommands[existing] = mergedSubcommands[existing].merging(probed: item)
      } else {
        index[item.name] = mergedSubcommands.count
        mergedSubcommands.append(item)
      }
    }

    var mergedOptions = options
    var seenOptionNames = Set(options.flatMap(\.names))
    for option in local.options where !option.names.contains(where: seenOptionNames.contains) {
      seenOptionNames.formUnion(option.names)
      mergedOptions.append(option)
    }

    return AutocompleteCommandSpec(
      name: name,
      description: description.text(for: .english).isEmpty ? local.description : description,
      aliases: aliases.isEmpty ? local.aliases : aliases,
      hidden: hidden,
      subcommands: mergedSubcommands.sorted { $0.name < $1.name },
      options: mergedOptions,
      arguments: arguments.isEmpty ? local.arguments : arguments
    )
  }

  /// 规格是否完整到不需要再做 `--help` 探测。
  ///
  /// 判定刻意比 `hasDetails` 严：上游 Fig 规格里存在“只有子命令、一个选项都没有”的
  /// 条目（`docker` 就是 58 个子命令 + 0 个选项），旧的宽松判定会认为它已经够详细，
  /// 于是那些命令的顶层 flag 永远补不出来。有子命令的命令必须同时有选项或参数才算
  /// 完整；纯 flag 型命令（无子命令）只要有选项就够。
  public var hasCompleteSpec: Bool {
    if !subcommands.isEmpty { return !options.isEmpty || !arguments.isEmpty }
    return !options.isEmpty || !arguments.isEmpty
  }

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
    /// 上一条真实条目的缩进，用来识别描述续行。`Int.max` 是“本区还没有签名”的哨兵：
    /// 每个区的第一条一定按签名处理，否则它会因为缩进大于上一区的残留值而被误判成
    /// 续行——docker 的 `Commands:` 区就紧跟在 `Options:` 区后面。
    var lastSignatureIndent = Int.max
    for sourceLine in output.split(separator: "\n", omittingEmptySubsequences: false) {
      let line = sourceLine.trimmingCharacters(in: .whitespacesAndNewlines)
      let header = line.lowercased()
      if ["commands:", "available commands:", "subcommands:", "management commands:"]
        .contains(header)
      {
        section = .commands
        lastSignatureIndent = Int.max
        continue
      }
      if ["options:", "flags:", "global options:"].contains(header) {
        section = .options
        lastSignatureIndent = Int.max
        continue
      }
      if line.isEmpty { continue }
      // help 输出会把过长的描述折到下一行，续行只有描述、没有签名。旧实现把这种行
      // 当成新条目，于是 `-l, --log-level string  Set the logging level ("debug",
      // "info", "warn", "error", "fatal")` 的第二行会变成一个叫 `"warn",` 的假候选，
      // `attach` 描述折行里的 `to a running container` 会变成一个叫 `to` 的假子命令。
      //
      // 判定要两个信号一起用，单靠任何一个都不够：
      //   * 缩进严格大于上一条签名 —— 描述续行总是对齐到描述列。只靠它不行，
      //     options 区的 `    --tls` 会比 `-D, --debug` 缩进更深却是真签名。
      //   * 本行看起来不像签名 —— options 区的签名必然以 `-` 开头。只靠它也不行，
      //     commands 区的续行首词（`to`）本身就是个合法标识符。
      let indent = sourceLine.prefix { $0 == " " || $0 == "\t" }.count
      if section != .none, indent > lastSignatureIndent,
        !looksLikeSignature(line, section: section)
      {
        continue
      }
      guard let (signature, description) = columns(in: line) else { continue }
      lastSignatureIndent = indent

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

  /// 缩进更深的一行是否仍然是真签名。options 区里 `    --tls` 这种为了对齐短选项
  /// 而多缩进的写法很常见，必须靠 `-` 前缀把它和描述续行区分开；commands 区的签名
  /// 一律左对齐在同一列，更深的缩进只可能是续行。
  private static func looksLikeSignature(_ line: String, section: Section) -> Bool {
    guard let first = line.split(whereSeparator: \.isWhitespace).first.map(String.init)
    else { return false }
    switch section {
    case .options: return first.hasPrefix("-")
    case .commands, .none: return false
    }
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
  /// 归一化到 [0,1] 的 frecency,供跨来源排序模型使用。`score` 只在学习库内部排序,
  /// 量纲不受约束,不能直接和规格候选比较。
  public let frecency: Double
  public let isSessionMatch: Bool
  public let pinCount: Int

  public init(
    command: String,
    score: Double,
    frecency: Double = 0,
    isSessionMatch: Bool = false,
    pinCount: Int = 0
  ) {
    self.command = command
    self.score = score
    self.frecency = frecency
    self.isSessionMatch = isSessionMatch
    self.pinCount = pinCount
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
  /// 撤销一次 `pin`。这是 `aster ignore` 的领域动作：只清掉固定标记，如果该命令还有
  /// 普通使用历史就保留下来（用户只是不想再把它钉在最前面，不是要抹掉自己跑过它）。
  /// 返回 false 表示这条命令本来就没有被固定过。
  @discardableResult
  public mutating func unpin(command: String, directory: String) -> Bool {
    guard let directory = Self.normalizedDirectory(directory),
      let sanitized = Self.sanitizedCommand(command),
      let index = entries.firstIndex(where: {
        $0.command == sanitized && $0.directory == directory && $0.pinCount > 0
      })
    else { return false }
    if entries[index].useCount > 0 {
      entries[index].pinCount = 0
    } else {
      entries.remove(at: index)
    }
    return true
  }

  /// 该命令在指定目录下是否被固定过，供 CLI 在撤销前做存在性判断。
  public func isPinned(command: String, directory: String) -> Bool {
    guard let directory = Self.normalizedDirectory(directory),
      let sanitized = Self.sanitizedCommand(command)
    else { return false }
    return entries.contains {
      $0.command == sanitized && $0.directory == directory && $0.pinCount > 0
    }
  }

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
        // 频率取 log2 并在 255 次封顶:线性计数会让一条刷了几百次的命令永远霸榜,
        // 而用户真正想要的是“最近在干什么”。
        let frequency = min(log2(1 + Double(entry.useCount)), 8) / 8
        // 时间衰减用 7 天半衰期的指数曲线。旧实现的 10_000/(1+ageDays) 是双曲衰减,
        // 尾巴太肥——一个月前跑过的命令仍保留 1/31 的权重,足以压住贴合当前输入的
        // 规格候选。指数衰减让一周前降到 0.5、三周前降到 0.125,正好落到规格之下。
        let ageDays = max(0, now.timeIntervalSince(entry.lastUsedAt)) / 86_400
        let recency = pow(0.5, ageDays / 7)
        let frecency = 0.55 * frequency + 0.45 * recency
        let isSessionMatch = entry.lastSessionIdentifier == normalizedSession
        // pin 加成同样封顶:重复 `aster learn` 四次以后不再继续拉开差距。
        let pinBoost = Double(min(entry.pinCount, 4)) / 4
        return AutocompleteLearnedSuggestion(
          command: entry.command,
          score: frecency + 2.0 * pinBoost + (isSessionMatch ? 0.6 : 0),
          frecency: frecency,
          isSessionMatch: isSessionMatch,
          pinCount: entry.pinCount
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
  /// 由磁盘活数据生成的参数候选(git 分支、Homebrew formula、npm script 等)。
  /// 与 `argument` 分开是为了让面板图标如实表达“这条来自你的仓库/机器,不是规格里写死的”。
  case dynamicArgument
  case file
  case folder
  case alias
  case snippet
  case learnedCommand
  case readmeCommand
  case correction
}

/// 候选被接受时替换命令行的范围。整行候选从行首替换,token 候选只替换正在输入的
/// token。引擎在构造候选时就定好范围,UI 不再自行推断,消除两处重复真值。
public enum AutocompleteReplacementSpan: Equatable, Sendable {
  case fullLine
  case currentToken(start: Int)

  public var start: Int {
    if case .currentToken(let value) = self { value } else { 0 }
  }
}

public struct AutocompleteCandidate: Equatable, Sendable {
  public let insertText: String
  public let displayText: String
  public let description: String
  public let kind: AutocompleteCandidateKind
  public let score: Double
  public let replacement: AutocompleteReplacementSpan

  /// `replacement` 默认取 `.fullLine` 是刻意的失败安全:某个构造点漏填时,接受路径的
  /// 前缀校验会失败并拒绝接受,而不是往命令行里插入错位文本。
  public init(
    insertText: String,
    displayText: String? = nil,
    description: String = "",
    kind: AutocompleteCandidateKind,
    score: Double = 0,
    replacement: AutocompleteReplacementSpan = .fullLine
  ) {
    self.insertText = insertText
    self.displayText = displayText ?? insertText
    self.description = description
    self.kind = kind
    self.score = score
    self.replacement = replacement
  }

  /// 在插入文本前补一个空格，用于“命令名刚打完、还没敲空格”时直接给出下一段参数。
  /// 显示文本不变：面板里应该看到 `attach`，而不是 ` attach`。
  func prefixedWithSeparator() -> AutocompleteCandidate {
    AutocompleteCandidate(
      insertText: " " + insertText, displayText: displayText, description: description,
      kind: kind, score: score, replacement: replacement)
  }

  /// 返回同一候选但换一个分数,供排序模型和跨来源归并复用。
  public func withScore(_ score: Double) -> AutocompleteCandidate {
    AutocompleteCandidate(
      insertText: insertText, displayText: displayText, description: description,
      kind: kind, score: score, replacement: replacement)
  }

  /// 接受该候选后命令行的完整文本。跨来源去重与接受路径共用它,保证“同一条命令”
  /// 无论以整行还是 token 形态出现,都归到同一个键、插入同一段字节。
  public func resultingLine(from line: String) -> String? {
    let start = replacement.start
    guard start >= 0, start <= line.count else { return nil }
    let head = String(line.prefix(start))
    let typed = String(line.dropFirst(start))
    guard insertText.hasPrefix(typed) else { return nil }
    return head + insertText
  }

  /// 接受该候选时需要追加到 PTY 的后缀。接受路径是只追加的,因此候选必须以
  /// “当前替换范围内已输入的文本”为前缀,否则返回 nil 表示不可接受。
  public func appendableSuffix(from line: String) -> String? {
    guard let resulting = resultingLine(from: line), resulting.hasPrefix(line),
      resulting.count > line.count
    else { return nil }
    return String(resulting.dropFirst(line.count))
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

  public static let empty = AutocompleteResult(
    candidates: [], ghostText: nil, replacementStart: 0)

  /// 从已排序候选派生 ghost 与整体替换起点。ghost 显示的文本和 Tab 实际插入的字节
  /// 必须来自同一次计算,否则用户看到的和接受到的会不一致——这正是过去引擎与控制器
  /// 各算一遍替换范围时出现的问题。
  public static func make(
    candidates: [AutocompleteCandidate], line: String
  ) -> AutocompleteResult {
    guard let first = candidates.first else {
      return AutocompleteResult(candidates: candidates, ghostText: nil, replacementStart: 0)
    }
    return AutocompleteResult(
      candidates: candidates,
      ghostText: first.appendableSuffix(from: line),
      replacementStart: first.replacement.start
    )
  }
}

/// 跨来源可比的候选相关性。所有来源折算到同一分制:基础权重表达“这类候选平均有多
/// 切题”,匹配质量表达“用户已经打了多少字”,frecency / 会话 / pin 表达“这个用户此刻
/// 有多想要它”。
///
/// 旧实现用分层加法常量(pin +2e6 > 历史 +1e6 > 规格 1e5 …),同一层内全部同分只能按
/// 字母序排,层与层之间又永远压制——任意一条冷历史都能压过全部规格子命令,来源之间
/// 无法交错。
///
/// 关键设计:**历史条目的基础权重刻意低于子命令**(130 < 165)。“它是一条历史”本身
/// 几乎不该加分,真正的价值全部来自 frecency 与会话加成。改动常量前请先重算这两条
/// (数字是 `git ch` 补 `checkout` 与历史 `git checkout --force origin` 的真实取值):
///
///   冷历史(frecency 0.1、非本会话) = 130 + 220*0.611 + 260*0.1  ≈ 290  → 输
///   前缀吻合的子命令               = 165 + 220*0.625            ≈ 303
///   本会话热历史(frecency 0.95)    = 130 + 220*0.611 + 247 + 120 ≈ 631  → 赢
///
/// 注意 matchQuality 在短前缀下被压得很扁(2/8 的输入比例只给到 0.625),所以不能像
/// 直觉那样假设“贴合的候选 mq≈0.9”——基础权重必须自己扛起来源之间的秩序。
/// frecency 的带宽(260+120+80=460)远大于基础权重跨度(100~300),“用得多”因此能翻越
/// 来源层级;而单次 frecency 加成又不足以让一条弱相关历史压住所有规格候选。
public enum AutocompleteRelevance {
  /// 用户已输入部分占候选全长的比例。前缀匹配下恒在 (0.5, 1],打字越准越靠前,
  /// 且这一项对所有来源共享,杜绝“某来源恒定垫底”。
  public static func matchQuality(typed: String, candidate: String) -> Double {
    guard !candidate.isEmpty else { return 0.5 }
    let ratio = min(1, Double(typed.count) / Double(candidate.count))
    return 0.5 + 0.5 * ratio
  }

  /// 各来源的基础权重。数量最大的文件/目录基座最低,必须靠用户已打的路径前缀浮上来。
  public static func baseWeight(for kind: AutocompleteCandidateKind) -> Double {
    switch kind {
    case .correction: 300      // 上条命令刚失败,纠错是最强意图
    case .snippet: 200         // `aster learn` 显式钉到当前目录的
    case .dynamicArgument: 175 // 分支 / formula / script 这类活数据
    case .subcommand: 165
    case .argument: 150
    case .option: 140
    case .alias: 135
    // 历史与命令名同级:见类型注释,历史的价值来自 frecency 而不是“它是历史”。
    case .learnedCommand: 130
    case .command: 130
    case .readmeCommand: 115
    case .folder: 110
    case .file: 100
    }
  }

  public static func score(
    kind: AutocompleteCandidateKind,
    matchQuality: Double,
    frecency: Double = 0,
    sessionBoost: Double = 0,
    pinBoost: Double = 0,
    extra: Double = 0
  ) -> Double {
    baseWeight(for: kind)
      + 220 * matchQuality
      + 260 * frecency
      + 120 * sessionBoost
      + 80 * pinBoost
      + extra
  }

  /// 便捷入口:按“候选自己的替换范围内已输入了什么”算匹配质量。
  public static func score(
    kind: AutocompleteCandidateKind,
    typed: String,
    candidate: String,
    frecency: Double = 0,
    sessionBoost: Double = 0,
    pinBoost: Double = 0,
    extra: Double = 0
  ) -> Double {
    score(
      kind: kind,
      matchQuality: matchQuality(typed: typed, candidate: candidate),
      frecency: frecency, sessionBoost: sessionBoost, pinBoost: pinBoost, extra: extra)
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
    dynamic: AutocompleteDynamicProvider = .empty,
    language: AutocompleteDescriptionLanguage = .system
  ) -> AutocompleteResult {
    // 空 prompt 不产生任何候选。没有输入就没有用户意图，把整个命令库和全部历史列出来
    // 只是噪音，而且面板一旦弹出就会吞掉回车，让用户以为终端卡住了。只有空白字符的
    // 行同样按空处理；`git ` 这种尾随空格的行 trim 后仍非空，不受影响。
    guard !query.line.trimmingCharacters(in: .whitespaces).isEmpty else {
      return .empty
    }
    let parsed = ShellCommandTokenizer.tokenize(query.line)
    let line = query.line
    let token = parsed.currentToken
    let tokenSpan = AutocompleteReplacementSpan.currentToken(start: parsed.currentTokenStart)
    var candidates: [AutocompleteCandidate] = []

    // 固定、历史与 README 候选保存完整命令行，任何输入阶段都可按完整前缀参与；
    // 规格与动态候选只替换当前 token。替换范围随候选一起传给 UI，不再由 UI 反推。
    candidates += pinned.filter { $0.command.hasPrefix(line) && $0.command != line }.map {
      AutocompleteCandidate(
        insertText: $0.command, kind: .snippet,
        score: AutocompleteRelevance.score(
          kind: .snippet, typed: line, candidate: $0.command,
          frecency: $0.frecency, sessionBoost: $0.isSessionMatch ? 1 : 0,
          pinBoost: Double(min($0.pinCount, 4)) / 4),
        replacement: .fullLine)
    }
    candidates += learned.filter { $0.command.hasPrefix(line) && $0.command != line }.map {
      AutocompleteCandidate(
        insertText: $0.command, kind: .learnedCommand,
        score: AutocompleteRelevance.score(
          kind: .learnedCommand, typed: line, candidate: $0.command,
          frecency: $0.frecency, sessionBoost: $0.isSessionMatch ? 1 : 0),
        replacement: .fullLine)
    }
    candidates += readmeCommands.filter { $0.hasPrefix(line) && $0 != line }.map {
      AutocompleteCandidate(
        insertText: $0, kind: .readmeCommand,
        score: AutocompleteRelevance.score(kind: .readmeCommand, typed: line, candidate: $0),
        replacement: .fullLine)
    }
    if parsed.tokens.count <= 1, !line.contains(where: \.isWhitespace) {
      candidates += aliases.filter { $0.hasPrefix(token) && $0 != token }.map {
        AutocompleteCandidate(
          insertText: $0, description: "Shell 别名", kind: .alias,
          score: AutocompleteRelevance.score(kind: .alias, typed: token, candidate: $0),
          replacement: tokenSpan)
      }
    }

    // 上面的空行 guard 已经排除了 tokens 为空的情况，这里只处理“正在输入命令名”和
    // “已经有命令名、在补子命令/选项/参数”两种真实输入状态。
    if parsed.tokens.count <= 1, !line.contains(where: \.isWhitespace) {
      candidates += specDatabase.commands
        .filter { $0.name.hasPrefix(token) && $0.name != token }
        .map {
          AutocompleteCandidate(
            insertText: $0.name,
            description: $0.description.text(for: language),
            kind: .command,
            score: AutocompleteRelevance.score(kind: .command, typed: token, candidate: $0.name),
            replacement: tokenSpan
          )
        }
      // 命令名已经打完整(还没敲空格)时，除了同前缀的其它命令名，也要给出这个命令
      // 本身能做什么。用户打完 `docker` 按 Tab 想看的是它的子命令和选项，而不是
      // 「还有哪些可执行文件叫 docker*」——旧实现在这里只剩一条 `docker-compose`。
      // 这些候选要补上前导空格，因为当前 token 已经被完整占用了。
      if let root = specDatabase.command(named: token) {
        candidates += Self.specCandidates(
          root: root, completed: [], current: "", language: language,
          span: .currentToken(start: line.count), dynamic: dynamic
        ).map { $0.prefixedWithSeparator() }
      }
    } else if let commandName = parsed.tokens.first,
      let root = specDatabase.command(named: commandName)
    {
      // 已完成的 token 不含正在输入的那个:行尾有空格时 currentToken 为空,全部 token
      // 都算完成;否则最后一个 token 就是正在输入的前缀,要从路径推进中排除。
      let completed = token.isEmpty
        ? Array(parsed.tokens.dropFirst()) : Array(parsed.tokens.dropFirst().dropLast())
      candidates += Self.specCandidates(
        root: root, completed: completed, current: token, language: language,
        span: tokenSpan, dynamic: dynamic)
    }

    return .make(candidates: Self.rank(candidates, line: line), line: line)
  }

  /// 跨来源归并 + 排序的唯一入口。服务层追加文件候选后会再调用一次,因此它必须
  /// 幂等:重复归并同一批候选不会反复叠加佐证加成(合并只在键冲突时发生)。
  public static func rank(
    _ candidates: [AutocompleteCandidate], line: String
  ) -> [AutocompleteCandidate] {
    var merged: [String: AutocompleteCandidate] = [:]
    var order: [String] = []
    for candidate in candidates {
      // 归一化键是“接受该候选后的完整命令行”。这样历史里的整行 `git checkout main`
      // 与动态分支候选 `main`(token) 会落到同一个键上,合并成一行——既保留 frecency
      // 排序,又保留“分支”图标。只按 insertText 去重完全拦不住这种跨来源重复。
      guard let resulting = candidate.resultingLine(from: line) else { continue }
      let key = Self.deduplicationKey(resulting)
      if let existing = merged[key] {
        merged[key] = Self.merge(existing, candidate)
      } else {
        merged[key] = candidate
        order.append(key)
      }
    }
    return order.compactMap { merged[$0] }
      .sorted { left, right in
        if left.score != right.score { return left.score > right.score }
        return left.insertText.localizedStandardCompare(right.insertText) == .orderedAscending
      }
  }

  /// 折叠连续空白、去尾随空白并做 NFC 归一。只用于判定“是不是同一条命令”,
  /// 实际插入的字节仍由幸存候选自己的替换范围决定。
  static func deduplicationKey(_ line: String) -> String {
    line.split(separator: " ", omittingEmptySubsequences: true)
      .joined(separator: " ")
      .precomposedStringWithCanonicalMapping
  }

  private static func merge(
    _ lhs: AutocompleteCandidate, _ rhs: AutocompleteCandidate
  ) -> AutocompleteCandidate {
    let fullLineKinds: Set<AutocompleteCandidateKind> = [
      .snippet, .learnedCommand, .readmeCommand, .correction,
    ]
    // 近似平局时优先整行候选:一次补全整条记住的命令,比只补一个 token 价值更大。
    var winner = lhs.score >= rhs.score ? lhs : rhs
    var loser = lhs.score >= rhs.score ? rhs : lhs
    if abs(lhs.score - rhs.score) < 15, fullLineKinds.contains(loser.kind),
      !fullLineKinds.contains(winner.kind)
    {
      swap(&winner, &loser)
    }
    let description = winner.description.isEmpty ? loser.description : winner.description
    // 佐证加成是固定 +25 而不是比例加成:跨来源一致只是弱证据,25 分约等于 0.11 的
    // matchQuality 差,足以在真平局时定序,不足以让它跨越好几名。
    return AutocompleteCandidate(
      insertText: winner.insertText,
      displayText: winner.displayText,
      description: description,
      kind: winner.kind,
      score: max(lhs.score, rhs.score) + 25,
      replacement: winner.replacement
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
    language: AutocompleteDescriptionLanguage,
    span: AutocompleteReplacementSpan,
    dynamic: AutocompleteDynamicProvider
  ) -> [AutocompleteCandidate] {
    var command = root
    // 命令路径供动态来源的兜底表使用(例如 `make` 根本没有 generatorScript)。
    var commandPath: [String] = [root.name]
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
        commandPath.append(subcommand.name)
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
            insertText: $0.name, description: $0.description, kind: .argument,
            score: AutocompleteRelevance.score(
              kind: .argument, typed: current, candidate: $0.name),
            replacement: span)
        }
      // 动态候选只在真正解析到某个参数槽位时才回调,避免每次按键都触碰磁盘。
      for source in AutocompleteDynamicSource.sources(for: argument, commandPath: commandPath) {
        result += dynamic.items(for: source)
          .filter { $0.name.hasPrefix(current) && $0.name != current }
          .map { item in
            AutocompleteCandidate(
              insertText: item.name, description: item.description, kind: .dynamicArgument,
              score: AutocompleteRelevance.score(
                kind: .dynamicArgument, typed: current, candidate: item.name,
                extra: item.rankBonus),
              replacement: span)
          }
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
            score: AutocompleteRelevance.score(
              kind: .option, typed: current, candidate: insert),
            replacement: span
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
            score: AutocompleteRelevance.score(
              kind: .subcommand, typed: current, candidate: $0.name),
            replacement: span
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

// MARK: - `aster learn` 目标分类

/// `aster learn <target>` 的三种意图。目录 → 记为常用目录;PATH 上的裸二进制 →
/// 用 `--help` 探测生成本地补全规格;其余一律当作整行命令钉到当前目录。
///
/// 判定顺序不能反:`aster learn 'npm run build'` 含空格,必须走 `.command`,否则会被
/// 当成一个叫 "npm run build" 的可执行文件去 PATH 上找。
public enum AutocompleteLearnTarget: Equatable, Sendable {
  case folder(String)
  case binary(name: String, executable: String)
  case command(String)

  public static func classify(
    target: String,
    isDirectory: (String) -> Bool,
    resolveExecutable: (String) -> String?
  ) -> AutocompleteLearnTarget {
    if isDirectory(target) { return .folder(target) }
    guard isBareBinaryName(target), let executable = resolveExecutable(target) else {
      return .command(target)
    }
    return .binary(name: target, executable: executable)
  }

  /// “PATH 上的裸二进制”必须同时满足:不含空白(有空格就是命令行)、不含 `/`
  /// (含路径就不是 PATH 查找)、字符集受限且长度有界。
  public static func isBareBinaryName(_ value: String) -> Bool {
    guard !value.isEmpty, value.utf8.count <= 128,
      !value.contains(where: { $0.isWhitespace }),
      !value.contains("/")
    else { return false }
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._+-"))
    return value.unicodeScalars.allSatisfy { allowed.contains($0) }
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
