import Foundation

// 命名工作区注册表（借鉴 tty7 `views.json` 的客户端工作区列表）。
//
// 本地命名工作区 = 一个窗口，快照仍在该窗口的 UserDefaults suite 里（主窗口用 standard）。
// 远端命名工作区 = 服务端的 `RemoteWorkspace`，服务端是唯一权威；这里只记最近使用时间，
// 用于切换器排序，不复制远端结构。注册表本身存在 UserDefaults.standard 的
// `aster.workspace.registry.v1`，由 App 侧 `NamedWorkspaceDirectory` 读写。

/// 本地工作区的快照存放位置。
public enum NamedWorkspaceStorage: Codable, Equatable, Hashable, Sendable {
  /// 主窗口：`UserDefaults.standard`。
  case standard
  /// 附加窗口：独立 suite，名称必须是 `suitePrefix + UUID`。
  case suite(String)
}

/// 一个本地命名工作区。
public struct NamedWorkspace: Codable, Equatable, Identifiable, Sendable {
  public let id: UUID
  public var name: String
  public var storage: NamedWorkspaceStorage
  /// 固定保留：关闭窗口时保留快照与条目。⌘⇧N 新建或被重命名过的工作区为 true；
  /// 普通「新窗口」为 false，关闭即删除，保持改造前的行为。
  public var isPinned: Bool
  /// 当前是否有窗口打开着它。
  public var isOpen: Bool
  public var createdAt: Date
  public var lastActiveAt: Date

  public init(
    id: UUID = UUID(), name: String, storage: NamedWorkspaceStorage, isPinned: Bool,
    isOpen: Bool, createdAt: Date, lastActiveAt: Date
  ) {
    self.id = id
    self.name = name
    self.storage = storage
    self.isPinned = isPinned
    self.isOpen = isOpen
    self.createdAt = createdAt
    self.lastActiveAt = lastActiveAt
  }
}

/// 注册表操作错误。
public enum NamedWorkspaceRegistryError: Error, Equatable, Sendable {
  case emptyName
  case nameTooLong
  case unknownWorkspace(UUID)
  case tooManyOpen
  case cannotRemoveStandard
}

/// 命名工作区注册表。纯值类型，所有操作都是可测的纯函数。
public struct NamedWorkspaceRegistry: Codable, Equatable, Sendable {
  /// UserDefaults 键。
  public static let defaultsKey = "aster.workspace.registry.v1"
  /// 附加窗口 suite 名前缀。`AdditionalWorkspaceWindowRegistry` 引用同一个常量。
  public static let suitePrefix = "io.local.aster-terminal.window."
  /// 同时打开的工作区上限：主窗口 + 16 个附加窗口。改造前主窗口不计入附加窗口的 16 个
  /// 恢复上限，这里含主窗口，所以是 17，保证旧数据迁移后原来会恢复的窗口一个不少。
  public static let maximumOpen = 17
  /// 关闭后保留的工作区上限；超出时按最近使用淘汰最旧的。
  public static let maximumRetained = 48
  /// 名称的最大字符数。
  public static let maximumNameLength = 80

  public private(set) var workspaces: [NamedWorkspace]
  /// 远端工作区最近使用时间，键是 `remoteActivityKey(machineID:workspaceID:)`。
  public private(set) var remoteActivity: [String: Date]

  public init(workspaces: [NamedWorkspace] = [], remoteActivity: [String: Date] = [:]) {
    self.workspaces = workspaces
    self.remoteActivity = remoteActivity
  }

  /// 远端活动记录的键。
  public static func remoteActivityKey(machineID: UUID, workspaceID: String) -> String {
    "\(machineID.uuidString)/\(workspaceID)"
  }

  /// 校验 suite 名：只接受 Aster 自己生成的 `前缀 + UUID`，防止读取任意 domain。
  public static func isValidSuiteName(_ name: String) -> Bool {
    name.hasPrefix(suitePrefix) && UUID(uuidString: String(name.dropFirst(suitePrefix.count))) != nil
  }

  /// 生成一个新的 suite 名。
  public static func makeSuiteName() -> String { suitePrefix + UUID().uuidString }

  // MARK: - 查询

  public func workspace(_ id: UUID) -> NamedWorkspace? { workspaces.first { $0.id == id } }

  public func workspace(storage: NamedWorkspaceStorage) -> NamedWorkspace? {
    workspaces.first { $0.storage == storage }
  }

  /// 最近使用优先的列表，供切换器使用。
  public var recentFirst: [NamedWorkspace] {
    workspaces.sorted { $0.lastActiveAt > $1.lastActiveAt }
  }

  /// 当前打开着的附加窗口 suite（按创建先后），用于写回旧键保证降级可用。
  public var openSuiteNames: [String] {
    workspaces.filter(\.isOpen).sorted { $0.createdAt < $1.createdAt }.compactMap {
      if case .suite(let name) = $0.storage { return name }
      return nil
    }
  }

  // MARK: - 修改

  /// 新建一个工作区条目并标记为打开。
  @discardableResult
  public mutating func create(
    name: String, storage: NamedWorkspaceStorage, isPinned: Bool, now: Date
  ) throws -> NamedWorkspace {
    let name = try Self.validatedName(name)
    guard workspaces.filter(\.isOpen).count < Self.maximumOpen else {
      throw NamedWorkspaceRegistryError.tooManyOpen
    }
    let workspace = NamedWorkspace(
      name: name, storage: storage, isPinned: isPinned, isOpen: true, createdAt: now,
      lastActiveAt: now)
    workspaces.append(workspace)
    return workspace
  }

  /// 重命名。重命名过的工作区视为用户在意它，自动固定保留。
  public mutating func rename(_ id: UUID, to name: String) throws {
    let name = try Self.validatedName(name)
    guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
      throw NamedWorkspaceRegistryError.unknownWorkspace(id)
    }
    workspaces[index].name = name
    workspaces[index].isPinned = true
  }

  /// 删除条目。主窗口的条目不能删除。返回被删条目，调用方据此清理其 suite。
  @discardableResult
  public mutating func remove(_ id: UUID) throws -> NamedWorkspace {
    guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
      throw NamedWorkspaceRegistryError.unknownWorkspace(id)
    }
    guard workspaces[index].storage != .standard else {
      throw NamedWorkspaceRegistryError.cannotRemoveStandard
    }
    return workspaces.remove(at: index)
  }

  /// 记录一次使用（窗口获得焦点、切换到该工作区）。
  public mutating func markActive(_ id: UUID, now: Date) {
    guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return }
    workspaces[index].lastActiveAt = now
    workspaces[index].isOpen = true
  }

  /// 标记重新打开。超出打开上限时抛错，调用方不应再创建窗口。
  public mutating func markOpened(_ id: UUID, now: Date) throws {
    guard let index = workspaces.firstIndex(where: { $0.id == id }) else {
      throw NamedWorkspaceRegistryError.unknownWorkspace(id)
    }
    if !workspaces[index].isOpen, workspaces.filter(\.isOpen).count >= Self.maximumOpen {
      throw NamedWorkspaceRegistryError.tooManyOpen
    }
    workspaces[index].isOpen = true
    workspaces[index].lastActiveAt = now
  }

  /// 窗口关闭时调用。固定保留的条目标记为关闭并返回 false（保留 suite）；
  /// 不保留的条目直接删除并返回 true（调用方删除 suite）。
  @discardableResult
  public mutating func markClosed(_ id: UUID) -> Bool {
    guard let index = workspaces.firstIndex(where: { $0.id == id }) else { return false }
    if workspaces[index].isPinned || workspaces[index].storage == .standard {
      workspaces[index].isOpen = false
      return false
    }
    workspaces.remove(at: index)
    return true
  }

  /// 记录远端工作区的使用时间。
  public mutating func markRemoteActive(machineID: UUID, workspaceID: String, now: Date) {
    remoteActivity[Self.remoteActivityKey(machineID: machineID, workspaceID: workspaceID)] = now
  }

  /// 清理：删除非法 suite、去重、淘汰超额的已关闭条目、删除已不存在机器的远端记录。
  /// 返回被淘汰条目的 suite 名，调用方负责删除对应 UserDefaults 域。
  public mutating func prune(knownMachineIDs: Set<UUID>? = nil) -> [String] {
    var seenStorage: Set<NamedWorkspaceStorage> = []
    var dropped: [String] = []
    workspaces = workspaces.filter { workspace in
      if case .suite(let name) = workspace.storage, !Self.isValidSuiteName(name) { return false }
      return seenStorage.insert(workspace.storage).inserted
    }
    let closed = workspaces.filter { !$0.isOpen && $0.storage != .standard }
      .sorted { $0.lastActiveAt > $1.lastActiveAt }
    if closed.count > Self.maximumRetained {
      let evicted = Set(closed.dropFirst(Self.maximumRetained).map(\.id))
      for workspace in workspaces where evicted.contains(workspace.id) {
        if case .suite(let name) = workspace.storage { dropped.append(name) }
      }
      workspaces.removeAll { evicted.contains($0.id) }
    }
    if let knownMachineIDs {
      remoteActivity = remoteActivity.filter { key, _ in
        guard let machine = key.split(separator: "/").first.flatMap({ UUID(uuidString: String($0)) })
        else { return false }
        return knownMachineIDs.contains(machine)
      }
    }
    return dropped
  }

  // MARK: - 迁移

  /// 从旧数据生成注册表：主窗口成为固定保留的「主工作区」，旧附加窗口 suite 成为
  /// 不保留、已打开的代号工作区。只在注册表不存在时调用。
  public static func migrated(
    mainName: String, legacySuites: [String], now: Date,
    codename: () -> String = { WorkspaceCodename.generate() }
  ) -> NamedWorkspaceRegistry {
    var registry = NamedWorkspaceRegistry()
    registry.workspaces.append(
      NamedWorkspace(
        name: mainName, storage: .standard, isPinned: true, isOpen: true, createdAt: now,
        lastActiveAt: now))
    var seen: Set<String> = []
    for suite in legacySuites where isValidSuiteName(suite) && seen.insert(suite).inserted {
      guard registry.workspaces.count < maximumOpen else { break }
      registry.workspaces.append(
        NamedWorkspace(
          name: codename(), storage: .suite(suite), isPinned: false, isOpen: true,
          createdAt: now, lastActiveAt: now))
    }
    return registry
  }

  /// 注册表已存在时，与旧键 `additional-window-suites` 对账。
  ///
  /// 正常运行时每次保存都把 `openSuiteNames` 写回旧键，两者一致，本方法不产生变化；
  /// 只有降级到旧版本又升级回来时才会出现分歧：旧版本关窗会删 suite 并从旧键移除，
  /// 旧版本新开的窗口只写进旧键。因此以旧键为准修正「是否打开」：
  /// - 注册表里打开、旧键里没有的 suite：不保留的条目删除，固定保留的条目标记为关闭；
  /// - 旧键里有、注册表里没有的合法 suite：补成不保留、已打开的代号工作区。
  /// 同时保证主窗口条目存在（数据被外部改坏时补回）。`legacyOpenSuites` 为 nil 表示旧键
  /// 不存在，只做主窗口兜底。
  public mutating func reconcile(
    legacyOpenSuites: [String]?, mainName: String, now: Date,
    codename: () -> String = { WorkspaceCodename.generate() }
  ) {
    if !workspaces.contains(where: { $0.storage == .standard }) {
      workspaces.insert(
        NamedWorkspace(
          name: mainName, storage: .standard, isPinned: true, isOpen: true, createdAt: now,
          lastActiveAt: now), at: 0)
    }
    guard let legacyOpenSuites else { return }
    let legacy = Set(legacyOpenSuites.filter(Self.isValidSuiteName))
    workspaces = workspaces.compactMap { workspace in
      guard case .suite(let name) = workspace.storage, workspace.isOpen, !legacy.contains(name)
      else { return workspace }
      guard workspace.isPinned else { return nil }
      var closed = workspace
      closed.isOpen = false
      return closed
    }
    var seen: Set<String> = []
    for suite in legacyOpenSuites where legacy.contains(suite) && seen.insert(suite).inserted {
      guard workspace(storage: .suite(suite)) == nil else {
        // 旧键里仍打开的固定保留条目：旧版本恢复过它，这里同样视为打开。
        if let index = workspaces.firstIndex(where: { $0.storage == .suite(suite) }) {
          workspaces[index].isOpen = true
        }
        continue
      }
      guard workspaces.filter(\.isOpen).count < Self.maximumOpen else { break }
      workspaces.append(
        NamedWorkspace(
          name: codename(), storage: .suite(suite), isPinned: false, isOpen: true,
          createdAt: now, lastActiveAt: now))
    }
  }

  /// 去空白后校验名称；App 侧的输入框用它在提交前给出提示。
  public static func validatedName(_ name: String) throws -> String {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw NamedWorkspaceRegistryError.emptyName }
    guard trimmed.count <= maximumNameLength else { throw NamedWorkspaceRegistryError.nameTooLong }
    return trimmed
  }
}

/// 工作区代号生成器（借鉴 tty7 的 "quiet-otter" 风格），用于预填名称。
public enum WorkspaceCodename {
  static let adjectives = [
    "amber", "brisk", "calm", "clever", "cosmic", "crisp", "dusky", "eager", "gentle", "golden",
    "hazy", "jolly", "keen", "lucky", "mellow", "misty", "nimble", "quiet", "rapid", "rustic",
    "silent", "sly", "steady", "sunny", "swift", "tidy", "vivid", "witty",
  ]
  static let animals = [
    "badger", "beaver", "crane", "falcon", "ferret", "finch", "gecko", "heron", "ibis", "koala",
    "lynx", "marten", "otter", "owl", "panda", "puffin", "raven", "robin", "salmon", "seal",
    "sparrow", "stoat", "swan", "tapir", "walrus", "wren", "yak", "zebra",
  ]

  /// 生成一个代号，可注入随机源便于测试。
  public static func generate<G: RandomNumberGenerator>(using generator: inout G) -> String {
    "\(adjectives.randomElement(using: &generator)!)-\(animals.randomElement(using: &generator)!)"
  }

  /// 用系统随机源生成代号。
  public static func generate() -> String {
    var generator = SystemRandomNumberGenerator()
    return generate(using: &generator)
  }
}
