import Foundation

// 已保存 SSH 主机的持久化：`~/Library/Application Support/Aster/hosts.json`。
//
// 规则与 `MachineProfileStore` 一致：整份校验通过才替换有效快照；文件不存在与内容损坏
// 是两种结果；写入走同目录临时文件 + rename，目录 0700、文件 0600。文件里没有任何秘密字段，
// 类型层面就不存在口令或私钥。

/// 主机存储错误，全部可恢复：调用方保留最后有效快照即可。
public enum SSHHostStoreError: Error, Equatable, Sendable {
  case corrupted(detail: String)
  case invalidHosts(reasons: [String])
  case ioFailure(detail: String)
}

/// hosts.json 的根对象。带版本号，便于以后迁移。
struct SSHHostDocument: Codable, Equatable {
  static let currentVersion = 1
  var version: Int
  var hosts: [SSHHostProfile]
}

/// 主机配置存储。线程安全：锁保护最后有效快照。
public final class SSHHostStore: @unchecked Sendable {
  /// 分组名的最大 UTF-8 字节数。
  public static let maximumGroupBytes = 64

  /// 默认路径：`~/Library/Application Support/Aster/hosts.json`。
  public static func defaultFileURL(fileManager: FileManager = .default) -> URL {
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("Aster/hosts.json")
  }

  public let fileURL: URL
  private let fileManager: FileManager
  private let lock = NSLock()
  private var lastValid: [SSHHostProfile] = [.emptyDefaults()]

  public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
  }

  /// 最后一份有效快照，默认项总在第一位。
  public var effectiveHosts: [SSHHostProfile] {
    lock.lock()
    defer { lock.unlock() }
    return lastValid
  }

  /// 从磁盘加载。文件不存在时返回只含默认项的列表（合法的首次启动）。
  @discardableResult
  public func load() throws -> [SSHHostProfile] {
    guard fileManager.fileExists(atPath: fileURL.path) else {
      return replaceSnapshot([.emptyDefaults()])
    }
    let data: Data
    do { data = try Data(contentsOf: fileURL) } catch {
      throw SSHHostStoreError.ioFailure(detail: String(describing: error))
    }
    return replaceSnapshot(try Self.decode(data))
  }

  /// 外部变更入口（文件监听读出内容后交给它）；nil 表示文件被删除。
  @discardableResult
  public func applyExternalChange(data: Data?) throws -> [SSHHostProfile] {
    guard let data else { return replaceSnapshot([.emptyDefaults()]) }
    return replaceSnapshot(try Self.decode(data))
  }

  /// 原子写入并替换有效快照。写入前整份校验，非法内容不会落盘。
  public func save(_ hosts: [SSHHostProfile]) throws {
    let normalized = Self.normalized(hosts)
    let reasons = Self.validate(normalized)
    guard reasons.isEmpty else { throw SSHHostStoreError.invalidHosts(reasons: reasons) }
    let data = try Self.encode(normalized)
    do {
      try PrivateFileWriter.write(data, to: fileURL, fileManager: fileManager)
    } catch {
      throw SSHHostStoreError.ioFailure(detail: String(describing: error))
    }
    replaceSnapshot(normalized)
  }

  @discardableResult
  private func replaceSnapshot(_ hosts: [SSHHostProfile]) -> [SSHHostProfile] {
    lock.lock()
    lastValid = hosts
    lock.unlock()
    return hosts
  }

  // MARK: - 编解码与校验

  /// 解码并整份校验。解析失败与内容非法分成两种错误。
  public static func decode(_ data: Data) throws -> [SSHHostProfile] {
    guard !data.isEmpty else { throw SSHHostStoreError.corrupted(detail: "empty file") }
    let document: SSHHostDocument
    do { document = try JSONDecoder().decode(SSHHostDocument.self, from: data) } catch {
      throw SSHHostStoreError.corrupted(detail: String(describing: error))
    }
    guard document.version <= SSHHostDocument.currentVersion else {
      throw SSHHostStoreError.corrupted(detail: "unsupported version \(document.version)")
    }
    let hosts = normalized(document.hosts)
    let reasons = validate(hosts)
    guard reasons.isEmpty else { throw SSHHostStoreError.invalidHosts(reasons: reasons) }
    return hosts
  }

  /// 编码成带版本号的稳定 JSON（键排序，便于人工查看与比较）。
  public static func encode(_ hosts: [SSHHostProfile]) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    do {
      return try encoder.encode(
        SSHHostDocument(version: SSHHostDocument.currentVersion, hosts: hosts))
    } catch {
      throw SSHHostStoreError.ioFailure(detail: String(describing: error))
    }
  }

  /// 规范化：默认项放到第一位（缺失就补上），分组名去空白、空串变 nil。
  public static func normalized(_ hosts: [SSHHostProfile]) -> [SSHHostProfile] {
    var defaults = hosts.first { $0.isDefaults } ?? .emptyDefaults()
    defaults.group = nil
    let others = hosts.filter { !$0.isDefaults }.map { profile -> SSHHostProfile in
      var copy = profile
      let group = copy.group?.trimmingCharacters(in: .whitespacesAndNewlines)
      copy.group = (group?.isEmpty ?? true) ? nil : group
      copy.name = copy.name.trimmingCharacters(in: .whitespacesAndNewlines)
      copy.host = copy.host.trimmingCharacters(in: .whitespacesAndNewlines)
      copy.user = copy.user.trimmingCharacters(in: .whitespacesAndNewlines)
      return copy
    }
    return [defaults] + others
  }

  /// 逐条校验，返回全部原因；空数组表示合法。
  public static func validate(_ hosts: [SSHHostProfile]) -> [String] {
    var reasons: [String] = []
    var seen: Set<UUID> = []
    let ids = Set(hosts.map(\.id))
    for (index, host) in hosts.enumerated() {
      let tag = "[\(index)]"
      if !seen.insert(host.id).inserted { reasons.append("\(tag) duplicate id") }
      if !host.isDefaults {
        if host.name.isEmpty { reasons.append("\(tag) empty name") }
        if host.host.isEmpty { reasons.append("\(tag) empty host") }
      }
      if host.host.contains(where: \.isNewline) || host.user.contains(where: \.isNewline) {
        reasons.append("\(tag) newline in host/user")
      }
      if let group = host.group {
        if group.utf8.count > maximumGroupBytes || group.contains(where: \.isNewline) {
          reasons.append("\(tag) invalid group")
        }
      }
      if let port = host.port, !(1...65535).contains(port) { reasons.append("\(tag) invalid port") }
      for proxy in [host.socksProxy, host.httpProxy].compactMap({ $0 })
      where !(1...65535).contains(proxy.port) || proxy.host.isEmpty {
        reasons.append("\(tag) invalid proxy")
      }
      for rule in host.forwards {
        let targetOK = rule.kind == .dynamic || (1...65535).contains(rule.target.port)
        if !(0...65535).contains(rule.bind.port) || !targetOK {
          reasons.append("\(tag) invalid forward")
        }
      }
      if let jump = host.jumpHostID, jump == host.id || !ids.contains(jump) {
        reasons.append("\(tag) invalid jumpHostID")
      }
      for value in [host.keepaliveInterval, host.keepaliveCountMax, host.connectTimeout]
      where (value ?? 0) < 0 {
        reasons.append("\(tag) negative timing")
      }
    }
    return reasons
  }

  // MARK: - 查询

  /// 与指定主机共用同一凭证 endpoint 的其它主机（删除口令前提示用；对应 tty7
  /// `profiles_sharing_endpoint`）。无法解析的主机不计入。
  public static func hostsSharingCredential(
    with id: UUID, in hosts: [SSHHostProfile]
  ) -> [SSHHostProfile] {
    guard let endpoint = try? SSHHostResolver.resolve(id, in: hosts).credentialEndpoint else {
      return []
    }
    return hosts.filter { other in
      other.id != id && !other.isDefaults
        && (try? SSHHostResolver.resolve(other.id, in: hosts).credentialEndpoint) == endpoint
    }
  }

  /// 引用了指定主机作为跳板的其它主机（删除前提示用）。
  public static func hostsUsingJump(_ id: UUID, in hosts: [SSHHostProfile]) -> [SSHHostProfile] {
    hosts.filter { $0.jumpHostID == id }
  }
}

/// 私有文件的原子写入：目录 0700、文件 0600，同目录临时文件再 rename。
///
/// 临时文件必须与目标同目录：跨文件系统的 rename 会退化成复制，失去原子性。
public enum PrivateFileWriter {
  public static func write(_ data: Data, to fileURL: URL, fileManager: FileManager = .default) throws {
    let directory = fileURL.deletingLastPathComponent()
    try fileManager.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    let temporary = directory.appendingPathComponent(
      ".\(fileURL.deletingPathExtension().lastPathComponent)-\(UUID().uuidString).tmp")
    do {
      try data.write(to: temporary, options: [.atomic])
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
      if fileManager.fileExists(atPath: fileURL.path) {
        _ = try fileManager.replaceItemAt(fileURL, withItemAt: temporary)
      } else {
        try fileManager.moveItem(at: temporary, to: fileURL)
      }
      try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    } catch {
      try? fileManager.removeItem(at: temporary)
      throw error
    }
  }
}
