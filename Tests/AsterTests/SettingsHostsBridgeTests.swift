import AppKit
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// 设置页「主机」分类的桥接：快照形状、保存与校验、`shell.sshEngine` 读写。
// 全部用临时 hosts.json 与假钥匙串，不碰用户真实文件与钥匙串。

/// 假钥匙串：只记录口令是否存在与删除调用。
@MainActor
final class FakeHostPasswords: SettingsHostPasswordStore {
  var saved: Set<String> = []
  var deleted: [String] = []

  func hasPassword(for endpoint: String) -> Bool { saved.contains(endpoint) }

  func deletePassword(for endpoint: String) throws {
    deleted.append(endpoint)
    saved.remove(endpoint)
  }
}

/// 记录桥接回调（toast、网页消息、回执）。
@MainActor
final class HostsBridgeRecorder {
  var toasts: [(text: String, isError: Bool)] = []
  var messages: [[String: Any]] = []
  var addMachineRequests: [MachineSetupFlow.Prefill] = []
  var openedFiles: [URL] = []
}

/// 测试夹具：临时目录里的主机存储、假钥匙串与可控的 ssh_config 解析结果。
@MainActor
struct HostsBridgeFixture {
  let root: URL
  let bridge: SettingsHostsBridge
  let passwords: FakeHostPasswords
  let recorder: HostsBridgeRecorder

  init(
    hosts: [SSHHostProfile] = [],
    machines: [MachineProfile] = [],
    listing: Result<SSHConfigListing, Error> = .failure(SSHBrokerError.executableMissing)
  ) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "AsterHostsBridge-\(UUID().uuidString)", isDirectory: true)
    let store = SSHHostStore(fileURL: root.appendingPathComponent("hosts.json"))
    if !hosts.isEmpty { try store.save([.emptyDefaults()] + hosts) }
    let passwords = FakeHostPasswords()
    let recorder = HostsBridgeRecorder()
    self.passwords = passwords
    self.recorder = recorder
    bridge = SettingsHostsBridge(
      dependencies: .init(
        directory: SSHHostDirectory(store: store),
        passwords: passwords,
        machines: { machines },
        machinesDidChange: nil,
        configListing: { try listing.get() },
        sshConfigURL: root.appendingPathComponent("ssh/config"),
        openInEditor: { recorder.openedFiles.append($0) },
        addMachine: { prefill, _ in recorder.addMachineRequests.append(prefill) },
        localUser: "tester"))
    bridge.toast = { recorder.toasts.append(($0, $1)) }
    bridge.postMessage = { recorder.messages.append($0) }
  }

  /// 同步执行一个动作并返回回执。异步动作（导入、打开编辑器）用 `performAsync`。
  func perform(_ action: String, _ payload: [String: Any]) -> Bool? {
    var result: Bool?
    bridge.handle(action: action, payload: payload) { result = $0 }
    return result
  }

  /// 执行异步动作并等待回执。
  func performAsync(_ action: String, _ payload: [String: Any] = [:]) async -> Bool {
    await withCheckedContinuation { continuation in
      bridge.handle(action: action, payload: payload) { continuation.resume(returning: $0) }
    }
  }

  func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

/// 快照里的主机行，按名称取。
@MainActor
private func row(_ name: String, in snapshot: [String: Any]) throws -> [String: Any] {
  let rows = try #require(snapshot["hosts"] as? [[String: Any]])
  return try #require(rows.first { ($0["profile"] as? [String: Any])?["name"] as? String == name })
}

@Test("主机快照按导入组、命名分组、未分组排序，并带口令、引用与共用统计")
@MainActor
func settingsHostsSnapshotShape() throws {
  let imported = SSHHostProfile(
    name: "orb", group: SSHHostProfile.importedGroup, host: "127.0.0.1", port: 32222, user: "root")
  let web = SSHHostProfile(name: "web", group: "prod", host: "web.example.com", user: "deploy")
  let webAlt = SSHHostProfile(name: "web-alt", host: "web.example.com", user: "deploy")
  let api = SSHHostProfile(
    name: "api", group: "prod", host: "api.example.com", jumpHostID: web.id,
    socksProxy: SSHHostPort(host: "127.0.0.1", port: 1080),
    forwards: [SSHForwardRule(kind: .local, bind: .init(host: "127.0.0.1", port: 8080), target: .init(host: "localhost", port: 80))],
    verifyHostKeys: false)
  let machine = MachineProfile(label: "Prod box", sshTarget: "web", hostID: web.id)
  let fixture = try HostsBridgeFixture(hosts: [webAlt, api, web, imported], machines: [machine])
  defer { fixture.cleanUp() }
  fixture.passwords.saved = ["deploy@web.example.com:22"]

  let snapshot = fixture.bridge.snapshot()
  #expect(JSONSerialization.isValidJSONObject(snapshot))
  let rows = try #require(snapshot["hosts"] as? [[String: Any]])
  #expect(rows.compactMap { ($0["profile"] as? [String: Any])?["name"] as? String } == ["orb", "api", "web", "web-alt"])
  #expect(snapshot["groups"] as? [String] == [SSHHostProfile.importedGroup, "prod"])
  #expect((snapshot["defaults"] as? [String: Any])?["id"] as? String == SSHHostProfile.defaultsProfileID.uuidString)
  #expect((snapshot["builtin"] as? [String: Any])?["user"] as? String == "tester")

  let webRow = try row("web", in: snapshot)
  #expect(webRow["hasPassword"] as? Bool == true)
  #expect(webRow["machines"] as? [String] == ["Prod box"])
  #expect(webRow["jumpDependents"] as? [String] == ["api"])
  #expect(webRow["credentialSharedWith"] as? [String] == ["web-alt"])
  #expect(webRow["connect"] as? String == "deploy@web.example.com")
  #expect(try row("web-alt", in: snapshot)["hasPassword"] as? Bool == true)
  #expect(try row("orb", in: snapshot)["hasPassword"] as? Bool == false)
  #expect(try row("api", in: snapshot)["jumpName"] as? String == "web")

  // 网页原样回传的对象必须能按 Codable 解码回同一台主机。
  let apiJSON = try #require(try row("api", in: snapshot)["profile"])
  #expect(try SettingsHostsBridge.decodeProfile(apiJSON) == api)
}

@Test("保存主机先校验：失败时 toast 原因且不落盘，成功后写入 hosts.json")
@MainActor
func settingsHostsSaveValidates() throws {
  let bastion = SSHHostProfile(name: "bastion", host: "bastion.example.com")
  let fixture = try HostsBridgeFixture(hosts: [bastion])
  defer { fixture.cleanUp() }

  var invalid = SettingsHostsBridge.profileJSON(SSHHostProfile(name: "", host: "db.example.com"))
  #expect(fixture.perform("hosts.save", ["profile": invalid]) == false)
  #expect(fixture.recorder.toasts.last?.isError == true)
  #expect(fixture.recorder.toasts.last?.text.contains("名称不能为空") == true)
  invalid["name"] = "db"
  invalid["port"] = 70_000
  #expect(fixture.perform("hosts.save", ["profile": invalid]) == false)
  #expect(fixture.recorder.toasts.last?.text.contains("端口必须在 1–65535 之间") == true)
  #expect(fixture.perform("hosts.save", ["profile": ["id": "not-a-uuid"]]) == false)
  #expect(fixture.bridge.directory.savedHosts.map(\.name) == ["bastion"])

  // 跳板环：bastion → db → bastion。
  let db = SSHHostProfile(name: "db", host: "db.example.com", jumpHostID: bastion.id)
  #expect(fixture.perform("hosts.save", ["profile": SettingsHostsBridge.profileJSON(db)]) == true)
  var cyclic = bastion
  cyclic.jumpHostID = db.id
  #expect(fixture.perform("hosts.save", ["profile": SettingsHostsBridge.profileJSON(cyclic)]) == false)
  #expect(fixture.recorder.toasts.last?.text.contains("循环") == true)

  // 默认项也走同一条保存路径。
  var defaults = SSHHostProfile.emptyDefaults()
  defaults.user = "ops"
  #expect(fixture.perform("hosts.save", ["profile": SettingsHostsBridge.profileJSON(defaults)]) == true)

  let reloaded = try SSHHostStore(fileURL: fixture.bridge.directory.store.fileURL).load()
  #expect(reloaded.first?.user == "ops")
  #expect(reloaded.contains(db))
  #expect(reloaded.first { $0.id == bastion.id }?.jumpHostID == nil)
}

@Test("主机 payload 里的控制字符与超量条目在边界被拒绝")
@MainActor
func settingsHostsRejectsControlCharacters() throws {
  var object = SettingsHostsBridge.profileJSON(SSHHostProfile(name: "x", host: "x.example.com"))
  object["proxyCommand"] = "nc %h %p\nrm -rf ~"
  #expect(throws: SettingsHostsError.self) { try SettingsHostsBridge.decodeProfile(object) }
  object["proxyCommand"] = nil
  object["identityFiles"] = Array(repeating: "~/.ssh/id", count: SettingsHostsBridge.maximumIdentityFiles + 1)
  #expect(throws: SettingsHostsError.invalidPayload) { try SettingsHostsBridge.decodeProfile(object) }
}

@Test("shell.sshEngine 经设置桥读写，非法值被拒绝")
@MainActor
func settingsSSHEngineRoundTrips() throws {
  let suite = "SettingsHosts.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let fixture = try HostsBridgeFixture()
  defer { fixture.cleanUp() }
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences, hostsBridge: fixture.bridge)
  controller.loadViewIfNeeded()

  var values = try #require(controller.settingsSnapshotForTesting()["values"] as? [String: Any])
  #expect(values["shell.sshEngine"] as? String == "native")
  try controller.applySettingForTesting(key: "shell.sshEngine", value: "openssh")
  #expect(preferences.configuration.shell.resolvedSSHEngine == .openssh)
  values = try #require(controller.settingsSnapshotForTesting()["values"] as? [String: Any])
  #expect(values["shell.sshEngine"] as? String == "openssh")
  #expect(throws: (any Error).self) { try controller.applySettingForTesting(key: "shell.sshEngine", value: "putty") }
  #expect(preferences.configuration.shell.resolvedSSHEngine == .openssh)
  #expect(controller.settingsSnapshotForTesting()["hosts"] is [String: Any])
}

@Test("只用指定私钥与 known_hosts 文件随保存落盘并原样读回；空列表存成 nil")
@MainActor
func settingsHostsSaveKeepsIdentitiesOnlyAndKnownHosts() throws {
  let fixture = try HostsBridgeFixture()
  defer { fixture.cleanUp() }
  let orb = SSHHostProfile(
    name: "orb", host: "127.0.0.1", port: 32222, user: "root",
    identityFiles: ["~/.orbstack/ssh/id_ed25519"], identitiesOnly: true,
    knownHostsFiles: ["~/.orbstack/ssh/known_hosts", "~/.ssh/known_hosts"])
  let object = SettingsHostsBridge.profileJSON(orb)
  #expect(object["identitiesOnly"] as? Bool == true)
  #expect(object["knownHostsFiles"] as? [String] == orb.knownHostsFiles)
  #expect(fixture.perform("hosts.save", ["profile": object]) == true)

  let reloaded = try SSHHostStore(fileURL: fixture.bridge.directory.store.fileURL).load()
  #expect(reloaded.first { $0.id == orb.id } == orb)
  let snapshotRow = try row("orb", in: fixture.bridge.snapshot())
  #expect(try SettingsHostsBridge.decodeProfile(snapshotRow["profile"]) == orb)

  // 表单把空文本框提交成空数组时也按「继承」处理。
  var cleared = SettingsHostsBridge.profileJSON(orb)
  cleared["knownHostsFiles"] = [String]()
  cleared["identitiesOnly"] = false
  #expect(fixture.perform("hosts.save", ["profile": cleared]) == true)
  let after = try #require(fixture.bridge.directory.host(orb.id))
  #expect(after.knownHostsFiles == nil)
  #expect(after.identitiesOnly == false)

  // 复制带上这两个字段。
  #expect(fixture.perform("hosts.duplicate", ["id": orb.id.uuidString]) == true)
  let copy = try #require(fixture.bridge.directory.savedHosts.first { $0.id != orb.id })
  #expect(copy.identitiesOnly == false && copy.knownHostsFiles == nil)
}

@Test("Agent 套接字随保存落盘并原样读回；空白存成 nil；控制字符被拒；复制带上它")
@MainActor
func settingsHostsSaveKeepsIdentityAgent() throws {
  let fixture = try HostsBridgeFixture()
  defer { fixture.cleanUp() }
  let host = SSHHostProfile(
    name: "vault", host: "10.0.0.9", user: "ops",
    identityAgent: "~/Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock")
  let object = SettingsHostsBridge.profileJSON(host)
  #expect(object["identityAgent"] as? String == host.identityAgent)
  #expect(fixture.perform("hosts.save", ["profile": object]) == true)
  let reloaded = try SSHHostStore(fileURL: fixture.bridge.directory.store.fileURL).load()
  #expect(reloaded.first { $0.id == host.id } == host)

  #expect(fixture.perform("hosts.duplicate", ["id": host.id.uuidString]) == true)
  let copy = try #require(fixture.bridge.directory.savedHosts.first { $0.id != host.id })
  #expect(copy.identityAgent == host.identityAgent)

  var broken = object
  broken["identityAgent"] = "/tmp/agent.sock\nProxyCommand evil"
  #expect(fixture.perform("hosts.save", ["profile": broken]) == false)
  #expect(fixture.bridge.directory.host(host.id)?.identityAgent == host.identityAgent)

  var cleared = object
  cleared["identityAgent"] = "   "
  #expect(fixture.perform("hosts.save", ["profile": cleared]) == true)
  #expect(fixture.bridge.directory.host(host.id)?.identityAgent == nil)
}
