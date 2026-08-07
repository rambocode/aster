import Foundation

/// Frequent Folders 的持久化访问记录。`rawScore` 每次访问增加 1，展示时再按最近访问
/// 时间衰减，避免定时任务持续改写数据库。
public struct FrequentFolderEntry: Codable, Equatable, Sendable {
  public let path: String
  public let rawScore: Double
  public let lastVisitedAt: Date

  public init(path: String, rawScore: Double, lastVisitedAt: Date) {
    self.path = path
    self.rawScore = rawScore
    self.lastVisitedAt = lastVisitedAt
  }
}

/// 一次可展示的匹配结果。分数已经相对查询时刻完成时间衰减。
public struct FrequentFolderMatch: Equatable, Sendable {
  public let path: String
  public let score: Double
  public let lastVisitedAt: Date

  public init(path: String, score: Double, lastVisitedAt: Date) {
    self.path = path
    self.score = score
    self.lastVisitedAt = lastVisitedAt
  }
}

/// Otty 风格的本地目录 frecency 数据库。
///
/// 数据库不访问文件系统：OSC 7、显式 `learn`、CLI 和导入层分别决定目录是否实际存在，
/// 本类型只负责路径规范化、学习/忽略语义、时间衰减、稳定排名和容量限制。
public struct FrequentFolders: Codable, Equatable, Sendable {
  public private(set) var entries: [FrequentFolderEntry]
  public let capacity: Int
  private var ignoredPaths: Set<String>

  public init(capacity: Int = 100) {
    self.capacity = min(max(capacity, 1), 100)
    entries = []
    ignoredPaths = []
  }

  private enum CodingKeys: String, CodingKey {
    case entries
    case capacity
    case ignoredPaths
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let decodedCapacity = try container.decodeIfPresent(Int.self, forKey: .capacity) ?? 100
    let decodedEntries =
      try container.decodeIfPresent([FrequentFolderEntry].self, forKey: .entries) ?? []
    let decodedIgnored = try container.decodeIfPresent([String].self, forKey: .ignoredPaths) ?? []

    self.init(capacity: decodedCapacity)
    // 忽略列表也来自外部持久化数据，采用稳定路径序后限制数量，防止恶意配置让内存
    // 随数组无限增长。正常产品操作远达不到该上限。
    ignoredPaths = Set(
      decodedIgnored.compactMap(Self.normalizePath).sorted().prefix(10_000)
    )

    // 外部 JSON 可能包含重复、NaN/Infinity、负分或已经被忽略的路径。解码阶段合并并
    // 清理，避免异常分数破坏排序；同一路径保留总访问分和最新访问时间。
    var merged: [String: FrequentFolderEntry] = [:]
    for entry in decodedEntries {
      guard let path = Self.normalizePath(entry.path), !ignoredPaths.contains(path),
        entry.rawScore.isFinite, entry.rawScore > 0,
        entry.lastVisitedAt.timeIntervalSinceReferenceDate.isFinite
      else { continue }
      if let previous = merged[path] {
        merged[path] = FrequentFolderEntry(
          path: path,
          rawScore: min(previous.rawScore + entry.rawScore, 1_000_000_000),
          lastVisitedAt: max(previous.lastVisitedAt, entry.lastVisitedAt)
        )
      } else {
        merged[path] = FrequentFolderEntry(
          path: path,
          rawScore: min(entry.rawScore, 1_000_000_000),
          lastVisitedAt: entry.lastVisitedAt
        )
      }
    }
    entries = Array(merged.values)
    let referenceDate = entries.map(\.lastVisitedAt).max() ?? Date(timeIntervalSinceReferenceDate: 0)
    prune(now: referenceDate)
    sortEntriesForPersistence()
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(entries, forKey: .entries)
    try container.encode(capacity, forKey: .capacity)
    try container.encode(ignoredPaths.sorted(), forKey: .ignoredPaths)
  }

  /// 记录一次目录访问。忽略列表和非法路径返回 `false`，不会修改既有数据。
  @discardableResult
  public mutating func record(_ path: String, at date: Date = Date()) -> Bool {
    guard let path = Self.normalizePath(path), !ignoredPaths.contains(path),
      date.timeIntervalSinceReferenceDate.isFinite
    else { return false }

    if let index = entries.firstIndex(where: { $0.path == path }) {
      let previous = entries[index]
      entries[index] = FrequentFolderEntry(
        path: path,
        rawScore: min(previous.rawScore + 1, 1_000_000_000),
        lastVisitedAt: max(previous.lastVisitedAt, date)
      )
    } else {
      entries.append(FrequentFolderEntry(path: path, rawScore: 1, lastVisitedAt: date))
    }
    prune(now: date)
    sortEntriesForPersistence()
    return true
  }

  /// 删除当前记录，但允许后续访问重新学习。
  @discardableResult
  public mutating func remove(_ path: String) -> Bool {
    guard let path = Self.normalizePath(path) else { return false }
    let previousCount = entries.count
    entries.removeAll { $0.path == path }
    return entries.count != previousCount
  }

  /// 删除记录并加入粘性忽略列表；后续 OSC 7 自动学习不会使它复活。
  @discardableResult
  public mutating func ignore(_ path: String) -> Bool {
    guard let path = Self.normalizePath(path) else { return false }
    entries.removeAll { $0.path == path }
    return ignoredPaths.insert(path).inserted
  }

  @discardableResult
  public mutating func unignore(_ path: String) -> Bool {
    guard let path = Self.normalizePath(path) else { return false }
    return ignoredPaths.remove(path) != nil
  }

  public func isIgnored(_ path: String) -> Bool {
    guard let path = Self.normalizePath(path) else { return false }
    return ignoredPaths.contains(path)
  }

  /// 按名称匹配等级、frecency、最近访问时间和路径稳定排序。
  ///
  /// 查询为空时返回全量排名，供 Open Quickly 的 Folders 过滤器直接消费。
  public func ranked(
    matching query: String = "",
    now: Date = Date(),
    limit: Int? = nil,
    excluding excludedPath: String? = nil
  ) -> [FrequentFolderMatch] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let normalizedExcluded = excludedPath.flatMap(Self.normalizePath)
    let ranked = entries.compactMap { entry -> (Int, FrequentFolderMatch)? in
      guard entry.path != normalizedExcluded else { return nil }
      let name = URL(fileURLWithPath: entry.path).lastPathComponent.lowercased()
      let path = entry.path.lowercased()
      let matchRank: Int
      if normalizedQuery.isEmpty {
        matchRank = 0
      } else if name == normalizedQuery {
        matchRank = 0
      } else if name.hasPrefix(normalizedQuery) {
        matchRank = 1
      } else if name.contains(normalizedQuery) {
        matchRank = 2
      } else if path.contains(normalizedQuery) {
        matchRank = 3
      } else {
        return nil
      }
      return (
        matchRank,
        FrequentFolderMatch(
          path: entry.path,
          score: Self.decayedScore(for: entry, now: now),
          lastVisitedAt: entry.lastVisitedAt
        )
      )
    }
    .sorted { lhs, rhs in
      if lhs.0 != rhs.0 { return lhs.0 < rhs.0 }
      if lhs.1.score != rhs.1.score { return lhs.1.score > rhs.1.score }
      if lhs.1.lastVisitedAt != rhs.1.lastVisitedAt {
        return lhs.1.lastVisitedAt > rhs.1.lastVisitedAt
      }
      return lhs.1.path.localizedStandardCompare(rhs.1.path) == .orderedAscending
    }
    .map(\.1)

    guard let limit else { return ranked }
    return Array(ranked.prefix(max(limit, 0)))
  }

  private static func decayedScore(for entry: FrequentFolderEntry, now: Date) -> Double {
    let age = max(now.timeIntervalSince(entry.lastVisitedAt), 0)
    let weight: Double
    switch age {
    case ..<3_600: weight = 4
    case ..<86_400: weight = 2
    case ..<604_800: weight = 0.5
    default: weight = 0.25
    }
    return entry.rawScore * weight
  }

  private mutating func prune(now: Date) {
    guard entries.count > capacity else { return }
    let retainedPaths = Set(ranked(now: now, limit: capacity).map(\.path))
    entries.removeAll { !retainedPaths.contains($0.path) }
  }

  /// 数组顺序不参与排名，但持久化采用稳定路径序，保证编码往返、diff 和备份可重复。
  private mutating func sortEntriesForPersistence() {
    entries.sort { $0.path < $1.path }
  }

  private static func normalizePath(_ rawPath: String) -> String? {
    guard !rawPath.isEmpty, rawPath.utf8.count <= 4_096,
      !rawPath.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    let expanded = (rawPath as NSString).expandingTildeInPath
    guard expanded.hasPrefix("/") else { return nil }
    let normalized = URL(fileURLWithPath: expanded).standardizedFileURL.path
    return normalized.isEmpty ? nil : normalized
  }
}

public enum FrequentFolderStoreError: Error, Equatable {
  case fileTooLarge
}

/// Frequent Folders 持久化的唯一编解码入口。先检查字节数再启动 JSONDecoder，避免
/// UserDefaults 被异常数据污染时在主线程构造无界数组；领域模型随后再执行逐项清理。
public enum FrequentFolderStore {
  public static let maximumEncodedBytes = 2 * 1_024 * 1_024

  public static func decode(_ data: Data) throws -> FrequentFolders {
    guard data.count <= maximumEncodedBytes else {
      throw FrequentFolderStoreError.fileTooLarge
    }
    return try JSONDecoder().decode(FrequentFolders.self, from: data)
  }

  public static func encode(_ folders: FrequentFolders) throws -> Data {
    let data = try JSONEncoder().encode(folders)
    guard data.count <= maximumEncodedBytes else {
      throw FrequentFolderStoreError.fileTooLarge
    }
    return data
  }
}
