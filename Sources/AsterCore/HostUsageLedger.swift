import Foundation

// 主机与机器的使用频率记录（frecency），供 Open Quickly 的 SSH 小节排序。
// 只存 ID / 目标文本、次数与最后使用时间，不含任何连接参数或秘密；持久化在
// UserDefaults 的 `aster.hosts.usage.v1`。打分规则与 `FrequentFolders` 同一套时间衰减。

/// 账本读取失败的原因。
public enum HostUsageLedgerError: Error, Equatable {
  case tooLarge
}

/// 使用记录的键：已保存主机或机器用 ID，alias 与快连目标用文本。
public enum HostUsageKey: Hashable, Sendable {
  case id(UUID)
  case target(String)

  /// 持久化用的字符串形式：`id:<UUID>` 或 `target:<文本>`。
  public var storageKey: String {
    switch self {
    case .id(let id): "id:\(id.uuidString)"
    case .target(let text): "target:\(text)"
    }
  }

  /// 从持久化字符串还原；格式不对返回 nil。
  public init?(storageKey: String) {
    if storageKey.hasPrefix("id:"), let id = UUID(uuidString: String(storageKey.dropFirst(3))) {
      self = .id(id)
    } else if storageKey.hasPrefix("target:"), storageKey.count > 7 {
      self = .target(String(storageKey.dropFirst(7)))
    } else {
      return nil
    }
  }
}

/// 一个键的使用记录。
public struct HostUsageEntry: Codable, Equatable, Sendable {
  /// 累计使用次数。
  public var count: Int
  /// 最后一次使用时间。
  public var lastUsed: Date

  public init(count: Int, lastUsed: Date) {
    self.count = count
    self.lastUsed = lastUsed
  }
}

/// 主机使用频率账本。值类型，读写 UserDefaults 由调用方显式触发。
public struct HostUsageLedger: Equatable, Sendable {
  /// UserDefaults 键。
  public static let defaultsKey = "aster.hosts.usage.v1"
  /// 文本键（alias / 快连）的保留上限；ID 键由 `prune(keepingIDs:)` 按存在性清理。
  public static let targetCapacity = 200

  public private(set) var entries: [HostUsageKey: HostUsageEntry]

  public init(entries: [HostUsageKey: HostUsageEntry] = [:]) {
    self.entries = entries
  }

  // MARK: - 记录与打分

  /// 记一次使用：次数加一，最后使用时间取较新者。
  public mutating func record(_ key: HostUsageKey, at date: Date = Date()) {
    if case .target(let text) = key, text.isEmpty { return }
    var entry = entries[key] ?? HostUsageEntry(count: 0, lastUsed: date)
    entry.count = min(entry.count + 1, 1_000_000)
    entry.lastUsed = max(entry.lastUsed, date)
    entries[key] = entry
    trimTargets(now: date)
  }

  /// frecency 分数：次数 × 最近程度权重；没有记录为 0。
  ///
  /// 权重分档与 `FrequentFolders` 相同（1 小时内 4、1 天内 2、1 周内 0.5、更早 0.25），
  /// 让「刚刚连过」的主机压过「很久以前连过很多次」的主机，又不至于一次误点就排到最前。
  public func score(for key: HostUsageKey, now: Date = Date()) -> Double {
    guard let entry = entries[key] else { return 0 }
    let age = max(now.timeIntervalSince(entry.lastUsed), 0)
    let weight: Double
    switch age {
    case ..<3_600: weight = 4
    case ..<86_400: weight = 2
    case ..<604_800: weight = 0.5
    default: weight = 0.25
    }
    return Double(entry.count) * weight
  }

  /// 按分数降序排列；同分保持输入顺序（调用方先按名称排好即可得到稳定结果）。
  public func ranked(_ keys: [HostUsageKey], now: Date = Date()) -> [HostUsageKey] {
    keys.enumerated()
      .map { (offset: $0.offset, key: $0.element, score: score(for: $0.element, now: now)) }
      .sorted { lhs, rhs in
        lhs.score != rhs.score ? lhs.score > rhs.score : lhs.offset < rhs.offset
      }
      .map(\.key)
  }

  // MARK: - 清理

  /// 删除已经不存在的主机或机器 ID；文本键不受影响。返回是否有改动。
  @discardableResult
  public mutating func prune(keepingIDs ids: Set<UUID>) -> Bool {
    let before = entries.count
    entries = entries.filter { key, _ in
      if case .id(let id) = key { return ids.contains(id) }
      return true
    }
    return entries.count != before
  }

  /// 文本键超出上限时按分数淘汰最低者：alias 与快连目标没有「是否存在」可查。
  private mutating func trimTargets(now: Date) {
    let targets = entries.keys.filter { if case .target = $0 { return true } else { return false } }
    guard targets.count > Self.targetCapacity else { return }
    let keep = Set(ranked(targets.sorted { $0.storageKey < $1.storageKey }, now: now)
      .prefix(Self.targetCapacity))
    for key in targets where !keep.contains(key) { entries.removeValue(forKey: key) }
  }

  // MARK: - 持久化

  /// 持久化数据的上限；超出视为损坏，避免异常数据在主线程构造无界字典。
  public static let maximumEncodedBytes = 512 * 1_024

  /// 从 UserDefaults 读取；键不存在返回空账本。
  ///
  /// - Throws: 数据超限或 JSON 损坏。调用方记诊断后按空账本处理即可——使用频率丢了只影响排序。
  public static func load(from defaults: UserDefaults) throws -> HostUsageLedger {
    guard let data = defaults.data(forKey: defaultsKey) else { return HostUsageLedger() }
    guard data.count <= maximumEncodedBytes else { throw HostUsageLedgerError.tooLarge }
    let raw = try JSONDecoder().decode([String: HostUsageEntry].self, from: data)
    var entries: [HostUsageKey: HostUsageEntry] = [:]
    for (storageKey, entry) in raw {
      guard let key = HostUsageKey(storageKey: storageKey), entry.count > 0,
        entry.lastUsed.timeIntervalSinceReferenceDate.isFinite
      else { continue }
      entries[key] = entry
    }
    return HostUsageLedger(entries: entries)
  }

  /// 写回 UserDefaults。
  public func save(to defaults: UserDefaults) throws {
    let raw = Dictionary(uniqueKeysWithValues: entries.map { ($0.key.storageKey, $0.value) })
    let encoder = JSONEncoder()
    encoder.outputFormatting = .sortedKeys
    defaults.set(try encoder.encode(raw), forKey: Self.defaultsKey)
  }
}
