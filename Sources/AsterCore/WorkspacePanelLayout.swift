import Foundation

/// 主窗口顶层区域的稳定语义。`Panel` 是窗口级容器，不等同于 `PaneLayout` 中承载
/// 终端、编辑器或文件浏览器的 Pane；中栏内部仍可继续递归拆分 Pane。
public enum WorkspacePanelRole: String, Codable, CaseIterable, Sendable {
  case sidebar
  case content
  case inspector
}

/// 每个工作区窗口独立持久化的 Panel 首选宽度。
///
/// 中栏宽度由窗口剩余空间推导，不写入状态；这样调整窗口大小时不会把一次临时压缩
/// 错当成用户的新首选宽度。
public struct WorkspacePanelLayoutState: Codable, Equatable, Sendable {
  /// Sidebar 的用户首选 point 宽度；读取外部数据后应先调用 `normalized()`。
  public var sidebarWidth: Double
  /// Inspector 的用户首选 point 宽度；不表示窄窗口下临时压缩后的 frame。
  public var inspectorWidth: Double

  /// 创建一份窗口级首选宽度。初始化不隐式 clamp，便于解码测试保留原始输入；布局
  /// 和持久化边界会通过 `normalized()` 统一校验。
  public init(sidebarWidth: Double, inspectorWidth: Double) {
    self.sidebarWidth = sidebarWidth
    self.inspectorWidth = inspectorWidth
  }

  public static let `default` = WorkspacePanelLayoutState(
    sidebarWidth: WorkspacePanelLayoutPolicy.sidebarDefaultWidth,
    inspectorWidth: WorkspacePanelLayoutPolicy.inspectorDefaultWidth
  )

  /// 规范化来自 UserDefaults 或旧配置的宽度，拒绝 NaN、无穷值和越界值。
  public func normalized() -> WorkspacePanelLayoutState {
    WorkspacePanelLayoutState(
      sidebarWidth: WorkspacePanelLayoutPolicy.clampedWidth(sidebarWidth, for: .sidebar),
      inspectorWidth: WorkspacePanelLayoutPolicy.clampedWidth(inspectorWidth, for: .inspector)
    )
  }

  /// 返回边缘 Panel 的首选宽度；Content 是弹性区域，因此返回 `nil`。
  public func preferredWidth(for role: WorkspacePanelRole) -> Double? {
    switch role {
    case .sidebar: sidebarWidth
    case .content: nil
    case .inspector: inspectorWidth
    }
  }
}

/// 与 AppKit 无关的 Panel 尺寸真值。窗口布局和设置页共用这些范围，避免两个入口
/// 各自维护魔法值后出现拖动能到达、滑杆却无法表示的状态。
public enum WorkspacePanelLayoutPolicy {
  public static let sidebarMinimumWidth = 180.0
  public static let sidebarDefaultWidth = 220.0
  public static let sidebarMaximumWidth = 360.0
  public static let contentMinimumWidth = 320.0
  public static let inspectorMinimumWidth = 240.0
  public static let inspectorDefaultWidth = 278.0
  public static let inspectorMaximumWidth = 480.0
  public static let dividerThickness = 1.0

  /// 返回边缘 Panel 的产品默认宽度；Content 没有固定默认值。
  public static func defaultWidth(for role: WorkspacePanelRole) -> Double? {
    switch role {
    case .sidebar: sidebarDefaultWidth
    case .content: nil
    case .inspector: inspectorDefaultWidth
    }
  }

  /// 返回用户可明确选择的 point 范围；Content 由可用空间求解，返回 `nil`。
  public static func widthRange(for role: WorkspacePanelRole) -> ClosedRange<Double>? {
    switch role {
    case .sidebar: sidebarMinimumWidth...sidebarMaximumWidth
    case .content: nil
    case .inspector: inspectorMinimumWidth...inspectorMaximumWidth
    }
  }

  /// 把外部宽度夹进角色范围。NaN 和无穷值回退到角色默认值；Content 原样返回。
  public static func clampedWidth(_ width: Double, for role: WorkspacePanelRole) -> Double {
    guard let range = widthRange(for: role) else { return width }
    let fallback = defaultWidth(for: role) ?? range.lowerBound
    guard width.isFinite else { return fallback }
    return min(max(width, range.lowerBound), range.upperBound)
  }

  /// 解析当前窗口里各可见 Panel 的实际宽度。
  ///
  /// - Parameters:
  ///   - availableWidth: `NSSplitView` 的总宽度，包含可见 divider。
  ///   - visibleRoles: 当前按视觉顺序挂载的角色；中栏应始终存在。
  ///   - state: 用户首选宽度。该值只读，临时压缩不会反向写入。
  /// - Returns: 每个可见角色的实际宽度；所有结果非负且总和加 divider 后不超过输入。
  public static func resolve(
    availableWidth: Double,
    visibleRoles: [WorkspacePanelRole],
    state: WorkspacePanelLayoutState
  ) -> [WorkspacePanelRole: Double] {
    let roles = WorkspacePanelRole.allCases.filter(visibleRoles.contains)
    guard !roles.isEmpty else { return [:] }
    let total = availableWidth.isFinite ? max(0, availableWidth) : 0
    let dividerCount = max(0, roles.count - 1)
    let contentBudget = max(0, total - Double(dividerCount) * dividerThickness)
    let normalized = state.normalized()

    var sidebar = roles.contains(.sidebar) ? normalized.sidebarWidth : 0
    var inspector = roles.contains(.inspector) ? normalized.inspectorWidth : 0
    let desiredContentMinimum =
      roles.contains(.content)
      ? min(contentMinimumWidth, contentBudget)
      : 0
    let sideBudget = max(0, contentBudget - desiredContentMinimum)
    var shortage = max(0, sidebar + inspector - sideBudget)

    // 右侧详情属于辅助信息，窗口变窄时先压缩它，再压缩主导航；两者都只压到各自
    // 最小值。正常窗口最小尺寸能够容纳这两项和 320pt 中栏。
    if inspector > 0, shortage > 0 {
      let reducible = inspector - inspectorMinimumWidth
      let reduction = min(shortage, max(0, reducible))
      inspector -= reduction
      shortage -= reduction
    }
    if sidebar > 0, shortage > 0 {
      let reducible = sidebar - sidebarMinimumWidth
      let reduction = min(shortage, max(0, reducible))
      sidebar -= reduction
      shortage -= reduction
    }

    // 对小于应用支持窗口尺寸的调用仍给出合法几何：按最小宽度比例继续压缩侧栏，
    // 不产生负宽度或让 frame 总和溢出。真实 NSWindow 的 minSize 会阻止进入此分支。
    if shortage > 0 {
      let sideTotal = sidebar + inspector
      if sideTotal > 0 {
        let scale = max(0, (sideTotal - shortage) / sideTotal)
        sidebar *= scale
        inspector *= scale
      }
    }

    var result: [WorkspacePanelRole: Double] = [:]
    if roles.contains(.sidebar) { result[.sidebar] = sidebar }
    if roles.contains(.inspector) { result[.inspector] = inspector }
    if roles.contains(.content) {
      result[.content] = max(0, contentBudget - sidebar - inspector)
    }
    return result
  }
}
