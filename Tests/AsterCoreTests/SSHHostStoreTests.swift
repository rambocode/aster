import Foundation
import Testing

@testable import AsterCore

// 测 SSHHostStore：原子写入、有效快照、损坏恢复、规范化、逐条校验原因，
// 以及 hostsSharingCredential / hostsUsingJump 两个查询辅助函数。

/// 建一个私有临时目录；每个用例自带唯一路径，互不干扰。
private func temporaryHostsStoreURL() -> URL {
  URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("aster-ssh-hosts-\(UUID().uuidString)")
    .appendingPathComponent("hosts.json")
}

/// 测：save → load 原样往返。
@Test func sshHostStoreRoundTripsThroughDisk() throws {
  let url = temporaryHostsStoreURL()
  let store = SSHHostStore(fileURL: url)
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

  let host = SSHHostProfile(name: "Box", host: "10.0.0.1", user: "deploy")
  try store.save([host])

  let loaded = try store.load()
  #expect(loaded == SSHHostStore.normalized([host]))
  #expect(store.effectiveHosts == loaded)
}

/// 测：`normalized` 缺默认项时自动补上一条，并把它放到第一位。
@Test func sshHostStoreNormalizedInsertsMissingDefaultsFirst() {
  let host = SSHHostProfile(name: "Box", host: "10.0.0.1")
  let normalized = SSHHostStore.normalized([host])

  #expect(normalized.count == 2)
  #expect(normalized.first?.isDefaults == true)
  #expect(normalized.last?.id == host.id)
}

/// 测：分组名两端空白被裁掉，纯空白/空串规范化成 nil。
@Test func sshHostStoreNormalizedTrimsGroupNames() {
  let padded = SSHHostProfile(name: "A", group: "  work  ", host: "a")
  let blank = SSHHostProfile(name: "B", group: "   ", host: "b")
  let empty = SSHHostProfile(name: "C", group: "", host: "c")

  let normalized = SSHHostStore.normalized([padded, blank, empty])
  let byID: [UUID: SSHHostProfile] = Dictionary(uniqueKeysWithValues: normalized.map { ($0.id, $0) })

  #expect(byID[padded.id]?.group == "work")
  #expect(byID[blank.id]?.group == nil)
  #expect(byID[empty.id]?.group == nil)
}

/// 测：结构性校验失败——重复 id、空 name、空 host、host/user 里含换行。
@Test func sshHostStoreValidateReportsStructuralIssues() {
  let sharedID = UUID()
  let duplicateA = SSHHostProfile(id: sharedID, name: "A", host: "a.example.com")
  let duplicateB = SSHHostProfile(id: sharedID, name: "B", host: "b.example.com")
  let emptyName = SSHHostProfile(name: "", host: "c.example.com")
  let emptyHost = SSHHostProfile(name: "D", host: "")
  let newlineHost = SSHHostProfile(name: "E", host: "e.example\n.com")
  let newlineUser = SSHHostProfile(name: "F", host: "f.example.com", user: "us\ner")

  let reasons = SSHHostStore.validate([
    .emptyDefaults(), duplicateA, duplicateB, emptyName, emptyHost, newlineHost, newlineUser,
  ])

  #expect(reasons.contains { $0.contains("duplicate id") })
  #expect(reasons.contains { $0.contains("empty name") })
  #expect(reasons.contains { $0.contains("empty host") })
  #expect(reasons.filter { $0.contains("newline in host/user") }.count == 2)
}

/// 测：字段范围校验失败——分组过长、端口越界、代理非法、转发非法、跳板非法、负数计时。
@Test func sshHostStoreValidateReportsFieldRangeIssues() {
  let longGroup = SSHHostProfile(name: "A", group: String(repeating: "g", count: 65), host: "a")
  let newlineGroup = SSHHostProfile(name: "B", group: "line1\nline2", host: "b")
  let portZero = SSHHostProfile(name: "C", host: "c", port: 0)
  let portOverflow = SSHHostProfile(name: "D", host: "d", port: 65536)
  let badProxy = SSHHostProfile(
    name: "E", host: "e", socksProxy: SSHHostPort(host: "127.0.0.1", port: 0))
  let badForward = SSHHostProfile(
    name: "F", host: "f",
    forwards: [
      SSHForwardRule(
        kind: .local, bind: SSHHostPort(host: "0.0.0.0", port: 80),
        target: SSHHostPort(host: "internal", port: 0))
    ])
  let selfJumpID = UUID()
  let selfJump = SSHHostProfile(id: selfJumpID, name: "G", host: "g", jumpHostID: selfJumpID)
  let missingJump = SSHHostProfile(name: "H", host: "h", jumpHostID: UUID())
  let negativeKeepalive = SSHHostProfile(name: "I", host: "i", keepaliveInterval: -1)
  let negativeTimeout = SSHHostProfile(name: "J", host: "j", connectTimeout: -5)

  let reasons = SSHHostStore.validate([
    .emptyDefaults(), longGroup, newlineGroup, portZero, portOverflow, badProxy, badForward,
    selfJump, missingJump, negativeKeepalive, negativeTimeout,
  ])

  #expect(reasons.filter { $0.contains("invalid group") }.count == 2)
  #expect(reasons.filter { $0.contains("invalid port") }.count == 2)
  #expect(reasons.contains { $0.contains("invalid proxy") })
  #expect(reasons.contains { $0.contains("invalid forward") })
  #expect(reasons.filter { $0.contains("invalid jumpHostID") }.count == 2)
  #expect(reasons.filter { $0.contains("negative timing") }.count == 2)
}

/// 测：`save` 写入非法内容时抛 `.invalidHosts` 且完全不落盘。
@Test func sshHostStoreSaveRejectsInvalidHostsWithoutPersisting() throws {
  let url = temporaryHostsStoreURL()
  let store = SSHHostStore(fileURL: url)
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

  let good = SSHHostProfile(name: "Good", host: "good.example.com")
  try store.save([good])

  let bad = SSHHostProfile(name: "", host: "bad.example.com")
  do {
    try store.save([bad])
    Issue.record("expected invalidHosts")
  } catch let error as SSHHostStoreError {
    guard case .invalidHosts(let reasons) = error else {
      Issue.record("expected invalidHosts, got \(error)")
      return
    }
    #expect(reasons.contains { $0.contains("empty name") })
  }
  // 上一次合法快照必须原样保留，磁盘内容不受影响。
  #expect(try store.load().contains { $0.id == good.id })
  #expect(store.effectiveHosts.contains { $0.id == good.id })
}

/// 测：解码空数据、坏 JSON、未来版本号全部归类为 `.corrupted`。
@Test func sshHostStoreDecodeThrowsCorruptedForBadInput() throws {
  #expect(throws: SSHHostStoreError.self) { try SSHHostStore.decode(Data()) }
  do {
    _ = try SSHHostStore.decode(Data())
    Issue.record("expected corrupted")
  } catch let error as SSHHostStoreError {
    guard case .corrupted = error else {
      Issue.record("expected corrupted, got \(error)")
      return
    }
  }

  let badJSON = Data("{ not json at all".utf8)
  do {
    _ = try SSHHostStore.decode(badJSON)
    Issue.record("expected corrupted")
  } catch let error as SSHHostStoreError {
    guard case .corrupted = error else {
      Issue.record("expected corrupted, got \(error)")
      return
    }
  }

  let futureVersion = try JSONEncoder().encode(
    SSHHostDocument(version: SSHHostDocument.currentVersion + 1, hosts: [.emptyDefaults()]))
  do {
    _ = try SSHHostStore.decode(futureVersion)
    Issue.record("expected corrupted")
  } catch let error as SSHHostStoreError {
    guard case .corrupted(let detail) = error else {
      Issue.record("expected corrupted, got \(error)")
      return
    }
    #expect(detail.contains("version"))
  }
}

/// 测：文件不存在时 `load` 返回只含默认项的列表（合法的首次启动状态）。
@Test func sshHostStoreLoadReturnsOnlyDefaultsWhenFileMissing() throws {
  let url = temporaryHostsStoreURL()
  let store = SSHHostStore(fileURL: url)
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

  let loaded = try store.load()
  #expect(loaded.count == 1)
  #expect(loaded[0].isDefaults)
}

/// 测：写入目录 0700、文件 0600，且不留临时文件残余。
@Test func sshHostStoreSaveWritesPrivatePermissionsWithoutLeftovers() throws {
  let url = temporaryHostsStoreURL()
  let store = SSHHostStore(fileURL: url)
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

  try store.save([SSHHostProfile(name: "Box", host: "10.0.0.1")])

  let directoryMode = try FileManager.default.attributesOfItem(
    atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
  let fileMode =
    try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
  #expect(directoryMode?.int16Value == 0o700)
  #expect(fileMode?.int16Value == 0o600)

  let leftovers = try FileManager.default.contentsOfDirectory(
    atPath: url.deletingLastPathComponent().path)
  #expect(leftovers == ["hosts.json"])
}

/// 测：`applyExternalChange(data: nil)` 表示文件被外部删除，回落到只含默认项。
@Test func sshHostStoreApplyExternalChangeWithNilDataResetsToDefaults() throws {
  let url = temporaryHostsStoreURL()
  let store = SSHHostStore(fileURL: url)
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

  try store.save([SSHHostProfile(name: "Box", host: "10.0.0.1")])
  let result = try store.applyExternalChange(data: nil)

  #expect(result.count == 1)
  #expect(result[0].isDefaults)
  #expect(store.effectiveHosts.count == 1)
}

/// 测：`hostsSharingCredential` 找出同 `user@host:port` 的其它主机；
/// 端口不同则不算共享，默认项不计入，主机名为空（无法解析）时返回空。
@Test func sshHostStoreHostsSharingCredentialMatchesByEndpoint() {
  let hostA = SSHHostProfile(name: "A", host: "10.0.0.1", port: 22, user: "deploy")
  let hostB = SSHHostProfile(name: "B", host: "10.0.0.1", port: 22, user: "deploy")
  let hostDifferentPort = SSHHostProfile(name: "C", host: "10.0.0.1", port: 2222, user: "deploy")
  let defaults = SSHHostProfile.emptyDefaults()
  let hosts = [defaults, hostA, hostB, hostDifferentPort]

  let sharingA = SSHHostStore.hostsSharingCredential(with: hostA.id, in: hosts)
  #expect(sharingA.map(\.id) == [hostB.id])

  let sharingB = SSHHostStore.hostsSharingCredential(with: hostB.id, in: hosts)
  #expect(sharingB.map(\.id) == [hostA.id])

  let sharingDifferentPort = SSHHostStore.hostsSharingCredential(
    with: hostDifferentPort.id, in: hosts)
  #expect(sharingDifferentPort.isEmpty)

  let unresolvable = SSHHostProfile(name: "Bad", host: "")
  #expect(SSHHostStore.hostsSharingCredential(with: unresolvable.id, in: [unresolvable]).isEmpty)
}

/// 测：`hostsUsingJump` 找出把指定主机当跳板的其它主机。
@Test func sshHostStoreHostsUsingJumpFindsReferencingHosts() {
  let jumpHost = SSHHostProfile(name: "Jump", host: "jump.example.com")
  let userA = SSHHostProfile(name: "A", host: "a.example.com", jumpHostID: jumpHost.id)
  let userB = SSHHostProfile(name: "B", host: "b.example.com", jumpHostID: jumpHost.id)
  let unrelated = SSHHostProfile(name: "C", host: "c.example.com")

  let referencing = SSHHostStore.hostsUsingJump(
    jumpHost.id, in: [jumpHost, userA, userB, unrelated])

  #expect(Set(referencing.map(\.id)) == Set([userA.id, userB.id]))
}
