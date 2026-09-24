import AsterCore
import Combine
import Foundation

// 已保存 SSH 主机的 App 侧唯一权威入口：读写 hosts.json、监听外部修改、发布变化。
// 设置页、Open Quickly、新建工作区表单与 broker 同步都从这里读，不各自持有副本。

/// 已保存 SSH 主机目录。
@MainActor
final class SSHHostDirectory: ObservableObject {
  static let shared = SSHHostDirectory()

  /// 当前有效主机列表，默认项在第一位。
  @Published private(set) var hosts: [SSHHostProfile]
  /// 最近一次加载失败的原因；nil 表示正常。失败时 `hosts` 保持最后有效值。
  @Published private(set) var loadError: String?

  let store: SSHHostStore
  private var watcher: FileSystemDirectoryWatcher?

  init(store: SSHHostStore = SSHHostStore()) {
    self.store = store
    hosts = store.effectiveHosts
    reload()
  }

  /// 不含默认项的真实主机。
  var savedHosts: [SSHHostProfile] { hosts.filter { !$0.isDefaults } }

  func host(_ id: UUID) -> SSHHostProfile? { hosts.first { $0.id == id } }

  /// 从磁盘重新加载；失败保留最后有效列表并记录原因。
  func reload() {
    do {
      hosts = try store.load()
      loadError = nil
    } catch {
      loadError = String(describing: error)
    }
  }

  /// 开始监听配置目录，外部编辑 hosts.json 后自动重载。重复调用无副作用。
  func startWatching() {
    guard watcher == nil else { return }
    let directory = store.fileURL.deletingLastPathComponent()
    try? FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    let watcher = FileSystemDirectoryWatcher(directory: directory)
    do {
      try watcher.start { [weak self] in self?.reload() }
      self.watcher = watcher
    } catch {
      loadError = String(describing: error)
    }
  }

  /// 新增或更新一条主机（按 id 匹配）。
  func upsert(_ profile: SSHHostProfile) throws {
    var next = hosts
    if let index = next.firstIndex(where: { $0.id == profile.id }) {
      next[index] = profile
    } else {
      next.append(profile)
    }
    try commit(next)
  }

  /// 删除一条主机；同时清掉其它主机对它的跳板引用。默认项不能删除。
  func remove(_ id: UUID) throws {
    guard id != SSHHostProfile.defaultsProfileID else { return }
    let next = hosts.filter { $0.id != id }.map { profile -> SSHHostProfile in
      var copy = profile
      if copy.jumpHostID == id { copy.jumpHostID = nil }
      return copy
    }
    try commit(next)
  }

  /// 只改分组。
  func setGroup(_ id: UUID, group: String?) throws {
    guard var profile = host(id) else { return }
    profile.group = group
    try upsert(profile)
  }

  /// 全部可解析主机的 broker 规格。
  func resolvedSpecs() -> [UUID: SSHResolvedSpec] {
    SSHHostResolver.resolveAll(hosts).specs
  }

  private func commit(_ next: [SSHHostProfile]) throws {
    try store.save(next)
    hosts = store.effectiveHosts
    loadError = nil
  }
}
