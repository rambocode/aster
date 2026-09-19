import AsterCore
import Combine
import Foundation

/// `/usage` 一次请求的结果；服务据此决定丢 token、退避还是解析。
enum ClaudeUsageFetchOutcome: Equatable, Sendable {
  case success(Data)
  case unauthorized
  case rateLimited(retryAfter: TimeInterval?)
  case failure(status: Int?)
}

/// Claude 账号级配额（5 小时 / 每周）的唯一数据源：用 Claude Code 自己维护的 OAuth token
/// 直接调官方 `/api/oauth/usage`，与 Claude 的 `/usage` 面板同源同值。
///
/// 为什么不用 statusLine：它的百分比来自上一次 API 响应头，只在本 pane 的 Claude 收到响应
/// 时刷新，多 pane 或其它设备用掉的额度看不到，且精度只有两位小数，常与 `/usage` 差 1%。
///
/// 整个 app 只有一个实例（`shared`），所有 Claude pane 共用同一份结果与同一条请求时间线：
/// 无论多少个 pane、Agent 启停多少次，对 `/usage` 的请求之间至少间隔 `minimumRequestInterval`。
/// 生命周期由 pane 引用计数驱动：有 Claude pane 时按 `pollInterval` 轮询，Agent 每轮结束再
/// 补拉一次；没有 Claude pane 时不发任何请求。token 只在内存里缓存到过期，不落盘。
@MainActor
final class ClaudeAccountQuotaService: ObservableObject {
  static let shared = ClaudeAccountQuotaService()
  /// 实测 `/usage` 的限流很紧：请求间隔 60s 仍会 429，≥90s 才稳定放行，且一旦被限流要
  /// 静默数分钟才恢复。之前 429 的真正来源不是轮询本身，而是每次 Claude 进程数从 0 变 1
  /// 都无视间隔强制拉一次：多个 pane 反复启停就把接口打爆。现在全 app 共享一条请求
  /// 时间线，任何来源（轮询首拍、轮询、回复结束补拉）都遵守同一个 90s 最小间隔。
  static let minimumRequestInterval: TimeInterval = 90
  /// 轮询周期与最小间隔一致：补拉发生后轮询会顺延到距上次请求满 90s，不会叠加请求。
  static let pollInterval: Duration = .seconds(90)
  /// 只有被动引用（状态栏 / 用量浮动窗，没有任何 Claude pane 在跑）时的轮询周期。
  /// 放宽到 300s：没人在用 Claude 的时候配额几乎不变，没必要按 pane 的节奏打接口。
  static let passivePollInterval: Duration = .seconds(300)
  nonisolated static let keychainService = "Claude Code-credentials"

  typealias Fetcher = @Sendable (_ token: String) async -> ClaudeUsageFetchOutcome
  /// 凭据读取一次同时给出 token 与订阅档位：两者在同一份 JSON 里，分两次读等于多敲一次钥匙串。
  typealias TokenReader = @Sendable () async -> (token: String, planName: String?)?
  /// 限流 / 服务端错误后的退避上限；每次失败翻倍，成功一次即归零。
  nonisolated static let maximumBackoff: TimeInterval = 600

  /// 最近一次成功拉取的窗口；nil 表示还没拿到过（无 token、离线、API key 登录）。
  /// 启动时先从本地缓存回填，所以接口被限流期间用量条仍能立刻显示上次的数值。
  @Published private(set) var windows: [AgentUsageWindow]?
  /// `windows` 对应的拉取时刻；缓存回填时是上次成功的时间，用量条据此标注数据新旧。
  private(set) var fetchedAt: Date?
  /// 订阅档位展示名（`Max 20x` / `Pro`）。来自凭据 JSON，只在真正重读钥匙串时更新。
  private(set) var planName: String?
  static let cacheKey = "aster.claude-quota.cache.v1"
  /// 缓存超过这个时长就不回填：周配额一天内变化有限，隔天的数字只会误导。
  static let cacheMaximumAge: TimeInterval = 24 * 3_600

  /// 本地缓存的载荷：窗口 + 拉取时刻 + 订阅档位。
  /// `planName` 可选，旧版本写的缓存缺这个键也能解码。
  private struct Cache: Codable {
    let windows: [AgentUsageWindow]
    let fetchedAt: Date
    var planName: String?
  }

  private let fetch: Fetcher
  private let readToken: TokenReader
  private let defaults: UserDefaults?
  private var retainCount = 0
  /// 被动引用数：状态栏与用量浮动窗持有，只要求「有数就行」，不要求 pane 级别的新鲜度。
  private var passiveRetainCount = 0
  /// 当前轮询循环使用的周期；nil 表示没有轮询。测试 seam，同时用于判断档位是否变化。
  private(set) var currentPollInterval: Duration?
  private var pollTask: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var lastFetchAt: Date?
  private var cachedToken: String?
  /// 退避截止时间：在此之前任何 refresh（包括定时轮询）都直接跳过，避免把 429 越打越多。
  private var backoffUntil: Date?
  private var consecutiveFailures = 0

  /// `defaults` 为 nil 时不读写缓存（测试用）。
  init(
    fetch: @escaping Fetcher = ClaudeAccountQuotaService.fetchUsage,
    readToken: @escaping TokenReader = ClaudeAccountQuotaService.readKeychainToken,
    defaults: UserDefaults? = .standard
  ) {
    self.fetch = fetch
    self.readToken = readToken
    self.defaults = defaults
    restoreCache()
  }

  /// 启动回填：只接受 24h 内的缓存。
  private func restoreCache() {
    guard let defaults, let data = defaults.data(forKey: Self.cacheKey),
      let cache = try? JSONDecoder().decode(Cache.self, from: data),
      Date().timeIntervalSince(cache.fetchedAt) < Self.cacheMaximumAge, !cache.windows.isEmpty
    else { return }
    windows = cache.windows
    fetchedAt = cache.fetchedAt
    // 档位一起回填：否则重启后要等第一次读钥匙串才显示，卡片上的徽标会闪一下才出现。
    planName = cache.planName
    // 快速重启也算在同一条请求时间线里：上次成功不到 90s 就不要再立刻打一次接口。
    lastFetchAt = cache.fetchedAt
  }

  private func persistCache() {
    guard let defaults, let windows, let fetchedAt,
      let data = try? JSONEncoder().encode(
        Cache(windows: windows, fetchedAt: fetchedAt, planName: planName))
    else { return }
    defaults.set(data, forKey: Self.cacheKey)
  }

  /// pane 的 Claude 开始运行：第一个引用启动轮询。轮询每一拍（含首拍）都先等到距上次
  /// 请求满 `minimumRequestInterval` 再拉，所以 Claude 刚退出又启动、或另一个 pane 接着
  /// 启动，都不会额外产生请求；已有数据时用量条直接显示共享的上次结果。
  func retain() {
    retainCount += 1
    updatePolling()
  }

  /// 状态栏 / 用量浮动窗的被动引用：没有任何 Claude pane 时按 `passivePollInterval` 慢速轮询。
  /// 与 `retain()` 共用同一条请求时间线和同一个轮询循环，不会新增第二个请求源。
  func retainPassive() {
    passiveRetainCount += 1
    updatePolling()
  }

  /// 释放被动引用。
  func releasePassive() {
    passiveRetainCount = max(passiveRetainCount - 1, 0)
    updatePolling()
  }

  /// 当前应使用的轮询周期：有 pane 引用按 90s，只有被动引用按 300s，都没有则不轮询。
  private var desiredPollInterval: Duration? {
    if retainCount > 0 { return Self.pollInterval }
    if passiveRetainCount > 0 { return Self.passivePollInterval }
    return nil
  }

  /// 按引用情况启动 / 换档 / 停止轮询循环。
  ///
  /// 换档必须重启循环，否则在途的 `Task.sleep` 还按旧周期跑，pane 起来后要等到下一拍才提速。
  /// 重启不会多打一次接口：新循环的首拍同样先等 `secondsUntilNextRequestAllowed()`，而
  /// `refresh(force:)` 在任何 await 之前就同步写下 `lastFetchAt`，所以即使新旧循环短暂重叠，
  /// 后进来的那次也会被最小间隔挡掉。
  private func updatePolling() {
    let desired = desiredPollInterval
    guard desired != currentPollInterval else { return }
    currentPollInterval = desired
    pollTask?.cancel()
    pollTask = nil
    // 没有任何引用了：连补拉也一并取消，彻底回到零请求。
    guard let desired else {
      refreshTask?.cancel()
      refreshTask = nil
      return
    }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        // 等待时长按上次请求时刻推算：补拉刚发生过就多等一会儿，从没请求过则立即拉。
        let wait = self?.secondsUntilNextRequestAllowed() ?? 0
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
        guard !Task.isCancelled else { return }
        await self?.refresh(force: false)
        try? await Task.sleep(for: desired)
      }
    }
  }

  /// 诊断 / 测试 seam：当前是否有轮询循环在跑。
  var hasScheduledPoll: Bool { pollTask != nil }

  /// 距下一次允许请求还差多少秒；0 表示现在就可以。
  private func secondsUntilNextRequestAllowed() -> TimeInterval {
    guard let lastFetchAt else { return 0 }
    return max(0, Self.minimumRequestInterval - Date().timeIntervalSince(lastFetchAt))
  }

  /// 最后一个 Claude pane 结束：降档或停止轮询，保留最后数据供下次立刻显示。
  func release() {
    retainCount = max(retainCount - 1, 0)
    // 没有 pane 在跑就没有「一轮刚结束」可言，待发的补拉一律取消；轮询的去留交给换档逻辑。
    if retainCount == 0 {
      refreshTask?.cancel()
      refreshTask = nil
    }
    updatePolling()
  }

  /// Agent 一轮结束后补拉：稍等让服务端记账，且遵守最小间隔。
  func refreshSoon(delay: Duration = .seconds(2)) {
    guard retainCount > 0, refreshTask == nil else { return }
    refreshTask = Task { [weak self] in
      try? await Task.sleep(for: delay)
      guard !Task.isCancelled else { return }
      await self?.refresh(force: false)
      self?.refreshTask = nil
    }
  }

  /// 拉一次。`force` 只绕过最小间隔（仅测试使用），生产路径一律 `false`，由共享的
  /// `lastFetchAt` 保证全 app 的请求间隔；退避期任何来源都不发请求。
  /// 只有 401 才丢弃 token（重新读 Keychain）；429 与其它服务端错误保留 token 并
  /// 按 `Retry-After` / 指数退避暂停，否则一次限流会被当成「未登录」而永远不显示用量条。
  /// 每个失败分支都写诊断（不含 token），让「条为什么没出来」能在日志里看到。
  func refresh(force: Bool) async {
    let now = Date()
    if let backoffUntil, now < backoffUntil { return }
    if !force, let lastFetchAt, now.timeIntervalSince(lastFetchAt) < Self.minimumRequestInterval {
      return
    }
    lastFetchAt = now
    if cachedToken == nil {
      let credentials = await readToken()
      cachedToken = credentials?.token
      // 档位只在真正重读凭据时更新：token 命中内存缓存就没有新的 JSON 可读，沿用上次的值。
      if let plan = credentials?.planName { planName = plan }
    }
    guard let token = cachedToken else {
      DiagnosticsCenter.shared.record(
        "claude_quota.token_unavailable", level: .warning, category: .integration)
      return
    }
    switch await fetch(token) {
    case .success(let data):
      guard let parsed = ClaudeAccountQuotaParser.windows(fromUsageResponse: data) else {
        DiagnosticsCenter.shared.record(
          "claude_quota.parse_failed", level: .warning, category: .integration,
          attributes: ["bytes": "\(data.count)"])
        return
      }
      backoffUntil = nil
      consecutiveFailures = 0
      fetchedAt = now
      if parsed != windows { windows = parsed }
      persistCache()
    case .unauthorized:
      cachedToken = nil
      DiagnosticsCenter.shared.record(
        "claude_quota.unauthorized", level: .warning, category: .integration)
    case .rateLimited(let retryAfter):
      let delay = retryAfter ?? nextBackoff()
      backoffUntil = now.addingTimeInterval(delay)
      DiagnosticsCenter.shared.record(
        "claude_quota.rate_limited", level: .warning, category: .integration,
        attributes: ["retry_after_seconds": "\(Int(delay))"])
    case .failure(let status):
      let delay = nextBackoff()
      backoffUntil = now.addingTimeInterval(delay)
      DiagnosticsCenter.shared.record(
        "claude_quota.fetch_failed", level: .warning, category: .integration,
        attributes: ["status": status.map(String.init) ?? "network", "retry_after_seconds": "\(Int(delay))"])
    }
  }

  /// 指数退避：120s、240s、480s … 封顶 `maximumBackoff`。起点取 120s 是因为被限流后
  /// 60s 内再试几乎必然还是 429，只会把惩罚窗口拖长。
  private func nextBackoff() -> TimeInterval {
    consecutiveFailures += 1
    return min(Self.maximumBackoff, 120 * pow(2, Double(consecutiveFailures - 1)))
  }

  /// 诊断 seam：当前是否处于退避期。
  var isBackingOff: Bool { backoffUntil.map { Date() < $0 } ?? false }

  /// 测试直接注入窗口（和可选的档位），绕过网络。
  func injectForTesting(_ windows: [AgentUsageWindow], planName: String? = nil) {
    fetchedAt = Date()
    if let planName { self.planName = planName }
    self.windows = windows
  }

  /// 官方接口。按状态码分流：200 成功、401 token 失效、429 限流（带 `Retry-After` 秒数）、
  /// 其余（含网络错误）为一般失败。
  static let fetchUsage: Fetcher = { token in
    var request = URLRequest(url: ClaudeAccountQuotaParser.usageEndpoint, timeoutInterval: 8)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    request.setValue("Aster", forHTTPHeaderField: "User-Agent")
    guard let (data, response) = try? await URLSession.shared.data(for: request),
      let http = response as? HTTPURLResponse
    else { return .failure(status: nil) }
    switch http.statusCode {
    case 200: return .success(data)
    case 401: return .unauthorized
    case 429:
      // 实测服务端会返回 `Retry-After: 0`，按字面执行等于不退避；只有正值才采信，
      // 否则交给指数退避。
      let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
      return .rateLimited(retryAfter: retryAfter.flatMap { $0 > 0 ? min($0, maximumBackoff) : nil })
    default: return .failure(status: http.statusCode)
    }
  }

  /// 读 Claude Code 的凭据：先登录钥匙串（首次会弹一次系统授权，选「始终允许」即可），
  /// 再回退 `~/.claude/.credentials.json`。走 `security` 命令而不是 SecItem，行为与
  /// Claude Code 自己一致，也避免把 Aster 的签名加进钥匙串项的 ACL。
  static let readKeychainToken: TokenReader = {
    await Task.detached(priority: .utility) { () -> (token: String, planName: String?)? in
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
      process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
      let output = Pipe()
      process.standardOutput = output
      process.standardError = FileHandle.nullDevice
      var data: Data?
      if (try? process.run()) != nil {
        data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 { data = nil }
      }
      if data == nil {
        let fallback = FileManager.default.homeDirectoryForCurrentUser
          .appendingPathComponent(".claude/.credentials.json")
        data = try? Data(contentsOf: fallback)
      }
      guard let data, let token = ClaudeAccountQuotaParser.accessToken(fromCredentials: data) else {
        return nil
      }
      return (token, ClaudeAccountQuotaParser.planName(fromCredentials: data))
    }.value
  }
}
