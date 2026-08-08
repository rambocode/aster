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

    guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
      applyPanelFrames(targetFrames, transitioning: role, presenting: presenting)
      completion?()
      return
    }

    if presenting, !startsFromCurrent {
      // 新挂载的 Panel 先从合法的折叠布局起步；它仍是 arrangedSubview，因此过渡态
      // 暂时保留相邻 1pt divider，避免 NSSplitView 认为子视图次序发生重叠。
      applyPanelFrames(
        resolvedCollapsedPanelFrames(for: role),
        transitioning: role,
        presenting: false
      )
    }

    for targetRole in targetFrames.keys {
      panelView(for: targetRole)?.wantsLayer = true
    }

    NSAnimationContext.runAnimationGroup(
      { context in
        context.duration = 0.18
        context.timingFunction = CAMediaTimingFunction(name: .easeOut)
        context.allowsImplicitAnimation = true
        // 直接写最终 frame 让模型层立即进入一致终态；`allowsImplicitAnimation`
        // 负责从当前 presentation frame 平滑插值，Content 与边缘 Panel 同步变化。
        applyPanelFrames(targetFrames, transitioning: role, presenting: presenting)
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

  private func applyPanelFrames(
    _ frames: [WorkspacePanelRole: NSRect],
    transitioning role: WorkspacePanelRole,
    presenting: Bool
  ) {
    let remainingRoles = panelRoles.filter { $0 != role && frames[$0] != nil }
    // NSSplitView 会在每次 frame 写入后校验 arrangedSubview 顺序。收起目标已经
    // 暂时脱离 arranged 布局；展开时先让其余 Panel 腾位，再展开边缘 Host。
    // 两条路径都避免 arranged frame 重叠或越界。
    let orderedRoles = presenting ? remainingRoles + [role] : [role] + remainingRoles
    for targetRole in orderedRoles {
      guard let frame = frames[targetRole] else { continue }
      guard let panelView = panelView(for: targetRole) else { continue }
      if targetRole == role {
        panelView.frame = frame
        (panelView as? WorkspaceEdgePanelHostView)?.updateTransitionViewport()
      } else {
        // 边缘 Panel 显隐时，Content 的模型 frame 一次到位即可。禁止它的
        // layer 跟随外层 NSAnimationContext 插值，否则终端已经按新列数
        // 重绘的网格还会被显示层二次拉伸，呈现为抖动和闪烁。
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        panelView.frame = frame
        (panelView as? WorkspaceEdgePanelHostView)?.updateTransitionViewport()
        // Content 的根 frame 一次到位后，必须在同一个禁动画事务内
        // 同步完成标题栏与终端子树布局。若延迟到外层动画或 completion，
        // 标题内容与终端都会在动画末帧再做一次 reflow。
        panelView.layoutSubtreeIfNeeded()
        CATransaction.commit()
      }
    }
    needsDisplay = true
  }
}
