// Token 扫描服务的缓存命中、落盘续扫与串行化行为。数据源用假实现，不碰真实 transcript。
import AsterCore
import Foundation
import Testing
import os

@testable import Aster

/// 让测试把某个文件的解析卡在确定时刻，从而在「刚解析完第一个文件」时发出取消。
private final class ScanGate: Sendable {
  let entered = DispatchSemaphore(value: 0)
  let release = DispatchSemaphore(value: 0)
}

/// 记录解析次数的假数据源。
///
/// 锁本身是引用类型，结构体被复制后仍然共享同一个计数。
private struct CountingTokenSource: TokenUsageSource {
  let provider: AgentProvider = .claudeCode
  let files: [TokenSourceFile]
  let bucketsByPath: [String: [TokenBucket]]
  /// 命中这个路径时先停下来等测试放行。
  let gatePath: String?
  let gate: ScanGate?
  let parseCount = OSAllocatedUnfairLock(initialState: 0)

  func discoverFiles(homeDirectory: URL) -> [TokenSourceFile] { files }

  func buckets(of file: TokenSourceFile, context: TokenScanContext) -> [TokenBucket] {
    if let gate, file.path == gatePath {
      gate.entered.signal()
      gate.release.wait()
    }
    parseCount.withLock { $0 += 1 }
    return bucketsByPath[file.path] ?? []
  }

  var parses: Int { parseCount.withLock { $0 } }
}

private let utcZone = TimeZone(identifier: "UTC") ?? .gmt
private let fixtureHome = URL(fileURLWithPath: "/fixture/home")

/// 两个文件分别落在不同的（日，项目）上，合并后应当得到两个样本。
private func makeSource(
  fileCount: Int = 1, gatePath: String? = nil, gate: ScanGate? = nil
) -> CountingTokenSource {
  var files: [TokenSourceFile] = []
  var buckets: [String: [TokenBucket]] = [:]
  for index in 0..<fileCount {
    let path = "/fixture/file-\(index).jsonl"
    files.append(TokenSourceFile(path: path, size: Int64(10 + index), modified: Double(100 + index)))
    buckets[path] = [
      TokenBucket(
        day: 20_000 + index, project: "/fixture/project-\(index)",
        totals: TokenTotals(input: 5, output: 3))
    ]
  }
  return CountingTokenSource(
    files: files, bucketsByPath: buckets, gatePath: gatePath, gate: gate)
}

/// 在 GCD 线程上等信号量。async 上下文里不能直接 `wait()`，而扫描本身跑在协作线程池上，
/// 也不该让测试再占住一条协作线程。
private func awaitSignal(_ semaphore: DispatchSemaphore) async {
  await withCheckedContinuation { continuation in
    DispatchQueue.global().async {
      semaphore.wait()
      continuation.resume()
    }
  }
}

private func makeCacheURL() -> URL {
  FileManager.default.temporaryDirectory
    .appendingPathComponent("TokenStatsServiceTests-\(UUID().uuidString)", isDirectory: true)
    .appendingPathComponent(TokenStatsService.cacheFileName, isDirectory: false)
}

private func makeService(
  cacheURL: URL?, sources: [any TokenUsageSource]
) -> TokenStatsService {
  TokenStatsService(
    homeDirectory: fixtureHome, cacheURL: cacheURL, sources: sources, timeZone: utcZone)
}

@Suite("TokenStatsService 扫描服务")
struct TokenStatsServiceTests {
  @Test("第二次扫描命中缓存，不重新解析文件")
  func secondScanHitsCache() async {
    let source = makeSource()
    let service = makeService(cacheURL: makeCacheURL(), sources: [source])

    let first = await service.load(progress: { _ in })
    #expect(first.count == 1)
    #expect(source.parses == 1)

    let second = await service.load(progress: { _ in })
    #expect(second == first)
    #expect(source.parses == 1)
  }

  @Test("缓存落盘后，新建的服务不扫描也能拿到样本")
  func diskCacheRevivesSamples() async {
    let cacheURL = makeCacheURL()
    let first = makeSource()
    let scanned = await makeService(cacheURL: cacheURL, sources: [first]).load(progress: { _ in })
    #expect(scanned.count == 1)

    let second = makeSource()
    let revived = makeService(cacheURL: cacheURL, sources: [second])
    let cached = await revived.cachedSamples()
    #expect(cached == scanned)
    #expect(second.parses == 0)
  }

  @Test("取消后半成品缓存落盘，下一次只解析剩下的文件")
  func cancelledScanResumesFromCache() async {
    let cacheURL = makeCacheURL()
    let gate = ScanGate()
    let first = makeSource(fileCount: 2, gatePath: "/fixture/file-0.jsonl", gate: gate)
    let service = makeService(cacheURL: cacheURL, sources: [first])

    let task = Task { await service.load(progress: { _ in }) }
    // 卡在第一个文件里时发出取消：引擎解析完这一个就会收尾，落盘的缓存里只有它。
    await awaitSignal(gate.entered)
    task.cancel()
    gate.release.signal()
    _ = await task.value

    #expect(first.parses == 1)
    #expect(FileManager.default.fileExists(atPath: cacheURL.path))

    let second = makeSource(fileCount: 2)
    let resumed = makeService(cacheURL: cacheURL, sources: [second])
    let samples = await resumed.load(progress: { _ in })
    #expect(second.parses == 1)
    #expect(samples.count == 2)
  }

  @Test("并发发起的两次扫描共用同一次结果")
  func concurrentLoadsShareOneScan() async {
    let source = makeSource(fileCount: 2)
    let service = makeService(cacheURL: nil, sources: [source])

    async let first = service.load(progress: { _ in })
    async let second = service.load(progress: { _ in })
    let results = await (first, second)

    #expect(source.parses == 2)  // 两个文件各一次，而不是两轮扫描的四次
    #expect(results.0 == results.1)
  }

  @Test("损坏的缓存文件被忽略，不影响扫描")
  func corruptedCacheIsIgnored() async throws {
    let cacheURL = makeCacheURL()
    try FileManager.default.createDirectory(
      at: cacheURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("this is not json".utf8).write(to: cacheURL)

    let source = makeSource()
    let service = makeService(cacheURL: cacheURL, sources: [source])
    let cached = await service.cachedSamples()
    #expect(cached == nil)

    let samples = await service.load(progress: { _ in })
    #expect(samples.count == 1)
  }
}
