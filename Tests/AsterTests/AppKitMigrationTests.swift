import AppKit
import AsterCore
import SwiftTerm
import Testing

@testable import Aster

@Test("终端视图区分 OSC 8 显式链接与普通文字链接")
@MainActor
func terminalViewReportsDetectedLinkSource() {
  let view = AsterTerminalView(frame: .zero)

  #expect(
    view.detectedSource(
      for: "codex://session/123",
      payload: "id=docs;codex://session/123"
    ) == .osc8)
  #expect(
    view.detectedSource(
      for: "codex://session/123",
      payload: "id=other;codex://session/different"
    ) == .plainText)
  #expect(view.detectedSource(for: "codex://session/123", payload: nil) == .plainText)
}

@Test("目标打开协调器记住 OSC 8 非标准 scheme 的始终允许选择")
@MainActor
func targetOpenCoordinatorRemembersExplicitSchemePermission() {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.controls.detectAllLinkSchemes = false
  var opened: [URL] = []
  var confirmations: [TargetSecurityReason] = []
  let coordinator = TerminalTargetOpenCoordinator(
    preferences: preferences,
    inspectFile: { _ in .missing },
    openURL: { opened.append($0); return true },
    confirm: { reason in confirmations.append(reason); return .always },
    reportError: { message in Issue.record("不应报告错误：\(message)") }
  )

  let didOpen = coordinator.open(
    "codex://session/123",
    source: .osc8,
    currentDirectory: "/tmp"
  )

  #expect(didOpen)
  #expect(confirmations == [.nonStandardScheme("codex")])
  #expect(opened == [URL(string: "codex://session/123")!])
  #expect(preferences.configuration.controls.resolvedAllowedNonStandardLinkSchemes == ["codex"])
}

@Test("目标打开协调器拒绝未检测 scheme 和特殊文件且不调用系统打开")
@MainActor
func targetOpenCoordinatorRejectsUndetectedAndSpecialTargets() {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.controls.detectAllLinkSchemes = false
  var openCount = 0
  var errors: [String] = []
  let coordinator = TerminalTargetOpenCoordinator(
    preferences: preferences,
    inspectFile: { _ in .namedPipe },
    openURL: { _ in openCount += 1; return true },
    confirm: { _ in Issue.record("拒绝目标不应请求确认"); return .once },
    reportError: { errors.append($0) }
  )

  let customOpened = coordinator.open(
    "ssh://host.example",
    source: .plainText,
    currentDirectory: "/tmp"
  )
  let pipeOpened = coordinator.open(
    "/tmp/events.pipe",
    source: .plainText,
    currentDirectory: "/tmp"
  )

  #expect(!customOpened)
  #expect(!pipeOpened)
  #expect(openCount == 0)
  #expect(errors.count == 2)
}

@Test("系统打开失败时不持久化始终允许选择")
@MainActor
func targetOpenCoordinatorDoesNotRememberFailedOpen() {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  var errors: [String] = []
  let coordinator = TerminalTargetOpenCoordinator(
    preferences: preferences,
    openURL: { _ in false },
    confirm: { _ in .always },
    reportError: { errors.append($0) }
  )

  let didOpen = coordinator.open(
    "codex://session/failed",
    source: .plainText,
    currentDirectory: "/tmp"
  )

  #expect(!didOpen)
  #expect(preferences.configuration.controls.resolvedAllowedNonStandardLinkSchemes.isEmpty)
  #expect(errors.count == 1)
}

@Test("配置导入保留检测设置但剥离本机安全授权")
@MainActor
func configurationImportStripsSecurityPermissions() {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  var imported = AsterConfiguration.default
  imported.controls.detectAllLinkSchemes = false
  imported.controls.customLinkSchemes = ["codex"]
  imported.controls.allowedNonStandardLinkSchemes = ["codex"]

  preferences.importConfiguration(imported)

  #expect(preferences.configuration.controls.resolvedLinkSchemePolicy == .custom(["codex"]))
  #expect(preferences.configuration.controls.resolvedAllowedNonStandardLinkSchemes.isEmpty)
}

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
  // 悬停动作区：「+ 新建 / 折叠」按钮放在侧栏顶部右侧，默认隐藏，鼠标进入侧栏
  // 才淡入（2026-08 设计变更，替代旧的「标签栏不含按钮」断言）。
  let hoverButtons = controller.view.descendants.compactMap { $0 as? NSButton }.filter {
    $0.toolTip == "新建标签页" || ($0.toolTip ?? "").hasPrefix("折叠标签栏")
  }
  #expect(hoverButtons.count == 2)
  #expect(hoverButtons.allSatisfy { $0.superview?.isHidden == true && $0.superview?.alphaValue == 0 })
  #expect(controller.view.descendants.compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("LOCAL") } == false)
}

@Test("折叠标签栏后顶部提供悬停恢复入口")
@MainActor
func collapsedTabBarOffersHoverRecovery() throws {
  let defaults = isolatedDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  // 折叠标签栏：内容区顶部应叠加「+ 新建 / 展开」悬停动作区与点击穿透的悬停带。
  preferences.configuration.appearance.showTabBar = false
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))

  window.contentView?.layoutSubtreeIfNeeded()

  let buttons = controller.view.descendants.compactMap { $0 as? NSButton }
  let addButton = try #require(buttons.first { $0.toolTip == "新建标签页" })
  let expandButton = try #require(buttons.first { $0.toolTip == "展开标签栏" })
  // 默认隐藏（悬停才淡入）；按钮行必须让开红绿灯遮挡区（实测约 103pt）。
  let row = try #require(addButton.superview)
  #expect(row.isHidden && row.alphaValue == 0)
  #expect(row.superview === expandButton.superview?.superview)
  #expect(row.frame.minX >= 104)
  // 悬停带点击穿透：不拦截下方终端的点击与拖选。
  let strip = controller.view.descendants.first {
    String(describing: type(of: $0)).contains("ClickThroughStripView")
  }
  #expect(strip != nil)
  #expect(strip?.hitTest(.zero) == nil)
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
  // 标题区本身保持纯净（无按钮）；侧栏顶部的悬停动作按钮不属于标题区，不参与断言。
  let titlebarButtons = (titlebar?.descendants ?? []).filter {
    String(describing: type(of: $0)).contains("ActionButton")
  }
  let labels = controller.view.descendants.compactMap { ($0 as? NSTextField)?.stringValue }
  #expect(titlebar != nil)
  #expect(abs((titlebar?.frame.height ?? 0) - 28) < 0.5)
  #expect(titlebarMaterial?.blendingMode == .withinWindow)
  #expect(titlebarButtons.isEmpty)
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

  // 标签行选中与未选中都显示同一份 tab.title（目录稳定显示名），
  // 切换标签时主文案保持不变。
  preferences.sidebarTabGrouping = .none
  preferences.sidebarTabOrder = .createdTime
  var controller = makeController()
  #expect(primaryTabLabels(in: controller).first == "tmp")

  let oldestTab = try #require(model.tabs.first)
  model.select(oldestTab)
  preferences.sidebarTabOrder = .updatedTime
  controller = makeController()
  #expect(primaryTabLabels(in: controller).first == "mike")

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
  #expect(
    TerminalSession.normalizeReportedWorkingDirectory("file://remote.example/home/mike") == "")
}

@Test("设置页从顶部开始并让导航与卡片占满可用宽度")
@MainActor
func settingsLayoutUsesTopAnchoredFullWidthRows() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  // setContentViewController 会把窗口收缩到控制器视图的 700×460 默认尺寸，
  // 断言按该尺寸（内容区 500pt、卡片约 448pt）计算。
  let window = makeTestWindow(content: controller, size: NSSize(width: 700, height: 460))

  window.contentView?.layoutSubtreeIfNeeded()

  let sidebarButtons = controller.view.descendants.compactMap { view -> NSButton? in
    guard String(describing: type(of: view)).contains("SettingsSidebarButton") else { return nil }
    return view as? NSButton
  }
  let contentScroll = try #require(controller.view.descendants.compactMap { $0 as? NSScrollView }.first)
  let cards = controller.view.descendants.filter {
    $0 is NSStackView
      && abs(($0.layer?.cornerRadius ?? 0) - SettingsMetrics.cardCornerRadius) < 0.1
  }
  let contentDocument = try #require(contentScroll.documentView)
  // 只在内容滚动区内找分组标题：侧栏按钮内部也有「通用」文本，会干扰顶部锚定断言。
  let sectionTitle = try #require(
    contentDocument.descendants.compactMap { $0 as? NSTextField }.first { $0.stringValue == "通用" }
  )
  let sectionTitleFrame = sectionTitle.convert(sectionTitle.bounds, to: controller.view)
  let contentDocumentType = String(describing: type(of: contentDocument))
  #expect(sidebarButtons.count == 9)
  #expect(sidebarButtons.allSatisfy { $0.frame.width >= 170 })
  #expect(contentScroll.documentView?.isFlipped == true)
  #expect(contentDocumentType.contains("FlippedDocumentView"))
  #expect((cards.first?.frame.width ?? 0) >= 430)
  // 顶部锚定：分组标题需位于窗口顶部约 70pt 内（460 - 自动内容内边距 - 26pt 边距）。
  #expect(sectionTitleFrame.maxY >= 390)
  // 卡片内不再画 1pt hairline 分隔线：行间只靠留白（Otty 风格视觉决策的回归锁）。
  let firstCard = try #require(cards.first as? NSStackView)
  #expect(firstCard.arrangedSubviews.allSatisfy { $0.frame.height > 1 })
}

@Test("设置页所有分类的卡片保持左右边距且占满内容宽度")
@MainActor
func settingsCardsKeepHorizontalInsetsAcrossSections() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 700, height: 460))

  // 回归锁：长说明文字的单行固有宽度可能超过内容区可用宽度，NSStackView 的
  // .width 对齐 + edgeInsets 会把这种卡片丢到 x=0、宽度异常（系统集成卡片曾
  // 因此贴到内容区左边缘）。修复 = 对卡片施加显式 required 边距约束。
  for section in SettingsViewController.Section.allCases {
    controller.showSection(section)
    window.contentView?.layoutSubtreeIfNeeded()
    let scroll = try #require(controller.view.descendants.compactMap { $0 as? NSScrollView }.first)
    let content = try #require(scroll.documentView?.subviews.first as? NSStackView)
    let expectedWidth = content.frame.width - content.edgeInsets.left - content.edgeInsets.right
    let cards = content.arrangedSubviews.filter {
      $0 is NSStackView
        && abs(($0.layer?.cornerRadius ?? 0) - SettingsMetrics.cardCornerRadius) < 0.1
    }
    #expect(!cards.isEmpty)
    for card in cards {
      #expect(abs(card.frame.minX - content.edgeInsets.left) < 0.5, "\(section.rawValue) 页卡片左边距异常：\(card.frame)")
      #expect(abs(card.frame.width - expectedWidth) < 0.5, "\(section.rawValue) 页卡片宽度异常：\(card.frame)")
    }
  }
}

@Test("设置分类页由真实可交互控件构成而非只读文字")
@MainActor
func settingsSectionsExposeInteractiveControls() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 940, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()

  // 每个分类页的最少开关/下拉数量来自字段接线映射表，防止页面回退成 infoRow 文案。
  let expectations: [(SettingsViewController.Section, Int, Int)] = [
    (.general, 2, 5),
    (.shell, 10, 0),
    (.controls, 9, 0),
    (.editor, 6, 0),
    (.agents, 10, 0),
    (.recipes, 0, 1),
  ]
  for (section, minSwitches, minPopups) in expectations {
    controller.showSection(section)
    let switches = controller.view.descendants.count(where: { $0 is NSSwitch })
    let popups = controller.view.descendants.count(where: { $0 is NSPopUpButton })
    #expect(switches >= minSwitches, "\(section) 页开关数不足：\(switches) < \(minSwitches)")
    #expect(popups >= minPopups, "\(section) 页下拉数不足：\(popups) < \(minPopups)")
  }
}

@Test("设置页新接线字段写入配置后可从 UserDefaults 恢复")
@MainActor
func settingsWiredFieldsPersistAcrossRelaunch() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.general.closeTabConfirmation = .never
  preferences.configuration.shell.terminalBell = false
  preferences.configuration.controls.focusFollowsMouse = true
  preferences.configuration.controls.detectAllLinkSchemes = false
  preferences.configuration.controls.customLinkSchemes = ["codex"]
  preferences.configuration.controls.allowedNonStandardLinkSchemes = ["codex"]
  preferences.configuration.editor.tabSize = 6
  preferences.configuration.agents.enabledAgents = ["claude"]
  preferences.configuration.appearance.lineHeight = 1.5
  preferences.configuration.recipeReplayMode = .skip

  let reloaded = AppPreferences(defaults: defaults)
  #expect(reloaded.configuration.general.closeTabConfirmation == .never)
  #expect(reloaded.configuration.shell.terminalBell == false)
  #expect(reloaded.configuration.controls.focusFollowsMouse == true)
  #expect(reloaded.configuration.controls.resolvedLinkSchemePolicy == .custom(["codex"]))
  #expect(reloaded.configuration.controls.resolvedAllowedNonStandardLinkSchemes == ["codex"])
  #expect(reloaded.configuration.editor.tabSize == 6)
  #expect(reloaded.configuration.agents.enabledAgents == ["claude"])
  #expect(reloaded.configuration.appearance.lineHeight == 1.5)
  #expect(reloaded.configuration.recipeReplayMode == .skip)

  // 越界值在重新加载时经 normalized() 钳回合法范围。
  preferences.configuration.editor.tabSize = 99
  #expect(AppPreferences(defaults: defaults).configuration.editor.tabSize == 8)
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

/// 覆盖 Claude Code / vim 等 TUI 发送 `CSI Ps SP q` 的场景：用户配置过形状后，
/// 程序端请求必须被丢弃；未配置时仍保持 SwiftTerm 的默认（跟随程序）行为。
@Test("程序端 DECSCUSR 请求不会覆盖用户配置的光标形状")
@MainActor
func programmaticCursorStyleDoesNotOverrideConfiguration() async throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
  let terminal = view.getTerminal()

  view.preferredCursorStyle = .steadyBar
  terminal.options.cursorStyle = .steadyBar
  terminal.setCursorStyle(.blinkBlock)
  // 纠正被排到回调之后执行，断言前必须让主 actor 跑完那个任务。
  try await Task.sleep(for: .milliseconds(50))
  #expect(terminal.options.cursorStyle == .steadyBar)

  view.preferredCursorStyle = nil
  terminal.setCursorStyle(.blinkUnderline)
  try await Task.sleep(for: .milliseconds(50))
  #expect(terminal.options.cursorStyle == .blinkUnderline)
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
