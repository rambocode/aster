import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// P7 A21 验证：IPC 写权限关闭拒绝远端写入、目标歧义拒绝、CLI 显式定位不受 GUI 影响。
///
/// 三组用例覆盖三条安全需求：
///   Item 5 — allowSendKeys=false 时，所有 pane/agent 写操作和机器写操作都被拒绝。
///   Item 6 — 两份配置标签相同时，resolve 返回 nil → notFound，拒绝写入。
///   Item 7 — dispatcher 的 resolveMachine 只从请求参数取目标，不读 GUI activeMachineID。
@Suite(.serialized)
@MainActor
struct RemoteWorkP7IPCTargetTests {

  // MARK: - 共享夹具

  private final class StubServices: MachineFleetServices, @unchecked Sendable {
    func runSetup(rawTarget: String, label: String, sessionName: String, profileID: UUID)
      async throws -> RemoteSetupOutcome
    {
      .ready(
        profile: MachineProfile(
          id: profileID, label: label, sshTarget: rawTarget, sessionName: sessionName),
        identity: MachineFleetFixtures.identity,
        report: MachineFleetFixtures.report)
    }

    func registry(for profile: MachineProfile) throws -> MachineRegistryAccess {
      throw ManagedSessionError.runtimeUnavailable("测试不提供注册表传输")
    }
  }

  private struct SilentDriver: MachineConnectionDriving {
    func connect(profile: MachineProfile, generation: UInt64) async -> MachineConnectionOutcome {
      .needsExplicitSetup(kind: nil, reason: "测试驱动不连接")
    }
    func heartbeat(profile: MachineProfile, generation: UInt64) async -> Bool { false }
    func confirmSnapshot(profile: MachineProfile, generation: UInt64) async -> Bool { false }
  }

  private final class PolicyBox {
    var policy = AsterControlDispatcher.Policy(
      allowSendKeys: true, allowSensitiveSessions: false, shell: AsterConfiguration().shell)
  }

  @MainActor
  private struct Fixture {
    let workspace: ControlTestWorkspace
    let dispatcher: AsterControlDispatcher
    let client: ControlFakeClient
    let fleet: MachineFleetModel
    let configURL: URL
    let policyBox: PolicyBox

    /// 发送一条控制协议请求并返回响应。
    func call(_ method: String, _ params: JSONValue? = nil) async -> AsterControlResponse {
      await dispatcher.handle(controlRequest(method, params), client: client)
    }
  }

  private func makeFixture(allowSendKeys: Bool = true, allowSensitiveSessions: Bool = false)
    throws -> Fixture
  {
    let workspace = try ControlTestWorkspace()
    let bridge = AsterControlBridge(socketPath: "/tmp/test.sock", binaryPath: "/tmp/aster-cli")
    bridge.activeModelProvider = { [weak model = workspace.model] in model }
    bridge.attach(model: workspace.model)
    let box = PolicyBox()
    box.policy.allowSendKeys = allowSendKeys
    box.policy.allowSensitiveSessions = allowSensitiveSessions
    let dispatcher = AsterControlDispatcher(bridge: bridge, version: "9.9.9") { box.policy }
    dispatcher.promptStallMilliseconds = 500
    dispatcher.startSettleMilliseconds = 100

    let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("AsterP7IPCTargetTests.\(UUID().uuidString)")
      .appendingPathComponent("machines.json")
    let fleet = MachineFleetModel(
      store: MachineProfileStore(fileURL: configURL),
      services: StubServices(),
      supervisor: MachineConnectionSupervisor(
        environment: MachineConnectionEnvironment(
          sleep: { _ in await Task.yield() }, jitter: { 0 }),
        driver: SilentDriver()),
      localStateProvider: { .online },
      localErrorProvider: { nil })
    MachineFleetModel.shared = fleet

    return Fixture(
      workspace: workspace, dispatcher: dispatcher, client: ControlFakeClient(),
      fleet: fleet, configURL: configURL, policyBox: box)
  }

  private func tearDown(_ fixture: Fixture) {
    fixture.fleet.stop()
    fixture.workspace.tearDown()
    try? FileManager.default.removeItem(at: fixture.configURL.deletingLastPathComponent())
  }

  // MARK: - Item 5: IPC 写门禁 (allowSendKeys=false)

  @Test("WriteGate 直接测试：allowSendKeys=false → writeNotAllowed")
  func writeGateBlocksWhenAllowSendKeysOff() async throws {
    let fixture = try makeFixture(allowSendKeys: false)
    defer { tearDown(fixture) }
    let session = try #require(fixture.workspace.model.selectedTab?.activeSession)
    let blocker = AsterControlWriteGate.blocker(
      session: session, allowSendKeys: false, allowSensitiveSessions: true)
    #expect(blocker?.code == .writeNotAllowed)
  }

  @Test("paneSendText 经 dispatcher 写门禁：allowSendKeys=false → writeNotAllowed")
  func paneSendTextRejectedByDispatcher() async throws {
    let fixture = try makeFixture(allowSendKeys: false)
    defer { tearDown(fixture) }
    let (_, _) = try fixture.workspace.makeActiveTerminalView()

    let response = await fixture.call(
      "pane.send_text", .object(["pane": .string("w1:p1"), "text": .string("hello")]))
    #expect(response.error?.code == .writeNotAllowed)
  }

  @Test("paneSendKeys 经 dispatcher 写门禁：allowSendKeys=false → writeNotAllowed")
  func paneSendKeysRejectedByDispatcher() async throws {
    let fixture = try makeFixture(allowSendKeys: false)
    defer { tearDown(fixture) }
    let (_, _) = try fixture.workspace.makeActiveTerminalView()

    let response = await fixture.call(
      "pane.send_keys", .object(["pane": .string("w1:p1"), "keys": .array([.string("enter")])]))
    #expect(response.error?.code == .writeNotAllowed)
  }

  @Test("agentSendKeys 经 dispatcher 写门禁：allowSendKeys=false → writeNotAllowed")
  func agentSendKeysRejectedByDispatcher() async throws {
    let fixture = try makeFixture(allowSendKeys: false)
    defer { tearDown(fixture) }
    let (_, view) = try fixture.workspace.makeActiveTerminalView()
    // 注入 agent 状态以便 agent 可被定位
    view.onAgentTerminalDirective?(
      AgentTerminalDirective(provider: .codex, signal: .processing, sessionID: "s1"))
    await pumpControlEvents()

    let response = await fixture.call(
      "agent.send_keys", .object(["target": .string("codex"), "keys": .array([.string("enter")])]))
    #expect(response.error?.code == .writeNotAllowed)
  }

  @Test("机器写方法同样遵守 allowSendKeys=false 门禁；只读方法不受影响")
  func machineWriteMethodsRejectedWhenWriteGateOff() async throws {
    let fixture = try makeFixture(allowSendKeys: false)
    defer { tearDown(fixture) }

    let response = await fixture.call(
      "machine.rename", .object(["machine": .string("x"), "label": .string("y")]))
    #expect(response.error?.code == .writeNotAllowed)

    let listResponse = await fixture.call("machine.list")
    #expect(listResponse.error == nil)
  }

  @Test("显示桥路径同样经过门禁：pane.send_text / pane.send_keys 走 dispatcher.gate()")
  func displayBridgePathAlsoGated() async throws {
    // 证明 `aster pane send-text` 经 dispatcher 分发调用 gate()，
    // gate() 内部调用 AsterControlWriteGate.blocker()，没有绕过路径。
    let fixture = try makeFixture(allowSendKeys: false)
    defer { tearDown(fixture) }
    let (_, _) = try fixture.workspace.makeActiveTerminalView()

    let sendText = await fixture.call(
      "pane.send_text", .object(["pane": .string("w1:p1"), "text": .string("ls")]))
    #expect(sendText.error?.code == .writeNotAllowed)

    let sendKeys = await fixture.call(
      "pane.send_keys", .object(["pane": .string("w1:p1"), "keys": .array([.string("enter")])]))
    #expect(sendKeys.error?.code == .writeNotAllowed)
  }

  // MARK: - Item 6: 目标歧义 (两个配置同标签 → 拒绝)

  @Test("两份配置标签相同 → resolve 返回 nil → 写方法报 notFound")
  func ambiguousLabelRejectsWrite() async throws {
    let fixture = try makeFixture()
    defer { tearDown(fixture) }
    _ = await fixture.fleet.addMachine(
      label: "server", sshTarget: "root@host-a", sessionName: "work", confirm: { _ in true })
    _ = await fixture.fleet.addMachine(
      label: "server", sshTarget: "root@host-b", sessionName: "work", confirm: { _ in true })

    let response = await fixture.call(
      "machine.disable", .object(["machine": .string("server")]))
    #expect(response.error?.code == .ambiguousTarget)
  }

  @Test("按 UUID 显式指定则不受标签歧义影响")
  func explicitUUIDBypassesAmbiguity() async throws {
    let fixture = try makeFixture()
    defer { tearDown(fixture) }
    guard case .added(let profileA) = await fixture.fleet.addMachine(
      label: "server", sshTarget: "root@host-a", sessionName: "work", confirm: { _ in true })
    else {
      Issue.record("添加第一台失败")
      return
    }
    _ = await fixture.fleet.addMachine(
      label: "server", sshTarget: "root@host-b", sessionName: "work", confirm: { _ in true })

    let response = await fixture.call(
      "machine.disable", .object(["machine": .string(profileA.id.uuidString)]))
    #expect(response.error == nil)
    #expect(response.result?["enabled"] == .bool(false))
  }

  @Test("MachineFleetModel.resolve 单元测试：单个匹配返回 profile、多个返回 nil")
  func resolveReturnsNilOnDuplicateLabels() async throws {
    let fixture = try makeFixture()
    defer { tearDown(fixture) }
    guard case .added(let profileA) = await fixture.fleet.addMachine(
      label: "dup", sshTarget: "root@a", sessionName: "s1", confirm: { _ in true })
    else {
      Issue.record("添加失败")
      return
    }
    #expect(fixture.fleet.resolve(idOrLabel: "dup")?.id == profileA.id)

    _ = await fixture.fleet.addMachine(
      label: "dup", sshTarget: "root@b", sessionName: "s2", confirm: { _ in true })

    // 两个 "dup" → resolve 返回 nil
    #expect(fixture.fleet.resolve(idOrLabel: "dup") == nil)

    // "local" 始终可解析
    #expect(fixture.fleet.resolve(idOrLabel: "local") != nil)
  }

  // MARK: - Item 7: CLI 显式定位不受 GUI 活动机器影响

  @Test("dispatcher 按请求参数定位机器，不读 GUI 活动机器状态")
  func cliTargetNotAffectedByGUIActiveMachine() async throws {
    let fixture = try makeFixture()
    defer { tearDown(fixture) }
    guard case .added(_) = await fixture.fleet.addMachine(
      label: "machine-a", sshTarget: "root@host-a", sessionName: "work",
      confirm: { _ in true })
    else {
      Issue.record("添加 A 失败")
      return
    }
    guard case .added(_) = await fixture.fleet.addMachine(
      label: "machine-b", sshTarget: "root@host-b", sessionName: "dev",
      confirm: { _ in true })
    else {
      Issue.record("添加 B 失败")
      return
    }

    // GUI 切换到 machine-b
    fixture.fleet.selectMachine(fixture.fleet.rows.last!.id)

    // CLI 按标签定位 machine-a：不受 GUI 选中的 machine-b 影响
    let response = await fixture.call(
      "machine.disable", .object(["machine": .string("machine-a")]))
    #expect(response.error == nil)
    #expect(response.result?["label"]?.stringValue == "machine-a")
    #expect(response.result?["enabled"] == .bool(false))

    // 验证 machine-b 未被影响（仍然 enabled）
    let listResponse = await fixture.call("machine.list")
    guard case .array(let machines)? = listResponse.result?["machines"] else {
      Issue.record("machines 应为数组")
      return
    }
    let machineB = machines.first { $0["label"]?.stringValue == "machine-b" }
    #expect(machineB?["enabled"] == .bool(true))
  }

  @Test("请求里不带 machine 参数 → 直接报错，不回落到 GUI 选中项")
  func emptyMachineTargetDoesNotFallBackToGUISelection() async throws {
    let fixture = try makeFixture()
    defer { tearDown(fixture) }
    _ = await fixture.fleet.addMachine(
      label: "any-machine", sshTarget: "root@host", sessionName: "work",
      confirm: { _ in true })

    // GUI 有选中项
    fixture.fleet.selectMachine(fixture.fleet.rows.last!.id)

    // 请求 machine 为空 → 应该报错
    let empty = await fixture.call("machine.disable", .object(["machine": .string("")]))
    #expect(empty.error?.code == .invalidParams)
  }
}
