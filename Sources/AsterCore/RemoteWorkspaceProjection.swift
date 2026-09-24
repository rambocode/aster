import Foundation

/// P4.2 客户端半边：把服务端共享结构投影成 App 已有的布局模型。
///
/// 全部是纯函数：输入 `RemoteSessionSnapshot`，输出 `PaneLayout` / `PaneDescriptor`，
/// 不触碰进程、文件系统或 AppKit，因此可以直接单测。
///
/// 规则（`docs/developer/remote-work.md` §3.3 / §4.2）：
/// - 共享结构里的每个 leaf 都是受管终端 pane，`PaneDescriptor.managedTerminal` 必填。
/// - `paneID` 跨恢复稳定，只作为身份；它**不能**证明进程存活，存活由
///   `ManagedTerminalStatus` 的实测状态决定。
/// - 投影结果的 `resourcePath` 恒为 nil：本地文件/编辑器/预览/Web 资源不属于共享结构。

/// 投影后的标签。
public struct ProjectedRemoteTab: Equatable, Sendable {
  public var tabID: String
  public var title: String
  public var layout: PaneLayout

  public init(tabID: String, title: String, layout: PaneLayout) {
    self.tabID = tabID
    self.title = title
    self.layout = layout
  }
}

/// 投影后的工作区。
public struct ProjectedRemoteWorkspace: Equatable, Sendable {
  public var workspaceID: String
  public var title: String
  public var cwd: String
  public var tabs: [ProjectedRemoteTab]

  public init(workspaceID: String, title: String, cwd: String, tabs: [ProjectedRemoteTab]) {
    self.workspaceID = workspaceID
    self.title = title
    self.cwd = cwd
    self.tabs = tabs
  }
}

/// 一次投影的完整结果。`revision` 随投影一起传下去，界面上的后续结构修改必须用它
/// 作为 `expectedRevision`，否则会用过期版本发起事务。
public struct ProjectedRemoteSession: Equatable, Sendable {
  public var revision: UInt64
  public var workspaces: [ProjectedRemoteWorkspace]
  /// paneID → 受管终端实测状态。界面用它显示 running/exited，而不是用 paneID 猜。
  public var terminalStatusByPaneID: [UUID: ManagedTerminalStatus]

  public init(
    revision: UInt64,
    workspaces: [ProjectedRemoteWorkspace],
    terminalStatusByPaneID: [UUID: ManagedTerminalStatus]
  ) {
    self.revision = revision
    self.workspaces = workspaces
    self.terminalStatusByPaneID = terminalStatusByPaneID
  }
}

public enum RemoteWorkspaceProjection {
  /// 把服务端快照投影成 App 侧布局模型。
  ///
  /// - Parameters:
  ///   - snapshot: `session.snapshot` 解码结果。
  ///   - server: 该会话的稳定服务引用，用于构造 `ManagedTerminalReference`。
  /// - Returns: 可直接驱动界面的投影结果。
  /// - Throws: `RemoteSnapshotError.invalidIdentifier`（paneID 不是合法 UUID）。
  public static func project(
    snapshot: RemoteSessionSnapshot,
    server: SessionServerReference
  ) throws -> ProjectedRemoteSession {
    let terminals = snapshot.terminalsByID
    var statusByPane: [UUID: ManagedTerminalStatus] = [:]
    var workspaces: [ProjectedRemoteWorkspace] = []
    workspaces.reserveCapacity(snapshot.workspaces.count)

    for workspace in snapshot.workspaces {
      var tabs: [ProjectedRemoteTab] = []
      tabs.reserveCapacity(workspace.tabs.count)
      for tab in workspace.tabs {
        let layout = try project(
          node: tab.layout,
          server: server,
          terminals: terminals,
          fallbackWorkingDirectory: workspace.cwd,
          statusByPane: &statusByPane
        )
        tabs.append(ProjectedRemoteTab(tabID: tab.tabID, title: tab.title, layout: layout))
      }
      workspaces.append(
        ProjectedRemoteWorkspace(
          workspaceID: workspace.workspaceID,
          title: workspace.title,
          cwd: workspace.cwd,
          tabs: tabs
        ))
    }

    return ProjectedRemoteSession(
      revision: snapshot.revision,
      workspaces: workspaces,
      terminalStatusByPaneID: statusByPane
    )
  }

  /// 投影单棵分屏树。
  public static func project(
    node: RemoteLayoutNode,
    server: SessionServerReference,
    terminals: [String: ManagedTerminalStatus],
    fallbackWorkingDirectory: String
  ) throws -> PaneLayout {
    var ignored: [UUID: ManagedTerminalStatus] = [:]
    return try project(
      node: node,
      server: server,
      terminals: terminals,
      fallbackWorkingDirectory: fallbackWorkingDirectory,
      statusByPane: &ignored
    )
  }

  private static func project(
    node: RemoteLayoutNode,
    server: SessionServerReference,
    terminals: [String: ManagedTerminalStatus],
    fallbackWorkingDirectory: String,
    statusByPane: inout [UUID: ManagedTerminalStatus]
  ) throws -> PaneLayout {
    switch node {
    case .leaf(let pane):
      guard let paneUUID = UUID(uuidString: pane.paneID) else {
        throw RemoteSnapshotError.invalidIdentifier(pane.paneID)
      }
      let status = terminals[pane.terminalID]
      if let status { statusByPane[paneUUID] = status }
      let descriptor = PaneDescriptor(
        id: paneUUID,
        kind: .terminal,
        // 终端的真实 cwd 由服务端上报；快照里没有该终端记录时退回工作区 cwd，
        // 绝不读取本机同路径来补全（§3.3：不读取本机同路径作为远端数据）。
        workingDirectory: status?.cwd ?? fallbackWorkingDirectory,
        resourcePath: nil,
        managedTerminal: ManagedTerminalReference(server: server, terminalID: pane.terminalID)
      )
      return .leaf(descriptor)

    case .split(let axis, let ratio, let first, let second):
      return .split(
        axis: axis,
        first: try project(
          node: first, server: server, terminals: terminals,
          fallbackWorkingDirectory: fallbackWorkingDirectory, statusByPane: &statusByPane),
        second: try project(
          node: second, server: server, terminals: terminals,
          fallbackWorkingDirectory: fallbackWorkingDirectory, statusByPane: &statusByPane),
        ratio: ratio
      )
    }
  }
}

// MARK: - 命名工作区选中项

/// 远端机器上一个工作区的摘要：供切换器、侧栏与 CLI 列表使用，全部取自缓存投影。
public struct RemoteWorkspaceSummary: Codable, Equatable, Sendable {
  public var workspaceID: String
  public var title: String
  public var tabCount: Int
  /// 该工作区全部标签里受管终端的数量；关闭工作区会结束这些远端进程。
  public var terminalCount: Int
  public var isSelected: Bool
  /// 每个标签的标题，按服务端顺序；切换器按标签名搜索工作区时用它。
  public var tabTitles: [String]

  public init(
    workspaceID: String, title: String, tabCount: Int, terminalCount: Int, isSelected: Bool,
    tabTitles: [String]
  ) {
    self.workspaceID = workspaceID
    self.title = title
    self.tabCount = tabCount
    self.terminalCount = terminalCount
    self.isSelected = isSelected
    self.tabTitles = tabTitles
  }
}

extension ProjectedRemoteSession {
  /// 按偏好解析出实际选中的工作区 ID。
  ///
  /// 偏好的工作区仍在投影里就用它；不在（被其它客户端关闭、或偏好为空）时退回第一个。
  /// 投影里没有任何工作区时返回 nil。规则集中在这里，避免界面各处各自「取 first」。
  public func resolvedWorkspaceID(preferred: String?) -> String? {
    if let preferred, workspaces.contains(where: { $0.workspaceID == preferred }) {
      return preferred
    }
    return workspaces.first?.workspaceID
  }

  /// 按 ID 取投影里的工作区。
  public func workspace(withID workspaceID: String?) -> ProjectedRemoteWorkspace? {
    guard let workspaceID else { return nil }
    return workspaces.first { $0.workspaceID == workspaceID }
  }

  /// 生成全部工作区的摘要；`selectedWorkspaceID` 应是 `resolvedWorkspaceID` 的结果。
  public func summaries(selectedWorkspaceID: String?) -> [RemoteWorkspaceSummary] {
    workspaces.map { workspace in
      RemoteWorkspaceSummary(
        workspaceID: workspace.workspaceID,
        title: workspace.title,
        tabCount: workspace.tabs.count,
        terminalCount: workspace.tabs.reduce(0) { count, tab in
          count + tab.layout.allPanes.filter { $0.managedTerminal != nil }.count
        },
        isSelected: workspace.workspaceID == selectedWorkspaceID,
        tabTitles: workspace.tabs.map(\.title))
    }
  }
}
