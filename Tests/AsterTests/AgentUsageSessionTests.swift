import AppKit
import Combine
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// Agent 用量条的数据链路：Claude 走账号配额服务（官方 /usage），Codex 走 rollout 文件监听；都发布到 TerminalSession.agentUsage。

@Test("用量变化不触发 TerminalTabItem 的 objectWillChange")
@MainActor
func usageChangesDoNotTriggerTabObjectWillChange() async throws {
  let (suiteName, defaults) = try agentUsageDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  let service = offlineClaudeQuotaService()
  session.claudeAccountQuota = service
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  defer {
    for runtime in tab.runtimes.values { runtime.terminalSession?.stop(immediately: true) }
  }
  terminalView.onAgentTerminalDirective?(AgentTerminalDirective(provider: .claudeCode, signal: .idle))
  #expect(session.activeAgentProvider == .claudeCode)

  var tabChanges = 0
  let subscription = tab.objectWillChange.sink { _ in tabChanges += 1 }
  defer { subscription.cancel() }
  service.injectForTesting(try #require(ClaudeAccountQuotaParser.windows(
    fromUsageResponse: Data(#"{"five_hour":{"utilization":10}}"#.utf8))))
  service.injectForTesting(try #require(ClaudeAccountQuotaParser.windows(
    fromUsageResponse: Data(#"{"five_hour":{"utilization":11}}"#.utf8))))
  try await waitUntil { session.agentUsage?.window(.fiveHour)?.usedPercent == 11 }
  #expect(tabChanges == 0)
}

@Test("Codex 绑定 session 后读取 rollout 尾部，追加时更新，provider 结束后停止")
@MainActor
func codexMonitorReadsRolloutTailAfterAppend() async throws {
  let (suiteName, defaults) = try agentUsageDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-usage-home-\(UUID().uuidString)", isDirectory: true)
  let day = home.appendingPathComponent(".codex/sessions/2026/09/06", isDirectory: true)
  try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: home) }
  let sessionID = "01a04237-0000-4000-8000-000000000001"
  let rollout = day.appendingPathComponent("rollout-2026-09-06T10-00-00-\(sessionID).jsonl")
  try #"{"type":"session_meta","payload":{"id":"\#(sessionID)"}}"#.appending("\n")
    .write(to: rollout, atomically: true, encoding: .utf8)

  let session = TerminalSession(workingDirectory: "/tmp")
  session.claudeAccountQuota = offlineClaudeQuotaService()
  session.agentUsageHomeDirectory = home
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  defer { session.stop(immediately: true) }
  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .idle, sessionID: sessionID))
  #expect(session.activeAgentSessionID == sessionID)

  let line = #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":400,"reasoning_output_tokens":0},"model_context_window":1000},"rate_limits":{"primary":{"used_percent":52,"window_minutes":10080,"resets_at":1788748005},"secondary":null}}}"#
  // 等定位任务先跑完（目录枚举在后台），再追加，验证监听而不是首读。
  try await Task.sleep(for: .milliseconds(400))
  let handle = try FileHandle(forWritingTo: rollout)
  try handle.seekToEnd()
  try handle.write(contentsOf: Data((line + "\n").utf8))
  try handle.close()

  var observed: AgentUsageSnapshot?
  for _ in 0..<40 where observed == nil {
    try await Task.sleep(for: .milliseconds(100))
    observed = session.agentUsage
  }
  let snapshot = try #require(observed)
  #expect(snapshot.provider == .codex)
  #expect(snapshot.window(.weekly)?.usedPercent == 52)
  #expect(snapshot.window(.session)?.usedPercent == 40)
  #expect(snapshot.window(.fiveHour) == nil)

  terminalView.onShellIntegrationEvent?(.commandFinished(exitStatus: 0))
  #expect(session.agentUsage == nil)
  let monitor = Mirror(reflecting: session).children.first { $0.label == "codexUsageMonitor" }?.value
  #expect(monitor.map { Mirror(reflecting: $0).displayStyle == .optional && String(describing: $0) == "nil" } ?? true)
}

private func agentUsageDefaults() throws -> (String, UserDefaults) {
  let suiteName = "AgentUsageSessionTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  return (suiteName, defaults)
}


@Test("Claude 5h / 周取自账号配额服务并实时刷新；Claude 结束后释放服务并清空")
@MainActor
func sessionMergesClaudeAccountQuotaWithSessionWindow() async throws {
  let (suiteName, defaults) = try agentUsageDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  let responses = MutableBox([
    #"{"five_hour":{"utilization":18.0},"seven_day":{"utilization":11.0}}"#,
    #"{"five_hour":{"utilization":21.0},"seven_day":{"utilization":12.0}}"#,
  ])
  let fetchCount = MutableBox(0)
  let service = ClaudeAccountQuotaService(
    fetch: { _ in
      fetchCount.value += 1
      let text = responses.value.first ?? ""
      if responses.value.count > 1 { responses.value.removeFirst() }
      return .success(Data(text.utf8))
    },
    readToken: { "token" },
    defaults: nil
  )
  let session = TerminalSession(workingDirectory: "/tmp")
  session.claudeAccountQuota = service
  let terminalView = try #require(session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }

  // lifecycle hook 认出 Claude 后服务开始轮询，首轮结果直接成为快照。
  #expect(session.agentUsage == nil)
  terminalView.onAgentTerminalDirective?(AgentTerminalDirective(provider: .claudeCode, signal: .idle))
  try await waitUntil { fetchCount.value >= 1 && session.agentUsage?.window(.fiveHour)?.usedPercent == 18 }
  #expect(session.agentUsage?.windows.map(\.usedPercent) == [18, 11])

  // 一轮结束（processing → idle）触发补拉；测试里把最小间隔绕开：直接强制刷新。
  await service.refresh(force: true)
  #expect(fetchCount.value == 2)
  try await waitUntil { session.agentUsage?.window(.fiveHour)?.usedPercent == 21 }
  #expect(session.agentUsage?.windows.map(\.usedPercent) == [21, 12])

  // Claude 结束：释放服务，条消失。
  terminalView.onShellIntegrationEvent?(.commandFinished(exitStatus: 0))
  #expect(session.agentUsage == nil)
}

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
    readToken: { tokenReads.value += 1; return "token" },
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
    fetch: { _ in .unauthorized }, readToken: { tokenReads.value += 1; return "token" },
    defaults: nil)
  tokenReads.value = 0
  await unauthorized.refresh(force: true)
  await unauthorized.refresh(force: true)
  #expect(tokenReads.value == 2)
  #expect(!unauthorized.isBackingOff)

  // 成功一次即清退避并出数。
  let healthy = ClaudeAccountQuotaService(
    fetch: { _ in .success(Data(#"{"five_hour":{"utilization":18.0}}"#.utf8)) }, readToken: { "token" },
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
    readToken: { "token" }, defaults: nil)

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
    readToken: { "token" }, defaults: defaults)
  await first.refresh(force: true)
  #expect(first.windows?.first?.usedPercent == 33)

  // 第二个实例即便接口一直 429，也能立刻拿到上次的数字与时刻。
  let second = ClaudeAccountQuotaService(
    fetch: { _ in .rateLimited(retryAfter: nil) }, readToken: { "token" }, defaults: defaults)
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
    fetch: { _ in .rateLimited(retryAfter: nil) }, readToken: { "token" }, defaults: defaults)
  #expect(third.windows == nil)
}
