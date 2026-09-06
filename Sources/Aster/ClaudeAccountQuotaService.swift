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
/// 生命周期由 pane 引用计数驱动：有 Claude pane 时每 60s 轮询，Agent 每轮结束再补拉一次；
/// 没有 Claude pane 时不发任何请求。token 只在内存里缓存到过期，不落盘。
@MainActor
final class ClaudeAccountQuotaService: ObservableObject {
  static let shared = ClaudeAccountQuotaService()
  static let pollInterval: Duration = .seconds(60)
  /// 活动触发的补拉与上次请求至少间隔这么久，避免连续几轮回复把接口打成 429。
  static let minimumRefreshInterval: TimeInterval = 10
  nonisolated static let keychainService = "Claude Code-credentials"

  typealias Fetcher = @Sendable (_ token: String) async -> ClaudeUsageFetchOutcome
  typealias TokenReader = @Sendable () async -> String?
  /// 限流 / 服务端错误后的退避上限；每次失败翻倍，成功一次即归零。
  nonisolated static let maximumBackoff: TimeInterval = 600

  /// 最近一次成功拉取的窗口；nil 表示还没拿到过（无 token、离线、API key 登录）。
  @Published private(set) var windows: [AgentUsageWindow]?

  private let fetch: Fetcher
  private let readToken: TokenReader
  private var retainCount = 0
  private var pollTask: Task<Void, Never>?
  private var refreshTask: Task<Void, Never>?
  private var lastFetchAt: Date?
  private var cachedToken: String?
  /// 退避截止时间：在此之前任何 refresh（包括定时轮询）都直接跳过，避免把 429 越打越多。
  private var backoffUntil: Date?
  private var consecutiveFailures = 0

  init(
    fetch: @escaping Fetcher = ClaudeAccountQuotaService.fetchUsage,
    readToken: @escaping TokenReader = ClaudeAccountQuotaService.readKeychainToken
  ) {
    self.fetch = fetch
    self.readToken = readToken
  }

  /// pane 的 Claude 开始运行：第一个引用启动轮询并立即拉一次。
  func retain() {
    retainCount += 1
    guard retainCount == 1 else { return }
    pollTask = Task { [weak self] in
      while !Task.isCancelled {
        await self?.refresh(force: true)
        try? await Task.sleep(for: Self.pollInterval)
      }
    }
  }

  /// 最后一个 Claude pane 结束：停止轮询，保留最后数据供下次立刻显示。
  func release() {
    retainCount = max(retainCount - 1, 0)
    guard retainCount == 0 else { return }
    pollTask?.cancel()
    pollTask = nil
    refreshTask?.cancel()
    refreshTask = nil
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

  /// 拉一次。只有 401 才丢弃 token（重新读 Keychain）；429 与其它服务端错误保留 token 并
  /// 按 `Retry-After` / 指数退避暂停，否则一次限流会被当成「未登录」而永远不显示用量条。
  /// 每个失败分支都写诊断（不含 token），让「条为什么没出来」能在日志里看到。
  func refresh(force: Bool) async {
    let now = Date()
    if let backoffUntil, now < backoffUntil { return }
    if !force, let lastFetchAt, now.timeIntervalSince(lastFetchAt) < Self.minimumRefreshInterval {
      return
    }
    lastFetchAt = now
    if cachedToken == nil { cachedToken = await readToken() }
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
      if parsed != windows { windows = parsed }
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

  /// 指数退避：60s、120s、240s … 封顶 `maximumBackoff`。
  private func nextBackoff() -> TimeInterval {
    consecutiveFailures += 1
    return min(Self.maximumBackoff, 60 * pow(2, Double(consecutiveFailures - 1)))
  }

  /// 诊断 seam：当前是否处于退避期。
  var isBackingOff: Bool { backoffUntil.map { Date() < $0 } ?? false }

  /// 测试直接注入窗口，绕过网络。
  func injectForTesting(_ windows: [AgentUsageWindow]) {
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
    await Task.detached(priority: .utility) { () -> String? in
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
      guard let data else { return nil }
      return ClaudeAccountQuotaParser.accessToken(fromCredentials: data)
    }.value
  }
}
