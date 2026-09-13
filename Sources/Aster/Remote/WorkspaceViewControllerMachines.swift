import AppKit
import AsterCore
import Combine
import Foundation

/// 机器侧栏分区的构建与动作（P4.3 的真实可点入口）。
///
/// 放在扩展里而不是塞进 `WorkspaceView.swift`：机器分区与标签列表是两个独立关注点，
/// 分开后标签栏的既有行为不会因为远程工作模式的改动被牵连。
extension WorkspaceViewController {
  /// 当前窗口使用的机器编排。测试替换 `MachineFleetModel.shared` 以隔离配置目录。
  var machineFleet: MachineFleetModel { MachineFleetModel.shared }

  /// 侧栏左下角的机器切换器：显示当前活动机器与状态，点开是机器列表弹出层。
  func makeMachineSwitcher() -> NSView {
    let theme = preferences.activeTheme
    let row = machineFleet.rows.first { $0.id == machineFleet.activeMachineID }
    let button = MachineSwitcherButton(row: row, theme: theme) { [weak self] in
      self?.makeMachineSection() ?? NSView()
    }
    let host = NSView()
    host.identifier = NSUserInterfaceItemIdentifier("machine-switcher-host")
    host.addSubview(button)
    let padding = CGFloat(theme.style.resolvedSidebarPadding.leading)
    NSLayoutConstraint.activate([
      button.leadingAnchor.constraint(equalTo: host.leadingAnchor, constant: padding + 4),
      button.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
      button.topAnchor.constraint(equalTo: host.topAnchor, constant: 6),
      button.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -10),
    ])
    return host
  }

  /// 机器列表（弹出层内容）：组头 + Local 与全部保存的机器行 + 「添加机器」。
  ///
  /// 行控件与右键菜单和常驻分区时代完全一样，只是宿主从侧栏顶部换成了弹出层。
  func makeMachineSection() -> NSView {
    let theme = preferences.activeTheme
    let column = NSStackView()
    column.orientation = .vertical
    column.alignment = .width
    column.spacing = 0
    column.translatesAutoresizingMaskIntoConstraints = false
    column.widthAnchor.constraint(equalToConstant: 300).isActive = true
    column.edgeInsets = NSEdgeInsets(top: 6, left: 0, bottom: 6, right: 0)

    let header = makeMachineSectionHeader(collapsed: false, theme: theme)
    column.addArrangedSubview(header)
    header.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true

    if let message = machineFleet.configurationError {
      // 配置损坏时保留最后一份有效配置与现存连接，只显示可恢复错误（§4.1 第 8 条）。
      let warning = makeLabel(message, size: 10, weight: .regular, color: .systemOrange)
      warning.identifier = NSUserInterfaceItemIdentifier("machine-config-error")
      warning.lineBreakMode = .byTruncatingTail
      warning.toolTip = message
      let host = NSView()
      host.addSubview(warning)
      warning.translatesAutoresizingMaskIntoConstraints = false
      NSLayoutConstraint.activate([
        warning.leadingAnchor.constraint(
          equalTo: host.leadingAnchor,
          constant: CGFloat(theme.style.resolvedSidebarPadding.leading) + 12),
        warning.trailingAnchor.constraint(lessThanOrEqualTo: host.trailingAnchor, constant: -8),
        warning.topAnchor.constraint(equalTo: host.topAnchor, constant: 2),
        warning.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -2),
      ])
      column.addArrangedSubview(host)
      host.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }

    for row in machineFleet.rows {
      let button = MachineRowButton(
        row: row,
        selected: row.id == machineFleet.activeMachineID,
        theme: theme,
        action: { [weak self] in
          // 选中即关闭弹出层：切换机器会重建侧栏，弹出层留着只会挂在旧按钮上。
          self?.machineSwitcher?.dismissPopover()
          self?.selectMachine(row.id)
        },
        menuProvider: { [weak self] in self?.makeMachineMenu(row) })
      column.addArrangedSubview(button)
      button.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }
    return column
  }

  /// 当前侧栏里的切换器按钮（弹出层的锚点）。
  var machineSwitcher: MachineSwitcherButton? {
    func find(_ view: NSView) -> MachineSwitcherButton? {
      if let button = view as? MachineSwitcherButton { return button }
      for child in view.subviews { if let found = find(child) { return found } }
      return nil
    }
    return find(view)
  }

  /// 「机器」组头：折叠箭头 + 标题 + 「+」添加按钮。
  ///
  /// 「+」是添加机器的主入口；它必须在这里而不是藏进设置页，因为 §4.1 第 2 条要求
  /// 添加动作是一个交互式设置流程。
  private func makeMachineSectionHeader(collapsed: Bool, theme: TerminalTheme) -> NSView {
    let foreground = NSColor(
      theme.resolvedColor(forSlot: "tab.foreground")
        ?? theme.style.tab.foreground ?? theme.palette.secondaryForeground)
    // 组头只是弹出层里的标题：不再折叠（列表本身就在弹出层里，关掉弹出层即"折叠"）。
    _ = collapsed
    let host = SidebarGroupHeaderView {}
    host.identifier = NSUserInterfaceItemIdentifier("machine-section-header")
    host.setAccessibilityLabel("机器分区")
    host.translatesAutoresizingMaskIntoConstraints = false
    host.heightAnchor.constraint(equalToConstant: 30).isActive = true

    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 5
    row.alignment = .centerY
    for symbol in ["server.rack"] {
      let icon = NSImageView()
      icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
      icon.contentTintColor = foreground
      icon.setContentHuggingPriority(.required, for: .horizontal)
      row.addArrangedSubview(icon)
    }
    let label = makeLabel("MACHINES", size: 10.5, weight: .semibold, color: foreground)
    label.identifier = NSUserInterfaceItemIdentifier("machine-section-title")
    row.addArrangedSubview(label)

    let add = NSButton()
    add.isBordered = false
    add.title = ""
    add.image = NSImage(systemSymbolName: "plus", accessibilityDescription: "添加机器")?
      .withSymbolConfiguration(.init(pointSize: 10, weight: .semibold))
    add.contentTintColor = foreground
    add.identifier = NSUserInterfaceItemIdentifier("machine-add-button")
    add.setAccessibilityLabel("添加机器")
    add.target = self
    add.action = #selector(presentAddMachine)
    add.translatesAutoresizingMaskIntoConstraints = false

    host.addSubview(row)
    host.addSubview(add)
    row.translatesAutoresizingMaskIntoConstraints = false
    NSLayoutConstraint.activate([
      row.leadingAnchor.constraint(
        equalTo: host.leadingAnchor,
        constant: CGFloat(theme.style.resolvedSidebarPadding.leading) + 10),
      row.centerYAnchor.constraint(equalTo: host.centerYAnchor),
      add.trailingAnchor.constraint(equalTo: host.trailingAnchor, constant: -8),
      add.centerYAnchor.constraint(equalTo: host.centerYAnchor),
      row.trailingAnchor.constraint(lessThanOrEqualTo: add.leadingAnchor, constant: -6),
    ])
    return host
  }

  /// 机器行右键菜单：重命名 / 启用 / 禁用 / 移除。
  ///
  /// 禁用与移除即使机器离线也必须可用（§4.1 第 7 条），所以这些项不按连接状态置灰；
  /// Local 不提供这些项——它不是一份可以删掉的配置。
  private func makeMachineMenu(_ row: MachineFleetRow) -> NSMenu? {
    guard !row.isLocal else { return nil }
    let menu = NSMenu(title: row.label)
    menu.autoenablesItems = false

    let rename = NSMenuItem(title: "重命名…", action: #selector(renameMachine(_:)), keyEquivalent: "")
    rename.target = self
    rename.representedObject = row.id
    rename.identifier = NSUserInterfaceItemIdentifier("machine-menu-rename")
    menu.addItem(rename)

    let toggle = NSMenuItem(
      title: row.enabled ? "禁用" : "启用", action: #selector(toggleMachineEnabled(_:)),
      keyEquivalent: "")
    toggle.target = self
    toggle.representedObject = row.id
    toggle.identifier = NSUserInterfaceItemIdentifier("machine-menu-toggle")
    menu.addItem(toggle)

    // 更新远端服务是显式事务（§7）：只在用户点了它才会停止/替换远端进程，后台永不自动做。
    let update = NSMenuItem(
      title: "更新远端服务…", action: #selector(updateMachineService(_:)), keyEquivalent: "")
    update.target = self
    update.representedObject = row.id
    update.identifier = NSUserInterfaceItemIdentifier("machine-menu-update-service")
    menu.addItem(update)

    // 已探测到清单时直接列成子菜单，一步启动；未探测/为空时保留弹窗入口（弹窗会现探）。
    let newAgent = NSMenuItem(title: "新建 Agent", action: nil, keyEquivalent: "")
    newAgent.identifier = NSUserInterfaceItemIdentifier("machine-menu-new-agent")
    if let agents = row.agents, !agents.isEmpty {
      let submenu = NSMenu(title: "新建 Agent")
      submenu.autoenablesItems = false
      for entry in agents {
        let item = NSMenuItem(
          title: MachineRowButton.agentsText([entry]), action: #selector(newMachineAgentDirect(_:)),
          keyEquivalent: "")
        item.target = self
        item.representedObject = [row.id.uuidString, entry.provider.rawValue]
        item.identifier = NSUserInterfaceItemIdentifier("machine-menu-agent-\(entry.provider.rawValue)")
        submenu.addItem(item)
      }
      submenu.addItem(.separator())
      let rescan = NSMenuItem(title: "重新探测…", action: #selector(rescanMachineAgents(_:)), keyEquivalent: "")
      rescan.target = self
      rescan.representedObject = row.id
      submenu.addItem(rescan)
      newAgent.submenu = submenu
    } else {
      newAgent.title = "新建 Agent…"
      newAgent.action = #selector(newMachineAgent(_:))
      newAgent.target = self
      newAgent.representedObject = row.id
    }
    menu.addItem(newAgent)

    let agents = NSMenuItem(
      title: "远端 Agent 集成…", action: #selector(configureMachineAgents(_:)), keyEquivalent: "")
    agents.target = self
    agents.representedObject = row.id
    agents.identifier = NSUserInterfaceItemIdentifier("machine-menu-agent-integration")
    menu.addItem(agents)

    menu.addItem(.separator())
    let remove = NSMenuItem(title: "移除…", action: #selector(removeMachine(_:)), keyEquivalent: "")
    remove.target = self
    remove.representedObject = row.id
    remove.identifier = NSUserInterfaceItemIdentifier("machine-menu-remove")
    menu.addItem(remove)
    return menu
  }

  // MARK: - 动作

  /// 添加机器：面板 → `RemoteMachineSetup` 事务 → 成功才保存配置。
  @objc func presentAddMachine() {
    guard let draft = MachineSetupSheet.promptForNewMachine(in: view.window) else { return }
    let window = view.window
    Task { @MainActor [weak self] in
      guard let self else { return }
      let result = await self.machineFleet.addMachine(
        label: draft.label, sshTarget: draft.sshTarget, sessionName: draft.sessionName,
        confirm: { MachineSetupSheet.confirm($0, in: window) })
      self.present(result, in: window)
    }
  }

  /// 子菜单直接选中某个已探测到的 Agent：跳过弹窗，切到该机器后立即开标签。
  @objc private func newMachineAgentDirect(_ sender: NSMenuItem) {
    guard let pair = sender.representedObject as? [String], pair.count == 2,
      let id = UUID(uuidString: pair[0]), let provider = AgentProvider(rawValue: pair[1])
    else { return }
    let window = view.window
    Task { @MainActor [weak self] in
      guard let self else { return }
      if self.machineFleet.activeMachineID != id {
        if let failure = self.machineFleet.selectMachine(id) {
          MachineSetupSheet.presentFailure(failure, in: window)
          return
        }
        self.scheduleRefresh()
        await self.remoteWorkspaces.activate(machineProfileID: id)
      }
      self.remoteWorkspaces.createAgentTab(provider: provider, workingDirectory: nil)
    }
  }

  /// 重新探测远端 Agent 清单并刷新侧栏。
  @objc private func rescanMachineAgents(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID else { return }
    let window = view.window
    Task { @MainActor [weak self] in
      guard let self else { return }
      do {
        _ = try await self.machineFleet.refreshAgentCatalog(id)
        self.scheduleRefresh()
      } catch {
        MachineSetupSheet.presentFailure(
          "远端 Agent 探测失败：\(RemoteSetupDescription.text(for: error))", in: window)
      }
    }
  }

  /// 侧栏右键「新建 Agent…」。
  @objc private func newMachineAgent(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID else { return }
    presentNewRemoteAgent(machineID: id)
  }

  /// 新建远端 Agent：探测远端清单 → 选 CLI → 切到该机器 → 服务端事务以 Agent 身份开标签。
  func presentNewRemoteAgent(machineID id: UUID) {
    let window = view.window
    let label = machineFleet.rows.first { $0.id == id }?.label ?? ""
    Task { @MainActor [weak self] in
      guard let self else { return }
      let catalog: [RemoteAgentCatalogEntry]
      do { catalog = try await self.machineFleet.remoteAgentCatalog(id) } catch {
        MachineSetupSheet.presentFailure(
          "远端 Agent 探测失败：\(RemoteSetupDescription.text(for: error))", in: window)
        return
      }
      guard !catalog.isEmpty else {
        MachineSetupSheet.presentNotice(
          "远端 PATH 上没有发现任何已知 Agent CLI（claude、codex、grok、gemini…）。",
          title: "没有可启动的 Agent", in: window)
        return
      }
      guard let provider = MachineSetupSheet.promptForRemoteAgent(catalog, machineLabel: label, in: window)
      else { return }
      // 目标机器不是活动机器时先切过去：结构事务只对活动机器提交。
      if self.machineFleet.activeMachineID != id {
        if let failure = self.machineFleet.selectMachine(id) {
          MachineSetupSheet.presentFailure(failure, in: window)
          return
        }
        self.scheduleRefresh()
        await self.remoteWorkspaces.activate(machineProfileID: id)
      }
      self.remoteWorkspaces.createAgentTab(provider: provider, workingDirectory: nil)
    }
  }

  /// 侧栏右键「远端 Agent 集成…」。
  @objc private func configureMachineAgents(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID else { return }
    presentAgentIntegration(machineID: id, automatic: false)
  }

  /// 远端 Agent 集成：探测 → 确认 → 安装 → 结果。
  /// `automatic` 是添加机器成功后的自动调用：远端没有可集成 CLI 时静默，不打扰用户。
  func presentAgentIntegration(machineID id: UUID, automatic: Bool) {
    let window = view.window
    let target = machineFleet.rows.first { $0.id == id }?.sshTarget ?? ""
    Task { @MainActor [weak self] in
      guard let self else { return }
      let result = await self.machineFleet.configureAgentIntegration(
        id, confirm: { MachineSetupSheet.confirmAgentIntegration($0, target: target, in: window) })
      switch result {
      case .installed(let report):
        // 自动调用且早已全部就位：什么也不说。
        if automatic, report.pending.isEmpty, report.entries.allSatisfy({ $0.failure == nil }) {
          return
        }
        MachineSetupSheet.presentAgentIntegration(report, in: window)
      case .nothingToInstall(let message):
        if !automatic { MachineSetupSheet.presentNotice(message, title: "没有可集成的 Agent", in: window) }
      case .cancelled:
        break
      case .failed(let message):
        MachineSetupSheet.presentFailure(message, in: window)
      }
    }
  }

  /// 侧栏右键「更新远端服务…」。
  @objc private func updateMachineService(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID else { return }
    presentUpdateService(machineID: id)
  }

  /// 更新远端服务：探测 → 确认（含受影响终端数）→ 停止/安装/重启 → 更新配置。
  /// 侧栏右键与「文件 ▸ 更新远端服务…」共用这一入口。
  func presentUpdateService(machineID id: UUID) {
    let window = view.window
    Task { @MainActor [weak self] in
      guard let self else { return }
      let result = await self.machineFleet.updateService(
        id, confirm: { MachineSetupSheet.confirm($0, in: window) })
      self.present(result, in: window)
    }
  }

  /// 添加 / 更新结果的统一呈现。
  private func present(_ result: MachineSetupResult, in window: NSWindow?) {
    switch result {
    case .added(let profile):
      scheduleRefresh()
      // 连上机器只得到一个 Shell 和 SSH 没区别：接着把 Agent 集成装到远端，
      // 远端 Agent 的状态与通知才会像本机一样出现。没有可集成 CLI 时静默。
      presentAgentIntegration(machineID: profile.id, automatic: true)
    case .updated(let profile):
      // 服务已换成新实例：丢掉这台机器的旧投影，活动机器会立即重新握手并冷恢复失效窗格。
      scheduleRefresh()
      Task { @MainActor [weak self] in
        await self?.remoteWorkspaces.discard(machineProfileID: profile.id)
      }
    case .upToDate(let message):
      MachineSetupSheet.presentNotice(message, in: window)
    case .cancelled:
      // 取消不保存任何配置，也不提示错误：这是一次正常的中止。
      break
    case .failed(let message):
      MachineSetupSheet.presentFailure(message, in: window)
    }
  }

  @objc private func renameMachine(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID,
      let row = machineFleet.rows.first(where: { $0.id == id }),
      let label = MachineSetupSheet.promptForRename(current: row.label, in: view.window)
    else { return }
    if let failure = machineFleet.rename(id, to: label) {
      MachineSetupSheet.presentFailure(failure, in: view.window)
      return
    }
    scheduleRefresh()
  }

  @objc private func toggleMachineEnabled(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID,
      let row = machineFleet.rows.first(where: { $0.id == id })
    else { return }
    if let failure = machineFleet.setEnabled(id, !row.enabled) {
      MachineSetupSheet.presentFailure(failure, in: view.window)
      return
    }
    scheduleRefresh()
  }

  @objc private func removeMachine(_ sender: NSMenuItem) {
    guard let id = sender.representedObject as? UUID,
      let row = machineFleet.rows.first(where: { $0.id == id }),
      MachineSetupSheet.confirmRemoval(label: row.label, in: view.window)
    else { return }
    if let failure = machineFleet.remove(id) {
      MachineSetupSheet.presentFailure(failure, in: view.window)
      return
    }
    scheduleRefresh()
  }

  /// 选中一台机器。离线机器允许选中查看缓存结构，但输入与导航由展示模型禁用。
  ///
  /// 只更新侧栏高亮等于没切机器：标签集合、画面订阅与交互闸门都必须跟着换，因此这里
  /// 一定要把切换交给 `RemoteWorkspaceCoordinator`。它内部先取消被切走机器的画面订阅，
  /// 再换标签集合，最后才取新机器的完整快照。
  private func selectMachine(_ id: UUID) {
    if let failure = machineFleet.selectMachine(id) {
      MachineSetupSheet.presentFailure(failure, in: view.window)
      return
    }
    scheduleRefresh()
    Task { @MainActor [weak self] in
      await self?.remoteWorkspaces.activate(machineProfileID: id)
    }
  }

  /// 机器分区的折叠状态键。加下划线前缀，避免与用户目录分组标题碰撞。
  static var machineSectionKey: String { "__machines__" }
}
