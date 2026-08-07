import AppKit
import Combine

/// SwiftPM 可执行程序的纯 AppKit 入口，不创建 `SwiftUI.App`、`Scene` 或 `NSHostingView`。
@main
enum AsterApplication {
  @MainActor
  static func main() {
    let application = NSApplication.shared
    let delegate = AsterAppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
  }
}

@MainActor
final class AsterAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  let model = AppModel()
  let preferences = AppPreferences()
  private var mainWindowController: NSWindowController?
  private var settingsWindowController: NSWindowController?
  private var cancellables: Set<AnyCancellable> = []
  private lazy var dockActivityCoordinator = DockActivityCoordinator(
    model: model, preferences: preferences)

  func applicationDidFinishLaunching(_ notification: Notification) {
    TerminalNotificationService.shared.refreshAuthorizationStatus()
    dockActivityCoordinator.start()
    // 提前创建 0600 CLI token，使首次执行 `aster learn` 无需先打开设置页或等待 Pane。
    _ = AutocompleteService.shared
    // Bash 与 tmux 子 Shell 需要受管 rc 区块；每次启动都按当前签名 Bundle 路径幂等
    // 刷新，应用移动或升级后不会继续 source 旧位置。失败只禁用集成，不阻塞终端窗口。
    if let installer = AsterResourceLocations.shellIntegrationInstaller() {
      do {
        try installer.reconcile(enabled: preferences.configuration.shell.shellIntegration)
      } catch {
        preferences.configuration.shell.shellIntegration = false
        fputs("Aster shell integration disabled: \(error.localizedDescription)\n", stderr)
      }
    }
    model.onTabOrderBecameManual = { [weak self] in
      self?.preferences.sidebarTabOrder = .manual
    }
    synchronizeWorkspaceConfiguration()
    NSApp.mainMenu = makeMainMenu()
    // Finder「服务 → 在 Aster 中打开」的接收端；服务菜单项由 Info.plist NSServices 声明。
    NSApp.servicesProvider = self
    showMainWindow()
    preferences.objectWillChange
      .sink { [weak self] _ in
        DispatchQueue.main.async {
          self?.applyAppearance()
          self?.synchronizeWorkspaceConfiguration()
        }
      }
      .store(in: &cancellables)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationDidBecomeActive(_ notification: Notification) {
    SecureInputCoordinator.shared.setApplicationActive(true)
    TerminalNotificationService.shared.refreshAuthorizationStatus()
  }

  func applicationDidResignActive(_ notification: Notification) {
    SecureInputCoordinator.shared.setApplicationActive(false)
  }

  func applicationWillTerminate(_ notification: Notification) {
    SecureInputCoordinator.shared.setApplicationActive(false)
  }

  /// Finder 服务入口：把选中的目录/文件交给统一的 URL 打开逻辑（目录开新标签）。
  @objc func openInAster(
    _ pboard: NSPasteboard, userData: String,
    error: AutoreleasingUnsafeMutablePointer<NSString>
  ) {
    let urls =
      pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
      as? [URL] ?? []
    guard !urls.isEmpty else { return }
    for url in urls { model.handleOpenURL(url) }
    showMainWindow()
  }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    model.prepareForTermination() ? .terminateNow : .terminateCancel
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    preferences.configuration.general.quitAfterLastWindowClosed
  }

  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    _ = dockActivityCoordinator.acknowledgeAndSelectNextError()
    showMainWindow()
    return true
  }

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls {
      if let result = AutocompleteService.shared?.handleLearnURL(url), result != .notHandled {
        continue
      }
      model.handleOpenURL(url)
    }
    showMainWindow()
  }

  private func showMainWindow() {
    if let mainWindowController {
      mainWindowController.showWindow(nil)
      mainWindowController.window?.makeKeyAndOrderFront(nil)
      return
    }
    let content = WorkspaceViewController(model: model, preferences: preferences)
    let configuredSize = NSSize(
      width: preferences.configuration.appearance.windowWidth,
      height: preferences.configuration.appearance.windowHeight
    )
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: configuredSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "Aster"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.isMovableByWindowBackground = false
    window.minSize = NSSize(width: 820, height: 520)
    window.contentViewController = content
    window.delegate = self
    window.setFrameAutosaveName("Aster.MainWindow")
    window.center()
    window.appearance = preferences.preferredAppearance
    let controller = NSWindowController(window: window)
    mainWindowController = controller
    controller.showWindow(nil)
  }

  /// 仅在用户结束拖动后保存窗口尺寸，避免 live resize 期间反复刷新整个 AppKit 工作区。
  func windowDidEndLiveResize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
          window === mainWindowController?.window else { return }
    preferences.configuration.appearance.windowWidth = window.contentLayoutRect.width
    preferences.configuration.appearance.windowHeight = window.contentLayoutRect.height
  }

  /// 设置页的“恢复默认尺寸”立即作用于主窗口，同时让后续启动使用相同尺寸。
  func applyDefaultMainWindowSize() {
    guard let window = mainWindowController?.window else { return }
    window.setContentSize(NSSize(width: 1180, height: 760))
    window.center()
  }

  @objc func showSettings(_ sender: Any?) {
    if let settingsWindowController {
      settingsWindowController.showWindow(sender)
      settingsWindowController.window?.makeKeyAndOrderFront(sender)
      return
    }
    let content = SettingsViewController(preferences: preferences)
    // fullSizeContentView + 透明标题栏让侧栏延伸到窗口顶部（Otty 式全高侧栏），
    // 红绿灯悬浮在侧栏上方，由侧栏顶部内边距让位。
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 700, height: 460),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "Aster 设置"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    // 宽度下限保证外观页主题网格（3 列卡片）不被横向裁切；高度靠内容滚动。
    window.minSize = NSSize(width: 700, height: 420)
    window.contentViewController = content
    window.isReleasedWhenClosed = false
    window.appearance = preferences.preferredAppearance
    window.center()
    let controller = NSWindowController(window: window)
    settingsWindowController = controller
    controller.showWindow(sender)
  }

  private func applyAppearance() {
    mainWindowController?.window?.appearance = preferences.preferredAppearance
    settingsWindowController?.window?.appearance = preferences.preferredAppearance
  }

  private func synchronizeWorkspaceConfiguration() {
    model.newTabPosition = preferences.configuration.appearance.resolvedNewTabPosition
    model.frecencyAutoRecord = preferences.configuration.shell.resolvedFrecencyAutoRecord
  }

  // MARK: - Native menu actions

  @objc private func newTab(_ sender: Any?) { model.newTab(); showMainWindow() }
  @objc private func reopenLastClosedTab(_ sender: Any?) { _ = model.reopenLastClosedTab() }
  @objc private func renameTab(_ sender: Any?) { model.promptRenameSelectedTab() }
  @objc private func openFile(_ sender: Any?) { model.openFile() }
  @objc private func openFolder(_ sender: Any?) { model.openFolder() }
  @objc private func closeTab(_ sender: Any?) { model.closeSelectedTab() }
  /// ⌘W：标签内还有分屏时只关闭聚焦面板，最后一个面板才关闭整个标签页。
  @objc private func closePaneOrTab(_ sender: Any?) { model.closeSelectedPaneOrTab() }
  @objc private func splitRight(_ sender: Any?) { model.splitSelectedTab(.right) }
  @objc private func splitLeft(_ sender: Any?) { model.splitSelectedTab(.left) }
  @objc private func splitDown(_ sender: Any?) { model.splitSelectedTab(.down) }
  @objc private func splitUp(_ sender: Any?) { model.splitSelectedTab(.up) }
  @objc private func closePane(_ sender: Any?) { model.closeActivePane() }
  @objc private func zoomSplit(_ sender: Any?) { model.toggleZoomActivePane() }
  @objc private func equalizeSplits(_ sender: Any?) { model.equalizeSplits() }
  @objc private func moveDividerUp(_ sender: Any?) { model.moveDivider(.up) }
  @objc private func moveDividerDown(_ sender: Any?) { model.moveDivider(.down) }
  @objc private func moveDividerLeft(_ sender: Any?) { model.moveDivider(.left) }
  @objc private func moveDividerRight(_ sender: Any?) { model.moveDivider(.right) }
  @objc private func focusPaneUp(_ sender: Any?) { model.focusPane(.up) }
  @objc private func focusPaneDown(_ sender: Any?) { model.focusPane(.down) }
  @objc private func focusPaneLeft(_ sender: Any?) { model.focusPane(.left) }
  @objc private func focusPaneRight(_ sender: Any?) { model.focusPane(.right) }
  @objc private func focusNextPane(_ sender: Any?) { model.focusPane(forward: true) }
  @objc private func focusPreviousPane(_ sender: Any?) { model.focusPane(forward: false) }
  @objc private func saveDocument(_ sender: Any?) { model.saveActiveDocument() }
  @objc private func find(_ sender: Any?) { model.toggleFind() }
  @objc private func commandPalette(_ sender: Any?) { model.togglePalette() }
  @objc private func openRecipe(_ sender: Any?) { model.openRecipe() }
  @objc private func saveRecipe(_ sender: Any?) { model.saveRecipe() }
  @objc private func toggleInspector(_ sender: Any?) { model.toggleInspector() }
  /// 折叠/展开标签栏：与垂直侧栏悬停出现的折叠按钮共用同一配置开关。
  @objc private func toggleTabBarVisibility(_ sender: Any?) {
    preferences.configuration.appearance.showTabBar.toggle()
  }
  @objc private func toggleSecureKeyboardEntry(_ sender: Any?) {
    SecureInputCoordinator.shared.toggleManualRequest()
  }
  @objc private func toggleActivePaneReadOnly(_ sender: Any?) {
    model.toggleActivePaneReadOnly()
  }

  private func makeMainMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(appMenuItem())
    menu.addItem(fileMenuItem())
    menu.addItem(editMenuItem())
    menu.addItem(shellModeMenuItem())
    menu.addItem(workspaceMenuItem())
    menu.addItem(windowMenuItem())
    return menu
  }

  private func appMenuItem() -> NSMenuItem {
    let item = NSMenuItem()
    let submenu = NSMenu(title: "Aster")
    submenu.addItem(withTitle: "关于 Aster", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    submenu.addItem(.separator())
    let settings = NSMenuItem(title: "设置…", action: #selector(showSettings(_:)), keyEquivalent: ",")
    settings.target = self
    submenu.addItem(settings)
    submenu.addItem(.separator())
    submenu.addItem(withTitle: "隐藏 Aster", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    submenu.addItem(withTitle: "退出 Aster", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    item.submenu = submenu
    return item
  }

  private func fileMenuItem() -> NSMenuItem {
    let item = NSMenuItem()
    let submenu = NSMenu(title: "文件")
    submenu.addItem(menuItem("新建标签页", #selector(newTab(_:)), "t"))
    submenu.addItem(
      menuItem("重新打开最近关闭的标签页", #selector(reopenLastClosedTab(_:)), "t", modifiers: [.command, .shift]))
    submenu.addItem(menuItem("打开文件…", #selector(openFile(_:)), "o"))
    submenu.addItem(menuItem("打开文件夹…", #selector(openFolder(_:)), "", modifiers: []))
    submenu.addItem(.separator())
    submenu.addItem(menuItem("保存", #selector(saveDocument(_:)), "s"))
    submenu.addItem(menuItem("重命名标签页…", #selector(renameTab(_:)), "", modifiers: []))
    submenu.addItem(menuItem("关闭", #selector(closePaneOrTab(_:)), "w"))
    submenu.addItem(
      menuItem("关闭标签页", #selector(closeTab(_:)), "w", modifiers: [.command, .shift]))
    item.submenu = submenu
    return item
  }

  private func editMenuItem() -> NSMenuItem {
    let item = NSMenuItem()
    let submenu = NSMenu(title: "编辑")
    submenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
    submenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
    submenu.addItem(textEditingMenuItem())
    submenu.addItem(.separator())
    submenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    submenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    submenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    let pasteAsItem = NSMenuItem(title: "粘贴为", action: nil, keyEquivalent: "")
    let pasteAsMenu = NSMenu(title: "粘贴为")
    pasteAsMenu.addItem(
      withTitle: "粘贴选区", action: #selector(AsterTerminalView.pasteSelection(_:)),
      keyEquivalent: "")
    pasteAsMenu.addItem(
      withTitle: "粘贴 Base64 编码文件…",
      action: #selector(AsterTerminalView.pasteFileBase64Encoded(_:)),
      keyEquivalent: "")
    pasteAsMenu.addItem(
      withTitle: "转义特殊字符后粘贴",
      action: #selector(AsterTerminalView.pasteEscapingSpecialCharacters(_:)), keyEquivalent: "")
    pasteAsMenu.addItem(
      withTitle: "括号粘贴", action: #selector(AsterTerminalView.pasteBracketed(_:)),
      keyEquivalent: "")
    pasteAsMenu.addItem(
      withTitle: "粘贴并在 Composer 中继续",
      action: #selector(AsterTerminalView.pasteAndContinueInComposer(_:)), keyEquivalent: "")
    pasteAsItem.submenu = pasteAsMenu
    submenu.addItem(pasteAsItem)
    submenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    submenu.addItem(.separator())
    submenu.addItem(menuItem("查找", #selector(find(_:)), "f"))
    submenu.addItem(.separator())
    submenu.addItem(
      menuItem(
        "安全键盘输入", #selector(toggleSecureKeyboardEntry(_:)), "", modifiers: []))
    item.submenu = submenu
    return item
  }

  /// 终端模式命令通过 responder chain 落到当前聚焦 Pane，分屏间不共享 Read-only、
  /// Vi 光标或 Hint 状态。只有 Vi Mode 配置默认快捷键，其余动作保留菜单与命令面板入口。
  func shellModeMenuItem() -> NSMenuItem {
    let item = NSMenuItem()
    let submenu = NSMenu(title: "Shell")
    submenu.addItem(
      responderMenuItem(
        "Vi Mode", #selector(AsterTerminalView.enterViMode(_:)), " ",
        modifiers: [.control, .shift]))
    submenu.addItem(
      responderMenuItem(
        "Mark Mode", #selector(AsterTerminalView.enterMarkMode(_:)), "", modifiers: []))
    submenu.addItem(
      responderMenuItem(
        "打开链接（Hint Mode）", #selector(AsterTerminalView.openHintMode(_:)), "",
        modifiers: []))
    submenu.addItem(.separator())
    submenu.addItem(
      menuItem("只读模式", #selector(toggleActivePaneReadOnly(_:)), "", modifiers: []))
    submenu.addItem(.separator())
    submenu.addItem(
      responderMenuItem(
        "显示/隐藏 Vi 按键提示", #selector(AsterTerminalView.toggleViKeyHints(_:)), "/",
        modifiers: [.command]))
    item.submenu = submenu
    return item
  }

  /// 这些菜单项既公开原生编辑能力，也让 AppKit 在进入 SwiftTerm 的不可覆写 keyDown
  /// 前通过 responder chain 分发默认快捷键。终端视图会按普通屏/增强协议动态校验。
  private func textEditingMenuItem() -> NSMenuItem {
    let item = NSMenuItem(title: "文本编辑", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "文本编辑")
    submenu.addItem(
      responderMenuItem(
        "移到行首", #selector(AsterTerminalView.movePromptToBeginningOfLine(_:)),
        Self.functionKey(NSLeftArrowFunctionKey), modifiers: [.command]))
    submenu.addItem(
      responderMenuItem(
        "移到行尾", #selector(AsterTerminalView.movePromptToEndOfLine(_:)),
        Self.functionKey(NSRightArrowFunctionKey), modifiers: [.command]))
    submenu.addItem(
      responderMenuItem(
        "向左移动一个词", #selector(AsterTerminalView.movePromptWordLeft(_:)),
        Self.functionKey(NSLeftArrowFunctionKey), modifiers: [.option]))
    submenu.addItem(
      responderMenuItem(
        "向右移动一个词", #selector(AsterTerminalView.movePromptWordRight(_:)),
        Self.functionKey(NSRightArrowFunctionKey), modifiers: [.option]))
    submenu.addItem(.separator())
    submenu.addItem(
      responderMenuItem(
        "删除到行首", #selector(AsterTerminalView.deletePromptToBeginningOfLine(_:)),
        "\u{8}", modifiers: [.command]))
    submenu.addItem(
      responderMenuItem(
        "删除到行尾", #selector(AsterTerminalView.deletePromptToEndOfLine(_:)),
        Self.functionKey(NSDeleteFunctionKey), modifiers: [.command]))
    submenu.addItem(
      responderMenuItem(
        "删除左侧词", #selector(AsterTerminalView.deletePromptWordLeft(_:)),
        "\u{8}", modifiers: [.option]))
    submenu.addItem(
      responderMenuItem(
        "删除右侧词", #selector(AsterTerminalView.deletePromptWordRight(_:)),
        Self.functionKey(NSDeleteFunctionKey), modifiers: [.option]))
    submenu.addItem(.separator())
    submenu.addItem(selectionMenuItem())
    item.submenu = submenu
    return item
  }

  /// Shift+Arrow 默认进入原生终端选区；Option 版本保持矩形列。没有注册 Command
  /// 组合，因此 Shift+Command+Arrow 会继续原样交给终端程序。
  func selectionMenuItem() -> NSMenuItem {
    let item = NSMenuItem(title: "扩展选区", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "扩展选区")
    let directions: [(String, Selector, Selector, Int)] = [
      ("向左扩展", #selector(AsterTerminalView.extendSelectionLeft(_:)),
        #selector(AsterTerminalView.extendRectangularSelectionLeft(_:)), NSLeftArrowFunctionKey),
      ("向右扩展", #selector(AsterTerminalView.extendSelectionRight(_:)),
        #selector(AsterTerminalView.extendRectangularSelectionRight(_:)), NSRightArrowFunctionKey),
      ("向上扩展", #selector(AsterTerminalView.extendSelectionUp(_:)),
        #selector(AsterTerminalView.extendRectangularSelectionUp(_:)), NSUpArrowFunctionKey),
      ("向下扩展", #selector(AsterTerminalView.extendSelectionDown(_:)),
        #selector(AsterTerminalView.extendRectangularSelectionDown(_:)), NSDownArrowFunctionKey),
    ]
    for (title, linearAction, rectangularAction, key) in directions {
      submenu.addItem(
        responderMenuItem(title, linearAction, Self.functionKey(key), modifiers: [.shift]))
      submenu.addItem(
        responderMenuItem(
          "\(title)（矩形）", rectangularAction, Self.functionKey(key),
          modifiers: [.shift, .option]))
    }
    item.submenu = submenu
    return item
  }

  private func responderMenuItem(
    _ title: String,
    _ action: Selector,
    _ key: String,
    modifiers: NSEvent.ModifierFlags
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    return item
  }

  /// 「显示」菜单：分屏的完整命令集（拆分方向、缩放、调整大小、聚焦面板）
  /// 按参考应用的分组组织，两个子菜单分别对应「调整拆分大小」和「聚焦面板」。
  private func workspaceMenuItem() -> NSMenuItem {
    let item = NSMenuItem()
    let submenu = NSMenu(title: "显示")
    submenu.addItem(menuItem("向右拆分", #selector(splitRight(_:)), "d"))
    submenu.addItem(menuItem("向左拆分", #selector(splitLeft(_:)), "d", modifiers: [.command, .option]))
    submenu.addItem(menuItem("向下拆分", #selector(splitDown(_:)), "d", modifiers: [.command, .shift]))
    submenu.addItem(
      menuItem("向上拆分", #selector(splitUp(_:)), "d", modifiers: [.command, .option, .shift]))
    submenu.addItem(.separator())
    submenu.addItem(
      menuItem("缩放拆分", #selector(zoomSplit(_:)), "\r", modifiers: [.command, .shift]))
    submenu.addItem(splitSizeMenuItem())
    submenu.addItem(focusPaneMenuItem())
    submenu.addItem(menuItem("关闭当前面板", #selector(closePane(_:)), "w", modifiers: [.command, .option]))
    submenu.addItem(.separator())
    submenu.addItem(menuItem("命令面板", #selector(commandPalette(_:)), "k"))
    submenu.addItem(menuItem("显示/隐藏详情面板", #selector(toggleInspector(_:)), "", modifiers: []))
    submenu.addItem(menuItem("显示/隐藏标签栏", #selector(toggleTabBarVisibility(_:)), "", modifiers: []))
    submenu.addItem(.separator())
    submenu.addItem(terminalScrollMenuItem())
    submenu.addItem(.separator())
    submenu.addItem(menuItem("打开 Recipe…", #selector(openRecipe(_:)), "", modifiers: []))
    submenu.addItem(menuItem("保存为 Recipe…", #selector(saveRecipe(_:)), "", modifiers: []))
    item.submenu = submenu
    return item
  }

  /// 滚动命令由 responder chain 定位到当前终端，避免应用层保存第二份“活动终端”状态。
  /// Command+Page Up/Down 留给后续 Shell Integration 的上一/下一命令导航。
  func terminalScrollMenuItem() -> NSMenuItem {
    let item = NSMenuItem(title: "终端滚动", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "终端滚动")
    submenu.addItem(
      responderMenuItem(
        "向上翻页", #selector(AsterTerminalView.scrollTerminalPageUp(_:)),
        Self.functionKey(NSPageUpFunctionKey), modifiers: [.shift]))
    submenu.addItem(
      responderMenuItem(
        "向下翻页", #selector(AsterTerminalView.scrollTerminalPageDown(_:)),
        Self.functionKey(NSPageDownFunctionKey), modifiers: [.shift]))
    submenu.addItem(.separator())
    submenu.addItem(
      responderMenuItem(
        "滚动到顶部", #selector(AsterTerminalView.scrollTerminalToTop(_:)),
        Self.functionKey(NSHomeFunctionKey), modifiers: [.shift]))
    submenu.addItem(
      responderMenuItem(
        "滚动到底部", #selector(AsterTerminalView.scrollTerminalToBottom(_:)),
        Self.functionKey(NSEndFunctionKey), modifiers: [.shift]))
    submenu.addItem(.separator())
    submenu.addItem(
      responderMenuItem(
        "上一条命令", #selector(AsterTerminalView.scrollToPreviousCommand(_:)),
        Self.functionKey(NSPageUpFunctionKey), modifiers: [.command]))
    submenu.addItem(
      responderMenuItem(
        "下一条命令", #selector(AsterTerminalView.scrollToNextCommand(_:)),
        Self.functionKey(NSPageDownFunctionKey), modifiers: [.command]))
    item.submenu = submenu
    return item
  }

  private func splitSizeMenuItem() -> NSMenuItem {
    let item = NSMenuItem(title: "调整拆分大小", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "调整拆分大小")
    submenu.addItem(
      menuItem("等分拆分", #selector(equalizeSplits(_:)), "=", modifiers: [.command, .control]))
    submenu.addItem(.separator())
    // 方向语义跟随分隔条本身：上移即让上方面板变小，与聚焦面板在哪一侧无关。
    submenu.addItem(
      menuItem("上移分隔条", #selector(moveDividerUp(_:)), Self.functionKey(NSUpArrowFunctionKey),
        modifiers: [.command, .control]))
    submenu.addItem(
      menuItem("下移分隔条", #selector(moveDividerDown(_:)), Self.functionKey(NSDownArrowFunctionKey),
        modifiers: [.command, .control]))
    submenu.addItem(
      menuItem("左移分隔条", #selector(moveDividerLeft(_:)), Self.functionKey(NSLeftArrowFunctionKey),
        modifiers: [.command, .control]))
    submenu.addItem(
      menuItem("右移分隔条", #selector(moveDividerRight(_:)), Self.functionKey(NSRightArrowFunctionKey),
        modifiers: [.command, .control]))
    item.submenu = submenu
    return item
  }

  private func focusPaneMenuItem() -> NSMenuItem {
    let item = NSMenuItem(title: "聚焦面板", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "聚焦面板")
    submenu.addItem(
      menuItem("聚焦上方面板", #selector(focusPaneUp(_:)), Self.functionKey(NSUpArrowFunctionKey),
        modifiers: [.command, .option]))
    submenu.addItem(
      menuItem("聚焦下方面板", #selector(focusPaneDown(_:)), Self.functionKey(NSDownArrowFunctionKey),
        modifiers: [.command, .option]))
    submenu.addItem(
      menuItem("聚焦左侧面板", #selector(focusPaneLeft(_:)), Self.functionKey(NSLeftArrowFunctionKey),
        modifiers: [.command, .option]))
    submenu.addItem(
      menuItem("聚焦右侧面板", #selector(focusPaneRight(_:)), Self.functionKey(NSRightArrowFunctionKey),
        modifiers: [.command, .option]))
    submenu.addItem(.separator())
    submenu.addItem(menuItem("聚焦下一个面板", #selector(focusNextPane(_:)), "]"))
    submenu.addItem(menuItem("聚焦上一个面板", #selector(focusPreviousPane(_:)), "["))
    item.submenu = submenu
    return item
  }

  /// AppKit 用私有区码位表示方向、翻页和首尾等功能键，菜单快捷键必须写成单字符字符串。
  private static func functionKey(_ functionKey: Int) -> String {
    guard let scalar = UnicodeScalar(UInt32(functionKey)) else { return "" }
    return String(Character(scalar))
  }

  private func windowMenuItem() -> NSMenuItem {
    let item = NSMenuItem()
    let submenu = NSMenu(title: "窗口")
    submenu.addItem(withTitle: "最小化", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    submenu.addItem(withTitle: "缩放", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
    submenu.addItem(withTitle: "前置全部窗口", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
    NSApp.windowsMenu = submenu
    item.submenu = submenu
    return item
  }

  private func menuItem(
    _ title: String,
    _ action: Selector,
    _ key: String,
    modifiers: NSEvent.ModifierFlags = .command
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    item.target = self
    return item
  }
}

/// 只有存在分屏时才有意义的命令在单面板标签下置灰，避免菜单项看起来可用却无反应。
extension AsterAppDelegate: NSMenuItemValidation {
  private static let splitOnlySelectors: Set<Selector> = [
    #selector(closePane(_:)), #selector(zoomSplit(_:)), #selector(equalizeSplits(_:)),
    #selector(moveDividerUp(_:)), #selector(moveDividerDown(_:)),
    #selector(moveDividerLeft(_:)), #selector(moveDividerRight(_:)),
    #selector(focusPaneUp(_:)), #selector(focusPaneDown(_:)),
    #selector(focusPaneLeft(_:)), #selector(focusPaneRight(_:)),
    #selector(focusNextPane(_:)), #selector(focusPreviousPane(_:)),
  ]

  func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
    guard let action = menuItem.action else { return true }
    if action == #selector(toggleSecureKeyboardEntry(_:)) {
      menuItem.state = SecureInputCoordinator.shared.isManualRequestActive ? .on : .off
      return true
    }
    if action == #selector(toggleActivePaneReadOnly(_:)) {
      menuItem.state = model.activePaneIsReadOnly ? .on : .off
      return model.selectedTab?.activeRuntime != nil
    }
    guard Self.splitOnlySelectors.contains(action) else { return true }
    return model.selectedTabHasSplits
  }
}
