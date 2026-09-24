// 远端机器的命名工作区：选中、列表、新建、改名、关闭，以及选中项的按机器持久化。
import AppKit
import AsterCore
import Foundation

/// 命名工作区操作的失败原因。文案面向用户，界面直接显示。
enum RemoteWorkspaceOperationError: LocalizedError, Equatable {
  /// 机器无法切换（不存在、已禁用等），附带侧栏模型给出的原因。
  case machineUnavailable(String)
  /// 机器没有可用的远端运行时，或握手失败。
  case notConnected
  /// 目标工作区不在服务端最新快照里（可能已被其它客户端关闭）。
  case workspaceNotFound(String)
  /// 工作区名称去掉首尾空白后为空。
  case emptyTitle

  var errorDescription: String? {
    switch self {
    case .machineUnavailable(let reason): reason
    case .notConnected: L("机器未配置远端运行时，无法读取共享工作区。")
    case .workspaceNotFound: L("远端工作区已不存在，可能已被其它客户端关闭。")
    case .emptyTitle: L("工作区名称不能为空。")
    }
  }
}

/// 远端选中工作区的持久化：按机器记住，切回这台机器或重启 App 后恢复。
///
/// 只存在本机 UserDefaults：选中项属于客户端（§4.2「客户端互不抢选中项」），
/// 绝不写进服务端结构。key 带机器 ID，多台机器互不覆盖。
struct RemoteWorkspaceSelectionStore {
  /// key 前缀；完整 key 为前缀 + 小写机器 UUID。
  static let keyPrefix = "aster.remote.selectedWorkspace."

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  /// 某台机器的 UserDefaults key。
  static func key(forMachine machineProfileID: UUID) -> String {
    keyPrefix + machineProfileID.uuidString.lowercased()
  }

  /// 读取某台机器上次选中的工作区 ID；从未选过返回 nil。
  func selectedWorkspaceID(forMachine machineProfileID: UUID) -> String? {
    defaults.string(forKey: Self.key(forMachine: machineProfileID))
  }

  /// 写入（nil 表示清除）某台机器的选中工作区。
  func save(_ workspaceID: String?, forMachine machineProfileID: UUID) {
    let key = Self.key(forMachine: machineProfileID)
    if let workspaceID {
      defaults.set(workspaceID, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }
}

extension RemoteWorkspaceCoordinator {
  /// 选中工作区变化。object 是协调器；userInfo：`machineID`（UUID）、`workspaceID`（String，可缺省）。
  /// 侧栏胶囊与切换器据此刷新。
  static let selectedWorkspaceDidChange = Notification.Name(
    "aster.remote.selectedWorkspaceDidChange")
  /// 某台机器的工作区列表（名称、标签数、终端数、选中项）变化。userInfo：`machineID`。
  static let remoteWorkspacesDidChange = Notification.Name(
    "aster.remote.workspacesDidChange")

  // MARK: - 查询（只读缓存，不发网络请求）

  /// 某台机器全部远端工作区的摘要，来自最近一次缓存的投影。
  ///
  /// 从未连接过或尚无快照时返回空数组；调用方不应把它当作「远端确实没有工作区」。
  func remoteWorkspaces(machineID: UUID) -> [RemoteWorkspaceSummary] {
    guard let workspace = workspaces[machineID], let projection = workspace.controller.projection
    else { return [] }
    return projection.summaries(
      selectedWorkspaceID: projection.resolvedWorkspaceID(preferred: workspace.selectedWorkspaceID))
  }

  /// 某台机器当前选中工作区的名称；给侧栏胶囊显示「机器 · 工作区名」。
  func selectedWorkspaceTitle(machineID: UUID) -> String? {
    workspaces[machineID]?.selectedRemoteWorkspace?.title
  }

  // MARK: - 选中

  /// 选中某台机器上的一个工作区，并显示它的标签。
  ///
  /// 当前窗口不在这台机器上时先切过去（与侧栏选机器同一条路径：先取消旧机器画面订阅，
  /// 再换标签集合，最后取快照）。缓存投影里已有该工作区时直接用缓存渲染，切换即时；
  /// 缓存里没有（例如刚新建）才重新取快照确认。
  /// - Throws: `RemoteWorkspaceOperationError`。
  func selectRemoteWorkspace(machineID: UUID, workspaceID: String) async throws {
    guard !isStopped, let model else { return }
    if let workspace = workspaces[machineID], let cached = workspace.controller.projection,
      cached.workspace(withID: workspaceID) == nil
    {
      // 缓存可能落后：先确认一次服务端最新结构，仍然没有才报错。
      _ = await refresh(machineProfileID: machineID)
      guard workspace.controller.projection?.workspace(withID: workspaceID) != nil else {
        throw RemoteWorkspaceOperationError.workspaceNotFound(workspaceID)
      }
    }
    if let workspace = workspaces[machineID] {
      setSelection(workspaceID, for: workspace)
    } else {
      // 还没握手过：先记下偏好，握手建出投影状态时会读回它。
      selectionStore.save(workspaceID, forMachine: machineID)
    }
    guard model.activeMachineID == machineID else {
      if let failure = machineSelector(machineID) {
        throw RemoteWorkspaceOperationError.machineUnavailable(failure)
      }
      await activate(machineProfileID: machineID)
      return
    }
    guard let workspace = workspaces[machineID] else {
      _ = await refresh(machineProfileID: machineID)
      return
    }
    if let cached = workspace.controller.projection {
      apply(projection: cached, to: workspace)
      onDidRefresh?()
    } else {
      _ = await refresh(machineProfileID: machineID)
    }
  }

  // MARK: - 新建 / 改名 / 关闭

  /// 新建一个远端工作区（服务端同时建首个标签与 Shell），成功后自动选中并显示它。
  ///
  /// 首个终端落在远端 `$HOME`：新工作区没有任何服务端 cwd 可继承，规则沿用
  /// `ManagedTerminalLaunchSpec`（cwd 传 POSIX 保证存在的 `/`，由远端 Shell 自己 `cd "$HOME"`）。
  /// - Returns: 新工作区的 ID。
  func createRemoteWorkspace(machineID: UUID, title: String) async throws -> String {
    let trimmed = try Self.validatedTitle(title)
    guard let workspace = await ensureWorkspace(machineProfileID: machineID) else {
      throw RemoteWorkspaceOperationError.notConnected
    }
    let terminal = RemoteTerminalSpec(
      cwd: ManagedTerminalLaunchSpec.remoteRootDirectory,
      argv: ManagedTerminalLaunchSpec.remoteArgv(landsInHome: true))
    let created = try await performStructureChange(on: workspace) { controller in
      try await controller.createWorkspace(title: trimmed, terminal: terminal)
    }
    // 先记下选中项，随后的快照直接渲染新工作区；缓存落后一拍，由选中流程重新取快照确认
    // （机器不是当前活动机器时顺带切过去）。
    setSelection(created.workspaceID, for: workspace)
    try await selectRemoteWorkspace(machineID: machineID, workspaceID: created.workspaceID)
    return created.workspaceID
  }

  /// 重命名远端工作区。只改标题，不动任何终端。
  func renameRemoteWorkspace(machineID: UUID, workspaceID: String, title: String) async throws {
    let trimmed = try Self.validatedTitle(title)
    guard let workspace = await ensureWorkspace(machineProfileID: machineID) else {
      throw RemoteWorkspaceOperationError.notConnected
    }
    _ = try await performStructureChange(on: workspace) { controller in
      try await controller.updateWorkspace(workspaceID: workspaceID, title: trimmed)
    }
    _ = await refresh(machineProfileID: machineID)
  }

  /// 关闭远端工作区：**结束其中全部远端进程**，不可撤销。
  ///
  /// 调用方负责先用 `confirmClose(summary:in:)` 取得用户确认。关闭的是选中项时，
  /// 随后的快照会让选中项退回第一个工作区并发出 `selectedWorkspaceDidChange`。
  func closeRemoteWorkspace(machineID: UUID, workspaceID: String) async throws {
    guard let workspace = await ensureWorkspace(machineProfileID: machineID) else {
      throw RemoteWorkspaceOperationError.notConnected
    }
    _ = try await performStructureChange(on: workspace) { controller in
      try await controller.closeWorkspace(workspaceID: workspaceID)
    }
    _ = await refresh(machineProfileID: machineID)
  }

  /// 关闭远端工作区前的确认框：列出将被结束的终端数；默认按钮是「取消」。
  ///
  /// 「分离」与「关闭」必须分开命名（§4.2）：这里是关闭，文案明确说会结束进程。
  static func confirmClose(summary: RemoteWorkspaceSummary, in window: NSWindow?) -> Bool {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = L("关闭远端工作区「\(summary.title)」？")
    alert.informativeText = L(
      "将结束其中 \(String(summary.terminalCount)) 个远端终端的进程（共 \(String(summary.tabCount)) 个标签），此操作不能撤销。只想暂时不看它，请切换到别的工作区。"
    )
    // 第一个按钮是默认按钮（回车触发）：误按回车只会取消，不会结束进程。
    alert.addButton(withTitle: L("取消"))
    let close = alert.addButton(withTitle: L("关闭工作区"))
    close.hasDestructiveAction = true
    return runModal(alert, in: window) == .alertSecondButtonReturn
  }

  // MARK: - 选中项内部实现

  /// 记下选中项并按机器持久化。只改状态不发通知：通知在 `apply` 渲染完成后统一发出，
  /// 保证监听方收到时标签栏已经是新工作区的标签。
  func setSelection(_ workspaceID: String?, for workspace: RemoteMachineWorkspace) {
    guard workspace.selectedWorkspaceID != workspaceID else { return }
    workspace.selectedWorkspaceID = workspaceID
    selectionStore.save(workspaceID, forMachine: workspace.machineProfileID)
  }

  /// 按新投影解析选中项：原选中项消失（被其它客户端关闭）时退回第一个。
  func reconcileSelection(
    with projection: ProjectedRemoteSession, for workspace: RemoteMachineWorkspace
  ) -> String? {
    let resolved = projection.resolvedWorkspaceID(preferred: workspace.selectedWorkspaceID)
    setSelection(resolved, for: workspace)
    return resolved
  }

  /// 渲染完成后通知界面：选中项变了发 `selectedWorkspaceDidChange`，
  /// 列表（名称、数量、选中项）变了发 `remoteWorkspacesDidChange`。
  ///
  /// 以「上次通知出去的摘要」为基准比较，而不是在每个改选中项的地方各发一次：
  /// 显式选中、新建后自动选中、被其它客户端关闭后的回退走的都是这一个出口。
  func publishChanges(_ projection: ProjectedRemoteSession, for workspace: RemoteMachineWorkspace) {
    let summaries = projection.summaries(selectedWorkspaceID: workspace.selectedWorkspaceID)
    guard summaries != workspace.lastSummaries else { return }
    let previousSelection = workspace.lastSummaries.first(where: \.isSelected)?.workspaceID
    workspace.lastSummaries = summaries
    let machineID = workspace.machineProfileID
    if previousSelection != workspace.selectedWorkspaceID {
      var userInfo: [String: Any] = ["machineID": machineID]
      if let selected = workspace.selectedWorkspaceID { userInfo["workspaceID"] = selected }
      NotificationCenter.default.post(
        name: Self.selectedWorkspaceDidChange, object: self, userInfo: userInfo)
    }
    NotificationCenter.default.post(
      name: Self.remoteWorkspacesDidChange, object: self, userInfo: ["machineID": machineID])
  }

  /// 执行一次工作区级事务；失败时先重新取快照（服务端可能已部分变更）再把错误抛给调用方。
  private func performStructureChange<Value>(
    on workspace: RemoteMachineWorkspace,
    _ body: (RemoteWorkspaceController) async throws -> Value
  ) async throws -> Value {
    do {
      return try await body(workspace.controller)
    } catch {
      _ = await refresh(machineProfileID: workspace.machineProfileID)
      throw error
    }
  }

  /// 名称去掉首尾空白；为空时报错，不向服务端提交空标题。
  private static func validatedTitle(_ title: String) throws -> String {
    let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw RemoteWorkspaceOperationError.emptyTitle }
    return trimmed
  }

  /// 有窗口时以 sheet 形式同步等待结果，没有窗口时退回应用级模态。
  private static func runModal(_ alert: NSAlert, in window: NSWindow?)
    -> NSApplication.ModalResponse
  {
    guard let window else { return alert.runModal() }
    alert.beginSheetModal(for: window) { response in NSApp.stopModal(withCode: response) }
    return NSApp.runModal(for: alert.window)
  }
}
