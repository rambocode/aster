// Token 页的后台扫描服务：串行、可取消、结果带缓存。
import AsterCore
import Foundation
import os

/// 扫描并缓存各 Agent 的本地 token 用量。
///
/// 只在 Token 页可见时由页面触发，从不定时。扫描跑在 utility 优先级，逐文件检查取消。
actor TokenStatsService {
  /// 缓存文件名。文件名里的 v1 与 `TokenStatsCache.currentVersion` 对应；结构不兼容时换文件名，
  /// 旧文件留在系统缓存目录里由 macOS 自行回收。
  static let cacheFileName = "token-stats.v1.json"

  /// 全部内置数据源。顺序只影响扫描顺序，不影响结果。
  static let defaultSources: [any TokenUsageSource] = [
    ClaudeTokenSource(),
    CodexTokenSource(),
    PiTokenSource(),
    GrokTokenSource(),
    GeminiTokenSource(),
    DroidTokenSource(),
    OpenCodeTokenSource(),
    HermesTokenSource(),
  ]

  /// 默认缓存路径：`~/Library/Caches/<bundle id>/token-stats.v1.json`。
  ///
  /// 放缓存目录而不是 Application Support：这份文件完全可以从 transcript 重建，
  /// 丢了只是再冷扫一次，不该占用需要备份的空间。
  static var defaultCacheURL: URL? {
    guard let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }
    return
      base
      .appendingPathComponent(Bundle.main.bundleIdentifier ?? "io.local.aster", isDirectory: true)
      .appendingPathComponent(cacheFileName, isDirectory: false)
  }

  private let homeDirectory: URL
  private let cacheURL: URL?
  private let sources: [any TokenUsageSource]
  private let timeZone: TimeZone

  /// 上次扫描留下的缓存与样本。页面再次打开时先拿它秒出旧数，再增量刷新。
  private var cache: TokenStatsCache?
  private var samples: [TokenSample]?
  /// 磁盘缓存只在首次需要时读一次，之后内存里的那份就是权威。
  private var didReadDisk = false
  /// 正在跑的扫描。同一时刻只允许一个，第二个调用方共用它的结果。
  private var inFlight: Task<[TokenSample], Never>?
  /// 传给引擎的取消标志。调用方取消时置位，引擎在下一个文件边界收尾。
  private var cancelFlag: OSAllocatedUnfairLock<Bool>?

  init(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    cacheURL: URL? = TokenStatsService.defaultCacheURL,
    sources: [any TokenUsageSource] = TokenStatsService.defaultSources,
    timeZone: TimeZone = .current
  ) {
    self.homeDirectory = homeDirectory
    self.cacheURL = cacheURL
    self.sources = sources
    self.timeZone = timeZone
  }

  /// 不触发扫描，直接给出上次的样本；没有任何缓存时返回 nil。
  ///
  /// 页面用它在 `activate()` 的第一帧就把旧数据画出来，避免每次打开都盯着进度条。
  func cachedSamples() -> [TokenSample]? {
    if let samples { return samples }
    guard let cache = currentCache() else { return nil }
    let merged = TokenStatsEngine.merge(cache)
    samples = merged
    return merged
  }

  /// 扫描（增量）并返回全部样本。`progress` 在任意线程回调。
  /// 任务被取消时返回目前已有的样本。
  func load(progress: @escaping @Sendable (TokenScanProgress) -> Void) async -> [TokenSample] {
    // 已经有扫描在跑就共用它：页面反复 activate 不该把磁盘再翻一遍。
    if let existing = inFlight {
      let flag = cancelFlag
      return await withTaskCancellationHandler {
        await existing.value
      } onCancel: {
        flag?.withLock { $0 = true }
      }
    }

    let flag = OSAllocatedUnfairLock(initialState: false)
    cancelFlag = flag
    let previous = currentCache()
    let sources = self.sources
    let home = homeDirectory
    let zone = timeZone
    // 用 detached 而不是继承取消的结构化任务：调用方取消后引擎仍要走完收尾流程，
    // 把已经解析好的半成品缓存落盘（冷扫一次要一分多钟，关窗不能前功尽弃）。
    // 取消只通过 `flag` 传进去，优先级固定 utility——用 background 在电池供电时会被压到几乎不跑。
    let task = Task<[TokenSample], Never>.detached(priority: .utility) { [weak self] in
      let result = TokenStatsEngine.scan(
        sources: sources, previous: previous, homeDirectory: home, timeZone: zone,
        isCancelled: { flag.withLock { $0 } }, progress: progress)
      await self?.finish(result)
      return result.samples
    }
    inFlight = task
    return await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      flag.withLock { $0 = true }
    }
  }

  // MARK: - 缓存

  /// 收下一次扫描的结果并落盘。取消产生的半成品同样保存，引擎保证它可以续扫。
  private func finish(_ result: TokenScanResult) {
    cache = result.cache
    samples = result.samples
    didReadDisk = true
    persist(result.cache)
    inFlight = nil
    cancelFlag = nil
  }

  /// 当前可用的缓存：内存优先，其次读一次磁盘。
  private func currentCache() -> TokenStatsCache? {
    if let cache { return cache }
    guard !didReadDisk else { return nil }
    didReadDisk = true
    cache = readDiskCache()
    return cache
  }

  /// 读磁盘缓存。文件不存在、读坏了、版本或时区对不上都当作没有缓存，冷扫一次即可恢复。
  private func readDiskCache() -> TokenStatsCache? {
    guard let cacheURL, let data = try? Data(contentsOf: cacheURL) else { return nil }
    guard let decoded = try? JSONDecoder().decode(TokenStatsCache.self, from: data),
      decoded.isCurrent(zone: timeZone.identifier)
    else { return nil }
    return decoded
  }

  /// 原子写缓存。写失败只是下次多扫一遍，不值得打扰用户，所以这里吞掉错误。
  private func persist(_ cache: TokenStatsCache) {
    guard let cacheURL else { return }
    do {
      try FileManager.default.createDirectory(
        at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
      try JSONEncoder().encode(cache).write(to: cacheURL, options: .atomic)
    } catch {
      return
    }
  }
}
