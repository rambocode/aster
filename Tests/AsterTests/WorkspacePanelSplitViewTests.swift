import AppKit
import AsterCore
import Testing

@testable import Aster

@MainActor
private func makePanelSplitStore() -> WorkspacePanelLayoutStore {
  let suite = "WorkspacePanelSplitViewTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return WorkspacePanelLayoutStore(defaults: defaults, legacySidebarWidth: 220)
}

@Test("三个窗口 Panel 共用一个可拖动布局并保持内容视图身份")
@MainActor
func workspacePanelSplitViewLaysOutThreeSemanticPanels() throws {
  let store = makePanelSplitStore()
  let sidebar = NSView()
  let content = NSView()
  let inspector = NSView()
  let split = WorkspacePanelSplitView(
    panels: [
      WorkspacePanel(role: .sidebar, contentView: sidebar),
      WorkspacePanel(role: .content, contentView: content),
      WorkspacePanel(role: .inspector, contentView: inspector),
    ],
    layoutStore: store
  )
  split.frame = NSRect(x: 0, y: 0, width: 1_180, height: 760)
  split.layoutSubtreeIfNeeded()

  #expect(split.dividerThickness == 1)
  #expect(split.panelRoles == [.sidebar, .content, .inspector])
  #expect(split.panelRole(forDividerAt: 0) == .sidebar)
  #expect(split.panelRole(forDividerAt: 1) == .inspector)
  #expect(abs(sidebar.frame.width - 220) < 0.5)
  #expect(abs(content.frame.width - 680) < 0.5)
  #expect(abs(inspector.frame.width - 278) < 0.5)

  store.setPreferredWidth(300, for: .sidebar)
  split.layoutSubtreeIfNeeded()
  #expect(split.panelContentView(for: .sidebar) === sidebar)
  #expect(split.panelView(for: .content) === content)
  #expect(split.panelContentView(for: .inspector) === inspector)
  #expect(abs(sidebar.frame.width - 300) < 0.5)
}

@Test("窄窗口单击 divider 不把临时压缩宽度覆盖为用户首选值")
@MainActor
func workspacePanelSplitViewCommitsOnlyAnActualDrag() {
  let store = makePanelSplitStore()
  store.setPreferredWidth(360, for: .sidebar)
  store.setPreferredWidth(480, for: .inspector)
  let sidebar = NSView()
  let split = WorkspacePanelSplitView(
    panels: [
      WorkspacePanel(role: .sidebar, contentView: sidebar),
      WorkspacePanel(role: .content, contentView: NSView()),
      WorkspacePanel(role: .inspector, contentView: NSView()),
    ],
    layoutStore: store
  )
  split.frame = NSRect(x: 0, y: 0, width: 820, height: 600)
  split.layoutSubtreeIfNeeded()
  let sidebarPanel = split.panelView(for: .sidebar)!
  let compressedWidth = sidebarPanel.frame.width
  #expect(compressedWidth == 258)

  split.commitUserResize(atDivider: 0, initialWidth: compressedWidth)
  #expect(store.state.sidebarWidth == 360)

  sidebarPanel.frame.size.width = 300
  split.commitUserResize(atDivider: 0, initialWidth: compressedWidth)
  #expect(store.state.sidebarWidth == 300)
}

@Test("Panel divider 双击语义按外侧角色复位而不是按可见索引猜测")
@MainActor
func workspacePanelSplitViewResetsTheOuterPanelForEachDivider() {
  let store = makePanelSplitStore()
  store.setPreferredWidth(340, for: .sidebar)
  store.setPreferredWidth(430, for: .inspector)
  let split = WorkspacePanelSplitView(
    panels: [
      WorkspacePanel(role: .sidebar, contentView: NSView()),
      WorkspacePanel(role: .content, contentView: NSView()),
      WorkspacePanel(role: .inspector, contentView: NSView()),
    ],
    layoutStore: store
  )

  split.resetPanelWidth(atDivider: 0)
  #expect(store.state.sidebarWidth == 220)
  #expect(store.state.inspectorWidth == 430)
  split.resetPanelWidth(atDivider: 1)
  #expect(store.state.inspectorWidth == 278)

  let rightOnly = WorkspacePanelSplitView(
    panels: [
      WorkspacePanel(role: .content, contentView: NSView()),
      WorkspacePanel(role: .inspector, contentView: NSView()),
    ],
    layoutStore: store
  )
  #expect(rightOnly.panelRole(forDividerAt: 0) == .inspector)
}

@Test("Panel divider 的原生命中区与 1pt 可见线严格一致")
@MainActor
func workspacePanelSplitViewDoesNotExpandTheNativeDividerHitArea() {
  let sidebar = NSView()
  let split = WorkspacePanelSplitView(
    panels: [
      WorkspacePanel(role: .sidebar, contentView: sidebar),
      WorkspacePanel(role: .content, contentView: NSView()),
    ],
    layoutStore: makePanelSplitStore()
  )
  let drawn = NSRect(x: 220, y: 0, width: 1, height: 600)
  let proposed = drawn.insetBy(dx: -2, dy: 0)

  let effective = split.splitView(
    split,
    effectiveRect: proposed,
    forDrawnRect: drawn,
    ofDividerAt: 0
  )

  #expect(effective == drawn)

  split.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
  split.layoutSubtreeIfNeeded()
  let dividerX = sidebar.frame.maxX
  #expect(split.hitTest(NSPoint(x: dividerX + 0.5, y: 300)) === split)
  #expect(split.hitTest(NSPoint(x: dividerX - 0.5, y: 300)) !== split)
  #expect(split.hitTest(NSPoint(x: dividerX + 1.5, y: 300)) !== split)
}

@Test("右侧 Panel 显隐复用同一视图且不能通过拖动折叠")
@MainActor
func workspacePanelSplitViewReusesDynamicallyPresentedInspector() {
  let store = makePanelSplitStore()
  let content = NSView()
  let inspector = NSView()
  let split = WorkspacePanelSplitView(
    panels: [WorkspacePanel(role: .content, contentView: content)],
    layoutStore: store
  )
  split.frame = NSRect(x: 0, y: 0, width: 900, height: 600)

  split.insert(
    WorkspacePanel(role: .inspector, contentView: inspector),
    animated: false
  )
  split.layoutSubtreeIfNeeded()
  #expect(split.panelContentView(for: .inspector) === inspector)
  #expect(split.canCollapsePanel(.inspector) == false)

  split.removePanel(.inspector, animated: false)
  #expect(split.panelView(for: .inspector) == nil)
  #expect(inspector.superview == nil)

  split.insert(
    WorkspacePanel(role: .inspector, contentView: inspector),
    animated: false
  )
  #expect(split.panelContentView(for: .inspector) === inspector)
}

@Test("右侧 Panel 的移除动画结束后真正解除挂载")
@MainActor
func workspacePanelSplitViewCompletesAnimatedRemoval() async throws {
  let store = makePanelSplitStore()
  let content = NSView()
  let inspector = NSView()
  let split = WorkspacePanelSplitView(
    panels: [
      WorkspacePanel(role: .content, contentView: content),
      WorkspacePanel(role: .inspector, contentView: inspector),
    ],
    layoutStore: store
  )
  split.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
  split.layoutSubtreeIfNeeded()
  let initialContentWidth = content.frame.width
  let inspectorPanel = split.panelView(for: .inspector)!

  split.removePanel(.inspector, animated: true)

  // 关闭过渡必须直接把整个 Panel frame 收到右边缘，并让 Content 同步接管空间；
  // Inspector 自己保持可见终态，不能先平移/淡出内部内容再瞬间改变布局。
  #expect(inspectorPanel.superview === split)
  #expect(inspectorPanel.frame.width == 0)
  #expect(inspector.superview === inspectorPanel)
  #expect(inspector.frame.width > 0)
  #expect(content.frame.width > initialContentWidth)
  let contentWidthDuringCollapse = content.frame.width
  // 只有正在收起的 Inspector Host 保留显示层动画，不能为了终端
  // 稳定而把用户可见的 Panel 过渡也一起取消。
  #expect(inspectorPanel.layer?.animationKeys()?.isEmpty == false)
  #expect(inspector.alphaValue == 1)
  #expect(CATransform3DIsIdentity(inspector.layer?.transform ?? CATransform3DIdentity))

  try await Task.sleep(for: .milliseconds(300))

  #expect(split.panelView(for: .inspector) == nil)
  #expect(inspector.superview == nil)
  // Content 在过渡开始时已经进入最终宽度；移除临时 divider 不应
  // 再让终端收到第二次 resize，避免关闭动画末帧出现 1pt 跳动。
  #expect(content.frame.width == contentWidthDuringCollapse)
}

@Test("右侧 Panel 收起时不对中央内容做显示层缩放")
@MainActor
func workspacePanelSplitViewDoesNotAnimateContentLayerDuringInspectorRemoval() {
  let content = NSView()
  let split = WorkspacePanelSplitView(
    panels: [
      WorkspacePanel(role: .content, contentView: content),
      WorkspacePanel(role: .inspector, contentView: NSView()),
    ],
    layoutStore: makePanelSplitStore()
  )
  split.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
  split.layoutSubtreeIfNeeded()

  split.removePanel(.inspector, animated: true)

  // 终端位于 Content Panel 内。关闭 Inspector 时 Content 的模型 frame 可以
  // 一次到位，但不能再对 bounds/position 做 Core Animation 插值，否则已经
  // 按新列数重绘的终端网格会被显示层二次拉伸，呈现为抖动和闪烁。
  #expect(content.layer?.animationKeys()?.isEmpty != false)
}

@Test("旧 split 的收起动画不能移除已迁移到新 split 的 Panel")
@MainActor
func workspacePanelSplitViewRemovalDoesNotDetachAReparentedPanel() async throws {
  let store = makePanelSplitStore()
  let inspector = NSView()
  let oldSplit = WorkspacePanelSplitView(
    panels: [
      WorkspacePanel(role: .content, contentView: NSView()),
      WorkspacePanel(role: .inspector, contentView: inspector),
    ],
    layoutStore: store
  )
  oldSplit.frame = NSRect(x: 0, y: 0, width: 900, height: 600)
  oldSplit.layoutSubtreeIfNeeded()
  oldSplit.removePanel(.inspector, animated: true)

  let newSplit = WorkspacePanelSplitView(
    panels: [
      WorkspacePanel(role: .content, contentView: NSView()),
      WorkspacePanel(role: .inspector, contentView: inspector),
    ],
    layoutStore: store
  )
  newSplit.frame = oldSplit.frame
  newSplit.layoutSubtreeIfNeeded()
  try await Task.sleep(for: .milliseconds(300))

  #expect(newSplit.panelContentView(for: .inspector) === inspector)
  #expect(inspector.superview === newSplit.panelView(for: .inspector))
  #expect(inspector.alphaValue == 1)
}

@Test("主窗口把侧栏工作区和详情统一挂载为 Panel")
@MainActor
func workspaceViewControllerUsesPanelLayoutForAllThreeColumns() throws {
  let suite = "WorkspacePanelRootTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorPresented = true
  let store = WorkspacePanelLayoutStore(defaults: defaults, legacySidebarWidth: 220)
  store.setPreferredWidth(300, for: .sidebar)
  store.setPreferredWidth(400, for: .inspector)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(
    model: model,
    preferences: preferences,
    panelLayoutStore: store
  )
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.contentView?.layoutSubtreeIfNeeded()

  let split = try #require(
    controller.view.panelDescendants.compactMap { $0 as? WorkspacePanelSplitView }.first
  )
  #expect(split.panelRoles == [.sidebar, .content, .inspector])
  #expect(abs((split.panelView(for: .sidebar)?.frame.width ?? 0) - 300) < 0.5)
  #expect(abs((split.panelView(for: .inspector)?.frame.width ?? 0) - 400) < 0.5)

  let terminal = try #require(
    controller.view.panelDescendants.compactMap { $0 as? AsterTerminalView }.first
  )
  model.toggleInspector()
  model.toggleInspector()
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(split.panelView(for: .inspector) != nil)
  #expect(controller.view.panelDescendants.contains { $0 === terminal })
}

@Test("顶部标签布局不创建左 Panel 但右 Panel 仍可调宽")
@MainActor
func workspaceViewControllerOmitsSidebarPanelForHorizontalTabs() throws {
  let suite = "WorkspacePanelHorizontalTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  let preferences = AppPreferences(defaults: defaults)
  preferences.tabBarLayout = .top
  preferences.inspectorPresented = true
  let store = WorkspacePanelLayoutStore(defaults: defaults, legacySidebarWidth: 220)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(
    model: model,
    preferences: preferences,
    panelLayoutStore: store
  )
  controller.loadViewIfNeeded()

  let split = try #require(
    controller.view.panelDescendants.compactMap { $0 as? WorkspacePanelSplitView }.first
  )
  #expect(split.panelRoles == [.content, .inspector])
  #expect(split.panelRole(forDividerAt: 0) == .inspector)
}

extension NSView {
  fileprivate var panelDescendants: [NSView] {
    subviews.flatMap { [$0] + $0.panelDescendants }
  }
}
