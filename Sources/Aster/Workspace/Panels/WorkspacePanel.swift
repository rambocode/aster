import AppKit
import AsterCore
import Combine

/// 主窗口中一个可组合的顶层区域。Panel 只描述角色、内容和通用尺寸策略；具体的
/// Sidebar、Workspace 与 Inspector 控制器不需要了解相邻区域如何挂载或拖动。
@MainActor
struct WorkspacePanel {
  let role: WorkspacePanelRole
  let contentView: NSView
}

/// 主窗口 Panel 的唯一横向布局边界。
///
/// 与中栏内部按比例持久化的 `PersistedSplitView` 不同，本类型保存左右 Panel 的 point
/// 宽度。普通窗口缩放只改变实际 frame，不覆盖首选值；只有用户拖 divider、双击复位
/// 或设置页滑杆才会写入 `WorkspacePanelLayoutStore`。
@MainActor
final class WorkspacePanelSplitView: NSSplitView, NSSplitViewDelegate {
  private var panels: [MountedWorkspacePanel]
  private let layoutStore: WorkspacePanelLayoutStore
  /// 左右边栏分隔线直接使用主题详情里的 Sidebar border token。hover 仍切换为 accent，
  /// 但静止态不再对该颜色二次降透明度，否则色板与最终窗口无法逐项对应。
  private(set) var themeDividerColor: NSColor
  private var subscriptions: Set<AnyCancellable> = []
  private var isApplyingPanelFrames = false
  private var isUserResizing = false
  private var hoveredDividerIndex: Int? {
    didSet {
      guard oldValue != hoveredDividerIndex else { return }
      needsDisplay = true
      window?.invalidateCursorRects(for: self)
    }
  }
  private var dividerTrackingAreas: [NSTrackingArea] = []
  private var transitionTokens: [WorkspacePanelRole: Int] = [:]
  /// 收起动画中的边缘 Panel 暂时不参与 NSSplitView 的 arranged 布局，
  /// 但仍作为子视图保留到动画完成。这让剩余 Panel 直接使用合法的
  /// 终态 frame，无需为已折叠的 0pt Panel 预留一条临时 divider。
  private(set) var transitionDetachedPanelRoles: Set<WorkspacePanelRole> = []
  /// 程序化显隐期间由 transition 代码直接动画各 Panel frame。此时必须暂停
  /// NSSplitView 的常规宽度求解，否则一次普通 layout 会把动画中的 frame 拉回首选值。
  private var transitioningPanelRoles: Set<WorkspacePanelRole> = []

  init(
    panels: [WorkspacePanel],
    layoutStore: WorkspacePanelLayoutStore,
    dividerColor: NSColor = AsterTheme.divider
  ) {
    self.panels = Self.sortedPanels(panels).map(MountedWorkspacePanel.init)
    self.layoutStore = layoutStore
    themeDividerColor = dividerColor
    super.init(frame: .zero)
    isVertical = true
    dividerStyle = .thin
    delegate = self
    for panel in self.panels {
      preparePanelViewForOwnership(panel.layoutView)
      addArrangedSubview(panel.layoutView)
    }
    layoutStore.$state
      .dropFirst()
      .sink { [weak self] _ in
        guard let self else { return }
        needsLayout = true
        superview?.needsLayout = true
      }
      .store(in: &subscriptions)
  }

  required init?(coder _: NSCoder) { nil }

  override var dividerThickness: CGFloat {
    CGFloat(WorkspacePanelLayoutPolicy.dividerThickness)
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }

  /// 动态挂载边缘 Panel。相同角色已经处于移除动画时，重新插入会让原视图从当前位置
  /// 返回终态，而不会创建第二份内容或丢失详情页内部状态。
  func insert(_ panel: WorkspacePanel, animated: Bool) {
    if let existing = panels.first(where: { $0.role == panel.role }) {
      if !animated { reattachTransitionPanelIfNeeded(panel.role) }
      let token = beginTransition(for: panel.role, animated: animated)
      guard animated else {
        preparePanelViewForOwnership(existing.layoutView)
        needsLayout = true
        return
      }
      animate(
        existing.layoutView,
        role: panel.role,
        presenting: true,
        startsFromCurrent: true
      ) { [weak self] in
        self?.completePresentation(for: panel.role, token: token)
      }
      return
    }
    let insertionIndex =
      panels.firstIndex {
        Self.order(of: $0.role) > Self.order(of: panel.role)
      } ?? panels.endIndex
    let mountedPanel = MountedWorkspacePanel(panel)
    panels.insert(mountedPanel, at: insertionIndex)
    preparePanelViewForOwnership(mountedPanel.layoutView)
    guard animated else {
      insertArrangedSubview(mountedPanel.layoutView, at: insertionIndex)
      needsLayout = true
      layoutSubtreeIfNeeded()
      updateTrackingAreas()
      return
    }
    // 展开动画与收起动画保持对称：新 Host 先作为普通覆盖层挂载，不能提前加入
    // arrangedSubviews。否则 NSSplitView 会先把 Content 布局到展开终态，动画代码随后
    // 又退回折叠起点，终端会经历多次甚至 0 高度的中间 frame。
    addSubview(mountedPanel.layoutView)
    transitionDetachedPanelRoles.insert(panel.role)
    let token = beginTransition(for: panel.role, animated: true)
    animate(mountedPanel.layoutView, role: panel.role, presenting: true) { [weak self] in
      self?.completePresentation(for: panel.role, token: token)
    }
  }

  /// 移除边缘 Panel。关闭开始时先脱离 arrangedSubview 布局、但保留为同一
  /// split 的动画覆盖层；Content 因此一次进入终态，动画结束后再解除视图挂载。
  func removePanel(
    _ role: WorkspacePanelRole,
    animated: Bool,
    completion: (@MainActor @Sendable () -> Void)? = nil
  ) {
    guard role != .content,
      let index = panels.firstIndex(where: { $0.role == role })
    else {
      completion?()
      return
    }
    let panel = panels[index]
    let token = beginTransition(for: role, animated: animated)
    let finish: @MainActor @Sendable () -> Void = {
      [weak self, weak layoutView = panel.layoutView] in
      guard let self, self.finishTransition(for: role, token: token),
        let current = self.panels.firstIndex(where: { $0.role == role })
      else { return }
      let removedPanel = self.panels.remove(at: current)
      // `refresh()` 可能在动画期间用同一内容视图创建新 split。旧 split 只能清理仍由
      // 自己持有的视图，不能把已经迁移到新布局边界的 Panel 再次移出层级。
      if let layoutView, layoutView.superview === self {
        if self.arrangedSubviews.contains(where: { $0 === layoutView }) {
          self.removeArrangedSubview(layoutView)
        }
        removedPanel.edgeHost?.detachContentIfOwned()
        layoutView.removeFromSuperview()
        self.preparePanelViewForOwnership(layoutView)
      }
      self.transitionDetachedPanelRoles.remove(role)
      self.finishPanelTransitionsIfStable()
      self.needsLayout = true
      self.layoutSubtreeIfNeeded()
      self.updateTrackingAreas()
      completion?()
    }
    guard animated else {
      finish()
      return
    }
    // Inspector 在动画期间仍是 split 的子视图，但不再是 arrangedSubview。
    // 因此 Content 能立即使用“Inspector 已移除”的完整宽度，而右侧
    // Host 仍可以在同一视图层级里被裁剪到 0pt。
    if arrangedSubviews.contains(where: { $0 === panel.layoutView }) {
      removeArrangedSubview(panel.layoutView)
      // macOS 版本间 `removeArrangedSubview` 对普通 subview 所有权的处理并不统一：
      // 有的实现会同时把视图移出层级。收起动画仍需要这个 Host 作为
      // 覆盖层，因此在被移除时立即接回 split，不重建其内容视图。
      if panel.layoutView.superview == nil { addSubview(panel.layoutView) }
      transitionDetachedPanelRoles.insert(role)
    }
    animate(panel.layoutView, role: role, presenting: false, completion: finish)
  }

  func resetPanelWidth(atDivider index: Int) {
    guard let role = panelRole(forDividerAt: index) else { return }
    layoutStore.resetPreferredWidth(for: role)
    needsLayout = true
  }

  override func layout() {
    guard transitioningPanelRoles.isEmpty else { return }
    super.layout()
    guard !isUserResizing else { return }
    applyPreferredPanelFrames()
  }

  override func resizeSubviews(withOldSize oldSize: NSSize) {
    guard !isApplyingPanelFrames, transitioningPanelRoles.isEmpty else { return }
    if isUserResizing {
      super.resizeSubviews(withOldSize: oldSize)
    } else {
      applyPreferredPanelFrames()
    }
  }

  private func applyPreferredPanelFrames() {
    guard !isApplyingPanelFrames, !panels.isEmpty else { return }
    isApplyingPanelFrames = true
    defer { isApplyingPanelFrames = false }
    let widths = WorkspacePanelLayoutPolicy.resolve(
      availableWidth: Double(bounds.width),
      visibleRoles: panelRoles,
      state: layoutStore.state
    )
    var originX: CGFloat = 0
    for (index, panel) in panels.enumerated() {
      let width = CGFloat(widths[panel.role] ?? 0)
      panel.layoutView.frame = NSRect(
        x: originX,
        y: 0,
        width: width,
        height: bounds.height
      )
      panel.layoutView.layoutSubtreeIfNeeded()
      originX += width
      if index < panels.count - 1 { originX += dividerThickness }
    }
    updateDividerFeedbackGeometry()
  }

  override func drawDivider(in rect: NSRect) {
    let index = dividerIndex(containing: NSPoint(x: rect.midX, y: rect.midY))
    let highlighted = index == hoveredDividerIndex && (window?.isKeyWindow ?? false)
    (highlighted ? AsterTheme.accent : themeDividerColor).setFill()
    rect.fill()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    updateDividerFeedbackGeometry()
  }

  private func updateDividerFeedbackGeometry() {
    for area in dividerTrackingAreas { removeTrackingArea(area) }
    dividerTrackingAreas.removeAll()
    for index in 0..<max(0, panels.count - 1) {
      guard let rect = dividerRect(at: index) else { continue }
      let area = NSTrackingArea(
        rect: rect,
        options: [.mouseEnteredAndExited, .activeInKeyWindow],
        owner: self
      )
      addTrackingArea(area)
      dividerTrackingAreas.append(area)
    }
    syncDividerHoverState()
    window?.invalidateCursorRects(for: self)
  }

  override func resetCursorRects() {
    super.resetCursorRects()
    for index in 0..<max(0, panels.count - 1) {
      if let rect = dividerRect(at: index) {
        addCursorRect(rect, cursor: .resizeLeftRight)
      }
    }
  }

  override func mouseEntered(with event: NSEvent) {
    // AppKit 在测试、辅助功能和 responder 转发路径中可能把普通 mouseMoved 事件送到
    // `mouseEntered`；这类事件读取 `trackingArea` 会抛 Objective-C exception。直接按
    // 窗口坐标命中 divider，同时兼容真实 tracking event 与合成事件。
    hoveredDividerIndex = dividerIndex(
      containing: convert(event.locationInWindow, from: nil)
    )
  }

  override func mouseExited(with _: NSEvent) {
    hoveredDividerIndex = nil
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    syncDividerHoverState()
  }

  private func syncDividerHoverState() {
    guard let window, window.isKeyWindow else {
      hoveredDividerIndex = nil
      return
    }
    hoveredDividerIndex = dividerIndex(
      containing: convert(window.mouseLocationOutsideOfEventStream, from: nil)
    )
  }

  private func dividerRect(at index: Int) -> NSRect? {
    guard panels.indices.contains(index), panels.indices.contains(index + 1) else { return nil }
    return NSRect(
      x: panels[index].layoutView.frame.maxX,
      y: 0,
      width: dividerThickness,
      height: bounds.height
    )
  }

  private func dividerIndex(containing point: NSPoint) -> Int? {
    (0..<max(0, panels.count - 1)).first { dividerRect(at: $0)?.contains(point) == true }
  }

  override func mouseDown(with event: NSEvent) {
    let point = convert(event.locationInWindow, from: nil)
    guard let index = dividerIndex(containing: point) else {
      super.mouseDown(with: event)
      return
    }
    if event.clickCount == 2 {
      resetPanelWidth(atDivider: index)
      return
    }
    let initialWidth = panelRole(forDividerAt: index)
      .flatMap { panelView(for: $0)?.frame.width }
    isUserResizing = true
    super.mouseDown(with: event)
    isUserResizing = false
    if let initialWidth {
      commitUserResize(atDivider: index, initialWidth: initialWidth)
    }
    needsLayout = true
  }

  /// 只在原生 divider tracking 确实改变 frame 后保存首选值。窗口缩窄时左右 Panel
  /// 可能被纯布局临时压缩；普通单击若也提交，就会把临时 frame 误当成用户选择。
  func commitUserResize(atDivider index: Int, initialWidth: CGFloat) {
    guard let role = panelRole(forDividerAt: index),
      let view = panelView(for: role)
    else { return }
    let finalWidth = view.frame.width
    guard abs(finalWidth - initialWidth) >= 0.5 else { return }
    layoutStore.setPreferredWidth(Double(finalWidth), for: role)
  }

}

extension WorkspacePanelSplitView {
  var panelRoles: [WorkspacePanelRole] { panels.map(\.role) }
  var panelLayoutState: WorkspacePanelLayoutState { layoutStore.state }

  /// 程序化显隐期间允许目标边缘 Panel 暂时收拢到 0；普通 divider 拖动仍严格遵守
  /// 最小宽度，调用方不能借这个过渡态把 Panel 永久折叠。
  func isPanelTransitioning(_ role: WorkspacePanelRole) -> Bool {
    transitioningPanelRoles.contains(role)
  }

  func panelView(for role: WorkspacePanelRole) -> NSView? {
    panels.first { $0.role == role }?.layoutView
  }

  /// 返回调用方最初提供的内容视图，用于保持控制器和交互状态身份；布局、拖动与过渡
  /// 一律使用 `panelView(for:)` 返回的 Panel 根视图。
  func panelContentView(for role: WorkspacePanelRole) -> NSView? {
    panels.first { $0.role == role }?.contentView
  }

  func panelRole(for view: NSView) -> WorkspacePanelRole? {
    panels.first { $0.layoutView === view || $0.contentView === view }?.role
  }

  /// divider 的可调角色由语义邻居决定，而不是由数组下标硬编码：隐藏左栏后，索引 0
  /// 自然表示 Inspector；只显示左栏时，同一个索引又表示 Sidebar。
  func panelRole(forDividerAt index: Int) -> WorkspacePanelRole? {
    guard panels.indices.contains(index), panels.indices.contains(index + 1) else { return nil }
    if panels[index].role == .sidebar { return .sidebar }
    if panels[index + 1].role == .inspector { return .inspector }
    return nil
  }

  func canCollapsePanel(_: WorkspacePanelRole) -> Bool { false }

  /// 快速反向展开时，收起 completion 会被 token 取消；原 Host 需要重新
  /// 成为 arrangedSubview，否则后续窗口缩放不会再由 NSSplitView 管理它。
  func reattachTransitionPanelIfNeeded(_ role: WorkspacePanelRole) {
    guard transitionDetachedPanelRoles.remove(role) != nil,
      let panelIndex = panels.firstIndex(where: { $0.role == role })
    else { return }
    let layoutView = panels[panelIndex].layoutView
    guard layoutView.superview === self,
      !arrangedSubviews.contains(where: { $0 === layoutView })
    else { return }
    insertArrangedSubview(layoutView, at: min(panelIndex, arrangedSubviews.count))
  }
}

extension WorkspacePanelSplitView {
  /// 递增角色 token 会让旧动画 completion 自动失效。非动画操作同时终止旧 frame
  /// 动画，使快速开关最终只服从最新一次用户意图。
  fileprivate func beginTransition(for role: WorkspacePanelRole, animated: Bool) -> Int {
    transitionTokens[role, default: 0] &+= 1
    if animated {
      transitioningPanelRoles.insert(role)
    } else {
      transitioningPanelRoles.remove(role)
      finishPanelTransitionsIfStable()
    }
    return transitionTokens[role, default: 0]
  }

  @discardableResult
  fileprivate func finishTransition(for role: WorkspacePanelRole, token: Int) -> Bool {
    guard transitionTokens[role] == token else { return false }
    transitioningPanelRoles.remove(role)
    return true
  }

  fileprivate func completePresentation(for role: WorkspacePanelRole, token: Int) {
    guard transitionTokens[role] == token else { return }
    reattachTransitionPanelIfNeeded(role)
    guard finishTransition(for: role, token: token) else { return }
    finishPanelTransitionsIfStable()
    needsLayout = true
    layoutSubtreeIfNeeded()
    updateTrackingAreas()
  }

  fileprivate static func sortedPanels(_ panels: [WorkspacePanel]) -> [WorkspacePanel] {
    // 重复角色没有合法布局语义；只保留调用方给出的第一项，避免两个 Inspector 共用
    // 一个持久化宽度却互相争抢 frame。
    var seen: Set<WorkspacePanelRole> = []
    return panels.filter { seen.insert($0.role).inserted }
      .sorted { order(of: $0.role) < order(of: $1.role) }
  }

  fileprivate static func order(of role: WorkspacePanelRole) -> Int {
    WorkspacePanelRole.allCases.firstIndex(of: role) ?? 0
  }

  /// 多个边缘 Panel 理论上可同时过渡；只有最后一个完成后才能恢复约束转换，否则
  /// 先结束的动画会在另一个动画中途重新锁住所有 frame。
  /// 多个边缘 Panel 理论上可以同时过渡；最后一个完成后再统一恢复 Host 内容布局。
  fileprivate func finishPanelTransitionsIfStable() {
    guard transitioningPanelRoles.isEmpty else { return }
    for panel in panels {
      panel.edgeHost?.finishFrameTransition()
    }
  }
}
