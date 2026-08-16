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

extension SidebarTabGrouping {
  /// 项目分组的组头标题真值：显示完整目录路径（home 缩写为 `~`）并保留尾部斜杠，
  /// 对齐 Otty 的 TABS 分组样式；目录为空时回退 `fallback`（标签标题）。
  /// 标题同时充当分组 key：用完整路径而不是最后一段目录名，两个同名目录
  /// （如不同仓库各自的 `src`）才不会被误并进同一组。
  public static func projectGroupTitle(
    forDirectory directory: String,
    homeDirectory: String,
    fallback: String
  ) -> String {
    // 去掉尾部斜杠再比较（根目录除外），避免 `/a/b/` 与 `/a/b` 分成两组。
    func trimmedPath(_ path: String) -> String {
      var value = path
      while value.count > 1, value.hasSuffix("/") { value.removeLast() }
      return value
    }
    let normalized = trimmedPath(directory)
    guard !normalized.isEmpty else { return fallback }
    let home = trimmedPath(homeDirectory)
    if home.count > 1 {
      if normalized == home { return "~/" }
      if normalized.hasPrefix(home + "/") {
        return "~" + normalized.dropFirst(home.count) + "/"
      }
    }
    return normalized == "/" ? "/" : normalized + "/"
  }
}

/// 左侧标签的时间排序依据，对应 Otty 标签整理菜单的 ORDER 区域。
/// 早期版本还有 `manual`：任何新标签插入都会自动切换过去，导致用户选择的时间排序
/// 悄悄失效；该值已删除，旧持久化的 "manual" 在载入时按 rawValue 解析失败回落默认。
public enum SidebarTabOrder: String, CaseIterable, Codable, Equatable, Sendable {
  case createdTime
  case updatedTime
}

/// 面板内容类型。终端、文件工具与网页共享同一分屏树，因此可以任意组合。
public enum PaneKind: String, Codable, Equatable, Sendable {
  case terminal
  case editor
  case fileBrowser
  case preview
  case web
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

/// 可持久化的单个工作区面板。文件类 Pane 的 `resourcePath` 保存本地路径，Web Pane
/// 保存规范化的 HTTP(S) URL；终端面板以 `workingDirectory` 为启动目录。
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

/// 分屏树的导航与几何操作。这些方法是「聚焦面板」「移动分隔条」「等分拆分」
/// 三组菜单命令的唯一真值来源：全部是纯函数，不依赖 AppKit 的实际帧尺寸，
/// 因此可以在 `AsterCore` 直接测试。
extension PaneLayout {
  /// 定位叶节点在树中的子节点索引路径（`0` 进入第一个子节点，`1` 进入第二个）。
  /// 返回空数组表示当前节点本身就是目标叶；找不到返回 nil。
  public func path(toPane paneID: UUID) -> [Int]? {
    switch self {
    case .leaf(let pane):
      return pane.id == paneID ? [] : nil
    case .split(_, let first, let second, _):
      if let sub = first.path(toPane: paneID) { return [0] + sub }
      if let sub = second.path(toPane: paneID) { return [1] + sub }
      return nil
    }
  }

  /// 读取路径指向的子树；路径越界或走进叶节点内部时返回 nil。
  public func node(at path: [Int]) -> PaneLayout? {
    guard let next = path.first else { return self }
    guard case .split(_, let first, let second, _) = self else { return nil }
    let remaining = Array(path.dropFirst())
    switch next {
    case 0: return first.node(at: remaining)
    case 1: return second.node(at: remaining)
    default: return nil
    }
  }

  /// 路径指向的分屏当前比例；路径不是分屏节点时返回 nil。
  public func splitRatio(at path: [Int]) -> Double? {
    guard let node = node(at: path), case .split(_, _, _, let ratio) = node else { return nil }
    return ratio
  }

  /// 把整棵树的所有分屏比例恢复为等分，Pane 身份与树形结构保持不变。
  public func equalizingRatios() -> PaneLayout {
    switch self {
    case .leaf:
      return self
    case .split(let axis, let first, let second, _):
      return .split(
        axis: axis,
        first: first.equalizingRatios(),
        second: second.equalizingRatios(),
        ratio: 0.5
      )
    }
  }

  /// 按方向查找相邻面板，用于「聚焦上/下/左/右面板」。
  ///
  /// 采用树式导航而非屏幕坐标：从目标叶自底向上找第一个「轴向匹配、且目标叶位于
  /// 移动方向来源侧」的祖先分屏，再进入对侧子树取靠近分隔条的那一片叶。屏幕坐标法
  /// 需要真实帧尺寸，无法在领域层求值，也会在窗口尚未布局时给出错误结果。
  public func adjacentPaneID(from paneID: UUID, direction: SplitDirection) -> UUID? {
    guard var path = path(toPane: paneID) else { return nil }
    let wantedAxis: SplitAxis = direction.isHorizontal ? .horizontal : .vertical
    // 向右/向下是「从第一个子节点走向第二个」，向左/向上相反。
    let forward = direction == .right || direction == .down

    while let branch = path.last {
      path.removeLast()
      guard let parent = node(at: path),
        case .split(let axis, let first, let second, _) = parent
      else { return nil }
      if axis == wantedAxis, branch == (forward ? 0 : 1) {
        let target = forward ? second : first
        return target.edgePaneID(alongAxis: wantedAxis, takeFirst: forward)
      }
    }
    return nil
  }

  /// 距离目标叶最近、且轴向匹配的祖先分屏路径，用于移动分隔条。
  /// 没有该方向的分隔条时返回 nil（例如只做过左右拆分却要求上移分隔条）。
  public func nearestSplitPath(fromPane paneID: UUID, axis: SplitAxis) -> [Int]? {
    guard var path = path(toPane: paneID) else { return nil }
    while !path.isEmpty {
      path.removeLast()
      if let node = node(at: path), node.axis == axis { return path }
    }
    return nil
  }

  /// 关闭某个叶节点后应当接管焦点的面板：它的兄弟子树中最靠近它的一片叶。
  /// 关闭后统一回到第一个 Pane 会让焦点在多层分屏里发生远距离跳跃。
  public func neighborPaneID(ofPane paneID: UUID) -> UUID? {
    guard var path = path(toPane: paneID), let branch = path.last else { return nil }
    path.removeLast()
    guard let parent = node(at: path),
      case .split(let axis, let first, let second, _) = parent
    else { return nil }
    let sibling = branch == 0 ? second : first
    // 被删叶在第一侧时，兄弟里最靠近的是它的「第一片」叶，反之取最后一片。
    return sibling.edgePaneID(alongAxis: axis, takeFirst: branch == 0)
  }

  /// 读取指定叶的描述符；面板不存在时返回 nil。
  public func descriptor(forPane paneID: UUID) -> PaneDescriptor? {
    allPanes.first { $0.id == paneID }
  }

  /// 交换两个面板的位置，分屏结构与所有比例保持不变（拖放到面板中心的语义）。
  /// 交换的是描述符而不是子树，因此两个面板的运行态（PTY、编辑缓冲）都不受影响。
  public func swappingPanes(_ first: UUID, _ second: UUID) -> PaneLayout {
    guard first != second,
      let firstPane = descriptor(forPane: first),
      let secondPane = descriptor(forPane: second)
    else { return self }
    return mappingLeaves { pane in
      if pane.id == first { return secondPane }
      if pane.id == second { return firstPane }
      return pane
    }
  }

  /// 把面板移动到目标面板的指定一侧（拖放到面板边缘的语义）。
  ///
  /// 先摘除再插入：摘除会自动提升被移动面板的兄弟节点，因此不会留下空容器，
  /// 目标面板在摘除后仍存在才继续。面板 ID 全程不变，运行态跟着一起搬。
  public func movingPane(
    _ paneID: UUID,
    nextTo targetID: UUID,
    direction: SplitDirection
  ) -> PaneLayout? {
    guard paneID != targetID, let moved = descriptor(forPane: paneID) else { return nil }
    guard let remaining = removing(paneID: paneID), remaining.path(toPane: targetID) != nil else {
      return nil
    }
    return remaining.splitting(paneID: targetID, direction: direction, with: moved)
  }

  /// 对每个叶节点应用变换，保持树形结构与比例不变。
  private func mappingLeaves(_ transform: (PaneDescriptor) -> PaneDescriptor) -> PaneLayout {
    switch self {
    case .leaf(let pane):
      return .leaf(transform(pane))
    case .split(let axis, let first, let second, let ratio):
      return .split(
        axis: axis,
        first: first.mappingLeaves(transform),
        second: second.mappingLeaves(transform),
        ratio: ratio
      )
    }
  }

  /// 沿指定轴取子树边缘的叶：`takeFirst` 为真取靠前一侧，否则取靠后一侧。
  /// 与导航轴垂直的分屏无法决定远近，统一取第一个子节点保持结果稳定。
  private func edgePaneID(alongAxis axis: SplitAxis, takeFirst: Bool) -> UUID? {
    switch self {
    case .leaf(let pane):
      return pane.id
    case .split(let nodeAxis, let first, let second, _):
      guard nodeAxis == axis else {
        return first.edgePaneID(alongAxis: axis, takeFirst: takeFirst)
      }
      return (takeFirst ? first : second).edgePaneID(alongAxis: axis, takeFirst: takeFirst)
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
