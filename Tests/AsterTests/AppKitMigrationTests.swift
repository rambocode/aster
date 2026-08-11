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
  imported.controls.clipboardReadAccess = .allow
  imported.controls.clipboardWriteAccess = .deny

  preferences.importConfiguration(imported)

  #expect(preferences.configuration.controls.resolvedLinkSchemePolicy == .custom(["codex"]))
  #expect(preferences.configuration.controls.resolvedAllowedNonStandardLinkSchemes.isEmpty)
  #expect(preferences.configuration.controls.resolvedClipboardReadAccess == .ask)
  #expect(preferences.configuration.controls.resolvedClipboardWriteAccess == .deny)
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

@Test("设置使用独立窗口（宽度固定、高度可拉伸）且不改动主工作区")
@MainActor
func settingsUsesFixedIndependentWindow() throws {
  let defaults = isolatedDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  let workspace = WorkspaceViewController(model: model, preferences: preferences)
  let workspaceWindow = makeTestWindow(
    content: workspace,
    size: NSSize(width: 1_180, height: 760)
  )
  let workspaceFrame = workspaceWindow.frame
  let workspaceRoot = try #require(workspace.view.subviews.first)
  let settings = SettingsViewController(preferences: preferences)
  let settingsWindowController = AsterSettingsWindowController(
    content: settings,
    appearance: preferences.preferredAppearance,
    defaults: defaults
  )
  let settingsWindow = try #require(settingsWindowController.window)

  #expect(settingsWindow !== workspaceWindow)
  #expect(settingsWindow.contentViewController === settings)
  #expect(settingsWindow.contentView?.frame.size == SettingsViewController.defaultContentSize)
  // 宽度上下界相同 = 横向锁死；高度只有下界，纵向自由拉伸。
  #expect(settingsWindow.minSize.width == settingsWindow.frame.width)
  #expect(settingsWindow.maxSize.width == settingsWindow.frame.width)
  #expect(settingsWindow.minSize.height == settingsWindow.frame.height)
  #expect(settingsWindow.maxSize.height > settingsWindow.frame.height * 2)
  #expect(settingsWindow.styleMask.contains(.resizable))
  #expect(settingsWindow.standardWindowButton(.miniaturizeButton)?.isEnabled == false)
  #expect(workspaceWindow.frame == workspaceFrame)
  #expect(workspace.view.subviews.contains { $0 === workspaceRoot })
  #expect(!workspaceRoot.isHidden)
  #expect(!workspace.children.contains { $0 is SettingsViewController })
  let visibleLabels = settings.view.descendants.compactMap {
    ($0 as? NSTextField)?.stringValue
  }
  #expect(!visibleLabels.contains("返回工作区"))
}

@Test("设置窗口打开时切换主题会实时刷新主工作区")
@MainActor
func themeSelectionRefreshesWorkspaceWhileSettingsStayOpen() async throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(defaults: defaults, directories: ["/tmp/live-theme"])
  let preferences = AppPreferences(defaults: defaults)
  preferences.appearance = .light
  let workspace = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(
    content: workspace,
    size: NSSize(width: 1_180, height: 760)
  )
  window.contentView?.layoutSubtreeIfNeeded()
  workspace.setSettingsPresentationActive(true)

  let pink = try #require(TerminalThemeCatalog.theme(named: "Pink"))
  preferences.selectTheme(pink)
  // AppPreferences 在 will-change 阶段广播，工作区要等当前调用栈结束后读取新主题。
  try await Task.sleep(for: .milliseconds(30))
  window.contentView?.layoutSubtreeIfNeeded()

  let root = try #require(workspace.view as? ThemeVisualEffectView)
  #expect(root.appliedThemeTint == pink.resolvedColor(forSlot: "interface.window"))
  let sidebar = try #require(
    workspace.view.descendants.first {
      $0.identifier?.rawValue == "workspace-sidebar"
    } as? ThemeVisualEffectView
  )
  #expect(sidebar.appliedThemeTint == pink.resolvedColor(forSlot: "sidebar.background"))
}

@Test("菜单主题选择器实时预览且仅在确认后持久化")
@MainActor
func themeSwitcherPreviewsAndCommitsAsOneTransaction() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.appearance = .light
  let ayu = try #require(preferences.themes(for: .light).first { $0.name == "Ayu Light" })
  let pink = try #require(preferences.themes(for: .light).first { $0.name == "Pink" })
  preferences.selectTheme(ayu)

  preferences.previewTheme(pink)
  #expect(preferences.activeTheme.name == "Pink")
  #expect(preferences.configuration.appearance.themeName == "Ayu Light")
  #expect(AppPreferences(defaults: defaults).activeTheme.name == "Ayu Light")
  preferences.cancelThemePreview()
  #expect(preferences.activeTheme.name == "Ayu Light")

  let cancelled = ThemeSwitcherViewController(preferences: preferences)
  cancelled.loadViewIfNeeded()
  #expect(cancelled.visibleThemeNames.count == 9)
  #expect(cancelled.selectedThemeName == "Ayu Light")
  cancelled.moveSelection(1)
  let previewedName = try #require(cancelled.selectedThemeName)
  #expect(previewedName != "Ayu Light")
  #expect(preferences.activeTheme.name == previewedName)
  cancelled.cancelPresentation()
  #expect(preferences.activeTheme.name == "Ayu Light")

  let committed = ThemeSwitcherViewController(preferences: preferences)
  committed.loadViewIfNeeded()
  committed.moveSelection(1)
  let committedName = try #require(committed.selectedThemeName)
  committed.commitSelection()
  #expect(preferences.configuration.appearance.themeName == committedName)
  #expect(AppPreferences(defaults: defaults).activeTheme.name == committedName)
}

@Test("设置页保持原始 700×460pt 默认尺寸")
@MainActor
func settingsKeepsOriginalDefaultSize() {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)

  controller.loadViewIfNeeded()

  #expect(controller.view.frame.size == NSSize(width: 700, height: 460))
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
  // 悬停动作区：「+ 新建 / 折叠」按钮放在侧栏顶部右侧，默认隐藏，指针进入对应
  // 感应区才淡入（2026-08 设计变更，替代旧的「标签栏不含按钮」断言）。两个按钮
  // 各自显隐，因此隐藏状态记在按钮自己身上，而不是共享的容器上。
  let hoverButtons = controller.view.descendants.compactMap { $0 as? NSButton }.filter {
    $0.toolTip == "新建标签页" || ($0.toolTip ?? "").hasPrefix("折叠标签栏")
  }
  #expect(hoverButtons.count == 2)
  #expect(hoverButtons.allSatisfy { $0.isHidden && $0.alphaValue == 0 })
  // 容器保持可见但不参与命中测试，隐藏按钮的位置仍然可以拖动窗口。
  let hoverContainer = try #require(hoverButtons.first?.superview)
  #expect(hoverContainer.isHidden == false)
  let hoverProbe = NSPoint(x: hoverContainer.frame.midX, y: hoverContainer.frame.midY)
  #expect(hoverContainer.hitTest(hoverProbe) == nil)
  #expect(controller.view.descendants.compactMap { ($0 as? NSTextField)?.stringValue }.contains { $0.contains("LOCAL") } == false)
}

@Test("侧栏标签行使用两侧留边的圆角底卡")
@MainActor
func verticalSidebarRowsUseInsetRoundedCard() throws {
  let defaults = isolatedDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()

  let row = try #require(
    controller.view.descendants.first {
      String(describing: type(of: $0)).contains("TabRowButton")
    })
  // 底卡是行内唯一带圆角 layer 的子视图；行本体保持透明并维持整行命中宽度。
  let card = try #require(row.subviews.first { ($0.layer?.cornerRadius ?? 0) > 0 })
  #expect(card.frame.minX == 6)
  #expect(card.frame.maxX == row.bounds.width - 6)
  #expect(card.frame.height < row.bounds.height)
  #expect((card.layer?.cornerRadius ?? 0) >= 8)
  #expect(row.layer?.backgroundColor?.alpha == 0)
}

@Test("左侧标签悬停显示关闭按钮且可直接关闭后台标签")
@MainActor
func verticalSidebarHoverCloseClosesTargetTabWithoutSelectingIt() throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(
    defaults: defaults,
    directories: [NSHomeDirectory(), "/tmp"]
  )
  let preferences = AppPreferences(defaults: defaults)
  let selectedTabID = try #require(model.selectedTabID)
  let backgroundTab = try #require(model.tabs.first { $0.id != selectedTabID })
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()

  let closeButton = try #require(
    controller.view.descendants.compactMap { $0 as? NSButton }.first {
      $0.identifier?.rawValue == "sidebar-tab-close-\(backgroundTab.id.uuidString)"
    })
  let tabRow = try #require(closeButton.superview?.superview as? NSButton)
  #expect(closeButton.isHidden)

  let hoverEvent = try #require(NSEvent.mouseEvent(
    with: .mouseMoved,
    location: tabRow.convert(
      NSPoint(x: tabRow.bounds.midX, y: tabRow.bounds.midY), to: nil),
    modifierFlags: [],
    timestamp: 0,
    windowNumber: window.windowNumber,
    context: nil,
    eventNumber: 1,
    clickCount: 0,
    pressure: 0
  ))
  tabRow.mouseEntered(with: hoverEvent)
  #expect(closeButton.isHidden == false)

  closeButton.performClick(nil)

  #expect(model.tabs.contains { $0.id == backgroundTab.id } == false)
  #expect(model.selectedTabID == selectedTabID)
}

@Test("左侧标签行尾覆盖运行、等待、刚完成、未读、错误与空闲状态")
@MainActor
func verticalSidebarActivityAccessoryTracksAllStates() async throws {
  let defaults = isolatedDefaults()
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.agents.badgeProcessing = true
  preferences.configuration.agents.badgeAwaitingInput = true
  preferences.configuration.agents.badgeTaskComplete = true
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  defer { session.stop(immediately: true) }

  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .processing)
  )
  try await Task.sleep(for: .milliseconds(50))
  #expect(try visibleTabAccessory(for: tab, in: controller) is NSProgressIndicator)
  let lifecycleRow = try tabRow(for: tab, in: controller)

  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .awaitingInput)
  )
  try await Task.sleep(for: .milliseconds(50))
  #expect(
    (try visibleTabAccessory(for: tab, in: controller) as? NSTextField)?.stringValue == "✋"
  )
  #expect(try tabRow(for: tab, in: controller) === lifecycleRow)

  terminalView.onTerminalUserInput?()
  try await Task.sleep(for: .milliseconds(50))
  #expect(try visibleTabAccessory(for: tab, in: controller) is NSProgressIndicator)
  #expect(try tabRow(for: tab, in: controller) === lifecycleRow)

  terminalView.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .idle)
  )
  try await Task.sleep(for: .milliseconds(50))
  #expect(
    (try visibleTabAccessory(for: tab, in: controller) as? NSTextField)?.stringValue == "●"
  )
  #expect(try tabRow(for: tab, in: controller) === lifecycleRow)

  terminalView.onTerminalUserInput?()
  try await Task.sleep(for: .milliseconds(50))
  let readAccessory = try #require(visibleTabAccessory(for: tab, in: controller) as? NSTextField)
  #expect(readAccessory.stringValue != "●")
  #expect(try tabRow(for: tab, in: controller) === lifecycleRow)

  terminalView.onTerminalBadgeDirective?(.set(.completed))
  try await Task.sleep(for: .milliseconds(50))
  #expect(
    (try visibleTabAccessory(for: tab, in: controller) as? NSTextField)?.stringValue == "✓"
  )
  #expect(try tabRow(for: tab, in: controller) === lifecycleRow)

  terminalView.onTerminalBadgeDirective?(.set(.error))
  try await Task.sleep(for: .milliseconds(50))
  #expect(
    (try visibleTabAccessory(for: tab, in: controller) as? NSTextField)?.stringValue == "!"
  )
  #expect(try tabRow(for: tab, in: controller) === lifecycleRow)

  terminalView.onTerminalBadgeDirective?(.clear)
  try await Task.sleep(for: .milliseconds(50))
  let idleAccessory = try #require(visibleTabAccessory(for: tab, in: controller) as? NSTextField)
  #expect(!["✋", "●", "✓", "!"].contains(idleAccessory.stringValue))
  #expect(try tabRow(for: tab, in: controller) === lifecycleRow)
}

/// 状态附件与悬停关闭按钮共享固定槽位；只读取当前可见附件，避免测试依赖具体视图层级
/// 之外的布局实现，同时仍覆盖用户看到的行尾状态变化。
@MainActor
private func visibleTabAccessory(
  for tab: TerminalTabItem,
  in controller: WorkspaceViewController
) throws -> NSView {
  let close = try #require(
    controller.view.descendants.compactMap { $0 as? NSButton }.first {
      $0.identifier?.rawValue == "sidebar-tab-close-\(tab.id.uuidString)"
    }
  )
  let slot = try #require(close.superview)
  return try #require(slot.subviews.first { $0 !== close && !$0.isHidden })
}

@MainActor
private func tabRow(
  for tab: TerminalTabItem,
  in controller: WorkspaceViewController
) throws -> TabRowButton {
  try #require(
    controller.view.descendants.compactMap { $0 as? TabRowButton }.first {
      $0.identifier?.rawValue == "workspace-tab-row-\(tab.id.uuidString)"
    }
  )
}

@Test("终端工作区不再渲染底部状态栏")
@MainActor
func terminalWorkspaceOmitsBottomStatusBar() throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(defaults: defaults, directories: [NSHomeDirectory()])
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.appearance.showStatusBar = true
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()

  let labels = controller.view.descendants.compactMap { ($0 as? NSTextField)?.stringValue }
  #expect(labels.contains { $0.contains("●  workspace") } == false)
  #expect(labels.contains { $0.contains("UTF-8") } == false)

  let settings = SettingsViewController(preferences: preferences)
  settings.loadViewIfNeeded()
  let settingLabels = settings.view.descendants.compactMap { ($0 as? NSTextField)?.stringValue }
  #expect(settingLabels.contains("显示状态栏") == false)
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
  // 默认隐藏（悬停才淡入）；折叠态两个按钮共用同一条顶部悬停带，同时显隐。
  #expect(addButton.isHidden && addButton.alphaValue == 0)
  #expect(expandButton.isHidden && expandButton.alphaValue == 0)
  // 按钮行必须让开红绿灯遮挡区（实测约 103pt）。
  let row = try #require(addButton.superview)
  #expect(row === expandButton.superview)
  #expect(row.frame.minX >= 104)
  // 悬停带点击穿透：不拦截下方终端的点击与拖选。
  let strip = controller.view.descendants.first {
    String(describing: type(of: $0)).contains("ClickThroughStripView")
  }
  #expect(strip != nil)
  #expect(strip?.hitTest(.zero) == nil)
}

@Test("工作区中央标题与 Pane 共用同一背景面并在悬停时显示路径胶囊")
@MainActor
func workspaceTitlebarMatchesOttyChrome() throws {
  let defaults = isolatedDefaults()
  let model = try makeNonTerminalTestModel(
    defaults: defaults,
    directories: ["/Users/mike/source/project/AsterTerminal"]
  )
  let preferences = AppPreferences(defaults: defaults)
  preferences.appearance = .light
  let glass = try #require(
    preferences.themes(for: .light).first { $0.name == "Glass Light" })
  preferences.selectTheme(glass)
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))

  window.contentView?.layoutSubtreeIfNeeded()

  let titlebar = controller.view.descendants.first {
    $0.identifier?.rawValue == "workspace-titlebar"
  }
  let titleButton = try #require(
    titlebar?.descendants.compactMap { $0 as? NSButton }.first {
      $0.identifier?.rawValue == "workspace-title-button"
    }
  )
  #expect(titlebar != nil)
  #expect(abs((titlebar?.frame.height ?? 0) - 28) < 0.5)
  let titlebarForeground = try #require(
    preferences.activeTheme.colorSlots.first { $0.id == "titlebar.foreground" }
  ).resolved
  // 标题只是中央 workspace 背景面上的内容，不能再建立一层独立 material；否则透明
  // 主题会在 28pt 高度处重复合成玻璃，和下面的 Pane 形成明显横向分割。
  #expect(titlebar is ThemeVisualEffectView == false)
  #expect(titlebar?.layer?.backgroundColor == NSColor.clear.cgColor)
  // `none` 是真实透明语义，不允许再用截图采样出的灰色替代。
  #expect(
    HexColor(nsColor: preferences.terminalCanvasBackgroundColor)
      == preferences.activeTheme.palette.windowBackground)
  #expect(HexColor(nsColor: titleButton.contentTintColor ?? .clear) == titlebarForeground)
  let explicitTitlebarBackground = preferences.activeTheme.style.titlebarBackground
    .map { NSColor($0).cgColor }
  #expect(
    titleButton.layer?.backgroundColor
      == (explicitTitlebarBackground ?? NSColor.clear.cgColor)
  )
  #expect(titleButton.title.contains("AsterTerminal"))
  #expect(titleButton.title.hasSuffix("⋯"))

  let hover = try #require(
    NSEvent.mouseEvent(
      // `NSEvent.mouseEvent` 只能构造鼠标按钮/移动事件；直接调用 mouseEntered 时使用
      // 同坐标的 mouseMoved 即可，避免 AppKit 因伪造 tracking 事件抛异常。
      with: .mouseMoved,
      location: titleButton.convert(
        NSPoint(x: titleButton.bounds.midX, y: titleButton.bounds.midY), to: nil),
      modifierFlags: [],
      timestamp: 0,
      windowNumber: window.windowNumber,
      context: nil,
      eventNumber: 0,
      clickCount: 0,
      pressure: 0
    )
  )
  titleButton.mouseEntered(with: hover)
  #expect(titleButton.title.contains("AsterTerminal"))
  #expect(titleButton.title.hasSuffix("⋯"))
  #expect(titleButton.layer?.backgroundColor != NSColor.clear.cgColor)
  #expect(HexColor(nsColor: titleButton.contentTintColor ?? .clear) == titlebarForeground)
}

@Test("主题详情改色写回对应 Otty 配置，清空覆盖会移除个性化段")
@MainActor
func themeColorOverridesPersistToOttyThemeFile() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let sourceURL = directory.appendingPathComponent("ayu-light.ottytheme")
  let original = "[meta]\nname = \"Ayu Light\"\n\n[terminal]\nbackground = \"#FCFCFC\"\n"
  try original.write(to: sourceURL, atomically: true, encoding: .utf8)

  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults, ottyThemesDirectoryURL: directory)
  let theme = try #require(TerminalThemeCatalog.theme(named: "Ayu Light"))
  preferences.setThemeColor(
    try #require(HexColor("#123456")), slotID: "sidebar.background", themeID: theme.id)

  let writtenURL = try #require(
    try preferences.writeThemeOverridesToLibraryFolder(themeID: theme.id))
  #expect(writtenURL == sourceURL)
  let personalized = try String(contentsOf: sourceURL, encoding: .utf8)
  #expect(personalized.hasPrefix(original.trimmingCharacters(in: .newlines)))
  #expect(personalized.contains(ThemeOverrideFileWriter.marker))
  #expect(personalized.contains("# otty-added: sidebar.background"))
  #expect(personalized.contains("background = \"#123456\""))

  preferences.clearThemeOverrides(themeID: theme.id)
  let resetURL = try #require(
    try preferences.writeThemeOverridesToLibraryFolder(themeID: theme.id))
  #expect(resetURL == sourceURL)
  #expect(
    try String(contentsOf: sourceURL, encoding: .utf8)
      == original.trimmingCharacters(in: .newlines) + "\n")
}

@Test("点击标题路径胶囊弹出可操作的工作区菜单")
@MainActor
func workspaceTitlePopoverExposesWorkingActions() throws {
  let defaults = isolatedDefaults()
  let directory = "/Users/mike/source/project/AsterTerminal"
  let model = try makeNonTerminalTestModel(defaults: defaults, directories: [directory])
  let preferences = AppPreferences(defaults: defaults)
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  defer { window.orderOut(nil) }
  window.makeKeyAndOrderFront(nil)
  window.contentView?.layoutSubtreeIfNeeded()

  let titleButton = try #require(
    controller.view.descendants.compactMap { $0 as? NSButton }.first {
      $0.identifier?.rawValue == "workspace-title-button"
    }
  )
  titleButton.performClick(nil)
  RunLoop.current.run(until: Date().addingTimeInterval(0.05))

  let popover = try #require(
    NSApp.windows.compactMap(\.contentView).first {
      $0.identifier?.rawValue == "workspace-title-popover"
        || $0.descendants.contains {
          $0.identifier?.rawValue == "workspace-title-popover"
        }
    }
  )
  let root = popover.identifier?.rawValue == "workspace-title-popover"
    ? popover
    : try #require(popover.descendants.first {
      $0.identifier?.rawValue == "workspace-title-popover"
    })
  let labels = root.descendants.compactMap { ($0 as? NSTextField)?.stringValue }
  let buttons = root.descendants.compactMap { $0 as? NSButton }
  #expect(labels.contains("WORKING DIRECTORY"))
  #expect(labels.contains((directory as NSString).abbreviatingWithTildeInPath + "/"))
  for identifier in [
    "workspace-title-copy-path", "workspace-title-reveal-finder", "workspace-title-open-in",
    "workspace-title-git", "workspace-title-notifications", "workspace-title-split",
    "workspace-title-find", "workspace-title-global-find", "workspace-title-jump",
    "workspace-title-palette",
  ] {
    #expect(buttons.contains { $0.identifier?.rawValue == identifier }, "缺少动作：\(identifier)")
  }

  let mode = try #require(root.descendants.compactMap { $0 as? NSSegmentedControl }.first)
  let field = try #require(root.descendants.compactMap { $0 as? NSTextField }.first {
    $0.identifier?.rawValue == "workspace-title-name-field"
  })
  mode.selectedSegment = 1
  _ = NSApp.sendAction(try #require(mode.action), to: mode.target, from: mode)
  field.stringValue = "dev: "
  _ = NSApp.sendAction(try #require(field.action), to: field.target, from: field)
  #expect(model.selectedTab?.tabTitleOverride == .prefix("dev: "))

  let reset = try #require(buttons.first {
    $0.identifier?.rawValue == "workspace-title-reset-name"
  })
  reset.performClick(nil)
  #expect(model.selectedTab?.tabTitleOverride == .automatic)

  let find = try #require(buttons.first { $0.identifier?.rawValue == "workspace-title-find" })
  find.performClick(nil)
  #expect(model.isFindPresented)
  let global = try #require(buttons.first {
    $0.identifier?.rawValue == "workspace-title-global-find"
  })
  global.performClick(nil)
  #expect(model.isGlobalFindPresented)
  let jump = try #require(buttons.first { $0.identifier?.rawValue == "workspace-title-jump" })
  jump.performClick(nil)
  #expect(model.isOpenQuicklyPresented)
  let palette = try #require(buttons.first {
    $0.identifier?.rawValue == "workspace-title-palette"
  })
  palette.performClick(nil)
  #expect(model.isPalettePresented)
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

@Test("外观设置的主题网格每行放四张等宽卡片")
@MainActor
func appearanceThemeGridUsesFourEqualColumns() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 700, height: 460))
  controller.showSection(.appearance)
  window.contentView?.layoutSubtreeIfNeeded()

  let cards = controller.view.descendants.filter {
    String(describing: type(of: $0)).contains("ThemeCardButton")
  }
  #expect(cards.count >= 8)
  // 同一行的卡片共用一个父视图（等分行栈）；行内张数与宽度都要一致。
  let rows = Dictionary(grouping: cards) { ObjectIdentifier($0.superview ?? $0) }
  let fullRows = rows.values.filter { $0.count == 4 }
  #expect(fullRows.count >= 2)
  #expect(rows.values.allSatisfy { $0.count <= 4 })
  for row in fullRows {
    let widths = row.map(\.frame.width)
    // fillEqually 在宽度不能整除时会把余数分给个别列，允许 1pt 的取整差。
    #expect((widths.max() ?? 0) - (widths.min() ?? 0) <= 1.0)
    // 700pt 窗口下内容区约 448pt，四等分后单卡仍需保持可读宽度。
    #expect((widths.first ?? 0) >= 84)
  }
}

@Test("设置页配色不跟随终端主题，卡片使用固定灰底")
@MainActor
func settingsChromeIgnoresTerminalTheme() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 700, height: 460))
  window.contentView?.layoutSubtreeIfNeeded()

  func cardColors() -> [NSColor] {
    controller.view.descendants
      .filter { abs(($0.layer?.cornerRadius ?? 0) - SettingsMetrics.cardCornerRadius) < 0.1 }
      .compactMap { $0.layer?.backgroundColor }
      .map { NSColor(cgColor: $0) ?? .clear }
  }
  let before = cardColors()
  #expect(!before.isEmpty)

  // 浅色外观下卡片就是 #FAFAFA。
  let expected = SettingsTheme.card.usingColorSpace(.sRGB)
  controller.view.appearance = NSAppearance(named: .aqua)
  let sample = try #require(cardColors().first?.usingColorSpace(.sRGB))
  #expect(abs(sample.redComponent - (expected?.redComponent ?? 0)) < 0.01)

  // 把当前主题换成一套完全不同的配色，设置页的卡片底色不得跟着变。
  preferences.selectTheme(
    TerminalThemeCatalog.resolve(named: "Catppuccin Mocha", customThemes: [], mode: .dark))
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(cardColors() == before)
}

@Test("色板改色写成覆盖层，内置主题不被复制成副本")
@MainActor
func themeSwatchColorPickWritesOverrideWithoutDuplicating() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  // `activeTheme` 在 appearance == .system 时会读 `NSApp.effectiveAppearance`，
  // 测试进程里必须先把 NSApplication 实例化，否则隐式解包直接崩。
  _ = NSApplication.shared
  let builtIn = preferences.activeTheme
  #expect(builtIn.isBuiltIn)
  let controller = SettingsViewController(preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 700, height: 460))
  controller.showSection(.appearance)
  window.contentView?.layoutSubtreeIfNeeded()

  let swatch = try #require(
    controller.view.descendants.first {
      $0.identifier?.rawValue == "theme-slot-interface.window"
    } as? NSControl)
  swatch.mouseDown(with: makeClickEvent(in: window))

  let picker = try #require(
    controller.presentedViewControllers?.compactMap { $0 as? InlineColorPickerViewController }
      .first)
  let hexField = try #require(
    picker.view.descendants.compactMap { $0 as? NSTextField }.first {
      $0.identifier?.rawValue == "inline-color-picker-hex"
    })
  // 真实输入会先触发 textDidChange；取色器据此区分「用户敲的」与「程序回写的」。
  hexField.stringValue = "#123456"
  NotificationCenter.default.post(name: NSControl.textDidChangeNotification, object: hexField)
  NotificationCenter.default.post(name: NSControl.textDidEndEditingNotification, object: hexField)

  // 改色只写覆盖表：主题库里不该多出「副本」，内置主题也仍然是内置的。
  #expect(preferences.themeLibrary.customThemes.isEmpty)
  #expect(preferences.themeOverrides(for: builtIn.id)["interface.window"]?.displayString == "#123456")
  #expect(preferences.activeTheme.palette.interfaceWindowBackground?.displayString == "#123456")
  #expect(preferences.activeTheme.id == builtIn.id)
  // 回归锁：`updateTheme` 广播会触发整页重建，销毁 popover 锚点后取色目标被清空、
  // 后续改色全部丢失——表现就是「调完颜色关掉，值没设置上」。色板视图实例不变即
  // 说明取色期间没有重建。
  let swatchAfterPick = controller.view.descendants.first {
    $0.identifier?.rawValue == "theme-slot-interface.window"
  }
  #expect(swatchAfterPick === swatch)

  // 撤销覆盖后完整回到内置主题的原始配色。
  preferences.clearThemeOverrides(themeID: builtIn.id)
  #expect(
    preferences.activeTheme.palette.interfaceWindowBackground
      == builtIn.palette.interfaceWindowBackground)
}

@Test("主题详情渲染出可点可悬停的完整 token 色板")
@MainActor
func appearanceThemeDetailRendersFullColorSlotBoard() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 700, height: 460))
  controller.showSection(.appearance)
  window.contentView?.layoutSubtreeIfNeeded()

  let expected = preferences.activeTheme.colorSlots
  let swatches = controller.view.descendants.filter {
    $0.identifier?.rawValue.hasPrefix("theme-slot-") == true
  }
  // 色板逐个渲染领域层给出的 token，不在界面里另立一套清单。
  #expect(swatches.count == expected.count)
  for slot in expected {
    let swatch = try #require(
      swatches.first { $0.identifier?.rawValue == "theme-slot-\(slot.id)" })
    // hover 提示带 token 名与色值，用户能照着改 .ottytheme 文件。
    #expect(swatch.toolTip == slot.tooltip)
    #expect(swatch.toolTip?.contains(slot.id) == true)
  }
  // 分组名比普通行文案小两号，色块才是这块的主角。只在胶囊内部找，避免匹配到
  // 「光标」「选区」这类同名的分组小标题。
  let capsules = controller.view.descendants.filter {
    String(describing: type(of: $0)).contains("ThemeColorGroupCapsule")
  }
  #expect(capsules.count == ThemeColorGroup.allCases.count - 1)  // terminal 组画在顶部，不出胶囊
  let groupLabels = capsules.flatMap { $0.descendants.compactMap { $0 as? NSTextField } }
  #expect(groupLabels.count == capsules.count)
  #expect(groupLabels.allSatisfy { ($0.font?.pointSize ?? 0) == 10 })
  // 派生态必须能从 tooltip 区分出来，否则看不出「改 window 会不会连带变」。
  #expect(expected.contains { $0.isDerived })
  #expect(
    swatches.contains { $0.toolTip?.contains("跟随 Window 派生") == true })
}

@Test("设置页每个顶层区块在窄窗口与宽窗口下都保持左右边距")
@MainActor
func settingsTopLevelBlocksKeepInsetsAtEverySize() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 700, height: 460))

  // 回归锁：以前只有 card / 分组标题有显式边距约束，其余顶层项（主题网格、主题详情、
  // 字体块、布局选择行）靠 NSStackView 的 .width 对齐。窗口放大后它们会缩成固有宽度
  // 并靠右，窄窗口下又会丢掉左边距——两种尺寸都要锁。
  for width in [700.0, 1_400.0] as [CGFloat] {
    window.setContentSize(NSSize(width: width, height: 900))
    for section in SettingsViewController.Section.allCases {
      controller.showSection(section)
      window.contentView?.layoutSubtreeIfNeeded()
      let scroll = try #require(controller.view.descendants.compactMap { $0 as? NSScrollView }.first)
      let content = try #require(scroll.documentView?.subviews.first as? NSStackView)
      let expectedWidth = content.frame.width - content.edgeInsets.left - content.edgeInsets.right
      for item in content.arrangedSubviews {
        // 约束作用在 alignment rect 上：NSTextField 的 frame 比它每边宽 2pt，
        // 直接比 frame 会把正常的标题误判成越界。
        let box = item.alignmentRect(forFrame: item.frame)
        #expect(
          abs(box.minX - content.edgeInsets.left) < 0.5,
          "\(section.rawValue) @\(Int(width)) 顶层项左边距异常：\(box)")
        #expect(
          abs(box.width - expectedWidth) < 0.5,
          "\(section.rawValue) @\(Int(width)) 顶层项宽度异常：\(box)")
      }
    }
  }
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
    (.appearance, 6, 10),
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

@Test("设置开关点击后就地更新且不重建当前页面")
@MainActor
func settingsSwitchUpdatesInPlaceWithoutRebuildingPage() async throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 700, height: 460))
  window.contentView?.layoutSubtreeIfNeeded()
  let originalSwitch = try #require(
    controller.view.descendants.compactMap { $0 as? NSSwitch }.first)

  originalSwitch.performClick(nil)
  // 设置页的配置订阅通过主队列合并刷新。等待队列排空后再检查控件身份，才能捕获
  // “点击后整页重建并销毁正在播放切换动画的 NSSwitch”这一真实卡顿路径。
  await withCheckedContinuation { continuation in
    DispatchQueue.main.async { continuation.resume() }
  }

  #expect(preferences.configuration.general.quitAfterLastWindowClosed)
  #expect(controller.view.descendants.contains { $0 === originalSwitch })
}

@Test("设置内容区字号小于左侧导航字号")
@MainActor
func settingsContentTypographyIsSmallerThanSidebarNavigation() throws {
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  controller.loadViewIfNeeded()

  let labels = controller.view.descendants.compactMap { $0 as? NSTextField }
  let sidebarLabel = try #require(labels.first { $0.stringValue == "智能体" })
  let rowTitle = try #require(labels.first { $0.stringValue == "语言" })
  let rowDetail = try #require(labels.first { $0.stringValue == "界面显示语言" })

  #expect(rowTitle.font?.pointSize == SettingsMetrics.rowTitleSize)
  #expect(rowDetail.font?.pointSize == SettingsMetrics.rowDetailSize)
  #expect((rowTitle.font?.pointSize ?? .greatestFiniteMagnitude) < (sidebarLabel.font?.pointSize ?? 0))
  #expect((rowDetail.font?.pointSize ?? .greatestFiniteMagnitude) < (rowTitle.font?.pointSize ?? 0))
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
  preferences.configuration.controls.shiftArrowSelection = false
  preferences.configuration.controls.clearSelectionOnTyping = false
  preferences.configuration.controls.scrollPastLastLine = .lastLineInMiddle
  preferences.configuration.controls.scrollPastFirstLine = .firstLineWithContent
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
  #expect(!reloaded.configuration.controls.resolvedShiftArrowSelection)
  #expect(!reloaded.configuration.controls.resolvedClearSelectionOnTyping)
  #expect(reloaded.configuration.controls.resolvedScrollPastLastLine == .lastLineInMiddle)
  #expect(reloaded.configuration.controls.resolvedScrollPastFirstLine == .firstLineWithContent)
  #expect(reloaded.configuration.editor.tabSize == 6)
  #expect(reloaded.configuration.agents.enabledAgents == ["claude"])
  #expect(reloaded.configuration.appearance.lineHeight == 1.5)
  #expect(reloaded.configuration.recipeReplayMode == .skip)

  // 越界值在重新加载时经 normalized() 钳回合法范围。
  preferences.configuration.editor.tabSize = 99
  #expect(AppPreferences(defaults: defaults).configuration.editor.tabSize == 8)
}

@Test("外观设置覆盖主题光标颜色并应用不透明度")
@MainActor
func appearanceCursorOverridesThemeAndAppliesOpacity() throws {
  _ = NSApplication.shared
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.appearance = .light
  preferences.configuration.appearance.cursorColorOverride = HexColor("#102030")!
  preferences.configuration.appearance.cursorTextColorOverride = HexColor("#F0E0D0")!
  preferences.configuration.appearance.cursorOpacity = 0.5

  let cursor = try #require(preferences.cursorColor.usingColorSpace(.sRGB))
  let cursorText = try #require(preferences.cursorTextColor.usingColorSpace(.sRGB))

  #expect(abs(cursor.redComponent - (16.0 / 255.0)) < 0.001)
  #expect(abs(cursor.alphaComponent - 0.5) < 0.001)
  #expect(abs(cursorText.redComponent - (240.0 / 255.0)) < 0.001)
  #expect(abs(cursorText.alphaComponent - 1) < 0.001)
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

@Test("透明主题实时覆盖终端自身的旧 backing layer 背景")
@MainActor
func transparentThemeRefreshesTerminalBackingLayer() throws {
  _ = NSApplication.shared
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.appearance = .light
  let glass = try #require(
    preferences.themes(for: .light).first { $0.name == "Glass Light" })
  preferences.selectTheme(glass)

  let session = TerminalSession(workingDirectory: "/tmp")
  let view = session.makeTerminalView(preferences: preferences)
  view.wantsLayer = true
  // SwiftTerm 的尺寸初始化会把当时的 native 背景写进 backing layer；模拟一个在主题
  // 切换前已经形成的黑底，确保 apply 不只更新绘制色，也会清掉旧 layer。
  view.layer?.backgroundColor = NSColor.black.cgColor

  session.apply(preferences: preferences)

  let backing = try #require(view.layer?.backgroundColor)
  let backingColor = try #require(NSColor(cgColor: backing))
  #expect(HexColor(nsColor: backingColor) == preferences.activeTheme.palette.windowBackground)
  #expect(
    HexColor(nsColor: view.nativeBackgroundColor)
      == preferences.activeTheme.palette.windowBackground)
}

@Test("菜单主题切换会同步刷新每个已运行终端 Pane")
@MainActor
func themePreviewRefreshesEveryRunningTerminalPane() async throws {
  _ = NSApplication.shared
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.appearance = .light
  let solarized = try #require(
    preferences.themes(for: .light).first { $0.name == "Solarized Light" })
  let april = try #require(
    preferences.themes(for: .light).first { $0.name == "April" })
  preferences.selectTheme(solarized)

  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  model.splitSelectedTab(.right)
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()

  preferences.previewTheme(april)
  try await Task.sleep(for: .milliseconds(50))
  window.contentView?.layoutSubtreeIfNeeded()

  let terminals = controller.view.descendants.compactMap { $0 as? AsterTerminalView }
  #expect(terminals.count == 2)
  for terminal in terminals {
    #expect(HexColor(nsColor: terminal.nativeBackgroundColor) == april.palette.windowBackground)
    let backing = try #require(terminal.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
    #expect(HexColor(nsColor: backing) == april.palette.windowBackground)
  }
}

@Test("显示菜单字号命令会刷新已经运行的终端字体")
@MainActor
func displayFontCommandsRefreshExistingTerminalViews() async throws {
  _ = NSApplication.shared
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()
  let terminal = try #require(
    controller.view.descendants.compactMap { $0 as? AsterTerminalView }.first)
  let initialSize = terminal.font.pointSize

  preferences.adjustFontSize(by: 1)
  try await Task.sleep(for: .milliseconds(50))

  #expect(terminal.font.pointSize == initialSize + 1)
}

@Test("Shell 异常退出会显示可恢复状态并重启同一 Pane")
@MainActor
func abnormalShellExitShowsRecoveryInsteadOfZombiePane() async throws {
  _ = NSApplication.shared
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let session = try #require(model.selectedTab?.activeSession)
  defer { session.stop(immediately: true) }

  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()
  let originalTerminal = try #require(
    controller.view.descendants.compactMap { $0 as? AsterTerminalView }.first)

  // 使用真实登录 Shell 退出路径，而不是直接改 Session 标志。该路径覆盖 PTY 尾部输出、
  // waitpid 状态转换、工作区刷新和用户最终看到的 Pane，能稳定抓住“旧画面仍在但无法
  // 输入，也没有任何结束提示”的僵尸终端缺陷。
  session.send("exit 7")
  for _ in 0..<100 where session.statusIsRunning {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(!session.statusIsRunning)

  let overlayIdentifier = "terminal-ended-overlay-\(session.id.uuidString)"
  var endedOverlay: NSView?
  for _ in 0..<50 {
    window.contentView?.layoutSubtreeIfNeeded()
    endedOverlay = controller.view.descendants.first {
      $0.identifier?.rawValue == overlayIdentifier
    }
    if endedOverlay != nil { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  let overlay = try #require(endedOverlay)
  let labels = overlay.descendants.compactMap { ($0 as? NSTextField)?.stringValue }
  #expect(labels.contains { $0.contains("Shell 异常退出") })
  #expect(labels.contains { $0.contains("状态码 7") })

  let restartIdentifier = "terminal-restart-shell-\(session.id.uuidString)"
  let restart = try #require(
    overlay.descendants.compactMap { $0 as? NSButton }.first {
      $0.identifier?.rawValue == restartIdentifier
    })
  restart.performClick(nil)
  for _ in 0..<100 where !session.statusIsRunning {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(session.statusIsRunning)
  for _ in 0..<50 {
    window.contentView?.layoutSubtreeIfNeeded()
    if controller.view.descendants.contains(where: {
      $0.identifier?.rawValue == overlayIdentifier
    }) == false { break }
    try await Task.sleep(for: .milliseconds(20))
  }

  let restartedTerminal = try #require(
    controller.view.descendants.compactMap { $0 as? AsterTerminalView }.first)
  #expect(restartedTerminal !== originalTerminal)
  #expect(controller.view.descendants.contains {
    $0.identifier?.rawValue == overlayIdentifier
  } == false)

  // 模拟上一代输出总线/进程 monitor 在新 PTY 已启动后才送达的迟到通知。该通知必须
  // 按 View 身份被忽略，否则刚恢复的终端会再次落入“屏幕存在但输入无效”的僵尸状态。
  session.processTerminated(source: originalTerminal, exitCode: 9)
  try await Task.sleep(for: .milliseconds(20))
  #expect(session.statusIsRunning)
  #expect(session.lifecycleState == .running)

  let sentinel = "ASTER_RESTARTED_\(UUID().uuidString.prefix(8))"
  session.send("printf '\(sentinel)\\n'")
  for _ in 0..<100 where !session.textSnapshot().lines.contains(where: { $0.contains(sentinel) }) {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(session.textSnapshot().lines.contains { $0.contains(sentinel) })
}

@Test("手动安全键盘输入在工作区标题栏显示状态胶囊")
@MainActor
func workspaceShowsSecureInputIndicator() async throws {
  _ = NSApplication.shared
  let defaults = isolatedDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  let coordinator = SecureInputCoordinator(
    enableSystemProtection: { true },
    disableSystemProtection: { true }
  )
  model.ensureInitialTab()
  let controller = WorkspaceViewController(
    model: model,
    preferences: preferences,
    secureInputCoordinator: coordinator
  )
  let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
  window.contentView?.layoutSubtreeIfNeeded()

  func currentIndicator() -> NSView? {
    controller.view.descendants.first {
      $0.identifier?.rawValue == "workspace-secure-input-indicator"
    }
  }
  #expect(try #require(currentIndicator()).isHidden)

  coordinator.setManualRequest(active: true)
  await Task.yield()
  let activeIndicator = try #require(currentIndicator())
  #expect(!activeIndicator.isHidden)
  #expect(activeIndicator.layer?.backgroundColor == SecureInputIndicatorView.secureBackgroundColor.cgColor)
  let indicatorLabels = activeIndicator.descendants.compactMap {
    ($0 as? NSTextField)?.stringValue
  }
  #expect(indicatorLabels.contains("SECURE INPUT"))

  coordinator.setManualRequest(active: false)
  await Task.yield()
  #expect(try #require(currentIndicator()).isHidden)
}

@Suite("浅色 Otty 主题呈现矩阵", .serialized)
@MainActor
struct LightThemeRenderParityTests {
  @Test("九套浅色主题的设置颜色逐项到达最终工作区对象")
  func everyLightThemeReachesRenderedWorkspaceObjects() throws {
    _ = NSApplication.shared
    let themes = TerminalThemeCatalog.builtIns.filter { $0.mode == .light }
    #expect(themes.count == 9)

    for theme in themes {
      try verifyVerticalWorkspace(theme)
      try verifyHorizontalWorkspace(theme)
    }
  }

  /// 竖直布局覆盖截图里的 Window、Container、Sidebar、Titlebar、Tab，以及终端、
  /// ANSI、光标和选区。右侧详情面板与左侧标签栏必须消费同一组 Sidebar token。
  private func verifyVerticalWorkspace(_ theme: TerminalTheme) throws {
    let defaults = isolatedDefaults()
    let preferences = AppPreferences(defaults: defaults)
    preferences.appearance = .light
    preferences.selectTheme(theme)
    preferences.tabBarLayout = .vertical
    let activeTheme = preferences.activeTheme
    let model = try makeNonTerminalTestModel(
      defaults: defaults,
      directories: ["/tmp/theme-matrix-first", "/tmp/theme-matrix-selected"]
    )
    let controller = WorkspaceViewController(model: model, preferences: preferences)
    let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
    window.contentView?.layoutSubtreeIfNeeded()

    let root = try #require(controller.view as? ThemeVisualEffectView)
    let windowColor = try slot("interface.window", in: activeTheme)
    #expect(root.appliedThemeTint == windowColor, "\(theme.name) Window")

    let sidebar = try themedView("workspace-sidebar", in: controller)
    // 详情控制器在生产中由可动画的 Panel host 延迟接入 split；单独加载其稳定根视图，
    // 可以直接验证主题而不把显隐转场时序引入颜色测试。
    let detailsController = DetailsPanelViewController(model: model, preferences: preferences)
    detailsController.loadViewIfNeeded()
    let details = try #require(detailsController.view as? ThemeVisualEffectView)
    let sidebarColor = try slot("sidebar.background", in: activeTheme)
    #expect(sidebar.appliedThemeTint == sidebarColor, "\(theme.name) Sidebar")
    #expect(details.appliedThemeTint == sidebarColor, "\(theme.name) Details Sidebar")
    #expect(sidebar.appliedThemeMaterial == activeTheme.style.sidebarMaterial ?? activeTheme.palette.material)
    #expect(details.appliedThemeMaterial == activeTheme.style.sidebarMaterial ?? activeTheme.palette.material)
    let sidebarForeground = try slot("sidebar.foreground", in: activeTheme)
    let sidebarTitle = try #require(
      identifiedView("workspace-sidebar-foreground", in: controller) as? NSTextField
    )
    #expect(HexColor(nsColor: sidebarTitle.textColor ?? .clear) == sidebarForeground)
    let split = try #require(
      controller.view.descendants.compactMap { $0 as? WorkspacePanelSplitView }.first
    )
    let sidebarBorder = try slot("sidebar.border", in: activeTheme)
    #expect(
      HexColor(nsColor: split.themeDividerColor) == sidebarBorder,
      "\(theme.name) Sidebar border"
    )

    let titlebar = try identifiedView("workspace-titlebar", in: controller)
    // 中央标题只浮在统一 workspace surface 上，不再重复创建一层 Window material。
    #expect(titlebar is ThemeVisualEffectView == false, "\(theme.name) Titlebar shared surface")
    #expect(titlebar.layer?.backgroundColor == NSColor.clear.cgColor)
    let titleButton = try #require(
      identifiedView("workspace-title-button", in: controller) as? WorkspaceTitleButton
    )
    let titlebarForeground = try slot("titlebar.foreground", in: activeTheme)
    #expect(
      HexColor(nsColor: titleButton.contentTintColor ?? .clear) == titlebarForeground,
      "\(theme.name) Titlebar foreground"
    )

    let container = try identifiedView("workspace-container", in: controller)
    let containerColor = try slot("container.background", in: activeTheme)
    let containerBorder = try slot("container.border", in: activeTheme)
    #expect(layerColor(of: container) == containerColor, "\(theme.name) Container")
    #expect(layerBorderColor(of: container) == containerBorder, "\(theme.name) Container border")

    let tabs = controller.view.descendants.compactMap { $0 as? TabRowButton }
    #expect(tabs.count == 2)
    let selectedID = try #require(model.selectedTabID)
    let selectedTab = try #require(tabs.first { tab in
      tab.descendants.contains {
        $0.identifier?.rawValue == "workspace-tab-background-\(selectedID.uuidString)"
      }
    })
    let unselectedTab = try #require(tabs.first { $0 !== selectedTab })
    let tabBackground = try tabDecoration(in: selectedTab)
    let tabActiveBackground = try slot("tab.activeBackground", in: activeTheme)
    let tabActiveForeground = try slot("tab.activeForeground", in: activeTheme)
    let tabTint = try #require(selectedTab.contentTintColor)
    #expect(layerColor(of: tabBackground) == tabActiveBackground, "\(theme.name) Tab active")
    #expect(HexColor(nsColor: tabTint) == tabActiveForeground, "\(theme.name) Tab foreground")
    let tabForeground = try slot("tab.foreground", in: activeTheme)
    #expect(
      HexColor(nsColor: unselectedTab.contentTintColor ?? .clear) == tabForeground,
      "\(theme.name) Tab resting foreground"
    )
    let tabActiveBorder = try slot("tab.activeBorderColor", in: activeTheme)
    #expect(
      layerBorderColor(of: tabBackground) == tabActiveBorder,
      "\(theme.name) Tab active border"
    )
    let expectedBorderWidth = CGFloat(activeTheme.style.tab.activeBorderWidth)
    #expect(
      tabBackground.layer?.borderWidth == expectedBorderWidth, "\(theme.name) Tab border width")
    unselectedTab.mouseEntered(with: makeClickEvent(in: window))
    let tabHoverBackground = try slot("tab.hoverBackground", in: activeTheme)
    let hoveredDecoration = try tabDecoration(in: unselectedTab)
    #expect(
      layerColor(of: hoveredDecoration) == tabHoverBackground,
      "\(theme.name) Tab hover"
    )
    unselectedTab.mouseExited(with: makeClickEvent(in: window))

    try verifyRuntimeRoles(activeTheme)

    // TerminalSession.apply 读取原始 alpha 的 canvas；脱离材质的浮层读取预合成
    // background。两条路径都纳入矩阵，避免 Glass 终端被错误画成截图采样灰色。
    #expect(HexColor(nsColor: preferences.terminalForegroundColor) == activeTheme.palette.foreground)
    #expect(HexColor(nsColor: preferences.terminalBackgroundColor) == activeTheme.palette.renderedTerminalBackground)
    #expect(
      HexColor(nsColor: preferences.terminalCanvasBackgroundColor)
        == activeTheme.palette.windowBackground)
    #expect(HexColor(nsColor: preferences.cursorColor) == activeTheme.palette.cursor)
    let cursorForeground = try slot("cursor.foreground", in: activeTheme)
    let selectionBackground = try slot("selection.background", in: activeTheme)
    let selectionForeground = try slot("selection.foreground", in: activeTheme)
    #expect(HexColor(nsColor: preferences.cursorTextColor) == cursorForeground)
    #expect(HexColor(nsColor: preferences.selectionColor) == selectionBackground)
    #expect(HexColor(nsColor: preferences.selectionForegroundColor) == selectionForeground)
    #expect(preferences.ansiColors == activeTheme.palette.ansiColors)
  }

  /// 横向布局单独锁定 Tabbar 与 `[tab-bar.tab]` 的覆盖/继承结果。
  private func verifyHorizontalWorkspace(_ theme: TerminalTheme) throws {
    let defaults = isolatedDefaults()
    let preferences = AppPreferences(defaults: defaults)
    preferences.appearance = .light
    preferences.selectTheme(theme)
    preferences.tabBarLayout = .top
    let activeTheme = preferences.activeTheme
    let model = try makeNonTerminalTestModel(defaults: defaults, directories: ["/tmp/theme-matrix"])
    let controller = WorkspaceViewController(model: model, preferences: preferences)
    let window = makeTestWindow(content: controller, size: NSSize(width: 1_180, height: 760))
    window.contentView?.layoutSubtreeIfNeeded()

    let tabbar = try themedView("workspace-tabbar", in: controller)
    let tabbarColor = try slot("tabbar.background", in: activeTheme)
    #expect(tabbar.appliedThemeTint == tabbarColor, "\(theme.name) Tabbar")
    let border = try identifiedView("workspace-tabbar-border", in: controller)
    let tabbarBorder = try slot("tabbar.border", in: activeTheme)
    #expect(layerColor(of: border) == tabbarBorder, "\(theme.name) Tabbar border")

    let tab = try #require(controller.view.descendants.compactMap { $0 as? TabRowButton }.first)
    let style = activeTheme.style.horizontalTab ?? activeTheme.style.tab
    let fallbackActiveBackground = try slot("tab.activeBackground", in: activeTheme)
    let fallbackActiveForeground = try slot("tab.activeForeground", in: activeTheme)
    let activeBackground = style.activeBackground ?? fallbackActiveBackground
    let activeForeground = style.activeForeground ?? fallbackActiveForeground
    let tabTint = try #require(tab.contentTintColor)
    #expect(layerColor(of: tab) == activeBackground, "\(theme.name) horizontal Tab active")
    #expect(HexColor(nsColor: tabTint) == activeForeground, "\(theme.name) horizontal Tab foreground")
  }

  private func slot(_ id: String, in theme: TerminalTheme) throws -> HexColor {
    try #require(theme.resolvedColor(forSlot: id), "主题 \(theme.name) 缺少 \(id)")
  }

  /// Panel 与 Accents 通过动态角色色进入查找栏、浮层、详情内容和通用控件；直接核对
  /// ThemeRuntime 可以避开某个业务页是否恰好有数据，同时仍锁住最终 AppKit 颜色入口。
  private func verifyRuntimeRoles(_ theme: TerminalTheme) throws {
    let appearance = try #require(NSAppearance(named: .aqua))
    let mappings: [(ThemeRuntime.Role, String)] = [
      (.panel, "panel.background"),
      (.surface, "panel.surface"),
      (.border, "panel.border"),
      (.accent, "interface.accent"),
      (.foreground, "interface.foreground"),
      (.secondary, "interface.secondaryForeground"),
      (.tertiary, "interface.tertiaryForeground"),
    ]
    for (role, slotID) in mappings {
      let rendered = HexColor(nsColor: ThemeRuntime.shared.color(for: role, appearance: appearance))
      let expected = try slot(slotID, in: theme)
      #expect(rendered == expected, "\(theme.name) \(slotID)")
    }
  }

  private func tabDecoration(in tab: TabRowButton) throws -> NSView {
    try #require(tab.descendants.first {
      $0.identifier?.rawValue.hasPrefix("workspace-tab-background-") == true
    })
  }

  private func identifiedView(
    _ id: String,
    in controller: WorkspaceViewController
  ) throws -> NSView {
    try #require(
      controller.view.descendants.first { $0.identifier?.rawValue == id },
      "工作区缺少主题验收对象 \(id)"
    )
  }

  private func themedView(
    _ id: String,
    in controller: WorkspaceViewController
  ) throws -> ThemeVisualEffectView {
    try #require(try identifiedView(id, in: controller) as? ThemeVisualEffectView)
  }

  private func layerColor(of view: NSView) -> HexColor? {
    view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)).map(HexColor.init(nsColor:))
  }

  private func layerBorderColor(of view: NSView) -> HexColor? {
    view.layer?.borderColor.flatMap(NSColor.init(cgColor:)).map(HexColor.init(nsColor:))
  }
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

@Test("光标默认模式只接受程序控制闪烁而不覆盖用户形状")
@MainActor
func cursorBlinkPriorityMatchesOttyDefaultAndAlwaysModes() async throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 400, height: 240))
  let terminal = view.getTerminal()

  // Codex 等 TUI 会用 DECSCUSR 请求方块光标。Default 模式允许它改变“是否闪烁”，
  // 但光标几何始终属于 Aster 外观设置，用户选择的竖线不能被程序改成方块。
  view.configureCursor(initialStyle: .steadyBar, pinsProgramBlinking: false)
  terminal.setCursorStyle(.blinkBlock)
  try await Task.sleep(for: .milliseconds(50))
  #expect(terminal.options.cursorStyle == .blinkBar)

  terminal.setCursorStyle(.steadyHollowBlock)
  try await Task.sleep(for: .milliseconds(50))
  #expect(terminal.options.cursorStyle == .steadyBar)

  view.configureCursor(initialStyle: .steadyHollowBlock, pinsProgramBlinking: true)
  terminal.setCursorStyle(.blinkBlock)
  try await Task.sleep(for: .milliseconds(50))
  #expect(terminal.options.cursorStyle == .steadyHollowBlock)
}

@Test("Pane 切换停止旧光标闪烁但不把竖线改成镂空方框")
@MainActor
func paneFocusPreservesConfiguredCursorGeometry() throws {
  let left = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 300, height: 220))
  let right = AsterTerminalView(frame: NSRect(x: 300, y: 0, width: 300, height: 220))
  left.configureCursor(initialStyle: .blinkBar, pinsProgramBlinking: true)
  right.configureCursor(initialStyle: .blinkBar, pinsProgramBlinking: true)

  left.setPaneActive(true)
  right.setPaneActive(false)
  #expect(left.getTerminal().options.cursorStyle == .blinkBar)
  #expect(right.getTerminal().options.cursorStyle == .steadyBar)

  left.setPaneActive(false)
  right.setPaneActive(true)
  #expect(left.getTerminal().options.cursorStyle == .steadyBar)
  #expect(right.getTerminal().options.cursorStyle == .blinkBar)
  // 失焦只暂停闪烁；SwiftTerm 的通用 hollow-block 替代样式不能覆盖用户选择的竖线。
  #expect(!left.caretViewTracksFocus)
  #expect(!right.caretViewTracksFocus)
}

/// 合成一次落在窗口中心的左键按下，用于驱动自绘控件的 `mouseDown`。
@MainActor
private func makeClickEvent(in window: NSWindow) -> NSEvent {
  NSEvent.mouseEvent(
    with: .leftMouseDown,
    location: NSPoint(x: window.frame.midX, y: window.frame.midY),
    modifierFlags: [],
    timestamp: 0,
    windowNumber: window.windowNumber,
    context: nil,
    eventNumber: 0,
    clickCount: 1,
    pressure: 1
  )!
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
