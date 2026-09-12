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

  /// 构建「机器」分区：可折叠组头 + Local 与全部保存的机器行。
  ///
  /// 折叠状态复用侧栏既有的分组折叠偏好，键名固定为 `__machines__`，不与用户的
  /// 项目/日期分组标题冲突。
  func makeMachineSection() -> NSView {
    let theme = preferences.activeTheme
    let column = NSStackView()
    column.orientation = .vertical
    column.alignment = .width
    column.spacing = 0

    let collapsed = preferences.isSidebarGroupCollapsed(title: Self.machineSectionKey)
    let header = makeMachineSectionHeader(collapsed: collapsed, theme: theme)
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

    guard !collapsed else { return column }

    for row in machineFleet.rows {
      let button = MachineRowButton(
        row: row,
        selected: row.id == machineFleet.activeMachineID,
        theme: theme,
        action: { [weak self] in self?.selectMachine(row.id) },
        menuProvider: { [weak self] in self?.makeMachineMenu(row) })
      column.addArrangedSubview(button)
      button.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
    }
    return column
  }

  /// 「机器」组头：折叠箭头 + 标题 + 「+」添加按钮。
  ///
  /// 「+」是添加机器的主入口；它必须在这里而不是藏进设置页，因为 §4.1 第 2 条要求
  /// 添加动作是一个交互式设置流程。
  private func makeMachineSectionHeader(collapsed: Bool, theme: TerminalTheme) -> NSView {
    let foreground = NSColor(
      theme.resolvedColor(forSlot: "tab.foreground")
        ?? theme.style.tab.foreground ?? theme.palette.secondaryForeground)
    let host = SidebarGroupHeaderView { [weak self] in
      guard let self else { return }
      self.preferences.toggleSidebarGroupCollapsed(title: Self.machineSectionKey)
      self.scheduleRefresh()
    }
    host.identifier = NSUserInterfaceItemIdentifier("machine-section-header")
    host.setAccessibilityRole(.button)
    host.setAccessibilityLabel("\(collapsed ? "展开" : "折叠")机器分区")
    host.translatesAutoresizingMaskIntoConstraints = false
    host.heightAnchor.constraint(equalToConstant: 30).isActive = true

    let row = NSStackView()
    row.orientation = .horizontal
    row.spacing = 5
    row.alignment = .centerY
    for symbol in [collapsed ? "chevron.right" : "chevron.down", "server.rack"] {
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
    case .added, .updated:
      scheduleRefresh()
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
