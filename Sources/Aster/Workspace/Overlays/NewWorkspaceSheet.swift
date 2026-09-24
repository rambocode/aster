// 「新建工作区」表单（⌘⇧N）：名称 + 主机下拉（本机 / 机器 / 已保存主机 / ssh 别名 / 添加主机…）+「在新窗口中打开」。
import AppKit
import AsterCore

// MARK: - 纯逻辑

/// 主机下拉里可选的目标。
enum NewWorkspaceHostChoice: Equatable {
  case local
  /// 已添加的机器（装有 aster-session）。
  case machine(UUID)
  /// 已保存但还没添加成机器的主机：先走添加机器流程。
  case savedHost(id: UUID, name: String)
  /// `~/.ssh/config` 里的别名：先走添加机器流程。
  case sshAlias(String)
  /// 打开设置的「主机」分类。
  case addHost

  /// 选中后才需要连到远端的目标；只有这些目标「在新窗口中打开」才有意义。
  var isRemote: Bool {
    switch self {
    case .machine, .savedHost, .sshAlias: true
    case .local, .addHost: false
    }
  }
}

/// 主机下拉的一行。
enum NewWorkspaceMenuEntry: Equatable {
  case choice(NewWorkspaceHostChoice, title: String)
  /// 不可选的小节标题。
  case header(String)
  case separator
}

/// 下拉里的一台已添加机器。
struct NewWorkspaceMachine: Equatable {
  var id: UUID
  var label: String
  var hostID: UUID?
  var sshTarget: String?
  var enabled: Bool
  var state: SessionConnectionState
}

/// 表单提交后要做的事。
enum NewWorkspaceSubmission: Equatable {
  /// 新开一个固定保留的本地工作区窗口。
  case createLocal(name: String)
  /// 在已添加的机器上建远端工作区；`inNewWindow` 为 false 时落在当前窗口。
  case createRemote(machineID: UUID, name: String, inNewWindow: Bool)
  /// 先添加机器，成功后再在新机器上建远端工作区。
  case addMachineThenCreate(prefill: MachineSetupFlow.Prefill, name: String, inNewWindow: Bool)
  /// 打开设置的「主机」分类。
  case openHostSettings
}

/// 表单的纯逻辑：下拉选项构建与提交分派。不碰任何窗口，测试直接调用。
@MainActor
enum NewWorkspaceForm {
  /// 构建主机下拉：本机 → 已添加的机器 → 未添加成机器的主机 → ssh 别名 → 添加主机…
  ///
  /// 去重规则：已经被某台机器绑定（`hostID`）的主机不再出现在主机组；别名已被某台机器
  /// 当作 target、或已作为主机保存过时，不再出现在别名组。一个目标只出现一次，
  /// 用户不会对同一台机器选出两条路径。`aliases` 为 nil 表示拿不到（broker 不可用），整组不显示。
  static func menuEntries(
    machines: [NewWorkspaceMachine], hosts: [SSHHostProfile], aliases: [String]?
  ) -> [NewWorkspaceMenuEntry] {
    var entries: [NewWorkspaceMenuEntry] = [.choice(.local, title: L("本机"))]
    // 已禁用的机器建不了工作区（选中机器会被拒绝），不列出来。
    let usable = machines.filter(\.enabled)
    if !usable.isEmpty {
      entries += [.separator, .header(L("机器"))]
      entries += usable.map {
        .choice(.machine($0.id), title: "\($0.label)（\(MachineRowButton.stateText($0.state))）")
      }
    }
    let boundHostIDs = Set(machines.compactMap(\.hostID))
    let realHosts = hosts.filter { !$0.isDefaults }
    let unboundHosts = realHosts.filter { !boundHostIDs.contains($0.id) }
    if !unboundHosts.isEmpty {
      entries += [.separator, .header(L("主机"))]
      entries += unboundHosts.map { .choice(.savedHost(id: $0.id, name: $0.name), title: $0.name) }
    }
    if let aliases {
      let taken = Set(machines.compactMap(\.sshTarget)).union(realHosts.map(\.name))
      var seen: Set<String> = []
      let fresh = aliases.filter { !$0.isEmpty && !taken.contains($0) && seen.insert($0).inserted }
      if !fresh.isEmpty {
        entries += [.separator, .header(L("SSH 别名"))]
        entries += fresh.map { .choice(.sshAlias($0), title: $0) }
      }
    }
    entries += [.separator, .choice(.addHost, title: L("添加主机…"))]
    return entries
  }

  /// 把表单结果翻译成要执行的动作。名称非法时抛 `NamedWorkspaceRegistryError`；
  /// 「添加主机…」不需要名称。本地工作区本来就是一个窗口，勾选框对它无意义。
  static func submission(
    choice: NewWorkspaceHostChoice, name rawName: String, openInNewWindow: Bool
  ) throws -> NewWorkspaceSubmission {
    if choice == .addHost { return .openHostSettings }
    let name = try NamedWorkspaceRegistry.validatedName(rawName)
    switch choice {
    case .local:
      return .createLocal(name: name)
    case .machine(let id):
      return .createRemote(machineID: id, name: name, inNewWindow: openInNewWindow)
    case .savedHost(let id, let hostName):
      return .addMachineThenCreate(
        prefill: .init(label: hostName, hostID: id), name: name, inNewWindow: openInNewWindow)
    case .sshAlias(let alias):
      return .addMachineThenCreate(
        prefill: .init(label: alias, sshTarget: alias), name: name, inNewWindow: openInNewWindow)
    case .addHost:
      return .openHostSettings
    }
  }
}

// MARK: - 界面

/// 新建工作区表单：NSAlert + accessory view，风格与 `MachineSetupSheet` 一致。
@MainActor
enum NewWorkspaceSheet {
  /// 「添加主机…」被选中时用来结束对话框的返回码。
  private static let addHostResponse = NSApplication.ModalResponse(rawValue: 1_100)

  /// 表单内容与下拉交互。对话框同步运行，局部变量持有它直到对话框结束。
  @MainActor
  private final class Form: NSObject {
    let nameField: NSTextField
    let hostPopUp = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
    let newWindowCheckbox = NSButton(checkboxWithTitle: L("在新窗口中打开"), target: nil, action: nil)
    /// 与下拉菜单项的 tag 一一对应。
    private var choices: [NewWorkspaceHostChoice] = []
    weak var alert: NSAlert?

    init(name: String, entries: [NewWorkspaceMenuEntry], selected: NewWorkspaceHostChoice, openInNewWindow: Bool) {
      nameField = WorkspaceSheetPresenter.makeNameField(name)
      super.init()
      hostPopUp.identifier = NSUserInterfaceItemIdentifier("new-workspace-host")
      newWindowCheckbox.identifier = NSUserInterfaceItemIdentifier("new-workspace-new-window")
      newWindowCheckbox.state = openInNewWindow ? .on : .off
      let menu = NSMenu()
      menu.autoenablesItems = false
      for entry in entries {
        switch entry {
        case .separator:
          menu.addItem(.separator())
        case .header(let title):
          menu.addItem(.sectionHeader(title: title))
        case .choice(let choice, let title):
          let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
          item.tag = choices.count
          choices.append(choice)
          menu.addItem(item)
        }
      }
      hostPopUp.menu = menu
      if let index = choices.firstIndex(of: selected) { hostPopUp.selectItem(withTag: index) }
      hostPopUp.target = self
      hostPopUp.action = #selector(hostChanged)
      updateCheckbox()
    }

    var selectedChoice: NewWorkspaceHostChoice {
      let tag = hostPopUp.selectedTag()
      return choices.indices.contains(tag) ? choices[tag] : .local
    }

    /// 纵向排好的 accessory view：名称、主机、勾选框。
    func makeAccessoryView() -> NSView {
      let stack = NSStackView(views: [nameField, hostPopUp, newWindowCheckbox])
      stack.orientation = .vertical
      stack.alignment = .leading
      stack.spacing = 8
      for view in [nameField, hostPopUp] {
        view.translatesAutoresizingMaskIntoConstraints = false
        view.widthAnchor.constraint(equalToConstant: 300).isActive = true
      }
      stack.frame = NSRect(x: 0, y: 0, width: 300, height: 86)
      return stack
    }

    /// 「添加主机…」是一个跳转而不是目标：选中即结束表单，由调用方打开设置。
    @objc private func hostChanged() {
      if selectedChoice == .addHost, let alert {
        WorkspaceSheetPresenter.finish(alert, code: NewWorkspaceSheet.addHostResponse)
        return
      }
      updateCheckbox()
    }

    /// 只有远端目标才能选择是否新开窗口；本地工作区总是新开一个窗口。
    private func updateCheckbox() {
      newWindowCheckbox.isEnabled = selectedChoice.isRemote
    }
  }

  /// 弹出表单。先取 ssh 别名（拿不到就不显示这一组），再展示；名称非法时提示后保留输入重新展示。
  static func present(in window: NSWindow?, directory: NamedWorkspaceDirectory) {
    Task { @MainActor in
      let aliases = await loadAliases()
      let fleet = MachineFleetModel.shared
      let entries = NewWorkspaceForm.menuEntries(
        machines: machines(fleet), hosts: SSHHostDirectory.shared.savedHosts, aliases: aliases)
      let controller = window?.contentViewController as? WorkspaceViewController
      var name = WorkspaceCodename.generate()
      var choice = defaultChoice(controller: controller, entries: entries)
      var openInNewWindow = false
      while true {
        let form = Form(name: name, entries: entries, selected: choice, openInNewWindow: openInNewWindow)
        let alert = NSAlert()
        alert.messageText = L("新建工作区")
        alert.informativeText = L("选择工作区所在的主机。本机工作区关闭窗口后仍会保留，可以用「切换工作区…」重新打开。")
        alert.accessoryView = form.makeAccessoryView()
        alert.addButton(withTitle: L("创建"))
        alert.addButton(withTitle: L("取消"))
        alert.window.initialFirstResponder = form.nameField
        form.alert = alert
        let response = WorkspaceSheetPresenter.run(alert, in: window)
        if response == addHostResponse {
          openHostSettings()
          return
        }
        guard response == .alertFirstButtonReturn else { return }
        name = form.nameField.stringValue
        choice = form.selectedChoice
        openInNewWindow = form.newWindowCheckbox.state == .on
        do {
          let submission = try NewWorkspaceForm.submission(
            choice: choice, name: name, openInNewWindow: openInNewWindow)
          await perform(submission, window: window, controller: controller, directory: directory)
          return
        } catch let error as NamedWorkspaceRegistryError {
          MachineSetupSheet.presentFailure(
            NamedWorkspaceDirectory.message(for: .registry(error)), in: window)
        } catch {
          MachineSetupSheet.presentFailure(WorkspaceSheetPresenter.describe(error), in: window)
          return
        }
      }
    }
  }

  /// 执行提交结果。远端失败（连接、事务）都以可读文案弹出。
  private static func perform(
    _ submission: NewWorkspaceSubmission, window: NSWindow?, controller: WorkspaceViewController?,
    directory: NamedWorkspaceDirectory
  ) async {
    switch submission {
    case .createLocal(let name):
      directory.createLocalWorkspace(named: name, errorWindow: window)
    case .createRemote(let machineID, let name, let inNewWindow):
      await createRemote(
        machineID: machineID, name: name, inNewWindow: inNewWindow, window: window,
        controller: controller, directory: directory)
    case .addMachineThenCreate(let prefill, let name, let inNewWindow):
      // 取消或失败时添加流程自己已经提示过，这里不再重复。
      guard let machineID = await MachineSetupFlow.presentAddMachine(prefill: prefill, in: window)
      else { return }
      await createRemote(
        machineID: machineID, name: name, inNewWindow: inNewWindow, window: window,
        controller: controller, directory: directory)
    case .openHostSettings:
      openHostSettings()
    }
  }

  /// 在当前窗口（或新开的窗口）建远端工作区；新工作区会被自动选中，并记一次使用。
  ///
  /// 没有当前工作区窗口（例如从空菜单栏触发）时同样新开窗口：远端工作区总得有个窗口显示。
  private static func createRemote(
    machineID: UUID, name: String, inNewWindow: Bool, window: NSWindow?,
    controller: WorkspaceViewController?, directory: NamedWorkspaceDirectory
  ) async {
    let target =
      inNewWindow || controller == nil
      ? WorkspaceWindowLauncher.openNewWindow(requester: controller?.model) : controller
    guard let target else {
      MachineSetupSheet.presentFailure(L("无法新建窗口。"), in: window)
      return
    }
    do {
      let workspaceID = try await target.remoteWorkspaces.createRemoteWorkspace(
        machineID: machineID, title: name)
      directory.markRemoteActive(machineID: machineID, workspaceID: workspaceID)
    } catch {
      MachineSetupSheet.presentFailure(
        L("无法创建远端工作区：\(WorkspaceSheetPresenter.describe(error))"), in: target.view.window ?? window)
    }
  }

  /// 打开设置并定位到「主机」分类。
  ///
  /// 按原始值取分类而不是直接写 `.hosts`：「主机」分类由设置包添加，合并前这里退回只打开设置窗口。
  private static func openHostSettings() {
    guard let delegate = NSApplication.shared.delegate as? AsterAppDelegate else { return }
    if let section = SettingsViewController.Section(rawValue: "主机") {
      delegate.showSettings(section: section)
    } else {
      delegate.showSettings(nil)
    }
  }

  /// 已添加的远端机器（带连接状态）。Local 不在其中，它是下拉第一项「本机」。
  private static func machines(_ fleet: MachineFleetModel) -> [NewWorkspaceMachine] {
    let states = Dictionary(fleet.rows.map { ($0.id, $0.state) }, uniquingKeysWith: { first, _ in first })
    return fleet.profiles.filter { $0.id != MachineProfile.localProfileID }.map {
      NewWorkspaceMachine(
        id: $0.id, label: $0.label, hostID: $0.hostID, sshTarget: $0.sshTarget, enabled: $0.enabled,
        state: states[$0.id] ?? .disconnected)
    }
  }

  /// 默认选中当前窗口所在的机器；本机或不在列表里时选「本机」。
  private static func defaultChoice(
    controller: WorkspaceViewController?, entries: [NewWorkspaceMenuEntry]
  ) -> NewWorkspaceHostChoice {
    guard let active = controller?.model.activeMachineID else { return .local }
    let isListed = entries.contains {
      if case .choice(.machine(let id), _) = $0 { return id == active }
      return false
    }
    return isListed ? .machine(active) : .local
  }

  /// 读取 `~/.ssh/config` 别名。broker 不可用（或尚未接入）时返回 nil，别名组整组不显示，
  /// 并记一条诊断，不打断新建流程。
  private static func loadAliases() async -> [String]? {
    do {
      return try await SSHBrokerSupervisor.shared.configListing().hosts.map(\.alias)
    } catch {
      DiagnosticsCenter.shared.record(
        "workspace.new_sheet_aliases_unavailable", level: .info, category: .workspace, error: error)
      return nil
    }
  }
}
