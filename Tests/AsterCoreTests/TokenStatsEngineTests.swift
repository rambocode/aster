// 增量扫描引擎的缓存命中、删除检测与取消行为。数据源用计数假实现，不碰真实 transcript。
import Foundation
import Testing
import os

@testable import AsterCore

/// 记录 `buckets(of:context:)` 被调用次数的假数据源，用来验证缓存命中时没有重新解析。
private struct CountingTokenSource: TokenUsageSource {
  let provider: AgentProvider
  let files: [TokenSourceFile]
  let bucketsByPath: [String: [TokenBucket]]
  /// 锁本身是引用类型，结构体被复制后仍然共享同一个计数。
  let parseCount = OSAllocatedUnfairLock(initialState: 0)

  func discoverFiles(homeDirectory: URL) -> [TokenSourceFile] { files }

  func buckets(of file: TokenSourceFile, context: TokenScanContext) -> [TokenBucket] {
    parseCount.withLock { $0 += 1 }
    return bucketsByPath[file.path] ?? []
  }

  var parses: Int { parseCount.withLock { $0 } }
}

private let utcZone = TimeZone(identifier: "UTC")!
private let fixtureHome = URL(fileURLWithPath: "/fixture/home")

private func scan(
  _ sources: [any TokenUsageSource], previous: TokenStatsCache? = nil,
  isCancelled: @escaping () -> Bool = { false }
) -> TokenScanResult {
  TokenStatsEngine.scan(
    sources: sources, previous: previous, homeDirectory: fixtureHome, timeZone: utcZone,
    isCancelled: isCancelled, progress: { _ in })
}

@Suite("TokenStats 扫描引擎")
struct TokenStatsEngineTests {
  private func source(
    _ provider: AgentProvider = .claudeCode, path: String = "/fixture/a.jsonl",
    size: Int64 = 10, modified: Double = 100, day: Int = 20_000, project: String = "/fixture/p",
    totals: TokenTotals = TokenTotals(input: 5, output: 3)
  ) -> CountingTokenSource {
    CountingTokenSource(
      provider: provider,
      files: [TokenSourceFile(path: path, size: size, modified: modified)],
      bucketsByPath: [path: [TokenBucket(day: day, project: project, totals: totals)]])
  }

  @Test("身份没变的文件命中缓存，不会被重新解析")
  func unchangedFileIsNotReparsed() {
    let first = source()
    let initial = scan([first])
    #expect(first.parses == 1)
    #expect(initial.samples.count == 1)
    #expect(initial.samples.first?.totals == TokenTotals(input: 5, output: 3))

    let second = source()
    let again = scan([second], previous: initial.cache)
    #expect(second.parses == 0)
    #expect(again.samples == initial.samples)
  }

  @Test("大小或修改时间变化时重新解析；毫秒内的抖动仍然算没变")
  func changedIdentityTriggersReparse() {
    let initial = scan([source()])

    let resized = source(size: 11)
    _ = scan([resized], previous: initial.cache)
    #expect(resized.parses == 1)

    let touched = source(modified: 100.5)
    _ = scan([touched], previous: initial.cache)
    #expect(touched.parses == 1)

    // mtime 是浮点秒，JSON 往返的最低位误差不能让整个语料每次重扫。
    let jittered = source(modified: 100.000_2)
    _ = scan([jittered], previous: initial.cache)
    #expect(jittered.parses == 0)
  }

  @Test("文件从磁盘消失后，它的统计随之消失")
  func deletedFileDropsOutOfTotals() {
    let initial = scan([source()])
    #expect(!initial.samples.isEmpty)

    let emptied = CountingTokenSource(provider: .claudeCode, files: [], bucketsByPath: [:])
    let after = scan([emptied], previous: initial.cache)
    #expect(after.samples.isEmpty)
    #expect(after.cache.files.isEmpty)
  }

  @Test("缓存版本或时区不符时整体丢弃")
  func staleCacheIsDiscarded() {
    let wrongZone = TokenStatsCache(zone: "Asia/Shanghai", files: [:])
    let zoneCase = source()
    _ = scan([zoneCase], previous: wrongZone)
    #expect(zoneCase.parses == 1)

    let initial = scan([source()])
    var wrongVersion = initial.cache
    wrongVersion.version = TokenStatsCache.currentVersion + 1
    let versionCase = source()
    _ = scan([versionCase], previous: wrongVersion)
    #expect(versionCase.parses == 1)
  }

  @Test("取消后停止解析，已完成的部分与未处理文件的旧缓存都保留")
  func cancellationKeepsFinishedWork() {
    let paths = ["/fixture/a.jsonl", "/fixture/b.jsonl"]
    let complete = CountingTokenSource(
      provider: .claudeCode,
      files: paths.map { TokenSourceFile(path: $0, size: 10, modified: 100) },
      bucketsByPath: [
        paths[0]: [TokenBucket(day: 1, project: "/p", totals: TokenTotals(input: 1))],
        paths[1]: [TokenBucket(day: 2, project: "/p", totals: TokenTotals(input: 2))],
      ])
    let full = scan([complete])
    #expect(complete.parses == 2)

    // 两个文件都变了，但第一个刚解析完就取消。
    let changed = CountingTokenSource(
      provider: .claudeCode,
      files: paths.map { TokenSourceFile(path: $0, size: 11, modified: 101) },
      bucketsByPath: [
        paths[0]: [TokenBucket(day: 1, project: "/p", totals: TokenTotals(input: 9))],
        paths[1]: [TokenBucket(day: 2, project: "/p", totals: TokenTotals(input: 9))],
      ])
    let partial = scan([changed], previous: full.cache, isCancelled: { true })

    #expect(partial.cancelled)
    #expect(changed.parses == 1)
    // 新解析的第一个文件用新值，还没轮到的第二个文件沿用旧缓存，这份半成品才能落盘续扫。
    #expect(partial.cache.files[paths[0]]?.size == 11)
    #expect(partial.cache.files[paths[1]]?.size == 10)
    #expect(partial.samples.map(\.totals.input) == [9, 2])
  }

  @Test("进度按文件回调，命中缓存的文件也计入")
  func progressCountsEveryFile() {
    let paths = ["/fixture/a.jsonl", "/fixture/b.jsonl"]
    let both = CountingTokenSource(
      provider: .claudeCode,
      files: paths.map { TokenSourceFile(path: $0, size: 10, modified: 100) },
      bucketsByPath: [:])
    var reported: [TokenScanProgress] = []
    _ = TokenStatsEngine.scan(
      sources: [both], previous: nil, homeDirectory: fixtureHome, timeZone: utcZone,
      isCancelled: { false }, progress: { reported.append($0) })
    #expect(reported == [TokenScanProgress(completed: 1, total: 2), TokenScanProgress(completed: 2, total: 2)])
  }

  @Test("同一天同一项目的不同 provider 各自成样本")
  func providersMergeSeparately() {
    let claude = source(.claudeCode, path: "/fixture/a.jsonl", totals: TokenTotals(input: 1))
    let codex = source(.codex, path: "/fixture/b.jsonl", totals: TokenTotals(input: 2))
    let result = scan([claude, codex])
    #expect(result.samples.count == 2)
    #expect(result.samples.map(\.provider).sorted { $0.rawValue < $1.rawValue }
      == [AgentProvider.claudeCode, .codex])
  }
}
