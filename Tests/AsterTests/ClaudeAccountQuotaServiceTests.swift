import AppKit
import Combine
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// Claude 账号配额服务（官方 /usage）的取数纪律：限流退避、全 app 共享一条请求时间线、
// 缓存跨启动回填。状态栏 AI 用量面板与终端 Pane 的引用都走这一个服务。

private final class MutableBox<Value>: @unchecked Sendable {
  var value: Value
  init(_ value: Value) { self.value = value }
}

/// 轮询等待主线程上的异步状态，最多 2s。
@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async throws {
  for _ in 0..<100 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(condition(), "等待超时")
}

/// 测试用离线账号配额服务：不读钥匙串、不发网络请求；用 `injectForTesting` 直接喂窗口。
@MainActor
func offlineClaudeQuotaService() -> ClaudeAccountQuotaService {
  ClaudeAccountQuotaService(fetch: { _ in .failure(status: nil) }, readToken: { nil }, defaults: nil)
}

// 429 不是「未登录」：token 必须保留、进入退避，退避期内的轮询不再发请求；恢复 200 后正常出数。
@Test("Claude 配额 429 保留 token 并退避，401 才丢弃 token")
@MainActor
func claudeQuotaServiceBacksOffOnRateLimitAndDropsTokenOnlyOnUnauthorized() async throws {
  let outcomes = MutableBox<[ClaudeUsageFetchOutcome]>([
    .rateLimited(retryAfter: 30),
    .success(Data(#"{"five_hour":{"utilization":18.0},"seven_day":{"utilization":11.0}}"#.utf8)),
  ])
  let fetchCount = MutableBox(0)
  let tokenReads = MutableBox(0)
  let service = ClaudeAccountQuotaService(
    fetch: { _ in
      fetchCount.value += 1
      return outcomes.value.isEmpty ? .failure(status: nil) : outcomes.value.removeFirst()
    },
    readToken: { tokenReads.value += 1; return ("token", nil) },
    defaults: nil
  )

  await service.refresh(force: true)
  #expect(fetchCount.value == 1)
  #expect(service.windows == nil)
  #expect(service.isBackingOff)
  // 退避期内强制刷新也不打接口，token 也没有被重新读取。
  await service.refresh(force: true)
  #expect(fetchCount.value == 1)
  #expect(tokenReads.value == 1)

  // 换成 401：必须真正丢 token（下一次会重新读 Keychain）。
  let unauthorized = ClaudeAccountQuotaService(
    fetch: { _ in .unauthorized }, readToken: { tokenReads.value += 1; return ("token", nil) },
    defaults: nil)
  tokenReads.value = 0
  await unauthorized.refresh(force: true)
  await unauthorized.refresh(force: true)
  #expect(tokenReads.value == 2)
  #expect(!unauthorized.isBackingOff)

  // 成功一次即清退避并出数。
  let healthy = ClaudeAccountQuotaService(
    fetch: { _ in .success(Data(#"{"five_hour":{"utilization":18.0}}"#.utf8)) }, readToken: { ("token", nil) },
    defaults: nil)
  await healthy.refresh(force: true)
  #expect(healthy.windows?.first?.usedPercent == 18)
  #expect(!healthy.isBackingOff)
}

// 全 app 共享一条请求时间线：Claude 反复启停、多个 pane 同时引用，都不会在 90s 内再打接口。
@Test("Claude 配额服务在最小间隔内重复 retain 不会重复请求")
@MainActor
func claudeQuotaServiceSharesRequestTimelineAcrossRetains() async throws {
  let fetchCount = MutableBox(0)
  let service = ClaudeAccountQuotaService(
    fetch: { _ in
      fetchCount.value += 1
      return .success(Data(#"{"five_hour":{"utilization":18.0}}"#.utf8))
    },
    readToken: { ("token", nil) }, defaults: nil)

  // 第一个 pane：从没请求过，轮询首拍立即拉。
  service.retain()
  try await waitUntil { fetchCount.value == 1 }
  // 第二个 pane 同时引用：共享结果，不新增请求。
  service.retain()
  try await Task.sleep(for: .milliseconds(100))
  #expect(fetchCount.value == 1)
  // 两个 pane 都结束再立刻启动一个新的：引用计数回到 1，轮询重启，但距上次请求不足 90s，
  // 首拍必须等待而不是立刻请求；补拉同样被拦下。
  service.release()
  service.release()
  service.retain()
  service.refreshSoon(delay: .zero)
  try await Task.sleep(for: .milliseconds(200))
  #expect(fetchCount.value == 1)
  #expect(service.windows?.first?.usedPercent == 18)
  service.release()
}

// 缓存：成功一次后写入 defaults；新实例启动即回填并带上原拉取时刻；过期缓存不回填。
@Test("Claude 配额缓存跨启动回填，超过 24h 不回填")
@MainActor
func claudeQuotaServiceRestoresRecentCacheAcrossLaunches() async throws {
  let suiteName = "AgentUsageSessionTests.cache.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let first = ClaudeAccountQuotaService(
    fetch: { _ in .success(Data(#"{"five_hour":{"utilization":33.0}}"#.utf8)) },
    readToken: { ("token", nil) }, defaults: defaults)
  await first.refresh(force: true)
  #expect(first.windows?.first?.usedPercent == 33)

  // 第二个实例即便接口一直 429，也能立刻拿到上次的数字与时刻。
  let second = ClaudeAccountQuotaService(
    fetch: { _ in .rateLimited(retryAfter: nil) }, readToken: { ("token", nil) }, defaults: defaults)
  #expect(second.windows?.first?.usedPercent == 33)
  let fetchedAt = try #require(second.fetchedAt)
  #expect(abs(fetchedAt.timeIntervalSinceNow) < 5)

  // 把缓存时间改到 25h 前：不回填。
  var stale = try #require(defaults.data(forKey: ClaudeAccountQuotaService.cacheKey))
  var object = try #require(try JSONSerialization.jsonObject(with: stale) as? [String: Any])
  object["fetchedAt"] = Date().addingTimeInterval(-25 * 3_600).timeIntervalSinceReferenceDate
  stale = try JSONSerialization.data(withJSONObject: object)
  defaults.set(stale, forKey: ClaudeAccountQuotaService.cacheKey)
  let third = ClaudeAccountQuotaService(
    fetch: { _ in .rateLimited(retryAfter: nil) }, readToken: { ("token", nil) }, defaults: defaults)
  #expect(third.windows == nil)
}
