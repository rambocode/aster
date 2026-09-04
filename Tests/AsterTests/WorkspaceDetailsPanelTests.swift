import AppKit
import AsterCore
import Combine
import Foundation
import Testing

@testable import Aster

@MainActor
private func panelTestDefaults() -> UserDefaults {
  let suite = "AsterDetailsPanelTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

private final class DetailsCancellationProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  var isCancelled: Bool {
    lock.withLock { value }
  }

  func markCancelled() {
    lock.withLock { value = true }
  }
}

@MainActor
private final class FirstResponderRecordingWindow: NSWindow {
  private(set) var requestedResponders: [NSResponder] = []

  override func makeFirstResponder(_ responder: NSResponder?) -> Bool {
    if let responder { requestedResponders.append(responder) }
    return super.makeFirstResponder(responder)
  }
}

@Test("编辑器探测只返回已安装的应用并保持固定顺序")
@MainActor
func editorLocatorReturnsOnlyInstalledEditorsInFixedOrder() {
  let installed: Set<String> = ["dev.zed.Zed", "com.microsoft.VSCode"]
  let editors = WorkspaceEditorLocator.detect { bundleIdentifier in
    installed.contains(bundleIdentifier)
      ? URL(fileURLWithPath: "/Applications/\(bundleIdentifier).app") : nil
  }

  #expect(editors.map(\.name) == ["VS Code", "Zed"])
  #expect(editors.map(\.bundleIdentifier) == ["com.microsoft.VSCode", "dev.zed.Zed"])
  #expect(WorkspaceEditorLocator.detect { _ in nil }.isEmpty)
}

@Test("详情面板显隐与选中页通过 UserDefaults 持久化并夹紧越界值")
@MainActor
func inspectorPreferencesRoundTripThroughDefaults() {
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  #expect(preferences.inspectorPresented == false)
  #expect(preferences.inspectorSection == 0)

  preferences.inspectorPresented = true
  preferences.inspectorSection = 2
  let reloaded = AppPreferences(defaults: defaults)
  #expect(reloaded.inspectorPresented == true)
  #expect(reloaded.inspectorSection == 2)

  // 上界随 History 页加入放宽到 4；越界值仍夹到最后一页而不是回落 Info。
  reloaded.inspectorSection = 9
  #expect(reloaded.inspectorSection == 4)
}

@Test("详情面板显隐复用同一颗固定位置图标")
@MainActor
func inspectorToggleKeepsIdenticalPositionAcrossPresentation() throws {
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorPresented = false
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.contentView?.layoutSubtreeIfNeeded()

  let toggle = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == "workspace-inspector-toggle" })
  let collapsedFrame = toggle.convert(toggle.bounds, to: nil)

  model.toggleInspector()
  window.contentView?.layoutSubtreeIfNeeded()

  let expandedToggle = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == "workspace-inspector-toggle" })
  let expandedFrame = expandedToggle.convert(expandedToggle.bounds, to: nil)
  // 同一个根视图覆盖按钮不参与 Panel 宽度求解，展开前后的实例和窗口坐标都不变。
  #expect(expandedToggle === toggle)
  #expect(abs(collapsedFrame.midX - expandedFrame.midX) < 0.5)
  #expect(abs(collapsedFrame.midY - expandedFrame.midY) < 0.5)
  #expect(collapsedFrame.size == expandedFrame.size)
  #expect(expandedToggle.isHidden == false)
  #expect(
    controller.view.allDescendants.contains {
      $0.identifier?.rawValue == "details-panel-close"
    } == false)
}

@Test("展开详情面板走 Panel 裁剪动画，布局与终端宽度一次到位")
@MainActor
func inspectorPresentationAnimatesWithoutRelayoutingTerminalEachFrame() async throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorPresented = false
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.makeKeyAndOrderFront(nil)
  defer { window.orderOut(nil) }
  window.contentView?.layoutSubtreeIfNeeded()
  try await Task.sleep(for: .milliseconds(50))
  window.contentView?.layoutSubtreeIfNeeded()

  let terminal = try #require(
    controller.view.allDescendants.compactMap { $0 as? AsterTerminalView }.first)
  let initialTerminalWidth = terminal.frame.width
  var gridSizes: [(columns: Int, rows: Int)] = []
  terminal.onGridSizeChange = { columns, rows in
    gridSizes.append((columns, rows))
  }

  model.toggleInspector()
  window.contentView?.layoutSubtreeIfNeeded()

  let split = try #require(inspectorSplit(in: controller.view))
  let panel = try #require(split.panelView(for: .inspector))
  let expectedWidth = controller.panelLayoutStore.state.inspectorWidth
  // 模型 frame 在动画开始时就进入终态，Core Animation 只插值 Panel Host 的显示层；
  // 终端因此只收到一次 resize，不会在 0.18 秒里反复发送 TIOCSWINSZ。
  #expect(abs(panel.frame.width - expectedWidth) < 0.5)
  let workspace = try #require(split.panelView(for: .content))
  let sidebarWidth = split.panelView(for: .sidebar)?.frame.width ?? 0
  let dividerCount = CGFloat(split.panelRoles.count - 1)
  // 终端一侧同样一次让位：标题栏（与终端同宽）已经缩到扣掉面板与分隔线后的宽度。
  #expect(
    abs(
      workspace.frame.width
        - (split.frame.width - sidebarWidth - expectedWidth - dividerCount)
    ) < 1
  )
  #expect(panel.wantsLayer)
  try await Task.sleep(for: .milliseconds(250))
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(terminal.frame.width < initialTerminalWidth)
  // 展开只能把终端从收起态宽度直接切到展开态宽度。若先布局到终态、再退回
  // 折叠动画起点、最后再次进入终态，这里会记录三次网格变化，TUI 的 SIGWINCH
  // 重绘就会作为真实内容重复进入缓冲区。
  #expect(gridSizes.count == 1)
}

@Test("重复开关详情面板不复制终端缓冲区内容")
@MainActor
func repeatedInspectorTransitionsKeepOneTerminalReflowPerToggle() async throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorPresented = false
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }

  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.makeKeyAndOrderFront(nil)
  defer { window.orderOut(nil) }
  window.contentView?.layoutSubtreeIfNeeded()
  try await Task.sleep(for: .milliseconds(50))
  window.contentView?.layoutSubtreeIfNeeded()

  let terminal = try #require(
    controller.view.allDescendants.compactMap { $0 as? AsterTerminalView }.first)
  let session = try #require(model.selectedTab?.activeSession)
  let sentinel = "ASTER_PANEL_REFLOW_SENTINEL"
  terminal.dataReceived(slice: Array("\r\n\(sentinel)\r\n".utf8)[...])
  let occurrencesBefore = session.textSnapshot().lines.filter { $0.contains(sentinel) }.count
  var gridSizes: [(columns: Int, rows: Int)] = []
  terminal.onGridSizeChange = { columns, rows in gridSizes.append((columns, rows)) }

  for _ in 0..<3 {
    let beforePresentation = gridSizes.count
    model.toggleInspector()
    try await Task.sleep(for: .milliseconds(250))
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(gridSizes.count - beforePresentation == 1)

    let beforeRemoval = gridSizes.count
    model.toggleInspector()
    try await Task.sleep(for: .milliseconds(250))
    window.contentView?.layoutSubtreeIfNeeded()
    #expect(gridSizes.count - beforeRemoval == 1)
  }

  let currentTerminal = try #require(
    controller.view.allDescendants.compactMap { $0 as? AsterTerminalView }.first)
  let occurrencesAfter = session.textSnapshot().lines.filter { $0.contains(sentinel) }.count
  #expect(currentTerminal === terminal)
  #expect(occurrencesBefore == 1)
  #expect(occurrencesAfter == occurrencesBefore)
  #expect(gridSizes.count == 6)
  #expect(Set(gridSizes.map(\.columns)).count == 2)
}

@Test("关闭详情面板不对终端子树做 frame 动画")
@MainActor
func inspectorRemovalDoesNotAnimateTerminalViewTree() throws {
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorPresented = true
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }

  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.contentView?.layoutSubtreeIfNeeded()

  let split = try #require(inspectorSplit(in: controller.view))
  let content = try #require(split.panelView(for: .content))
  let terminal = try #require(
    content.allDescendants.compactMap { $0 as? AsterTerminalView }.first)
  var gridSizes: [(columns: Int, rows: Int)] = []
  terminal.onGridSizeChange = { columns, rows in
    gridSizes.append((columns, rows))
  }

  model.toggleInspector()
  window.contentView?.layoutSubtreeIfNeeded()

  let frameAnimationKeys: Set<String> = ["bounds", "position"]
  let animatedViews = ([content] + content.allDescendants).filter { view in
    guard view === terminal || view.isDescendant(of: terminal) || terminal.isDescendant(of: view)
    else { return false }
    return !(Set(view.layer?.animationKeys() ?? []).isDisjoint(with: frameAnimationKeys))
  }
  // 根 Content 没有动画仍不够：如果 Auto Layout 在外层 NSAnimationContext
  // 内延迟刷新终端子树，容器或终端 layer 仍会被二次拉伸。
  #expect(animatedViews.isEmpty)
  // 一次显隐只能把终端网格直接切到最终列数。重复通知意味着 NSSplitView 的中间
  // frame 泄漏进 SwiftTerm，会让 TUI 连续清屏、reflow，用户看到的就是抖动闪烁。
  #expect(gridSizes.count <= 1)
}

@Test("面板显隐始终保留唯一切换入口并呈现五个页签 chip")
@MainActor
func workspaceHeaderRevealsInspectorToggleAndPanelChips() {
  let collapsedDefaults = panelTestDefaults()
  let collapsedPreferences = AppPreferences(defaults: collapsedDefaults)
  let collapsedModel = AppModel(defaults: collapsedDefaults)
  collapsedModel.ensureInitialTab()
  let collapsedController = WorkspaceViewController(
    model: collapsedModel, preferences: collapsedPreferences)
  collapsedController.loadViewIfNeeded()

  let collapsedIdentifiers = collapsedController.view.allDescendants
    .compactMap { $0.identifier?.rawValue }
  #expect(collapsedIdentifiers.contains("workspace-inspector-toggle"))
  let toggle = collapsedController.view.allDescendants.compactMap { $0 as? NSButton }
    .first { $0.identifier?.rawValue == "workspace-inspector-toggle" }
  // 收起态保留同一入口和固定布局槽位，但没有标题栏悬停时不显示。
  #expect(toggle?.isHidden == true)

  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorPresented = true
  preferences.inspectorSection = 1
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()

  let identifiers = controller.view.allDescendants.compactMap { $0.identifier?.rawValue }
  // 面板展开后仍由根视图上的唯一入口负责关闭，Panel header 不再创建第二颗按钮。
  let expandedToggle = controller.view.allDescendants.compactMap { $0 as? NSButton }
    .first { $0.identifier?.rawValue == "workspace-inspector-toggle" }
  #expect(expandedToggle?.isHidden == false)
  #expect(identifiers.contains("details-panel-close") == false)
  for chip in [
    "details-chip-info",
    "details-chip-outline",
    "details-chip-git",
    "details-chip-files",
    "details-chip-history",
  ] {
    #expect(identifiers.contains(chip))
  }
  // 持久化的选中页应反映为对应 chip 的选中态标题。
  let outlineChip = controller.view.allDescendants.compactMap { $0 as? NSButton }
    .first { $0.identifier?.rawValue == "details-chip-outline" }
  #expect(outlineChip?.title.contains("Outline") == true)
  // 大列表页改用原生虚拟化表格；普通 stack 页仍使用左上原点翻转文档。
  let panelScrolls = controller.view.allDescendants.compactMap { $0 as? NSScrollView }
  #expect(
    panelScrolls.contains {
      $0.documentView is FlippedDocumentView || $0.documentView is NSTableView
    })
}

@Test("Inspector 单一按钮关闭后延迟隐藏并跟随标题栏悬停")
@MainActor
func inspectorToggleDoesNotFlashDuringPanelCollapse() async throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorPresented = true
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }

  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.makeKeyAndOrderFront(nil)
  defer { window.orderOut(nil) }
  window.contentView?.layoutSubtreeIfNeeded()

  let toggle = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == "workspace-inspector-toggle" })
  let currentSplit = try #require(inspectorSplit(in: controller.view))
  #expect(toggle.isHidden == false)
  let frameBeforeCollapse = toggle.convert(toggle.bounds, to: nil)

  model.toggleInspector()
  window.contentView?.layoutSubtreeIfNeeded()

  // 点击关闭只改变同一实例的显示策略；它不离开根视图，也不改变坐标。
  #expect(toggle.isHidden == false)
  let frameDuringCollapse = toggle.convert(toggle.bounds, to: nil)
  #expect(abs(frameBeforeCollapse.midX - frameDuringCollapse.midX) < 0.5)
  #expect(abs(frameBeforeCollapse.midY - frameDuringCollapse.midY) < 0.5)
  #expect(frameBeforeCollapse.size == frameDuringCollapse.size)
  #expect(toggle.window === window)
  let content = try #require(currentSplit.panelView(for: .content))
  let inspector = try #require(currentSplit.panelView(for: .inspector))
  #expect(inspector.frame.width == 0)
  #expect(content.frame.maxX <= inspector.frame.minX)
  try await Task.sleep(for: .milliseconds(300))
  let collapsedToggle = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == "workspace-inspector-toggle" })
  let collapsedTitlebar = try #require(
    controller.view.allDescendants.first {
      $0.identifier?.rawValue == "workspace-titlebar"
    })
  // Panel 解除挂载后仍是同一实例；即使鼠标已经离开，也要短暂停留再淡出。
  #expect(collapsedToggle === toggle)
  #expect(collapsedToggle.isHidden == false)
  #expect(currentSplit.panelView(for: .inspector) == nil)

  let exit = try #require(
    NSEvent.mouseEvent(
      with: .mouseMoved,
      location: NSPoint(x: -20, y: -20),
      modifierFlags: [],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: 0,
      clickCount: 0,
      pressure: 0
    ))
  controller.mouseMoved(with: exit)
  #expect(collapsedToggle.isHidden == false)
  try await Task.sleep(for: .milliseconds(800))
  #expect(collapsedToggle.isHidden)

  let hoverLocation = collapsedTitlebar.convert(
    NSPoint(x: collapsedTitlebar.bounds.midX, y: collapsedTitlebar.bounds.midY),
    to: nil
  )
  let hover = try #require(
    NSEvent.mouseEvent(
      with: .mouseMoved,
      location: hoverLocation,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: 0,
      clickCount: 0,
      pressure: 0
    ))
  controller.mouseMoved(with: hover)
  #expect(collapsedToggle.isHidden == false)

  let secondExit = try #require(
    NSEvent.mouseEvent(
      with: .mouseMoved,
      location: NSPoint(x: -20, y: -20),
      modifierFlags: [],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: 0,
      clickCount: 0,
      pressure: 0
    ))
  controller.mouseMoved(with: secondExit)
  try await Task.sleep(for: .milliseconds(200))
  #expect(collapsedToggle.isHidden)
}

@Test("切换详情面板显隐会写回偏好，下次启动恢复")
@MainActor
func togglingInspectorPersistsPresentationState() {
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()

  model.toggleInspector()
  #expect(preferences.inspectorPresented == true)
  model.toggleInspector()
  #expect(preferences.inspectorPresented == false)
}

@Test("详情面板显隐只更新内容区且保留终端与侧栏视图")
@MainActor
func togglingInspectorDoesNotRebuildWorkspaceViews() async throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }

  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.contentView?.layoutSubtreeIfNeeded()

  let terminal = try #require(
    controller.view.allDescendants.compactMap { $0 as? AsterTerminalView }.first)
  let tabsLabel = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTextField }
      .first { $0.stringValue == "TABS" })
  #expect(window.makeFirstResponder(terminal))

  model.toggleInspector()
  window.contentView?.layoutSubtreeIfNeeded()

  #expect(controller.view.allDescendants.contains { $0 === terminal })
  #expect(controller.view.allDescendants.contains { $0 === tabsLabel })
  #expect(window.firstResponder === terminal)
  let details = try #require(
    controller.children.compactMap { $0 as? DetailsPanelViewController }.first)

  model.toggleInspector()
  model.toggleInspector()
  window.contentView?.layoutSubtreeIfNeeded()
  let split = try #require(inspectorSplit(in: controller.view))
  let inspector = try #require(split.panelContentView(for: .inspector))

  #expect(controller.view.allDescendants.contains { $0 === terminal })
  #expect(controller.view.allDescendants.contains { $0 === tabsLabel })
  #expect(controller.children.contains { $0 === details })
  #expect(window.firstResponder === terminal)

  // 等待超过显隐动画时长，再确认被 transition token 判定为过期的收起 completion
  // 没有延迟移除刚重新展开的同一视图。终端启动事件可能在等待期间触发一次正常
  // 工作区刷新，因此以当前 split 验证所有权，同时要求 Inspector 内容身份保持不变。
  try await Task.sleep(for: .milliseconds(300))
  let currentSplit = try #require(inspectorSplit(in: controller.view))
  #expect(currentSplit.panelContentView(for: .inspector) === inspector)
  #expect(inspector.superview === currentSplit.panelView(for: .inspector))
  #expect(inspector.alphaValue == 1)
  #expect(CATransform3DIsIdentity(inspector.layer?.transform ?? CATransform3DIdentity))
}

@Test("从 Inspector 搜索框收起详情后把输入焦点交还活动 Pane")
@MainActor
func collapsingInspectorRestoresFocusFromItsSearchField() async throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorPresented = true
  preferences.inspectorSection = 3
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }

  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.contentView?.layoutSubtreeIfNeeded()

  let terminal = try #require(
    controller.view.allDescendants.compactMap { $0 as? AsterTerminalView }.first)
  let search = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSSearchField }.first)
  #expect(window.makeFirstResponder(search))
  search.selectText(nil)
  let fieldEditor = try #require(window.fieldEditor(false, for: search))
  #expect(window.firstResponder === fieldEditor)

  model.toggleInspector()
  try await Task.sleep(for: .milliseconds(300))

  #expect(window.firstResponder === terminal)
}

@Test("Files 搜索使用稳定搜索框与虚拟化表格")
@MainActor
func filesSearchKeepsInputViewAndUsesVirtualizedRows() throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 3
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }
  let controller = DetailsPanelViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()

  let search = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSSearchField }.first)
  search.stringValue = "Sources"
  controller.controlTextDidChange(
    Notification(name: NSControl.textDidChangeNotification, object: search))

  let currentSearch = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSSearchField }.first)
  let filesTable = controller.view.allDescendants.compactMap { $0 as? NSTableView }
    .first { $0.identifier?.rawValue == "details-files-table" }
  #expect(currentSearch === search)
  #expect(filesTable != nil)
}

@Test("Files 显示隐藏文件开关会带着 includeHidden 重新枚举")
@MainActor
func filesShowHiddenToggleReenumeratesWithFlag() async throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 3
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.stop(immediately: true) }
  var includeHiddenFlags: [Bool] = []
  let client = WorkspaceInspectionClient(
    information: { _ in WorkspaceInformationSnapshot(processes: [], listeningPorts: []) },
    git: { _ in GitStatusSummary() },
    files: { _, includeHidden in
      includeHiddenFlags.append(includeHidden)
      if includeHidden {
        return [
          WorkspaceFileNode(path: "/tmp/.gitignore", name: ".gitignore", depth: 0, isDirectory: false),
          WorkspaceFileNode(path: "/tmp/README.md", name: "README.md", depth: 0, isDirectory: false),
        ]
      }
      return [
        WorkspaceFileNode(path: "/tmp/README.md", name: "README.md", depth: 0, isDirectory: false)
      ]
    }
  )
  let controller = DetailsPanelViewController(
    model: model, preferences: preferences, inspectionClient: client)
  controller.loadViewIfNeeded()
  await Task.yield()
  await Task.yield()

  let table = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTableView }
      .first { $0.identifier?.rawValue == "details-files-table" })
  #expect(table.numberOfRows == 1)
  #expect(includeHiddenFlags == [false])

  let toggle = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == "details-files-show-hidden" })
  #expect(toggle.toolTip == "包含隐藏文件")
  toggle.performClick(nil)
  await Task.yield()
  await Task.yield()

  #expect(includeHiddenFlags == [false, true])
  #expect(table.numberOfRows == 2)
  #expect(toggle.toolTip == "不包含隐藏文件")
}

@Test("Files 首次加载默认收起目录并只投影顶层行")
@MainActor
func filesInitiallyCollapsesDirectories() async throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 3
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.stop(immediately: true) }
  let nodes = [
    WorkspaceFileNode(path: "/tmp/Sources", name: "Sources", depth: 0, isDirectory: true),
    WorkspaceFileNode(path: "/tmp/Sources/main.swift", name: "main.swift", depth: 1, isDirectory: false),
    WorkspaceFileNode(path: "/tmp/README.md", name: "README.md", depth: 0, isDirectory: false),
  ]
  let client = WorkspaceInspectionClient(
    information: { _ in WorkspaceInformationSnapshot(processes: [], listeningPorts: []) },
    git: { _ in GitStatusSummary() },
    files: { _, _ in nodes }
  )
  let controller = DetailsPanelViewController(
    model: model, preferences: preferences, inspectionClient: client)
  controller.loadViewIfNeeded()
  await Task.yield()
  await Task.yield()

  let table = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTableView }
      .first { $0.identifier?.rawValue == "details-files-table" })
  #expect(table.numberOfRows == 2)

  let directoryCell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
  let disclosure = try #require(
    directoryCell.allDescendants.compactMap { $0 as? NSButton }.first)
  disclosure.performClick(nil)
  #expect(table.numberOfRows == 3)
}

@Test("Files 右键菜单严格匹配资源动作且目录展开只由树内入口负责")
@MainActor
func filesContextMenuItemsAndDirectoryExpandStayInTree() async throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 3
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.stop(immediately: true) }
  let nodes = [
    WorkspaceFileNode(path: "/tmp/Sources", name: "Sources", depth: 0, isDirectory: true),
    WorkspaceFileNode(path: "/tmp/Sources/main.swift", name: "main.swift", depth: 1, isDirectory: false),
    WorkspaceFileNode(path: "/tmp/README.md", name: "README.md", depth: 0, isDirectory: false),
  ]
  let client = WorkspaceInspectionClient(
    information: { _ in WorkspaceInformationSnapshot(processes: [], listeningPorts: []) },
    git: { _ in GitStatusSummary() },
    files: { _, _ in nodes }
  )
  let controller = DetailsPanelViewController(
    model: model, preferences: preferences, inspectionClient: client)
  controller.loadViewIfNeeded()
  await Task.yield()
  await Task.yield()

  let table = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTableView }
      .first { $0.identifier?.rawValue == "details-files-table" })
  let menu = try #require(table.menu)
  #expect(table.numberOfRows == 2)

  // 顶层排序：目录优先 → Sources (0), README.md (1)
  table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
  controller.menuWillOpen(menu)
  let fileTitles = menu.items.map(\.title)
  #expect(fileTitles == [
    "Open", "Open in Aster", "", "New File…", "New Folder…", "Rename…",
    "Move to Trash", "", "Copy Path", "Copy Relative Path", "Reveal in Finder",
  ])
  let openInAsterItem = try #require(menu.items.first { $0.title == "Open in Aster" })
  let openInAster = try #require(openInAsterItem.submenu)
  let asterTitles = openInAster.items.map { $0.title }
  #expect(asterTitles == [
    "Current Pane", "", "New Tab", "", "New Window", "", "Split Right",
    "Split Left", "Split Top", "Split Bottom",
  ])

  table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
  controller.menuWillOpen(menu)
  let directoryTitles = menu.items.map(\.title)
  #expect(directoryTitles == fileTitles)
  #expect(table.numberOfRows == 2)
  let kinds = model.selectedTab?.runtimes.values.map(\.descriptor.kind) ?? []
  #expect(!kinds.contains(.fileBrowser))

  // 目录展开仍通过 chevron 完成，右键菜单不再混入树结构动作。
  let directoryCell = try #require(table.view(atColumn: 0, row: 0, makeIfNecessary: true))
  let disclosure = try #require(
    directoryCell.allDescendants.compactMap { $0 as? NSButton }.first)
  disclosure.performClick(nil)
  #expect(table.numberOfRows == 3)
}

@Test("Git 变更使用虚拟化表格")
@MainActor
func gitChangesUseVirtualizedRows() throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 2
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }
  let controller = DetailsPanelViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()

  let gitTable = controller.view.allDescendants.compactMap { $0 as? NSTableView }
    .first { $0.identifier?.rawValue == "details-git-table" }
  #expect(gitTable != nil)
}

/// Git 页交互测试共享的夹具：固定一条未暂存变更、可注入的编辑器列表与 diff 文本，
/// 面板挂在真实窗口里，行内动作与 diff 浮层才有 `view.window` 可用。
@MainActor
private func makeGitPanelFixture(
  editors: [DetectedEditor] = [],
  diff: String = "",
  editorOpener: @escaping @MainActor ([URL], DetectedEditor) -> Void = { _, _ in }
) -> (controller: DetailsPanelViewController, model: AppModel, window: NSWindow) {
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 2
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let status = GitStatusSummary(
    branch: "master",
    objectID: "abc1234",
    changes: [GitChange(path: "Sources/Aster/AppModel.swift", status: ".M")],
    diffStat: GitDiffStat(filesChanged: 1, insertions: 925, deletions: 237)
  )
  let client = WorkspaceInspectionClient(
    information: { _ in WorkspaceInformationSnapshot(processes: [], listeningPorts: []) },
    git: { _ in status },
    files: { _, _ in [] },
    diff: { _, _, _ in diff }
  )
  let controller = DetailsPanelViewController(
    model: model,
    preferences: preferences,
    inspectionClient: client,
    editorLocator: { editors },
    editorOpener: editorOpener
  )
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
    styleMask: [.titled, .resizable],
    backing: .buffered,
    defer: false
  )
  // 详情面板在真实窗口里只占右侧 278pt；diff 气泡要贴着它的左缘展开，因此夹具必须
  // 保留左侧空间，不能把面板当成整个 contentView。
  let host = NSView()
  window.contentView = host
  controller.loadViewIfNeeded()
  host.addSubview(controller.view)
  controller.view.translatesAutoresizingMaskIntoConstraints = false
  NSLayoutConstraint.activate([
    controller.view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
    controller.view.topAnchor.constraint(equalTo: host.topAnchor),
    controller.view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
    controller.view.widthAnchor.constraint(equalToConstant: 278),
  ])
  host.layoutSubtreeIfNeeded()
  return (controller, model, window)
}

@MainActor
private func gitRowCell(in controller: DetailsPanelViewController, row: Int) throws -> NSView {
  let table = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTableView }
      .first { $0.identifier?.rawValue == "details-git-table" })
  return try #require(table.view(atColumn: 0, row: row, makeIfNecessary: true))
}

@MainActor
private func button(_ identifier: String, in view: NSView) throws -> NSButton {
  try #require(
    view.allDescendants.compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == identifier })
}

@Test("Commit 下拉提供 Push/Pull/Fetch 与需要分支名的 Merge/Rebase")
@MainActor
func gitCommitMenuOffersRemoteAndBranchOperations() async throws {
  _ = NSApplication.shared
  let fixture = makeGitPanelFixture()
  defer { fixture.model.selectedTab?.stop(immediately: true) }
  await Task.yield()
  await Task.yield()

  let menu = fixture.controller.makeGitOperationsMenu()
  #expect(menu.items.map(\.title) == ["Push", "Pull", "Fetch", "", "Merge…", "Rebase…"])
  #expect(menu.items[3].isSeparatorItem)
  // Commit 主按钮与下拉箭头共享一个圆角背景，不再各画一块独立 bezel。
  let commit = try #require(
    fixture.controller.view.allDescendants.compactMap { $0 as? SplitActionButton }
      .first { $0.identifier?.rawValue == "details-git-commit" })
  #expect(commit.primaryButton.title == "Commit")
  #expect(commit.isHidden == false)
  #expect(commit.spacing == 0)
  #expect(commit.primaryButton.isBordered == false)
  #expect(commit.arrowButton.isBordered == false)
  #expect(commit.layer?.cornerRadius == 7)
}

@Test("Git 页编辑器入口使用偏好的已安装编辑器并可切换")
@MainActor
func gitEditorButtonUsesPreferredInstalledEditor() async throws {
  _ = NSApplication.shared
  let editors = [
    DetectedEditor(
      name: "VS Code", bundleIdentifier: "com.microsoft.VSCode",
      appURL: URL(fileURLWithPath: "/Applications/VSCode.app")),
    DetectedEditor(
      name: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92",
      appURL: URL(fileURLWithPath: "/Applications/Cursor.app")),
  ]
  var openedEditor: DetectedEditor?
  var openedURLs: [URL] = []
  let fixture = makeGitPanelFixture(editors: editors) { urls, editor in
    openedURLs = urls
    openedEditor = editor
  }
  defer { fixture.model.selectedTab?.stop(immediately: true) }
  await Task.yield()
  await Task.yield()

  let editorButton = try #require(
    fixture.controller.view.allDescendants.compactMap { $0 as? SplitActionButton }
      .first { $0.identifier?.rawValue == "details-git-editor" })
  // 没有保存过偏好时回落到探测顺序的第一项。
  #expect(editorButton.primaryButton.title == "VS Code")
  #expect(editorButton.isHidden == false)

  let menu = fixture.controller.makeEditorMenu()
  #expect(menu.items.map(\.title) == ["VS Code", "Cursor"])
  #expect(menu.items[0].state == .on)
  let cursor = menu.items[1]
  _ = cursor.target?.perform(cursor.action, with: cursor)

  #expect(editorButton.primaryButton.title == "Cursor")
  #expect(fixture.controller.makeEditorMenu().items[1].state == .on)
  #expect(openedEditor?.bundleIdentifier == "com.todesktop.230313mzl4w4u92")
  #expect(openedURLs == [URL(fileURLWithPath: fixture.model.selectedTab?.workingDirectory ?? "")])
}

@Test("Git 变更行悬停才显示暂存、编辑器与预览三个动作")
@MainActor
func gitChangeRowRevealsActionsOnHover() async throws {
  _ = NSApplication.shared
  let editors = [
    DetectedEditor(
      name: "Cursor", bundleIdentifier: "com.todesktop.230313mzl4w4u92",
      appURL: URL(fileURLWithPath: "/Applications/Cursor.app"))
  ]
  let fixture = makeGitPanelFixture(editors: editors)
  defer { fixture.model.selectedTab?.stop(immediately: true) }
  await Task.yield()
  await Task.yield()

  // row 0 是 Unstaged 分组标题，row 1 才是变更行。
  let cell = try gitRowCell(in: fixture.controller, row: 1)
  let stage = try button("details-git-row-stage", in: cell)
  let editor = try button("details-git-row-editor", in: cell)
  let preview = try button("details-git-row-preview", in: cell)
  #expect(stage.isHidden)
  #expect(editor.isHidden)
  #expect(preview.isHidden)

  let entered = try #require(
    NSEvent.enterExitEvent(
      with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
      userData: nil))
  cell.mouseEntered(with: entered)

  #expect(!stage.isHidden)
  #expect(!editor.isHidden)
  #expect(!preview.isHidden)
  #expect(stage.toolTip?.contains("git add") == true)
  #expect(editor.toolTip == "在 Cursor 中打开")

  // 悬停整行会加底色：无边框图标本身没有指针反馈，行必须自己给出「这里可以点」的提示。
  let rowBackground = try #require(
    cell.subviews.first { $0.layer?.cornerRadius == 5 && !($0 is NSButton) })
  #expect(!rowBackground.isHidden)
  #expect((rowBackground.layer?.backgroundColor?.alpha ?? 0) > 0)
  // 行内图标各自也有悬停底色，静息态保持透明。
  #expect((stage.layer?.backgroundColor?.alpha ?? 0) == 0)
  let insideStage = NSPoint(x: stage.bounds.midX, y: stage.bounds.midY)
  stage.mouseEntered(
    with: try #require(
      NSEvent.enterExitEvent(
        with: .mouseEntered, location: stage.convert(insideStage, to: nil), modifierFlags: [],
        timestamp: 0, windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0,
        trackingNumber: 0, userData: nil)))
  #expect((stage.layer?.backgroundColor?.alpha ?? 0) > 0)

  let exited = try #require(
    NSEvent.enterExitEvent(
      with: .mouseExited, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
      userData: nil))
  cell.mouseExited(with: exited)
  #expect(stage.isHidden)
  #expect(rowBackground.isHidden)
  // 图标隐藏时收不到 mouseExited，重新显示不能残留上一次的悬停底色。
  #expect((stage.layer?.backgroundColor?.alpha ?? 0) == 0)
}

@Test("未探测到编辑器时变更行不显示编辑器入口")
@MainActor
func gitChangeRowHidesEditorActionWithoutInstalledEditor() async throws {
  _ = NSApplication.shared
  let fixture = makeGitPanelFixture()
  defer { fixture.model.selectedTab?.stop(immediately: true) }
  await Task.yield()
  await Task.yield()

  let cell = try gitRowCell(in: fixture.controller, row: 1)
  let entered = try #require(
    NSEvent.enterExitEvent(
      with: .mouseEntered, location: .zero, modifierFlags: [], timestamp: 0,
      windowNumber: fixture.window.windowNumber, context: nil, eventNumber: 0, trackingNumber: 0,
      userData: nil))
  cell.mouseEntered(with: entered)

  #expect(try button("details-git-row-editor", in: cell).isHidden)
  #expect(try !button("details-git-row-preview", in: cell).isHidden)
  let editorButton = fixture.controller.view.allDescendants.compactMap { $0 as? SplitActionButton }
    .first { $0.identifier?.rawValue == "details-git-editor" }
  #expect(editorButton?.isHidden == true)
}

@Test("详情面板的文件项单击不打开，双击才在工作区打开")
@MainActor
func detailsFileItemsRequireDoubleClickToOpen() async throws {
  _ = NSApplication.shared
  let fixture = makeGitPanelFixture()
  let tab = try #require(fixture.model.selectedTab)
  defer { tab.stop(immediately: true) }
  await Task.yield()
  await Task.yield()

  let cell = try gitRowCell(in: fixture.controller, row: 1)
  let fileButton = try #require(
    cell.subviews.compactMap { $0 as? PointingHandButton }.first)
  #expect(fileButton.activatesOnDoubleClickOnly)

  // performClick 没有关联事件，clickCount 视为 1，等价于单击：工作区布局不能变化。
  let layoutBeforeClick = tab.layout
  fileButton.performClick(nil)
  #expect(tab.layout == layoutBeforeClick)
  // 单击被拦在 sendAction 之前，动作本身没有被派发。
  #expect(fileButton.sendAction(fileButton.action, to: fileButton.target) == false)
}

@Test("预览按钮打开内置 diff 浮层并渲染只读 diff 文本")
@MainActor
func gitPreviewPresentsInlineDiffOverlay() async throws {
  _ = NSApplication.shared
  let diff = """
    diff --git a/App.swift b/App.swift
    @@ -1,2 +1,2 @@
    -let value = 1
    +let value = 2
    """
  let fixture = makeGitPanelFixture(diff: diff)
  defer { fixture.model.selectedTab?.stop(immediately: true) }
  await Task.yield()
  await Task.yield()

  let cell = try gitRowCell(in: fixture.controller, row: 1)
  // 行视图是刚按需创建的，先跑一轮布局让它拿到最终 frame——否则点击时记录的锚点是
  // 布局前的旧位置，断言会和布局后的行位置对不上。
  fixture.window.contentView?.layoutSubtreeIfNeeded()
  try button("details-git-row-preview", in: cell).performClick(nil)
  await Task.yield()
  await Task.yield()
  fixture.window.contentView?.layoutSubtreeIfNeeded()

  let contentView = try #require(fixture.window.contentView)
  let overlay = try #require(
    contentView.allDescendants
      .first { $0.identifier?.rawValue == "details-git-diff-preview" } as? GitDiffPreviewOverlay)
  let text = try #require(overlay.allDescendants.compactMap { $0 as? NSTextView }.first)
  #expect(text.string.contains("+let value = 2"))
  #expect(text.string.contains("-let value = 1"))
  #expect(text.isEditable == false)

  // 气泡右缘贴着详情面板左缘；本体可能因为贴近窗口边缘被夹回来，但箭头仍对准触发行。
  let panel = try #require(
    overlay.allDescendants
      .first { $0.identifier?.rawValue == "details-git-diff-panel" } as? CalloutPanelView)
  let panelEdgeX = fixture.controller.view.convert(fixture.controller.view.bounds, to: overlay).minX
  let rowCenterY = cell.convert(cell.bounds, to: overlay).midY
  #expect(abs(panel.frame.maxX - panelEdgeX) < 1)
  #expect(panel.frame.minX > 0)
  #expect(panel.frame.minY >= 0)
  #expect(panel.frame.maxY <= overlay.bounds.height)
  #expect(abs(panel.frame.minY + panel.arrowCenterY - rowCenterY) < 1)

  // 文件名压在浅色标题条上，标题条贴气泡顶边并让开右侧箭头宽度。
  let header = try #require(
    overlay.allDescendants.first { $0.identifier?.rawValue == "details-git-diff-header" })
  let headerInPanel = header.convert(header.bounds, to: panel)
  // 标题条底色由设计稿固定为 #EFF4FF，不随明暗外观变化。
  let headerColor = try #require(header.layer?.backgroundColor)
  let srgb = try #require(NSColor(cgColor: headerColor)?.usingColorSpace(.sRGB))
  #expect(abs(srgb.redComponent - 0xEF / 255) < 0.01)
  #expect(abs(srgb.greenComponent - 0xF4 / 255) < 0.01)
  #expect(abs(srgb.blueComponent - 0xFF / 255) < 0.01)
  #expect(abs(headerInPanel.maxY - panel.bounds.height) < 1)
  #expect(headerInPanel.minX == 0)
  #expect(abs(headerInPanel.maxX - (panel.bounds.width - 9)) < 1)

  // 关闭按钮必须留在标题条内且不压到箭头根部。
  let close = try button("details-git-diff-close", in: overlay)
  let closeInPanel = close.convert(close.bounds, to: panel)
  #expect(closeInPanel.maxX <= panel.bounds.width - 9)
  #expect(closeInPanel.minY >= headerInPanel.minY)
  #expect(closeInPanel.maxY <= headerInPanel.maxY)

  overlay.dismiss()
  #expect(!contentView.allDescendants.contains { $0 === overlay })
}

@Test("详情检查取消会及时终止正在运行的外部命令")
func workspaceInspectionCancellationStopsCommandPromptly() async {
  let task = Task.detached {
    WorkspaceInspectionService.runForTesting(
      executable: "/bin/sleep",
      arguments: ["5"],
      timeout: 5
    )
  }
  try? await Task.sleep(for: .milliseconds(50))
  let clock = ContinuousClock()
  let cancelledAt = clock.now
  task.cancel()
  _ = await task.value

  #expect(cancelledAt.duration(to: clock.now) < .seconds(1))
}

@Test("详情面板只启动当前 Git 页需要的检查")
@MainActor
func detailsPanelStartsOnlySelectedInspection() async {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 2
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }
  var informationCalls = 0
  var gitCalls = 0
  var filesCalls = 0
  let client = WorkspaceInspectionClient(
    information: { _ in
      informationCalls += 1
      return WorkspaceInformationSnapshot(processes: [], listeningPorts: [])
    },
    git: { _ in
      gitCalls += 1
      return GitStatusSummary()
    },
    files: { _, _ in
      filesCalls += 1
      return []
    }
  )
  let controller = DetailsPanelViewController(
    model: model,
    preferences: preferences,
    inspectionClient: client
  )
  controller.loadViewIfNeeded()
  await Task.yield()
  await Task.yield()

  #expect(informationCalls == 0)
  #expect(gitCalls == 1)
  #expect(filesCalls == 0)
}

@Test("Info 检查失败显示可重试状态，并在重试成功后显示真实空端口")
@MainActor
func informationFailureRendersRetryAndRecovers() async throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 0
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }
  var calls = 0
  let client = WorkspaceInspectionClient(
    information: { _ in
      calls += 1
      if calls == 1 {
        return WorkspaceInformationSnapshot(
          processes: [],
          listeningPorts: [],
          state: .failed("无法读取监听端口。")
        )
      }
      return WorkspaceInformationSnapshot(processes: [], listeningPorts: [])
    },
    git: { _ in GitStatusSummary() },
    files: { _, _ in [] }
  )
  let controller = DetailsPanelViewController(
    model: model,
    preferences: preferences,
    inspectionClient: client
  )
  controller.loadViewIfNeeded()
  for _ in 0..<8 { await Task.yield() }

  let failedLabels = controller.view.allDescendants.compactMap { $0 as? NSTextField }
    .map(\.stringValue)
  #expect(failedLabels.contains("无法读取监听端口。"))
  let retry = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSButton }.first { $0.title == "Retry" })
  retry.performClick(nil)
  for _ in 0..<8 { await Task.yield() }

  #expect(calls == 2)
  let recoveredLabels = controller.view.allDescendants.compactMap { $0 as? NSTextField }
    .map(\.stringValue)
  #expect(recoveredLabels.contains("No listening ports"))
  #expect(recoveredLabels.contains("无法读取监听端口。") == false)
}

@Test("Git 页收起超过缓存期限后重开会重新检查")
@MainActor
func reopeningGitAfterCacheExpiryRefreshesStatus() async {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 2
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.stop(immediately: true) }
  var gitCalls = 0
  var currentTime = Date(timeIntervalSince1970: 1_000)
  let client = WorkspaceInspectionClient(
    information: { _ in WorkspaceInformationSnapshot(processes: [], listeningPorts: []) },
    git: { _ in
      gitCalls += 1
      return GitStatusSummary()
    },
    files: { _, _ in [] }
  )
  let controller = DetailsPanelViewController(
    model: model,
    preferences: preferences,
    inspectionClient: client,
    now: { currentTime }
  )
  controller.loadViewIfNeeded()
  await Task.yield()
  await Task.yield()
  #expect(gitCalls == 1)

  controller.setPresentationActive(false)
  currentTime = currentTime.addingTimeInterval(31)
  controller.setPresentationActive(true)
  await Task.yield()
  await Task.yield()

  #expect(gitCalls == 2)
}

@Test("切换详情页会取消上一页未完成的检查")
@MainActor
func switchingDetailsSectionCancelsPreviousInspection() async throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 0
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }
  let probe = DetailsCancellationProbe()
  var gitCalls = 0
  let client = WorkspaceInspectionClient(
    information: { _ in
      do { try await Task.sleep(for: .seconds(5)) }
      catch { probe.markCancelled() }
      return WorkspaceInformationSnapshot(processes: [], listeningPorts: [])
    },
    git: { _ in
      gitCalls += 1
      return GitStatusSummary()
    },
    files: { _, _ in [] }
  )
  let controller = DetailsPanelViewController(
    model: model,
    preferences: preferences,
    inspectionClient: client
  )
  controller.loadViewIfNeeded()
  await Task.yield()
  let gitChip = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == "details-chip-git" })
  gitChip.performClick(nil)
  await Task.yield()
  await Task.yield()

  #expect(probe.isCancelled)
  #expect(gitCalls == 1)
}

@Test("Open Quickly 局部挂载浮层且不会重建工作区")
@MainActor
func openQuicklyPresentsWithoutRebuildingWorkspace() throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()
  let originalTabsLabel = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTextField }
      .first { $0.stringValue == "TABS" })

  model.toggleOpenQuickly()

  let searchFields = controller.view.allDescendants.compactMap { $0 as? NSSearchField }
  #expect(searchFields.contains { $0.placeholderString?.contains("搜索命令") == true })
  #expect(controller.view.allDescendants.contains { $0 === originalTabsLabel })
  let originalOverlay = try #require(controller.view.allDescendants.first {
    $0.identifier?.rawValue == "open-quickly-overlay"
  })

  model.toggleOpenQuickly()
  #expect(!controller.view.allDescendants.contains { $0 === originalOverlay })
  model.toggleOpenQuickly()
  #expect(controller.view.allDescendants.contains { $0 === originalOverlay })
  #expect(controller.view.allDescendants.contains { $0 === originalTabsLabel })

  let escape = try #require(NSEvent.keyEvent(
    with: .keyDown,
    location: .zero,
    modifierFlags: [],
    timestamp: 0,
    windowNumber: 0,
    context: nil,
    characters: "\u{1b}",
    charactersIgnoringModifiers: "\u{1b}",
    isARepeat: false,
    keyCode: 53
  ))
  let search = try #require(searchFields.first)
  search.keyDown(with: escape)
  #expect(model.isOpenQuicklyPresented == false)
  #expect(!controller.view.allDescendants.contains { $0 === originalOverlay })

  model.toggleOpenQuickly()
  NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
  #expect(model.isOpenQuicklyPresented == false)
  #expect(!controller.view.allDescendants.contains { $0 === originalOverlay })
}

@Test("Esc 在搜索框失焦后仍关闭工作区级临时浮层")
@MainActor
func escapeDismissesWorkspaceOverlaysRegardlessOfFirstResponder() throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }
  let terminal = try #require(model.selectedTab?.activeSession?.makeTerminalView(
    preferences: preferences) as? AsterTerminalView)
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller

  let presentations: [(present: () -> Void, isPresented: () -> Bool)] = [
    ({ model.togglePalette() }, { model.isPalettePresented }),
    ({ model.toggleGlobalFind() }, { model.isGlobalFindPresented }),
    ({ model.toggleAgentHistory() }, { model.isAgentHistoryPresented }),
    ({ model.toggleOpenQuickly() }, { model.isOpenQuicklyPresented }),
  ]
  for presentation in presentations {
    presentation.present()
    RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    // 模拟用户点到结果、按钮或后方终端：Esc 不能依赖 OverlaySearchField 仍是
    // first responder，必须由当前工作区窗口的展示边界统一接住。
    #expect(window.makeFirstResponder(terminal))
    let escape = try #require(NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      characters: "\u{1b}",
      charactersIgnoringModifiers: "\u{1b}",
      isARepeat: false,
      keyCode: 53
    ))
    NSApp.sendEvent(escape)
    #expect(presentation.isPresented() == false)
  }

  model.togglePalette()
  let otherWindow = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
  )
  let otherWindowEscape = try #require(NSEvent.keyEvent(
    with: .keyDown,
    location: .zero,
    modifierFlags: [],
    timestamp: 1,
    windowNumber: otherWindow.windowNumber,
    context: nil,
    characters: "\u{1b}",
    charactersIgnoringModifiers: "\u{1b}",
    isARepeat: false,
    keyCode: 53
  ))
  NSApp.sendEvent(otherWindowEscape)
  #expect(model.isPalettePresented)
  model.dismissWorkspaceOverlays()
}

@Test("Open Quickly 搜索、过滤器和结果共享横向基线且切换复用结果行")
@MainActor
func openQuicklyAlignsContentAndReusesRows() throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  model.toggleOpenQuickly()
  window.contentView?.layoutSubtreeIfNeeded()

  let overlay = try #require(controller.view.allDescendants.first {
    $0.identifier?.rawValue == "open-quickly-overlay"
  })
  let backdrop = try #require(controller.view.allDescendants.first {
    $0.identifier?.rawValue == "open-quickly-backdrop"
  })
  let search = try #require(controller.view.allDescendants.compactMap { $0 as? NSSearchField }
    .first { $0.identifier?.rawValue == "open-quickly-search" })
  let resultsStack = try #require(controller.view.allDescendants.compactMap { $0 as? NSStackView }
    .first { $0.identifier?.rawValue == "open-quickly-results" })
  let resultsScroll = try #require(resultsStack.enclosingScrollView)
  let firstRow = try #require(controller.view.allDescendants.compactMap { $0 as? NSButton }
    .first { $0.identifier?.rawValue.hasPrefix("open-quickly-row-") == true })
  let firstBadge = try #require(controller.view.allDescendants.first {
    $0.identifier?.rawValue.hasPrefix("open-quickly-badge-") == true
  })
  let firstSectionHeader = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTextField }
      .first { $0.stringValue == "标签页" })
  let originalOverlayWidth = overlay.bounds.width
  #expect(abs(originalOverlayWidth - 700) < 1)
  #expect(backdrop.frame == controller.view.bounds)
  #expect((overlay.layer?.shadowOpacity ?? 0) >= 0.20)
  #expect(search.isBezeled == false)
  #expect(search.focusRingType == .none)
  let searchRow = try #require(controller.view.allDescendants.first {
    $0.identifier?.rawValue == "open-quickly-search-row"
  })
  // 行高固定 36pt，但输入控件保持文字固有高度：撑满整行会让无边框
  // NSSearchFieldCell 把单行文字贴顶画，图标就掉到文字下面。
  #expect(abs(searchRow.bounds.height - 36) < 1)
  #expect(search.bounds.height < 30)
  let searchIcon = try #require(controller.view.allDescendants.first {
    $0.identifier?.rawValue == "open-quickly-search-icon"
  })
  let iconFrame = searchIcon.convert(searchIcon.bounds, to: searchRow)
  let fieldAlignmentRect = search.alignmentRect(forFrame: search.frame)
  // 使用独立 icon 与真实输入控件，确保默认 placeholder、输入文字和 IME 都从 icon 右侧
  // 开始，而不是依赖 borderless NSSearchFieldCell 的不稳定内部 rect。
  #expect((search.cell as? NSSearchFieldCell)?.searchButtonCell == nil)
  #expect(abs(iconFrame.minX - 8) < 0.5)
  #expect(abs(fieldAlignmentRect.minX - 32) < 0.5)
  #expect(iconFrame.maxX + 7 <= fieldAlignmentRect.minX)
  #expect(abs(iconFrame.midY - fieldAlignmentRect.midY) < 1)
  #expect((searchIcon as? NSImageView)?.imageAlignment == .alignCenter)
  #expect((searchIcon as? NSImageView)?.imageScaling == .scaleProportionallyDown)
  // NSScrollView 没有能向 NSStackView 传播的固有高度；结果区必须显式采用内容高度，
  // 否则目标和行都已创建，真实窗口里仍会被压成 0 高度而完全不可见。
  #expect(resultsScroll.bounds.height > 0)
  #expect(abs(searchRow.frame.width - resultsStack.bounds.width) < 1)
  #expect(abs(firstRow.frame.width - resultsStack.bounds.width) < 1)
  let badgeFrameInRow = firstBadge.convert(firstBadge.bounds, to: firstRow)
  #expect(firstRow.bounds.maxX - badgeFrameInRow.maxX <= 12)
  let headerFrameInOverlay = firstSectionHeader.convert(firstSectionHeader.bounds, to: overlay)
  #expect(headerFrameInOverlay.minX < overlay.bounds.midX)

  // modifier monitor 需要经 NSApplication 事件通道验证：按住 ⌘ 后 chip 和
  // 前九条结果出现键帽，松开后收起，不会重建结果行。
  let commandDown = try #require(NSEvent.keyEvent(
    with: .flagsChanged,
    location: .zero,
    modifierFlags: [.command],
    timestamp: 0,
    windowNumber: window.windowNumber,
    context: nil,
    characters: "",
    charactersIgnoringModifiers: "",
    isARepeat: false,
    keyCode: 55
  ))
  NSApp.sendEvent(commandDown)
  window.contentView?.layoutSubtreeIfNeeded()
  let openedChipWithHint = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == "open-quickly-chip-opened" })
  let firstShortcut = try #require(controller.view.allDescendants.first {
    $0.identifier?.rawValue.hasPrefix("open-quickly-shortcut-") == true
  })
  #expect(openedChipWithHint.attributedTitle.string.contains("⌘W"))
  #expect(firstShortcut.isHidden == false)

  let commandUp = try #require(NSEvent.keyEvent(
    with: .flagsChanged,
    location: .zero,
    modifierFlags: [],
    timestamp: 1,
    windowNumber: window.windowNumber,
    context: nil,
    characters: "",
    charactersIgnoringModifiers: "",
    isARepeat: false,
    keyCode: 55
  ))
  NSApp.sendEvent(commandUp)
  #expect(openedChipWithHint.attributedTitle.string.contains("⌘W") == false)
  #expect(firstShortcut.isHidden)

  let currentShortcut = try #require(NSEvent.keyEvent(
    with: .keyDown,
    location: .zero,
    modifierFlags: [.command],
    timestamp: 2,
    windowNumber: window.windowNumber,
    context: nil,
    characters: "j",
    charactersIgnoringModifiers: "j",
    isARepeat: false,
    keyCode: 38
  ))
  NSApp.sendEvent(currentShortcut)
  let currentChip = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == "open-quickly-chip-current" })
  #expect((currentChip.layer?.backgroundColor?.alpha ?? 0) > 0.10)

  let openedChip = try #require(controller.view.allDescendants.compactMap { $0 as? NSButton }
    .first { $0.identifier?.rawValue == "open-quickly-chip-opened" })
  openedChip.performClick(nil)
  window.contentView?.layoutSubtreeIfNeeded()
  let reusedFirstRow = try #require(controller.view.allDescendants.compactMap { $0 as? NSButton }
    .first { $0.identifier?.rawValue.hasPrefix("open-quickly-row-") == true })
  #expect(abs(overlay.bounds.width - originalOverlayWidth) < 1)
  #expect(reusedFirstRow === firstRow)

  // 浮层内部鼠标事件不得被“外部点击关闭”误判；搜索框点击后保持展示。
  let insideClick = try #require(NSEvent.mouseEvent(
    with: .leftMouseDown,
    location: search.convert(
      NSPoint(x: search.bounds.midX, y: search.bounds.midY), to: nil),
    modifierFlags: [],
    timestamp: 2.5,
    windowNumber: window.windowNumber,
    context: nil,
    eventNumber: 2,
    clickCount: 1,
    pressure: 1
  ))
  NSApp.sendEvent(insideClick)
  RunLoop.main.run(until: Date().addingTimeInterval(0.01))
  #expect(model.isOpenQuicklyPresented)
  #expect(controller.view.allDescendants.contains { $0 === overlay })

  let outsideClick = try #require(NSEvent.mouseEvent(
    with: .leftMouseDown,
    location: NSPoint(x: 4, y: 4),
    modifierFlags: [],
    timestamp: 3,
    windowNumber: window.windowNumber,
    context: nil,
    eventNumber: 1,
    clickCount: 1,
    pressure: 1
  ))
  NSApp.sendEvent(outsideClick)
  #expect(model.isOpenQuicklyPresented == false)
  #expect(!controller.view.allDescendants.contains { $0 === overlay })
}

/// 命令面板搜索行的垂直几何：与 Open Quickly 用同一套约束，放大镜必须和输入文字
/// 在同一水平线上。行高仍是 36pt，但输入控件不再被撑满整行。
@Test("命令面板搜索图标与输入文字垂直居中对齐")
@MainActor
func commandPaletteAlignsSearchIconWithText() async throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  model.togglePalette()
  // 命令面板挂载走 `objectWillChange` → `DispatchQueue.main.async` 的异步重建，
  // 必须先让出 main actor 才能拿到浮层视图。
  try await Task.sleep(for: .milliseconds(100))
  window.contentView?.layoutSubtreeIfNeeded()
  defer { model.dismissWorkspaceOverlays() }

  let search = try #require(controller.view.allDescendants.compactMap { $0 as? NSSearchField }
    .first { $0.identifier?.rawValue == "command-palette-search" })
  let searchRow = try #require(controller.view.allDescendants.first {
    $0.identifier?.rawValue == "command-palette-search-row"
  })
  let searchIcon = try #require(
    searchRow.subviews.compactMap { $0 as? NSImageView }.first)

  #expect(abs(searchRow.bounds.height - 36) < 1)
  #expect(search.bounds.height < 30)
  let iconFrame = searchIcon.convert(searchIcon.bounds, to: searchRow)
  let fieldAlignmentRect = search.alignmentRect(forFrame: search.frame)
  #expect(abs(iconFrame.midY - fieldAlignmentRect.midY) < 1)
}

/// 分组重排与「文件」过滤器都是用户直接看到的结构，用一条端到端用例把
/// 「窗口小节在最前 + 英文徽章 + 文件 chip 与它的 placeholder」一起钉住。
@Test("Open Quickly 全部视图以窗口小节开头且提供文件过滤器")
@MainActor
func openQuicklyShowsWindowSectionAndFileFilter() throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  model.toggleOpenQuickly()
  window.contentView?.layoutSubtreeIfNeeded()
  defer { model.dismissWorkspaceOverlays() }

  let search = try #require(controller.view.allDescendants.compactMap { $0 as? NSSearchField }
    .first { $0.identifier?.rawValue == "open-quickly-search" })
  let resultsStack = try #require(controller.view.allDescendants.compactMap { $0 as? NSStackView }
    .first { $0.identifier?.rawValue == "open-quickly-results" })

  // 「全部」下第一个小节必须是「窗口」，后面才是标签页。
  let headers = resultsStack.arrangedSubviews
    .filter { !($0 is OpenQuicklyRowView) }
    .compactMap { $0.allDescendants.compactMap { ($0 as? NSTextField)?.stringValue }.first }
  #expect(headers.first == "窗口")
  #expect(headers.contains("标签页"))

  // 窗口行的徽章统一用英文 `Window`。
  let windowBadge = try #require(controller.view.allDescendants.first {
    $0.identifier?.rawValue.hasPrefix("open-quickly-badge-window:") == true
  })
  let windowBadgeText = windowBadge.allDescendants.compactMap { ($0 as? NSTextField)?.stringValue }
  #expect(windowBadgeText.contains("Window"))

  let fileChip = try #require(controller.view.allDescendants.compactMap { $0 as? NSButton }
    .first { $0.identifier?.rawValue == "open-quickly-chip-file" })
  #expect(search.placeholderString == "搜索命令、URL、文件…")

  fileChip.performClick(nil)
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(search.placeholderString == "搜索当前目录下的文件…")
}

@Test("Open Quickly 默认聚焦搜索框且内部点击不会关闭")
@MainActor
func openQuicklySearchFocusAndInsideClickStayPresented() throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = FirstResponderRecordingWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller

  model.toggleOpenQuickly()
  window.contentView?.layoutSubtreeIfNeeded()

  let search = try #require(controller.view.allDescendants.compactMap { $0 as? NSSearchField }
    .first { $0.identifier?.rawValue == "open-quickly-search" })
  let overlayController = try #require(
    controller.children.compactMap { $0 as? OpenQuicklyOverlayViewController }.first)
  #expect(search.isEditable)
  #expect(search.isSelectable)
  #expect(search.isEnabled)
  #expect(window.initialFirstResponder === search)
  #expect(window.requestedResponders.contains { $0 === search })
  RunLoop.main.run(until: Date().addingTimeInterval(0.01))
  let fieldEditor = try #require(search.currentEditor())
  #expect(window.firstResponder === fieldEditor)

  let click = try #require(NSEvent.mouseEvent(
    with: .leftMouseDown,
    location: search.convert(
      NSPoint(x: search.bounds.midX, y: search.bounds.midY), to: nil),
    modifierFlags: [],
    timestamp: 0,
    windowNumber: window.windowNumber,
    context: nil,
    eventNumber: 1,
    clickCount: 1,
    pressure: 1
  ))
  let hitView = window.contentView?.hitTest(click.locationInWindow)
  #expect(hitView === fieldEditor || hitView?.isDescendant(of: fieldEditor) == true)
  #expect(overlayController.containsWindowPoint(click.locationInWindow))
  #expect(overlayController.containsWindowPoint(NSPoint(x: 4, y: 4)) == false)
  NSApp.sendEvent(click)
  #expect(model.isOpenQuicklyPresented)
  #expect(controller.view.allDescendants.contains { $0.identifier?.rawValue == "open-quickly-overlay" })
}

@Test("未运行 Agent CLI 时 Open Quickly Prompt 仍写入当前终端")
@MainActor
func openQuicklyPromptFallsBackToActiveTerminalWithoutAgent() async throws {
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let session = try #require(model.selectedTab?.activeSession)
  let terminal = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }

  let prompt = "explain this terminal output"
  let metadata = AgentSessionMetadata(
    id: "history-without-live-agent",
    configuration: .init(provider: .codex),
    projectDirectory: "/tmp",
    title: "Previous Codex session",
    createdAt: .distantPast,
    updatedAt: Date(),
    transcriptFileURL: URL(fileURLWithPath: "/tmp/history-without-live-agent.jsonl")
  )
  model.replaceAgentHistoriesForTesting([
    AgentSessionHistory(
      metadata: metadata,
      transcript: AgentTranscriptReport(
        entries: [
          AgentTranscriptEntry(
            sourceRecordIndex: 0,
            kind: .message(role: .user),
            timestamp: Date(),
            text: prompt)
        ],
        skippedRecordCount: 0,
        truncatedEntryCount: 0
      )
    )
  ])
  var encoded: [UInt8] = []
  terminal.onEncodedInput = { encoded.append(contentsOf: $0) }

  let controller = OpenQuicklyOverlayViewController(model: model)
  controller.loadViewIfNeeded()
  let targetID = try #require(controller.promptTargetIDsForTesting.first)
  controller.activateTargetForTesting(id: targetID)
  try await Task.sleep(for: .milliseconds(50))

  #expect(String(decoding: encoded, as: UTF8.self).contains(prompt))
  #expect(!encoded.contains(13))
}

@Test("详情面板切走再切回会复用已构建页而不是重建大文件树")
@MainActor
func detailsPanelTabSwitchReusesCachedSectionViews() throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 3
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }
  let controller = DetailsPanelViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()

  let originalFilesSearch = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSSearchField }.first)
  let infoChip = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == "details-chip-info" })
  let filesChip = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == "details-chip-files" })

  infoChip.performClick(nil)
  filesChip.performClick(nil)

  let restoredFilesSearch = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSSearchField }.first)
  #expect(restoredFilesSearch === originalFilesSearch)
}

@Test("详情面板页签默认等宽收起，选中项扩展宽度且切换后归位")
@MainActor
func detailsPanelChipsKeepUniformCollapsedWidthAndExpandSelection() throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 0
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  defer { tab.stop(immediately: true) }
  let controller = DetailsPanelViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()

  func chipWidth(_ identifier: String) throws -> CGFloat {
    let chip = try #require(
      controller.view.allDescendants.compactMap { $0 as? NSButton }
        .first { $0.identifier?.rawValue == identifier })
    return try #require(chip.constraints.first { $0.firstAttribute == .width }).constant
  }

  // 未选中页签保持同一收起宽度：默认状态下四个 chip 的间距不随各自标题长度变化。
  let collapsed = try chipWidth("details-chip-outline")
  let gitCollapsed = try chipWidth("details-chip-git")
  let filesCollapsed = try chipWidth("details-chip-files")
  #expect(gitCollapsed == collapsed)
  #expect(filesCollapsed == collapsed)
  // 选中项在收起宽度基础上扩展出标题文字。
  let selected = try chipWidth("details-chip-info")
  #expect(selected > collapsed)

  let git = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == "details-chip-git" })
  git.performClick(nil)

  // 切换后宽度互换：新选中项展开，旧选中项立即回到统一收起宽度，不残留扩展位。
  #expect(try chipWidth("details-chip-git") > collapsed)
  #expect(try chipWidth("details-chip-info") == collapsed)
}

@Test("活动 Pane 切换仍复用详情页根视图与表格行池")
@MainActor
func activePaneSwitchKeepsLoadedDetailsPageRoots() async throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 3
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let firstPaneID = tab.activePaneID
  defer { tab.stop(immediately: true) }
  var filesCalls = 0
  let client = WorkspaceInspectionClient(
    information: { _ in WorkspaceInformationSnapshot(processes: [], listeningPorts: []) },
    git: { _ in GitStatusSummary() },
    files: { _, _ in
      filesCalls += 1
      return []
    }
  )
  let controller = DetailsPanelViewController(
    model: model, preferences: preferences, inspectionClient: client)
  controller.loadViewIfNeeded()
  await Task.yield()

  let originalSearch = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSSearchField }.first)
  let originalTable = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTableView }
      .first { $0.identifier?.rawValue == "details-files-table" })

  tab.split(direction: .right)
  await Task.yield()
  #expect(filesCalls == 2)
  tab.setActivePane(firstPaneID)

  let currentSearch = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSSearchField }.first)
  let currentTable = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTableView }
      .first { $0.identifier?.rawValue == "details-files-table" })
  #expect(currentSearch === originalSearch)
  #expect(currentTable === originalTable)
}

@Test("活动 Pane 切换时 Files 保留旧帧并原子替换新目录")
@MainActor
func activePaneSwitchKeepsFilesVisibleUntilReplacementIsReady() async throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 3
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  defer { tab.stop(immediately: true) }

  let oldNodes = [
    WorkspaceFileNode(path: "/tmp/old.txt", name: "old.txt", depth: 0, isDirectory: false)
  ]
  let newNodes = [
    WorkspaceFileNode(path: "/tmp/new-a.txt", name: "new-a.txt", depth: 0, isDirectory: false),
    WorkspaceFileNode(path: "/tmp/new-b.txt", name: "new-b.txt", depth: 0, isDirectory: false),
  ]
  var filesCalls = 0
  let client = WorkspaceInspectionClient(
    information: { _ in WorkspaceInformationSnapshot(processes: [], listeningPorts: []) },
    git: { _ in GitStatusSummary() },
    files: { _, _ in
      filesCalls += 1
      return filesCalls == 1 ? oldNodes : newNodes
    }
  )
  let controller = DetailsPanelViewController(
    model: model, preferences: preferences, inspectionClient: client)
  controller.loadViewIfNeeded()
  controller.view.frame = NSRect(x: 0, y: 0, width: 278, height: 600)
  controller.view.layoutSubtreeIfNeeded()
  await Task.yield()
  await Task.yield()

  let table = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTableView }
      .first { $0.identifier?.rawValue == "details-files-table" })
  #expect(table.numberOfRows == 1)

  tab.split(direction: .right)

  // 新目录枚举尚未获得执行机会时，旧行应继续绘制；透明刷新屏障负责拦截旧动作。
  #expect(table.numberOfRows == 1)
  let overlay = try #require(
    controller.view.allDescendants.first {
      $0.identifier?.rawValue == "details-pane-refresh-overlay"
    })
  #expect(overlay.isHidden == false)
  #expect(overlay.bounds.width > 0)
  let overlayCenter = NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)
  #expect(overlay.hitTest(overlayCenter) === overlay)

  await Task.yield()
  await Task.yield()
  #expect(filesCalls == 2)
  #expect(table.numberOfRows == 2)
  #expect(overlay.isHidden)
}

@Test("活动 Pane 切换时 Git 保留旧帧并原子替换新状态")
@MainActor
func activePaneSwitchKeepsGitVisibleUntilReplacementIsReady() async throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 2
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  defer { tab.stop(immediately: true) }

  let oldStatus = GitStatusSummary(
    branch: "master", objectID: "old",
    changes: [GitChange(path: "old.txt", status: ".M")])
  let newStatus = GitStatusSummary(
    branch: "feature", objectID: "new",
    changes: [
      GitChange(path: "new-a.txt", status: ".M"),
      GitChange(path: "new-b.txt", status: ".M"),
    ])
  var gitCalls = 0
  let client = WorkspaceInspectionClient(
    information: { _ in WorkspaceInformationSnapshot(processes: [], listeningPorts: []) },
    git: { _ in
      gitCalls += 1
      return gitCalls == 1 ? oldStatus : newStatus
    },
    files: { _, _ in [] }
  )
  let controller = DetailsPanelViewController(
    model: model, preferences: preferences, inspectionClient: client)
  controller.loadViewIfNeeded()
  await Task.yield()
  await Task.yield()

  let table = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTableView }
      .first { $0.identifier?.rawValue == "details-git-table" })
  #expect(table.numberOfRows == 2)

  tab.split(direction: .right)

  #expect(table.numberOfRows == 2)
  let overlay = try #require(
    controller.view.allDescendants.first {
      $0.identifier?.rawValue == "details-pane-refresh-overlay"
    })
  #expect(overlay.isHidden == false)

  await Task.yield()
  await Task.yield()
  #expect(gitCalls == 2)
  #expect(table.numberOfRows == 3)
  #expect(overlay.isHidden)
}

@Test("活动 Pane 切换时 Outline 保留旧帧并原子替换新结构")
@MainActor
func activePaneSwitchKeepsOutlineVisibleUntilReplacementIsReady() async throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 1
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  defer { tab.stop(immediately: true) }

  let firstURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-outline-first-\(UUID().uuidString).md")
  let secondURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-outline-second-\(UUID().uuidString).md")
  try Data("# First\n".utf8).write(to: firstURL)
  try Data("# Second\n## Child\n".utf8).write(to: secondURL)
  defer {
    try? FileManager.default.removeItem(at: firstURL)
    try? FileManager.default.removeItem(at: secondURL)
  }

  tab.split(direction: .right, kind: .editor, resourcePath: firstURL.path)
  let firstEditorID = tab.activePaneID
  tab.split(direction: .right, kind: .editor, resourcePath: secondURL.path)
  let secondEditorID = tab.activePaneID
  tab.setActivePane(firstEditorID)

  let controller = DetailsPanelViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()
  let table = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTableView }
      .first { $0.identifier?.rawValue == "details-outline-table" })
  for _ in 0..<40 {
    if table.numberOfRows == 1 { break }
    await Task.yield()
  }
  #expect(table.numberOfRows == 1)

  tab.setActivePane(secondEditorID)

  #expect(table.numberOfRows == 1)
  let overlay = try #require(
    controller.view.allDescendants.first {
      $0.identifier?.rawValue == "details-pane-refresh-overlay"
    })
  #expect(overlay.isHidden == false)

  for _ in 0..<40 {
    if table.numberOfRows == 2 { break }
    await Task.yield()
  }
  #expect(table.numberOfRows == 2)
  #expect(overlay.isHidden)
}

@Test("Outline 实时跟随编辑内容并把条目点击路由到对应行")
@MainActor
func outlineTracksDocumentEditsAndRevealsSelectedLine() async throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let document = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-outline-\(UUID().uuidString).md")
  try Data("# Initial\n".utf8).write(to: document)
  defer { try? FileManager.default.removeItem(at: document) }

  let pane = PaneDescriptor(
    kind: .editor,
    workingDirectory: document.deletingLastPathComponent().path,
    resourcePath: document.path
  )
  let tabSnapshot = WorkspaceTabSnapshot(
    id: UUID(), title: "Outline", layout: .leaf(pane))
  let snapshot = WorkspaceSnapshot(selectedTabID: tabSnapshot.id, tabs: [tabSnapshot])
  defaults.set(try JSONEncoder().encode(snapshot), forKey: "aster.workspace.snapshot.v1")
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 1
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let runtime = try #require(tab.activeRuntime)
  let controller = DetailsPanelViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()

  let outlineTable = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTableView }
      .first { $0.identifier?.rawValue == "details-outline-table" })

  runtime.updateDocument("# Updated\n\n## Child\n")
  var childButton: NSButton?
  for _ in 0..<20 {
    await Task.yield()
    try await Task.sleep(for: .milliseconds(20))
    for row in 0..<outlineTable.numberOfRows {
      let cell = outlineTable.view(atColumn: 0, row: row, makeIfNecessary: true)
      childButton = cell?.allDescendants.compactMap { $0 as? NSButton }
        .first { $0.title.trimmingCharacters(in: .whitespaces) == "Child" }
      if childButton != nil { break }
    }
    if childButton != nil { break }
  }
  let child = try #require(childButton)
  var revealedLine: Int?
  let subscription = tab.documentLineRevealRequested.sink { revealedLine = $0.line }
  child.performClick(nil)

  #expect(revealedLine == 3)
  withExtendedLifetime(subscription) {}
}

@Test("Outline 在终端命令完成后实时显示 Shell Integration 锚点")
@MainActor
func outlineTracksCompletedTerminalCommands() async throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 1
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  defer { tab.stop(immediately: true) }
  let terminalView = session.makeTerminalView(preferences: preferences)
  terminalView.resize(cols: 40, rows: 6)
  let controller = DetailsPanelViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()

  let output =
    "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}echo outline\r\n"
    + "\u{1B}]133;C\u{7}outline\r\n\u{1B}]133;D;0\u{7}"
  terminalView.dataReceived(slice: Array(output.utf8)[...])
  await Task.yield()

  let outlineTable = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTableView }
      .first { $0.identifier?.rawValue == "details-outline-table" })
  let titles = (0..<outlineTable.numberOfRows).flatMap { row in
    outlineTable.view(atColumn: 0, row: row, makeIfNecessary: true)?
      .allDescendants.compactMap { ($0 as? NSButton)?.title } ?? []
  }
  #expect(titles.contains { $0.contains("echo outline") })

  // 切换到异步解析的编辑器 Pane 时，旧终端条目作为不可交互视觉帧保留；透明屏障
  // 同步拦截旧动作，解析完成后再一次性替换为新 Pane 的 Outline。
  let document = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-outline-switch-\(UUID().uuidString).md")
  try Data("# Editor\n".utf8).write(to: document)
  defer { try? FileManager.default.removeItem(at: document) }
  tab.split(direction: .right, kind: .editor, resourcePath: document.path)
  #expect(outlineTable.numberOfRows == 1)
  let overlay = try #require(
    controller.view.allDescendants.first {
      $0.identifier?.rawValue == "details-pane-refresh-overlay"
    })
  #expect(overlay.isHidden == false)

  for _ in 0..<40 {
    if overlay.isHidden { break }
    await Task.yield()
  }
  let updatedTitles = (0..<outlineTable.numberOfRows).flatMap { row in
    outlineTable.view(atColumn: 0, row: row, makeIfNecessary: true)?
      .allDescendants.compactMap { ($0 as? NSButton)?.title } ?? []
  }
  #expect(overlay.isHidden)
  #expect(updatedTitles.contains { $0.contains("Editor") })
  #expect(updatedTitles.contains { $0.contains("echo outline") } == false)
}

@Test("终端目录变化只刷新 Files 数据且不重建工作区或夺走输入焦点")
@MainActor
func workingDirectoryChangeRefreshesFilesWithoutRebuildingWorkspaceOrStealingFocus() async throws {
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorPresented = true
  preferences.inspectorSection = 3
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let session = try #require(model.selectedTab?.activeSession)
  defer { session.stop(immediately: true) }

  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_180, height: 760),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.contentView?.layoutSubtreeIfNeeded()
  await Task.yield()

  let terminalView = try #require(
    controller.view.allDescendants.compactMap { $0 as? AsterTerminalView }.first)
  let detailsController = try #require(
    controller.children.compactMap { $0 as? DetailsPanelViewController }.first)
  #expect(window.makeFirstResponder(terminalView))
  #expect(window.firstResponder === terminalView)

  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-details-focus-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let marker = "new-cwd-marker-\(UUID().uuidString).txt"
  try Data().write(to: directory.appendingPathComponent(marker))

  var observedDirectories: [String] = []
  let directorySubscription = model.selectedTab?.workingDirectoryChanged.sink {
    observedDirectories.append($0.directory)
  }
  session.hostCurrentDirectoryUpdate(source: terminalView, directory: directory.path)
  var visibleButtonTitles: [String] = []
  for _ in 0..<40 {
    visibleButtonTitles = controller.view.allDescendants.compactMap { ($0 as? NSButton)?.title }
    if visibleButtonTitles.contains(marker) { break }
    try await Task.sleep(for: .milliseconds(100))
  }

  // CWD 是内容更新，不是布局更新；终端与详情面板都必须继续使用原实例。
  #expect(controller.view.allDescendants.contains { $0 === terminalView })
  #expect(controller.children.contains { $0 === detailsController })
  #expect(window.firstResponder === terminalView)
  #expect(observedDirectories.contains(directory.path))
  #expect(model.selectedTab?.workingDirectory == directory.path)
  #expect(visibleButtonTitles.contains(marker))
  withExtendedLifetime(directorySubscription) {}
}

// MARK: - History

@Test("History（Memory）页挂载专用表格、刷新与浏览器入口，并给出可区分的空状态")
@MainActor
func memorySectionMountsTableAndDistinguishableEmptyState() throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 4
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }
  let controller = DetailsPanelViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()

  let table = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTableView }
      .first { $0.identifier?.rawValue == "details-memory-table" })
  #expect(table.numberOfRows == 0)

  let identifiers = controller.view.allDescendants.compactMap { $0.identifier?.rawValue }
  #expect(identifiers.contains("details-memory-refresh"))
  // 管理（固定/禁用/删除）由 Memory 浏览器承担，本页必须给出显式入口。
  #expect(identifiers.contains("details-memory-manage"))

  // 空状态必须说清原因：仍在读取、未开启记录，还是确实没有记忆。
  let texts = controller.view.allDescendants.compactMap { ($0 as? NSTextField)?.stringValue }
  #expect(
    texts.contains {
      $0.contains("正在读取项目记忆") || $0.contains("未开启记录") || $0.contains("暂无记忆")
    })
}

@Test("Outline 页下半部内嵌会话时间线区域，返回按钮在列表态隐藏")
@MainActor
func outlineSectionEmbedsSessionHistoryArea() throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 1
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }
  let controller = DetailsPanelViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()

  // 现场命令 Outline 与过去的会话记录同属「时间线」，必须同页可见。
  let outlineTable = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTableView }
      .first { $0.identifier?.rawValue == "details-outline-table" })
  let historyTable = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTableView }
      .first { $0.identifier?.rawValue == "details-history-table" })
  #expect(outlineTable.isHiddenByAncestor == false)
  #expect(historyTable.isHiddenByAncestor == false)

  let identifiers = controller.view.allDescendants.compactMap { $0.identifier?.rawValue }
  #expect(identifiers.contains("details-history-refresh"))
  // 返回按钮只属于详情态；列表态必须隐藏，否则用户会点到一个无处可返回的入口。
  let back = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == "details-history-back" })
  #expect(back.isHidden)

  // 会话区空状态必须说清原因：仍在读取、未开启记录，还是确实没有记录。
  let texts = controller.view.allDescendants.compactMap { ($0 as? NSTextField)?.stringValue }
  #expect(
    texts.contains {
      $0.contains("正在读取会话记录") || $0.contains("未开启记录") || $0.contains("暂无记录")
    })
}

@Test("切到 History 页只切换可见性，已挂载的其它页内容保持在视图树中")
@MainActor
func historyChipSwitchesVisibilityWithoutRebuildingOtherSections() throws {
  _ = NSApplication.shared
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorSection = 3
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }
  let controller = DetailsPanelViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()

  let filesTable = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTableView }
      .first { $0.identifier?.rawValue == "details-files-table" })
  let chip = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSButton }
      .first { $0.identifier?.rawValue == "details-chip-history" })
  chip.performClick(nil)

  #expect(preferences.inspectorSection == 4)
  let memoryTable = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTableView }
      .first { $0.identifier?.rawValue == "details-memory-table" })
  // Files 页仍留在视图树里（只是被祖先隐藏），回切不需要重建数百个控件与约束。
  #expect(controller.view.allDescendants.contains { $0 === filesTable })
  #expect(filesTable.isHiddenByAncestor)
  #expect(memoryTable.isHiddenByAncestor == false)
}

@Test("History 行高按行类型区分，展开正文块受最大高度约束")
@MainActor
func historyRowHeightsVaryByRowKind() throws {
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  let controller = DetailsPanelViewController(model: model, preferences: preferences)

  let timelineRow = SessionTimelineRow(
    id: "session#1",
    sequence: 1,
    timestamp: Date(),
    kind: .command,
    title: "swift build",
    subtitle: "/repo",
    status: .failed(1)
  )
  let width: CGFloat = 260
  #expect(
    controller.historyRowHeight(.sectionHeader("时间线"), width: width)
      == SessionHistoryMetrics.sectionHeaderHeight)
  #expect(
    controller.historyRowHeight(.timeline(timelineRow, isExpanded: false), width: width)
      == SessionHistoryMetrics.timelineRowHeight)
  // 1MiB 的 artifact 不能把单行撑成一屏；超长正文靠「复制」而不是无限行高。
  let huge = SessionHistoryRow.expandedText(
    id: "session#1",
    text: String(repeating: "some long output line\n", count: 500),
    isFullText: true,
    canLoadFullText: false
  )
  #expect(
    controller.historyRowHeight(huge, width: width)
      == SessionHistoryMetrics.expandedTextMaximumHeight)
  let short = SessionHistoryRow.expandedText(
    id: "session#1", text: "one line", isFullText: false, canLoadFullText: true)
  #expect(
    controller.historyRowHeight(short, width: width)
      < SessionHistoryMetrics.expandedTextMaximumHeight)
}

@Test("时间线行没有可展开内容时不给出悬停高亮这一空承诺")
@MainActor
func historyTimelineRowOnlyPromisesInteractionWhenExpandable() throws {
  let cell = SessionHistoryTimelineRowView(
    identifier: NSUserInterfaceItemIdentifier("details-history-row"))
  let plain = SessionTimelineRow(
    id: "session#1", sequence: 1, timestamp: Date(), kind: .gitSnapshot,
    title: "main", subtitle: "abcdef1", status: .none, source: .git, detail: nil)
  cell.configure(row: plain, isExpanded: false) {}
  #expect(cell.isHoverHighlightEnabled == false)

  let expandable = SessionTimelineRow(
    id: "session#2", sequence: 2, timestamp: Date(), kind: .command,
    title: "swift test", subtitle: "/repo", status: .failed(1), source: .terminal,
    detail: SessionTimelineDetail(excerpt: "failed", artifactRelativePath: nil))
  cell.configure(row: expandable, isExpanded: false) {}
  #expect(cell.isHoverHighlightEnabled)
}

@Test("transcript 补录的事件在行上有可见来源标注")
@MainActor
func historyTimelineRowMarksTranscriptSourcedEvents() throws {
  let cell = SessionHistoryTimelineRowView(
    identifier: NSUserInterfaceItemIdentifier("details-history-row"))
  let terminal = SessionTimelineRow(
    id: "session#1", sequence: 1, timestamp: Date(), kind: .command,
    title: "swift build", subtitle: "/repo", status: .succeeded, source: .terminal)
  cell.configure(row: terminal, isExpanded: false) {}
  #expect(
    cell.allDescendants.compactMap { ($0 as? NSTextField)?.stringValue }
      .contains("transcript") == false)

  let transcript = SessionTimelineRow(
    id: "session#2", sequence: 2, timestamp: Date(), kind: .fileModified,
    title: "App.swift", subtitle: "/repo/Sources/App.swift", status: .none, source: .transcript)
  cell.configure(row: transcript, isExpanded: false) {}
  let badge = cell.allDescendants.compactMap { $0 as? NSTextField }
    .first { $0.stringValue == "transcript" }
  #expect(badge?.isHidden == false)
  #expect(cell.toolTip?.contains("非终端实测") == true)
}

@Test("History 各类行走复用池并带稳定的行标识")
@MainActor
func historyRowsUseReusableCellsWithStableIdentifiers() throws {
  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  let controller = DetailsPanelViewController(model: model, preferences: preferences)
  let table = NSTableView()

  let timelineRow = SessionTimelineRow(
    id: "session#1", sequence: 1, timestamp: Date(), kind: .toolCall,
    title: "Edit", subtitle: "/repo/App.swift", status: .none, source: .transcript)
  let cases: [(SessionHistoryRow, String)] = [
    (.sectionHeader("Memory"), "details-history-section"),
    (.memory(title: "标题", body: "正文", sources: "来源：规则提炼 · event ×2"), "details-history-memory"),
    (.timeline(timelineRow, isExpanded: false), "details-history-row"),
    (
      .expandedText(id: "session#1", text: "output", isFullText: false, canLoadFullText: true),
      "details-history-output"
    ),
  ]
  for (row, identifier) in cases {
    let view = try #require(controller.makeHistoryRowView(row, in: table))
    #expect(view.identifier?.rawValue == identifier)
  }
}

extension NSView {
  fileprivate var allDescendants: [NSView] {
    subviews.flatMap { [$0] + $0.allDescendants }
  }

  /// 页签切换只翻转页根视图的 `isHidden`，因此判断某个深层控件是否可见必须一路上溯。
  fileprivate var isHiddenByAncestor: Bool {
    var node: NSView? = self
    while let current = node {
      if current.isHidden { return true }
      node = current.superview
    }
    return false
  }
}

/// Inspector 现在属于主题 Container 内层 Pane split；不能再按遍历顺序取第一个
/// WorkspacePanelSplitView，因为第一个是只负责 Sidebar ↔ Content 的外层边界。
@MainActor
private func inspectorSplit(in root: NSView) -> WorkspacePanelSplitView? {
  guard let container = root.allDescendants.first(where: {
    $0.identifier?.rawValue == "workspace-container"
  }) else { return nil }
  return container.allDescendants.compactMap { $0 as? WorkspacePanelSplitView }.first
}
