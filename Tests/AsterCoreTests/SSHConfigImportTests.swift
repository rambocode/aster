import Foundation
import Testing

@testable import AsterCore

// `~/.ssh/config` 导入合并的纯函数规则：组内按名去重、更新、跳板映射与非法条目跳过。

/// 顺序生成的固定 ID，便于断言新主机。
private func sequentialIDs() -> () -> UUID {
  var next = 0
  return {
    next += 1
    return UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", next))!
  }
}

@Test("首次导入：名称用 alias，主机缺省取 alias，放进导入组")
func sshConfigImportAddsHosts() {
  let listing = SSHConfigListing(hosts: [
    SSHConfigHostEntry(alias: "orb", hostName: "127.0.0.1", user: "root", port: 32222, identityFiles: ["~/.orbstack/ssh/id_ed25519"]),
    SSHConfigHostEntry(alias: "plain"),
    SSHConfigHostEntry(alias: "*.internal", user: "ops"),
  ])
  let result = SSHConfigImport.merge(listing, into: [.emptyDefaults()], makeID: sequentialIDs())

  #expect(result.added == 2)
  #expect(result.updated == 0 && result.unchanged == 0)
  #expect(result.hosts.first?.isDefaults == true)
  let orb = result.hosts[1]
  #expect(orb.name == "orb" && orb.host == "127.0.0.1" && orb.port == 32222 && orb.user == "root")
  #expect(orb.group == SSHHostProfile.importedGroup)
  #expect(orb.identityFiles == ["~/.orbstack/ssh/id_ed25519"])
  #expect(result.hosts[2].host == "plain")
  // 通配模式不是具体主机，不导入。
  #expect(!result.hosts.contains { $0.name == "*.internal" })
}

@Test("再次导入按名称在导入组内更新：保留 ID 与 Aster 自有字段，统计更新与未变")
func sshConfigImportUpdatesInPlace() {
  var existing = SSHHostProfile(
    name: "orb", group: SSHHostProfile.importedGroup, host: "127.0.0.1", port: 32222, user: "root",
    auth: .password, verifyHostKeys: false)
  let same = SSHHostProfile(name: "same", group: SSHHostProfile.importedGroup, host: "same.example.com")
  // 同名但不在导入组：用户自己建的主机，导入不能覆盖它。
  let manual = SSHHostProfile(name: "orb", group: "lab", host: "10.0.0.9")
  let listing = SSHConfigListing(hosts: [
    SSHConfigHostEntry(alias: "orb", hostName: "127.0.0.2", user: "root", port: 32222),
    SSHConfigHostEntry(alias: "orb", hostName: "ignored.example.com"),
    SSHConfigHostEntry(alias: "same", hostName: "same.example.com"),
  ])
  let result = SSHConfigImport.merge(listing, into: [.emptyDefaults(), existing, same, manual])

  #expect(result.added == 0)
  #expect(result.updated == 1)
  #expect(result.unchanged == 1)
  #expect(result.hosts.count == 4)
  existing.host = "127.0.0.2"
  // 同名重复出现时第一条生效；认证方式与主机密钥校验是 Aster 自有设置，原样保留。
  #expect(result.hosts[1] == existing)
  #expect(result.hosts[3] == manual)
}

@Test("ProxyJump 第一跳映射到已导入的 alias，找不到时留空并写进报告")
func sshConfigImportMapsJumpHosts() {
  let listing = SSHConfigListing(
    hosts: [
      SSHConfigHostEntry(alias: "db", hostName: "10.0.0.5", proxyJump: "ops@bastion:2222,other"),
      SSHConfigHostEntry(alias: "bastion", hostName: "bastion.example.com"),
      SSHConfigHostEntry(alias: "cache", proxyJump: "unknown.example.com"),
      SSHConfigHostEntry(alias: "v6", proxyJump: "[bastion]:22"),
      SSHConfigHostEntry(alias: "direct", proxyJump: "none"),
    ],
    ignored: [SSHConfigIgnoredOption(file: "~/.ssh/config", line: 3, option: "Match", reason: "unsupported")])
  let result = SSHConfigImport.merge(listing, into: [.emptyDefaults()])
  let byName = Dictionary(uniqueKeysWithValues: result.hosts.map { ($0.name, $0) })
  let bastion = byName["bastion"]!

  #expect(byName["db"]?.jumpHostID == bastion.id)
  #expect(byName["v6"]?.jumpHostID == bastion.id)
  #expect(byName["cache"]?.jumpHostID == nil)
  #expect(byName["direct"]?.jumpHostID == nil)
  #expect(result.unresolvedJumps == [SSHConfigUnresolvedJump(host: "cache", proxyJump: "unknown.example.com")])
  #expect(result.ignored.map(\.option) == ["Match"])
  #expect(SSHHostStore.validate(result.hosts).isEmpty)
}

@Test("参数非法的条目整条跳过并报告，不拖垮其它主机")
func sshConfigImportRejectsInvalidEntries() {
  let listing = SSHConfigListing(hosts: [
    SSHConfigHostEntry(alias: "bad", port: 70_000),
    SSHConfigHostEntry(alias: "good", hostName: "good.example.com"),
  ])
  let result = SSHConfigImport.merge(listing, into: [.emptyDefaults()])

  #expect(result.added == 1)
  #expect(result.rejected == [SSHConfigRejectedHost(alias: "bad", reasons: ["invalid port"])])
  #expect(result.hosts.map(\.name) == ["Defaults", "good"])
}

@Test("跳板第一跳的主机名解析")
func sshConfigImportParsesFirstHop() {
  #expect(SSHConfigImport.firstHopAlias("bastion") == "bastion")
  #expect(SSHConfigImport.firstHopAlias("ops@bastion:2222, second") == "bastion")
  #expect(SSHConfigImport.firstHopAlias("ssh://ops@bastion:22") == "bastion")
  #expect(SSHConfigImport.firstHopAlias("[fe80::1]:22") == "fe80::1")
  #expect(SSHConfigImport.firstHopAlias("fe80::1") == "fe80::1")
  #expect(SSHConfigImport.firstHopAlias("none") == nil)
  #expect(SSHConfigImport.firstHopAlias(" ") == nil)
}

/// 测：导入带上 `UserKnownHostsFile` 与 `IdentitiesOnly`；旧版输出缺这两个键时照常解码。
@Test func sshConfigImportCarriesKnownHostsAndIdentitiesOnly() throws {
  let json = #"{"hosts":[{"alias":"orb","hostName":"127.0.0.1","port":32222,"identityFiles":[],"#
    + #""userKnownHostsFiles":["~/.orbstack/ssh/known_hosts"],"identitiesOnly":true,"forwards":[]},"#
    + #"{"alias":"legacy","identityFiles":[],"forwards":[]}],"ignored":[]}"#
  let listing = try JSONDecoder().decode(SSHConfigListing.self, from: Data(json.utf8))
  #expect(listing.hosts[1].userKnownHostsFiles.isEmpty)
  let result = SSHConfigImport.merge(listing, into: [.emptyDefaults()])
  let orb = try #require(result.hosts.first { $0.name == "orb" })
  #expect(orb.knownHostsFiles == ["~/.orbstack/ssh/known_hosts"])
  #expect(orb.identitiesOnly == true)
  let legacy = try #require(result.hosts.first { $0.name == "legacy" })
  #expect(legacy.knownHostsFiles == nil)
}
