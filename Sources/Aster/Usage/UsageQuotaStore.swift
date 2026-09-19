// 配额页与状态栏共用的账号快照来源：合并 Claude（官方 usage 接口）、Codex（app-server，
// rollout 兜底）、Cursor（官方用量接口）与 Antigravity（它自己的本地 language server）。
import AsterCore
import Combine
import Foundation

/// 账号配额的唯一发布点。
///
/// `start()` 之后才有任何开销；`stop()` 之后不留轮询。Claude 侧复用
/// `ClaudeAccountQuotaService.shared` 的共享请求时间线，绝不另起第二条；其余三家各自
/// 按 `pollInterval` 被动轮询，取数一律放后台，结果带世代校验回主线程。
@MainActor
final class UsageQuotaStore: ObservableObject {
  /// 一次取数的结果，屏蔽各来源的差异。
  struct QuotaReading: Sendable {
    var windows: [AgentUsageWindow]
    var plan: String?
    var fetchedAt: Date
  }

  /// Codex 权威来源的注入点，生产走 `CodexAppServerQuotaClient.latestWindows`。
  typealias CodexAppServerReader = @Sendable (_ homeDirectory: URL, _ now: Date) -> (
    windows: [AgentUsageWindow], plan: String?
  )?
  /// Codex 兜底来源的注入点，生产走 `CodexAccountQuotaReader.latestWindows`。
  typealias CodexReader = @Sendable (_ homeDirectory: URL, _ now: Date) -> (
    windows: [AgentUsageWindow], updatedAt: Date, plan: String?
  )?
  /// Cursor 来源的注入点。
  typealias CursorReader = @Sendable (_ homeDirectory: URL, _ now: Date) -> QuotaReading?
  /// Antigravity 来源的注入点。不带 home 参数：它要找的是运行中的进程，不是文件。
  typealias AntigravityReader = @Sendable (_ now: Date) -> QuotaReading?

  static let claudeAccountID = "claudeCode:default"
  static let codexAccountID = "codex:default"
  static let cursorAccountID = "cursorCLI:default"
  static let antigravityAccountID = "agy:default"
  /// 被动轮询周期。这些来源没有任何本地事件可订阅（rollout 只反映本机会话，Cursor 与
  /// Antigravity 是远端/进程状态），只能定期问一次；与 Claude 的被动档一致取 300 秒。
  static let codexPollInterval: Duration = .seconds(300)
  /// 浮动窗打开触发的刷新节流：距上次成功不足这么久就跳过，避免反复开关面板把子进程刷爆。
  static let codexRefreshThrottle: TimeInterval = 60

  /// 有数据的账号。没有任何窗口的 provider 不出现。
  @Published private(set) var accounts: [UsageAccountSnapshot] = []

  /// 一个需要主动去取的配额来源的全部状态。Claude 不在此列——它由共享服务推送。
  @MainActor
  private final class PolledSource {
    let accountID: String
    let provider: AgentProvider
    let label: String
    /// 取数体。阻塞式 IO，只在 `Task.detached` 里调用。
    let load: @Sendable (Date) -> QuotaReading?
    var snapshot: UsageAccountSnapshot?
    var task: Task<Void, Never>?
    var pollTask: Task<Void, Never>?
    /// 上一次还没回来。起子进程或发请求可能要几秒，期间的触发一律丢弃而不是排队。
    var inFlight = false
    /// 上一次取数成功的时刻，只用于节流判断。
    var lastSuccessAt: Date?
    /// 每次发起自增；回主线程时对不上就说明结果已过期，直接丢弃。
    var generation = 0

    init(
      accountID: String, provider: AgentProvider, label: String,
      load: @escaping @Sendable (Date) -> QuotaReading?
    ) {
      self.accountID = accountID
      self.provider = provider
      self.label = label
      self.load = load
    }

    func cancel() {
      task?.cancel()
      task = nil
      pollTask?.cancel()
      pollTask = nil
      inFlight = false
      lastSuccessAt = nil
      generation += 1
      snapshot = nil
    }
  }

  private let claude: ClaudeAccountQuotaService
  /// 节流阈值。做成实例属性只为让测试能把它调成 0，生产一律用 `codexRefreshThrottle`。
  private let refreshThrottle: TimeInterval
  private var cancellables: Set<AnyCancellable> = []
  private var started = false
  private var claudeSnapshot: UsageAccountSnapshot?
  private let sources: [PolledSource]

  init(
    claude: ClaudeAccountQuotaService = .shared,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    codexAppServer: @escaping CodexAppServerReader = CodexAppServerQuotaClient.latestWindows,
    codexReader: @escaping CodexReader = CodexAccountQuotaReader.latestWindows,
    cursorReader: @escaping CursorReader = UsageQuotaStore.liveCursorReader,
    antigravityReader: @escaping AntigravityReader = UsageQuotaStore.liveAntigravityReader,
    refreshThrottle: TimeInterval = UsageQuotaStore.codexRefreshThrottle
  ) {
    self.claude = claude
    self.refreshThrottle = refreshThrottle
    let home = homeDirectory
    sources = [
      PolledSource(
        accountID: Self.codexAccountID, provider: .codex, label: "Codex",
        load: { now in
          // app-server 是权威值：它反映服务端当前额度，rollout 只有本机某个会话的历史快照。
          if let authoritative = codexAppServer(home, now) {
            return QuotaReading(
              windows: authoritative.windows, plan: authoritative.plan, fetchedAt: now)
          }
          guard let local = codexReader(home, now) else { return nil }
          return QuotaReading(
            windows: local.windows, plan: local.plan, fetchedAt: local.updatedAt)
        }),
      PolledSource(
        accountID: Self.cursorAccountID, provider: .cursorCLI, label: "Cursor",
        load: { now in cursorReader(home, now) }),
      PolledSource(
        accountID: Self.antigravityAccountID, provider: .antigravity, label: "Antigravity",
        load: { now in antigravityReader(now) }),
    ]
  }

  /// 生产的 Cursor 取数体。
  static let liveCursorReader: CursorReader = { home, now in
    guard let result = CursorAccountQuotaClient.latest(homeDirectory: home, now: now) else {
      return nil
    }
    return QuotaReading(
      windows: result.windows, plan: result.plan, fetchedAt: result.fetchedAt)
  }

  /// 生产的 Antigravity 取数体。
  ///
  /// 每次都重新 `locateServer()`，刻意不缓存端点：定位是一次 `ps`（找不到进程时就此结束）
  /// 加最多一次 `lsof`，实测约 32 毫秒，摊到 300 秒一轮可以忽略；而缓存住「没找到」会让
  /// 用户刚打开 Antigravity 后迟迟看不到卡片，缓存住旧端口则会在它重启后一直打错地方。
  static let liveAntigravityReader: AntigravityReader = { now in
    guard let result = AntigravityQuotaClient.latest(now: now) else { return nil }
    return QuotaReading(
      windows: result.windows, plan: result.plan, fetchedAt: result.fetchedAt)
  }

  /// 功能开启：开始被动轮询。可重复调用。
  func start() {
    guard !started else { return }
    started = true
    claude.retainPassive()
    // `$windows` 订阅时会立刻回放当前值，所以本地缓存里的数字不用等第一次请求就能显示。
    claude.$windows
      .sink { [weak self] windows in self?.applyClaude(windows) }
      .store(in: &cancellables)
    for source in sources {
      refresh(source, throttled: false)
      schedulePoll(source)
    }
  }

  /// 功能关闭：停止一切轮询。可重复调用。
  func stop() {
    guard started else { return }
    started = false
    claude.releasePassive()
    cancellables.removeAll()
    for source in sources { source.cancel() }
    claudeSnapshot = nil
    publish()
  }

  /// 浮动窗打开配额页时调用：尽快把各来源刷新一遍，但受节流保护。
  func refreshLocalSources() {
    for source in sources { refresh(source, throttled: true) }
  }

  /// 诊断 / 测试 seam：被动轮询是否已排上。各来源同起同停，取第一个即可代表整体。
  var hasScheduledCodexPoll: Bool { sources.contains { $0.pollTask != nil } }

  /// 单次延迟任务自续，不用 `Timer`：省掉一个常驻 runloop 源，`stop()` 里取消即彻底结束。
  private func schedulePoll(_ source: PolledSource) {
    source.pollTask = Task { [weak self, weak source] in
      try? await Task.sleep(for: Self.codexPollInterval)
      guard !Task.isCancelled, let self, let source, self.started else { return }
      self.refresh(source, throttled: false)
      self.schedulePoll(source)
    }
  }

  /// 取一次某个来源的配额。
  ///
  /// `throttled` 为真时距上次成功不足 `refreshThrottle` 就直接跳过；上一次还没回来也跳过——
  /// 同时起两次既慢又没有意义。
  private func refresh(_ source: PolledSource, throttled: Bool) {
    guard started, !source.inFlight else { return }
    if throttled, let last = source.lastSuccessAt,
      Date().timeIntervalSince(last) < refreshThrottle
    { return }
    source.generation += 1
    let token = source.generation
    let load = source.load
    source.inFlight = true
    source.task?.cancel()
    source.task = Task { [weak self, weak source] in
      let result = await Task.detached(priority: .utility) { load(Date()) }.value
      guard let self, let source else { return }
      source.inFlight = false
      guard !Task.isCancelled, token == source.generation else { return }
      self.apply(result, to: source)
    }
  }

  /// Claude 侧的窗口变化落到快照。`fetchedAt` 与窗口在服务里是同一次刷新写的，配对读取。
  private func applyClaude(_ windows: [AgentUsageWindow]?) {
    if let windows, !windows.isEmpty {
      claudeSnapshot = UsageAccountSnapshot(
        id: Self.claudeAccountID, provider: .claudeCode, label: "Claude", plan: claude.planName,
        windows: windows, fetchedAt: claude.fetchedAt)
    } else {
      claudeSnapshot = nil
    }
    publish()
  }

  /// 某个来源一次取数的结果落到快照。取不到就让那张卡片消失——这些都是私有接口或需要对方
  /// 进程在跑，读不到是常态而非错误，不弹窗也不保留旧数字。
  private func apply(_ reading: QuotaReading?, to source: PolledSource) {
    if let reading, !reading.windows.isEmpty {
      source.lastSuccessAt = Date()
      source.snapshot = UsageAccountSnapshot(
        id: source.accountID, provider: source.provider, label: source.label, plan: reading.plan,
        windows: reading.windows, fetchedAt: reading.fetchedAt)
    } else {
      source.snapshot = nil
    }
    publish()
  }

  /// 汇总发布。`UsageAccountSnapshot` 的 `==` 不比较 `fetchedAt`，所以数值没变就不重新发布，
  /// 视图不会因为每一轮轮询而重绘。
  private func publish() {
    let order = AgentProvider.allCases
    let ordered = ([claudeSnapshot] + sources.map(\.snapshot)).compactMap { $0 }
      .sorted {
        (order.firstIndex(of: $0.provider) ?? order.count)
          < (order.firstIndex(of: $1.provider) ?? order.count)
      }
    guard ordered != accounts else { return }
    accounts = ordered
  }
}
