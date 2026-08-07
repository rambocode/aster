import AppKit
import AsterCore
import Testing

@testable import Aster

@MainActor
private func isolatedDefaults() -> UserDefaults {
  let suite = "AsterTests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

@Test("主工作区由纯 AppKit 视图控制器构成")
@MainActor
func workspaceUsesOnlyNativeAppKitViews() throws {
  let defaults = isolatedDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  model.splitSelectedTab(.right)
  let controller = WorkspaceViewController(model: model, preferences: preferences)

  controller.loadViewIfNeeded()

  #expect(controller.view is NSVisualEffectView)
  #expect(controller.view.descendants.contains { String(describing: type(of: $0)).contains("NSHosting") } == false)
  #expect(controller.view.descendants.contains { $0 is NSSplitView } == true)
}

@Test("设置页由纯 AppKit 控件构成并保留九个分类")
@MainActor
func settingsUsesOnlyNativeAppKitControls() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)

  controller.loadViewIfNeeded()

  #expect(controller.sections.count == 9)
  #expect(controller.view.descendants.contains { String(describing: type(of: $0)).contains("NSHosting") } == false)
  #expect(controller.view.descendants.contains { $0 is NSScrollView } == true)
}

@Test("垂直标签栏使用 Otty 的整行选中结构")
@MainActor
func verticalSidebarUsesFullWidthRows() throws {
  let defaults = isolatedDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))

  window.contentView?.layoutSubtreeIfNeeded()

  let tabButtons = controller.view.descendants.compactMap { view -> NSButton? in
    guard String(describing: type(of: view)).contains("TabRowButton") else { return nil }
    return view as? NSButton
  }
  #expect(tabButtons.count == 1)
  #expect((tabButtons.first?.frame.width ?? 0) >= 210)
  #expect(tabButtons.first?.enclosingScrollView == nil)
  #expect(controller.view.descendants.contains { $0 is NSProgressIndicator } == false)
  #expect(controller.view.descendants.compactMap { ($0 as? NSButton)?.toolTip }.contains("新建标签页") == false)
  #expect(controller.view.descendants.compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("LOCAL") } == false)
}

@Test("工作区标题栏紧凑显示目录且不包含额外工具按钮")
@MainActor
func workspaceTitlebarMatchesOttyChrome() throws {
  let defaults = isolatedDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))

  window.contentView?.layoutSubtreeIfNeeded()

  let titlebar = controller.view.descendants.first {
    $0.identifier?.rawValue == "workspace-titlebar"
  }
  let titlebarMaterial = titlebar as? NSVisualEffectView
  let actionButtons = controller.view.descendants.filter {
    String(describing: type(of: $0)).contains("ActionButton")
  }
  let labels = controller.view.descendants.compactMap { ($0 as? NSTextField)?.stringValue }
  #expect(titlebar != nil)
  #expect(abs((titlebar?.frame.height ?? 0) - 28) < 0.5)
  #expect(titlebarMaterial?.blendingMode == .withinWindow)
  #expect(actionButtons.isEmpty)
  #expect(labels.contains("~"))
}

@Test("TABS 标题使用截图一致的原生标签整理菜单按钮")
@MainActor
func sidebarProvidesNativeTabOrganizerMenu() throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(defaults: defaults, directories: [NSHomeDirectory()])
  let preferences = AppPreferences(defaults: defaults)
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))

  window.contentView?.layoutSubtreeIfNeeded()

  let organizer = try #require(controller.view.descendants.compactMap { $0 as? NSButton }.first {
    $0.toolTip == "整理标签"
  })
  #expect(String(describing: type(of: organizer)).contains("SidebarOptionsButton"))
  #expect(organizer.image?.accessibilityDescription == "整理标签")

  let menu = try #require(organizer.menu)
  #expect(
    menu.items.map(\.title) == [
      "GROUP", "No Grouping", "By Project", "By Date", "",
      "ORDER", "Created Time", "Updated Time", "",
      "DIVIDER", "Insert Divider", "Remove All Dividers",
    ]
  )
  #expect(menu.item(withTitle: "No Grouping")?.state == .on)
  #expect(menu.item(withTitle: "Created Time")?.state == .on)
  #expect(menu.item(withTitle: "By Project")?.image != nil)
  #expect(menu.item(withTitle: "Insert Divider")?.image != nil)
}

@Test("标签整理菜单会持久切换勾选项并管理分隔线")
@MainActor
func sidebarOrganizerMenuActionsUpdateListState() throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(defaults: defaults, directories: [NSHomeDirectory()])
  let preferences = AppPreferences(defaults: defaults)
  var controller = WorkspaceViewController(model: model, preferences: preferences)
  var window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))

  func rebuildWorkspace() {
    controller = WorkspaceViewController(model: model, preferences: preferences)
    window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  }

  func currentMenu() throws -> NSMenu {
    window.contentView?.layoutSubtreeIfNeeded()
    let button = try #require(controller.view.descendants.compactMap { $0 as? NSButton }.first {
      $0.toolTip == "整理标签"
    })
    return try #require(button.menu)
  }

  func perform(_ title: String, in menu: NSMenu) {
    let index = menu.indexOfItem(withTitle: title)
    #expect(index >= 0)
    guard index >= 0 else { return }
    let item = menu.items[index]
    let action = item.action
    #expect(action != nil)
    if let action {
      #expect(NSApp.sendAction(action, to: item.target, from: item))
    }
  }

  var menu = try currentMenu()
  perform("By Project", in: menu)
  #expect(preferences.sidebarTabGrouping == .project)
  rebuildWorkspace()
  menu = try currentMenu()
  #expect(menu.item(withTitle: "By Project")?.state == .on)
  #expect(menu.item(withTitle: "No Grouping")?.state == .off)

  perform("Updated Time", in: menu)
  #expect(preferences.sidebarTabOrder == .updatedTime)
  rebuildWorkspace()
  menu = try currentMenu()
  #expect(menu.item(withTitle: "Updated Time")?.state == .on)
  #expect(menu.item(withTitle: "Created Time")?.state == .off)

  perform("Insert Divider", in: menu)
  #expect(model.dividerAfterTabIDs.contains(model.selectedTabID!))
  rebuildWorkspace()
  #expect(controller.view.descendants.contains {
    $0.identifier?.rawValue == "sidebar-manual-divider"
  })

  let restoredPreferences = AppPreferences(defaults: defaults)
  #expect(restoredPreferences.sidebarTabGrouping == .project)
  #expect(restoredPreferences.sidebarTabOrder == .updatedTime)
  let restoredModel = AppModel(defaults: defaults)
  restoredModel.ensureInitialTab()
  #expect(restoredModel.dividerAfterTabIDs == model.dividerAfterTabIDs)

  menu = try currentMenu()
  perform("Remove All Dividers", in: menu)
  rebuildWorkspace()
  #expect(controller.view.descendants.contains {
    $0.identifier?.rawValue == "sidebar-manual-divider"
  } == false)
}

@Test("项目分组与时间排序会真实改变左侧标签列表")
@MainActor
func sidebarOrganizerAppliesGroupingAndOrdering() throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(
    defaults: defaults,
    directories: [NSHomeDirectory(), "/tmp"]
  )
  let preferences = AppPreferences(defaults: defaults)

  func makeController() -> WorkspaceViewController {
    let controller = WorkspaceViewController(model: model, preferences: preferences)
    let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
    window.contentView?.layoutSubtreeIfNeeded()
    return controller
  }

  func primaryTabLabels(in controller: WorkspaceViewController) -> [String] {
    controller.view.descendants.compactMap { view -> NSButton? in
      guard String(describing: type(of: view)).contains("TabRowButton") else { return nil }
      return view as? NSButton
    }.compactMap { button in
      button.subviews.compactMap { ($0 as? NSTextField)?.stringValue }.first
    }
  }

  preferences.sidebarTabGrouping = .none
  preferences.sidebarTabOrder = .createdTime
  var controller = makeController()
  #expect(primaryTabLabels(in: controller).first == "/tmp")

  let oldestTab = try #require(model.tabs.first)
  model.select(oldestTab)
  preferences.sidebarTabOrder = .updatedTime
  controller = makeController()
  #expect(primaryTabLabels(in: controller).first == "~")

  preferences.sidebarTabGrouping = .project
  controller = makeController()
  let groupHeaders = controller.view.descendants.compactMap { ($0 as? NSTextField) }.filter {
    $0.identifier?.rawValue == "sidebar-group-header"
  }.map(\.stringValue)
  #expect(Set(groupHeaders) == Set(["mike", "tmp"]))
}

@Test("OSC 7 文件 URL 会规范化为可恢复的本地目录")
@MainActor
func terminalNormalizesReportedWorkingDirectory() {
  #expect(
    TerminalSession.normalizeReportedWorkingDirectory(
      "file://localhost/Users/mike/source/project/dxtun"
    ) == "/Users/mike/source/project/dxtun"
  )
  #expect(TerminalSession.normalizeReportedWorkingDirectory("file:///tmp/Aster%20QA") == "/tmp/Aster QA")
  #expect(TerminalSession.normalizeReportedWorkingDirectory("/Users/mike") == "/Users/mike")
}

@Test("设置页从顶部开始并让导航与卡片占满可用宽度")
@MainActor
func settingsLayoutUsesTopAnchoredFullWidthRows() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 940, height: 760))

  window.contentView?.layoutSubtreeIfNeeded()

  let sidebarButtons = controller.view.descendants.compactMap { view -> NSButton? in
    guard String(describing: type(of: view)).contains("SettingsSidebarButton") else { return nil }
    return view as? NSButton
  }
  let contentScroll = try #require(controller.view.descendants.compactMap { $0 as? NSScrollView }.first)
  let cards = controller.view.descendants.filter {
    $0 is NSStackView && abs(($0.layer?.cornerRadius ?? 0) - 10) < 0.1
  }
  let sectionTitle = try #require(
    controller.view.descendants.compactMap { $0 as? NSTextField }.first { $0.stringValue == "通用" }
  )
  let sectionTitleFrame = sectionTitle.convert(sectionTitle.bounds, to: controller.view)
  let contentDocument = try #require(contentScroll.documentView)
  let contentDocumentType = String(describing: type(of: contentDocument))
  #expect(sidebarButtons.count == 9)
  #expect(sidebarButtons.allSatisfy { $0.frame.width >= 170 })
  #expect(contentScroll.documentView?.isFlipped == true)
  #expect(contentDocumentType.contains("FlippedDocumentView"))
  #expect((cards.first?.frame.width ?? 0) >= 650)
  #expect(sectionTitleFrame.maxY >= 690)
}

@Test("主题容器把 Otty 材质映射为原生视觉效果")
@MainActor
func themeMaterialUsesNativeVisualEffectView() throws {
  let glass = try #require(TerminalThemeCatalog.theme(named: "Glass Light"))
  let view = ThemeVisualEffectView()

  view.apply(material: glass.palette.material, tint: glass.palette.panelBackground)

  #expect(view.material == .hudWindow)
  #expect(view.blendingMode == .behindWindow)
  #expect(view.state == .active)
}

private extension NSView {
  var descendants: [NSView] {
    subviews + subviews.flatMap(\.descendants)
  }
}

/// 标签整理测试只验证 AppKit 列表，不需要真实 PTY。使用编辑器 Pane 避免与串行的
/// PTY 生命周期测试并发抢占伪终端资源，同时仍经过正式工作区快照恢复路径。
@MainActor
private func makeNonTerminalTestModel(
  defaults: UserDefaults,
  directories: [String]
) throws -> AppModel {
  let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
  let tabs = directories.enumerated().map { index, directory in
    WorkspaceTabSnapshot(
      id: UUID(),
      title: URL(fileURLWithPath: directory).lastPathComponent,
      layout: .leaf(
        PaneDescriptor(
          kind: .editor,
          workingDirectory: directory,
          resourcePath: "/tmp/aster-sidebar-test-\(index).txt"
        )
      ),
      createdAt: baseDate.addingTimeInterval(Double(index)),
      updatedAt: baseDate.addingTimeInterval(Double(index))
    )
  }
  let snapshot = WorkspaceSnapshot(
    selectedTabID: tabs.last?.id ?? UUID(),
    tabs: tabs
  )
  defaults.set(try JSONEncoder().encode(snapshot), forKey: "aster.workspace.snapshot.v1")
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  return model
}

@MainActor
private func makeTestWindow(content: NSViewController, size: NSSize) -> NSWindow {
  let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: size),
    styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.titleVisibility = .hidden
  window.titlebarAppearsTransparent = true
  window.contentViewController = content
  return window
}
