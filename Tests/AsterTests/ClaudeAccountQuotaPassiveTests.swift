import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// 被动引用（状态栏 / 用量浮动窗）与 pane 引用共用同一条请求时间线：换档只改轮询周期，
// 绝不因为换档多打一次 /usage。

/// 计数用的可变盒子；测试全在主线程上跑，但闭包签名要求 Sendable。
private final class CountBox: @unchecked Sendable {
  var value = 0
}

@MainActor
private func countingQuotaService() -> (ClaudeAccountQuotaService, CountBox) {
  let count = CountBox()
  let service = ClaudeAccountQuotaService(
    fetch: { _ in
      count.value += 1
      return .success(Data(#"{"five_hour":{"utilization":18.0}}"#.utf8))
    },
    readToken: { ("token", nil) },
    defaults: nil)
  return (service, count)
}

/// 轮询等待主线程上的异步状态，最多 2s。
@MainActor
private func waitForQuota(_ condition: @MainActor () -> Bool) async throws {
  for _ in 0..<100 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(condition(), "等待超时")
}

@Test("ClaudeQuotaPassive: 只有被动引用时按 300s 轮询，全部释放后停止")
@MainActor
func claudeQuotaPassiveUsesSlowIntervalAndStops() async throws {
  let (service, count) = countingQuotaService()
  #expect(service.currentPollInterval == nil)
  #expect(!service.hasScheduledPoll)

  service.retainPassive()
  #expect(service.currentPollInterval == ClaudeAccountQuotaService.passivePollInterval)
  #expect(service.hasScheduledPoll)
  // 从没请求过：慢档的首拍同样立刻拉一次，浮动窗打开就有数。
  // 计数在 fetch 闭包里先加一，`windows` 要等回到主线程才写入；等后者，否则会抢在赋值前断言。
  try await waitForQuota { service.windows != nil }
  #expect(count.value == 1)
  #expect(service.windows?.first?.usedPercent == 18)

  // 第二个被动引用不换档，也不新增请求。
  service.retainPassive()
  #expect(service.currentPollInterval == ClaudeAccountQuotaService.passivePollInterval)
  service.releasePassive()
  #expect(service.hasScheduledPoll)

  service.releasePassive()
  #expect(service.currentPollInterval == nil)
  #expect(!service.hasScheduledPoll)
  try await Task.sleep(for: .milliseconds(150))
  #expect(count.value == 1)
}

@Test("ClaudeQuotaPassive: 叠加 pane 引用提速到 90s，pane 释放后回到 300s，换档不多打接口")
@MainActor
func claudeQuotaPassiveSwitchesTierWithoutExtraRequest() async throws {
  let (service, count) = countingQuotaService()
  service.retainPassive()
  try await waitForQuota { count.value == 1 }

  // pane 起来：提速到 90s。此时距上次请求不足 90s，重启的循环必须等待而不是立刻再拉。
  service.retain()
  #expect(service.currentPollInterval == ClaudeAccountQuotaService.pollInterval)
  try await Task.sleep(for: .milliseconds(200))
  #expect(count.value == 1)

  // pane 结束：降回慢档，同样不产生额外请求。
  service.release()
  #expect(service.currentPollInterval == ClaudeAccountQuotaService.passivePollInterval)
  #expect(service.hasScheduledPoll)
  try await Task.sleep(for: .milliseconds(200))
  #expect(count.value == 1)

  service.releasePassive()
  #expect(service.currentPollInterval == nil)
  #expect(!service.hasScheduledPoll)
  #expect(count.value == 1)
}

// refreshSoon 是「Agent 一轮刚结束」的补拉，只对 pane 引用有意义；被动引用不该触发它。
@Test("ClaudeQuotaPassive: refreshSoon 只对 pane 引用生效")
@MainActor
func claudeQuotaRefreshSoonRequiresActiveRetain() async throws {
  let (service, count) = countingQuotaService()
  // 没有任何引用：补拉直接被守卫拦下。
  service.refreshSoon(delay: .zero)
  try await Task.sleep(for: .milliseconds(150))
  #expect(count.value == 0)

  service.retainPassive()
  try await waitForQuota { count.value == 1 }
  service.refreshSoon(delay: .zero)
  try await Task.sleep(for: .milliseconds(150))
  #expect(count.value == 1)
  service.releasePassive()
}
