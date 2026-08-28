import Foundation

/// 屏幕检测发布层的纯逻辑，移植自 herdr `src/pane/agent_detection.rs` 与 `pane.rs` 检测循环。
///
/// 职责：决定“这一轮要不要读屏”与“检测结果要不要发布”。不做 IO、不持有定时器，
/// 时间全部由调用方注入（`ContinuousClock.Instant`），便于测试。
///
/// 关键节奏（常量见下）：
/// - 正常每 300ms 轮询一次；处于 pending idle 确认期时加速到 100ms。
/// - working → 普通 idle（无 visible_idle / visible_blocker 证据）不立即发布，需连续 3 次
///   确认且总时长 ≤ 700ms，避免 Agent 刷屏间隙被误判为空闲；`visibleIdle` 直通。
/// - Agent 刚被识别后有 3s 启动宽限，期间不读屏，避免把启动画面当成状态。
/// - 持续 blocked 时每 800ms 重发一次心跳，让上层的“需要你”提醒能刷新。
public struct AgentScreenDetectionPublisher: Sendable {
  public typealias Instant = ContinuousClock.Instant

  public static let pollInterval: Duration = .milliseconds(300)
  public static let pendingIdleRecheck: Duration = .milliseconds(100)
  public static let pendingIdleConfirmations = 3
  public static let pendingIdleCap: Duration = .milliseconds(700)
  public static let stableVisibleSignalRefresh: Duration = .milliseconds(800)
  public static let startupGraceWindow: Duration = .seconds(3)

  /// 已发布（或待发布）的状态快照。
  public struct PublishedState: Equatable, Sendable {
    public var state: AgentScreenState
    public var visibleIdle: Bool
    public var visibleBlocker: Bool
    public var visibleWorking: Bool
    public var processExited: Bool
    /// idle 是「未命中任何规则」的兜底；上层可在这种 idle 上叠加等待输入启发式。
    public var isFallbackIdle: Bool

    public init(
      state: AgentScreenState,
      visibleIdle: Bool = false,
      visibleBlocker: Bool = false,
      visibleWorking: Bool = false,
      processExited: Bool = false,
      isFallbackIdle: Bool = false
    ) {
      self.state = state
      self.visibleIdle = visibleIdle
      self.visibleBlocker = visibleBlocker
      self.visibleWorking = visibleWorking
      self.processExited = processExited
      self.isFallbackIdle = isFallbackIdle
    }
  }

  /// working → 普通 idle 的确认计数器（对应 herdr `PendingIdleConfirmation`）。
  public struct PendingIdleConfirmation: Equatable, Sendable {
    var startedAt: Instant?
    var confirmations = 0

    public init() {}

    public var isActive: Bool { startedAt != nil }

    public mutating func clear() {
      startedAt = nil
      confirmations = 0
    }

    /// 是否要继续压住这次 working → idle。返回 true 表示本轮不发布。
    ///
    /// 只对“working → 无证据 idle”生效；第一次看到时开始计时并压住，之后每次确认 +1，
    /// 累计到 3 次或超过 700ms 上限即放行。任何其它转换都会清空计数器。
    public mutating func shouldHoldWorkingToIdle(
      previous: PublishedState, next: PublishedState,
      agentChanged: Bool, processExited: Bool, now: Instant
    ) -> Bool {
      let isWorkingToPlainIdle =
        previous.state == .working && next.state == .idle
        && !next.visibleIdle && !next.visibleBlocker
        && !agentChanged && !processExited
      guard isWorkingToPlainIdle else {
        clear()
        return false
      }
      guard let startedAt else {
        self.startedAt = now
        confirmations = 0
        return true
      }
      if startedAt.duration(to: now) >= AgentScreenDetectionPublisher.pendingIdleCap {
        clear()
        return false
      }
      confirmations += 1
      if confirmations >= AgentScreenDetectionPublisher.pendingIdleConfirmations {
        clear()
        return false
      }
      return true
    }
  }

  public private(set) var pendingIdle = PendingIdleConfirmation()
  /// 上次发布 visible_blocker / visible_working 的时刻，用于 blocked 心跳判定。
  public private(set) var lastVisibleSignalRefresh: Instant?
  /// 上次读屏时的内容序号；idle 且序号未变则跳过读屏。
  public private(set) var lastScreenScanContentSequence: UInt64?
  /// 启动宽限截止时刻；nil 表示不在宽限期。
  public private(set) var startupGraceUntil: Instant?

  public init() {}

  /// 本轮之后应等待多久再轮询。
  public var nextPollInterval: Duration {
    pendingIdle.isActive ? Self.pendingIdleRecheck : Self.pollInterval
  }

  /// 清空全部内部状态（Agent 消失 / 会话重置）。
  public mutating func reset() {
    pendingIdle.clear()
    lastVisibleSignalRefresh = nil
    lastScreenScanContentSequence = nil
    startupGraceUntil = nil
  }

  /// 识别到新的 Agent：开始启动宽限（默认 3s，测试可缩短），并清空旧 Agent 的缓存。
  public mutating func beginStartupGrace(now: Instant, window: Duration = startupGraceWindow) {
    pendingIdle.clear()
    lastScreenScanContentSequence = nil
    lastVisibleSignalRefresh = nil
    startupGraceUntil = now + window
  }

  /// 启动宽限处理（对应 pane.rs 检测循环开头）。返回 true 表示本轮应跳过读屏。
  ///
  /// 进程退出会立即结束宽限；宽限到期的那一轮也跳过（herdr 同样 `continue`），下一轮才开始读屏。
  public mutating func consumeStartupGrace(processExited: Bool, now: Instant) -> Bool {
    guard let until = startupGraceUntil else { return false }
    startupGraceUntil = nil
    pendingIdle.clear()
    if processExited {
      lastScreenScanContentSequence = nil
      return false
    }
    if now < until {
      startupGraceUntil = until
    }
    return true
  }

  /// 是否需要读屏（对应 herdr `decide_detection_screen_read`）。
  ///
  /// 只有“已发布 idle + 没有任何转换信号 + PTY 内容序号自上次读屏未变”才跳过：
  /// idle 时屏幕不变就不可能产生新证据，省掉一次读屏与规则求值。
  /// 返回 true 时会记录本次序号；序号为 nil（无 Agent）永远读。
  public mutating func shouldReadScreen(
    state: AgentScreenState, contentSequence: UInt64?,
    agentChanged: Bool, processExited: Bool
  ) -> Bool {
    let skip =
      state == .idle && contentSequence != nil
      && !pendingIdle.isActive && !agentChanged && !processExited
      && lastScreenScanContentSequence == contentSequence
    if skip { return false }
    lastScreenScanContentSequence = contentSequence
    return true
  }

  /// 把引擎结果折叠成发布决策（对应 herdr `detection_update_for_publish_with_osc` +
  /// `decide_screen_detection_publish`）。返回 nil 表示本轮不发布。
  ///
  /// - processExited：直接发布 idle + visibleIdle，不看屏幕。
  /// - skipStateUpdate：菜单 / 查看器等覆盖层，保持上一状态并清掉 pending idle。
  /// - 其它：先过 pending idle 压制，再判断状态或 visible 标志是否变化、是否 blocked 心跳到期。
  public mutating func decide(
    detection: AgentScreenDetection, previous: PublishedState,
    agentChanged: Bool, processExited: Bool, now: Instant
  ) -> PublishedState? {
    let effective: AgentScreenDetection
    if processExited {
      effective = AgentScreenDetection(state: .idle, visibleIdle: true)
    } else if detection.skipStateUpdate {
      pendingIdle.clear()
      return nil
    } else {
      effective = detection
    }

    let next = PublishedState(
      state: effective.state,
      visibleIdle: effective.visibleIdle && effective.state == .idle,
      visibleBlocker: effective.visibleBlocker && effective.state == .blocked,
      visibleWorking: effective.visibleWorking && effective.state == .working,
      processExited: processExited,
      isFallbackIdle: effective.isFallbackIdle && effective.state == .idle)

    if pendingIdle.shouldHoldWorkingToIdle(
      previous: previous, next: next, agentChanged: agentChanged,
      processExited: processExited, now: now)
    {
      return nil
    }

    let stableBlocker = next.visibleBlocker && previous.visibleBlocker
    let refreshDue =
      stableBlocker
      && (lastVisibleSignalRefresh.map { $0.duration(to: now) >= Self.stableVisibleSignalRefresh }
        ?? true)

    let shouldPublish =
      next.state != previous.state
      || next.visibleIdle != previous.visibleIdle
      || next.visibleBlocker != previous.visibleBlocker
      || next.visibleWorking != previous.visibleWorking
      || next.isFallbackIdle != previous.isFallbackIdle
      || agentChanged || processExited || refreshDue
    guard shouldPublish else { return nil }

    // 与 herdr apply_agent_detection_publish_update 一致：只有带 visible 证据的发布才刷新心跳基准。
    lastVisibleSignalRefresh = (next.visibleBlocker || next.visibleWorking) ? now : nil
    return next
  }
}
