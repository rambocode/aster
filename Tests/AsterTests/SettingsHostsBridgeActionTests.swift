import Foundation
import Testing

@testable import Aster
@testable import AsterCore

// 设置页「主机」分类的行动作：删除、忘记口令、复制、添加为机器、导入与编辑 ~/.ssh/config。
// 夹具见 SettingsHostsBridgeTests.swift。

@Test("删除主机清掉跳板引用；口令只在没有其它主机共用时才一起删除")
@MainActor
func settingsHostsDeleteHonorsSharedCredentials() throws {
  let web = SSHHostProfile(name: "web", host: "web.example.com", user: "deploy")
  let webAlt = SSHHostProfile(name: "web-alt", group: "prod", host: "web.example.com", user: "deploy")
  let api = SSHHostProfile(name: "api", host: "api.example.com", user: "deploy", jumpHostID: web.id)
  let fixture = try HostsBridgeFixture(hosts: [web, webAlt, api])
  defer { fixture.cleanUp() }
  fixture.passwords.saved = ["deploy@web.example.com:22", "deploy@api.example.com:22"]

  // web 与 web-alt 共用 endpoint：删 web 不能删掉 web-alt 还在用的口令。
  #expect(fixture.perform("hosts.delete", ["id": web.id.uuidString]) == true)
  #expect(fixture.passwords.deleted.isEmpty)
  #expect(fixture.bridge.directory.host(web.id) == nil)
  #expect(fixture.bridge.directory.host(api.id)?.jumpHostID == nil)

  // api 的口令没人共用，删主机时一起删。
  #expect(fixture.perform("hosts.delete", ["id": api.id.uuidString]) == true)
  #expect(fixture.passwords.deleted == ["deploy@api.example.com:22"])

  // 默认项与不存在的主机都不能删。
  #expect(fixture.perform("hosts.delete", ["id": SSHHostProfile.defaultsProfileID.uuidString]) == false)
  #expect(fixture.perform("hosts.delete", ["id": UUID().uuidString]) == false)
  #expect(fixture.recorder.toasts.last?.isError == true)
}

@Test("忘记口令按 endpoint 删除，快照列出共用它的主机")
@MainActor
func settingsHostsForgetPasswordListsSharingHosts() throws {
  let web = SSHHostProfile(name: "web", host: "web.example.com", user: "deploy")
  let webAlt = SSHHostProfile(name: "web-alt", host: "web.example.com", port: 22, user: "deploy")
  let fixture = try HostsBridgeFixture(hosts: [web, webAlt])
  defer { fixture.cleanUp() }
  fixture.passwords.saved = ["deploy@web.example.com:22"]

  let rows = try #require(fixture.bridge.snapshot()["hosts"] as? [[String: Any]])
  let webRow = try #require(rows.first { ($0["profile"] as? [String: Any])?["name"] as? String == "web" })
  #expect(webRow["credentialSharedWith"] as? [String] == ["web-alt"])
  #expect(
    SSHHostStore.hostsSharingCredential(with: web.id, in: fixture.bridge.directory.hosts).map(\.name)
      == ["web-alt"])

  #expect(fixture.perform("hosts.forgetPassword", ["id": web.id.uuidString]) == true)
  #expect(fixture.passwords.deleted == ["deploy@web.example.com:22"])
  #expect(fixture.recorder.toasts.last?.isError == false)
  let after = try #require(fixture.bridge.snapshot()["hosts"] as? [[String: Any]])
  #expect(after.allSatisfy { $0["hasPassword"] as? Bool == false })
}

@Test("复制主机生成新 ID，导入组的副本放到未分组；添加为机器带上主机预填")
@MainActor
func settingsHostsDuplicateAndAddMachine() throws {
  let imported = SSHHostProfile(
    name: "orb", group: SSHHostProfile.importedGroup, host: "127.0.0.1", port: 32222, user: "root")
  let fixture = try HostsBridgeFixture(hosts: [imported])
  defer { fixture.cleanUp() }

  #expect(fixture.perform("hosts.duplicate", ["id": imported.id.uuidString]) == true)
  let copy = try #require(fixture.bridge.directory.savedHosts.first { $0.id != imported.id })
  #expect(copy.name == "orb 副本")
  #expect(copy.group == nil)
  #expect(copy.host == imported.host && copy.port == imported.port && copy.user == imported.user)

  #expect(fixture.perform("hosts.addMachine", ["id": imported.id.uuidString]) == true)
  #expect(fixture.recorder.addMachineRequests == [MachineSetupFlow.Prefill(label: "orb", hostID: imported.id)])
}

@Test("导入 ~/.ssh/config：桩抛错时给出可读 toast，成功时保存并发出汇总")
@MainActor
func settingsHostsImportReportsResult() async throws {
  let failing = try HostsBridgeFixture()
  defer { failing.cleanUp() }
  #expect(await failing.performAsync("hosts.import") == false)
  #expect(failing.recorder.toasts.last?.text.contains("找不到 aster-ssh") == true)

  let listing = SSHConfigListing(
    hosts: [
      SSHConfigHostEntry(alias: "bastion", hostName: "bastion.example.com", user: "ops"),
      SSHConfigHostEntry(alias: "db", hostName: "10.0.0.5", proxyJump: "ops@bastion:22"),
    ],
    ignored: [SSHConfigIgnoredOption(file: "~/.ssh/config", line: 12, option: "Match", reason: "unsupported")])
  let fixture = try HostsBridgeFixture(listing: .success(listing))
  defer { fixture.cleanUp() }
  #expect(await fixture.performAsync("hosts.import") == true)

  let saved = try SSHHostStore(fileURL: fixture.bridge.directory.store.fileURL).load()
  let bastion = try #require(saved.first { $0.name == "bastion" })
  #expect(saved.first { $0.name == "db" }?.jumpHostID == bastion.id)
  let report = try #require(fixture.recorder.messages.last?["report"] as? [String: Any])
  #expect(fixture.recorder.messages.last?["type"] as? String == "hostsImportReport")
  #expect(report["added"] as? Int == 2)
  #expect((report["ignored"] as? [[String: Any]])?.first?["option"] as? String == "Match")
}

@Test("在 ~/.ssh/config 中编辑：文件不存在时建 0700 目录与 0600 空文件再打开")
@MainActor
func settingsHostsEditSSHConfigCreatesPrivateFile() async throws {
  let fixture = try HostsBridgeFixture()
  defer { fixture.cleanUp() }
  let url = fixture.root.appendingPathComponent("ssh/config")

  #expect(await fixture.performAsync("hosts.editSSHConfig") == true)
  #expect(fixture.recorder.openedFiles == [url])
  let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
  let directoryMode = try FileManager.default.attributesOfItem(
    atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? Int
  #expect(fileMode == 0o600)
  #expect(directoryMode == 0o700)

  // 已存在的文件原样保留，不改内容。
  try "Host keep\n".write(to: url, atomically: true, encoding: .utf8)
  #expect(await fixture.performAsync("hosts.editSSHConfig") == true)
  #expect(try String(contentsOf: url, encoding: .utf8) == "Host keep\n")
}

@Test("设置页把 hosts. 前缀动作转交主机协作者")
@MainActor
func settingsRoutesHostActionsToBridge() throws {
  let suite = "SettingsHostsRoute.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let host = SSHHostProfile(name: "gone", host: "gone.example.com")
  let fixture = try HostsBridgeFixture(hosts: [host])
  defer { fixture.cleanUp() }
  let controller = SettingsViewController(
    preferences: AppPreferences(defaults: defaults), hostsBridge: fixture.bridge)
  controller.loadViewIfNeeded()

  controller.applyThemeActionForTesting("hosts.delete", payload: ["id": host.id.uuidString])
  #expect(fixture.bridge.directory.host(host.id) == nil)
}

@Test("本页动作不重复推快照；外部修改 hosts.json 才请求刷新")
@MainActor
func settingsHostsRefreshesOnlyOnExternalChanges() async throws {
  let fixture = try HostsBridgeFixture(hosts: [SSHHostProfile(name: "a", host: "a.example.com")])
  defer { fixture.cleanUp() }
  let bridge = fixture.bridge
  var refreshes = 0
  // 与设置页接线一致：推快照就是重建一次快照。
  bridge.pushSnapshot = { _ = bridge.snapshot() }
  bridge.scheduleRefresh = { refreshes += 1 }
  bridge.start()
  _ = bridge.snapshot()

  let added = SSHHostProfile(name: "b", host: "b.example.com")
  #expect(fixture.perform("hosts.save", ["profile": SettingsHostsBridge.profileJSON(added)]) == true)
  try await Task.sleep(for: .milliseconds(50))
  #expect(refreshes == 0)

  // 另一个写者直接改文件，再由目录重载（等价于文件监听触发）。
  let other = SSHHostStore(fileURL: bridge.directory.store.fileURL)
  try other.save(bridge.directory.hosts + [SSHHostProfile(name: "c", host: "c.example.com")])
  bridge.directory.reload()
  try await Task.sleep(for: .milliseconds(50))
  #expect(refreshes >= 1)
}
