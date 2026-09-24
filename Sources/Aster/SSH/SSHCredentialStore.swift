import AsterCore
import Foundation

// SSH 凭证的钥匙串存取（P0 接口桩，由钥匙串包实现）。
// 口令：service `io.aster.ssh`，账户 `user@host:port`；
// 私钥 passphrase：service `io.aster.ssh-key`，账户是私钥文件内容 SHA-512 的小写 hex。
// 秘密只进钥匙串，永不写文件或日志。

/// 钥匙串访问失败。
enum SSHCredentialStoreError: Error, Equatable {
  case keychain(OSStatus)
}

/// SSH 凭证存储。
struct SSHCredentialStore: Sendable {
  static let passwordService = "io.aster.ssh"
  static let passphraseService = "io.aster.ssh-key"

  /// 测试用前缀，避免污染真实条目；生产为空。
  var serviceSuffix: String

  init(serviceSuffix: String = "") { self.serviceSuffix = serviceSuffix }

  /// 读取某个 endpoint 的口令；不存在返回 nil。
  func password(for endpoint: String) throws -> String? { nil }
  /// 保存口令（覆盖已有值）。
  func setPassword(_ password: String, for endpoint: String) throws {}
  /// 删除口令；不存在不算错误。
  func deletePassword(for endpoint: String) throws {}
  /// 是否已保存口令（设置页显示「忘记口令」用）。
  func hasPassword(for endpoint: String) -> Bool { false }

  /// 读取私钥 passphrase。
  func passphrase(forKeyDigest digest: String) throws -> String? { nil }
  /// 保存私钥 passphrase。
  func setPassphrase(_ passphrase: String, forKeyDigest digest: String) throws {}
  /// 删除私钥 passphrase。
  func deletePassphrase(forKeyDigest digest: String) throws {}
}
