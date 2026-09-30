// Open Quickly「工作区」条目：各窗口的窗口内工作区、已关闭的旧窗口、各机器远端工作区的生成与排序，
// 以及主动作与右键菜单动作的执行。
import AppKit
import AsterCore

// MARK: - 纯数据

/// 切换器里一台远端机器的快照（来自 `MachineFleetModel.rows`）。
struct WorkspaceSwitcherMachine: Equatable {
  var id: UUID
  var label: String
  var enabled: Bool
  var state: SessionConnectionState
}

/// 切换器里的一个窗口内工作区。
struct WorkspaceSwitcherGroup: Equatable {
  var id: UUID
  var name: String
  /// 其中标签的标题；nil 表示窗口正显示远端机器，本机标签暂时收起，拿不到。
  var tabTitles: [String]?
}

/// 切换器里一个打开着的工作区窗口，以及它的窗口内工作区。
struct WorkspaceSwitcherWindow: Equatable {
  /// `NSWindow.windowNumber`，执行命令时据此找回窗口。
  var windowNumber: Int
  /// 多窗口时用来区分窗口的名称；只有一个窗口时为 nil，副标题里不出现。
  var label: String?
  /// 是否为发起切换器的窗口。
  var isCurrent: Bool
  /// 窗口是否正显示本机。显示远端时工作区仍在，但不能删除（`AppModel` 会拒绝）。
  var isLocalActive: Bool
  var selectedGroupID: UUID?
  /// 按窗口侧栏里的顺序。
  var groups: [WorkspaceSwitcherGroup]
}

/// 生成切换器条目需要的全部输入。纯值：测试直接构造，生产由 `live(...)` 从现有对象采集。
struct WorkspaceSwitcherSnapshot {
  /// 打开着的工作区窗口，按窗口前后顺序（当前窗口由 `isCurrent` 标出，排序时提到最前）。
  var windows: [WorkspaceSwitcherWindow] = []
  /// 本地窗口注册表条目。只有已关闭的条目会生成「重新打开窗口」行；打开着的窗口
  /// 已经按其中的窗口内工作区分别列出，不再单独占一行。
  var localWorkspaces: [NamedWorkspace] = []
  /// 远端工作区最近使用时间，键见 `NamedWorkspaceRegistry.remoteActivityKey`。
  var remoteActivity: [String: Date] = [:]
  /// 全部远端机器（不含 Local）。
  var machines: [WorkspaceSwitcherMachine] = []
  /// 各机器缓存投影里的远端工作区；没有缓存的机器缺省或为空数组。
  var remoteWorkspaces: [UUID: [RemoteWorkspaceSummary]] = [:]
}

/// 切换器条目能触发的动作。执行由 `WorkspaceSwitcherActions` 负责，这里只描述「做什么」，便于测试。
enum WorkspaceSwitcherCommand: Equatable {
  /// 置前窗口并切到其中的窗口内工作区（窗口正显示远端机器时先切回本机）。
  case selectGroup(windowNumber: Int, groupID: UUID)
  case renameGroup(windowNumber: Int, groupID: UUID)
  /// 删除窗口内工作区（先确认，会关闭其中全部标签）。
  case deleteGroup(windowNumber: Int, groupID: UUID)
  /// 打开本地注册表条目：已打开时置前窗口，否则开窗恢复。
  case openLocal(UUID)
  case renameLocal(UUID, currentName: String)
  /// 删除已关闭的本地工作区（连同快照）。
  case removeLocal(UUID, name: String)
  /// 在当前窗口选中远端工作区（必要时先切到这台机器）。
  case selectRemote(machineID: UUID, workspaceID: String)
  /// 新开一个窗口，切到这台机器并选中该工作区。
  case openRemoteInNewWindow(machineID: UUID, workspaceID: String)
  case renameRemote(machineID: UUID, workspaceID: String, currentTitle: String)
  /// 关闭远端工作区（先确认，会结束其中全部远端进程）。
  case closeRemote(machineID: UUID, summary: RemoteWorkspaceSummary)
  /// 把当前窗口切到这台机器；机器已禁用时先启用。
  case connectMachine(UUID)
  /// 启用（连接）或禁用（断开）这台机器。
  case setMachineEnabled(UUID, Bool)
}

/// 右键 / ⌘K 菜单里的一项。
struct WorkspaceSwitcherMenuItem: Equatable {
  var title: String
  var command: WorkspaceSwitcherCommand
}

/// 一条切换器条目：Open Quickly 行的内容、状态点、主动作与菜单。
struct WorkspaceSwitcherEntry: Equatable {
  var item: OpenQuicklyItem
  var symbol: String
  var badge: String
  /// 条目对应的终端是否就在某个打开的窗口里（窗口内工作区恒为 true）；其它条目为 false。
  var isOpen: Bool
  /// 状态点对应的连接状态；nil 表示不画状态点（本地条目）。
  var connectionState: SessionConnectionState?
  var primaryTitle: String
  var primary: WorkspaceSwitcherCommand
  var menu: [WorkspaceSwitcherMenuItem]
}

/// 切换器条目生成器。只做纯计算，不读任何全局状态。
@MainActor
enum WorkspaceSwitcherCatalog {
  /// 条目 ID 前缀；四类条目互不重叠，也不会和 Open Quickly 其它来源冲突。
  static let groupPrefix = "workspace:group:"
  static let localPrefix = "workspace:local:"
  static let remotePrefix = "workspace:remote:"
  static let connectPrefix = "workspace:connect:"

  /// 窗口内工作区的分数基数，远大于任何以秒计的时间戳。
  static let groupScoreBase = Date.distantFuture.timeIntervalSince1970

  /// 生成全部条目：窗口内工作区在前，其余最近使用优先。
  ///
  /// 排序都写进 `item.score`：`OpenQuicklyIndex` 在同一匹配质量内按 score 降序排，空查询时
  /// 就是这里的顺序，有查询时仍是匹配质量优先。
  /// - 窗口内工作区不记使用时间，用简单可预期的规则：当前窗口的当前工作区第一，然后是
  ///   当前窗口的其余工作区、其它窗口的工作区，都按侧栏列表顺序。分数从 `groupScoreBase`
  ///   逐个递减，保证排在所有带时间戳的条目前面。
  /// - 已关闭的旧窗口与远端工作区按最近使用时间；没有使用记录的远端工作区记 0，
  ///   「连接到…」行记 -1，永远排在已知工作区后面。
  static func entries(from snapshot: WorkspaceSwitcherSnapshot) -> [WorkspaceSwitcherEntry] {
    var result = groupEntries(snapshot.windows)
    result += snapshot.localWorkspaces.filter { !$0.isOpen }.map { localEntry($0) }
    for machine in snapshot.machines {
      // 已禁用的机器不读缓存：它的投影不再更新，列出来的工作区可能早已不存在。
      let summaries = machine.enabled ? snapshot.remoteWorkspaces[machine.id] ?? [] : []
      guard !summaries.isEmpty else {
        result.append(connectEntry(machine))
        continue
      }
      for summary in summaries {
        let key = NamedWorkspaceRegistry.remoteActivityKey(
          machineID: machine.id, workspaceID: summary.workspaceID)
        result.append(remoteEntry(summary, machine: machine, lastActive: snapshot.remoteActivity[key]))
      }
    }
    return result.sorted { lhs, rhs in
      if lhs.item.score != rhs.item.score { return lhs.item.score > rhs.item.score }
      if lhs.item.title != rhs.item.title {
        return lhs.item.title.localizedStandardCompare(rhs.item.title) == .orderedAscending
      }
      return lhs.item.id < rhs.item.id
    }
  }

  /// 行的副标题：机器名 + 全部标签标题。按标签名、机器名输入都能搜到这个工作区。
  static func detail(machine: String, tabTitles: [String]) -> String {
    let tabs = tabTitles.filter { !$0.isEmpty }
    return tabs.isEmpty ? machine : "\(machine) · \(tabs.joined(separator: ", "))"
  }

  /// 各窗口的窗口内工作区条目，按 `entries` 里说明的顺序排好并写入递减的分数。
  private static func groupEntries(_ windows: [WorkspaceSwitcherWindow]) -> [WorkspaceSwitcherEntry] {
    let ordered = windows.filter(\.isCurrent) + windows.filter { !$0.isCurrent }
    var result: [WorkspaceSwitcherEntry] = []
    for window in ordered {
      var groups = window.groups
      // 只把当前窗口正在看的工作区提到最前；其它窗口的选中项对用户不是「当前」。
      if window.isCurrent, window.isLocalActive,
        let index = groups.firstIndex(where: { $0.id == window.selectedGroupID })
      {
        groups.insert(groups.remove(at: index), at: 0)
      }
      for group in groups {
        result.append(
          groupEntry(group, in: window, score: groupScoreBase - Double(result.count)))
      }
    }
    return result
  }

  /// 窗口内工作区的副标题：本机 ·（多窗口时）窗口名 · 标签数 · 标签标题。
  /// 按标签标题、窗口名输入都能搜到这个工作区。
  static func groupDetail(windowLabel: String?, tabTitles: [String]?) -> String {
    var parts = [L("本机")]
    if let windowLabel { parts.append(windowLabel) }
    if let tabTitles {
      parts.append(L("\(String(tabTitles.count)) 个标签"))
      let titles = tabTitles.filter { !$0.isEmpty }
      if !titles.isEmpty { parts.append(titles.joined(separator: ", ")) }
    }
    return parts.joined(separator: " · ")
  }

  /// 窗口内工作区条目。只剩一个工作区、或窗口正显示远端时不提供删除。
  private static func groupEntry(
    _ group: WorkspaceSwitcherGroup, in window: WorkspaceSwitcherWindow, score: Double
  ) -> WorkspaceSwitcherEntry {
    let isCurrent = window.isCurrent && window.isLocalActive && window.selectedGroupID == group.id
    var menu = [
      WorkspaceSwitcherMenuItem(
        title: L("重命名…"),
        command: .renameGroup(windowNumber: window.windowNumber, groupID: group.id))
    ]
    if window.isLocalActive, window.groups.count > 1 {
      menu.append(
        WorkspaceSwitcherMenuItem(
          title: L("删除…"),
          command: .deleteGroup(windowNumber: window.windowNumber, groupID: group.id)))
    }
    return WorkspaceSwitcherEntry(
      item: OpenQuicklyItem(
        id: "\(groupPrefix)\(window.windowNumber):\(group.id.uuidString)", kind: .workspace,
        title: group.name,
        detail: groupDetail(windowLabel: window.label, tabTitles: group.tabTitles), score: score),
      symbol: "square.stack",
      badge: isCurrent ? L("当前") : L("本机"),
      isOpen: true,
      connectionState: nil,
      primaryTitle: L("切换到工作区"),
      primary: .selectGroup(windowNumber: window.windowNumber, groupID: group.id),
      menu: menu)
  }

  /// 已关闭的旧窗口条目（旧版「本机工作区 = 一个窗口」留下的，或关掉的主窗口）。
  /// 点它重新打开窗口，恢复布局和目录；非主窗口可以删除。保留它们是为了老用户的数据不丢。
  private static func localEntry(_ workspace: NamedWorkspace) -> WorkspaceSwitcherEntry {
    var menu = [
      WorkspaceSwitcherMenuItem(
        title: L("重命名…"), command: .renameLocal(workspace.id, currentName: workspace.name)),
      WorkspaceSwitcherMenuItem(title: L("在新窗口打开"), command: .openLocal(workspace.id)),
    ]
    if !workspace.isOpen, workspace.storage != .standard {
      menu.append(
        WorkspaceSwitcherMenuItem(
          title: L("删除…"), command: .removeLocal(workspace.id, name: workspace.name)))
    }
    return WorkspaceSwitcherEntry(
      item: OpenQuicklyItem(
        id: localPrefix + workspace.id.uuidString, kind: .workspace, title: workspace.name,
        detail: detail(machine: L("本机"), tabTitles: []),
        score: workspace.lastActiveAt.timeIntervalSince1970, timestamp: workspace.lastActiveAt),
      symbol: workspace.isOpen ? "macwindow" : "macwindow.badge.plus",
      badge: workspace.isOpen ? L("已打开") : L("本机"),
      isOpen: workspace.isOpen,
      connectionState: nil,
      primaryTitle: workspace.isOpen ? L("切换到窗口") : L("打开工作区"),
      primary: .openLocal(workspace.id),
      menu: menu)
  }

  /// 远端工作区条目。
  private static func remoteEntry(
    _ summary: RemoteWorkspaceSummary, machine: WorkspaceSwitcherMachine, lastActive: Date?
  ) -> WorkspaceSwitcherEntry {
    let machineID = machine.id
    let workspaceID = summary.workspaceID
    return WorkspaceSwitcherEntry(
      item: OpenQuicklyItem(
        id: "\(remotePrefix)\(machineID.uuidString):\(workspaceID)", kind: .workspace,
        title: summary.title, detail: detail(machine: machine.label, tabTitles: summary.tabTitles),
        score: lastActive?.timeIntervalSince1970 ?? 0, timestamp: lastActive),
      symbol: "server.rack",
      badge: L("远端"),
      isOpen: false,
      connectionState: machine.state,
      primaryTitle: L("切换到工作区"),
      primary: .selectRemote(machineID: machineID, workspaceID: workspaceID),
      menu: [
        WorkspaceSwitcherMenuItem(
          title: L("重命名…"),
          command: .renameRemote(
            machineID: machineID, workspaceID: workspaceID, currentTitle: summary.title)),
        WorkspaceSwitcherMenuItem(
          title: L("在新窗口打开"),
          command: .openRemoteInNewWindow(machineID: machineID, workspaceID: workspaceID)),
        WorkspaceSwitcherMenuItem(
          title: L("关闭工作区…"), command: .closeRemote(machineID: machineID, summary: summary)),
        WorkspaceSwitcherMenuItem(title: L("断开"), command: .setMachineEnabled(machineID, false)),
      ])
  }

  /// 没有缓存投影（离线、没访问过或已禁用）的机器只占一行「连接到 <机器名>…」。
  private static func connectEntry(_ machine: WorkspaceSwitcherMachine) -> WorkspaceSwitcherEntry {
    let toggle =
      machine.enabled
      ? WorkspaceSwitcherMenuItem(title: L("断开"), command: .setMachineEnabled(machine.id, false))
      : WorkspaceSwitcherMenuItem(title: L("连接"), command: .setMachineEnabled(machine.id, true))
    return WorkspaceSwitcherEntry(
      item: OpenQuicklyItem(
        id: connectPrefix + machine.id.uuidString, kind: .workspace,
        title: L("连接到 \(machine.label)…"),
        detail: machine.enabled
          ? "\(machine.label) · \(MachineRowButton.stateText(machine.state))"
          : "\(machine.label) · \(L("已断开"))",
        score: -1),
      symbol: "bolt.horizontal",
      badge: L("机器"),
      isOpen: false,
      connectionState: machine.state,
      primaryTitle: L("连接"),
      primary: .connectMachine(machine.id),
      menu: [toggle])
  }
}

// MARK: - 采集现场状态

extension WorkspaceSwitcherSnapshot {
  /// 从各工作区窗口、本地目录、机器编排与各窗口的远端协调器采集快照。
  ///
  /// 远端列表只读缓存（`remoteWorkspaces(machineID:)` 不发网络请求）：先看当前窗口，
  /// 再看其它窗口已建出的协调器，任意一个窗口访问过这台机器，切换器就能列出它的工作区。
  /// 只读 `loadedRemoteWorkspaces`，不会为了列条目在别的窗口里现造协调器。
  @MainActor
  static func live(
    controller: WorkspaceViewController?, directory: NamedWorkspaceDirectory?,
    fleet: MachineFleetModel
  ) -> WorkspaceSwitcherSnapshot {
    var windows = (NSApplication.shared.delegate as? AsterAppDelegate)?.workspaceWindows ?? []
    // 测试与嵌入宿主没有 AppDelegate：至少列出发起切换器的这个窗口。
    if let current = controller?.view.window, let model = controller?.model,
      !windows.contains(where: { $0.window === current })
    {
      windows.insert((current, model), at: 0)
    }
    let machines = fleet.rows.filter { !$0.isLocal }.map {
      WorkspaceSwitcherMachine(id: $0.id, label: $0.label, enabled: $0.enabled, state: $0.state)
    }
    let coordinators =
      [controller?.loadedRemoteWorkspaces]
      + windows.map { ($0.window.contentViewController as? WorkspaceViewController)?.loadedRemoteWorkspaces }
    var remote: [UUID: [RemoteWorkspaceSummary]] = [:]
    for machine in machines where machine.enabled {
      remote[machine.id] =
        coordinators.lazy.compactMap { $0?.remoteWorkspaces(machineID: machine.id) }
        .first { !$0.isEmpty } ?? []
    }
    let currentWindow = controller?.view.window
    return WorkspaceSwitcherSnapshot(
      windows: windows.enumerated().map { index, entry in
        switcherWindow(
          entry.window, model: entry.model, index: index, showLabel: windows.count > 1,
          isCurrent: entry.window === currentWindow, directory: directory)
      },
      localWorkspaces: directory?.workspaces ?? [],
      remoteActivity: directory?.remoteActivity ?? [:], machines: machines,
      remoteWorkspaces: remote)
  }

  /// 一个窗口的切换器快照。
  ///
  /// 窗口名优先用注册表里这个窗口的名字（旧版改过名的窗口名字有含义，而且不随窗口前后顺序变），
  /// 没登记时退回「窗口 N」。窗口正显示远端机器时 `tabs` 是远端标签，不拿来当本机工作区的搜索词。
  @MainActor
  private static func switcherWindow(
    _ window: NSWindow, model: AppModel, index: Int, showLabel: Bool, isCurrent: Bool,
    directory: NamedWorkspaceDirectory?
  ) -> WorkspaceSwitcherWindow {
    let registered = directory?.workspaceID(for: window).flatMap { directory?.workspace($0)?.name }
    let isLocal = model.isLocalMachineActive
    return WorkspaceSwitcherWindow(
      windowNumber: window.windowNumber,
      label: showLabel ? registered ?? L("窗口 \(String(index + 1))") : nil,
      isCurrent: isCurrent,
      isLocalActive: isLocal,
      selectedGroupID: model.selectedWorkspaceGroupID,
      groups: model.workspaceGroups.map { group in
        WorkspaceSwitcherGroup(
          id: group.id, name: group.name,
          tabTitles: isLocal
            ? model.tabs.filter { $0.workspaceGroupID == group.id }.map(\.title) : nil)
      })
  }
}

// MARK: - 动作执行

/// 执行切换器命令。持有发起切换器的窗口控制器（弱引用），远端操作都落在这个窗口的协调器上。
@MainActor
final class WorkspaceSwitcherActions {
  private weak var controller: WorkspaceViewController?
  private let directory: NamedWorkspaceDirectory?
  private let fleet: MachineFleetModel

  /// `directory` 为 nil 时（测试宿主没有 AppDelegate）本地命令静默不执行。
  init(controller: WorkspaceViewController?, directory: NamedWorkspaceDirectory?, fleet: MachineFleetModel) {
    self.controller = controller
    self.directory = directory
    self.fleet = fleet
  }

  /// 生产环境的目录：AppDelegate 持有的那一个（即 `NamedWorkspaceDirectory.shared`）。
  /// 没有 AppDelegate 的测试宿主返回 nil，切换器不去读写用户真实注册表。
  static var appDirectory: NamedWorkspaceDirectory? {
    (NSApplication.shared.delegate as? AsterAppDelegate)?.workspaceDirectory
  }

  private var window: NSWindow? { controller?.view.window }

  /// 下一轮主循环再执行：命令可能要弹 sheet，而调用点常在菜单跟踪或浮层关闭的过程中。
  func schedule(_ command: WorkspaceSwitcherCommand) {
    DispatchQueue.main.async { [self] in perform(command) }
  }

  /// 立即执行命令。所有失败都以可读文案弹出，不静默吞掉。
  func perform(_ command: WorkspaceSwitcherCommand) {
    switch command {
    case .selectGroup(let windowNumber, let groupID):
      guard let target = WorkspaceGroupNavigator.controller(windowNumber: windowNumber) else { return }
      Task { @MainActor in await WorkspaceGroupNavigator.select(groupID, in: target) }
    case .renameGroup(let windowNumber, let groupID):
      // 目标可能是别的窗口：先置前，对话框才不会弹在一个看不见的窗口上。
      guard let target = WorkspaceGroupNavigator.controller(windowNumber: windowNumber) else { return }
      WorkspaceGroupNavigator.bringToFront(target)
      WorkspaceGroupActions.promptRename(groupID, in: target.model, window: target.view.window)
    case .deleteGroup(let windowNumber, let groupID):
      guard let target = WorkspaceGroupNavigator.controller(windowNumber: windowNumber) else { return }
      WorkspaceGroupNavigator.bringToFront(target)
      WorkspaceGroupActions.confirmAndDelete(groupID, in: target.model, window: target.view.window)
    case .openLocal(let id):
      directory?.open(id)
    case .renameLocal(let id, let currentName):
      guard let directory,
        let name = WorkspaceSheetPresenter.promptForName(
          title: L("重命名工作区"), message: L("重命名后，这个工作区会在关闭窗口后保留。"),
          current: currentName, confirm: L("保存"), in: window)
      else { return }
      do { try directory.rename(id, to: name) } catch { presentLocalError(error) }
    case .removeLocal(let id, let name):
      guard let directory, confirmRemoval(name: name) else { return }
      do { try directory.remove(id) } catch { presentLocalError(error) }
    case .selectRemote(let machineID, let workspaceID):
      guard let coordinator = controller?.remoteWorkspaces else { return }
      select(machineID: machineID, workspaceID: workspaceID, on: coordinator)
    case .openRemoteInNewWindow(let machineID, let workspaceID):
      guard let target = WorkspaceWindowLauncher.openNewWindow(requester: controller?.model) else {
        MachineSetupSheet.presentFailure(L("无法新建窗口。"), in: window)
        return
      }
      select(machineID: machineID, workspaceID: workspaceID, on: target.remoteWorkspaces)
    case .renameRemote(let machineID, let workspaceID, let currentTitle):
      guard let coordinator = controller?.remoteWorkspaces,
        let title = WorkspaceSheetPresenter.promptForName(
          title: L("重命名远端工作区"), message: L("只改名称，不影响其中的终端。"),
          current: currentTitle, confirm: L("保存"), in: window)
      else { return }
      run {
        try await coordinator.renameRemoteWorkspace(
          machineID: machineID, workspaceID: workspaceID, title: title)
      }
    case .closeRemote(let machineID, let summary):
      guard let coordinator = controller?.remoteWorkspaces,
        RemoteWorkspaceCoordinator.confirmClose(summary: summary, in: window)
      else { return }
      run {
        try await coordinator.closeRemoteWorkspace(machineID: machineID, workspaceID: summary.workspaceID)
      }
    case .connectMachine(let id):
      if fleet.rows.first(where: { $0.id == id })?.enabled == false,
        let failure = fleet.setEnabled(id, true)
      {
        MachineSetupSheet.presentFailure(failure, in: window)
        return
      }
      controller?.presentMachineSelection(id)
    case .setMachineEnabled(let id, let enabled):
      if let failure = fleet.setEnabled(id, enabled) {
        MachineSetupSheet.presentFailure(failure, in: window)
        return
      }
      controller?.scheduleRefresh()
    }
  }

  /// 记一次远端使用（切换器排序），再在指定协调器所在窗口选中该工作区。
  private func select(machineID: UUID, workspaceID: String, on coordinator: RemoteWorkspaceCoordinator) {
    directory?.markRemoteActive(machineID: machineID, workspaceID: workspaceID)
    run {
      try await coordinator.selectRemoteWorkspace(machineID: machineID, workspaceID: workspaceID)
    }
  }

  /// 跑一个远端事务，失败时把原因弹到发起窗口上。
  private func run(_ body: @escaping @MainActor () async throws -> Void) {
    let window = window
    Task { @MainActor in
      do {
        try await body()
      } catch {
        MachineSetupSheet.presentFailure(WorkspaceSheetPresenter.describe(error), in: window)
      }
    }
  }

  /// 删除本地工作区前确认：删除会连同快照一起清掉，不能撤销。默认按钮是「取消」。
  private func confirmRemoval(name: String) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = L("删除工作区「\(name)」？")
    alert.informativeText = L("工作区保存的标签与布局会一起删除，此操作不能撤销。")
    alert.addButton(withTitle: L("取消"))
    alert.addButton(withTitle: L("删除")).hasDestructiveAction = true
    return WorkspaceSheetPresenter.run(alert, in: window) == .alertSecondButtonReturn
  }

  /// 本地目录错误走目录自己的文案；其它错误按通用方式描述。
  private func presentLocalError(_ error: any Error) {
    if let error = error as? NamedWorkspaceDirectoryError {
      NamedWorkspaceDirectory.presentError(error, in: window)
    } else {
      MachineSetupSheet.presentFailure(WorkspaceSheetPresenter.describe(error), in: window)
    }
  }
}

// MARK: - 共享的窗口与对话框工具

/// 新开普通工作区窗口并拿到它的控制器。
@MainActor
enum WorkspaceWindowLauncher {
  /// 通过模型已有的「新建窗口」回调开窗，再按开窗前后的窗口集合差找出新窗口。
  ///
  /// 不给 AppDelegate 加新入口：开窗仍走同一条 `createWorkspaceWindow` 事务（登记注册表、
  /// 上限检查、失败回滚），这里只是事后认领结果。开窗是同步的，返回时新窗口已在列表里。
  static func openNewWindow(requester: AppModel?) -> WorkspaceViewController? {
    guard let delegate = NSApplication.shared.delegate as? AsterAppDelegate else { return nil }
    let before = Set(delegate.workspaceWindows.map { ObjectIdentifier($0.window) })
    let model = requester ?? delegate.model
    guard model.onRequestNewWindow?(nil) == true else { return nil }
    let created = delegate.workspaceWindows.first { !before.contains(ObjectIdentifier($0.window)) }
    return created?.window.contentViewController as? WorkspaceViewController
  }
}

/// 切换器与新建表单共用的对话框工具。
@MainActor
enum WorkspaceSheetPresenter {
  /// 有窗口时以 sheet 同步等待结果，没有窗口时退回应用级模态（与 `MachineSetupSheet` 一致）。
  static func run(_ alert: NSAlert, in window: NSWindow?) -> NSApplication.ModalResponse {
    guard let window, window.isVisible else { return alert.runModal() }
    alert.beginSheetModal(for: window) { response in NSApp.stopModal(withCode: response) }
    return NSApp.runModal(for: alert.window)
  }

  /// 结束一个正在展示的对话框（sheet 或应用级模态），让 `run` 返回 `code`。
  static func finish(_ alert: NSAlert, code: NSApplication.ModalResponse) {
    if let parent = alert.window.sheetParent {
      parent.endSheet(alert.window, returnCode: code)
    } else {
      NSApp.stopModal(withCode: code)
    }
  }

  /// 单个名称输入框的对话框；取消返回 nil。名称校验留给调用方的领域方法。
  static func promptForName(
    title: String, message: String, current: String, confirm: String, in window: NSWindow?
  ) -> String? {
    let field = makeNameField(current)
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = message
    alert.accessoryView = field
    alert.addButton(withTitle: confirm)
    alert.addButton(withTitle: L("取消"))
    alert.window.initialFirstResponder = field
    guard run(alert, in: window) == .alertFirstButtonReturn else { return nil }
    return field.stringValue
  }

  /// 名称输入框，宽度与现有重命名对话框一致。
  static func makeNameField(_ value: String) -> NSTextField {
    let field = NSTextField(string: value)
    field.placeholderString = L("工作区名称")
    field.identifier = NSUserInterfaceItemIdentifier("workspace-name-field")
    field.frame = NSRect(x: 0, y: 0, width: 300, height: 24)
    return field
  }

  /// 把远端或设置事务的错误翻译成一句用户能读懂的话。
  static func describe(_ error: any Error) -> String {
    if let operation = error as? RemoteWorkspaceOperationError, let text = operation.errorDescription {
      return text
    }
    if let directory = error as? NamedWorkspaceDirectoryError {
      return NamedWorkspaceDirectory.message(for: directory)
    }
    return RemoteSetupDescription.text(for: error)
  }
}
