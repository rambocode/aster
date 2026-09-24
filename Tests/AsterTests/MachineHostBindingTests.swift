import AsterCore
import Foundation
import Testing
import os

@testable import Aster

// 「机器绑定已保存主机」的 App 侧测试：添加机器带 hostID、target 生成、link.state 接入连接编排。
// 全部用私有临时配置与假服务，不碰用户真实配置、钥匙串与网络。

/// 只实现旧签名的假服务：证明协议扩展的 hostID 缺省实现能让旧替身继续工作。
private final class RecordingFleetServices: MachineFleetServices, Sendable {
  private let targets = OSAllocatedUnfairLock<[String]>(initialState: [])

  var setupTargets: [String] { targets.withLock { $0 } }

  func runSetup(rawTarget: String, label: String, sessionName: String, profileID: UUID)
    async throws -> RemoteSetupOutcome
  {
    targets.withLock { $0.append(rawTarget) }
    return .ready(
      profile: MachineProfile(
        id: profileID, label: label, sshTarget: rawTarget, sessionName: sessionName,
        remoteBinaryPath: "/usr/local/bin/aster-session", stateParentPath: "/root/.local/state/aster"),
      identity: MachineFleetFixtures.identity,
      report: MachineFleetFixtures.report)
  }

  func registry(for profile: MachineProfile) throws -> MachineRegistryAccess {
    throw ManagedSessionError.runtimeUnavailable("测试不提供注册表传输")
  }
}

/// 一直在线的驱动：配合 link.state 用例观察状态被投递与重连。
private struct OnlineDriver: MachineConnectionDriving {
  func connect(profile: MachineProfile, generation: UInt64) async -> MachineConnectionOutcome {
    .connected(MachineFleetFixtures.identity)
  }
  func heartbeat(profile: MachineProfile, generation: UInt64) async -> Bool { true }
  func confirmSnapshot(profile: MachineProfile, generation: UInt64) async -> Bool { true }
}

@MainActor
private func makeBindingFleet(
  services: RecordingFleetServices = RecordingFleetServices(),
  driver: any MachineConnectionDriving = OnlineDriver(),
  hostTarget: @escaping (UUID) throws -> String
) -> (MachineFleetModel, URL) {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AsterMachineHostBinding.\(UUID().uuidString)")
    .appendingPathComponent("machines.json")
  let fleet = MachineFleetModel(
    store: MachineProfileStore(fileURL: url),
    services: services,
    supervisor: MachineConnectionSupervisor(
      environment: MachineConnectionEnvironment(
        sleep: { _ in try? await Task.sleep(for: .milliseconds(5)) }, jitter: { 0 }),
      driver: driver),
    localStateProvider: { .online },
    localErrorProvider: { nil },
    hostTarget: hostTarget)
  return (fleet, url)
}

@MainActor
@Test("添加机器绑定主机：target 取主机连接串，配置与行都带 hostID")
func machineHostBindingAddMachineStoresHostID() async throws {
  let hostID = UUID()
  let services = RecordingFleetServices()
  let (fleet, url) = makeBindingFleet(services: services) { id in
    #expect(id == hostID)
    return "deploy@10.0.0.5"
  }
  defer {
    fleet.stop()
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }

  let result = await fleet.addMachine(
    label: "lab", sshTarget: "ignored-manual-text", sessionName: "work", hostID: hostID,
    confirm: { _ in true })
  guard case .added(let profile) = result else {
    Issue.record("添加应成功，实际：\(result)")
    return
  }
  #expect(services.setupTargets == ["deploy@10.0.0.5"])
  #expect(profile.hostID == hostID)
  #expect(profile.sshTarget == "deploy@10.0.0.5")
  #expect(fleet.rows.last?.hostID == hostID)
  #expect(try MachineProfileStore(fileURL: url).load() == .loaded([profile]))
}

@MainActor
@Test("添加机器绑定主机：主机无法解析时直接失败，不做任何网络动作")
func machineHostBindingAddMachineFailsForUnknownHost() async throws {
  let services = RecordingFleetServices()
  let (fleet, url) = makeBindingFleet(services: services) { id in
    throw SSHHostResolutionError.unknownHost(id)
  }
  defer {
    fleet.stop()
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }
  let result = await fleet.addMachine(
    label: "lab", sshTarget: "", sessionName: "work", hostID: UUID(), confirm: { _ in true })
  guard case .failed = result else {
    Issue.record("应失败，实际：\(result)")
    return
  }
  #expect(services.setupTargets.isEmpty)
  #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test("主机 → OpenSSH target：端口 22 用 user@host，其它端口与 IPv6 用 ssh:// URI，并继承默认项")
func machineHostBindingOpenSSHTarget() throws {
  var defaults = SSHHostProfile.emptyDefaults()
  defaults.user = "ops"
  let plain = SSHHostProfile(name: "a", host: "10.0.0.5", user: "deploy")
  let custom = SSHHostProfile(name: "b", host: "orb.local", port: 32222, user: "root")
  let inherited = SSHHostProfile(name: "c", host: "build")
  let ipv6 = SSHHostProfile(name: "d", host: "fe80::1", user: "root")
  let hosts = [defaults, plain, custom, inherited, ipv6]

  #expect(try MachineFleetModel.openSSHTarget(forHost: plain.id, in: hosts) == "deploy@10.0.0.5")
  #expect(
    try MachineFleetModel.openSSHTarget(forHost: custom.id, in: hosts)
      == "ssh://root@orb.local:32222")
  #expect(try MachineFleetModel.openSSHTarget(forHost: inherited.id, in: hosts) == "ops@build")
  #expect(try MachineFleetModel.openSSHTarget(forHost: ipv6.id, in: hosts) == "ssh://root@[fe80::1]")
  // 生成的文本必须能通过 target 前置校验，OpenSSH 回退路径才连得上。
  for host in [plain, custom, inherited, ipv6] {
    _ = try RemoteSSHTarget.parse(try MachineFleetModel.openSSHTarget(forHost: host.id, in: hosts))
  }
  #expect(throws: SSHHostResolutionError.self) {
    try MachineFleetModel.openSSHTarget(forHost: UUID(), in: hosts)
  }
}

@MainActor
@Test("link.state：需要用户处理的失败立即进入 attention；链路恢复后立即重连")
func machineHostBindingLinkStateDrivesSupervisor() async throws {
  let hostID = UUID()
  let (fleet, url) = makeBindingFleet { _ in "deploy@10.0.0.5" }
  defer {
    fleet.stop()
    try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
  }
  guard
    case .added(let profile) = await fleet.addMachine(
      label: "lab", sshTarget: "", sessionName: "work", hostID: hostID, confirm: { _ in true })
  else {
    Issue.record("添加应成功")
    return
  }
  func state() async -> SessionConnectionState? {
    await fleet.refreshStatuses()
    return fleet.statuses[profile.id]?.state
  }
  func waitFor(_ expected: SessionConnectionState) async -> Bool {
    for _ in 0..<200 {
      if await state() == expected { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return false
  }
  #expect(await waitFor(.online))

  // 按 target 匹配不到绑定主机的机器；瞬时失败也不投递。
  fleet.handleLinkState(
    SSHLinkStateEvent(
      endpoint: "deploy@10.0.0.5:22", target: "deploy@10.0.0.5", state: .failed,
      errorKind: .hostKeyChanged, detail: "changed"))
  fleet.handleLinkState(
    SSHLinkStateEvent(
      endpoint: "deploy@10.0.0.5:22", hostID: hostID, state: .failed, errorKind: .hostUnreachable))
  try await Task.sleep(for: .milliseconds(100))
  #expect(await state() == .online)

  fleet.handleLinkState(
    SSHLinkStateEvent(
      endpoint: "deploy@10.0.0.5:22", hostID: hostID, state: .failed, errorKind: .hostKeyChanged,
      detail: "host key changed"))
  #expect(await waitFor(.attention))
  #expect(fleet.statuses[profile.id]?.reason == "host key changed")

  fleet.handleLinkState(
    SSHLinkStateEvent(endpoint: "deploy@10.0.0.5:22", hostID: hostID, state: .connected))
  #expect(await waitFor(.online))
}
