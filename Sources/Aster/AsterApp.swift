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
    NSApp.mainMenu = makeMainMenu()
    // Finder「服务 → 在 Aster 中打开」的接收端；服务菜单项由 Info.plist NSServices 声明。
    NSApp.servicesProvider = self
    showMainWindow()
    preferences.objectWillChange
      .sink { [weak self] _ in
        DispatchQueue.main.async { self?.applyAppearance() }
      }
      .store(in: &cancellables)
    NSApp.activate(ignoringOtherApps: true)
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

  // MARK: - Native menu actions

  @objc private func newTab(_ sender: Any?) { model.newTab(); showMainWindow() }
  @objc private func openFile(_ sender: Any?) { model.openFile() }
  @objc private func openFolder(_ sender: Any?) { model.openFolder() }
  @objc private func closeTab(_ sender: Any?) { model.closeSelectedTab() }
  @objc private func splitRight(_ sender: Any?) { model.splitSelectedTab(.right) }
  @objc private func splitDown(_ sender: Any?) { model.splitSelectedTab(.down) }
  @objc private func closePane(_ sender: Any?) { model.closeActivePane() }
  @objc private func saveDocument(_ sender: Any?) { model.saveActiveDocument() }
  @objc private func find(_ sender: Any?) { model.toggleFind() }
  @objc private func commandPalette(_ sender: Any?) { model.togglePalette() }
  @objc private func openRecipe(_ sender: Any?) { model.openRecipe() }
  @objc private func saveRecipe(_ sender: Any?) { model.saveRecipe() }
  @objc private func toggleInspector(_ sender: Any?) { model.toggleInspector() }

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
    submenu.addItem(menuItem("打开文件…", #selector(openFile(_:)), "o"))
    submenu.addItem(menuItem("打开文件夹…", #selector(openFolder(_:)), "", modifiers: []))
    submenu.addItem(.separator())
    submenu.addItem(menuItem("保存", #selector(saveDocument(_:)), "s"))
    submenu.addItem(menuItem("关闭标签页", #selector(closeTab(_:)), "w"))
    item.submenu = submenu
    return item
  }

  private func editMenuItem() -> NSMenuItem {
    let item = NSMenuItem()
    let submenu = NSMenu(title: "编辑")
    submenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
    submenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "Z")
    submenu.addItem(.separator())
    submenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    submenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    submenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    submenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    submenu.addItem(.separator())
    submenu.addItem(menuItem("查找", #selector(find(_:)), "f"))
    item.submenu = submenu
    return item
  }

  private func workspaceMenuItem() -> NSMenuItem {
    let item = NSMenuItem()
    let submenu = NSMenu(title: "工作区")
    submenu.addItem(menuItem("向右分屏", #selector(splitRight(_:)), "d"))
    submenu.addItem(menuItem("向下分屏", #selector(splitDown(_:)), "d", modifiers: [.command, .shift]))
    submenu.addItem(menuItem("关闭当前面板", #selector(closePane(_:)), "w", modifiers: [.command, .option]))
    submenu.addItem(.separator())
    submenu.addItem(menuItem("命令面板", #selector(commandPalette(_:)), "k"))
    submenu.addItem(menuItem("显示/隐藏详情面板", #selector(toggleInspector(_:)), "", modifiers: []))
    submenu.addItem(.separator())
    submenu.addItem(menuItem("打开 Recipe…", #selector(openRecipe(_:)), "", modifiers: []))
    submenu.addItem(menuItem("保存为 Recipe…", #selector(saveRecipe(_:)), "", modifiers: []))
    item.submenu = submenu
    return item
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
