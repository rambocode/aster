import AppKit
import AsterCore

/// Panel 显隐时，Content 的模型 frame 一次进入终态，只有边缘 Host 执行显示层
/// 折叠动画。这样既保留整块 Panel 过渡，又不会二次拉伸已重绘的终端网格。
@MainActor
extension WorkspacePanelSplitView {
  /// 接管可能来自旧 split 的 Panel 根视图时，终止旧的位移/透明度动画并恢复稳定终态。
  /// 这里只清理 Panel 根 layer；内容内部的终端或列表动画不受影响。
  func preparePanelViewForOwnership(_ view: NSView) {
    view.layer?.removeAllAnimations()
    view.layer?.transform = CATransform3DIdentity
    view.alphaValue = 1
    // Panel 由 split 统一写 frame；稳定态保留 autoresizing mask，使外层 Auto Layout
    // 能从当前 frame 生成约束。动画开始时会暂时关闭转换，完成后再恢复。
    view.translatesAutoresizingMaskIntoConstraints = true
  }

  func animate(
    _ view: NSView,
    role: WorkspacePanelRole,
    presenting: Bool,
    startsFromCurrent: Bool = false,
    completion: (@MainActor @Sendable () -> Void)? = nil
  ) {
    view.wantsLayer = true
    view.layer?.transform = CATransform3DIdentity
    view.alphaValue = 1

    let targetFrames =
      presenting
      ? resolvedPanelFrames(for: panelRoles)
      : resolvedCollapsedPanelFrames(for: role)
    let stableContentWidth = presenting
      ? targetFrames[role]?.width ?? view.bounds.width
      : max(view.bounds.width, view.frame.width)
    (view as? WorkspaceEdgePanelHostView)?.beginFrameTransition(
      minimumContentWidth: stableContentWidth
    )

    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      applyPanelFramesImmediately(targetFrames, transitioning: role)
      completion?()
      return
    }

    if presenting, !startsFromCurrent {
      // 新挂载的 Panel 仍是 detached overlay。先在动画上下文之外放到折叠起点，
      // Content 的 frame 与收起态相同，因此不会产生一次无意义的终端 resize。
      applyPanelFramesImmediately(resolvedCollapsedPanelFrames(for: role), transitioning: role)
    }

    // Content 必须在进入 NSAnimationContext 之前一次布局到终态。仅用 CATransaction
    // 禁用 layer action 不够：AppKit Auto Layout 仍会继承外层动画上下文并逐帧改变
    // 终端子树，造成连续 TIOCSWINSZ 与 TUI 重绘。
    applyNonTransitioningPanelFramesImmediately(targetFrames, transitioning: role)

    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        context.allowsImplicitAnimation = true
        // 动画上下文中只写边缘 Host；Content 已经在上方完成终态布局。
        applyTransitioningPanelFrame(targetFrames[role], role: role)
      },
      completionHandler: {
        Task { @MainActor in completion?() }
      }
    )
  }

  /// 按与普通布局相同的宽度策略生成一组终态 frame。动画只改变 frame，不写回 store，
  /// 因此显隐操作不会污染用户拖动保存的首选宽度。
  private func resolvedPanelFrames(
    for visibleRoles: [WorkspacePanelRole]
  ) -> [WorkspacePanelRole: NSRect] {
    let widths = WorkspacePanelLayoutPolicy.resolve(
      availableWidth: Double(bounds.width),
      visibleRoles: visibleRoles,
      state: panelLayoutState
    )
    var result: [WorkspacePanelRole: NSRect] = [:]
    var originX: CGFloat = 0
    for (index, role) in visibleRoles.enumerated() {
      let width = CGFloat(widths[role] ?? 0)
      result[role] = NSRect(x: originX, y: 0, width: width, height: bounds.height)
      originX += width
      if index < visibleRoles.count - 1 { originX += dividerThickness }
    }
    return result
  }

  /// 收起目标已暂时脱离 arrangedSubviews，因此剩余 Panel 直接使用与
  /// 真正移除后相同的宽度与 divider 数量。目标 Host 保留在 split 子视图
  /// 层级中，但作为 0pt 动画覆盖层贴在对应边界。
  private func resolvedCollapsedPanelFrames(
    for collapsingRole: WorkspacePanelRole
  ) -> [WorkspacePanelRole: NSRect] {
    let visibleRoles = panelRoles.filter { $0 != collapsingRole }
    let widths = WorkspacePanelLayoutPolicy.resolve(
      availableWidth: Double(bounds.width),
      visibleRoles: visibleRoles,
      state: panelLayoutState
    )
    var result: [WorkspacePanelRole: NSRect] = [:]
    var originX: CGFloat = 0
    for (index, role) in visibleRoles.enumerated() {
      let width = CGFloat(widths[role] ?? 0)
      result[role] = NSRect(x: originX, y: 0, width: width, height: bounds.height)
      originX += width
      if index < visibleRoles.count - 1 { originX += dividerThickness }
    }
    let collapsedX: CGFloat = collapsingRole == .inspector ? bounds.maxX : bounds.minX
    result[collapsingRole] = NSRect(
      x: collapsedX,
      y: 0,
      width: 0,
      height: bounds.height
    )
    return result
  }

  private func applyPanelFramesImmediately(
    _ frames: [WorkspacePanelRole: NSRect],
    transitioning role: WorkspacePanelRole
  ) {
    applyNonTransitioningPanelFramesImmediately(frames, transitioning: role)
    applyTransitioningPanelFrame(frames[role], role: role)
    needsDisplay = true
  }

  /// 非目标 Panel 完全位于动画上下文之外。显式禁用 Core Animation action，并同步
  /// 布局整个子树，保证 Content 中的 SwiftTerm 只看到最终网格尺寸。
  private func applyNonTransitioningPanelFramesImmediately(
    _ frames: [WorkspacePanelRole: NSRect],
    transitioning role: WorkspacePanelRole
  ) {
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    for targetRole in panelRoles where targetRole != role {
      guard let frame = frames[targetRole], let panelView = panelView(for: targetRole) else {
        continue
      }
      panelView.frame = frame
      (panelView as? WorkspaceEdgePanelHostView)?.updateTransitionViewport()
      panelView.needsLayout = true
      panelView.layoutSubtreeIfNeeded()
    }
  }

  /// 过渡目标只有边缘 Host。Content 和其它 Panel 不得从这里进入动画上下文。
  private func applyTransitioningPanelFrame(_ frame: NSRect?, role: WorkspacePanelRole) {
    guard let frame, let panelView = panelView(for: role) else { return }
    panelView.frame = frame
    (panelView as? WorkspaceEdgePanelHostView)?.updateTransitionViewport()
    needsDisplay = true
  }
}
