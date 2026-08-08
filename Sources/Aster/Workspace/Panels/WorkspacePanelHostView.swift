import AppKit
import AsterCore

/// 边缘 Panel 的裁剪边界。
///
/// Inspector/Sidebar 的内容通常包含带最小宽度约束的 stack、搜索框和按钮，不能直接
/// 把内容根视图动画到 0pt。Host 把「参与 split 的可变宽度」与「内容自身的稳定布局」
/// 分开：过渡时只收拢 Host，并把内容固定在外侧边缘，由 Host 从内侧逐步裁剪。
/// 因此右上角切换按钮保持窗口坐标不变，内容与 Panel 也不会分成两段消失。
@MainActor
final class WorkspaceEdgePanelHostView: NSView {
  let role: WorkspacePanelRole
  let contentView: NSView

  private var stableContentWidth: CGFloat = 0
  private var preservesContentWidth = false

  init(role: WorkspacePanelRole, contentView: NSView) {
    precondition(role != .content, "Content Panel 不需要边缘裁剪 Host")
    self.role = role
    self.contentView = contentView
    super.init(frame: .zero)
    wantsLayer = true
    layer?.masksToBounds = true

    // 内容可能正从旧 split 的过渡 Host 迁移过来。先解除旧层级，再恢复成由当前 Host
    // 手工定位的根视图；不建立边缘约束，避免内容的最小宽度反向撑开 Host。
    contentView.removeFromSuperview()
    contentView.translatesAutoresizingMaskIntoConstraints = true
    addSubview(contentView)
  }

  required init?(coder _: NSCoder) { nil }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  /// 开始收拢/展开时冻结内容宽度。Host 继续改变 frame，内容只沿外侧边缘定位，
  /// 其内部 Auto Layout 不会在 0...首选宽度之间反复求解。
  func beginFrameTransition(minimumContentWidth: CGFloat) {
    // 首次展开时 Host 仍是 0pt 覆盖层，内容也尚未得到最终 frame。显式传入目标宽度，
    // 才能从第一帧就冻结 Inspector 的内部布局，并沿 trailing edge 做稳定裁剪。
    stableContentWidth = max(
      stableContentWidth,
      max(minimumContentWidth, max(bounds.width, contentView.frame.width))
    )
    preservesContentWidth = true
    needsLayout = true
    layoutSubtreeIfNeeded()
    updateTransitionViewport()
  }

  /// 展开完成后重新让内容跟随 Host 的实际宽度，后续 divider 拖动和窗口缩放仍实时
  /// 更新 Panel 内容；本方法仅用于仍挂载的 Host。
  func finishFrameTransition() {
    preservesContentWidth = false
    stableContentWidth = bounds.width
    bounds.origin = .zero
    layoutContent()
  }

  /// Panel 卸载时只移除仍归当前 Host 所有的内容。若 refresh 已把同一内容迁移到新
  /// split，这里不能把它从新 Host 再次摘走。
  func detachContentIfOwned() {
    guard contentView.superview === self else { return }
    contentView.frame = NSRect(
      x: 0,
      y: 0,
      width: max(stableContentWidth, contentView.frame.width),
      height: max(bounds.height, contentView.frame.height)
    )
    contentView.removeFromSuperview()
    contentView.translatesAutoresizingMaskIntoConstraints = true
  }

  override func layout() {
    super.layout()
    if !preservesContentWidth { stableContentWidth = bounds.width }
    layoutContent()
    updateTransitionViewport()
  }

  /// Inspector 的 trailing edge 在整个过渡中固定。通过移动 Host 的 bounds viewport
  /// 而不是移动内容根视图，既能从左向右裁剪，又不会让内容内部 Auto Layout 因根视图
  /// 改成 0pt 或负 origin 而重新排版。
  func updateTransitionViewport() {
    guard preservesContentWidth, role == .inspector else {
      bounds.origin = .zero
      return
    }
    bounds.origin.x = max(0, stableContentWidth - bounds.width)
  }

  private func layoutContent() {
    let contentWidth =
      preservesContentWidth
      ? max(stableContentWidth, bounds.width)
      : bounds.width
    contentView.frame = NSRect(
      x: 0,
      y: 0,
      width: contentWidth,
      height: bounds.height
    )
  }
}

/// `WorkspacePanel` 是调用方提供的语义描述；挂载记录额外持有 split 真正布局的根视图。
/// Content 直接参与布局，边缘 Panel 则通过裁剪 Host 参与布局。
@MainActor
struct MountedWorkspacePanel {
  let role: WorkspacePanelRole
  let contentView: NSView
  let layoutView: NSView

  init(_ panel: WorkspacePanel) {
    role = panel.role
    contentView = panel.contentView
    if panel.role == .content {
      layoutView = panel.contentView
    } else {
      layoutView = WorkspaceEdgePanelHostView(
        role: panel.role,
        contentView: panel.contentView
      )
    }
  }

  var edgeHost: WorkspaceEdgePanelHostView? {
    layoutView as? WorkspaceEdgePanelHostView
  }
}
