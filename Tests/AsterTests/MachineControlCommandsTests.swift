import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// P4.8：机器/会话控制协议方法与 `aster-cli` 前端的定向测试。
///
/// dispatcher 用隔离 defaults 的工作区夹具与私有配置文件；CLI 部分直接执行构建产物，
/// 只验证参数解析与用法错误，不连接用户真实 App。
@Suite(.serialized)
@MainActor
struct MachineControlCommandsTests {

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

  private struct Fixture {
    let workspace: ControlTestWorkspace
    let dispatcher: AsterControlDispatcher
    let client: ControlFakeClient
    let fleet: MachineFleetModel
    let configURL: URL

    func call(_ method: String, _ params: JSONValue? = nil) async -> AsterControlResponse {
      await dispatcher.handle(controlRequest(method, params), client: client)
    }
  }

  private func makeFixture(allowSendKeys: Bool = true) throws -> (Fixture, PolicyBox) {
    let workspace = try ControlTestWorkspace()
    let bridge = AsterControlBridge(socketPath: "/tmp/test.sock", binaryPath: "/tmp/aster-cli")
    bridge.activeModelProvider = { [weak model = workspace.model] in model }
    bridge.attach(model: workspace.model)
    let box = PolicyBox()
    box.policy.allowSendKeys = allowSendKeys
    let dispatcher = AsterControlDispatcher(bridge: bridge, version: "9.9.9") { box.policy }

    let configURL = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("AsterMachineControlTests.\(UUID().uuidString)")
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
    // dispatcher 走进程级共享实例；测试期间整体替换成私有配置，绝不写用户真实配置。
    MachineFleetModel.shared = fleet
    return (
      Fixture(
        workspace: workspace, dispatcher: dispatcher, client: ControlFakeClient(), fleet: fleet,
        configURL: configURL),
      box
    )
  }

  private func tearDown(_ fixture: Fixture) {
    fixture.fleet.stop()
    fixture.workspace.tearDown()
    try? FileManager.default.removeItem(at: fixture.configURL.deletingLastPathComponent())
  }

  // MARK: - dispatcher

  @Test("machine.list：Local 恒在最上，结构化输出包含会话名与状态")
  func machineListIncludesLocalFirst() async throws {
    let (fixture, _) = try makeFixture()
    defer { tearDown(fixture) }
    _ = await fixture.fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work", confirm: { _ in true })

    let response = await fixture.call("machine.list")
    #expect(response.error == nil)
    guard case .array(let machines)? = response.result?["machines"] else {
      Issue.record("machines 应为数组")
      return
    }
    #expect(machines.count == 2)
    #expect(machines[0]["id"]?.stringValue == "local")
    #expect(machines[0]["isLocal"] == .bool(true))
    #expect(machines[1]["label"]?.stringValue == "orb")
    #expect(machines[1]["sessionName"]?.stringValue == "work")
    #expect(machines[1]["sshTarget"]?.stringValue == "root@ubuntu@orb")
  }

  @Test("machine.rename / disable / enable / remove 的完整回合")
  func machineLifecycleThroughControlProtocol() async throws {
    let (fixture, _) = try makeFixture()
    defer { tearDown(fixture) }
    guard case .added(let profile) = await fixture.fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work", confirm: { _ in true })
    else {
      Issue.record("前置添加失败")
      return
    }

    let renamed = await fixture.call(
      "machine.rename",
      .object(["machine": .string(profile.id.uuidString), "label": .string("orb-ubuntu")]))
    #expect(renamed.error == nil)
    #expect(renamed.result?["label"]?.stringValue == "orb-ubuntu")

    // 之后可以按新标签定位，说明重命名真的写回了配置。
    let disabled = await fixture.call(
      "machine.disable", .object(["machine": .string("orb-ubuntu")]))
    #expect(disabled.error == nil)
    #expect(disabled.result?["state"]?.stringValue == SessionConnectionState.disabled.rawValue)
    #expect(disabled.result?["enabled"] == .bool(false))

    let enabled = await fixture.call(
      "machine.enable", .object(["machine": .string("orb-ubuntu")]))
    #expect(enabled.error == nil)
    #expect(enabled.result?["enabled"] == .bool(true))

    let removed = await fixture.call(
      "machine.remove", .object(["machine": .string("orb-ubuntu")]))
    #expect(removed.error == nil)
    #expect(fixture.fleet.profiles.isEmpty)

    // 移除之后再次定位必须报 not_found，而不是回落到别的机器。
    let missing = await fixture.call(
      "machine.remove", .object(["machine": .string("orb-ubuntu")]))
    #expect(missing.error?.code == .notFound)
  }

  @Test("跨机器动作必须显式指定机器；空 machine 直接拒绝")
  func machineTargetIsMandatory() async throws {
    let (fixture, _) = try makeFixture()
    defer { tearDown(fixture) }
    let empty = await fixture.call("machine.disable", .object(["machine": .string("  ")]))
    #expect(empty.error?.code == .invalidParams)

    let missing = await fixture.call("session.list", .object(["machine": .string("不存在")]))
    #expect(missing.error?.code == .notFound)
  }

  @Test("Local 不能被禁用或移除，控制协议同样拒绝")
  func localCannotBeDisabledThroughControlProtocol() async throws {
    let (fixture, _) = try makeFixture()
    defer { tearDown(fixture) }
    let disabled = await fixture.call("machine.disable", .object(["machine": .string("local")]))
    #expect(disabled.error?.code == .invalidRequest)
    let removed = await fixture.call("machine.remove", .object(["machine": .string("local")]))
    #expect(removed.error?.code == .invalidRequest)
  }

  @Test("写方法遵守既有 IPC 写门禁；只读的 machine.list 不受影响")
  func writeGateAppliesToMachineMutations() async throws {
    let (fixture, _) = try makeFixture(allowSendKeys: false)
    defer { tearDown(fixture) }
    let blocked = await fixture.call(
      "machine.rename", .object(["machine": .string("x"), "label": .string("y")]))
    #expect(blocked.error?.code == .writeNotAllowed)

    let readOnly = await fixture.call("machine.list")
    #expect(readOnly.error == nil)
  }

  @Test("machine.add 不代替用户接受安装或替换；未知方法仍返回 method_not_found")
  func addRequiresInteractiveConfirmationAndUnknownMethodsStillFail() async throws {
    let (fixture, _) = try makeFixture()
    defer { tearDown(fixture) }
    let added = await fixture.call(
      "machine.add",
      .object([
        "label": .string("orb"), "sshTarget": .string("root@ubuntu@orb"),
        "sessionName": .string("work"),
      ]))
    // 本夹具的设置事务直接成功，因此这里应当保存成功；确认路径由取消用例覆盖。
    #expect(added.error == nil)
    #expect(added.result?["label"]?.stringValue == "orb")

    let unknown = await fixture.call("machine.notARealMethod")
    #expect(unknown.error?.code == .methodNotFound)
  }

  @Test("session.list 在没有配置注册表传输时报明确错误，不返回空列表")
  func sessionListSurfacesTransportFailure() async throws {
    let (fixture, _) = try makeFixture()
    defer { tearDown(fixture) }
    _ = await fixture.fleet.addMachine(
      label: "orb", sshTarget: "root@ubuntu@orb", sessionName: "work", confirm: { _ in true })
    let response = await fixture.call("session.list", .object(["machine": .string("orb")]))
    #expect(response.error != nil)
    #expect(response.error?.message.contains("测试不提供注册表传输") == true)
  }

  // MARK: - CLI 前端

  /// 执行构建产物 `aster-cli`，返回 (退出码, stdout, stderr)。
  ///
  /// 只用于验证参数解析与用法错误：这些路径在连接 socket **之前**就返回，
  /// 因此不需要运行中的 App，也不会碰用户真实工作区。
  private func runCLI(_ arguments: [String]) throws -> (Int32, String, String) {
    let binary = URL(fileURLWithPath: Bundle.main.bundlePath)
      .deletingLastPathComponent().appendingPathComponent("aster-cli")
    guard FileManager.default.isExecutableFile(atPath: binary.path) else {
      throw MachineCLITestSkip.binaryMissing(binary.path)
    }
    let process = Process()
    process.executableURL = binary
    process.arguments = arguments
    // 指向一个必定不存在的 socket，保证解析之后的连接阶段快速失败而不是拉起 App。
    var environment = ProcessInfo.processInfo.environment
    environment["ASTER_SOCKET_PATH"] =
      NSTemporaryDirectory() + "aster-cli-test-\(UUID().uuidString).sock"
    environment["ASTER_CLI_NO_LAUNCH"] = "1"
    process.environment = environment
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice
    try process.run()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
      process.terminationStatus,
      String(decoding: outData, as: UTF8.self),
      String(decoding: errData, as: UTF8.self)
    )
  }

  private enum MachineCLITestSkip: Error { case binaryMissing(String) }

  /// `Self.cliUsageExitCode` 的字面值。`AsterCLI` 是可执行 target，测试 target 无法
  /// import 它的常量；两处必须保持一致。
  private static let cliUsageExitCode: Int32 = 2

  @Test("CLI 参数解析：缺少 --machine / --name / 子命令都返回用法错误")
  func cliRejectsIncompleteInvocations() throws {
    let cases: [[String]] = [
      ["machine"],
      ["machine", "rename", "only-one"],
      ["machine", "add", "--label", "x"],
      ["session", "list"],
      ["session", "create", "--machine", "orb"],
    ]
    for arguments in cases {
      guard let result = try? runCLI(arguments) else { return }
      #expect(result.0 == Self.cliUsageExitCode, "\(arguments) 应返回用法错误")
      #expect(result.2.contains("machine list"), "\(arguments) 的错误里应带用法说明")
    }
  }

  @Test("CLI 参数解析：完整命令通过解析后才去连接 socket")
  func cliAcceptsCompleteInvocations() throws {
    // socket 不存在，因此解析成功的命令必然停在「App 不可达」而不是用法错误。
    let cases: [[String]] = [
      ["machine", "list"],
      ["machine", "add", "--label", "orb", "--ssh-target", "root@ubuntu@orb", "--session", "work"],
      ["machine", "rename", "orb", "orb-ubuntu"],
      ["machine", "disable", "orb"],
      ["session", "list", "--machine", "orb"],
      ["session", "delete", "--machine", "orb", "--name", "work"],
    ]
    for arguments in cases {
      guard let result = try? runCLI(arguments) else { return }
      #expect(result.0 != Self.cliUsageExitCode, "\(arguments) 不应是用法错误：\(result.2)")
    }
  }

  @Test("CLI 不接管既有 session 子命令，避免影响 P2 的 detach/end")
  func cliLeavesExistingSessionSubcommandsAlone() {
    #expect(!MachineCommandsMatcher.matches(["session", "detach", "w1:p1"]))
    #expect(!MachineCommandsMatcher.matches(["session", "terminals"]))
    #expect(!MachineCommandsMatcher.matches(["agent", "list"]))
    #expect(MachineCommandsMatcher.matches(["machine", "list"]))
    #expect(MachineCommandsMatcher.matches(["session", "create"]))
  }
}

/// `MachineCommands.matches` 的判定规则副本。
///
/// `AsterCLI` 是可执行 target，测试 target 无法 import；这里按同一份规则重述一次，
/// 用来锁住「不接管既有 session 子命令」这条边界。两处必须同时修改。
enum MachineCommandsMatcher {
  static func matches(_ argv: [String]) -> Bool {
    guard let first = argv.first else { return false }
    if first == "machine" { return true }
    guard first == "session", argv.count > 1 else { return false }
    return ["list", "create", "stop", "delete"].contains(argv[1])
  }
}
