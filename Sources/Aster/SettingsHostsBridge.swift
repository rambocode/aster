import AppKit
import AsterCore
import Combine
import Foundation

// 设置页「主机」分类的桥接协作者：为网页生成主机快照，并执行 `hosts.` 前缀的动作。
//
// `SettingsViewController` 只负责把消息转进来、把快照与回执送出去；它的 private 成员
// 不对这里开放，需要的能力（推送快照、toast、向网页发消息、取窗口）都以闭包注入。
// 主机真值只在 `SSHHostDirectory`，这里不持有可写副本。

/// 设置页用到的口令钥匙串能力：只判断与删除，读写口令本身由认证流程负责。
@MainActor
protocol SettingsHostPasswordStore {
  /// 是否已为该 endpoint 保存口令。
  func hasPassword(for endpoint: String) -> Bool
  /// 删除该 endpoint 的口令；不存在不算错误。
  func deletePassword(for endpoint: String) throws
}

extension SSHCredentialStore: SettingsHostPasswordStore {}

/// 设置页「主机」分类的快照与动作处理。
@MainActor
final class SettingsHostsBridge {
  /// 外部依赖。生产用 `.live()`；测试注入临时 hosts.json、假钥匙串与假机器列表。
  struct Dependencies {
    var directory: SSHHostDirectory
    var passwords: any SettingsHostPasswordStore
    /// 当前机器配置，用于统计「被几台机器引用」。
    var machines: @MainActor () -> [MachineProfile]
    /// 机器列表可能变化时发出（例如「添加为机器…」完成后）；nil 表示不监听。
    var machinesDidChange: AnyPublisher<Void, Never>?
    /// 读取 `~/.ssh/config` 的解析结果。
    var configListing: @MainActor () async throws -> SSHConfigListing
    /// 「在 ~/.ssh/config 中编辑」打开的文件。
    var sshConfigURL: URL
    /// 用默认文本编辑器打开文件。
    var openInEditor: @MainActor (URL) async throws -> Void
    /// 弹出「添加机器」流程。
    var addMachine: @MainActor (MachineSetupFlow.Prefill, NSWindow?) -> Void
    /// 用户名的内置缺省值（表单占位符用）。
    var localUser: String

    /// 生产依赖：共享主机目录、真实钥匙串、机器编队与 aster-ssh。
    @MainActor static func live() -> Dependencies {
      Dependencies(
        directory: .shared,
        passwords: SSHCredentialStore(),
        machines: { MachineFleetModel.shared.profiles },
        machinesDidChange: MachineFleetModel.shared.$rows.map { _ in () }.eraseToAnyPublisher(),
        configListing: { try await SSHBrokerSupervisor.shared.configListing() },
        sshConfigURL: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config"),
        openInEditor: SettingsHostsBridge.openInDefaultTextEditor,
        addMachine: { prefill, window in
          Task { @MainActor in
            _ = await MachineSetupFlow.presentAddMachine(prefill: prefill, in: window)
          }
        },
        localUser: NSUserName())
    }
  }

  let dependencies: Dependencies
  var directory: SSHHostDirectory { dependencies.directory }

  /// 立即推送一份新快照。动作成功后先推快照再发回执，网页拿到回执时列表已是新值。
  var pushSnapshot: () -> Void = {}
  /// 主机列表在外部变化（文件监听、其它窗口）时请求刷新；可以是异步合并的刷新。
  var scheduleRefresh: () -> Void = {}
  /// 显示一条 toast；第二个参数为 true 表示错误。
  var toast: (String, Bool) -> Void = { _, _ in }
  /// 向网页发送一条结构化消息（导入汇总等）。
  var postMessage: ([String: Any]) -> Void = { _ in }
  /// 设置窗口，用作弹出流程的宿主。
  var window: () -> NSWindow? = { nil }

  /// 最近一次快照所基于的主机列表、加载错误与机器引用；外部变化与它相同就不必再推。
  private var renderedState: RenderedState?
  private var cancellables: Set<AnyCancellable> = []
  /// 导入进行中。连点只跑一次，避免两次合并基于同一旧列表互相覆盖。
  var isImporting = false

  /// 快照的输入摘要，用来判断外部通知是否真的改变了页面内容。
  private struct RenderedState: Equatable {
    var hosts: [SSHHostProfile]
    var loadError: String?
    /// 机器对主机的引用（hostID 与标签）；连接状态变化不影响本页。
    var machineReferences: [MachineReference]
  }

  /// 一台机器对主机的引用。
  private struct MachineReference: Equatable {
    var hostID: UUID?
    var label: String
  }

  init(dependencies: Dependencies) {
    self.dependencies = dependencies
  }

  /// 当前的快照输入摘要。
  private func currentState(machines: [MachineProfile]) -> RenderedState {
    RenderedState(
      hosts: directory.hosts, loadError: directory.loadError,
      machineReferences: machines.map { MachineReference(hostID: $0.hostID, label: $0.label) })
  }

  /// 开始监听主机目录。重复调用无副作用。
  func start() {
    guard cancellables.isEmpty else { return }
    directory.startWatching()
    // @Published 在 willSet 时发出，此刻 `hosts` 还是旧值；切到下一轮主队列再读。
    var changes = directory.$hosts.map { _ in () }
      .merge(with: directory.$loadError.map { _ in () })
      .eraseToAnyPublisher()
    if let machines = dependencies.machinesDidChange { changes = changes.merge(with: machines).eraseToAnyPublisher() }
    changes
      .receive(on: DispatchQueue.main)
      .sink { [weak self] _ in
        guard let self else { return }
        // 本页动作已同步推过快照；只有真正的外部变化才再刷新一次，避免多推一份快照让
        // 网页下一次提交带着过期 revision 被拒绝。机器的连接状态变化也会走到这里，同样跳过。
        guard self.renderedState != self.currentState(machines: self.dependencies.machines()) else { return }
        self.scheduleRefresh()
      }
      .store(in: &cancellables)
  }

  // MARK: - 快照

  /// 网页快照的 `hosts` 字段。
  ///
  /// 形状：`defaults`（默认项）、`hosts`（已排序的主机行）、`groups`（已有分组，供 datalist）、
  /// `builtin`（内置缺省值，供占位符）、`importedGroup`、`sshConfigPath`、`loadError`。
  func snapshot() -> [String: Any] {
    let hosts = directory.hosts
    let machines = dependencies.machines()
    renderedState = currentState(machines: machines)
    let defaults = hosts.first(where: \.isDefaults) ?? .emptyDefaults()
    let saved = Self.sorted(hosts.filter { !$0.isDefaults })
    let names = Dictionary(hosts.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
    let endpoints = Self.credentialEndpoints(hosts)

    // 同一 endpoint 只查一次钥匙串：共用凭证的主机很常见，每次快照都会重建。
    var passwordByEndpoint: [String: Bool] = [:]
    for endpoint in Set(endpoints.values) {
      passwordByEndpoint[endpoint] = dependencies.passwords.hasPassword(for: endpoint)
    }
    var hostsByEndpoint: [String: [SSHHostProfile]] = [:]
    for profile in saved {
      if let endpoint = endpoints[profile.id] { hostsByEndpoint[endpoint, default: []].append(profile) }
    }

    let rows: [[String: Any]] = saved.map { profile in
      let endpoint = endpoints[profile.id]
      var row: [String: Any] = [
        "profile": Self.profileJSON(profile),
        "connect": profile.connectString,
        "hasPassword": endpoint.flatMap { passwordByEndpoint[$0] } ?? false,
        "machines": machines.filter { $0.hostID == profile.id }.map(\.label),
        "jumpDependents": SSHHostStore.hostsUsingJump(profile.id, in: hosts).map(\.name),
        // 与 `SSHHostStore.hostsSharingCredential` 同语义；按 endpoint 分组一次算完，
        // 避免每行都把全部主机再解析一遍。
        "credentialSharedWith": endpoint.map { endpoint in
          (hostsByEndpoint[endpoint] ?? []).filter { $0.id != profile.id }.map(\.name)
        } ?? [],
      ]
      if let jumpID = profile.jumpHostID, let jumpName = names[jumpID] { row["jumpName"] = jumpName }
      return row
    }

    let groups = Self.orderedGroups(saved)
    return [
      "defaults": Self.profileJSON(defaults),
      "hosts": rows,
      "groups": groups,
      "builtin": [
        "port": 22,
        "user": dependencies.localUser,
        "auth": SSHAuthMode.auto.rawValue,
        "keepaliveInterval": 15,
        "keepaliveCountMax": 3,
        "connectTimeout": 10,
        "verifyHostKeys": true,
        "agentForward": false,
      ] as [String: Any],
      "importedGroup": SSHHostProfile.importedGroup,
      "sshConfigPath": (dependencies.sshConfigURL.path as NSString).abbreviatingWithTildeInPath,
      "loadError": directory.loadError ?? "",
    ]
  }

  /// 列表顺序：`~/.ssh/config` 导入组在前，其它分组按名称，最后是未分组；组内按名称。
  static func sorted(_ hosts: [SSHHostProfile]) -> [SSHHostProfile] {
    hosts.sorted { lhs, rhs in
      let left = groupRank(lhs.group)
      let right = groupRank(rhs.group)
      if left != right { return left < right }
      if let a = lhs.group, let b = rhs.group, a != b {
        return a.localizedStandardCompare(b) == .orderedAscending
      }
      let order = lhs.name.localizedStandardCompare(rhs.name)
      return order == .orderedSame ? lhs.id.uuidString < rhs.id.uuidString : order == .orderedAscending
    }
  }

  /// 分组排名：导入组 0、命名分组 1、未分组 2。
  private static func groupRank(_ group: String?) -> Int {
    guard let group else { return 2 }
    return group == SSHHostProfile.importedGroup ? 0 : 1
  }

  /// 已排序主机里出现过的分组名（去重、保持显示顺序）。
  static func orderedGroups(_ sortedHosts: [SSHHostProfile]) -> [String] {
    var seen: Set<String> = []
    return sortedHosts.compactMap(\.group).filter { seen.insert($0).inserted }
  }

  /// 每台可解析主机的凭证 endpoint（`user@host:port`）。解析失败的主机没有 endpoint，
  /// 也就不可能有已保存口令，这不是需要报告的错误。
  static func credentialEndpoints(_ hosts: [SSHHostProfile]) -> [UUID: String] {
    SSHHostResolver.resolveAll(hosts).specs.mapValues(\.credentialEndpoint)
  }

  /// 把主机编码成网页用的对象。键名与 `SSHHostProfile` 的 Codable 键一致，网页原样回传后
  /// 可以直接用 `JSONDecoder` 解码；nil 字段省略。
  static func profileJSON(_ profile: SSHHostProfile) -> [String: Any] {
    var object: [String: Any] = [
      "id": profile.id.uuidString,
      "name": profile.name,
      "host": profile.host,
      "user": profile.user,
      "identityFiles": profile.identityFiles,
      "forwards": profile.forwards.map { rule in
        [
          "kind": rule.kind.rawValue,
          "bind": ["host": rule.bind.host, "port": rule.bind.port],
          "target": ["host": rule.target.host, "port": rule.target.port],
          "description": rule.description,
        ] as [String: Any]
      },
    ]
    object["group"] = profile.group
    object["port"] = profile.port
    object["jumpHostID"] = profile.jumpHostID?.uuidString
    object["proxyCommand"] = profile.proxyCommand
    object["socksProxy"] = profile.socksProxy.map { ["host": $0.host, "port": $0.port] as [String: Any] }
    object["httpProxy"] = profile.httpProxy.map { ["host": $0.host, "port": $0.port] as [String: Any] }
    object["auth"] = profile.auth?.rawValue
    object["agentForward"] = profile.agentForward
    object["keepaliveInterval"] = profile.keepaliveInterval
    object["keepaliveCountMax"] = profile.keepaliveCountMax
    object["connectTimeout"] = profile.connectTimeout
    object["verifyHostKeys"] = profile.verifyHostKeys
    return object
  }

  /// 用系统登记的纯文本编辑器打开文件。`~/.ssh/config` 没有扩展名，直接 `open(url)`
  /// 会找不到默认应用，所以先按纯文本类型查编辑器。
  static func openInDefaultTextEditor(_ url: URL) async throws {
    let workspace = NSWorkspace.shared
    guard let editor = workspace.urlForApplication(toOpen: .plainText) else {
      guard workspace.open(url) else { throw SettingsHostsError.noTextEditor }
      return
    }
    _ = try await workspace.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
  }
}
