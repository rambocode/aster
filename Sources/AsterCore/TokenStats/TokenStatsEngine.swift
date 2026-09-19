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
    // 骨架：由「token 内核」任务实现。
    TokenScanResult(
      samples: [], cache: TokenStatsCache(zone: timeZone.identifier), cancelled: false)
  }

  /// 把缓存里所有文件的 bucket 按（日，项目，provider）合并成样本。
  public static func merge(_ cache: TokenStatsCache) -> [TokenSample] {
    // 骨架：由「token 内核」任务实现。
    []
  }
}
