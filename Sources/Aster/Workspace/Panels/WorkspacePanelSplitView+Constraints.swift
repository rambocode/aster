import AppKit
import AsterCore

/// 把 divider 的原生拖动约束集中在布局边界，避免 Sidebar 或 Inspector 控制器
/// 各自推导相邻区域尺寸。约束始终为中间内容保留最小宽度，并禁止拖动折叠 Panel。
@MainActor
extension WorkspacePanelSplitView {
  func splitView(_: NSSplitView, canCollapseSubview subview: NSView) -> Bool {
    guard let role = panelRole(for: subview) else { return false }
    return isPanelTransitioning(role)
  }

  /// `NSSplitView` 会把 `.thin` divider 的默认有效命中区向两侧扩张。产品约定左右
  /// Panel 不增加宽命中带，因此把原生拖动区域收回到实际画出的 1pt；hover、cursor、
  /// 双击和拖动提交就都使用同一套几何。
  func splitView(
    _: NSSplitView,
    effectiveRect _: NSRect,
    forDrawnRect drawnRect: NSRect,
    ofDividerAt _: Int
  ) -> NSRect {
    drawnRect
  }

  func splitView(
    _: NSSplitView,
    constrainMinCoordinate proposedMinimumPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat {
    coordinateRange(forDividerAt: dividerIndex)?.lowerBound ?? proposedMinimumPosition
  }

  func splitView(
    _: NSSplitView,
    constrainMaxCoordinate proposedMaximumPosition: CGFloat,
    ofSubviewAt dividerIndex: Int
  ) -> CGFloat {
    coordinateRange(forDividerAt: dividerIndex)?.upperBound ?? proposedMaximumPosition
  }

  private func coordinateRange(forDividerAt index: Int) -> ClosedRange<CGFloat>? {
    guard let role = panelRole(forDividerAt: index) else { return nil }
    let total = bounds.width
    switch role {
    case .sidebar:
      let inspectorWidth = panelView(for: .inspector)?.frame.width ?? 0
      let trailingDivider = panelView(for: .inspector) == nil ? 0 : dividerThickness
      let maximumFromContent =
        total - inspectorWidth - trailingDivider
        - CGFloat(WorkspacePanelLayoutPolicy.contentMinimumWidth) - dividerThickness
      let upper = min(
        CGFloat(WorkspacePanelLayoutPolicy.sidebarMaximumWidth),
        maximumFromContent
      )
      let lower =
        isPanelTransitioning(.sidebar)
        ? 0 : CGFloat(WorkspacePanelLayoutPolicy.sidebarMinimumWidth)
      return lower...max(lower, upper)
    case .content:
      return nil
    case .inspector:
      let lowerFromMaximum =
        total - dividerThickness
        - CGFloat(WorkspacePanelLayoutPolicy.inspectorMaximumWidth)
      let sidebarWidth = panelView(for: .sidebar)?.frame.width ?? 0
      let leadingDivider = panelView(for: .sidebar) == nil ? 0 : dividerThickness
      let lowerFromContent =
        sidebarWidth + leadingDivider
        + CGFloat(WorkspacePanelLayoutPolicy.contentMinimumWidth)
      let lower = max(lowerFromMaximum, lowerFromContent)
      let upper =
        isPanelTransitioning(.inspector)
        ? total - dividerThickness
        : total - dividerThickness
          - CGFloat(WorkspacePanelLayoutPolicy.inspectorMinimumWidth)
      return min(lower, upper)...upper
    }
  }
}
