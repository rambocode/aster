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

  func applicationDidFinishLaunching(_ notification: Notification) {
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

  func application(_ application: NSApplication, open urls: [URL]) {
    for url in urls { model.handleOpenURL(url) }
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

  private func makeMainMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(appMenuItem())
    menu.addItem(fileMenuItem())
    menu.addItem(editMenuItem())
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

  /// 这些菜单项既公开原生编辑能力，也让 AppKit 在进入 SwiftTerm 的不可覆写 keyDown
  /// 前通过 responder chain 分发默认快捷键。终端视图会按普通屏/增强协议动态校验。
  private func textEditingMenuItem() -> NSMenuItem {
    let item = NSMenuItem(title: "文本编辑", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "文本编辑")
    submenu.addItem(
      responderMenuItem(
        "移到行首", #selector(AsterTerminalView.movePromptToBeginningOfLine(_:)),
        Self.arrowKey(NSLeftArrowFunctionKey), modifiers: [.command]))
    submenu.addItem(
      responderMenuItem(
        "移到行尾", #selector(AsterTerminalView.movePromptToEndOfLine(_:)),
        Self.arrowKey(NSRightArrowFunctionKey), modifiers: [.command]))
    submenu.addItem(
      responderMenuItem(
        "向左移动一个词", #selector(AsterTerminalView.movePromptWordLeft(_:)),
        Self.arrowKey(NSLeftArrowFunctionKey), modifiers: [.option]))
    submenu.addItem(
      responderMenuItem(
        "向右移动一个词", #selector(AsterTerminalView.movePromptWordRight(_:)),
        Self.arrowKey(NSRightArrowFunctionKey), modifiers: [.option]))
    submenu.addItem(.separator())
    submenu.addItem(
      responderMenuItem(
        "删除到行首", #selector(AsterTerminalView.deletePromptToBeginningOfLine(_:)),
        "\u{8}", modifiers: [.command]))
    submenu.addItem(
      responderMenuItem(
        "删除到行尾", #selector(AsterTerminalView.deletePromptToEndOfLine(_:)),
        Self.arrowKey(NSDeleteFunctionKey), modifiers: [.command]))
    submenu.addItem(
      responderMenuItem(
        "删除左侧词", #selector(AsterTerminalView.deletePromptWordLeft(_:)),
        "\u{8}", modifiers: [.option]))
    submenu.addItem(
      responderMenuItem(
        "删除右侧词", #selector(AsterTerminalView.deletePromptWordRight(_:)),
        Self.arrowKey(NSDeleteFunctionKey), modifiers: [.option]))
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
    submenu.addItem(menuItem("打开 Recipe…", #selector(openRecipe(_:)), "", modifiers: []))
    submenu.addItem(menuItem("保存为 Recipe…", #selector(saveRecipe(_:)), "", modifiers: []))
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
      menuItem("上移分隔条", #selector(moveDividerUp(_:)), Self.arrowKey(NSUpArrowFunctionKey),
        modifiers: [.command, .control]))
    submenu.addItem(
      menuItem("下移分隔条", #selector(moveDividerDown(_:)), Self.arrowKey(NSDownArrowFunctionKey),
        modifiers: [.command, .control]))
    submenu.addItem(
      menuItem("左移分隔条", #selector(moveDividerLeft(_:)), Self.arrowKey(NSLeftArrowFunctionKey),
        modifiers: [.command, .control]))
    submenu.addItem(
      menuItem("右移分隔条", #selector(moveDividerRight(_:)), Self.arrowKey(NSRightArrowFunctionKey),
        modifiers: [.command, .control]))
    item.submenu = submenu
    return item
  }

  private func focusPaneMenuItem() -> NSMenuItem {
    let item = NSMenuItem(title: "聚焦面板", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "聚焦面板")
    submenu.addItem(
      menuItem("聚焦上方面板", #selector(focusPaneUp(_:)), Self.arrowKey(NSUpArrowFunctionKey),
        modifiers: [.command, .option]))
    submenu.addItem(
      menuItem("聚焦下方面板", #selector(focusPaneDown(_:)), Self.arrowKey(NSDownArrowFunctionKey),
        modifiers: [.command, .option]))
    submenu.addItem(
      menuItem("聚焦左侧面板", #selector(focusPaneLeft(_:)), Self.arrowKey(NSLeftArrowFunctionKey),
        modifiers: [.command, .option]))
    submenu.addItem(
      menuItem("聚焦右侧面板", #selector(focusPaneRight(_:)), Self.arrowKey(NSRightArrowFunctionKey),
        modifiers: [.command, .option]))
    submenu.addItem(.separator())
    submenu.addItem(menuItem("聚焦下一个面板", #selector(focusNextPane(_:)), "]"))
    submenu.addItem(menuItem("聚焦上一个面板", #selector(focusPreviousPane(_:)), "["))
    item.submenu = submenu
    return item
  }

  /// AppKit 用私有区码位表示方向键，菜单快捷键必须写成对应的单字符字符串。
  private static func arrowKey(_ functionKey: Int) -> String {
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
    guard Self.splitOnlySelectors.contains(action) else { return true }
    return model.selectedTabHasSplits
  }
}
