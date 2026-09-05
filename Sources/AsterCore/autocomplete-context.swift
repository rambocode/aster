import Foundation

/// 补全时的规格游标。只消费已经完成的参数，不执行 Shell 或访问文件系统。
/// 引擎、文件枚举和历史参数学习共用它，避免对同一输入给出互相矛盾的候选。
public struct AutocompleteArgumentContext: Sendable {
  public private(set) var command: AutocompleteCommandSpec
  public private(set) var commandPath: [String]
  public private(set) var positionalIndex = 0
  public private(set) var pendingArgument: AutocompleteArgumentSpec?
  public private(set) var pendingOptionName: String?
  public private(set) var optionsTerminated = false
  public private(set) var usedOptionNames: Set<String> = []

  public init(root: AutocompleteCommandSpec, completed: [String]) {
    command = root
    commandPath = [root.name]
    var pending: [AutocompleteArgumentSpec] = []
    for token in completed {
      if let argument = pending.first {
        if argument.isOptional,
          token == "--" || command.option(named: String(token.prefix { $0 != "=" })) != nil
        {
          pending = []
          pendingOptionName = nil
        } else {
          if !argument.isVariadic { pending.removeFirst() }
          if pending.isEmpty { pendingOptionName = nil }
          continue
        }
      }
      if !optionsTerminated, token == "--" {
        optionsTerminated = true
        continue
      }
      if !optionsTerminated, token.hasPrefix("-"), token.count > 1 {
        let name = String(token.prefix { $0 != "=" })
        if let option = command.option(named: name) {
          usedOptionNames.formUnion(option.names)
          pending = token.contains("=") ? Array(option.args.dropFirst()) : option.args
          pendingOptionName = pending.isEmpty ? nil : option.name
        }
        continue
      }
      if !optionsTerminated, positionalIndex == 0,
        let subcommand = command.subcommand(named: token)
      {
        command = subcommand
        commandPath.append(subcommand.name)
        continue
      }
      positionalIndex += 1
    }
    pendingArgument = pending.first
  }

  public var argument: AutocompleteArgumentSpec? {
    if let pendingArgument { return pendingArgument }
    guard !command.arguments.isEmpty else { return nil }
    let index = min(positionalIndex, command.arguments.count - 1)
    let value = command.arguments[index]
    return positionalIndex < command.arguments.count || value.isVariadic ? value : nil
  }

  /// 参数槽位标识，与选项顺序无关，但区分命令路径、位置参数和选项参数。
  public var argumentKey: String? {
    guard argument != nil else { return nil }
    return commandPath.joined(separator: "/") + ":"
      + (pendingOptionName ?? "position-\(min(positionalIndex, max(0, command.arguments.count - 1)))")
  }

  public enum FilesystemMode: Sendable { case none, folders, filesAndFolders }

  public var filesystemMode: FilesystemMode {
    if commandPath == ["cd"] || commandPath == ["pushd"] { return .folders }
    guard let argument else { return .none }
    return Self.filesystemMode(for: argument)
  }

  public static func filesystemMode(for argument: AutocompleteArgumentSpec) -> FilesystemMode {
    if argument.wantsFoldersOnly { return .folders }
    if argument.wantsFilesystemCandidates { return .filesAndFolders }
    // 部分 Fig 规格通过函数生成器表达路径，导入后的静态信息仍保留参数名称。
    let name = argument.name.lowercased()
    if name.contains("folder") || name.contains("directory") { return .folders }
    if name.contains("path") || name.contains("file") { return .filesAndFolders }
    return .none
  }
}

/// 只追加编码后的后缀，保留用户原先的引号/反斜杠；不展开变量或命令替换。
public enum AutocompleteShellInsertion {
  public static func token(value: String, typed: String, raw: String, closeQuote: Bool) -> String? {
    guard value.hasPrefix(typed) else { return nil }
    var quote: Character?
    var escaped = false
    for character in raw {
      if escaped { escaped = false; continue }
      if character == "\\", quote != "'" { escaped = true; continue }
      if let active = quote {
        if character == active { quote = nil }
      } else if character == "'" || character == "\"" { quote = character }
    }
    // 未完成的转义不能安全追加，也不能把复杂展开当作字面路径。
    guard !escaped else { return nil }
    let suffix = String(value.dropFirst(typed.count))
    let encoded: String
    if quote == "'" {
      encoded = suffix.replacingOccurrences(of: "'", with: "'\\''")
    } else if quote == "\"" {
      encoded = suffix.map { "\\\"$`".contains($0) ? "\\" + String($0) : String($0) }.joined()
    } else {
      let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-+@%/:=,"))
      encoded = suffix.unicodeScalars.map { safe.contains($0) ? String($0) : "\\" + String($0) }.joined()
    }
    return raw + encoded + (closeQuote ? quote.map(String.init) ?? "" : "")
  }
}

extension AutocompleteLearningDatabase {
  /// 从现有脱敏历史推导参数候选，不额外保存原始命令。按目录、命令路径和参数槽位隔离，
  /// 最多检查排名靠前的 256 条、每条 64 个 token，避免按键触发无界历史扫描。
  public func argumentCandidates(
    line: String, directory: String, sessionIdentifier: String,
    specDatabase: AutocompleteSpecDatabase
  ) -> [AutocompleteCandidate] {
    let parsed = ShellCommandTokenizer.tokenize(line)
    guard let executable = parsed.tokens.first,
      let root = specDatabase.command(named: executable),
      parsed.tokens.count > 1 || parsed.currentToken.isEmpty
    else { return [] }
    let completed = parsed.currentToken.isEmpty
      ? Array(parsed.tokens.dropFirst()) : Array(parsed.tokens.dropFirst().dropLast())
    let context = AutocompleteArgumentContext(root: root, completed: completed)
    guard let key = context.argumentKey, !parsed.currentToken.hasPrefix("-") else { return [] }
    let raw = String(line.dropFirst(parsed.currentTokenStart))
    var candidates: [String: AutocompleteCandidate] = [:]
    for entry in suggestions(prefix: "", directory: directory, sessionIdentifier: sessionIdentifier).prefix(256) {
      let tokens = ShellCommandTokenizer.tokenize(entry.command).tokens
      guard tokens.first == executable, tokens.count <= 64 else { continue }
      for index in tokens.indices.dropFirst() {
        let value = tokens[index]
        guard !value.hasPrefix("-"), value.hasPrefix(parsed.currentToken), value != parsed.currentToken else { continue }
        let source = AutocompleteArgumentContext(root: root, completed: Array(tokens[1..<index]))
        guard source.argumentKey == key,
          let insert = AutocompleteShellInsertion.token(value: value, typed: parsed.currentToken, raw: raw, closeQuote: true)
        else { continue }
        let score = AutocompleteRelevance.score(
          kind: .argument, typed: parsed.currentToken, candidate: value,
          frecency: entry.frecency, sessionBoost: entry.isSessionMatch ? 1 : 0)
        if score > (candidates[value]?.score ?? -.infinity) {
          candidates[value] = AutocompleteCandidate(
            insertText: insert, displayText: value, description: "最近使用的参数", kind: .argument,
            score: score, replacement: .currentToken(start: parsed.currentTokenStart))
        }
      }
    }
    return Array(candidates.values)
  }
}
