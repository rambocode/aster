import Foundation

/// Otty 参考界面中可切换的三种标签导航位置。
public enum TabBarLayout: String, CaseIterable, Codable, Equatable, Sendable {
  case vertical
  case top
  case bottom
}

/// 左侧标签的可选分组方式，对应 Otty 标签整理菜单的 GROUP 区域。
public enum SidebarTabGrouping: String, CaseIterable, Codable, Equatable, Sendable {
  case none
  case project
  case date
}

/// 左侧标签的时间排序依据，对应 Otty 标签整理菜单的 ORDER 区域。
public enum SidebarTabOrder: String, CaseIterable, Codable, Equatable, Sendable {
  case createdTime
  case updatedTime
}

/// 面板内容类型。终端、编辑器和文件浏览器共享同一分屏树，因此可以任意组合。
public enum PaneKind: String, Codable, Equatable, Sendable {
  case terminal
  case editor
  case fileBrowser
  case preview
}

public enum SplitAxis: String, Codable, Equatable, Sendable {
  case horizontal
  case vertical
}

public enum SplitDirection: String, CaseIterable, Codable, Equatable, Sendable {
  case left
  case right
  case up
  case down

  public var isHorizontal: Bool { self == .left || self == .right }
}

/// 可持久化的单个工作区面板。`resourcePath` 仅供编辑器、预览和文件面板使用；
/// 终端面板以 `workingDirectory` 为启动目录。
public struct PaneDescriptor: Identifiable, Codable, Equatable, Sendable {
  public let id: UUID
  public var kind: PaneKind
  public var workingDirectory: String
  public var resourcePath: String?

  public init(
    id: UUID = UUID(),
    kind: PaneKind,
    workingDirectory: String,
    resourcePath: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.workingDirectory = workingDirectory
    self.resourcePath = resourcePath
  }
}

/// 递归分屏树。每次拆分只替换目标叶节点，关闭叶节点时自动提升其兄弟，避免留下
/// 只有一个子节点的空分隔容器。
public indirect enum PaneLayout: Codable, Equatable, Sendable {
  case leaf(PaneDescriptor)
  case split(axis: SplitAxis, first: PaneLayout, second: PaneLayout, ratio: Double)

  public var allPanes: [PaneDescriptor] {
    switch self {
    case .leaf(let pane): [pane]
    case .split(_, let first, let second, _): first.allPanes + second.allPanes
    }
  }

  public var axis: SplitAxis? {
    guard case .split(let axis, _, _, _) = self else { return nil }
    return axis
  }

  public var firstPaneID: UUID? {
    switch self {
    case .leaf(let pane): pane.id
    case .split(_, let first, _, _): first.firstPaneID
    }
  }

  public func splitting(
    paneID: UUID,
    direction: SplitDirection,
    with newPane: PaneDescriptor
  ) -> PaneLayout? {
    switch self {
    case .leaf(let pane):
      guard pane.id == paneID else { return nil }
      let existing = PaneLayout.leaf(pane)
      let inserted = PaneLayout.leaf(newPane)
      let first = direction == .left || direction == .up ? inserted : existing
      let second = direction == .left || direction == .up ? existing : inserted
      return .split(
        axis: direction.isHorizontal ? .horizontal : .vertical,
        first: first,
        second: second,
        ratio: 0.5
      )

    case .split(let axis, let first, let second, let ratio):
      if let updatedFirst = first.splitting(
        paneID: paneID,
        direction: direction,
        with: newPane
      ) {
        return .split(axis: axis, first: updatedFirst, second: second, ratio: ratio)
      }
      if let updatedSecond = second.splitting(
        paneID: paneID,
        direction: direction,
        with: newPane
      ) {
        return .split(axis: axis, first: first, second: updatedSecond, ratio: ratio)
      }
      return nil
    }
  }

  public func removing(paneID: UUID) -> PaneLayout? {
    remove(paneID: paneID).layout
  }

  /// 更新指定叶节点并保留整棵分屏树的方向与比例，用于把运行中 Shell 报告的 cwd
  /// 写回可恢复快照，而不重建其它 Pane 的身份。
  public func updatingPane(
    paneID: UUID,
    transform: (PaneDescriptor) -> PaneDescriptor
  ) -> PaneLayout {
    switch self {
    case .leaf(let pane):
      return pane.id == paneID ? .leaf(transform(pane)) : self
    case .split(let axis, let first, let second, let ratio):
      return .split(
        axis: axis,
        first: first.updatingPane(paneID: paneID, transform: transform),
        second: second.updatingPane(paneID: paneID, transform: transform),
        ratio: ratio
      )
    }
  }

  /// 更新路径指向的分屏比例，并保持其它节点及 Pane 身份不变。
  ///
  /// 路径中的 `0` 表示进入第一个子节点，`1` 表示进入第二个子节点；空路径表示
  /// 当前节点。比例会限制在 `0.05...0.95`，非法路径或非有限数值保持原布局不变。
  /// - Parameters:
  ///   - path: 从当前节点到目标分屏的子节点索引路径。
  ///   - ratio: 第一个子节点占可用空间的比例。
  /// - Returns: 更新后的不可变分屏树；输入无效时返回原树。
  public func updatingSplitRatio(at path: [Int], ratio: Double) -> PaneLayout {
    guard ratio.isFinite else { return self }
    guard case .split(let axis, let first, let second, let currentRatio) = self else {
      return self
    }

    guard let next = path.first else {
      return .split(
        axis: axis,
        first: first,
        second: second,
        ratio: min(max(ratio, 0.05), 0.95)
      )
    }

    let remaining = Array(path.dropFirst())
    switch next {
    case 0:
      return .split(
        axis: axis,
        first: first.updatingSplitRatio(at: remaining, ratio: ratio),
        second: second,
        ratio: currentRatio
      )
    case 1:
      return .split(
        axis: axis,
        first: first,
        second: second.updatingSplitRatio(at: remaining, ratio: ratio),
        ratio: currentRatio
      )
    default:
      return self
    }
  }

  private func remove(paneID: UUID) -> (layout: PaneLayout?, didRemove: Bool) {
    switch self {
    case .leaf(let pane):
      return pane.id == paneID ? (nil, true) : (self, false)

    case .split(let axis, let first, let second, let ratio):
      let firstResult = first.remove(paneID: paneID)
      if firstResult.didRemove {
        guard let updatedFirst = firstResult.layout else { return (second, true) }
        return (.split(axis: axis, first: updatedFirst, second: second, ratio: ratio), true)
      }

      let secondResult = second.remove(paneID: paneID)
      if secondResult.didRemove {
        guard let updatedSecond = secondResult.layout else { return (first, true) }
        return (.split(axis: axis, first: first, second: updatedSecond, ratio: ratio), true)
      }
      return (self, false)
    }
  }
}

public enum RecipeReplayMode: String, CaseIterable, Codable, Equatable, Sendable {
  case automatic
  case confirmOnce
  case oneByOne
  case skip
}

public struct RecipeTab: Codable, Equatable, Sendable {
  public var title: String
  public var layout: PaneLayout
  public var commands: [String]

  public init(title: String, layout: PaneLayout, commands: [String] = []) {
    self.title = title
    self.layout = layout
    self.commands = commands
  }
}

/// `.asterrecipe` 文件的稳定领域模型。它只保存可重建状态，不序列化运行中的 PID、
/// 文件描述符或临时 UI 焦点。
public struct WorkspaceRecipe: Codable, Equatable, Sendable {
  public var name: String
  public var tabs: [RecipeTab]
  public var replayMode: RecipeReplayMode

  public init(name: String, tabs: [RecipeTab], replayMode: RecipeReplayMode) {
    self.name = name
    self.tabs = tabs
    self.replayMode = replayMode
  }
}
