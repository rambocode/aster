import AppKit
import AsterCore
import Foundation

// Open Quickly「SSH」过滤器的数据：机器、已保存主机、ssh alias 与快连行。
// 纯计算（去重、排序、快连行位置）在 `OpenQuicklyHostCatalog`；`OpenQuicklyHostTargets`
// 负责取数据（alias 走 Rust 解析器并缓存）和接动作。浮层只把这里的条目转成自己的行。

/// 一行 SSH 类目标。字段与浮层内部的 Target 一一对应，由浮层负责转换。
struct OpenQuicklyHostEntry {
  let item: OpenQuicklyItem
  let symbol: String
  let badge: String
  let actionTitle: String
  let action: () -> Void
  var menuActions: [(title: String, handler: () -> Void)] = []
}

/// SSH 小节的纯目录计算。
enum OpenQuicklyHostCatalog {
  /// 一台远端机器的输入。
  struct Machine: Equatable {
    var id: UUID
    var label: String
    var target: String?
    var hostID: UUID?
  }

  /// `~/.ssh/config` 里的一个 alias。
  struct Alias: Equatable {
    var alias: String
    var hostName: String?
    var user: String?
    var port: Int?

    /// 显示用的真实地址：`user@hostName:port`，缺字段时省略。
    var destination: String {
      QuickConnectTarget(user: user, host: hostName ?? alias, port: port).displayText
    }
  }

  /// 一行的身份与显示内容。
  struct Row: Equatable {
    enum Kind: Equatable {
      case machine(UUID)
      case host(UUID)
      case alias(String)
    }
    var kind: Kind
    var title: String
    var detail: String
    var score: Double

    /// 浮层条目 ID，同一身份每次构建都相同。带 `ssh-` 前缀，避免与工作区切换器的机器条目撞 ID
    /// （浮层用 `uniqueKeysWithValues` 建索引，重复 ID 会直接崩溃）；alias 沿用旧的 `ssh:` 前缀。
    var id: String {
      switch kind {
      case .machine(let id): "ssh-machine:\(id.uuidString)"
      case .host(let id): "ssh-host:\(id.uuidString)"
      case .alias(let alias): "ssh:\(alias)"
      }
    }

    var itemKind: OpenQuicklyKind {
      switch kind {
      case .machine: .machine
      case .host: .host
      case .alias: .ssh
      }
    }
  }

  /// 生成机器、主机与 alias 三组行，每组按 frecency 降序（同分按名称）。
  ///
  /// 去重规则：主机被某台机器引用（`hostID`，或旧机器的 target 文本等于主机 target）时只
  /// 显示机器；alias 的名称或真实地址已对应某台主机或机器时不再单独列出——同一目标出现
  /// 两三次只会让用户犹豫该点哪一个。
  static func rows(
    machines: [Machine],
    hosts: [SSHHostProfile],
    aliases: [Alias],
    ledger: HostUsageLedger,
    now: Date = Date()
  ) -> [Row] {
    let savedHosts = hosts.filter { !$0.isDefaults }
    let hostTargets = Dictionary(
      savedHosts.compactMap { host in openSSHTarget(host.id, in: hosts).map { (host.id, $0) } },
      uniquingKeysWith: { first, _ in first })

    let machineRows = machines.map { machine in
      Row(
        kind: .machine(machine.id), title: machine.label, detail: machine.target ?? "",
        score: ledger.score(for: .id(machine.id), now: now))
    }
    let referencedHostIDs = Set(machines.compactMap(\.hostID))
    let machineTargets = Set(machines.compactMap(\.target))
    let freeHosts = savedHosts.filter { host in
      !referencedHostIDs.contains(host.id)
        && !(hostTargets[host.id].map(machineTargets.contains) ?? false)
    }
    let hostRows = freeHosts.map { host in
      Row(
        kind: .host(host.id), title: host.name.isEmpty ? host.connectString : host.name,
        detail: [host.connectString, host.group].compactMap { $0 }.filter { !$0.isEmpty }
          .joined(separator: " · "),
        score: ledger.score(for: .id(host.id), now: now))
    }

    // 已知名称与地址：主机的名称、连接串与规范 target；机器的标签与 target。
    var known = Set<String>()
    for host in savedHosts {
      known.formUnion([host.name, host.connectString, hostTargets[host.id] ?? ""])
    }
    for machine in machines { known.formUnion([machine.label, machine.target ?? ""]) }
    known.remove("")
    var seenAliases = Set<String>()
    let aliasRows = aliases.compactMap { alias -> Row? in
      guard seenAliases.insert(alias.alias).inserted,
        !known.contains(alias.alias), !known.contains(alias.destination)
      else { return nil }
      return Row(
        kind: .alias(alias.alias), title: alias.alias, detail: alias.destination,
        score: ledger.score(for: .target(alias.alias), now: now))
    }
    return sortedByScore(machineRows) + sortedByScore(hostRows) + sortedByScore(aliasRows)
  }

  /// 主机的规范 target；无法解析的主机（缺主机名、跳板成环）没有 target，只按名称去重。
  private static func openSSHTarget(_ id: UUID, in hosts: [SSHHostProfile]) -> String? {
    do {
      return try MachineFleetModel.openSSHTarget(forHost: id, in: hosts)
    } catch {
      return nil
    }
  }

  /// 分数降序，同分按标题。空查询时浮层按 score 排序，这里先排好也便于测试断言。
  private static func sortedByScore(_ rows: [Row]) -> [Row] {
    rows.sorted { lhs, rhs in
      lhs.score != rhs.score
        ? lhs.score > rhs.score
        : lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
    }
  }

  /// 快连行的三种动作。
  enum QuickConnectAction: CaseIterable {
    case connect
    case saveAsHost
    case addAsMachine

    var id: String {
      switch self {
      case .connect: "quick-connect:connect"
      case .saveAsHost: "quick-connect:save-host"
      case .addAsMachine: "quick-connect:add-machine"
      }
    }
  }

  /// 查询能解析成连接目标时返回目标，否则 nil。只在「全部」与「SSH」过滤器下给快连行。
  static func quickConnectTarget(query: String, filter: OpenQuicklyFilter) -> QuickConnectTarget? {
    guard filter == .all || filter == .ssh, QuickConnectTarget.looksLikeTarget(query) else {
      return nil
    }
    return QuickConnectTarget.parse(query)
  }

  /// 把快连行插到 SSH 小节（`.ssh` 类型）最前面。
  ///
  /// 搜索结果已按小节优先级排好（机器 → 主机 → SSH → 智能体 → 文件），所以插入点就是
  /// 第一个 SSH、智能体或文件条目：有 alias 时正好在 alias 之前，没有时紧跟在主机之后。
  static func inserting(
    _ quickConnect: [OpenQuicklyItem], into items: [OpenQuicklyItem]
  ) -> [OpenQuicklyItem] {
    guard !quickConnect.isEmpty else { return items }
    let quickIDs = Set(quickConnect.map(\.id))
    var result = items.filter { !quickIDs.contains($0.id) }
    let index =
      result.firstIndex { [.ssh, .agent, .file].contains($0.kind) } ?? result.endIndex
    result.insert(contentsOf: quickConnect, at: index)
    return result
  }
}

/// SSH 类条目的数据源与动作。每个浮层一个实例；alias 缓存进程内共享。
@MainActor
final class OpenQuicklyHostTargets {
  private let model: AppModel
  private let window: () -> NSWindow?
  /// Swift 解析器读 `~/.ssh/config` 的回退（Rust 解析器拿不到时用）。
  private let fallbackAliases: () -> [SSHHost]
  /// alias 异步刷新完成后通知浮层重建条目。
  private let onChange: () -> Void

  /// Rust 解析器的 alias 缓存。静态是有意的：浮层会被缓存并反复展示，`aster-ssh config
  /// list` 是一次子进程调用，同一份配置在 TTL 内没必要重复解析。
  private static var aliasCache: (loadedAt: Date, aliases: [OpenQuicklyHostCatalog.Alias])?
  private static var aliasRefreshInFlight = false
  private static let aliasTTL: TimeInterval = 30

  init(
    model: AppModel,
    window: @escaping () -> NSWindow?,
    fallbackAliases: @escaping () -> [SSHHost],
    onChange: @escaping () -> Void
  ) {
    self.model = model
    self.window = window
    self.fallbackAliases = fallbackAliases
    self.onChange = onChange
  }

  // MARK: - 常驻条目

  /// 机器、主机与 alias 条目。alias 优先用缓存，缓存缺失或过期时后台刷新并先用 Swift 回退。
  func entries() -> [OpenQuicklyHostEntry] {
    let fleet = MachineFleetModel.shared
    let directory = SSHHostDirectory.shared
    let machines = fleet.rows.filter { !$0.isLocal && $0.enabled }.map {
      OpenQuicklyHostCatalog.Machine(id: $0.id, label: $0.label, target: $0.sshTarget, hostID: $0.hostID)
    }
    // 配置读失败时列表只是最后有效值，此时清理会误删还在的 ID，所以只在两边都正常时清理。
    if directory.loadError == nil, fleet.configurationError == nil {
      HostUsageTracking.prune(
        keepingIDs: Set(directory.savedHosts.map(\.id)).union(fleet.rows.map(\.id)))
    }
    let rows = OpenQuicklyHostCatalog.rows(
      machines: machines, hosts: directory.hosts, aliases: currentAliases(),
      ledger: HostUsageTracking.ledger())
    return rows.map(entry(for:))
  }

  /// 当前 alias：缓存命中直接用；否则触发后台刷新，这一轮先用 Swift 解析结果。
  private func currentAliases() -> [OpenQuicklyHostCatalog.Alias] {
    if let cache = Self.aliasCache {
      if Date().timeIntervalSince(cache.loadedAt) >= Self.aliasTTL { refreshAliases() }
      return cache.aliases
    }
    refreshAliases()
    return fallbackAliases().map {
      OpenQuicklyHostCatalog.Alias(alias: $0.alias, hostName: $0.hostName, user: $0.user, port: $0.port)
    }
  }

  /// 后台调用 `aster-ssh config list`（支持 Include）。失败保留旧缓存或继续用 Swift 回退。
  private func refreshAliases() {
    guard !Self.aliasRefreshInFlight else { return }
    Self.aliasRefreshInFlight = true
    Task { @MainActor [weak self] in
      defer { Self.aliasRefreshInFlight = false }
      do {
        let listing = try await SSHBrokerSupervisor.shared.configListing()
        let aliases = listing.hosts.filter { Self.isConcreteAlias($0.alias) }.map {
          OpenQuicklyHostCatalog.Alias(alias: $0.alias, hostName: $0.hostName, user: $0.user, port: $0.port)
        }
        let changed = Self.aliasCache?.aliases != aliases
        Self.aliasCache = (Date(), aliases)
        if changed { self?.onChange() }
      } catch {
        DiagnosticsCenter.shared.record(
          "open_quickly.ssh_config_failed", level: .notice, category: .integration, error: error)
      }
    }
  }

  /// `Host *`、`!bad` 这类模式不是可连接的 alias。
  private static func isConcreteAlias(_ alias: String) -> Bool {
    !alias.isEmpty && !alias.contains("*") && !alias.contains("?") && !alias.hasPrefix("!")
      && NativeSSHPaneSpec.target(alias) != nil
  }

  /// 把一行目录数据接上动作。
  private func entry(for row: OpenQuicklyHostCatalog.Row) -> OpenQuicklyHostEntry {
    let item = OpenQuicklyItem(
      id: row.id, kind: row.itemKind, title: row.title, detail: row.detail, score: row.score)
    switch row.kind {
    case .machine(let id):
      return OpenQuicklyHostEntry(
        item: item, symbol: "server.rack", badge: L("机器"), actionTitle: L("切换到机器")
      ) { [weak self] in self?.switchToMachine(id) }
    case .host(let id):
      let name = row.title
      var entry = OpenQuicklyHostEntry(
        item: item, symbol: "network", badge: L("主机"), actionTitle: L("SSH 连接")
      ) { [weak self] in
        self?.dismiss()
        self?.model.openNativeSSH(hostID: id)
      }
      entry.menuActions = [
        (L("添加为机器…"), { [weak self] in
          self?.addMachine(.init(label: name, hostID: id))
        }),
        (L("编辑主机…"), { [weak self] in
          self?.dismiss()
          self?.model.showHostSettings(hostID: id)
        }),
      ]
      return entry
    case .alias(let alias):
      var entry = OpenQuicklyHostEntry(
        item: item, symbol: "terminal", badge: "SSH", actionTitle: L("SSH 连接")
      ) { [weak self] in
        self?.dismiss()
        self?.model.openNativeSSH(target: alias)
      }
      let aliasTarget = QuickConnectTarget.parse(row.detail)
        ?? QuickConnectTarget(user: nil, host: alias, port: nil)
      entry.menuActions = [
        (L("保存为主机…"), { [weak self] in
          self?.saveHost(.init(name: alias, target: aliasTarget))
        }),
        (L("添加为机器…"), { [weak self] in
          self?.addMachine(.init(label: alias, sshTarget: alias))
        }),
        (L("在终端里用 ssh 连接"), { [weak self] in
          self?.dismiss()
          self?.model.openSSHInTerminal(target: alias)
        }),
      ]
      return entry
    }
  }

  // MARK: - 快连

  /// 查询能解析成目标时的三行：原生连接、保存为主机、添加为机器。
  func quickConnectEntries(query: String, filter: OpenQuicklyFilter) -> [OpenQuicklyHostEntry] {
    guard let target = OpenQuicklyHostCatalog.quickConnectTarget(query: query, filter: filter) else {
      return []
    }
    let normalized = target.normalizedTarget
    let display = target.displayText
    return OpenQuicklyHostCatalog.QuickConnectAction.allCases.map { action in
      switch action {
      case .connect:
        return OpenQuicklyHostEntry(
          item: .init(id: action.id, kind: .ssh, title: L("SSH 连接 \(display)"), detail: normalized),
          symbol: "bolt.horizontal", badge: L("快连"), actionTitle: L("SSH 连接")
        ) { [weak self] in
          self?.dismiss()
          self?.model.openNativeSSH(target: normalized)
        }
      case .saveAsHost:
        return OpenQuicklyHostEntry(
          item: .init(id: action.id, kind: .ssh, title: L("保存为主机…"), detail: display),
          symbol: "plus.circle", badge: L("快连"), actionTitle: L("保存为主机…")
        ) { [weak self] in
          self?.saveHost(.init(name: target.host, target: target, connectNow: true))
        }
      case .addAsMachine:
        return OpenQuicklyHostEntry(
          item: .init(id: action.id, kind: .ssh, title: L("添加为机器…"), detail: display),
          symbol: "server.rack", badge: L("快连"), actionTitle: L("添加为机器…")
        ) { [weak self] in
          self?.addMachine(.init(label: target.host, sshTarget: normalized))
        }
      }
    }
  }

  // MARK: - 动作

  private func dismiss() { model.isOpenQuicklyPresented = false }

  /// 在当前窗口切到机器：与侧栏「选机器」同一条路径（校验 + 协调器切换 + 使用频率）。
  private func switchToMachine(_ id: UUID) {
    let controller = window()?.contentViewController as? WorkspaceViewController
    dismiss()
    controller?.presentMachineSelection(id)
  }

  /// 关闭浮层后再弹表单：表单是 sheet，浮层还在时会挡住输入。
  private func saveHost(_ prefill: SaveSSHHostSheet.Prefill) {
    let window = window()
    dismiss()
    model.presentSaveHost(prefill: prefill, in: window)
  }

  /// 走共享的添加机器流程；成功后由流程自己提示，这里只关浮层。
  private func addMachine(_ prefill: MachineSetupFlow.Prefill) {
    let window = window()
    dismiss()
    Task { @MainActor in
      await MachineSetupFlow.presentAddMachine(prefill: prefill, in: window)
    }
  }
}
