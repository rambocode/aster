// SSHCredentialStore 的真实钥匙串读写。每个用例用独立的 service 后缀，结束时清理。
import Foundation
import Security
import Testing

@testable import Aster

/// 测试宿主拿不到钥匙串时的 OSStatus：缺 entitlement、不能交互、钥匙串不可用或不存在。
private let keychainUnavailableStatuses: Set<OSStatus> = [
  errSecMissingEntitlement, errSecInteractionNotAllowed, errSecNotAvailable, errSecNoSuchKeychain,
]

/// 探测一次写入与删除；只有上面列出的「不可用」状态才跳过，其它错误照常暴露为失败。
private let keychainAvailable: Bool = {
  let probe = SSHCredentialStore(serviceSuffix: ".tests.probe.\(UUID().uuidString)")
  do {
    try probe.setPassword("probe", for: "probe@localhost:22")
    try probe.deletePassword(for: "probe@localhost:22")
    return true
  } catch SSHCredentialStoreError.keychain(let status) {
    return !keychainUnavailableStatuses.contains(status)
  } catch {
    return true
  }
}()

/// 每个用例独立的存储，避免并行或残留条目互相干扰。
private func isolatedStore() -> SSHCredentialStore {
  SSHCredentialStore(serviceSuffix: ".tests.\(UUID().uuidString)")
}

/// 读一个不存在的口令返回 nil，写入后能读回，覆盖写入取最新值。
@Test(.enabled(if: keychainAvailable, "测试宿主无法访问登录钥匙串"))
func sshCredentialStorePasswordRoundTripAndOverwrite() throws {
  let store = isolatedStore()
  let endpoint = "deploy@10.0.0.5:22"
  defer { #expect(throws: Never.self) { try store.deletePassword(for: endpoint) } }

  #expect(try store.password(for: endpoint) == nil)
  #expect(!store.hasPassword(for: endpoint))

  try store.setPassword("hunter2", for: endpoint)
  #expect(try store.password(for: endpoint) == "hunter2")
  #expect(store.hasPassword(for: endpoint))

  try store.setPassword("口令-ünïcode", for: endpoint)
  #expect(try store.password(for: endpoint) == "口令-ünïcode")
}

/// 删除后读不到；删除不存在的条目不报错。
@Test(.enabled(if: keychainAvailable, "测试宿主无法访问登录钥匙串"))
func sshCredentialStoreDeleteIsIdempotent() throws {
  let store = isolatedStore()
  let endpoint = "root@[::1]:2222"
  try store.setPassword("secret", for: endpoint)
  try store.deletePassword(for: endpoint)
  #expect(try store.password(for: endpoint) == nil)
  #expect(!store.hasPassword(for: endpoint))
  try store.deletePassword(for: endpoint)
  try store.deletePassphrase(forKeyDigest: "never-stored")
}

/// passphrase 与口令用不同的 service，互不覆盖；service 后缀隔离真实条目。
@Test(.enabled(if: keychainAvailable, "测试宿主无法访问登录钥匙串"))
func sshCredentialStorePassphraseUsesSeparateService() throws {
  let store = isolatedStore()
  let digest = String(repeating: "ab", count: 64)
  defer {
    #expect(throws: Never.self) {
      try store.deletePassphrase(forKeyDigest: digest)
      try store.deletePassword(for: digest)
    }
  }

  #expect(try store.passphrase(forKeyDigest: digest) == nil)
  try store.setPassphrase("pass-1", forKeyDigest: digest)
  try store.setPassphrase("pass-2", forKeyDigest: digest)
  #expect(try store.passphrase(forKeyDigest: digest) == "pass-2")
  // 同一个账户名在口令 service 下不存在。
  #expect(try store.password(for: digest) == nil)
  // 生产 service（空后缀）下也看不到测试条目。
  #expect(try SSHCredentialStore().passphrase(forKeyDigest: digest) == nil)

  try store.deletePassphrase(forKeyDigest: digest)
  #expect(try store.passphrase(forKeyDigest: digest) == nil)
}
