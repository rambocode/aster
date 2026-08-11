import AppKit
import AsterCore
import Combine
import Testing

@testable import Aster

/// 分屏运行态测试统一用独立 UserDefaults suite，避免污染 `.standard` 里的真实工作区快照。
@MainActor
private func makeSplitWorkspace() throws -> (model: AppModel, tab: TerminalTabItem) {
  let suite = "AsterSplitTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  return (model, tab)
}

/// 从快照恢复出一个两面板工作区并完成布局，用于断言真实 frame。
@MainActor
private func makeLaidOutSplitWorkspace(
  axis: SplitAxis,
  tabBarLayout: TabBarLayout
) throws -> WorkspaceViewController {
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  let layout = PaneLayout.split(
    axis: axis,
    first: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: home)),
    second: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: home)),
    ratio: 0.5
  )
  return try makeLaidOutWorkspace(layout: layout, tabBarLayout: tabBarLayout)
}

/// 单面板工作区，用于对照「只有分屏才出现的装饰」。
@MainActor
private func makeLaidOutWorkspace(tabBarLayout: TabBarLayout) throws -> WorkspaceViewController {
  let home = FileManager.default.homeDirectoryForCurrentUser.path
  return try makeLaidOutWorkspace(
    layout: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: home)),
    tabBarLayout: tabBarLayout
  )
}

@MainActor
private func makeLaidOutWorkspace(
  layout: PaneLayout,
  tabBarLayout: TabBarLayout
) throws -> WorkspaceViewController {
  let suite = "AsterSplitLayoutTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)

  let tabSnapshot = WorkspaceTabSnapshot(id: UUID(), title: "split", layout: layout)
  let snapshot = WorkspaceSnapshot(selectedTabID: tabSnapshot.id, tabs: [tabSnapshot])
  defaults.set(try JSONEncoder().encode(snapshot), forKey: "aster.workspace.snapshot.v1")

  let preferences = AppPreferences(defaults: defaults)
  preferences.tabBarLayout = tabBarLayout
  let controller = WorkspaceViewController(
    model: AppModel(defaults: defaults), preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.contentView?.layoutSubtreeIfNeeded()
  return controller
}

@MainActor
private func paneHostViews(in view: NSView) -> [ActivePaneHostView] {
  var found: [ActivePaneHostView] = []
  if let host = view as? ActivePaneHostView { found.append(host) }
  for sub in view.subviews { found += paneHostViews(in: sub) }
  return found
}

@MainActor
private func terminalViews(in view: NSView) -> [NSView] {
  var found: [NSView] = []
  if String(describing: type(of: view)).contains("AsterTerminalView") { found.append(view) }
  for sub in view.subviews { found += terminalViews(in: sub) }
  return found
}

/// 回归：上下分屏曾经整块塌陷成一条分隔条——NSSplitView 给每个面板加了
/// `height == 0 @250` 的回退约束，而纵向链路上没有必需约束把内容区撑开。
@Test(
  "分屏面板在两个方向、两种标签栏布局下都撑满内容区",
  arguments: [SplitAxis.vertical, SplitAxis.horizontal], [TabBarLayout.vertical, TabBarLayout.top]
)
@MainActor
func splitPanesFillContentArea(axis: SplitAxis, tabBarLayout: TabBarLayout) throws {
  let controller = try makeLaidOutSplitWorkspace(axis: axis, tabBarLayout: tabBarLayout)

  let terminals = terminalViews(in: controller.view)
  #expect(terminals.count == 2)
  for terminal in terminals {
    #expect(terminal.frame.width > 300)
    #expect(terminal.frame.height > 200)
  }

  // 0.5 比例：分隔方向上的两块尺寸应该基本相等（差值来自 1pt 分隔条的取整）。
  let sizes = terminals.map { axis == .vertical ? $0.frame.height : $0.frame.width }
  #expect(abs((sizes.first ?? 0) - (sizes.last ?? 0)) <= 2)
}

@Test("拖放落点按四边 25% 判定方向，中心区域表示交换")
@MainActor
func paneDropZonesFollowPointerPosition() {
  let frame = NSRect(x: 100, y: 200, width: 400, height: 300)

  // AppKit 非翻转坐标：靠近 maxY 是「上方」，靠近 minY 是「下方」。
  #expect(PaneDropGeometry.zone(in: frame, at: NSPoint(x: 110, y: 350)).direction == .left)
  #expect(PaneDropGeometry.zone(in: frame, at: NSPoint(x: 490, y: 350)).direction == .right)
  #expect(PaneDropGeometry.zone(in: frame, at: NSPoint(x: 300, y: 490)).direction == .up)
  #expect(PaneDropGeometry.zone(in: frame, at: NSPoint(x: 300, y: 210)).direction == .down)

  let center = PaneDropGeometry.zone(in: frame, at: NSPoint(x: 300, y: 350))
  #expect(center.direction == nil)
  #expect(center.rect == frame)

  // 边缘高亮只覆盖对应的一半区域。
  #expect(
    PaneDropGeometry.zone(in: frame, at: NSPoint(x: 110, y: 350)).rect
      == NSRect(x: 100, y: 200, width: 200, height: 300))
  #expect(
    PaneDropGeometry.zone(in: frame, at: NSPoint(x: 300, y: 490)).rect
      == NSRect(x: 100, y: 350, width: 400, height: 150))
}

@Test("拖放会重排分屏而不重建面板运行态")
@MainActor
func paneDropReordersWithoutRecreatingRuntimes() throws {
  let (model, tab) = try makeSplitWorkspace()
  let left = tab.activePaneID
  model.splitSelectedTab(.right)
  let right = tab.activePaneID
  let leftRuntime = try #require(tab.runtime(for: left))

  model.swapPanes(left, right)
  #expect(tab.layout.firstPaneID == right)
  #expect(tab.runtime(for: left) === leftRuntime)

  model.movePane(right, nextTo: left, direction: .down)
  #expect(tab.layout.node(at: [])?.axis == .vertical)
  #expect(tab.activePaneID == right)
  #expect(tab.runtime(for: left) === leftRuntime)
}

/// 设计要求：同一标签的多个 Pane 中，未聚焦者内容整体朝主题材质褪色（变灰）。
/// 用内容 alpha 而不是颜色遮罩：透明主题的 window 色自带 alpha，
/// `withAlphaComponent` 会把它画成近黑色块；alpha 褪色在任何主题下语义一致，
/// 也不需要额外的点击穿透遮罩视图。
@Test("非聚焦 Pane 内容褪色，焦点切换只做局部翻转")
@MainActor
func inactivePaneContentIsDimmed() throws {
  let (model, tab) = try makeSplitWorkspace()
  model.splitSelectedTab(.right)
  let suite = "AsterSplitDimTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let controller = WorkspaceViewController(
    model: model, preferences: AppPreferences(defaults: defaults))
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.contentView?.layoutSubtreeIfNeeded()
  defer {
    for runtime in tab.runtimes.values { runtime.terminalSession?.stop(immediately: true) }
    window.orderOut(nil)
  }

  let hosts = paneHostViews(in: controller.view)
  #expect(hosts.count == 2)
  // 仍不引入遮罩子视图：内容视图 + 拖动把手 + 关闭按钮。
  for host in hosts {
    #expect(host.subviews.count == 3)
    #expect(
      host.subviews.contains {
        String(describing: type(of: $0)).contains("ClickThroughStripView")
      } == false)
  }
  #expect(hosts.filter(\.isActivePane).count == 1)

  func contentAlpha(of host: ActivePaneHostView) -> CGFloat? {
    host.subviews.first {
      let name = String(describing: type(of: $0))
      return !name.contains("DragHandle") && !name.contains("CloseButton")
    }?.alphaValue
  }

  let activeCandidate = hosts.first { $0.isActivePane }
  let inactiveCandidate = hosts.first { !$0.isActivePane }
  let active = try #require(activeCandidate)
  let inactive = try #require(inactiveCandidate)
  let inactiveAlpha = try #require(contentAlpha(of: inactive))
  #expect(contentAlpha(of: active) == 1)
  #expect(inactiveAlpha < 1)

  // 切换焦点：褪色状态局部翻转，host 实例保持不变（不触发整树重建）。
  tab.setActivePane(inactive.paneID)
  let dimmedAlpha = try #require(contentAlpha(of: active))
  #expect(contentAlpha(of: inactive) == 1)
  #expect(dimmedAlpha < 1)
  let hostsAfter = paneHostViews(in: controller.view)
  #expect(hostsAfter.count == 2)
  #expect(hostsAfter.allSatisfy { after in hosts.contains { $0 === after } })
}

@Test("窗口失去键盘焦点时终端光标停止闪烁并保持形状")
@MainActor
func inactiveWindowStopsCursorBlinking() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
  let terminal = view.getTerminal()
  view.preferredCursorStyle = .blinkBar
  #expect(terminal.options.cursorStyle == .blinkBar)

  view.setWindowActive(false)
  #expect(terminal.options.cursorStyle == .steadyBar)

  view.setWindowActive(true)
  #expect(terminal.options.cursorStyle == .blinkBar)

  // 不闪烁的配置在两种状态下都保持原样。
  view.preferredCursorStyle = .steadyUnderline
  view.setWindowActive(false)
  #expect(terminal.options.cursorStyle == .steadyUnderline)
}

@Test("窗口失去键盘焦点时叠加褪色遮罩且不拦截点击")
@MainActor
func inactiveWindowShowsDimmingOverlay() throws {
  let controller = try makeLaidOutSplitWorkspace(axis: .horizontal, tabBarLayout: .vertical)

  // 测试进程里的窗口不是 key window，等同于「非聚焦」。
  controller.updateWindowActivationOverlay()
  #expect(controller.isShowingInactiveOverlay)

  let overlay = try #require(
    controller.view.subviews.last { String(describing: type(of: $0)).contains("InactiveWindow") })
  #expect(overlay.hitTest(NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)) == nil)
  #expect(overlay.frame.size == controller.view.bounds.size)
}

@Test("终端不显示 SwiftTerm 的 overlay 滚动条")
@MainActor
func terminalHidesOverlayScroller() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))

  let scrollers = view.subviews.compactMap { $0 as? NSScroller }
  let allHidden = scrollers.allSatisfy(\.isHidden)
  #expect(!scrollers.isEmpty)
  #expect(allHidden)
}

@Test("只有存在分屏时才安装顶边拖动把手")
@MainActor
func dragHandleAppearsOnlyWithSplits() throws {
  func handleCount(in view: NSView) -> Int {
    var count = String(describing: type(of: view)).contains("PaneDragHandleView") ? 1 : 0
    for sub in view.subviews { count += handleCount(in: sub) }
    return count
  }

  let split = try makeLaidOutSplitWorkspace(axis: .vertical, tabBarLayout: .vertical)
  #expect(handleCount(in: split.view) == 2)

  let single = try makeLaidOutWorkspace(tabBarLayout: .vertical)
  #expect(handleCount(in: single.view) == 0)
}

@Test("⌘W 在有分屏时只关闭聚焦面板，最后一个面板才关闭标签页")
@MainActor
func closeCommandPrefersFocusedPane() throws {
  let (model, tab) = try makeSplitWorkspace()
  model.splitSelectedTab(.right)
  let focused = tab.activePaneID
  #expect(tab.layout.allPanes.count == 2)

  model.closeSelectedPaneOrTab()

  #expect(model.tabs.count == 1)
  #expect(model.tabs.first === tab)
  #expect(tab.layout.allPanes.count == 1)
  #expect(!tab.layout.allPanes.map(\.id).contains(focused))

  // 只剩一个面板时同一个命令才升级为关闭标签页（工作区至少保留一个标签）。
  model.closeSelectedPaneOrTab()
  #expect(model.tabs.count == 1)
  #expect(model.tabs.first !== tab)
}

@Test("关闭面板后焦点落在相邻面板而不是第一个面板")
@MainActor
func closingPaneMovesFocusToNeighbor() throws {
  let (model, tab) = try makeSplitWorkspace()
  let firstPane = tab.activePaneID
  model.splitSelectedTab(.right)
  let secondPane = tab.activePaneID
  model.splitSelectedTab(.down)
  let thirdPane = tab.activePaneID
  #expect(tab.layout.allPanes.count == 3)

  model.closeActivePane()

  #expect(!tab.layout.allPanes.map(\.id).contains(thirdPane))
  #expect(tab.activePaneID == secondPane)
  #expect(tab.layout.allPanes.map(\.id).contains(firstPane))
}

@Test("方向聚焦与分隔条调整作用于当前分屏树")
@MainActor
func focusAndDividerCommandsUpdateLayout() throws {
  let (model, tab) = try makeSplitWorkspace()
  let leftPane = tab.activePaneID
  model.splitSelectedTab(.right)
  let rightPane = tab.activePaneID

  model.focusPane(.left)
  #expect(tab.activePaneID == leftPane)
  model.focusPane(forward: true)
  #expect(tab.activePaneID == rightPane)

  model.moveDivider(.right)
  let widened = try #require(tab.layout.splitRatio(at: []))
  #expect(abs(widened - 0.55) < 1e-9)

  model.equalizeSplits()
  #expect(tab.layout.splitRatio(at: []) == 0.5)
}

@Test("缩放拆分只对多面板生效，并在继续拆分时自动还原")
@MainActor
func zoomAppliesOnlyToSplitWorkspaces() throws {
  let (model, tab) = try makeSplitWorkspace()

  model.toggleZoomActivePane()
  #expect(tab.zoomedPaneID == nil)

  model.splitSelectedTab(.right)
  model.toggleZoomActivePane()
  #expect(tab.zoomedPaneID == tab.activePaneID)

  model.toggleZoomActivePane()
  #expect(tab.zoomedPaneID == nil)

  model.toggleZoomActivePane()
  model.splitSelectedTab(.down)
  // 新面板若留在放大态之外就是不可见的，拆分必须退出放大。
  #expect(tab.zoomedPaneID == nil)
}

@Test("切换聚焦面板不会触发工作区视图重建")
@MainActor
func focusChangeDoesNotRebuildWorkspace() throws {
  let (model, tab) = try makeSplitWorkspace()
  let firstPane = tab.activePaneID
  model.splitSelectedTab(.right)

  var rebuildCount = 0
  var focusEvents: [UUID] = []
  var subscriptions: Set<AnyCancellable> = []
  tab.objectWillChange.sink { _ in rebuildCount += 1 }.store(in: &subscriptions)
  tab.activePaneChanged.sink { focusEvents.append($0) }.store(in: &subscriptions)

  tab.setActivePane(firstPane)
  // 重复设置同一个面板、或设置不存在的面板都不应该产生事件。
  tab.setActivePane(firstPane)
  tab.setActivePane(UUID())

  #expect(tab.activePaneID == firstPane)
  #expect(focusEvents == [firstPane])
  #expect(rebuildCount == 0)
}
