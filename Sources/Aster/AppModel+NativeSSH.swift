import AppKit
import AsterCore
import Foundation

// 原生 SSH 标签：Pane 子进程直接是 `aster-ssh client … --tty`，不经登录 Shell。
// 引擎不是 native 或 broker 不可用时回退到「新本地标签里敲 ssh <target>」，并说明原因。
// 另含主机使用频率记录、「保存为主机…」与「编辑主机…」入口，供 Open Quickly 和标签菜单共用。

// MARK: - 使用频率

/// 主机 / 机器使用频率的 App 侧入口。账本是纯值类型，这里负责读写 UserDefaults。
@MainActor
enum HostUsageTracking {
  /// 持久化位置；测试替换成独立 suite，绝不写用户真实配置。
  static var defaults: UserDefaults = .standard

  /// 当前账本。数据损坏时记诊断并按空账本处理——丢的只是排序依据。
  static func ledger() -> HostUsageLedger {
    do {
      return try HostUsageLedger.load(from: defaults)
    } catch {
      DiagnosticsCenter.shared.record(
        "hosts.usage.load_failed", level: .warning, category: .storage, error: error)
      return HostUsageLedger()
    }
  }

  /// 记一次使用（切到机器、打开原生 SSH、快连）。
  static func record(_ key: HostUsageKey, at date: Date = Date()) {
    var ledger = ledger()
    ledger.record(key, at: date)
    save(ledger)
  }

  /// 删除已不存在的主机与机器 ID。
  static func prune(keepingIDs ids: Set<UUID>) {
    var ledger = ledger()
    guard ledger.prune(keepingIDs: ids) else { return }
    save(ledger)
  }

  private static func save(_ ledger: HostUsageLedger) {
    do {
      try ledger.save(to: defaults)
    } catch {
      DiagnosticsCenter.shared.record(
        "hosts.usage.save_failed", level: .warning, category: .storage, error: error)
    }
  }
}

// MARK: - 启动计划

/// 原生 SSH Pane 的启动决策：用 `aster-ssh client`，还是回退到 OpenSSH。
enum NativeSSHPaneLaunch {
  /// 启动计划。
  enum Plan: Equatable {
    /// 直接执行 `aster-ssh client`。
    case native(executable: String, arguments: [String])
    /// 引擎不可用：回退为在普通 Shell 里敲入 `ssh <target>`，并提示原因。
    case openssh(target: String, reason: String)
    /// 连回退目标都拿不到（主机已删除或无法解析）：只能提示原因。
    case unavailable(reason: String)
  }

  /// 取当前原生端点。每次启动现取：broker socket 路径每次 App 启动都会变。测试替换。
  @MainActor static var endpointProvider: () throws -> NativeSSHEndpoint = {
    try SSHBrokerSupervisor.shared.nativeEndpoint()
  }

  /// 按端点可用性决定启动方式。纯函数，便于测试。
  ///
  /// - Parameters:
  ///   - spec: Pane 记录的连接目标。
  ///   - endpoint: 当前端点或取端点时的错误。
  ///   - hosts: 全部主机（含默认项），用于回退时生成 OpenSSH target。
  static func plan(
    for spec: NativeSSHPaneSpec,
    endpoint: Result<NativeSSHEndpoint, any Error>,
    hosts: [SSHHostProfile]
  ) -> Plan {
    if let hostID = spec.hostID, !hosts.contains(where: { $0.id == hostID && !$0.isDefaults }) {
      return .unavailable(reason: L("这台主机已被删除，无法连接。"))
    }
    switch endpoint {
    case .success(let endpoint):
      return .native(executable: endpoint.executablePath, arguments: clientArguments(spec, endpoint))
    case .failure(let error):
      do {
        return .openssh(target: try openSSHTarget(for: spec, hosts: hosts), reason: fallbackReason(error))
      } catch {
        return .unavailable(reason: L("主机配置无法解析：\(String(describing: error))"))
      }
    }
  }

  /// `aster-ssh client` 的 argv：交互 Shell（不带远端命令）、要 pty、允许弹认证表单。
  static func clientArguments(_ spec: NativeSSHPaneSpec, _ endpoint: NativeSSHEndpoint) -> [String] {
    NativeSSHClientInvocation(
      endpoint: endpoint, target: spec.clientTarget, tty: true, noPrompt: false
    ).arguments()
  }

  /// 回退时交给 OpenSSH 的目标：主机按合并默认项后的规格生成，文本原样使用。
  static func openSSHTarget(for spec: NativeSSHPaneSpec, hosts: [SSHHostProfile]) throws -> String {
    if let hostID = spec.hostID {
      return try MachineFleetModel.openSSHTarget(forHost: hostID, in: hosts)
    }
    return spec.target ?? ""
  }

  /// 敲进 Shell 的回退命令。目标只含安全字符时原样写出，否则按 POSIX 单引号转义。
  static func typedSSHCommand(target: String) -> String {
    let safe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-@:/[]%"))
    let quoted =
      target.unicodeScalars.allSatisfy(safe.contains) ? target : RemoteSSHInvocation.quote(target)
    return "ssh \(quoted)"
  }

  /// 回退原因的用户文案。
  static func fallbackReason(_ error: any Error) -> String {
    switch error as? SSHBrokerError {
    case .engineDisabled?:
      L("当前 SSH 引擎是 OpenSSH，已改用终端里的 ssh 命令连接。")
    case .executableMissing?:
      L("找不到 aster-ssh，已改用终端里的 ssh 命令连接。")
    default:
      L("原生 SSH 引擎不可用（\(String(describing: error))），已改用终端里的 ssh 命令连接。")
    }
  }

  /// 标签默认标题：主机名称，其次主机地址；文本目标取解析出的主机名或 alias 本身。
  static func defaultTitle(for spec: NativeSSHPaneSpec, hosts: [SSHHostProfile]) -> String {
    if let hostID = spec.hostID, let host = hosts.first(where: { $0.id == hostID }) {
      return host.name.isEmpty ? host.host : host.name
    }
    let text = spec.target ?? "SSH"
    return QuickConnectTarget.parse(text)?.host ?? text
  }
}

// MARK: - 打开原生 SSH 标签

extension AppModel {
  /// 打开一台已保存主机的原生 SSH 标签。
  func openNativeSSH(hostID: UUID) {
    guard SSHHostDirectory.shared.host(hostID).map({ !$0.isDefaults }) == true else {
      notice = L("主机不存在。")
      return
    }
    HostUsageTracking.record(.id(hostID))
    openNativeSSH(spec: .host(hostID))
  }

  /// 打开 alias 或 `user@host:port` 目标的原生 SSH 标签。
  func openNativeSSH(target: String) {
    guard let spec = NativeSSHPaneSpec.target(target) else {
      notice = L("无效的 SSH 目标。")
      return
    }
    HostUsageTracking.record(.target(target))
    openNativeSSH(spec: spec)
  }

  /// 新建一个本地标签，Pane 直接运行 `aster-ssh client`；引擎不可用时回退到敲 ssh 命令。
  ///
  /// 这里先探一次端点只为决定「开原生标签还是回退」：真正的启动命令在 Pane 挂载时由
  /// `TerminalSession` 现取端点再生成，恢复的标签也走同一条路径。
  private func openNativeSSH(spec: NativeSSHPaneSpec) {
    guard leaveRemoteMachineForNativeSSH() else { return }
    let hosts = SSHHostDirectory.shared.hosts
    let endpoint = Result { try NativeSSHPaneLaunch.endpointProvider() }
    switch NativeSSHPaneLaunch.plan(for: spec, endpoint: endpoint, hosts: hosts) {
    case .unavailable(let reason):
      notice = reason
    case .openssh(let target, let reason):
      openSSHInTerminal(target: target, reason: reason)
    case .native:
      let title = NativeSSHPaneLaunch.defaultTitle(for: spec, hosts: hosts)
      // 远端 Shell 的目录与本机无关；用 home 作本地目录，避免新标签被归进当前项目分组。
      let directory = FileManager.default.homeDirectoryForCurrentUser.path
      let pane = PaneDescriptor(kind: .terminal, workingDirectory: directory, nativeSSH: spec)
      let tab = TerminalTabItem(
        title: title, workingDirectory: directory, layout: .leaf(pane),
        titleState: TerminalTitleState(fallback: title))
      insertTab(tab, hasContent: true)
    }
  }

  /// 在新本地标签里预填 `ssh <target>`（不回车），由用户确认执行。原生引擎不可用时的回退。
  ///
  /// - Parameter reason: 非空时作为提示显示，告诉用户为什么没走原生连接。
  func openSSHInTerminal(target: String, reason: String? = nil) {
    guard NativeSSHPaneSpec.target(target) != nil else {
      notice = L("无效的 SSH 目标。")
      return
    }
    guard leaveRemoteMachineForNativeSSH() else { return }
    let command = NativeSSHPaneLaunch.typedSSHCommand(target: target)
    newTab(hasContent: true)
    if let reason { notice = reason }
    let tab = selectedTab
    // 与 `openSSHHost` 相同：新 Shell 需要一点时间出提示符，过早写入会被 rc 脚本吞掉。
    Task { @MainActor [weak tab] in
      do { try await Task.sleep(for: .milliseconds(800)) } catch { return }
      tab?.activeSession?.typeText(command)
    }
  }

  /// 原生 SSH 标签只能是本地标签：当前窗口在远端机器上时先切回 Local。
  ///
  /// 选「切回 Local」而不是拒绝：用户的意图是开一个连到某主机的终端，这和远端机器的
  /// 共享工作区无关；切换走侧栏同一条路径（机器列表高亮 + 协调器同步前半程），远端标签
  /// 只是被分离，不会结束。切不回去（没有协调器）时提示原因并放弃。
  private func leaveRemoteMachineForNativeSSH() -> Bool {
    guard remoteStructureHandler != nil else { return true }
    if let coordinator = remoteStructureHandler as? RemoteWorkspaceCoordinator {
      _ = MachineFleetModel.shared.selectMachine(MachineProfile.localProfileID)
      coordinator.beginActivation(machineProfileID: MachineProfile.localProfileID)
    }
    guard remoteStructureHandler == nil else {
      notice = L("当前窗口在远端机器上，请先切回本机再打开 SSH 标签。")
      return false
    }
    return true
  }
}

// MARK: - 保存为主机 / 编辑主机

extension AppModel {
  /// 弹出「保存为主机…」表单，保存后可选立即连接。
  func presentSaveHost(prefill: SaveSSHHostSheet.Prefill, in window: NSWindow?) {
    let groups = Set(SSHHostDirectory.shared.savedHosts.compactMap(\.group)).sorted()
    guard let draft = SaveSSHHostSheet.prompt(prefill: prefill, groups: groups, in: window) else {
      return
    }
    let profile: SSHHostProfile
    do {
      profile = try SaveSSHHostSheet.makeProfile(draft)
      try SettingsHostsBridge.validate(profile, in: SSHHostDirectory.shared.hosts + [profile])
      try SSHHostDirectory.shared.upsert(profile)
    } catch {
      MachineSetupSheet.presentFailure(SaveSSHHostSheet.describe(error), in: window)
      return
    }
    if draft.connectNow { openNativeSSH(hostID: profile.id) }
  }

  /// 打开设置的「主机」分类并编辑指定主机（主机不存在时停在列表）。
  func showHostSettings(hostID: UUID?) {
    guard let delegate = NSApp.delegate as? AsterAppDelegate else { return }
    delegate.showSettings(section: .hosts)
    guard let hostID else { return }
    let settings = NSApp.windows.lazy
      .compactMap { $0.contentViewController as? SettingsViewController }.first
    settings?.showHost(hostID)
  }

  /// 标签右键菜单里的主机项：原生 SSH 标签给「编辑主机…」，手敲 ssh 的本地标签给「保存为主机…」。
  func hostMenuItems(for tab: TerminalTabItem, window: NSWindow?) -> [NSMenuItem] {
    guard let session = tab.activeSession else { return [] }
    if let spec = session.nativeSSH {
      if let hostID = spec.hostID {
        return [
          ActionMenuItem(title: L("编辑主机…")) { [weak self] in
            self?.showHostSettings(hostID: hostID)
          }
        ]
      }
      guard let text = spec.target, let target = QuickConnectTarget.parse(text) else { return [] }
      let prefill = SaveSSHHostSheet.Prefill(name: text, target: target)
      return [
        ActionMenuItem(title: L("保存为主机…")) { [weak self] in
          self?.presentSaveHost(prefill: prefill, in: window)
        }
      ]
    }
    // 远端机器上的 ssh 进程跑在远端，本机的 ~/.ssh 与它无关，不提供保存。
    guard isLocalMachineActive, let invocation = session.sshInvocation else { return [] }
    let resolved = session.sshRemoteEndpoint
    return [
      ActionMenuItem(title: L("保存为主机…")) { [weak self] in
        switch QuickConnectTarget.derive(from: invocation) {
        case .target(let target):
          let prefill = SaveSSHHostSheet.Prefill.derived(
            target: target, invocation: invocation, resolved: resolved)
          self?.presentSaveHost(prefill: prefill, in: window)
        case .rejected(let rejection):
          MachineSetupSheet.presentNotice(
            SaveSSHHostSheet.describe(rejection), title: L("无法从这条 ssh 命令保存主机"),
            in: window)
        }
      }
    ]
  }
}
