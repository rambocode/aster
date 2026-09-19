import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// Cursor 与 Antigravity 两个来源接进 UsageQuotaStore 后的行为；零网络、零进程。

/// 记录调用次数并按次返回不同结果的假来源。
///
/// 取数在 detached 任务里跑，计数会被后台线程写，所以加锁。
private final class FakeQuotaReader: @unchecked Sendable {
  private let results: [UsageQuotaStore.QuotaReading?]
  private let lock = NSLock()
  private var callCount = 0

  init(results: [UsageQuotaStore.QuotaReading?]) {
    self.results = results
  }

  var calls: Int {
    lock.lock()
    defer { lock.unlock() }
    return callCount
  }

  func read() -> UsageQuotaStore.QuotaReading? {
    lock.lock()
    let index = callCount
    callCount += 1
    lock.unlock()
    guard !results.isEmpty else { return nil }
    return results[min(index, results.count - 1)]
  }
}

@MainActor
private func sourcesFixture(
  cursor: FakeQuotaReader, antigravity: FakeQuotaReader
) -> UsageQuotaStore {
  let service = ClaudeAccountQuotaService(
    fetch: { _ in .failure(status: nil) }, readToken: { nil }, defaults: nil)
  return UsageQuotaStore(
    claude: service,
    homeDirectory: URL(fileURLWithPath: "/tmp"),
    codexAppServer: { _, _ in nil },
    codexReader: { _, _ in nil },
    cursorReader: { _, _ in cursor.read() },
    antigravityReader: { _ in antigravity.read() },
    refreshThrottle: 0)
}

/// 轮询等待主线程上的异步状态，最多 3s。
@MainActor
private func waitForSources(_ condition: @MainActor () -> Bool) async throws {
  for _ in 0..<150 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(condition(), "等待超时")
}

private func reading(
  _ kind: AgentUsageWindowKind, _ percent: Double, plan: String?, label: String? = nil
) throws -> UsageQuotaStore.QuotaReading {
  let window = try #require(
    AgentUsageWindow(kind: kind, usedPercent: percent, label: label))
  return UsageQuotaStore.QuotaReading(windows: [window], plan: plan, fetchedAt: Date())
}

@Test("UsageQuotaSources: Cursor 与 Antigravity 的快照按 provider 顺序汇总，带档位")
@MainActor
func usageQuotaSourcesAggregatesCursorAndAntigravity() async throws {
  let cursor = FakeQuotaReader(results: [try reading(.billingCycle, 5, plan: "Pro")])
  let agy = FakeQuotaReader(
    results: [try reading(.modelWeekly, 40, plan: "Ultra", label: "Gemini 3 Pro")])
  let store = sourcesFixture(cursor: cursor, antigravity: agy)
  store.start()
  defer { store.stop() }

  try await waitForSources { store.accounts.count == 2 }
  // 顺序跟随 AgentProvider.allCases：cursorCLI 在 antigravity 之前。
  #expect(store.accounts.map(\.provider) == [.cursorCLI, .antigravity])
  #expect(store.accounts.map(\.label) == ["Cursor", "Antigravity"])
  #expect(store.accounts.map(\.plan) == ["Pro", "Ultra"])
  #expect(store.accounts.first?.windows.first?.kind == .billingCycle)
  #expect(store.accounts.last?.windows.first?.displayLabel == "Gemini 3 Pro")
}

@Test("UsageQuotaSources: 某个来源取不到就只让它那张卡片消失，不影响别家")
@MainActor
func usageQuotaSourcesDropsOnlyTheFailingAccount() async throws {
  // 第一次有值、之后一直为 nil：模拟用户关掉了 Antigravity。
  let cursor = FakeQuotaReader(results: [try reading(.billingCycle, 5, plan: "Pro")])
  let agy = FakeQuotaReader(
    results: [try reading(.modelWeekly, 40, plan: nil), nil])
  let store = sourcesFixture(cursor: cursor, antigravity: agy)
  store.start()
  defer { store.stop() }

  try await waitForSources { store.accounts.count == 2 }
  store.refreshLocalSources()
  try await waitForSources { store.accounts.count == 1 }
  #expect(store.accounts.map(\.provider) == [.cursorCLI])
}

@Test("UsageQuotaSources: 空窗口视同取不到，不留下没有进度条的空卡片")
@MainActor
func usageQuotaSourcesTreatsEmptyWindowsAsMissing() async throws {
  let empty = UsageQuotaStore.QuotaReading(windows: [], plan: "Pro", fetchedAt: Date())
  let cursor = FakeQuotaReader(results: [empty])
  let agy = FakeQuotaReader(results: [nil])
  let store = sourcesFixture(cursor: cursor, antigravity: agy)
  store.start()
  defer { store.stop() }

  try await waitForSources { cursor.calls >= 1 }
  try await Task.sleep(for: .milliseconds(60))
  #expect(store.accounts.isEmpty)
}

@Test("UsageQuotaSources: stop 之后不再取数，各来源的轮询都已取消")
@MainActor
func usageQuotaSourcesStopCancelsEveryPoll() async throws {
  let cursor = FakeQuotaReader(results: [try reading(.billingCycle, 5, plan: nil)])
  let agy = FakeQuotaReader(results: [nil])
  let store = sourcesFixture(cursor: cursor, antigravity: agy)
  store.start()
  try await waitForSources { store.accounts.count == 1 }
  #expect(store.hasScheduledCodexPoll)

  store.stop()
  #expect(!store.hasScheduledCodexPoll)
  #expect(store.accounts.isEmpty)
  let before = cursor.calls
  store.refreshLocalSources()
  try await Task.sleep(for: .milliseconds(80))
  #expect(cursor.calls == before)
}
