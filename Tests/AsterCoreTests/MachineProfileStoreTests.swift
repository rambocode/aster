import Foundation
import Testing

@testable import AsterCore

/// P4.5：配置原子写入、有效快照、损坏恢复与「重命名不重连」（A13/A14.3）。

/// 建一个私有临时目录；每个用例自带唯一路径，互不干扰。
private func temporaryStoreURL() -> URL {
  let directory = URL(fileURLWithPath: NSTemporaryDirectory())
    .appendingPathComponent("aster-p4-machines-\(UUID().uuidString)")
  return directory.appendingPathComponent("machines.json")
}

private func sampleProfiles() -> [MachineProfile] {
  [
    MachineProfile(label: "Local", sshTarget: nil, sessionName: "default", enabled: true),
    MachineProfile(
      label: "Build box", sshTarget: "root@ubuntu@orb", sessionName: "work", enabled: true),
  ]
}

@Test func remoteWorkP4StoreWritesPrivatePermissionsAtomically() throws {
  let url = temporaryStoreURL()
  let store = MachineProfileStore(fileURL: url)
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

  try store.save(sampleProfiles())

  let directoryMode = try FileManager.default.attributesOfItem(
    atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
  let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions]
    as? NSNumber
  #expect(directoryMode?.int16Value == 0o700)
  #expect(fileMode?.int16Value == 0o600)

  // 临时文件必须已经被 rename 掉，不留残余。
  let leftovers = try FileManager.default.contentsOfDirectory(
    atPath: url.deletingLastPathComponent().path)
  #expect(leftovers == ["machines.json"])
}

@Test func remoteWorkP4StoreNeverPersistsCredentials() throws {
  let data = try MachineProfileStore.encode(sampleProfiles())
  let text = String(decoding: data, as: UTF8.self)
  let json = try JSONSerialization.jsonObject(with: data) as! [[String: Any]]

  // 只允许出现规格里列出的字段：不透明 ID、标签、原始 SSH target、命名会话、enabled。
  for object in json {
    #expect(Set(object.keys).isSubset(of: MachineProfileStore.allowedKeys))
  }
  for forbidden in ["password", "passphrase", "privateKey", "identityFile", "socket", "token"] {
    #expect(!text.lowercased().contains(forbidden.lowercased()))
  }
}

@Test func remoteWorkP4StoreRoundTripsThroughDisk() throws {
  let url = temporaryStoreURL()
  let store = MachineProfileStore(fileURL: url)
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

  let profiles = sampleProfiles()
  try store.save(profiles)
  #expect(try store.load() == .loaded(profiles))
  #expect(store.effectiveProfiles == profiles)
}

@Test func remoteWorkP4StoreDistinguishesMissingFileFromCorruption() throws {
  let url = temporaryStoreURL()
  let store = MachineProfileStore(fileURL: url)
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

  // 文件不存在：合法的首次启动状态。
  #expect(try store.load() == .absent)

  // 每次 sampleProfiles() 都会生成新的随机 ID，所以先固定一份再断言快照不变。
  let saved = sampleProfiles()
  try store.save(saved)
  try Data("{ this is not json".utf8).write(to: url)

  // 内容损坏：明确报错，绝不当成空配置。
  do {
    _ = try store.load()
    Issue.record("expected corruption error")
  } catch let error as MachineProfileStoreError {
    guard case .corrupted = error else {
      Issue.record("expected corrupted, got \(error)")
      return
    }
  }
  // 有效快照保持不变，现存连接因此不受影响。
  #expect(store.effectiveProfiles == saved)
}

@Test func remoteWorkP4StoreRejectsWholeFileWhenOneEntryIsInvalid() throws {
  let url = temporaryStoreURL()
  let store = MachineProfileStore(fileURL: url)
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let saved = sampleProfiles()
  try store.save(saved)

  let mixed = try JSONSerialization.data(withJSONObject: [
    ["id": UUID().uuidString, "label": "Good", "sessionName": "work", "enabled": true],
    ["id": "not-a-uuid", "label": "Bad", "sessionName": "work", "enabled": true],
  ])

  do {
    _ = try store.applyExternalChange(data: mixed)
    Issue.record("expected invalidProfiles")
  } catch let error as MachineProfileStoreError {
    guard case .invalidProfiles(let reasons) = error else {
      Issue.record("expected invalidProfiles, got \(error)")
      return
    }
    #expect(reasons.count == 1)
    #expect(reasons[0].contains("invalid id"))
  }
  // 整份拒绝：合法的那条也不会被部分应用。
  #expect(store.effectiveProfiles == saved)
}

@Test func remoteWorkP4StoreRejectsUnknownKeys() throws {
  let url = temporaryStoreURL()
  let store = MachineProfileStore(fileURL: url)
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  let withSecret = try JSONSerialization.data(withJSONObject: [
    [
      "id": UUID().uuidString, "label": "Bad", "sessionName": "work", "enabled": true,
      "password": "hunter2",
    ]
  ])
  do {
    _ = try store.applyExternalChange(data: withSecret)
    Issue.record("expected invalidProfiles")
  } catch let error as MachineProfileStoreError {
    guard case .invalidProfiles(let reasons) = error else {
      Issue.record("expected invalidProfiles, got \(error)")
      return
    }
    #expect(reasons[0].contains("password"))
  }
}

@Test func remoteWorkP4StoreExternalDeletionIsNotCorruption() throws {
  let url = temporaryStoreURL()
  let store = MachineProfileStore(fileURL: url)
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  try store.save(sampleProfiles())
  // nil 表示文件被外部删除：这是空配置，不是损坏。
  #expect(try store.applyExternalChange(data: nil) == .absent)
  #expect(store.effectiveProfiles.isEmpty)
}

@Test func remoteWorkP4StoreAppliesValidExternalChangeAtOnce() throws {
  let url = temporaryStoreURL()
  let store = MachineProfileStore(fileURL: url)
  defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
  try store.save(sampleProfiles())
  let updated = [
    MachineProfile(label: "Only", sshTarget: "host", sessionName: "work", enabled: false)
  ]
  #expect(try store.applyExternalChange(data: try MachineProfileStore.encode(updated)) == .loaded(updated))
  #expect(store.effectiveProfiles == updated)
}

@Test func remoteWorkP4RenameDoesNotRequireReconnect() {
  let original = sampleProfiles()
  var renamed = original
  renamed[1].label = "Renamed box"

  // 只改标签：diff 为空，重连集合为空。
  #expect(MachineProfileStore.diff(old: original, new: renamed).isEmpty)
  #expect(MachineProfileStore.reconnectRequiredProfileIDs(old: original, new: renamed).isEmpty)
}

@Test func remoteWorkP4DiffDetectsConnectionRelevantChanges() {
  let original = sampleProfiles()

  var retargeted = original
  retargeted[1].sshTarget = "root@other@orb"
  #expect(
    MachineProfileStore.diff(old: original, new: retargeted)
      == [.connectionChanged(original[1].id)])

  var rebound = original
  rebound[1].sessionName = "build"
  #expect(MachineProfileStore.diff(old: original, new: rebound) == [.connectionChanged(original[1].id)])

  var disabled = original
  disabled[1].enabled = false
  #expect(MachineProfileStore.diff(old: original, new: disabled) == [.enabledChanged(original[1].id)])

  let removed = [original[0]]
  #expect(MachineProfileStore.diff(old: original, new: removed) == [.removed(original[1].id)])
  // 移除只需要断开，不需要重连。
  #expect(MachineProfileStore.reconnectRequiredProfileIDs(old: original, new: removed).isEmpty)

  let added = original + [MachineProfile(label: "New", sshTarget: "n", sessionName: "s")]
  #expect(MachineProfileStore.reconnectRequiredProfileIDs(old: original, new: added).count == 1)
}
