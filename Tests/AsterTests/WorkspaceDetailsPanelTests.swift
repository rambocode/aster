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

  reloaded.inspectorSection = 9
  #expect(reloaded.inspectorSection == 3)
}

@Test("面板收起时标题栏含悬停切换按钮，展开后隐藏并呈现四个页签 chip")
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
  // 默认完全透明，悬停才淡入。
  #expect(toggle?.superview?.alphaValue == 0)

  let defaults = panelTestDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.inspectorPresented = true
  preferences.inspectorSection = 1
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()

  let identifiers = controller.view.allDescendants.compactMap { $0.identifier?.rawValue }
  // 面板展开后标题栏不再渲染切换按钮，收起入口在面板 header 右侧。
  #expect(!identifiers.contains("workspace-inspector-toggle"))
  #expect(identifiers.contains("details-panel-close"))
  for chip in ["details-chip-info", "details-chip-outline", "details-chip-git", "details-chip-files"] {
    #expect(identifiers.contains(chip))
  }
  // 持久化的选中页应反映为对应 chip 的选中态标题。
  let outlineChip = controller.view.allDescendants.compactMap { $0 as? NSButton }
    .first { $0.identifier?.rawValue == "details-chip-outline" }
  #expect(outlineChip?.title.contains("Outline") == true)
  // 面板滚动文档必须左上原点翻转，否则内容短于视口时会沉到底部。
  let panelScrolls = controller.view.allDescendants.compactMap { $0 as? NSScrollView }
  #expect(panelScrolls.contains { $0.documentView is FlippedDocumentView })
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
  let firstRow = try #require(controller.view.allDescendants.compactMap { $0 as? NSButton }
    .first { $0.identifier?.rawValue.hasPrefix("open-quickly-row-") == true })
  let firstBadge = try #require(controller.view.allDescendants.first {
    $0.identifier?.rawValue.hasPrefix("open-quickly-badge-") == true
  })
  let firstSectionHeader = try #require(
    controller.view.allDescendants.compactMap { $0 as? NSTextField }
      .first { $0.stringValue == "已打开" })
  let originalOverlayWidth = overlay.bounds.width
  #expect(abs(originalOverlayWidth - 700) < 1)
  #expect(backdrop.frame == controller.view.bounds)
  #expect((overlay.layer?.shadowOpacity ?? 0) >= 0.20)
  #expect(search.isBezeled == false)
  #expect(search.focusRingType == .none)
  #expect(abs(search.bounds.height - 36) < 1)
  let searchCell = try #require(search.cell as? NSSearchFieldCell)
  let searchIconRect = searchCell.searchButtonRect(forBounds: search.bounds)
  let searchTextRect = searchCell.searchTextRect(forBounds: search.bounds)
  #expect(searchIconRect.maxX + 6 <= searchTextRect.minX)
  #expect(abs(searchIconRect.midY - searchTextRect.midY) < 1)
  #expect(search.frame.width >= overlay.bounds.width - 32)
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

  // 浮层内部鼠标事件不得被“外部点击关闭”误判；搜索框点击后
  // 仍保持展示并成为窗口文本编辑器的客户端。
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
  #expect(window.initialFirstResponder === search)

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

  runtime.updateDocument("# Updated\n\n## Child\n")
  await Task.yield()

  let buttons = controller.view.allDescendants.compactMap { $0 as? NSButton }
  let buttonTitles = buttons.map { $0.title.trimmingCharacters(in: .whitespaces) }
  #expect(buttonTitles.contains("Child"))
  let child = try #require(buttons.first { $0.title.trimmingCharacters(in: .whitespaces) == "Child" })
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
  let session = try #require(model.selectedTab?.activeSession)
  defer { session.stop(immediately: true) }
  let terminalView = session.makeTerminalView(preferences: preferences)
  terminalView.resize(cols: 40, rows: 6)
  let controller = DetailsPanelViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()

  let output =
    "\u{1B}]133;A\u{7}$ \u{1B}]133;B\u{7}echo outline\r\n"
    + "\u{1B}]133;C\u{7}outline\r\n\u{1B}]133;D;0\u{7}"
  terminalView.dataReceived(slice: Array(output.utf8)[...])
  await Task.yield()

  let titles = controller.view.allDescendants.compactMap { ($0 as? NSButton)?.title }
  #expect(titles.contains { $0.contains("echo outline") })
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

extension NSView {
  fileprivate var allDescendants: [NSView] {
    subviews.flatMap { [$0] + $0.allDescendants }
  }
}
