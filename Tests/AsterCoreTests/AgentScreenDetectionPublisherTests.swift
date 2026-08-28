import Testing

@testable import AsterCore

/// 发布层纯逻辑测试（移植 herdr pane/agent_detection.rs 末尾用例，并补齐宽限 / 心跳 / 进程退出）。
///
/// `#expect` 内不能直接调 mutating 方法，因此先把结果绑定到 let 再断言。
@Suite("AgentScreenDetectionPublisher")
struct AgentScreenDetectionPublisherTests {
  typealias Publisher = AgentScreenDetectionPublisher
  typealias Published = AgentScreenDetectionPublisher.PublishedState

  static func published(_ state: AgentScreenState) -> Published { Published(state: state) }

  /// 与 herdr `screen_detection` 助手一致：idle 带 visible_idle，working 带 visible_working。
  static func detection(_ state: AgentScreenState) -> AgentScreenDetection {
    AgentScreenDetection(
      state: state, visibleIdle: state == .idle, visibleWorking: state == .working)
  }

  /// 模拟 herdr 用例：上次读屏序号是 10。
  static func publisherAfterScan(sequence: UInt64 = 10) -> Publisher {
    var publisher = Publisher()
    _ = publisher.shouldReadScreen(
      state: .working, contentSequence: sequence, agentChanged: false, processExited: false)
    return publisher
  }

  /// 读屏决策的简写。
  static func read(
    _ publisher: inout Publisher, state: AgentScreenState, sequence: UInt64?,
    agentChanged: Bool = false, processExited: Bool = false
  ) -> Bool {
    publisher.shouldReadScreen(
      state: state, contentSequence: sequence, agentChanged: agentChanged,
      processExited: processExited)
  }

  /// pending idle 判定的简写（默认无 agentChanged / processExited）。
  static func hold(
    _ pending: inout Publisher.PendingIdleConfirmation, previous: Published, next: Published,
    now: ContinuousClock.Instant
  ) -> Bool {
    pending.shouldHoldWorkingToIdle(
      previous: previous, next: next, agentChanged: false, processExited: false, now: now)
  }

  @Test("idle 且底部缓冲未变时跳过读屏")
  func screenReadSkipsUnchangedIdleBottomBuffer() {
    var publisher = Self.publisherAfterScan()
    let read = Self.read(&publisher, state: .idle, sequence: 10)
    #expect(!read)
  }

  @Test("idle 但缓冲变化时读屏")
  func screenReadReadsWhenIdleBottomBufferChanges() {
    var publisher = Self.publisherAfterScan()
    let read = Self.read(&publisher, state: .idle, sequence: 11)
    #expect(read)
    #expect(publisher.lastScreenScanContentSequence == 11)
  }

  @Test("转换信号、pending idle、无 Agent 时总是读屏")
  func screenReadReadsForTransitionsAndMissingAgent() {
    var changed = Self.publisherAfterScan()
    let readChanged = Self.read(&changed, state: .idle, sequence: 10, agentChanged: true)
    #expect(readChanged)

    var exited = Self.publisherAfterScan()
    let readExited = Self.read(&exited, state: .idle, sequence: 10, processExited: true)
    #expect(readExited)

    var noAgent = Self.publisherAfterScan()
    let readNoAgent = Self.read(&noAgent, state: .idle, sequence: nil)
    #expect(readNoAgent)

    var working = Self.publisherAfterScan()
    let readWorking = Self.read(&working, state: .working, sequence: 10)
    #expect(readWorking)

    // pending idle 激活时也要读屏。
    var pending = Self.publisherAfterScan()
    let now = ContinuousClock.now
    let held = pending.decide(
      detection: AgentScreenDetection(state: .idle), previous: Self.published(.working),
      agentChanged: false, processExited: false, now: now)
    #expect(held == nil)
    #expect(pending.pendingIdle.isActive)
    #expect(pending.nextPollInterval == Publisher.pendingIdleRecheck)
    let readPending = Self.read(&pending, state: .idle, sequence: 10)
    #expect(readPending)
  }

  @Test("working → 普通 idle 需连续 3 次确认")
  func pendingIdleHoldsWorkingToPlainIdleUntilConfirmed() {
    let now = ContinuousClock.now
    let previous = Self.published(.working)
    let next = Self.published(.idle)
    var pending = Publisher.PendingIdleConfirmation()

    let first = Self.hold(&pending, previous: previous, next: next, now: now)
    let second = Self.hold(
      &pending, previous: previous, next: next, now: now + Publisher.pendingIdleRecheck)
    let third = Self.hold(
      &pending, previous: previous, next: next, now: now + Publisher.pendingIdleRecheck * 2)
    let fourth = Self.hold(
      &pending, previous: previous, next: next, now: now + Publisher.pendingIdleRecheck * 3)
    #expect(first && second && third)
    #expect(!fourth)
    #expect(!pending.isActive)
  }

  @Test("pending idle 超过 700ms 上限即放行")
  func pendingIdleCapReleasesHold() {
    let now = ContinuousClock.now
    let previous = Self.published(.working)
    let next = Self.published(.idle)
    var pending = Publisher.PendingIdleConfirmation()
    let first = Self.hold(&pending, previous: previous, next: next, now: now)
    let capped = Self.hold(
      &pending, previous: previous, next: next, now: now + Publisher.pendingIdleCap)
    #expect(first)
    #expect(!capped)
    // 其它转换会清空计数器。
    let restarted = Self.hold(&pending, previous: previous, next: next, now: now)
    let blocked = Self.hold(&pending, previous: previous, next: Self.published(.blocked), now: now)
    #expect(restarted)
    #expect(!blocked)
    #expect(!pending.isActive)
  }

  @Test("visible_idle 直通，不进入 pending")
  func visibleIdleBypassesPlainIdleHold() {
    let now = ContinuousClock.now
    var next = Self.published(.idle)
    next.visibleIdle = true
    var pending = Publisher.PendingIdleConfirmation()
    let held = Self.hold(&pending, previous: Self.published(.working), next: next, now: now)
    #expect(!held)
  }

  @Test("visible blocker 立即发布")
  func transitionDecisionPublishesNextForVisibleBlocker() {
    var publisher = Publisher()
    let now = ContinuousClock.now
    let result = publisher.decide(
      detection: AgentScreenDetection(state: .blocked, visibleBlocker: true),
      previous: Self.published(.idle), agentChanged: false, processExited: false, now: now)
    #expect(result == Published(state: .blocked, visibleBlocker: true))
    #expect(publisher.lastVisibleSignalRefresh == now)
  }

  @Test("屏幕 working 证据无需 PTY 活动即可发布")
  func screenPublishKeepsVisibleWorkingWithoutPTYActivity() {
    var publisher = Publisher()
    let result = publisher.decide(
      detection: Self.detection(.working), previous: Self.published(.idle),
      agentChanged: false, processExited: false, now: ContinuousClock.now)
    #expect(result == Published(state: .working, visibleWorking: true))
  }

  @Test("blocked → visible idle 不经延迟直接发布")
  func screenPublishCanPublishIdleWithoutInputTaintDelay() {
    var publisher = Publisher()
    let result = publisher.decide(
      detection: Self.detection(.idle), previous: Self.published(.blocked),
      agentChanged: false, processExited: false, now: ContinuousClock.now)
    #expect(result == Published(state: .idle, visibleIdle: true))
    #expect(publisher.lastVisibleSignalRefresh == nil)
  }

  @Test("相同状态不重复发布；持续 blocked 每 800ms 心跳一次")
  func stableBlockerHeartbeat() {
    var publisher = Publisher()
    let now = ContinuousClock.now
    let blocked = AgentScreenDetection(state: .blocked, visibleBlocker: true)
    let previous = Published(state: .blocked, visibleBlocker: true)

    // 没有上次刷新记录 → 视为到期，先发一次。
    let initial = publisher.decide(
      detection: blocked, previous: previous, agentChanged: false, processExited: false, now: now)
    #expect(initial != nil)
    // 未到 800ms → 不发。
    let early = publisher.decide(
      detection: blocked, previous: previous, agentChanged: false, processExited: false,
      now: now + .milliseconds(500))
    #expect(early == nil)
    // 到期 → 心跳。
    let heartbeat = publisher.decide(
      detection: blocked, previous: previous, agentChanged: false, processExited: false,
      now: now + Publisher.stableVisibleSignalRefresh)
    #expect(heartbeat != nil)
    // 无 visible 的相同状态永远不重复发布。
    let sameWorking = publisher.decide(
      detection: AgentScreenDetection(state: .working), previous: Self.published(.working),
      agentChanged: false, processExited: false, now: now + .seconds(5))
    #expect(sameWorking == nil)
  }

  @Test("进程退出直接发布 idle + visible_idle；skip 规则不发布并清 pending")
  func processExitedAndSkipStateUpdate() {
    var publisher = Publisher()
    let now = ContinuousClock.now
    let exited = publisher.decide(
      detection: AgentScreenDetection(state: .working, visibleWorking: true),
      previous: Self.published(.working), agentChanged: false, processExited: true, now: now)
    #expect(exited == Published(state: .idle, visibleIdle: true, processExited: true))

    // 先进入 pending，再遇到 skip 规则 → 清空 pending 且不发布。
    let held = publisher.decide(
      detection: AgentScreenDetection(state: .idle), previous: Self.published(.working),
      agentChanged: false, processExited: false, now: now)
    #expect(held == nil)
    #expect(publisher.pendingIdle.isActive)
    let skipped = publisher.decide(
      detection: AgentScreenDetection(state: .unknown, skipStateUpdate: true),
      previous: Self.published(.working), agentChanged: false, processExited: false, now: now)
    #expect(skipped == nil)
    #expect(!publisher.pendingIdle.isActive)
    #expect(publisher.nextPollInterval == Publisher.pollInterval)
  }

  @Test("启动宽限 3s 内不读屏；进程退出立即结束宽限")
  func startupGraceWindow() {
    var publisher = Publisher()
    let now = ContinuousClock.now
    publisher.beginStartupGrace(now: now)
    let inGrace = publisher.consumeStartupGrace(processExited: false, now: now + .seconds(1))
    #expect(inGrace)
    #expect(publisher.startupGraceUntil != nil)
    // 到期那一轮仍然跳过，但宽限结束。
    let expiring = publisher.consumeStartupGrace(processExited: false, now: now + .seconds(3))
    #expect(expiring)
    #expect(publisher.startupGraceUntil == nil)
    let afterGrace = publisher.consumeStartupGrace(processExited: false, now: now + .seconds(4))
    #expect(!afterGrace)

    var exiting = Publisher()
    exiting.beginStartupGrace(now: now)
    let exitedInGrace = exiting.consumeStartupGrace(processExited: true, now: now)
    #expect(!exitedInGrace)
    #expect(exiting.startupGraceUntil == nil)

    publisher.reset()
    #expect(publisher.lastScreenScanContentSequence == nil)
    #expect(publisher.startupGraceUntil == nil)
  }
}

extension AgentScreenDetectionPublisherTests {
  @Test("兜底 idle 标记随发布状态传递，且兜底/规则 idle 切换会触发发布")
  func fallbackIdlePropagates() {
    var publisher = Publisher()
    let now = ContinuousClock.now
    let fallback = publisher.decide(
      detection: AgentScreenDetection(state: .idle, isFallbackIdle: true),
      previous: Self.published(.working), agentChanged: false, processExited: false, now: now)
    // working → 普通 idle 先被 pending 压住。
    #expect(fallback == nil)
    let confirmed = publisher.decide(
      detection: AgentScreenDetection(state: .idle, isFallbackIdle: true),
      previous: Self.published(.working), agentChanged: false, processExited: false,
      now: now + Publisher.pendingIdleCap)
    #expect(confirmed?.isFallbackIdle == true)
    let ruled = publisher.decide(
      detection: AgentScreenDetection(state: .idle, visibleIdle: true),
      previous: confirmed!, agentChanged: false, processExited: false, now: now + .seconds(1))
    #expect(ruled?.isFallbackIdle == false)
    #expect(ruled?.visibleIdle == true)
  }
}
