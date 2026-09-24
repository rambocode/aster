// `host.list` 控制方法，以及 `aster-cli host|workspace` 前端参数解析的定向测试。
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 挂好替身主机快照的 dispatcher。
@MainActor
private func hostDispatcher(_ snapshot: HostControlSnapshot) -> AsterControlDispatcher {
  let bridge = AsterControlBridge(socketPath: "/tmp/test.sock", binaryPath: "/tmp/aster-cli")
  // 写门禁关着：host.list 是只读方法，不应受它影响。
  let dispatcher = AsterControlDispatcher(bridge: bridge, version: "9.9.9") {
    AsterControlDispatcher.Policy(
      allowSendKeys: false, allowSensitiveSessions: false, shell: AsterConfiguration().shell)
  }
  dispatcher.hostSnapshotProvider = { snapshot }
  return dispatcher
}

@Test("host.list：跳过默认项，按默认项合并用户与端口，带跳板名，不输出任何认证信息")
@MainActor
func hostControlListShape() async throws {
  var defaults = SSHHostProfile.emptyDefaults()
  defaults.user = "deploy"
  defaults.port = 2222
  let bastion = SSHHostProfile(name: "bastion", host: "jump.example.com", port: 22, user: "ops")
  let web = SSHHostProfile(
    name: "web", group: "prod", host: "10.0.0.5", jumpHostID: bastion.id,
    proxyCommand: "nc %h %p", auth: .password, identityFiles: ["~/.ssh/secret_key"])
  let v6 = SSHHostProfile(name: "v6", host: "fe80::1", port: 2200, user: "root")
  let dispatcher = hostDispatcher(
    HostControlSnapshot(hosts: [defaults, bastion, web, v6], loadError: nil))

  let response = await dispatcher.handle(controlRequest("host.list"), client: ControlFakeClient())
  #expect(response.error == nil)
  let result = try #require(response.result)
  let list = try result.decoded(as: HostListResult.self)
  #expect(list.configurationError == nil)
  #expect(list.hosts.map(\.name) == ["bastion", "web", "v6"])
  #expect(list.hosts[0].target == "ops@jump.example.com:22")
  #expect(list.hosts[1].target == "deploy@10.0.0.5:2222")
  #expect(list.hosts[1].group == "prod")
  #expect(list.hosts[1].jumpHostID == bastion.id.uuidString)
  #expect(list.hosts[1].jumpHostName == "bastion")
  #expect(list.hosts[2].target == "root@[fe80::1]:2200")

  // 行里只能有这些键：认证方式、私钥、代理命令、口令状态一律不出现。
  guard case .array(let rows)? = result["hosts"], case .object(let row)? = rows.dropFirst().first
  else {
    Issue.record("hosts 不是对象数组")
    return
  }
  #expect(Set(row.keys).isSubset(of: ["id", "name", "group", "target", "jumpHostID", "jumpHostName"]))
  let encoded = String(decoding: try JSONEncoder().encode(result), as: UTF8.self)
  for secret in ["password", "secret_key", "nc %h", "auth", "identity", "proxy"] {
    #expect(!encoded.contains(secret), "输出不应包含 \(secret)")
  }
}

@Test("host.list：hosts.json 加载失败时回显错误，列表保持最后有效值；失效的跳板只回显 ID")
@MainActor
func hostControlListReportsLoadError() async throws {
  let orphan = UUID()
  let host = SSHHostProfile(name: "solo", host: "solo.local", jumpHostID: orphan)
  let dispatcher = hostDispatcher(HostControlSnapshot(hosts: [host], loadError: "坏的 JSON"))
  let list = try #require(
    await dispatcher.handle(controlRequest("host.list"), client: ControlFakeClient()).result
  ).decoded(as: HostListResult.self)
  #expect(list.configurationError == "坏的 JSON")
  #expect(list.hosts.map(\.target) == ["solo.local:22"])
  #expect(list.hosts[0].jumpHostID == orphan.uuidString)
  #expect(list.hosts[0].jumpHostName == nil)
}

// MARK: - CLI 前端

/// 构建产物 `aster-cli` 的位置。
///
/// `scripts/test.sh` 的宿主是 `.build/aster-appkit-test-host`，产物在它旁边的 `debug/` 里；
/// 直接跑 xctest 时产物与测试 bundle 同目录。只看 `Bundle.main` 的父目录会找不到产物，
/// 让 CLI 用例全部静默跳过，所以几处都找，找不到就让用例失败。machine 组的 CLI 用例也用它。
func asterCLIBinary() -> URL? {
  let host = Bundle.main.executableURL.map { [$0.deletingLastPathComponent()] } ?? []
  let roots = host + Bundle.allBundles.filter { $0.bundlePath.hasSuffix(".xctest") }
    .map { URL(fileURLWithPath: $0.bundlePath).deletingLastPathComponent() }
  return roots.flatMap {
    [$0.appendingPathComponent("aster-cli"), $0.appendingPathComponent("debug/aster-cli")]
  }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

/// 执行构建产物 `aster-cli`，返回 (退出码, stderr)。
///
/// 只验证参数解析：用法错误在连接 socket 之前返回；解析通过的命令指向一个必定不存在的
/// socket 并禁止拉起 App，因此会停在「App 不可达」，不会碰用户真实工作区。
private func runHostWorkspaceCLI(_ arguments: [String]) throws -> (status: Int32, stderr: String) {
  let binary = try #require(asterCLIBinary(), "找不到 aster-cli 构建产物")
  let process = Process()
  process.executableURL = binary
  process.arguments = arguments
  var environment = ProcessInfo.processInfo.environment
  environment["ASTER_SOCKET_PATH"] =
    NSTemporaryDirectory() + "aster-cli-test-\(UUID().uuidString).sock"
  environment["ASTER_CLI_NO_LAUNCH"] = "1"
  process.environment = environment
  let err = Pipe()
  process.standardOutput = FileHandle.nullDevice
  process.standardError = err
  process.standardInput = FileHandle.nullDevice
  try process.run()
  let errData = err.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return (process.terminationStatus, String(decoding: errData, as: UTF8.self))
}

/// `AsterCLIExitCode.usage` 的字面值；可执行 target 无法 import，两处必须一致。
private let cliUsageExitCode: Int32 = 2

@Test("CLI：host / workspace 缺参数、未知参数与多余参数都返回用法错误")
func hostWorkspaceCLIRejectsBadInvocations() throws {
  let cases: [([String], String)] = [
    (["host"], "host list"),
    (["host", "bogus"], "host list"),
    (["host", "list", "extra"], "host list"),
    (["workspace"], "workspace list"),
    (["workspace", "bogus"], "workspace list"),
    (["workspace", "list", "extra"], "workspace list"),
    (["workspace", "open"], "workspace open"),
    (["workspace", "open", "a", "b"], "workspace open"),
    (["workspace", "open", "--bogus"], "workspace open"),
    (["workspace", "new"], "workspace new"),
    (["workspace", "new", "--name"], "workspace new"),
    (["workspace", "new", "positional"], "workspace new"),
    (["workspace", "new", "--name", "x", "--bogus", "y"], "workspace new"),
    (["workspace", "new", "--name", "x", "--machine", ""], "workspace new"),
  ]
  for (arguments, usage) in cases {
    let result = try runHostWorkspaceCLI(arguments)
    #expect(result.status == cliUsageExitCode, "\(arguments) 应返回用法错误：\(result.stderr)")
    #expect(result.stderr.contains(usage), "\(arguments) 的错误里应带用法说明")
  }
}

@Test("CLI：完整命令（含 --json / --format json）通过解析后才去连接 socket")
func hostWorkspaceCLIAcceptsCompleteInvocations() throws {
  let cases: [[String]] = [
    ["host", "list"],
    ["host", "list", "--json"],
    ["workspace", "list", "--format", "json"],
    ["workspace", "open", "dev"],
    ["workspace", "open", "orb/dev", "--json"],
    ["workspace", "new", "--name", "notes"],
    ["workspace", "new", "--machine", "orb", "--name", "api", "--json"],
  ]
  for arguments in cases {
    let result = try runHostWorkspaceCLI(arguments)
    #expect(result.status != cliUsageExitCode, "\(arguments) 不应是用法错误：\(result.stderr)")
  }
}
