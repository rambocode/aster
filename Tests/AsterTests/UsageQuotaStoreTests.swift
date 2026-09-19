import Combine
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// 配额来源的汇总：Claude 走共享的账号配额服务，Codex 先问 app-server 再退回 rollout；零网络。

/// 记录 app-server 调用次数并按次返回不同结果的假客户端。
private final class FakeCodexAppServer: @unchecked Sendable {
  private let results: [(windows: [AgentUsageWindow], plan: String?)?]
  private let lock = NSLock()
  private var callCount = 0

  init(results: [(windows: [AgentUsageWindow], plan: String?)?]) {
    self.results = results
  }

  var calls: Int {
    lock.lock()
    defer { lock.unlock() }
    return callCount
  }

  func read(homeDirectory: URL, now: Date) -> (windows: [AgentUsageWindow], plan: String?)? {
    lock.lock()
    let index = callCount
    callCount += 1
    lock.unlock()
    guard !results.isEmpty else { return nil }
    return results[min(index, results.count - 1)]
  }
}

/// 记录 Codex 读取次数并按次返回不同结果的假读取器。
///
/// 读取在 detached 任务里跑，计数可能被后台线程写，所以加锁。
private final class FakeCodexReader: @unchecked Sendable {
  /// 每次调用按顺序取一项；用完后一直返回最后一项。
  private let results: [(windows: [AgentUsageWindow], updatedAt: Date, plan: String?)?]
  /// 第 n 次调用前先阻塞这么久，用来制造「旧结果后到」。
  private let delays: [TimeInterval]
  private let lock = NSLock()
  private var callCount = 0

  /// `plans` 按下标对应 `results`；多数用例不关心档位，缺省全是 nil。
  init(
    results: [(windows: [AgentUsageWindow], updatedAt: Date)?],
    plans: [String?] = [],
    delays: [TimeInterval] = []
  ) {
    self.results = results.enumerated().map { index, item in
      item.map {
        (
          windows: $0.windows, updatedAt: $0.updatedAt,
          plan: index < plans.count ? plans[index] : nil
        )
      }
    }
    self.delays = delays
  }

  var calls: Int {
    lock.lock()
    defer { lock.unlock() }
    return callCount
  }

  func read(homeDirectory: URL, now: Date) -> (
    windows: [AgentUsageWindow], updatedAt: Date, plan: String?
  )? {
    lock.lock()
    let index = callCount
    callCount += 1
    lock.unlock()
    if index < delays.count, delays[index] > 0 { Thread.sleep(forTimeInterval: delays[index]) }
    guard !results.isEmpty else { return nil }
    return results[min(index, results.count - 1)]
  }
}

/// 默认 app-server 返回 nil，测试若不关心权威来源就自然走 rollout 兜底。
/// `refreshThrottle` 默认 0：多数用例要验证「每次触发都读」，节流单独测。
@MainActor
private func quotaStoreFixture(
  claudeWindows: [AgentUsageWindow]? = nil,
  claudePlan: String? = nil,
  appServer: FakeCodexAppServer = FakeCodexAppServer(results: [nil]),
  reader: FakeCodexReader,
  cursor: @escaping UsageQuotaStore.CursorReader = { _, _ in nil },
  antigravity: @escaping UsageQuotaStore.AntigravityReader = { _ in nil },
  refreshThrottle: TimeInterval = 0
) -> (UsageQuotaStore, ClaudeAccountQuotaService) {
  let service = ClaudeAccountQuotaService(
    fetch: { _ in .failure(status: nil) }, readToken: { nil }, defaults: nil)
  if let claudeWindows { service.injectForTesting(claudeWindows, planName: claudePlan) }
  let store = UsageQuotaStore(
    claude: service,
    homeDirectory: URL(fileURLWithPath: "/tmp"),
    codexAppServer: { home, now in appServer.read(homeDirectory: home, now: now) },
    codexReader: { home, now in reader.read(homeDirectory: home, now: now) },
    // Cursor 与 Antigravity 默认注入空实现：不注入就会走生产读取器，测试会去读真实的
    // Cursor 凭据库并发起网络请求。
    cursorReader: cursor,
    antigravityReader: antigravity,
    refreshThrottle: refreshThrottle)
  return (store, service)
}

/// 轮询等待主线程上的异步状态，最多 3s。
@MainActor
private func waitForStore(_ condition: @MainActor () -> Bool) async throws {
  for _ in 0..<150 {
    if condition() { return }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(condition(), "等待超时")
}

private func window(_ kind: AgentUsageWindowKind, _ percent: Double) throws -> AgentUsageWindow {
  try #require(AgentUsageWindow(kind: kind, usedPercent: percent))
}

@Test("UsageQuotaStore: start 取被动引用并汇总 Claude + Codex，stop 后全部释放")
@MainActor
func usageQuotaStoreStartsAndStops() async throws {
  let reader = FakeCodexReader(results: [(windows: [try window(.fiveHour, 40)], updatedAt: Date())])
  let (store, service) = quotaStoreFixture(
    claudeWindows: [try window(.fiveHour, 12), try window(.weekly, 30)], reader: reader)

  #expect(store.accounts.isEmpty)
  store.start()
  // 被动引用立刻生效，轮询走慢档。
  #expect(service.currentPollInterval == ClaudeAccountQuotaService.passivePollInterval)
  // Claude 侧订阅时就回放了缓存值，不用等任何请求。
  #expect(store.accounts.map(\.id) == [UsageQuotaStore.claudeAccountID])
  // Codex 没有可订阅的本地事件，只能被动轮询；开启期间必须有一个在排队的任务。
  #expect(store.hasScheduledCodexPoll)

  try await waitForStore { store.accounts.count == 2 }
  #expect(store.accounts.map(\.id) == [UsageQuotaStore.claudeAccountID, UsageQuotaStore.codexAccountID])
  #expect(store.accounts.map(\.label) == ["Claude", "Codex"])
  #expect(store.accounts.map(\.provider) == [.claudeCode, .codex])
  #expect(store.accounts[1].windows.map(\.usedPercent) == [40])

  // 重复 start 不叠加引用、不重复读文件。
  let callsAfterStart = reader.calls
  store.start()
  #expect(reader.calls == callsAfterStart)

  store.stop()
  #expect(store.accounts.isEmpty)
  #expect(service.currentPollInterval == nil)
  #expect(!service.hasScheduledPoll)
  #expect(!store.hasScheduledCodexPoll)
  store.stop()
  #expect(service.currentPollInterval == nil)
  #expect(!store.hasScheduledCodexPoll)
}

@Test("UsageQuotaStore: 值没变不重新发布")
@MainActor
func usageQuotaStoreDeduplicatesUnchangedValues() async throws {
  let claudeWindows = [try window(.fiveHour, 12)]
  // 两次读到同样的百分比，只是 updatedAt 不同：不应该再发一次。
  let reader = FakeCodexReader(results: [
    (windows: [try window(.weekly, 55)], updatedAt: Date(timeIntervalSince1970: 1)),
    (windows: [try window(.weekly, 55)], updatedAt: Date(timeIntervalSince1970: 2)),
  ])
  let (store, service) = quotaStoreFixture(claudeWindows: claudeWindows, reader: reader)

  var publishes = 0
  let subscription = store.$accounts.dropFirst().sink { _ in publishes += 1 }
  defer { subscription.cancel() }

  store.start()
  try await waitForStore { store.accounts.count == 2 }
  let afterStart = publishes

  store.refreshLocalSources()
  try await waitForStore { reader.calls == 2 }
  try await Task.sleep(for: .milliseconds(100))
  #expect(publishes == afterStart)

  // Claude 侧同理：注入完全相同的窗口不产生新发布。
  service.injectForTesting(claudeWindows)
  try await Task.sleep(for: .milliseconds(100))
  #expect(publishes == afterStart)

  // 数值真变了才发布。
  service.injectForTesting([try window(.fiveHour, 13)])
  try await waitForStore { publishes == afterStart + 1 }
  #expect(store.accounts.first?.windows.map(\.usedPercent) == [13])
  store.stop()
}

// 起一次 app-server 要几百毫秒到几秒；浮动窗反复开关期间的触发必须直接丢弃，不能排队，
// 否则用户开合几次面板就攒出一串子进程。
@Test("UsageQuotaStore: 上一次 Codex 取数没回来时跳过本次，不排队")
@MainActor
func usageQuotaStoreSkipsWhileCodexRequestInFlight() async throws {
  let reader = FakeCodexReader(
    results: [
      (windows: [try window(.weekly, 11)], updatedAt: Date()),
      (windows: [try window(.weekly, 22)], updatedAt: Date()),
    ],
    delays: [0.4, 0])
  let (store, _) = quotaStoreFixture(reader: reader)

  store.start()
  // 等第一次真的开始读（后台任务，发起是异步的）；此时它还卡在 0.4s 的延迟里。
  try await waitForStore { reader.calls == 1 }
  // 第一次还在飞的时候连打三次：全部被 in-flight 守卫挡下。
  store.refreshLocalSources()
  store.refreshLocalSources()
  store.refreshLocalSources()
  #expect(reader.calls == 1)

  try await waitForStore { store.accounts.contains { $0.provider == .codex } }
  #expect(store.accounts.first?.windows.map(\.usedPercent) == [11])
  #expect(reader.calls == 1)

  // 回来之后再触发才会真的读第二次。
  store.refreshLocalSources()
  try await waitForStore { store.accounts.first?.windows.map(\.usedPercent) == [22] }
  #expect(reader.calls == 2)
  store.stop()
}

// app-server 反映服务端当前额度，rollout 只有本机某个会话的历史快照：实测同一时刻
// rollout 说 84%，app-server 说 100%（已限流）。必须以 app-server 为准。
@Test("UsageQuotaStore: Codex 优先用 app-server，失败才退回 rollout")
@MainActor
func usageQuotaStorePrefersAppServerOverRollout() async throws {
  let appServer = FakeCodexAppServer(results: [(windows: [try window(.weekly, 100)], plan: "Pro")])
  let reader = FakeCodexReader(
    results: [(windows: [try window(.weekly, 84)], updatedAt: Date(timeIntervalSince1970: 1))])
  let (store, _) = quotaStoreFixture(appServer: appServer, reader: reader)

  store.start()
  try await waitForStore { store.accounts.contains { $0.provider == .codex } }
  let codex = try #require(store.accounts.first { $0.provider == .codex })
  #expect(codex.windows.map(\.usedPercent) == [100])
  #expect(codex.plan == "Pro")
  // app-server 成功时连 rollout 都不读。
  #expect(reader.calls == 0)
  // 权威结果的时刻就是取数时刻，不是某个文件的 mtime。
  #expect(abs(try #require(codex.fetchedAt).timeIntervalSinceNow) < 5)
  store.stop()

  // app-server 拿不到（codex 未安装或版本太旧）：退回 rollout，并且没有档位可显示。
  let offline = FakeCodexAppServer(results: [nil])
  let (fallbackStore, _) = quotaStoreFixture(appServer: offline, reader: reader)
  fallbackStore.start()
  try await waitForStore { fallbackStore.accounts.contains { $0.provider == .codex } }
  let fallback = try #require(fallbackStore.accounts.first { $0.provider == .codex })
  #expect(fallback.windows.map(\.usedPercent) == [84])
  #expect(fallback.plan == nil)
  #expect(fallback.fetchedAt == Date(timeIntervalSince1970: 1))
  #expect(offline.calls == 1)
  fallbackStore.stop()
}

// 档位是快照 `==` 的一部分：只有档位变了也要重新发布，否则卡片上的徽标不会出现。
@Test("UsageQuotaStore: 两家的订阅档位都进快照，档位变化触发重新发布")
@MainActor
func usageQuotaStoreCarriesPlanNames() async throws {
  let appServer = FakeCodexAppServer(results: [(windows: [try window(.weekly, 100)], plan: "Pro")])
  let reader = FakeCodexReader(results: [nil])
  let (store, service) = quotaStoreFixture(
    claudeWindows: [try window(.fiveHour, 12)], claudePlan: "Max 20x", appServer: appServer,
    reader: reader)

  store.start()
  try await waitForStore { store.accounts.count == 2 }
  #expect(store.accounts.map(\.plan) == ["Max 20x", "Pro"])

  // 窗口数值不变、只有档位变：仍然要发布一次。
  var publishes = 0
  let subscription = store.$accounts.dropFirst().sink { _ in publishes += 1 }
  defer { subscription.cancel() }
  service.injectForTesting([try window(.fiveHour, 12)], planName: "Max 5x")
  try await waitForStore { store.accounts.first?.plan == "Max 5x" }
  #expect(publishes == 1)
  store.stop()
}

// rollout 里的 `plan_type` 经常是 null，但有值时也要跟着兜底结果一起进快照。
@Test("UsageQuotaStore: 走 rollout 兜底时带上 rollout 里的档位")
@MainActor
func usageQuotaStoreCarriesFallbackPlan() async throws {
  let reader = FakeCodexReader(
    results: [(windows: [try window(.weekly, 84)], updatedAt: Date(timeIntervalSince1970: 1))],
    plans: ["Plus"])
  let (store, _) = quotaStoreFixture(reader: reader)
  store.start()
  try await waitForStore { store.accounts.contains { $0.provider == .codex } }
  #expect(store.accounts.first?.plan == "Plus")
  store.stop()
}

@Test("UsageQuotaStore: 距上次成功不足节流窗口时 refreshLocalSources 跳过")
@MainActor
func usageQuotaStoreThrottlesPanelRefresh() async throws {
  let appServer = FakeCodexAppServer(results: [(windows: [try window(.weekly, 100)], plan: "Pro")])
  let reader = FakeCodexReader(results: [nil])
  // 节流窗口给足，保证测试期间一定落在窗口内。
  let (store, _) = quotaStoreFixture(
    appServer: appServer, reader: reader, refreshThrottle: UsageQuotaStore.codexRefreshThrottle)

  store.start()
  try await waitForStore { store.accounts.contains { $0.provider == .codex } }
  #expect(appServer.calls == 1)

  store.refreshLocalSources()
  store.refreshLocalSources()
  try await Task.sleep(for: .milliseconds(150))
  #expect(appServer.calls == 1)
  store.stop()
}

@Test("UsageQuotaStore: Codex 没有数据时不出现该账号；stop 后 refreshLocalSources 不再读文件")
@MainActor
func usageQuotaStoreOmitsCodexWithoutData() async throws {
  let reader = FakeCodexReader(results: [nil])
  let (store, _) = quotaStoreFixture(claudeWindows: [try window(.fiveHour, 9)], reader: reader)
  store.start()
  try await waitForStore { reader.calls == 1 }
  try await Task.sleep(for: .milliseconds(100))
  #expect(store.accounts.map(\.provider) == [.claudeCode])

  store.stop()
  store.refreshLocalSources()
  try await Task.sleep(for: .milliseconds(100))
  #expect(reader.calls == 1)
}

// MARK: - CodexAccountQuotaReader

private func codexTokenCountLine(fiveHourResetsAt: Double, weeklyResetsAt: Double, percent: Double)
  -> String
{
  #"""
  {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":400,"reasoning_output_tokens":0},"model_context_window":1000},"rate_limits":{"primary":{"used_percent":\#(percent),"window_minutes":300,"resets_at":\#(fiveHourResetsAt)},"secondary":{"used_percent":\#(percent + 1),"window_minutes":10080,"resets_at":\#(weeklyResetsAt)}}}}
  """#
}

/// 在临时 home 里造一个 rollout 文件。
private func writeRollout(home: URL, day: String, name: String, line: String) throws -> URL {
  let directory = home.appendingPathComponent(".codex/sessions/\(day)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let url = directory.appendingPathComponent(name)
  try (line + "\n").write(to: url, atomically: true, encoding: .utf8)
  return url
}

private func temporaryHome() -> URL {
  FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-usage-quota-\(UUID().uuidString)", isDirectory: true)
}

@Test("UsageQuotaReader: 按目录名倒序找最新 rollout，空日目录回退，丢掉会话窗口")
func usageQuotaReaderFindsNewestRolloutAndDropsSessionWindow() throws {
  let home = temporaryHome()
  defer { try? FileManager.default.removeItem(at: home) }
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let future = now.addingTimeInterval(3_600).timeIntervalSince1970

  // 更旧的一天：不该被选中。
  _ = try writeRollout(
    home: home, day: "2026/09/16", name: "rollout-2026-09-16T10-00-00-a.jsonl",
    line: codexTokenCountLine(fiveHourResetsAt: future, weeklyResetsAt: future, percent: 1))
  // 目标日目录里有两个文件，取名字更大（更晚）的那个。
  _ = try writeRollout(
    home: home, day: "2026/09/17", name: "rollout-2026-09-17T09-00-00-a.jsonl",
    line: codexTokenCountLine(fiveHourResetsAt: future, weeklyResetsAt: future, percent: 5))
  let newest = try writeRollout(
    home: home, day: "2026/09/17", name: "rollout-2026-09-17T21-00-00-b.jsonl",
    line: codexTokenCountLine(fiveHourResetsAt: future, weeklyResetsAt: future, percent: 33))
  // 当天目录存在但没有 rollout：必须回退到前一天。
  try FileManager.default.createDirectory(
    at: home.appendingPathComponent(".codex/sessions/2026/09/18", isDirectory: true),
    withIntermediateDirectories: true)

  let result = try #require(CodexAccountQuotaReader.latestWindows(homeDirectory: home, now: now))
  #expect(result.windows.map(\.kind) == [.fiveHour, .weekly])
  #expect(result.windows.map(\.usedPercent) == [33, 34])
  let modified = try #require(
    newest.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
  #expect(abs(result.updatedAt.timeIntervalSince(modified)) < 0.01)
}

@Test("UsageQuotaReader: 已过重置时刻的窗口按清零处理并保留说明")
func usageQuotaReaderZeroesExpiredWindows() throws {
  let home = temporaryHome()
  defer { try? FileManager.default.removeItem(at: home) }
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let past = now.addingTimeInterval(-60).timeIntervalSince1970
  let future = now.addingTimeInterval(3_600).timeIntervalSince1970
  _ = try writeRollout(
    home: home, day: "2026/09/17", name: "rollout-2026-09-17T09-00-00-a.jsonl",
    line: codexTokenCountLine(fiveHourResetsAt: past, weeklyResetsAt: future, percent: 70))

  let result = try #require(CodexAccountQuotaReader.latestWindows(homeDirectory: home, now: now))
  let fiveHour = try #require(result.windows.first { $0.kind == .fiveHour })
  #expect(fiveHour.usedPercent == 0)
  #expect(fiveHour.resetsAt == nil)
  #expect(fiveHour.detail != nil)
  // 还没到重置时刻的窗口原样保留。
  let weekly = try #require(result.windows.first { $0.kind == .weekly })
  #expect(weekly.usedPercent == 71)
  #expect(weekly.resetsAt == Date(timeIntervalSince1970: future))
}

@Test("UsageQuotaReader: 没有 sessions 目录或没有可用数据时返回 nil")
func usageQuotaReaderReturnsNilWithoutUsableData() throws {
  let home = temporaryHome()
  defer { try? FileManager.default.removeItem(at: home) }
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  #expect(CodexAccountQuotaReader.latestWindows(homeDirectory: home, now: now) == nil)

  // 只有会话上下文占比、没有账号级窗口：不算可用数据。
  let sessionOnly =
    #"{"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":400,"reasoning_output_tokens":0},"model_context_window":1000}}}"#
  _ = try writeRollout(
    home: home, day: "2026/09/17", name: "rollout-2026-09-17T09-00-00-a.jsonl", line: sessionOnly)
  #expect(CodexAccountQuotaReader.latestWindows(homeDirectory: home, now: now) == nil)
}

// 本机实测这个键存在但常常是 null（只有服务端认为需要时才填），所以两种都得处理。
@Test("UsageQuotaReader: 取 rollout 的 rate_limits.plan_type，为 null 时不显示档位")
func usageQuotaReaderReadsRolloutPlanType() throws {
  let home = temporaryHome()
  defer { try? FileManager.default.removeItem(at: home) }
  let now = Date(timeIntervalSince1970: 1_800_000_000)
  let future = now.addingTimeInterval(3_600).timeIntervalSince1970
  let withPlan =
    #"""
    {"type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":400,"reasoning_output_tokens":0},"model_context_window":1000},"rate_limits":{"limit_id":"codex","plan_type":"pro","primary":{"used_percent":84,"window_minutes":10080,"resets_at":\#(future)},"secondary":null}}}
    """#
  _ = try writeRollout(
    home: home, day: "2026/09/17", name: "rollout-2026-09-17T09-00-00-a.jsonl", line: withPlan)
  let result = try #require(CodexAccountQuotaReader.latestWindows(homeDirectory: home, now: now))
  #expect(result.windows.map(\.usedPercent) == [84])
  #expect(result.plan == "Pro")

  // plan_type 为 null：窗口照常，档位为 nil。
  let nullPlan = withPlan.replacingOccurrences(of: #""plan_type":"pro""#, with: #""plan_type":null"#)
  let other = temporaryHome()
  defer { try? FileManager.default.removeItem(at: other) }
  _ = try writeRollout(
    home: other, day: "2026/09/17", name: "rollout-2026-09-17T09-00-00-a.jsonl", line: nullPlan)
  let nullResult = try #require(
    CodexAccountQuotaReader.latestWindows(homeDirectory: other, now: now))
  #expect(nullResult.windows.map(\.usedPercent) == [84])
  #expect(nullResult.plan == nil)
}
