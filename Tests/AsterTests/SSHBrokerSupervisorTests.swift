import AsterCore
import Foundation
import Testing

@testable import Aster

// SSHBrokerSupervisor 生命周期与事件分发：用假 broker（见 SSHBrokerTestSupport）验证
// ready、profiles.sync、认证转交、崩溃重启与 config list。

@MainActor
@Test("broker 监管：拉起后等到 ready，发布端点并推送 profiles.sync；主机变化再推一次；退出发 shutdown")
func sshBrokerSupervisorStartsSyncsAndShutsDown() async throws {
  let broker = try FakeSSHBroker()
  defer { broker.remove() }
  let (directory, hostsURL) = makeTemporaryHostDirectory()
  defer { try? FileManager.default.removeItem(at: hostsURL.deletingLastPathComponent()) }
  let first = SSHHostProfile(name: "orb", host: "127.0.0.1", port: 32222, user: "root")
  try directory.upsert(first)
  let routing = SSHEngineRouting()
  let supervisor = makeFakeBrokerSupervisor(broker, directory: directory, routing: routing)

  supervisor.start(preferredEngine: .native)
  #expect(supervisor.engine == .native)
  try await supervisor.waitUntilReady()
  let endpoint = try supervisor.nativeEndpoint()
  #expect(routing.nativeEndpoint == endpoint)
  #expect(endpoint.executablePath == broker.executable.standardizedFileURL.path)
  #expect(endpoint.brokerSocketPath.hasPrefix("/tmp/aster-sshb-"))
  #expect(endpoint.brokerSocketPath.utf8.count < 104)
  // 私有目录只对本人开放。
  let socketDirectory = (endpoint.brokerSocketPath as NSString).deletingLastPathComponent
  let permissions = try FileManager.default.attributesOfItem(atPath: socketDirectory)[
    .posixPermissions] as? NSNumber
  #expect(permissions?.intValue == 0o700)

  #expect(await sshBrokerEventually { broker.received().contains { $0.contains("\"profiles.sync\"") } })
  let firstSync = broker.received().first { $0.contains("profiles.sync") } ?? ""
  #expect(firstSync.contains(first.id.uuidString))

  let second = SSHHostProfile(name: "lab", host: "10.0.0.5", user: "deploy")
  try directory.upsert(second)
  #expect(
    await sshBrokerEventually {
      broker.received().filter { $0.contains("profiles.sync") }.last?.contains(second.id.uuidString)
        == true
    })
  let syncCount = broker.received().filter { $0.contains("profiles.sync") }.count
  #expect(syncCount == 2)

  supervisor.shutdown()
  #expect(routing.nativeEndpoint == nil)
  #expect(supervisor.engine == .openssh)
  #expect(await sshBrokerEventually { broker.received().last?.contains("\"shutdown\"") == true })
  #expect(!FileManager.default.fileExists(atPath: socketDirectory))
}

@MainActor
@Test("broker 监管：没有认证协调者时回答取消与拒绝；link.state 交给接收者；坏行与未知类型不影响后续")
func sshBrokerSupervisorDispatchesEventsWithoutCoordinator() async throws {
  let broker = try FakeSSHBroker()
  defer { broker.remove() }
  try broker.setEvents([
    #"{"type":"auth.request","id":"a1","endpoint":"deploy@10.0.0.5:22","kind":"password","prompts":[{"text":"Password:","echo":false}],"attempt":1,"interactive":true}"#,
    "this is not json",
    #"{"type":"future.thing","x":1}"#,
    #"{"type":"hostkey.confirm","id":"h1","endpoint":"10.0.0.5:22","algorithm":"ssh-ed25519","fingerprint":"SHA256:abc","status":"unknown","interactive":true}"#,
    #"{"type":"link.state","endpoint":"deploy@10.0.0.5:22","target":"lab","state":"failed","errorKind":"hostUnreachable","detail":"refused"}"#,
  ])
  let (directory, hostsURL) = makeTemporaryHostDirectory()
  defer { try? FileManager.default.removeItem(at: hostsURL.deletingLastPathComponent()) }
  var linkStates: [SSHLinkStateEvent] = []
  let supervisor = makeFakeBrokerSupervisor(
    broker, directory: directory, routing: SSHEngineRouting(),
    linkStates: { linkStates.append($0) })
  defer { supervisor.shutdown() }

  supervisor.start(preferredEngine: .native)
  try await supervisor.waitUntilReady()
  #expect(
    await sshBrokerEventually {
      let lines = broker.received()
      return lines.contains { $0.contains("auth.answer") }
        && lines.contains { $0.contains("hostkey.answer") }
    })
  let lines = broker.received()
  #expect(lines.contains(#"{"id":"a1","responses":null,"secret":null,"type":"auth.answer"}"#))
  #expect(lines.contains(#"{"accept":false,"id":"h1","type":"hostkey.answer"}"#))
  #expect(await sshBrokerEventually { linkStates.count == 1 })
  #expect(linkStates.first?.state == .failed)
  #expect(linkStates.first?.errorKind == .hostUnreachable)
  #expect(supervisor.diagnostics.contains { $0.hasPrefix("ssh.broker.malformed_line") })
  // 诊断里不出现坏行的原文。
  #expect(!supervisor.diagnostics.contains { $0.contains("this is not json") })
}

@MainActor
@Test("broker 监管：认证请求交给协调者，回答原样写回；auth.result 转交协调者")
func sshBrokerSupervisorForwardsCoordinatorAnswers() async throws {
  let broker = try FakeSSHBroker()
  defer { broker.remove() }
  try broker.setEvents([
    #"{"type":"auth.request","id":"a7","endpoint":"deploy@10.0.0.5:22","kind":"password","prompts":[],"attempt":1,"interactive":true}"#,
    #"{"type":"hostkey.confirm","id":"h7","endpoint":"10.0.0.5:22","algorithm":"ssh-ed25519","fingerprint":"SHA256:abc","status":"changed","interactive":true}"#,
    #"{"type":"auth.result","id":"a7","accepted":true}"#,
  ])
  let (directory, hostsURL) = makeTemporaryHostDirectory()
  defer { try? FileManager.default.removeItem(at: hostsURL.deletingLastPathComponent()) }
  let coordinator = FakeSSHAuthCoordinator()
  let supervisor = makeFakeBrokerSupervisor(broker, directory: directory, routing: SSHEngineRouting())
  supervisor.authCoordinator = coordinator
  defer { supervisor.shutdown() }

  supervisor.start(preferredEngine: .native)
  try await supervisor.waitUntilReady()
  #expect(
    await sshBrokerEventually {
      broker.received().contains(#"{"id":"a7","responses":null,"secret":"pw-a7","type":"auth.answer"}"#)
        && broker.received().contains(#"{"accept":true,"id":"h7","type":"hostkey.answer"}"#)
    })
  #expect(coordinator.answeredRequests == ["a7"])
  #expect(await sshBrokerEventually { coordinator.results.count == 1 })
  #expect(coordinator.results.first?.0 == "a7")
  #expect(coordinator.results.first?.1 == true)
  // 秘密只经控制通道，不进诊断。
  #expect(!supervisor.diagnostics.contains { $0.contains("pw-a7") })
}

@MainActor
@Test("broker 监管：崩溃后按退避重启，同一 socket 路径，新实例重新收到 profiles.sync")
func sshBrokerSupervisorRestartsAfterCrash() async throws {
  let broker = try FakeSSHBroker()
  defer { broker.remove() }
  try broker.mark("crash-once")
  let (directory, hostsURL) = makeTemporaryHostDirectory()
  defer { try? FileManager.default.removeItem(at: hostsURL.deletingLastPathComponent()) }
  try directory.upsert(SSHHostProfile(name: "orb", host: "127.0.0.1", user: "root"))
  let routing = SSHEngineRouting()
  let supervisor = makeFakeBrokerSupervisor(broker, directory: directory, routing: routing)
  defer { supervisor.shutdown() }

  supervisor.start(preferredEngine: .native)
  let endpoint = try supervisor.nativeEndpoint()
  #expect(await sshBrokerEventually { supervisor.launchCount == 2 && supervisor.isReady })
  #expect(supervisor.diagnostics.contains { $0.hasPrefix("ssh.broker.exited: status=3") })
  // 端点在重启前后保持不变：已写进 Pane 命令行的桥仍然有效。
  #expect(try supervisor.nativeEndpoint() == endpoint)
  #expect(routing.nativeEndpoint == endpoint)
  #expect(await sshBrokerEventually { broker.received(2).contains { $0.contains("profiles.sync") } })
}

@MainActor
@Test("broker 监管：超时未报 ready 时结束进程并重启")
func sshBrokerSupervisorRestartsWhenReadyTimesOut() async throws {
  let broker = try FakeSSHBroker()
  defer { broker.remove() }
  try broker.mark("no-ready")
  let (directory, hostsURL) = makeTemporaryHostDirectory()
  defer { try? FileManager.default.removeItem(at: hostsURL.deletingLastPathComponent()) }
  let supervisor = makeFakeBrokerSupervisor(
    broker, directory: directory, routing: SSHEngineRouting(), readyTimeout: .milliseconds(500))
  defer { supervisor.shutdown() }

  supervisor.start(preferredEngine: .native)
  await #expect(throws: SSHBrokerError.startFailed("broker not ready")) {
    try await supervisor.waitUntilReady()
  }
  // 负载高时假脚本启动也可能超过看门狗，多重启一轮是正确行为，所以只要求「至少重启过一次」。
  #expect(await sshBrokerEventually { supervisor.launchCount >= 2 && supervisor.isReady })
  #expect(supervisor.diagnostics.contains { $0.hasPrefix("ssh.broker.ready_timeout") })
}

@MainActor
@Test("config list：在后台执行 aster-ssh config list --json 并解码")
func sshBrokerSupervisorReadsConfigListing() async throws {
  let broker = try FakeSSHBroker()
  defer { broker.remove() }
  try #"{"hosts":[{"alias":"orb","hostName":"127.0.0.1","user":"root","port":32222,"identityFiles":[],"forwards":[]}],"ignored":[{"file":"~/.ssh/config","line":12,"option":"Match","reason":"unsupported"}]}"#
    .write(to: broker.directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
  let (directory, hostsURL) = makeTemporaryHostDirectory()
  defer { try? FileManager.default.removeItem(at: hostsURL.deletingLastPathComponent()) }
  // 引擎为 openssh 时也能读：设置页导入不依赖 broker。
  let supervisor = makeFakeBrokerSupervisor(
    broker, directory: directory, routing: SSHEngineRouting(),
    environment: [SSHEngine.environmentKey: "openssh"])
  let listing = try await supervisor.configListing()
  #expect(listing.hosts.map(\.alias) == ["orb"])
  #expect(listing.hosts.first?.port == 32222)
  #expect(listing.ignored.first?.option == "Match")
}
