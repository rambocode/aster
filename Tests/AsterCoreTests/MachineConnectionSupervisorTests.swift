import Foundation
import Testing

@testable import AsterCore

/// P4.4：独立连接任务、取消代次、退避、心跳与 attention（A14）。
///
/// 全部使用虚拟时钟：`sleep` 只记录逻辑时长并推进逻辑时间，不真正等待，
/// 因此退避表与心跳节奏可以被精确断言。

/// 虚拟时钟。记录每次等待的秒数并推进逻辑当前时间。
private final class VirtualClock: @unchecked Sendable {
  private let lock = NSLock()
  private var current = Date(timeIntervalSince1970: 1_700_000_000)
  private var waits: [TimeInterval] = []

  var recordedWaits: [TimeInterval] {
    lock.lock()
    defer { lock.unlock() }
    return waits
  }

  var now: Date {
    lock.lock()
    defer { lock.unlock() }
    return current
  }

  func advance(_ seconds: TimeInterval) {
    lock.lock()
    waits.append(seconds)
    current = current.addingTimeInterval(seconds)
    lock.unlock()
  }

  /// 抖动固定为 0，让断言可以对上退避表的精确值。
  func environment() -> MachineConnectionEnvironment {
    MachineConnectionEnvironment(
      now: { [self] in now },
      sleep: { [self] seconds in
        advance(seconds)
        await Task.yield()
      },
      jitter: { 0 }
    )
  }
}

/// 按脚本返回结果的连接驱动。
private final class ScriptedConnectionDriver: MachineConnectionDriving, @unchecked Sendable {
  private let lock = NSLock()
  private var connectScript: [MachineConnectionOutcome]
  private var heartbeatScript: [Bool]
  var snapshotConfirmed: Bool
  /// 脚本用完之后的心跳默认值。要让连接一直保持在线时设为 true。
  private let defaultHeartbeat: Bool
  private(set) var connectCalls = 0

  init(
    connect: [MachineConnectionOutcome],
    heartbeat: [Bool] = [],
    defaultHeartbeat: Bool = false,
    snapshotConfirmed: Bool = true
  ) {
    self.connectScript = connect
    self.heartbeatScript = heartbeat
    self.defaultHeartbeat = defaultHeartbeat
    self.snapshotConfirmed = snapshotConfirmed
  }

  func connect(profile: MachineProfile, generation: UInt64) async -> MachineConnectionOutcome {
    nextConnect()
  }

  func heartbeat(profile: MachineProfile, generation: UInt64) async -> Bool {
    nextHeartbeat()
  }

  /// 取脚本的同步实现。NSLock 不能在 async 上下文里直接用，所以锁操作留在同步方法内。
  private func nextConnect() -> MachineConnectionOutcome {
    lock.lock()
    defer { lock.unlock() }
    connectCalls += 1
    return connectScript.isEmpty
      ? .needsExplicitSetup(kind: nil, reason: "script exhausted")
      : connectScript.removeFirst()
  }

  private func nextHeartbeat() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    return heartbeatScript.isEmpty ? defaultHeartbeat : heartbeatScript.removeFirst()
  }

  func confirmSnapshot(profile: MachineProfile, generation: UInt64) async -> Bool {
    snapshotConfirmed
  }
}

private func remoteProfile(label: String = "Build box") -> MachineProfile {
  MachineProfile(label: label, sshTarget: "root@ubuntu@orb", sessionName: "work", enabled: true)
}

/// 轮询直到状态满足条件；虚拟时钟不真正等待，所以几次 yield 就能收敛。
private func waitForState(
  _ supervisor: MachineConnectionSupervisor,
  profileID: UUID,
  _ predicate: @Sendable (MachineConnectionStatus) -> Bool
) async -> MachineConnectionStatus? {
  for _ in 0..<2000 {
    if let status = await supervisor.status(profileID: profileID), predicate(status) {
      return status
    }
    await Task.yield()
  }
  return await supervisor.status(profileID: profileID)
}

// MARK: - 策略数值

@Test func remoteWorkP4PolicyUsesSpecifiedNumbers() {
  let policy = MachineConnectionPolicy()
  #expect(policy.connectTimeout == 10)
  #expect(policy.handshakeTimeout == 5)
  #expect(policy.backoffSchedule == [1, 2, 4, 8, 16, 30])
  #expect(policy.backoffJitterFraction == 0.2)
  #expect(policy.heartbeatInterval == 15)
  #expect(policy.heartbeatMissTolerance == 3)
}

@Test func remoteWorkP4BackoffTableAndJitterAreExact() {
  let policy = MachineConnectionPolicy()
  #expect((0..<6).map { policy.baseBackoff(attempt: $0) } == [1, 2, 4, 8, 16, 30])
  // 超出表长后固定用最后一档，不继续翻倍。
  #expect(policy.baseBackoff(attempt: 99) == 30)
  // ±20% 抖动。
  #expect(policy.backoffDelay(attempt: 0, jitter: 1) == 1.2)
  #expect(policy.backoffDelay(attempt: 0, jitter: -1) == 0.8)
  #expect(policy.backoffDelay(attempt: 4, jitter: 0) == 16)
  #expect(policy.backoffDelay(attempt: 5, jitter: 1) == 36)
  // 越界抖动被夹到 ±1，不会放大成任意倍数。
  #expect(policy.backoffDelay(attempt: 0, jitter: 5) == 1.2)
}

@Test func remoteWorkP4SSHFailureKindDecidesAttentionVersusBackoff() {
  #expect(
    MachineConnectionOutcome.from(sshKind: .hostKeyUnknown, detail: "d")
      == .needsExplicitSetup(kind: .hostKeyUnknown, reason: "d"))
  #expect(
    MachineConnectionOutcome.from(sshKind: .authenticationRequired, detail: "d")
      == .needsExplicitSetup(kind: .authenticationRequired, reason: "d"))
  #expect(
    MachineConnectionOutcome.from(sshKind: .remoteCommandMissing, detail: "d")
      == .needsExplicitSetup(kind: .remoteCommandMissing, reason: "d"))
  #expect(
    MachineConnectionOutcome.from(sshKind: .hostUnreachable, detail: "d")
      == .transient(reason: "d"))
  #expect(MachineConnectionOutcome.from(sshKind: .timeout, detail: "d") == .transient(reason: "d"))
}

// MARK: - 退避与心跳

@Test func remoteWorkP4TransientFailuresFollowBackoffTable() async {
  let clock = VirtualClock()
  let driver = ScriptedConnectionDriver(connect: [
    .transient(reason: "unreachable"),
    .transient(reason: "unreachable"),
    .transient(reason: "unreachable"),
    .needsExplicitSetup(kind: .hostKeyUnknown, reason: "host key unknown"),
  ])
  let supervisor = MachineConnectionSupervisor(
    environment: clock.environment(), driver: driver)
  let profile = remoteProfile()

  await supervisor.start(profile: profile)
  let status = await waitForState(supervisor, profileID: profile.id) { $0.state == .attention }

  #expect(status?.state == .attention)
  #expect(status?.reason == "host key unknown")
  // 三次可重试失败 → 退避 1、2、4 秒（抖动为 0）。
  #expect(clock.recordedWaits == [1, 2, 4])
}

@Test func remoteWorkP4ThreeMissedHeartbeatsTriggerReconnect() async {
  let clock = VirtualClock()
  let driver = ScriptedConnectionDriver(
    connect: [
      .connected(
        SessionServerIdentity(
          reference: P4Fixtures.server, serverEpoch: P4Fixtures.serverEpoch,
          capabilities: ["health_check"], version: "0.1.0")),
      .needsExplicitSetup(kind: nil, reason: "stop here"),
    ],
    heartbeat: [true, false, false, false]
  )
  let supervisor = MachineConnectionSupervisor(
    environment: clock.environment(), driver: driver)
  let profile = remoteProfile()

  await supervisor.start(profile: profile)
  _ = await waitForState(supervisor, profileID: profile.id) { $0.state == .attention }

  // 4 次心跳间隔 15 秒（1 次成功 + 3 次未响应），之后按退避表第一档重连。
  #expect(clock.recordedWaits == [15, 15, 15, 15, 1])
  #expect(driver.connectCalls == 2)
}

@Test func remoteWorkP4AttentionDoesNotRetryInBackground() async {
  let clock = VirtualClock()
  let driver = ScriptedConnectionDriver(connect: [
    .needsExplicitSetup(kind: .authenticationRequired, reason: "interactive auth required")
  ])
  let supervisor = MachineConnectionSupervisor(
    environment: clock.environment(), driver: driver)
  let profile = remoteProfile()

  await supervisor.start(profile: profile)
  _ = await waitForState(supervisor, profileID: profile.id) { $0.state == .attention }
  for _ in 0..<50 { await Task.yield() }

  // attention 需要用户显式处理：后台不重连、不重启服务、不自动安装。
  #expect(driver.connectCalls == 1)
  #expect(clock.recordedWaits.isEmpty)
}

// MARK: - 代次与输入

@Test func remoteWorkP4StaleGenerationResultsAreDropped() async {
  let clock = VirtualClock()
  let driver = ScriptedConnectionDriver(connect: [
    .needsExplicitSetup(kind: .hostKeyUnknown, reason: "host key unknown")
  ])
  let supervisor = MachineConnectionSupervisor(
    environment: clock.environment(), driver: driver)
  let profile = remoteProfile()

  await supervisor.start(profile: profile)
  _ = await waitForState(supervisor, profileID: profile.id) { $0.state == .attention }
  let generation = await supervisor.currentGeneration(profileID: profile.id)

  // 注入一个旧代次的回调：结果必须被完整丢弃，状态一个字段都不变。
  let accepted = await supervisor.deliver(
    profileID: profile.id, generation: generation &- 1,
    outcome: .connected(
      SessionServerIdentity(
        reference: P4Fixtures.server, serverEpoch: P4Fixtures.serverEpoch,
        capabilities: [], version: "0.1.0")))
  #expect(accepted == false)
  let status = await supervisor.status(profileID: profile.id)
  #expect(status?.state == .attention)
  #expect(status?.identity == nil)
  #expect(await supervisor.droppedStaleResults >= 1)

  // 当前代次的结果正常应用。
  #expect(
    await supervisor.deliver(
      profileID: profile.id, generation: generation, outcome: .transient(reason: "later")))
  #expect(await supervisor.status(profileID: profile.id)?.state == .reconnecting)
}

@Test func remoteWorkP4RestartBumpsGeneration() async {
  let clock = VirtualClock()
  let driver = ScriptedConnectionDriver(connect: [
    .needsExplicitSetup(kind: nil, reason: "a"),
    .needsExplicitSetup(kind: nil, reason: "b"),
  ])
  let supervisor = MachineConnectionSupervisor(
    environment: clock.environment(), driver: driver)
  let profile = remoteProfile()

  await supervisor.start(profile: profile)
  let first = await supervisor.currentGeneration(profileID: profile.id)
  await supervisor.start(profile: profile)
  let second = await supervisor.currentGeneration(profileID: profile.id)
  #expect(second > first)
}

@Test func remoteWorkP4RenameDoesNotChangeGenerationOrState() async {
  let clock = VirtualClock()
  let driver = ScriptedConnectionDriver(connect: [
    .needsExplicitSetup(kind: nil, reason: "hold")
  ])
  let supervisor = MachineConnectionSupervisor(
    environment: clock.environment(), driver: driver)
  let profile = remoteProfile(label: "Old name")

  await supervisor.start(profile: profile)
  _ = await waitForState(supervisor, profileID: profile.id) { $0.state == .attention }
  let before = await supervisor.status(profileID: profile.id)

  await supervisor.rename(profileID: profile.id, label: "New name")
  let after = await supervisor.status(profileID: profile.id)

  // 重命名只改标签：代次、状态、连接全部保持不变，因此不会触发重连。
  #expect(after?.generation == before?.generation)
  #expect(after?.state == before?.state)
  #expect(driver.connectCalls == 1)
}

@Test func remoteWorkP4InputIsNotBufferedOrReplayedWhileOffline() async {
  let clock = VirtualClock()
  // 心跳一直有响应，连接保持在线，便于断言输入投递结果。
  let driver = ScriptedConnectionDriver(
    connect: [
      .connected(
        SessionServerIdentity(
          reference: P4Fixtures.server, serverEpoch: P4Fixtures.serverEpoch,
          capabilities: [], version: "0.1.0"))
    ],
    defaultHeartbeat: true
  )
  let supervisor = MachineConnectionSupervisor(
    environment: clock.environment(), driver: driver)
  let profile = remoteProfile()

  await supervisor.start(profile: profile)
  let status = await waitForState(supervisor, profileID: profile.id) {
    $0.state == .online && $0.inputAllowed
  }
  let generation = try! #require(status?.generation)

  // 身份与快照都校验通过后才放行输入。
  #expect(await supervisor.submitInput(profileID: profile.id, generation: generation) == .delivered)

  // 旧代次的输入结果未知：既不确认送达，也不自动重放。
  #expect(
    await supervisor.submitInput(profileID: profile.id, generation: generation &- 1)
      == .deliveryUnknown)

  // 断开后明确拒绝，不缓存断线期间的键入。
  await supervisor.disable(profileID: profile.id)
  let current = await supervisor.currentGeneration(profileID: profile.id)
  #expect(await supervisor.submitInput(profileID: profile.id, generation: current) == .rejected)
}

@Test func remoteWorkP4InputBlockedUntilSnapshotConfirmed() async {
  let clock = VirtualClock()
  let driver = ScriptedConnectionDriver(
    connect: [
      .connected(
        SessionServerIdentity(
          reference: P4Fixtures.server, serverEpoch: P4Fixtures.serverEpoch,
          capabilities: [], version: "0.1.0")),
      .needsExplicitSetup(kind: nil, reason: "stop"),
    ],
    snapshotConfirmed: false
  )
  let supervisor = MachineConnectionSupervisor(
    environment: clock.environment(), driver: driver)
  let profile = remoteProfile()

  await supervisor.start(profile: profile)
  _ = await waitForState(supervisor, profileID: profile.id) { $0.state == .attention }

  // 快照没确认就不放行输入，并按退避重连（不把「握手成功」当成「可以输入」）。
  #expect(clock.recordedWaits.first == 1)
  #expect(await supervisor.status(profileID: profile.id)?.inputAllowed == false)
}

@Test func remoteWorkP4OneMachineFailureDoesNotBlockAnother() async {
  let clock = VirtualClock()
  // 黑洞机器一直可重试失败；正常机器一次就连上。
  let blackHole = ScriptedConnectionDriver(connect: Array(repeating: .transient(reason: "blackhole"), count: 200))
  let healthy = ScriptedConnectionDriver(
    connect: [
      .connected(
        SessionServerIdentity(
          reference: P4Fixtures.server, serverEpoch: P4Fixtures.serverEpoch,
          capabilities: [], version: "0.1.0"))
    ],
    defaultHeartbeat: true
  )
  let blackHoleSupervisor = MachineConnectionSupervisor(
    environment: clock.environment(), driver: blackHole)
  let healthySupervisor = MachineConnectionSupervisor(
    environment: VirtualClock().environment(), driver: healthy)

  let stuck = remoteProfile(label: "Black hole")
  let good = remoteProfile(label: "Good")
  await blackHoleSupervisor.start(profile: stuck)
  await healthySupervisor.start(profile: good)

  // 失联机器仍在退避重连的同时，另一台照常上线。
  let status = await waitForState(healthySupervisor, profileID: good.id) {
    $0.state == .online && $0.inputAllowed
  }
  #expect(status?.state == .online)
  #expect(await blackHoleSupervisor.status(profileID: stuck.id)?.state == .reconnecting)
  await blackHoleSupervisor.remove(profileID: stuck.id)
  await healthySupervisor.remove(profileID: good.id)
}

@Test func remoteWorkP4DisableAndRemoveWorkWhileOffline() async {
  let clock = VirtualClock()
  let driver = ScriptedConnectionDriver(connect: Array(repeating: .transient(reason: "down"), count: 100))
  let supervisor = MachineConnectionSupervisor(
    environment: clock.environment(), driver: driver)
  let profile = remoteProfile()

  await supervisor.start(profile: profile)
  _ = await waitForState(supervisor, profileID: profile.id) { $0.state == .reconnecting }

  // 离线也能禁用：只断开该配置，不停止远端服务（本层不会发出任何停止动作）。
  await supervisor.disable(profileID: profile.id)
  #expect(await supervisor.status(profileID: profile.id)?.state == .disabled)

  await supervisor.remove(profileID: profile.id)
  #expect(await supervisor.status(profileID: profile.id) == nil)
}

@Test func remoteWorkP4DisabledProfileNeverConnects() async {
  let clock = VirtualClock()
  let driver = ScriptedConnectionDriver(connect: [.transient(reason: "should not run")])
  let supervisor = MachineConnectionSupervisor(
    environment: clock.environment(), driver: driver)
  var profile = remoteProfile()
  profile.enabled = false

  await supervisor.start(profile: profile)
  for _ in 0..<20 { await Task.yield() }
  #expect(await supervisor.status(profileID: profile.id)?.state == .disabled)
  #expect(driver.connectCalls == 0)
}
