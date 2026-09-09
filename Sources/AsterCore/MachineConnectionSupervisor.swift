import Foundation

/// P4.4：每机器独立连接任务、取消代次、退避、健康检查与 attention。
///
/// 依据 `docs/developer/remote-work.md` §4.1 第 1/4/5/6 条：
/// - 每个 `MachineProfile` 一条**独立**任务；一台失联不阻塞另一台，也不阻塞 Local。
/// - 连接超时 10 秒、握手 5 秒；退避 1/2/4/8/16/30 秒并加 ±20% 抖动。
/// - 在线时 15 秒无应用层流量发心跳，连续 3 次未响应转 `reconnecting`。
/// - 需要交互认证 / 主机密钥未知 / 需要安装或替换服务 → `attention`，后台不重启服务、
///   不自动安装。
/// - 重连先校验 serverID/epoch 与快照，再放行输入；断线期间的输入不缓存不重放，
///   结果未知返回 `delivery_unknown`。
///
/// 时钟与调度全部可注入，所以 A14 的「虚拟时钟验证退避与心跳」可以真实断言，
/// 不需要 sleep 真实时间。

/// 连接策略。**全部数值集中在这里**（§4.1 第 5 条：所有值集中定义并测试）。
public struct MachineConnectionPolicy: Equatable, Sendable {
  /// TCP/SSH 连接超时（秒）。
  public var connectTimeout: TimeInterval
  /// 协议握手超时（秒）。
  public var handshakeTimeout: TimeInterval
  /// 退避表（秒）。超出表长后固定使用最后一档。
  public var backoffSchedule: [TimeInterval]
  /// 退避抖动幅度（比例）。±20%。
  public var backoffJitterFraction: Double
  /// 在线时无应用层流量多久发一次心跳（秒）。
  public var heartbeatInterval: TimeInterval
  /// 连续多少次心跳未响应转入 `reconnecting`。
  public var heartbeatMissTolerance: Int

  public init(
    connectTimeout: TimeInterval = 10,
    handshakeTimeout: TimeInterval = 5,
    backoffSchedule: [TimeInterval] = [1, 2, 4, 8, 16, 30],
    backoffJitterFraction: Double = 0.2,
    heartbeatInterval: TimeInterval = 15,
    heartbeatMissTolerance: Int = 3
  ) {
    self.connectTimeout = connectTimeout
    self.handshakeTimeout = handshakeTimeout
    self.backoffSchedule = backoffSchedule
    self.backoffJitterFraction = backoffJitterFraction
    self.heartbeatInterval = heartbeatInterval
    self.heartbeatMissTolerance = heartbeatMissTolerance
  }

  /// 第 `attempt` 次重试（从 0 开始）的基准退避秒数，未加抖动。
  ///
  /// 超出退避表长度后固定用最后一档（30 秒），不继续翻倍：无限增长会让恢复延迟
  /// 变得不可预期，用户看不出机器什么时候会再试。
  public func baseBackoff(attempt: Int) -> TimeInterval {
    guard !backoffSchedule.isEmpty else { return 0 }
    let index = min(max(attempt, 0), backoffSchedule.count - 1)
    return backoffSchedule[index]
  }

  /// 加抖动后的实际退避秒数。
  ///
  /// - Parameter jitter: 归一化抖动，取值 `-1...1`；乘上 `backoffJitterFraction`
  ///   得到 ±20% 的实际偏移。测试注入确定值即可断言精确结果。
  public func backoffDelay(attempt: Int, jitter: Double) -> TimeInterval {
    let base = baseBackoff(attempt: attempt)
    let clamped = min(max(jitter, -1), 1)
    return base * (1 + clamped * backoffJitterFraction)
  }
}

/// 一次连接尝试的结果。
public enum MachineConnectionOutcome: Equatable, Sendable {
  /// 连接与握手成功。
  case connected(SessionServerIdentity)
  /// 可自动重试的失败（不可达、超时、传输层错误）→ 退避重连。
  case transient(reason: String)
  /// 需要用户显式处理（交互认证、主机密钥未知/变更、需要安装或替换服务）→ attention。
  /// 后台在此状态下**不重启服务、不自动安装**。
  case needsExplicitSetup(kind: RemoteSSHFailureKind?, reason: String)
}

extension MachineConnectionOutcome {
  /// 由 SSH 层失败分类直接得出结果类别，避免各调用点各判一遍。
  public static func from(sshKind: RemoteSSHFailureKind, detail: String) -> MachineConnectionOutcome
  {
    sshKind.requiresExplicitSetup
      ? .needsExplicitSetup(kind: sshKind, reason: detail)
      : .transient(reason: detail)
  }
}

/// 输入投递结果。断线期间不缓存、不重放。
public enum ManagedInputDelivery: String, Equatable, Sendable {
  /// 已交给在线连接。
  case delivered
  /// 结果未知：连接代次已变化或在途时断线。不自动重放。
  case deliveryUnknown = "delivery_unknown"
  /// 明确拒绝：当前不在线，或重连后尚未完成身份/快照校验。
  case rejected
}

/// 单台机器的连接状态快照。界面直接渲染它。
public struct MachineConnectionStatus: Equatable, Sendable {
  public var profileID: UUID
  public var state: SessionConnectionState
  /// 当前取消代次。旧代次的回调与结果一律丢弃。
  public var generation: UInt64
  /// 已连续失败次数，决定下一档退避。
  public var failureCount: Int
  /// 连续未响应的心跳次数。
  public var missedHeartbeats: Int
  /// 已校验的服务身份；重连后必须重新校验才会重新填充。
  public var identity: SessionServerIdentity?
  /// 身份与快照都校验通过后才为 true；只有它为 true 才放行输入。
  public var inputAllowed: Bool
  /// 最近一次状态更新时间，供离线展示「缓存时间」。
  public var lastUpdatedAt: Date
  /// 进入 attention 或退避的已脱敏原因。
  public var reason: String?

  public init(
    profileID: UUID,
    state: SessionConnectionState,
    generation: UInt64,
    failureCount: Int = 0,
    missedHeartbeats: Int = 0,
    identity: SessionServerIdentity? = nil,
    inputAllowed: Bool = false,
    lastUpdatedAt: Date,
    reason: String? = nil
  ) {
    self.profileID = profileID
    self.state = state
    self.generation = generation
    self.failureCount = failureCount
    self.missedHeartbeats = missedHeartbeats
    self.identity = identity
    self.inputAllowed = inputAllowed
    self.lastUpdatedAt = lastUpdatedAt
    self.reason = reason
  }
}

/// 每台机器的连接驱动。真实实现走 SSH，测试注入替身。
///
/// `generation` 一路传下去，是为了让驱动自身也能在返回前发现自己已被取消。
public protocol MachineConnectionDriving: Sendable {
  /// 建立连接并完成握手；实现内部必须遵守 `connectTimeout` / `handshakeTimeout`。
  func connect(profile: MachineProfile, generation: UInt64) async -> MachineConnectionOutcome
  /// 应用层心跳；返回 false 表示本次未响应。
  func heartbeat(profile: MachineProfile, generation: UInt64) async -> Bool
  /// 重连后的快照确认。只有它返回 true 才放行输入。
  func confirmSnapshot(profile: MachineProfile, generation: UInt64) async -> Bool
}

/// 可注入的时间与调度环境。虚拟时钟测试用它替换真实等待。
public struct MachineConnectionEnvironment: Sendable {
  public var now: @Sendable () -> Date
  /// 等待指定秒数。虚拟时钟实现只推进逻辑时间，不真正阻塞。
  public var sleep: @Sendable (TimeInterval) async -> Void
  /// 归一化抖动源，取值 `-1...1`。
  public var jitter: @Sendable () -> Double

  public init(
    now: @escaping @Sendable () -> Date = { Date() },
    sleep: @escaping @Sendable (TimeInterval) async -> Void = { seconds in
      try? await Task.sleep(nanoseconds: UInt64(max(seconds, 0) * 1_000_000_000))
    },
    jitter: @escaping @Sendable () -> Double = { Double.random(in: -1...1) }
  ) {
    self.now = now
    self.sleep = sleep
    self.jitter = jitter
  }
}

/// 多机器连接编排器。
///
/// 每台机器一条独立的 `Task`：任何一台的退避等待、超时或 attention 都在自己的任务里，
/// 不会占用编排器本身，因此不阻塞其它机器，也不阻塞 Local 的启动与输入
/// （Local 根本不进入本编排器）。
public actor MachineConnectionSupervisor {
  private struct Entry {
    var profile: MachineProfile
    var status: MachineConnectionStatus
    var task: Task<Void, Never>?
  }

  public let policy: MachineConnectionPolicy
  private let environment: MachineConnectionEnvironment
  private let driver: any MachineConnectionDriving
  private var entries: [UUID: Entry] = [:]
  /// 因代次过期被丢弃的回调数量。测试用它证明旧代回调确实没有被应用。
  private(set) public var droppedStaleResults: Int = 0

  public init(
    policy: MachineConnectionPolicy = MachineConnectionPolicy(),
    environment: MachineConnectionEnvironment = MachineConnectionEnvironment(),
    driver: any MachineConnectionDriving
  ) {
    self.policy = policy
    self.environment = environment
    self.driver = driver
  }

  // MARK: - 生命周期

  /// 启动（或重启）某台机器的独立连接任务。
  ///
  /// 每次调用都会**递增代次**并取消旧任务：切换配置、修改连接相关字段之后，旧任务
  /// 的任何结果都不能再影响新状态。
  public func start(profile: MachineProfile) {
    guard profile.enabled else {
      setDisabled(profile: profile)
      return
    }
    let generation = bumpGeneration(for: profile.id)
    var status = MachineConnectionStatus(
      profileID: profile.id,
      state: .connecting,
      generation: generation,
      lastUpdatedAt: environment.now()
    )
    status.inputAllowed = false
    entries[profile.id] = Entry(profile: profile, status: status, task: nil)
    let task = Task<Void, Never> { [weak self] in
      await self?.runConnectionLoop(profileID: profile.id, generation: generation)
    }
    entries[profile.id]?.task = task
  }

  /// 禁用某台机器：即使离线也能操作；只断开该配置，**不停止远端服务**。
  public func disable(profileID: UUID) {
    guard var entry = entries[profileID] else { return }
    entry.task?.cancel()
    entry.task = nil
    let generation = bumpGeneration(for: profileID)
    entry.status = MachineConnectionStatus(
      profileID: profileID,
      state: .disabled,
      generation: generation,
      identity: entry.status.identity,
      inputAllowed: false,
      lastUpdatedAt: environment.now(),
      reason: nil
    )
    entries[profileID] = entry
  }

  /// 移除某台机器：即使离线也能操作；只断开该配置，**不停止远端服务**。
  public func remove(profileID: UUID) {
    entries[profileID]?.task?.cancel()
    entries.removeValue(forKey: profileID)
  }

  /// 只改标签的重命名**不触发重连**：代次、任务与连接状态全部保持不变。
  public func rename(profileID: UUID, label: String) {
    entries[profileID]?.profile.label = label
  }

  // MARK: - 查询

  public func status(profileID: UUID) -> MachineConnectionStatus? {
    entries[profileID]?.status
  }

  public func allStatuses() -> [MachineConnectionStatus] {
    entries.values.map(\.status).sorted { $0.profileID.uuidString < $1.profileID.uuidString }
  }

  public func currentGeneration(profileID: UUID) -> UInt64 {
    entries[profileID]?.status.generation ?? 0
  }

  // MARK: - 代次校验

  /// 某个代次的结果是否仍然有效。旧代次一律丢弃并计数。
  public func accepts(profileID: UUID, generation: UInt64) -> Bool {
    guard let entry = entries[profileID], entry.status.generation == generation else {
      droppedStaleResults += 1
      return false
    }
    return true
  }

  /// 外部（例如尚在飞行中的旧连接回调）投递一次结果。
  ///
  /// 这是 A14「注入旧代回调」的入口：代次不匹配时结果被完整丢弃，状态一个字段都不变。
  @discardableResult
  public func deliver(
    profileID: UUID,
    generation: UInt64,
    outcome: MachineConnectionOutcome
  ) -> Bool {
    guard accepts(profileID: profileID, generation: generation) else { return false }
    apply(outcome: outcome, profileID: profileID)
    return true
  }

  // MARK: - 输入

  /// 提交一次终端输入。
  ///
  /// - 代次已变化 → `delivery_unknown`：这条输入是否到达服务端无法确定，**不重放**。
  /// - 不在线或重连后尚未完成身份/快照校验 → `rejected`：不缓存断线期间的键入。
  public func submitInput(profileID: UUID, generation: UInt64) -> ManagedInputDelivery {
    guard let entry = entries[profileID] else { return .rejected }
    guard entry.status.generation == generation else {
      droppedStaleResults += 1
      return .deliveryUnknown
    }
    guard entry.status.state == .online, entry.status.inputAllowed else { return .rejected }
    return .delivered
  }

  // MARK: - 连接循环

  /// 单台机器的独立连接循环：连接 → 校验 → 心跳 → 失败退避重连。
  private func runConnectionLoop(profileID: UUID, generation: UInt64) async {
    while !Task.isCancelled {
      guard let profile = entries[profileID]?.profile,
        entries[profileID]?.status.generation == generation
      else { return }

      let outcome = await driver.connect(profile: profile, generation: generation)
      guard accepts(profileID: profileID, generation: generation) else { return }
      apply(outcome: outcome, profileID: profileID)

      switch outcome {
      case .needsExplicitSetup:
        // attention 需要用户到显式设置入口处理；后台不重启服务、不自动安装，
        // 因此这里结束循环，不进入退避重连。
        return

      case .transient:
        guard let failureCount = entries[profileID]?.status.failureCount else { return }
        let delay = policy.backoffDelay(
          attempt: failureCount - 1, jitter: environment.jitter())
        await environment.sleep(delay)
        continue

      case .connected(let identity):
        // 重连后先校验 serverID/epoch 与快照，通过之后才放行输入。
        let admitted = await admitAfterHandshake(
          profileID: profileID, generation: generation, profile: profile, identity: identity)
        guard admitted else {
          guard accepts(profileID: profileID, generation: generation) else { return }
          markTransient(profileID: profileID, reason: "snapshot not confirmed")
          let failureCount = entries[profileID]?.status.failureCount ?? 1
          await environment.sleep(
            policy.backoffDelay(attempt: failureCount - 1, jitter: environment.jitter()))
          continue
        }
        let healthy = await runHeartbeatLoop(
          profileID: profileID, generation: generation, profile: profile)
        guard healthy == false, accepts(profileID: profileID, generation: generation) else {
          return
        }
        // 连续 3 次心跳未响应 → reconnecting，走退避表从头开始。
        markReconnecting(profileID: profileID)
        await environment.sleep(policy.backoffDelay(attempt: 0, jitter: environment.jitter()))
        continue
      }
    }
  }

  /// 校验重连结果：serverID/epoch 与上次一致或首次连接，且快照确认到达。
  private func admitAfterHandshake(
    profileID: UUID,
    generation: UInt64,
    profile: MachineProfile,
    identity: SessionServerIdentity
  ) async -> Bool {
    let confirmed = await driver.confirmSnapshot(profile: profile, generation: generation)
    guard accepts(profileID: profileID, generation: generation) else { return false }
    guard confirmed else { return false }
    entries[profileID]?.status.inputAllowed = true
    entries[profileID]?.status.identity = identity
    entries[profileID]?.status.lastUpdatedAt = environment.now()
    return true
  }

  /// 心跳循环。返回 true 表示被取消/代次失效，false 表示健康检查判定失联。
  private func runHeartbeatLoop(
    profileID: UUID,
    generation: UInt64,
    profile: MachineProfile
  ) async -> Bool {
    while !Task.isCancelled {
      await environment.sleep(policy.heartbeatInterval)
      guard accepts(profileID: profileID, generation: generation) else { return true }
      let responded = await driver.heartbeat(profile: profile, generation: generation)
      guard accepts(profileID: profileID, generation: generation) else { return true }
      if responded {
        entries[profileID]?.status.missedHeartbeats = 0
        entries[profileID]?.status.lastUpdatedAt = environment.now()
        continue
      }
      let missed = (entries[profileID]?.status.missedHeartbeats ?? 0) + 1
      entries[profileID]?.status.missedHeartbeats = missed
      if missed >= policy.heartbeatMissTolerance { return false }
    }
    return true
  }

  // MARK: - 状态变更

  private func apply(outcome: MachineConnectionOutcome, profileID: UUID) {
    switch outcome {
    case .connected(let identity):
      entries[profileID]?.status.state = .online
      entries[profileID]?.status.identity = identity
      entries[profileID]?.status.failureCount = 0
      entries[profileID]?.status.missedHeartbeats = 0
      entries[profileID]?.status.reason = nil
      entries[profileID]?.status.lastUpdatedAt = environment.now()
      // 身份拿到了，但快照还没确认，所以此刻仍然不放行输入。
      entries[profileID]?.status.inputAllowed = false

    case .transient(let reason):
      markTransient(profileID: profileID, reason: reason)

    case .needsExplicitSetup(_, let reason):
      entries[profileID]?.status.state = .attention
      entries[profileID]?.status.inputAllowed = false
      entries[profileID]?.status.reason = reason
      entries[profileID]?.status.lastUpdatedAt = environment.now()
    }
  }

  private func markTransient(profileID: UUID, reason: String) {
    entries[profileID]?.status.state = .reconnecting
    entries[profileID]?.status.inputAllowed = false
    entries[profileID]?.status.failureCount += 1
    entries[profileID]?.status.reason = reason
    entries[profileID]?.status.lastUpdatedAt = environment.now()
  }

  private func markReconnecting(profileID: UUID) {
    entries[profileID]?.status.state = .reconnecting
    entries[profileID]?.status.inputAllowed = false
    entries[profileID]?.status.missedHeartbeats = 0
    entries[profileID]?.status.failureCount = 1
    entries[profileID]?.status.reason = "heartbeat timeout"
    entries[profileID]?.status.lastUpdatedAt = environment.now()
  }

  private func setDisabled(profile: MachineProfile) {
    entries[profile.id]?.task?.cancel()
    let generation = bumpGeneration(for: profile.id)
    entries[profile.id] = Entry(
      profile: profile,
      status: MachineConnectionStatus(
        profileID: profile.id,
        state: .disabled,
        generation: generation,
        lastUpdatedAt: environment.now()
      ),
      task: nil
    )
  }

  /// 递增取消代次并取消旧任务。所有会让旧结果失效的动作都必须经过这里。
  @discardableResult
  private func bumpGeneration(for profileID: UUID) -> UInt64 {
    let next = (entries[profileID]?.status.generation ?? 0) &+ 1
    entries[profileID]?.task?.cancel()
    entries[profileID]?.task = nil
    entries[profileID]?.status.generation = next
    return next
  }
}
