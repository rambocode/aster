// 命令间的「上一条 → 下一条」转移统计，给补全提供上下文（输入法的个人二元模型）。
import Foundation

/// 记录同一会话里相邻两条成功命令的「意图键」转移，例如 `git add` 之后常跑
/// `git commit`，`git commit` 之后常跑 `git push`。
///
/// 意图键只取命令名加第一层子命令（`git commit`、`npm run`、`ls`），不含参数与路径，
/// 既能跨目录复用，也不保存敏感值。
///
/// 算法借鉴输入法的个人 n-gram：
/// - 条件概率用绝对折扣 `max(c(a,b) − D, 0) / c(a)`，只出现一次的巧合不会产生加分；
/// - 置信度 `c(a) / (c(a) + K)` 随前一条命令的样本量平滑增长；
/// - 条目超过容量时所有计数整体减半并丢掉过小的项，而不是按时间逐条淘汰。
public struct AutocompleteTransitionTable: Codable, Equatable, Sendable {
  /// 绝对折扣。每次转移计 1 份，折扣 0.5 使第二次重复才开始明显生效。
  public static let discount = 0.5
  /// 置信度平滑常数：前一条命令出现 4 次时置信度为 0.5。
  public static let confidenceK = 4.0
  /// 加分满额（分制与 `AutocompleteRelevance.score` 相同）。约等于一条中等热度历史的
  /// frecency 加成，足以在同类候选之间定序，不足以压过更贴合输入的候选。
  public static let maximumBonus = 160.0
  public static let capacity = 2_000

  public private(set) var counts: [String: [String: Double]] = [:]

  public init() {}

  /// 记录一次 `previous → next` 转移。两条命令的意图键相同（如连续 `ls`）也会记录。
  public mutating func record(
    previous: String, next: String, specDatabase: AutocompleteSpecDatabase
  ) {
    guard let from = Self.intentKey(of: previous, specDatabase: specDatabase),
      let to = Self.intentKey(of: next, specDatabase: specDatabase)
    else { return }
    counts[from, default: [:]][to, default: 0] += 1
    if counts.values.reduce(0, { $0 + $1.count }) > Self.capacity { halve() }
  }

  /// 在上一条命令之后，接受这个候选得到的命令行能获得多少上下文加分。
  ///
  /// 候选只打完了命令名（例如 `git`）时，把所有以它开头的意图键概率加总：
  /// 上一条是 `git add` 时，`git` 本身也应该靠前。
  public func bonus(
    previous: String, candidateLine: String, specDatabase: AutocompleteSpecDatabase
  ) -> Double {
    guard let context = context(after: previous, specDatabase: specDatabase),
      let to = Self.intentKey(of: candidateLine, specDatabase: specDatabase)
    else { return 0 }
    return context.bonus(intentKey: to)
  }

  /// 取出上一条命令对应的转移行。一次查询只算一次，供所有候选复用。
  public func context(
    after previous: String, specDatabase: AutocompleteSpecDatabase
  ) -> Context? {
    guard let from = Self.intentKey(of: previous, specDatabase: specDatabase),
      let row = counts[from], !row.isEmpty
    else { return nil }
    return Context(row: row)
  }

  /// 某条前文命令之后的转移分布。
  public struct Context: Sendable {
    let row: [String: Double]

    /// 候选意图键的上下文加分：折扣后的条件概率 × 置信度 × 满额。
    public func bonus(intentKey to: String) -> Double {
      let total = row.values.reduce(0, +)
      let matched = row.filter { $0.key == to || $0.key.hasPrefix(to + " ") }.values
        .reduce(0) { $0 + max($1 - AutocompleteTransitionTable.discount, 0) }
      guard matched > 0, total > 0 else { return 0 }
      let probability = min(matched / total, 1)
      let confidence = total / (total + AutocompleteTransitionTable.confidenceK)
      return AutocompleteTransitionTable.maximumBonus * probability * confidence
    }
  }

  /// 意图键：命令名加第一层子命令；命令没有规格或第二个 token 不是子命令时只取命令名。
  public static func intentKey(of command: String, specDatabase: AutocompleteSpecDatabase) -> String? {
    intentKey(of: ShellCommandTokenizer.tokenize(command).tokens) { specDatabase.command(named: $0) }
  }

  /// 同上，调用方可传入带缓存的规格查找。
  static func intentKey(
    of tokens: [String], lookup: (String) -> AutocompleteCommandSpec?
  ) -> String? {
    guard let name = tokens.first, !name.isEmpty, name.utf8.count <= 256 else { return nil }
    guard tokens.count >= 2, let root = lookup(name), let subcommand = root.subcommand(named: tokens[1])
    else { return name }
    return name + " " + subcommand.name
  }

  /// 超出容量时整体减半，计数低于 0.5 的项直接删除。
  private mutating func halve() {
    counts = counts.compactMapValues { row in
      let kept = row.compactMapValues { $0 / 2 >= 0.5 ? $0 / 2 : nil }
      return kept.isEmpty ? nil : kept
    }
  }

  /// 校验反序列化数据，拒绝超量或非法计数，避免损坏文件拖慢补全。
  public func validated() -> AutocompleteTransitionTable? {
    guard counts.count <= Self.capacity,
      counts.values.reduce(0, { $0 + $1.count }) <= Self.capacity,
      counts.values.allSatisfy({ $0.values.allSatisfy { $0.isFinite && $0 > 0 && $0 < 1e9 } })
    else { return nil }
    return self
  }
}
