import Foundation

/// P4.5：机器配置的原子写入、外部变更应用、有效快照与损坏恢复。
///
/// 依据 `docs/developer/remote-work.md` §3.3 与 §4.1 第 7/8 条：
/// - 配置目录只保存不透明 ID、标签、原始 SSH target、命名会话与 enabled；
///   **绝不保存密码、私钥、临时 socket 路径**。
/// - 整份校验通过才一次性应用成新的有效快照；任何一条无效就保留最后有效配置与
///   现存连接，返回可恢复错误。
/// - **文件被删除**与**内容损坏**是两种不同结果；解析失败绝不能当成空配置。
/// - 重命名（只改 label）不触发重连。
///
/// 实际的 FSEvents 监听在 App 侧（`Sources/Aster/FileSystemDirectoryWatcher.swift`）；
/// Core 只暴露 `applyExternalChange(data:)` 这个纯可测入口。

/// 配置存储错误。全部可恢复：调用方保留最后有效快照与现存连接即可。
public enum MachineProfileStoreError: Error, Equatable, Sendable {
  /// 配置文件不存在。与「损坏」严格区分：这是合法的首次启动状态。
  case fileMissing(path: String)
  /// 文件存在但无法解析成配置。**不能**当作空配置处理。
  case corrupted(detail: String)
  /// 解析成功但内容不合法；`reasons` 逐条说明，整份拒绝。
  case invalidProfiles(reasons: [String])
  /// 读写文件系统失败。
  case ioFailure(detail: String)
}

/// 一次加载的结果。首次启动（文件不存在）与损坏必须能分辨。
public enum MachineProfileLoadResult: Equatable, Sendable {
  /// 文件存在且整份校验通过。
  case loaded([MachineProfile])
  /// 文件不存在：按空配置启动是**合法**的，但调用方要知道这不是损坏。
  case absent
}

/// 需要重连的配置变更。重命名不在其中。
public enum MachineProfileChange: Equatable, Hashable, Sendable {
  /// 新增配置：需要建立连接。
  case added(UUID)
  /// 移除配置：需要断开该配置（不停止远端服务）。
  case removed(UUID)
  /// 连接相关字段变化（SSH target 或绑定的命名会话）：必须重连。
  case connectionChanged(UUID)
  /// enabled 变化：启用要连接，禁用要断开。
  case enabledChanged(UUID)

  public var profileID: UUID {
    switch self {
    case .added(let id), .removed(let id), .connectionChanged(let id), .enabledChanged(let id): id
    }
  }
}

/// 机器配置存储。
///
/// 线程安全：内部用锁保护「最后有效快照」，因为 FSEvents 回调与 UI 写入可能并发到达。
public final class MachineProfileStore: @unchecked Sendable {
  /// 配置文件里允许出现的键。写出与读入都以它为准，多一个键就说明有东西不该被保存。
  public static let allowedKeys: Set<String> = ["id", "label", "sshTarget", "sessionName", "enabled"]

  /// 默认配置路径：`~/Library/Application Support/Aster/machines.json`。
  public static func defaultFileURL(
    fileManager: FileManager = .default
  ) -> URL {
    let base =
      fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(
        "Library/Application Support")
    return base.appendingPathComponent("Aster/machines.json")
  }

  public let fileURL: URL
  private let fileManager: FileManager
  private let lock = NSLock()
  private var lastValid: [MachineProfile] = []

  public init(fileURL: URL? = nil, fileManager: FileManager = .default) {
    self.fileManager = fileManager
    self.fileURL = fileURL ?? Self.defaultFileURL(fileManager: fileManager)
  }

  /// 最后一份有效快照。损坏或校验失败之后它保持不变，现存连接因此不受影响。
  public var effectiveProfiles: [MachineProfile] {
    lock.lock()
    defer { lock.unlock() }
    return lastValid
  }

  // MARK: - 读

  /// 从磁盘加载并整份校验。
  ///
  /// 只有全部校验通过才会替换有效快照；任何一条无效就抛 `invalidProfiles`，
  /// 快照与现存连接保持原样。
  @discardableResult
  public func load() throws -> MachineProfileLoadResult {
    guard fileManager.fileExists(atPath: fileURL.path) else { return .absent }
    let data: Data
    do { data = try Data(contentsOf: fileURL) } catch {
      throw MachineProfileStoreError.ioFailure(detail: String(describing: error))
    }
    let profiles = try Self.decode(data)
    lock.lock()
    lastValid = profiles
    lock.unlock()
    return .loaded(profiles)
  }

  /// 外部变更入口（FSEvents 回调把文件内容读出来后交给它）。
  ///
  /// 这是 Core 侧唯一的可测入口：不触碰 FSEvents，也不自己读文件，因此
  /// 「损坏内容不清空有效连接」可以被直接断言。
  @discardableResult
  public func applyExternalChange(data: Data?) throws -> MachineProfileLoadResult {
    // nil 表示文件已被删除。删除与损坏是两种结果：删除后按空配置继续，
    // 但有效快照必须显式清空而不是保留旧值，否则界面会显示已经不存在的机器。
    guard let data else {
      lock.lock()
      lastValid = []
      lock.unlock()
      return .absent
    }
    let profiles = try Self.decode(data)
    lock.lock()
    lastValid = profiles
    lock.unlock()
    return .loaded(profiles)
  }

  /// 纯解码 + 整份校验。解析失败与内容非法分成两种错误。
  public static func decode(_ data: Data) throws -> [MachineProfile] {
    guard !data.isEmpty else {
      throw MachineProfileStoreError.corrupted(detail: "empty file")
    }
    let raw: [[String: Any]]
    do {
      guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
        throw MachineProfileStoreError.corrupted(detail: "root is not an array of objects")
      }
      raw = array
    } catch let error as MachineProfileStoreError {
      throw error
    } catch {
      throw MachineProfileStoreError.corrupted(detail: String(describing: error))
    }

    var profiles: [MachineProfile] = []
    var reasons: [String] = []
    var seenIDs: Set<UUID> = []
    for (index, object) in raw.enumerated() {
      // 未知键说明这份文件不是本程序写出来的，或被人塞了不该保存的字段
      // （例如凭据）。整份拒绝，不做选择性忽略。
      let unknown = Set(object.keys).subtracting(allowedKeys)
      if !unknown.isEmpty {
        reasons.append("[\(index)] unexpected keys: \(unknown.sorted().joined(separator: ","))")
        continue
      }
      guard let idText = object["id"] as? String, let id = UUID(uuidString: idText) else {
        reasons.append("[\(index)] invalid id")
        continue
      }
      guard let label = object["label"] as? String, !label.isEmpty else {
        reasons.append("[\(index)] invalid label")
        continue
      }
      guard let sessionName = object["sessionName"] as? String, !sessionName.isEmpty else {
        reasons.append("[\(index)] invalid sessionName")
        continue
      }
      guard let enabled = object["enabled"] as? Bool else {
        reasons.append("[\(index)] invalid enabled")
        continue
      }
      var sshTarget: String?
      if let value = object["sshTarget"] {
        guard let text = value as? String, !text.isEmpty else {
          reasons.append("[\(index)] invalid sshTarget")
          continue
        }
        sshTarget = text
      }
      guard seenIDs.insert(id).inserted else {
        reasons.append("[\(index)] duplicate id")
        continue
      }
      profiles.append(
        MachineProfile(
          id: id, label: label, sshTarget: sshTarget, sessionName: sessionName, enabled: enabled))
    }
    guard reasons.isEmpty else {
      throw MachineProfileStoreError.invalidProfiles(reasons: reasons)
    }
    return profiles
  }

  // MARK: - 写

  /// 原子写入：目录 0700、文件 0600，临时文件写好后在**同目录**内 rename。
  ///
  /// 同目录 rename 是原子性的前提（跨文件系统的 rename 会退化成复制），因此临时文件
  /// 必须与目标文件同目录，不能放 `/tmp`。
  public func save(_ profiles: [MachineProfile]) throws {
    let directory = fileURL.deletingLastPathComponent()
    do {
      try fileManager.createDirectory(
        at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
      // 目录可能早就存在且权限不对，createDirectory 不会修正，所以显式再设一次。
      try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    } catch {
      throw MachineProfileStoreError.ioFailure(detail: String(describing: error))
    }

    let data = try Self.encode(profiles)
    let temporary = directory.appendingPathComponent(".machines-\(UUID().uuidString).json")
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
      throw MachineProfileStoreError.ioFailure(detail: String(describing: error))
    }

    lock.lock()
    lastValid = profiles
    lock.unlock()
  }

  /// 序列化。只写 `allowedKeys` 里的字段：凭据与临时 socket 路径在类型层面就不存在，
  /// 这里再用显式白名单挡一层，防止未来给 `MachineProfile` 加字段时意外落盘。
  public static func encode(_ profiles: [MachineProfile]) throws -> Data {
    let objects: [[String: Any]] = profiles.map { profile in
      var object: [String: Any] = [
        "id": profile.id.uuidString,
        "label": profile.label,
        "sessionName": profile.sessionName,
        "enabled": profile.enabled,
      ]
      if let target = profile.sshTarget { object["sshTarget"] = target }
      return object
    }
    do {
      return try JSONSerialization.data(
        withJSONObject: objects, options: [.prettyPrinted, .sortedKeys])
    } catch {
      throw MachineProfileStoreError.ioFailure(detail: String(describing: error))
    }
  }

  // MARK: - 差异

  /// 计算需要重连的变更集合。
  ///
  /// **只改 label 的重命名不在结果里**（§4.1 第 7 条：重命名只改标签）。连接相关字段
  /// 只有 `sshTarget` 与 `sessionName`：前者决定连到哪台机器，后者决定绑定哪个命名会话。
  public static func diff(old: [MachineProfile], new: [MachineProfile]) -> Set<MachineProfileChange>
  {
    let oldByID = Dictionary(old.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let newByID = Dictionary(new.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    var changes: Set<MachineProfileChange> = []

    for (id, profile) in newByID {
      guard let previous = oldByID[id] else {
        changes.insert(.added(id))
        continue
      }
      if previous.sshTarget != profile.sshTarget || previous.sessionName != profile.sessionName {
        changes.insert(.connectionChanged(id))
      }
      if previous.enabled != profile.enabled {
        changes.insert(.enabledChanged(id))
      }
    }
    for id in oldByID.keys where newByID[id] == nil {
      changes.insert(.removed(id))
    }
    return changes
  }

  /// 需要重连的配置 ID 集合。移除不需要重连，只需要断开，所以不计入。
  public static func reconnectRequiredProfileIDs(
    old: [MachineProfile],
    new: [MachineProfile]
  ) -> Set<UUID> {
    Set(
      diff(old: old, new: new).compactMap { change -> UUID? in
        switch change {
        case .added(let id), .connectionChanged(let id), .enabledChanged(let id): id
        case .removed: nil
        }
      })
  }
}
