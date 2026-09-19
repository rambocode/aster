// 增量扫描引擎：按 (size, mtime) 跳过没变的文件，只解析新写的 transcript。
// 移植自 jettoai/tally（MIT）的 TokenStatsEngine。
import Foundation

/// 扫描缓存：`path → (provider, size, mtime, buckets)`。
///
/// 版本号或时区变化时整体作废：归因规则改了旧 bucket 就不可信；bucket 的 `day` 是本地日，
/// 换时区后同一时刻会落到另一天。
public struct TokenStatsCache: Codable, Equatable, Sendable {
  public struct Entry: Codable, Equatable, Sendable {
    public var provider: String
    public var size: Int64
    public var modified: Double
    public var buckets: [TokenBucket]

    public init(provider: String, size: Int64, modified: Double, buckets: [TokenBucket]) {
      self.provider = provider
      self.size = size
      self.modified = modified
      self.buckets = buckets
    }
  }

  /// 解析或归因规则每次变化都要加一。
  public static let currentVersion = 1

  public var version: Int
  public var zone: String
  public var files: [String: Entry]

  public init(version: Int = TokenStatsCache.currentVersion, zone: String, files: [String: Entry] = [:]) {
    self.version = version
    self.zone = zone
    self.files = files
  }

  /// 缓存是否还能用于给定时区。
  public func isCurrent(zone: String) -> Bool {
    version == Self.currentVersion && self.zone == zone
  }
}

/// 一次扫描的进度：已处理文件数 / 总文件数。
public struct TokenScanProgress: Equatable, Sendable {
  public var completed: Int
  public var total: Int

  public init(completed: Int, total: Int) {
    self.completed = completed
    self.total = total
  }
}

/// 一次扫描的产物。`cancelled` 为真时 `cache` 仍然包含已完成的部分，可以落盘续扫。
public struct TokenScanResult: Equatable, Sendable {
  public var samples: [TokenSample]
  public var cache: TokenStatsCache
  public var cancelled: Bool

  public init(samples: [TokenSample], cache: TokenStatsCache, cancelled: Bool) {
    self.samples = samples
    self.cache = cache
    self.cancelled = cancelled
  }
}

public enum TokenStatsEngine {
  /// 扫描所有数据源。在后台线程同步执行；每处理完一个文件检查一次 `isCancelled`。
  ///
  /// 新缓存是重建而不是合并：磁盘上已删除的 transcript 自动从统计里消失。
  public static func scan(
    sources: [any TokenUsageSource],
    previous: TokenStatsCache?,
    homeDirectory: URL,
    timeZone: TimeZone,
    isCancelled: () -> Bool,
    progress: (TokenScanProgress) -> Void
  ) -> TokenScanResult {
    // 版本或时区对不上就整体丢弃：归因规则变了旧 bucket 不可信，换时区后同一时刻会落到另一天。
    let known = previous.flatMap { $0.isCurrent(zone: timeZone.identifier) ? $0 : nil }

    // 先把所有数据源的文件列全再开始解析：进度条一开始就要知道分母，
    // 中途取消时也才知道哪些文件还没轮到。
    var discovered: [(file: TokenSourceFile, source: any TokenUsageSource)] = []
    for source in sources {
      for file in source.discoverFiles(homeDirectory: homeDirectory) {
        discovered.append((file, source))
      }
    }

    let context = TokenProjectResolver(timeZone: timeZone)
    var next: [String: TokenStatsCache.Entry] = [:]
    next.reserveCapacity(discovered.count)
    var cancelled = false

    for index in discovered.indices {
      let (file, source) = discovered[index]
      let providerID = source.provider.rawValue
      // 身份没变就不再打开文件。mtime 是浮点秒，比较留 1ms 容差，
      // 否则 JSON 编解码在最低位上的误差会让每个文件每次都被判定「变了」。
      if let entry = known?.files[file.path], entry.provider == providerID,
        entry.size == file.size, abs(entry.modified - file.modified) < 0.001
      {
        next[file.path] = entry
      } else {
        next[file.path] = TokenStatsCache.Entry(
          provider: providerID, size: file.size, modified: file.modified,
          buckets: source.buckets(of: file, context: context))
      }
      progress(TokenScanProgress(completed: index + 1, total: discovered.count))

      if isCancelled() {
        cancelled = true
        // 还没轮到的文件把旧条目原样带上，这份半成品缓存才有落盘续扫的价值；
        // 磁盘上已经没有的文件本来就不在 `discovered` 里，所以仍然会被丢掉。
        for remaining in discovered[(index + 1)...] {
          if let entry = known?.files[remaining.file.path] { next[remaining.file.path] = entry }
        }
        break
      }
    }

    // 新缓存是重建而不是合并：磁盘上已删除的 transcript 自动从统计里消失。
    let cache = TokenStatsCache(zone: timeZone.identifier, files: next)
    return TokenScanResult(samples: merge(cache), cache: cache, cancelled: cancelled)
  }

  /// 把缓存里所有文件的 bucket 按（日，项目，provider）合并成样本。
  public static func merge(_ cache: TokenStatsCache) -> [TokenSample] {
    struct Key: Hashable {
      let day: Int
      let project: String
      let provider: AgentProvider
    }

    var cells: [Key: TokenTotals] = [:]
    for entry in cache.files.values {
      // 认不出的 provider 直接跳过：缓存可能是更新的版本写的，降级运行时不该把它归给某个已知 provider。
      guard let provider = AgentProvider(rawValue: entry.provider) else { continue }
      for bucket in entry.buckets {
        cells[
          Key(day: bucket.day, project: bucket.project, provider: provider),
          default: TokenTotals()] += bucket.totals
      }
    }
    // 排序让同一份缓存每次都得到同样的数组（字典遍历顺序不稳定），便于比对与测试。
    return
      cells
      .map {
        TokenSample(
          day: $0.key.day, project: $0.key.project, provider: $0.key.provider, totals: $0.value)
      }
      .sorted {
        ($0.day, $0.project, $0.provider.rawValue) < ($1.day, $1.project, $1.provider.rawValue)
      }
  }
}
