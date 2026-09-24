import AsterCore
import Foundation
import Testing

@testable import Aster

// SSHBrokerSupervisor 的定向测试。broker 用临时目录里的 /bin/sh 假脚本代替：
// 它按 PROTOCOL.md §4 说 JSON Lines，把收到的每一行追加到 received-<次数> 文件，
// 并能按标记文件模拟崩溃、不报 ready 与预置事件。全程不碰真实 hosts.json、钥匙串与网络。

/// 一次测试用的假 broker 环境。
private struct FakeBroker {
  let directory: URL
  let executable: URL

  /// 生成脚本。`$3` 是 `broker --socket <path>` 里的 socket 路径。
  init() throws {
    directory = URL(fileURLWithPath: "/tmp")
      .appendingPathComponent("aster-fake-broker-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    executable = directory.appendingPathComponent("aster-ssh")
    let script = """
      #!/bin/sh
      DIR='\(directory.path)'
      if [ "$1" = "config" ]; then
        cat "$DIR/config.json"
        exit 0
      fi
      n=$(cat "$DIR/count" 2>/dev/null || echo 0)
      n=$((n+1))
      echo "$n" > "$DIR/count"
      if [ -f "$DIR/no-ready" ]; then
        rm -f "$DIR/no-ready"
        exec sleep 30
        exit 0
      fi
      printf '{"type":"ready","socket":"%s","version":"fake-%s"}\\n' "$3" "$n"
      if [ -f "$DIR/crash-once" ]; then
        rm -f "$DIR/crash-once"
        exit 3
      fi
      if [ -f "$DIR/events" ]; then
        cat "$DIR/events"
      fi
      while IFS= read -r line; do
        printf '%s\\n' "$line" >> "$DIR/received-$n"
        case "$line" in
          *'"type":"shutdown"'*) exit 0 ;;
        esac
      done
      exit 0
      """
    try script.write(to: executable, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
  }

  /// 放一个标记文件（crash-once、no-ready）。
  func mark(_ name: String) throws {
    try Data().write(to: directory.appendingPathComponent(name))
  }

  /// 预置 broker 启动后立刻输出的事件行。
  func setEvents(_ lines: [String]) throws {
    try (lines.joined(separator: "\n") + "\n").write(
      to: directory.appendingPathComponent("events"), atomically: true, encoding: .utf8)
  }

  /// 第 n 个 broker 实例收到的全部行。
  func received(_ instance: Int = 1) -> [String] {
    let url = directory.appendingPathComponent("received-\(instance)")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init)
  }

  func remove() {
    try? FileManager.default.removeItem(at: directory)
  }
}

/// 回答固定内容并记录调用的假认证协调者。
@MainActor
private final class FakeAuthCoordinator: SSHAuthCoordinating {
  var results: [(String, Bool)] = []
  var answeredRequests: [String] = []

  func answer(_ request: SSHAuthRequest) async -> SSHBrokerCommand {
    answeredRequests.append(request.id)
    return .authAnswer(id: request.id, secret: "pw-\(request.id)", responses: nil)
  }

  func handleResult(id: String, accepted: Bool) { results.append((id, accepted)) }

  func confirmHostKey(_ request: SSHHostKeyRequest) async -> SSHBrokerCommand {
    .hostKeyAnswer(id: request.id, accept: true)
  }
}

/// 在主线程上轮询条件，最多等 `seconds` 秒。
@MainActor
private func eventually(_ seconds: Double = 5, _ condition: () -> Bool) async -> Bool {
  let deadline = Date().addingTimeInterval(seconds)
  while Date() < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return condition()
}

/// 私有主机目录（临时 hosts.json）。
@MainActor
private func makeHostDirectory() -> (SSHHostDirectory, URL) {
  let url = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AsterSSHBrokerTests.\(UUID().uuidString)")
    .appendingPathComponent("hosts.json")
  return (SSHHostDirectory(store: SSHHostStore(fileURL: url)), url)
}

/// 用假 broker 构造监管者。退避与超时调小，用例不等真实秒数。
@MainActor
private func makeSupervisor(
  _ broker: FakeBroker, directory: SSHHostDirectory, routing: SSHEngineRouting,
  environment: [String: String] = ["PATH": "/usr/bin:/bin"],
  readyTimeout: Duration = .seconds(5),
  linkStates: ((SSHLinkStateEvent) -> Void)? = nil
) -> SSHBrokerSupervisor {
  var tuning = SSHBrokerSupervisor.Tuning()
  tuning.readyTimeout = readyTimeout
  tuning.restartDelays = [0.05]
  let executable = broker.executable
  return SSHBrokerSupervisor(
    routing: routing, hostDirectory: { directory }, linkStateHandler: linkStates,
    environment: environment, tuning: tuning, locateExecutable: { executable })
}

@MainActor
@Test("broker 监管：拉起后等到 ready，发布端点并推送 profiles.sync；主机变化再推一次；退出发 shutdown")
func sshBrokerSupervisorStartsSyncsAndShutsDown() async throws {
  let broker = try FakeBroker()
  defer { broker.remove() }
  let (directory, hostsURL) = makeHostDirectory()
  defer { try? FileManager.default.removeItem(at: hostsURL.deletingLastPathComponent()) }
  let first = SSHHostProfile(name: "orb", host: "127.0.0.1", port: 32222, user: "root")
  try directory.upsert(first)
  let routing = SSHEngineRouting()
  let supervisor = makeSupervisor(broker, directory: directory, routing: routing)

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

  #expect(await eventually { broker.received().contains { $0.contains("\"profiles.sync\"") } })
  let firstSync = broker.received().first { $0.contains("profiles.sync") } ?? ""
  #expect(firstSync.contains(first.id.uuidString))

  let second = SSHHostProfile(name: "lab", host: "10.0.0.5", user: "deploy")
  try directory.upsert(second)
  #expect(
    await eventually {
      broker.received().filter { $0.contains("profiles.sync") }.last?.contains(second.id.uuidString)
        == true
    })
  let syncCount = broker.received().filter { $0.contains("profiles.sync") }.count
  #expect(syncCount == 2)

  supervisor.shutdown()
  #expect(routing.nativeEndpoint == nil)
  #expect(supervisor.engine == .openssh)
  #expect(await eventually { broker.received().last?.contains("\"shutdown\"") == true })
  #expect(!FileManager.default.fileExists(atPath: socketDirectory))
}

@MainActor
@Test("broker 监管：没有认证协调者时回答取消与拒绝；link.state 交给接收者；坏行与未知类型不影响后续")
func sshBrokerSupervisorDispatchesEventsWithoutCoordinator() async throws {
  let broker = try FakeBroker()
  defer { broker.remove() }
  try broker.setEvents([
    #"{"type":"auth.request","id":"a1","endpoint":"deploy@10.0.0.5:22","kind":"password","prompts":[{"text":"Password:","echo":false}],"attempt":1,"interactive":true}"#,
    "this is not json",
    #"{"type":"future.thing","x":1}"#,
    #"{"type":"hostkey.confirm","id":"h1","endpoint":"10.0.0.5:22","algorithm":"ssh-ed25519","fingerprint":"SHA256:abc","status":"unknown","interactive":true}"#,
    #"{"type":"link.state","endpoint":"deploy@10.0.0.5:22","target":"lab","state":"failed","errorKind":"hostUnreachable","detail":"refused"}"#,
  ])
  let (directory, hostsURL) = makeHostDirectory()
  defer { try? FileManager.default.removeItem(at: hostsURL.deletingLastPathComponent()) }
  var linkStates: [SSHLinkStateEvent] = []
  let supervisor = makeSupervisor(
    broker, directory: directory, routing: SSHEngineRouting(),
    linkStates: { linkStates.append($0) })
  defer { supervisor.shutdown() }

  supervisor.start(preferredEngine: .native)
  try await supervisor.waitUntilReady()
  #expect(
    await eventually {
      let lines = broker.received()
      return lines.contains { $0.contains("auth.answer") }
        && lines.contains { $0.contains("hostkey.answer") }
    })
  let lines = broker.received()
  #expect(lines.contains(#"{"id":"a1","responses":null,"secret":null,"type":"auth.answer"}"#))
  #expect(lines.contains(#"{"accept":false,"id":"h1","type":"hostkey.answer"}"#))
  #expect(await eventually { linkStates.count == 1 })
  #expect(linkStates.first?.state == .failed)
  #expect(linkStates.first?.errorKind == .hostUnreachable)
  #expect(supervisor.diagnostics.contains { $0.hasPrefix("ssh.broker.malformed_line") })
  // 诊断里不出现坏行的原文。
  #expect(!supervisor.diagnostics.contains { $0.contains("this is not json") })
}

@MainActor
@Test("broker 监管：认证请求交给协调者，回答原样写回；auth.result 转交协调者")
func sshBrokerSupervisorForwardsCoordinatorAnswers() async throws {
  let broker = try FakeBroker()
  defer { broker.remove() }
  try broker.setEvents([
    #"{"type":"auth.request","id":"a7","endpoint":"deploy@10.0.0.5:22","kind":"password","prompts":[],"attempt":1,"interactive":true}"#,
    #"{"type":"hostkey.confirm","id":"h7","endpoint":"10.0.0.5:22","algorithm":"ssh-ed25519","fingerprint":"SHA256:abc","status":"changed","interactive":true}"#,
    #"{"type":"auth.result","id":"a7","accepted":true}"#,
  ])
  let (directory, hostsURL) = makeHostDirectory()
  defer { try? FileManager.default.removeItem(at: hostsURL.deletingLastPathComponent()) }
  let coordinator = FakeAuthCoordinator()
  let supervisor = makeSupervisor(broker, directory: directory, routing: SSHEngineRouting())
  supervisor.authCoordinator = coordinator
  defer { supervisor.shutdown() }

  supervisor.start(preferredEngine: .native)
  try await supervisor.waitUntilReady()
  #expect(
    await eventually {
      broker.received().contains(#"{"id":"a7","responses":null,"secret":"pw-a7","type":"auth.answer"}"#)
        && broker.received().contains(#"{"accept":true,"id":"h7","type":"hostkey.answer"}"#)
    })
  #expect(coordinator.answeredRequests == ["a7"])
  #expect(await eventually { coordinator.results.count == 1 })
  #expect(coordinator.results.first?.0 == "a7")
  #expect(coordinator.results.first?.1 == true)
  // 秘密只经控制通道，不进诊断。
  #expect(!supervisor.diagnostics.contains { $0.contains("pw-a7") })
}

@MainActor
@Test("broker 监管：崩溃后按退避重启，同一 socket 路径，新实例重新收到 profiles.sync")
func sshBrokerSupervisorRestartsAfterCrash() async throws {
  let broker = try FakeBroker()
  defer { broker.remove() }
  try broker.mark("crash-once")
  let (directory, hostsURL) = makeHostDirectory()
  defer { try? FileManager.default.removeItem(at: hostsURL.deletingLastPathComponent()) }
  try directory.upsert(SSHHostProfile(name: "orb", host: "127.0.0.1", user: "root"))
  let routing = SSHEngineRouting()
  let supervisor = makeSupervisor(broker, directory: directory, routing: routing)
  defer { supervisor.shutdown() }

  supervisor.start(preferredEngine: .native)
  let endpoint = try supervisor.nativeEndpoint()
  #expect(await eventually { supervisor.launchCount == 2 && supervisor.isReady })
  #expect(supervisor.diagnostics.contains { $0.hasPrefix("ssh.broker.exited: status=3") })
  // 端点在重启前后保持不变：已写进 Pane 命令行的桥仍然有效。
  #expect(try supervisor.nativeEndpoint() == endpoint)
  #expect(routing.nativeEndpoint == endpoint)
  #expect(await eventually { broker.received(2).contains { $0.contains("profiles.sync") } })
}

@MainActor
@Test("broker 监管：超时未报 ready 时结束进程并重启")
func sshBrokerSupervisorRestartsWhenReadyTimesOut() async throws {
  let broker = try FakeBroker()
  defer { broker.remove() }
  try broker.mark("no-ready")
  let (directory, hostsURL) = makeHostDirectory()
  defer { try? FileManager.default.removeItem(at: hostsURL.deletingLastPathComponent()) }
  let supervisor = makeSupervisor(
    broker, directory: directory, routing: SSHEngineRouting(), readyTimeout: .milliseconds(500))
  defer { supervisor.shutdown() }

  supervisor.start(preferredEngine: .native)
  await #expect(throws: SSHBrokerError.startFailed("broker not ready")) {
    try await supervisor.waitUntilReady()
  }
  // 负载高时假脚本启动也可能超过看门狗，多重启一轮是正确行为，所以只要求「至少重启过一次」。
  #expect(await eventually { supervisor.launchCount >= 2 && supervisor.isReady })
  #expect(supervisor.diagnostics.contains { $0.hasPrefix("ssh.broker.ready_timeout") })
}

@MainActor
@Test("引擎选择：找不到二进制回退 openssh 并记诊断；环境变量 openssh 时不拉起 broker")
func sshBrokerSupervisorFallsBackToOpenSSH() throws {
  let (directory, hostsURL) = makeHostDirectory()
  defer { try? FileManager.default.removeItem(at: hostsURL.deletingLastPathComponent()) }
  let routing = SSHEngineRouting()
  let missing = SSHBrokerSupervisor(
    routing: routing, hostDirectory: { directory }, environment: [:], locateExecutable: { nil })
  missing.start(preferredEngine: .native)
  #expect(missing.engine == .openssh)
  #expect(routing.nativeEndpoint == nil)
  #expect(missing.diagnostics.contains { $0 == "ssh.engine.fallback: executable missing" })
  #expect(throws: SSHBrokerError.engineDisabled) { try missing.nativeEndpoint() }

  let broker = try FakeBroker()
  defer { broker.remove() }
  let overridden = makeSupervisor(
    broker, directory: directory, routing: routing,
    environment: [SSHEngine.environmentKey: "openssh"])
  overridden.start(preferredEngine: .native)
  #expect(overridden.engine == .openssh)
  #expect(overridden.launchCount == 0)
  #expect(routing.nativeEndpoint == nil)
}

@Test("引擎选择：环境变量优先于设置，非法取值忽略并报告")
func sshBrokerSupervisorRequestedEngine() {
  #expect(SSHBrokerSupervisor.requestedEngine(environment: [:], preferred: .native) == (.native, nil))
  #expect(
    SSHBrokerSupervisor.requestedEngine(
      environment: ["ASTER_SSH_ENGINE": "OpenSSH"], preferred: .native) == (.openssh, nil))
  #expect(
    SSHBrokerSupervisor.requestedEngine(
      environment: ["ASTER_SSH_ENGINE": "native"], preferred: .openssh) == (.native, nil))
  let invalid = SSHBrokerSupervisor.requestedEngine(
    environment: ["ASTER_SSH_ENGINE": "putty"], preferred: .openssh)
  #expect(invalid.engine == .openssh)
  #expect(invalid.problem != nil)
}

@Test("定位 aster-ssh：环境变量 → App 包 → 主程序同目录 → 开发构建 cargo 产物")
func sshBrokerSupervisorLocatesExecutable() throws {
  let fileManager = FileManager.default
  let root = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("AsterLocateSSH.\(UUID().uuidString)")
  defer { try? fileManager.removeItem(at: root) }
  func makeExecutable(_ relative: String) throws -> URL {
    let url = root.appendingPathComponent(relative)
    try fileManager.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("#!/bin/sh\n".utf8).write(to: url)
    try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return url.standardizedFileURL
  }
  let devMain = root.appendingPathComponent(".build/debug/Aster")
  let appBundle = root.appendingPathComponent("Aster.app")

  // 什么都没有。
  #expect(
    SSHBrokerSupervisor.locate(
      environment: [:], bundleURL: appBundle, mainExecutableURL: devMain, fileManager: fileManager)
      == nil)
  // 只有 cargo 产物：由 .build 反推仓库根。
  let cargo = try makeExecutable("SshRuntime/target/debug/aster-ssh")
  #expect(
    SSHBrokerSupervisor.locate(
      environment: [:], bundleURL: appBundle, mainExecutableURL: devMain, fileManager: fileManager)
      == cargo)
  // 主程序同目录优先于 cargo 产物。
  let sibling = try makeExecutable(".build/debug/aster-ssh")
  #expect(
    SSHBrokerSupervisor.locate(
      environment: [:], bundleURL: appBundle, mainExecutableURL: devMain, fileManager: fileManager)
      == sibling)
  // App 包内优先于开发产物。
  let bundled = try makeExecutable("Aster.app/Contents/MacOS/aster-ssh")
  #expect(
    SSHBrokerSupervisor.locate(
      environment: [:], bundleURL: appBundle, mainExecutableURL: devMain, fileManager: fileManager)
      == bundled)
  // 环境变量最优先；指向不可执行文件时忽略。
  let override = try makeExecutable("custom/aster-ssh")
  #expect(
    SSHBrokerSupervisor.locate(
      environment: ["ASTER_SSH_BINARY": override.path], bundleURL: appBundle,
      mainExecutableURL: devMain, fileManager: fileManager) == override)
  #expect(
    SSHBrokerSupervisor.locate(
      environment: ["ASTER_SSH_BINARY": "/nonexistent/aster-ssh"], bundleURL: appBundle,
      mainExecutableURL: devMain, fileManager: fileManager) == bundled)
}

@MainActor
@Test("config list：在后台执行 aster-ssh config list --json 并解码")
func sshBrokerSupervisorReadsConfigListing() async throws {
  let broker = try FakeBroker()
  defer { broker.remove() }
  try #"{"hosts":[{"alias":"orb","hostName":"127.0.0.1","user":"root","port":32222,"identityFiles":[],"forwards":[]}],"ignored":[{"file":"~/.ssh/config","line":12,"option":"Match","reason":"unsupported"}]}"#
    .write(to: broker.directory.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
  let (directory, hostsURL) = makeHostDirectory()
  defer { try? FileManager.default.removeItem(at: hostsURL.deletingLastPathComponent()) }
  // 引擎为 openssh 时也能读：设置页导入不依赖 broker。
  let supervisor = makeSupervisor(
    broker, directory: directory, routing: SSHEngineRouting(),
    environment: [SSHEngine.environmentKey: "openssh"])
  let listing = try await supervisor.configListing()
  #expect(listing.hosts.map(\.alias) == ["orb"])
  #expect(listing.hosts.first?.port == 32222)
  #expect(listing.ignored.first?.option == "Match")
}
