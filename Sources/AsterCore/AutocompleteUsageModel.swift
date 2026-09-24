// 从学习历史推导 token 级使用频次，给规格候选（命令名、子命令、选项、参数值）加分。
import Foundation

/// token 级「用户词频」模型，借鉴输入法的两层频次：
///
/// - **全局层**（输入法的 weight）：所有目录的历史一起统计。新目录里敲 `cl` 也能先补
///   常用的 `claude`，而不是按字母序排在 `clang`、`clear` 后面——整行历史按目录隔离，
///   冷启动时一条都用不上。
/// - **目录层**（输入法的 choice，证据更强）：只统计当前目录的历史。
///
/// 两层都用 `k·ln(1 + min(n, cap))` 的对数加分并封顶，而不是硬置顶：用过一次就能在
/// 前缀相近的同类候选之间定序，但刷了几百次的值也不会压过更贴合当前输入的候选。
/// 模型只读现有脱敏历史，不另存任何原始命令。
public struct AutocompleteUsageModel: Sendable {
  /// 全局层单位加分。`ln 2 × 25 ≈ 17` 大于同前缀子命令间最常见的匹配质量差（约 8 分），
  /// 所以用过一次就能定序；封顶 `ln 21 × 25 ≈ 76`，不足以翻越来源层级。
  public static let globalWeight = 25.0
  /// 目录层单位加分，比全局层强：同一个项目里的习惯比跨项目的习惯更可信。
  public static let directoryWeight = 35.0
  /// 次数封顶，与 Glimmer 的 `CHOICE_CAP` 相同。
  public static let countCap = 20.0
  /// 次数按 30 天半衰期衰减：项目切换频繁，三个月前的习惯只保留约八分之一。
  public static let halfLifeDays = 30.0

  /// 命令名所在的槽位。
  public static let commandSlot = "@command"

  private var global: [String: [String: Double]] = [:]
  private var byDirectory: [String: [String: [String: Double]]] = [:]
  /// 所有槽位里出现过的值。补全时先查这张表，没用过的候选（例如上千个 Homebrew
  /// formula 里的绝大多数）直接跳过，不做任何解析。
  private var knownValues: Set<String> = []

  public init() {}

  /// 从学习条目构建。只在历史变化后重建一次，不在每次按键时扫描。
  public init(
    entries: [AutocompleteLearnedEntry],
    specDatabase: AutocompleteSpecDatabase,
    now: Date = Date()
  ) {
    builtAt = now
    // 规格查找是对 700 多条命令的线性扫描；同一命令名、同一条命令（不同目录）在历史里
    // 大量重复，分别按名字和命令文本缓存，5000 条历史的构建才不会拖慢按键。
    var specCache: [String: AutocompleteCommandSpec?] = [:]
    var slotCache: [String: [(slot: String, value: String)]] = [:]
    for entry in entries where entry.useCount > 0 {
      let ageDays = max(0, now.timeIntervalSince(entry.lastUsedAt)) / 86_400
      let weight = Double(min(entry.useCount, 1_000)) * pow(0.5, ageDays / Self.halfLifeDays)
      guard weight > 0.001 else { continue }
      let slots = slotCache[entry.command] ?? Self.slots(of: entry.command) { name in
        if let cached = specCache[name] { return cached }
        let found = specDatabase.command(named: name)
        specCache[name] = found
        return found
      }
      slotCache[entry.command] = slots
      for (slot, value) in slots {
        global[slot, default: [:]][value, default: 0] += weight
        knownValues.insert(value)
        byDirectory[entry.directory, default: [:]][slot, default: [:]][value, default: 0] += weight
      }
    }
  }

  /// 构建时刻。时间衰减只在构建时计算，调用方据此定期重建。
  public private(set) var builtAt = Date()

  /// 增量记入一次刚执行的命令（权重 1，不衰减）。每条命令执行后不必全量重建。
  public mutating func add(
    command: String, directory: String, specDatabase: AutocompleteSpecDatabase
  ) {
    for (slot, value) in Self.slots(of: command, specDatabase: specDatabase) {
      global[slot, default: [:]][value, default: 0] += 1
      byDirectory[directory, default: [:]][slot, default: [:]][value, default: 0] += 1
      knownValues.insert(value)
    }
  }

  /// 某个槽位上某个值的加分（分制与 `AutocompleteRelevance.score` 相同）。
  public func bonus(slot: String, value: String, directory: String) -> Double {
    let globalCount = global[slot]?[value] ?? 0
    let localCount = byDirectory[directory]?[slot]?[value] ?? 0
    return Self.globalWeight * log(1 + min(globalCount, Self.countCap))
      + Self.directoryWeight * log(1 + min(localCount, Self.countCap))
  }

  /// 命令行里每个 token 所在的槽位与归一化值。命令名用 `@command`；选项只取 `=` 前的
  /// 名字；子命令、位置参数和选项参数沿用 `AutocompleteArgumentContext` 的槽位标识，
  /// 与补全时的判定保持一致。没有规格的命令只统计命令名。
  public static func slots(
    of command: String, specDatabase: AutocompleteSpecDatabase
  ) -> [(slot: String, value: String)] {
    slots(of: command) { specDatabase.command(named: $0) }
  }

  /// 同上，调用方可传入带缓存的规格查找。
  static func slots(
    of command: String, lookup: (String) -> AutocompleteCommandSpec?
  ) -> [(slot: String, value: String)] {
    let tokens = ShellCommandTokenizer.tokenize(command).tokens
    guard let name = tokens.first, !name.isEmpty, tokens.count <= 64 else { return [] }
    var result: [(slot: String, value: String)] = [(commandSlot, name)]
    guard let root = lookup(name) else { return result }
    for index in tokens.indices.dropFirst() {
      if let slot = slot(of: tokens[index], after: Array(tokens[1..<index]), root: root) {
        result.append(slot)
      }
    }
    return result
  }

  /// 单个 token 在给定前文下的槽位。补全加分与历史统计共用它。
  public static func slot(
    of token: String, after completed: [String], root: AutocompleteCommandSpec
  ) -> (slot: String, value: String)? {
    slot(of: token, in: AutocompleteArgumentContext(root: root, completed: completed))
  }

  /// 同上，前文的规格游标由调用方提供（可复用）。
  public static func slot(
    of token: String, in context: AutocompleteArgumentContext
  ) -> (slot: String, value: String)? {
    guard !token.isEmpty else { return nil }
    let path = context.commandPath.joined(separator: "/")
    if !context.optionsTerminated, context.pendingArgument == nil,
      token.hasPrefix("-"), token.count > 1
    {
      return (path + ":option", String(token.prefix { $0 != "=" }))
    }
    if !context.optionsTerminated, context.pendingArgument == nil, context.positionalIndex == 0,
      let subcommand = context.command.subcommand(named: token)
    {
      return (path + ":subcommand", subcommand.name)
    }
    guard let key = context.argumentKey else { return nil }
    return (key, token)
  }
}

extension AutocompleteUsageModel {
  /// 已由其它机制保证顺序的来源：不参与使用频次与上下文加分。
  private static let fixedKinds: Set<AutocompleteCandidateKind> = [
    .correction, .clipboard, .followUp,
  ]

  /// 在各来源已打分的候选上叠加使用频次与上下文加分。没有任何候选的分数变化时返回
  /// nil，调用方可以沿用已排好的顺序，免去一次全量重排。
  ///
  /// - token 候选（命令名、别名、子命令、选项、参数值、动态值）按所在槽位查使用频次；
  ///   文件与目录名不按全局频次加分——相对路径跨目录没有意义，目录内的路径习惯已由
  ///   历史参数候选覆盖。
  /// - 整行候选已有 frecency，不再叠加 token 频次，只叠加上下文加分。
  /// - 上下文加分对所有候选按「接受后得到的命令行」计算，与去重键同源。
  ///
  /// 加分只改变分数，不改变候选内容与替换范围，所以 ghost 与实际插入仍保持一致。
  public static func applyingBonuses(
    _ candidates: [AutocompleteCandidate],
    line: String,
    directory: String,
    usage: AutocompleteUsageModel,
    transitions: AutocompleteTransitionTable,
    previousCommand: String?,
    specDatabase: AutocompleteSpecDatabase
  ) -> [AutocompleteCandidate]? {
    // 一次查询里候选大多共用同一个命令名；规格查找是线性扫描，按名字缓存。
    var specCache: [String: AutocompleteCommandSpec?] = [:]
    func lookup(_ name: String) -> AutocompleteCommandSpec? {
      if let cached = specCache[name] { return cached }
      let found = specDatabase.command(named: name)
      specCache[name] = found
      return found
    }
    let context = previousCommand.flatMap {
      transitions.context(after: $0, specDatabase: specDatabase)
    }
    // token 候选共用替换起点之前的文本（常见情况下只有一两个起点），前文的 token 与
    // 规格游标按起点只算一次。`brew install ` 这类槽位有上千个动态候选，逐条重新解析
    // 整行会让一次按键多花上百毫秒。
    var heads: [Int: (tokens: [String], context: AutocompleteArgumentContext?)] = [:]
    func head(at start: Int) -> (tokens: [String], context: AutocompleteArgumentContext?) {
      if let cached = heads[start] { return cached }
      let tokens = ShellCommandTokenizer.tokenize(String(line.prefix(start))).tokens
      let context = tokens.first.flatMap(lookup).map {
        AutocompleteArgumentContext(root: $0, completed: Array(tokens.dropFirst()))
      }
      heads[start] = (tokens, context)
      return (tokens, context)
    }
    var changed = false
    let adjusted = candidates.map { candidate -> AutocompleteCandidate in
      guard !fixedKinds.contains(candidate.kind) else { return candidate }
      // 快速路径：token 候选的值从没用过、且没有上下文可加分时，什么都不用算。
      if case .currentToken(let start) = candidate.replacement,
        !usage.knownValues.contains(String(candidate.insertText.drop { $0 == " " })),
        context == nil || head(at: start).tokens.count >= 2
      {
        return candidate
      }
      guard let resulting = candidate.resultingLine(from: line) else { return candidate }
      var extra = 0.0
      let tokens: [String]
      if case .currentToken(let start) = candidate.replacement, start <= resulting.count,
        case let own = ShellCommandTokenizer.tokenize(String(resulting.dropFirst(start))).tokens,
        own.count == 1, let value = own.first, !value.isEmpty
      {
        let prefix = head(at: start)
        tokens = Array((prefix.tokens + [value]).prefix(2))
        if candidate.kind != .file, candidate.kind != .folder {
          let slot: (slot: String, value: String)?
          if prefix.tokens.isEmpty {
            slot = (commandSlot, value)
          } else if let context = prefix.context {
            slot = Self.slot(of: value, in: context)
          } else {
            slot = nil
          }
          if let slot {
            extra += usage.bonus(slot: slot.slot, value: slot.value, directory: directory)
          }
        }
      } else {
        tokens = ShellCommandTokenizer.tokenize(resulting).tokens
      }
      if let context,
        let key = AutocompleteTransitionTable.intentKey(of: tokens, lookup: lookup)
      {
        extra += context.bonus(intentKey: key)
      }
      guard extra > 0 else { return candidate }
      changed = true
      return candidate.withScore(candidate.score + extra)
    }
    return changed ? adjusted : nil
  }
}

extension AutocompleteUsageModel {
  /// 命令名只接受这些字符；`./build.sh`、`clear;` 这类相对路径或带分隔符的 token
  /// 换个目录就没有意义，不作为全局候选。
  private static let commandNameCharacters = CharacterSet.alphanumerics
    .union(CharacterSet(charactersIn: "-_.+@:"))

  /// 当前槽位上用过、但规格没有提供的值（输入法的「用户词」）。
  ///
  /// - 命令位：历史里执行过、规格库里没有的命令名（如 `claude`、`codex`）。整行历史按
  ///   目录隔离，新目录里一条都用不上；这里跨目录补上命令名本身。学习库已排除退出码
  ///   127 的命令，所以不再查 PATH——从 Finder 启动的 App 的 PATH 很短，查了反而误删。
  /// - 参数位：同一命令路径、同一参数槽位上用过的值（如 `ssh` 的主机名）。要文件或
  ///   目录的槽位跳过：相对路径跨目录无效，由文件枚举和目录内历史参数负责；有活数据的
  ///   槽位（git 分支等）也跳过，以当前项目的真实数据为准。
  ///
  /// 候选只给基础分，使用频次加分统一在 `rerank` 里叠加。每个槽位最多 20 条。
  public func learnedValueCandidates(
    line: String, specDatabase: AutocompleteSpecDatabase
  ) -> [AutocompleteCandidate] {
    let parsed = ShellCommandTokenizer.tokenize(line)
    let current = parsed.currentToken
    let raw = String(line.dropFirst(parsed.currentTokenStart))
    let slot: String
    let kind: AutocompleteCandidateKind
    let description: String
    if parsed.tokens.count <= 1, !line.contains(where: \.isWhitespace) {
      guard !current.isEmpty else { return [] }
      slot = Self.commandSlot
      kind = .command
      description = L("最近使用的命令")
    } else {
      guard let name = parsed.tokens.first, let root = specDatabase.command(named: name),
        !current.hasPrefix("-")
      else { return [] }
      let completed = current.isEmpty
        ? Array(parsed.tokens.dropFirst()) : Array(parsed.tokens.dropFirst().dropLast())
      let context = AutocompleteArgumentContext(root: root, completed: completed)
      // 有活数据的槽位（分支、npm script、formula…）以当前项目的真实数据为准：
      // 别的仓库用过的分支名放到这里只会是错的。
      guard context.filesystemMode == .none, let key = context.argumentKey,
        let argument = context.argument,
        AutocompleteDynamicSource.sources(for: argument, commandPath: context.commandPath).isEmpty
      else { return [] }
      slot = key
      kind = .argument
      description = L("最近使用的参数")
    }
    guard let values = global[slot] else { return [] }
    return values
      .filter { value, _ in
        value.hasPrefix(current) && value != current && value.utf8.count <= 256
          && (kind != .command
            || specDatabase.command(named: value) == nil
              && value.unicodeScalars.allSatisfy { Self.commandNameCharacters.contains($0) })
      }
      .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
      .prefix(20)
      .compactMap { value, _ in
        guard let insert = AutocompleteShellInsertion.token(
          value: value, typed: current, raw: raw, closeQuote: true)
        else { return nil }
        return AutocompleteCandidate(
          insertText: insert, displayText: value, description: description, kind: kind,
          score: AutocompleteRelevance.score(kind: kind, typed: current, candidate: value),
          replacement: .currentToken(start: parsed.currentTokenStart))
      }
  }
}
