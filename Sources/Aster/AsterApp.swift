import AppKit
import AsterCore
import Combine

/// 应用退出分成“可取消确认”和“不可逆提交”两阶段。只有全部窗口都确认成功，才会
/// 写入 clean-quit 标记并终止 PTY，避免后一个窗口取消时前一个窗口已经失去进程。
@MainActor
protocol WorkspaceTerminationParticipant: AnyObject {
  func confirmTermination() -> Bool
  func commitTermination()
}

@MainActor
enum WorkspaceTerminationTransaction {
  @discardableResult
  static func commit(_ participants: [any WorkspaceTerminationParticipant]) -> Bool {
    guard participants.allSatisfy({ $0.confirmTermination() }) else { return false }
    participants.forEach { $0.commitTermination() }
    return true
  }
}

extension AppModel: WorkspaceTerminationParticipant {}

/// 附加窗口的 suite 名只接受 Aster 自己生成的 UUID 形式并限制数量。UserDefaults 内容
/// 可被外部工具改写，恢复层不能据此读取任意 domain 或无限创建窗口。
enum AdditionalWorkspaceWindowRegistry {
  static let prefix = "io.local.aster-terminal.window."
  static let maximumWindows = 16

  static func normalized(_ names: [String]) -> [String] {
    var seen: Set<String> = []
    return names.compactMap { name -> String? in
      guard name.hasPrefix(prefix),
        UUID(uuidString: String(name.dropFirst(prefix.count))) != nil,
        seen.insert(name).inserted
      else { return nil }
      return name
    }.prefix(maximumWindows).map { $0 }
  }
}

/// SwiftPM 可执行程序的纯 AppKit 入口，不创建 `SwiftUI.App`、`Scene` 或 `NSHostingView`。
@main
enum AsterApplication {
  @MainActor
  static func main() {
    // 在创建窗口前开始记录，启动阶段的资源和集成失败才能进入同一诊断会话。
    DiagnosticsCenter.shared.start()
    DiagnosticsCenter.shared.cleanStaleFeedbackArchives()
    let application = NSApplication.shared
    let delegate = AsterAppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.regular)
    application.run()
  }
}

/// 唯一设置窗口的外壳。尺寸与红绿灯能力集中在这里，避免入口或分类根据内容量各自
/// 调整窗口：宽度固定 `700pt`（九类导航与卡片排版按该宽度设计），高度可拉伸并跨启动
/// 记忆，超出可视高度的内容仍由设置页内部滚动承载。
@MainActor
final class AsterSettingsWindowController: NSWindowController {
  private let defaults: UserDefaults

  init(
    content: SettingsViewController,
    appearance: NSAppearance?,
    defaults: UserDefaults = .standard
  ) {
    self.defaults = defaults
    let restoredHeight = Self.restoredContentHeight(from: defaults)
    let window = NSWindow(
      contentRect: NSRect(
        origin: .zero,
        size: NSSize(width: SettingsViewController.defaultContentSize.width, height: restoredHeight)
      ),
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered,
      defer: false
    )
    window.title = "Aster 设置"
    window.titleVisibility = .hidden
    window.titlebarAppearsTransparent = true
    window.contentViewController = content
    // min/max 是 frame 尺寸（含标题栏），必须由内容尺寸换算，直接拿内容高度会把可用
    // 高度少算一条标题栏，最小化拖拽时窗口会比设计下限更矮。
    let minimumFrame = window.frameRect(
      forContentRect: NSRect(
        origin: .zero,
        size: NSSize(
          width: SettingsWindowGeometry.width, height: SettingsWindowGeometry.minimumHeight)
      )
    )
    window.minSize = minimumFrame.size
    // 宽度上下界相同即锁死横向；高度放开，纵向 zoom 与拖拽都只改高度。
    window.maxSize = NSSize(width: minimumFrame.width, height: .greatestFiniteMagnitude)
    // 必须在挂上 contentViewController 之后再套用记忆高度：赋值会把窗口收缩回控制器
    // 视图自己的默认尺寸，写在前面的 contentRect 会被直接抹掉。
    window.setContentSize(
      NSSize(width: SettingsViewController.defaultContentSize.width, height: restoredHeight))
    window.standardWindowButton(.miniaturizeButton)?.isEnabled = false
    window.isReleasedWhenClosed = false
    window.appearance = appearance
    window.center()
    super.init(window: window)
  }

  required init?(coder: NSCoder) { nil }

  /// 记录当前内容高度。由窗口 delegate 在拖拽结束与关闭时调用——`windowDidResize`
  /// 在实时拖拽中每帧触发，逐帧写 UserDefaults 只会给主线程添无谓负担。
  func persistContentHeight() {
    guard let window else { return }
    let contentHeight = window.contentRect(forFrameRect: window.frame).height
    defaults.set(Double(contentHeight), forKey: SettingsWindowGeometry.heightDefaultsKey)
  }

  /// 读取上次记住的内容高度，并按当前主屏可视高度钳制后返回。
  private static func restoredContentHeight(from defaults: UserDefaults) -> CGFloat {
    let stored = defaults.object(forKey: SettingsWindowGeometry.heightDefaultsKey) as? Double
    // 拿不到屏幕信息（无头会话、屏幕正在切换）时不做上界钳制：宁可保留用户记住的高度，
    // 也不要凭一个猜测值把窗口缩回最小尺寸。
    let available = NSScreen.main.map { Double($0.visibleFrame.height) } ?? .greatestFiniteMagnitude
    return CGFloat(
      SettingsWindowGeometry.clampHeight(
        stored ?? SettingsWindowGeometry.defaultHeight,
        availableHeight: available
      )
    )
  }
}

@MainActor
final class AsterAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
  private struct WorkspaceWindowRecord {
    let controller: NSWindowController
    let model: AppModel
    let defaultsSuiteName: String
  }

  let model = AppModel()
  let preferences = AppPreferences()
  private var mainWindowController: NSWindowController?
  /// 设置使用唯一独立窗口；Panel 宽度编辑仍绑定最近成为 key 的工作区窗口。
  private var settingsWindowController: AsterSettingsWindowController?
  /// Otty 风格的菜单主题选择器。由 AppDelegate 强持有，避免工作区实时刷新时被释放；
  /// 它关闭后立即清空，下一次打开重新读取当前明暗模式和主题列表。
  private var themeSwitcherPanelController: ThemeSwitcherPanelController?
  private let panelSettingsBinding = WorkspacePanelSettingsBinding()
  private var panelLayoutStores: [ObjectIdentifier: WorkspacePanelLayoutStore] = [:]
  /// 记录工作区窗口的 key 顺序。当前工作区关闭后，绑定回退到最近使用的仍存活窗口，
  /// 而不是依赖 Dictionary 的不稳定遍历顺序。
  private var activeWorkspaceWindowOrder: [ObjectIdentifier] = []
  private var pictureInPictureController: PanePictureInPictureController?
  /// sheet 必须被应用生命周期强持有，避免系统动画期间控制器提前释放。
  private var feedbackSheetController: FeedbackSheetController?
  /// CLI 使用受保护文件传输而非常驻 socket。主线程定时器只消费已经落盘的小型
  /// 请求头；实际 `run/exec` 完成由 Shell Integration 回调异步写回，不阻塞界面。
  private var cliRequestTimer: Timer?
  /// 附加窗口各自拥有独立 AppModel/PTY 树；Preferences 仍全局共享。以窗口对象身份
  /// 查找模型，菜单动作始终路由到 key window，不会误操作首个窗口。
  private var additionalWorkspaceWindows: [ObjectIdentifier: WorkspaceWindowRecord] = [:]
  private let additionalWorkspaceSuitesKey = "aster.workspace.additional-window-suites.v1"
  private var isTerminating = false
  private var cancellables: Set<AnyCancellable> = []
  private lazy var dockActivityCoordinator = DockActivityCoordinator(
    model: model, preferences: preferences)

  func applicationDidFinishLaunching(_ notification: Notification) {
    if let resources = AsterResourceLocations.resourcesDirectory() {
      do {
        try BundledFontRegistry.registerBundledFonts(resourcesDirectory: resources)
      } catch {
        // 字体失败只退化为 CoreText 系统 fallback，不阻止用户进入终端。
        DiagnosticsCenter.shared.record(
          "startup.font_registration_failed", level: .warning, category: .integration, error: error)
      }
    }
    TerminalNotificationService.shared.refreshAuthorizationStatus()
    dockActivityCoordinator.start()
    // 提前创建 0600 CLI token，使首次执行 `aster learn` 无需先打开设置页或等待 Pane。
    _ = AutocompleteService.shared
    startCLIRequestConsumer()
    // Bash 与 tmux 子 Shell 需要受管 rc 区块；每次启动都按当前签名 Bundle 路径幂等
    // 刷新，应用移动或升级后不会继续 source 旧位置。失败只禁用集成，不阻塞终端窗口。
    if let installer = AsterResourceLocations.shellIntegrationInstaller() {
      do {
        try installer.reconcile(enabled: preferences.configuration.shell.shellIntegration)
      } catch {
        preferences.configuration.shell.shellIntegration = false
        DiagnosticsCenter.shared.record(
          "startup.shell_integration_disabled", level: .warning, category: .integration, error: error)
      }
    }
    configureWorkspaceModel(model)
    model.beginApplicationSession(launchBehavior: preferences.configuration.launchBehavior)
    DiagnosticsCenter.shared.record("application.launched", level: .notice, category: .lifecycle)
    synchronizeWorkspaceConfiguration()
    NSApp.mainMenu = makeMainMenu()
    // Finder「服务 → 在 Aster 中打开」的接收端；服务菜单项由 Info.plist NSServices 声明。
    NSApp.servicesProvider = self
    showMainWindow()
    restoreAdditionalWorkspaceWindows()
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
    isTerminating = true
    themeSwitcherPanelController?.dismiss(commit: false)
    themeSwitcherPanelController = nil
    persistAdditionalWorkspaceSuites()
    cliRequestTimer?.invalidate()
    cliRequestTimer = nil
    dockActivityCoordinator.stop()
    SecureInputCoordinator.shared.setApplicationActive(false)
    DiagnosticsCenter.shared.finish(reason: "application_will_terminate")
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
    let models = [model] + additionalWorkspaceWindows.values.map(\.model)
    guard WorkspaceTerminationTransaction.commit(models) else { return .terminateCancel }
    isTerminating = true
    persistAdditionalWorkspaceSuites()
    return .terminateNow
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

  /// 每轮设置消费上限，防止恶意或损坏目录持续产出请求而饿死 AppKit event loop。
  /// 服务层会先完成 token、owner、权限、普通文件和参数校验，本层只做窗口路由。
  private func startCLIRequestConsumer() {
    guard cliRequestTimer == nil, AutocompleteService.shared?.cliRequestService != nil else {
      return
    }
    cliRequestTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) {
      [weak self] _ in
      MainActor.assumeIsolated { self?.drainCLIRequests() }
    }
    cliRequestTimer?.tolerance = 0.025
    drainCLIRequests()
  }

  private func drainCLIRequests(maximumCount: Int = 32) {
    guard let service = AutocompleteService.shared?.cliRequestService else { return }
    for _ in 0..<maximumCount {
      let request: AsterCLIRequest
      do {
        guard let next = try service.takeNextRequest() else { return }
        request = next
      } catch {
        DiagnosticsCenter.shared.record(
          "cli.request_consume_failed", level: .error, category: .integration, error: error)
        return
      }
      activeWorkspaceModel.executeWorkflowCLI(
        request.action,
        standardInput: request.standardInput.isEmpty ? nil : request.standardInput,
        allowSendKeys: preferences.configuration.controls.resolvedIPCAllowSendKeys,
        allowSensitiveSessions:
          preferences.configuration.controls.resolvedIPCAllowSensitiveSessions
      ) { result in
        do {
          try service.respond(
            to: request,
            response: WorkflowCLITransportResponseEncoder.encode(result)
          )
        } catch {
          DiagnosticsCenter.shared.record(
            "cli.response_write_failed", level: .error, category: .integration, error: error)
        }
      }
    }
  }

  private func showMainWindow() {
    if let mainWindowController {
      if let window = mainWindowController.window,
        let content = window.contentViewController as? WorkspaceViewController
      {
        // 主窗口关闭后 NSWindowController 仍被 AppDelegate 持有，Dock reopen 会复用它。
        // `windowWillClose` 已移除旧映射，因此重新显示前必须把同一 store 注册回来。
        panelLayoutStores[ObjectIdentifier(window)] = content.panelLayoutStore
      }
      mainWindowController.showWindow(nil)
      mainWindowController.window?.makeKeyAndOrderFront(nil)
      return
    }
    let controller = makeWorkspaceWindow(
      model: model,
      defaults: .standard,
      autosaveName: "Aster.MainWindow"
    )
    mainWindowController = controller
    controller.showWindow(nil)
  }

  private func makeWorkspaceWindow(
    model: AppModel,
    defaults: UserDefaults,
    autosaveName: String?
  ) -> NSWindowController {
    let panelLayoutStore = WorkspacePanelLayoutStore(
      defaults: defaults,
      legacySidebarWidth: preferences.sidebarWidth
    )
    let content = WorkspaceViewController(
      model: model,
      preferences: preferences,
      panelLayoutStore: panelLayoutStore
    )
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
    panelLayoutStores[ObjectIdentifier(window)] = panelLayoutStore
    if let autosaveName { window.setFrameAutosaveName(autosaveName) }
    window.center()
    window.appearance = preferences.preferredAppearance
    return NSWindowController(window: window)
  }

  /// 仅在用户结束拖动后保存窗口尺寸，避免 live resize 期间反复刷新整个 AppKit 工作区。
  func windowDidEndLiveResize(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    // 设置窗口只记高度（宽度被 min/max 锁死），且不进 AsterConfiguration——它属于窗口
    // 状态而非用户配置，导出配置时不应带走。
    if window === settingsWindowController?.window {
      settingsWindowController?.persistContentHeight()
      return
    }
    guard window === mainWindowController?.window else { return }
    preferences.configuration.appearance.windowWidth = window.contentLayoutRect.width
    preferences.configuration.appearance.windowHeight = window.contentLayoutRect.height
  }

  func windowDidBecomeKey(_ notification: Notification) {
    guard let window = notification.object as? NSWindow,
      let store = panelLayoutStores[ObjectIdentifier(window)]
    else { return }
    let identifier = ObjectIdentifier(window)
    activeWorkspaceWindowOrder.removeAll { $0 == identifier }
    activeWorkspaceWindowOrder.append(identifier)
    panelSettingsBinding.bind(store)
  }

  func windowWillClose(_ notification: Notification) {
    guard let window = notification.object as? NSWindow else { return }
    if window === settingsWindowController?.window {
      // 缩放按钮（纵向 zoom）不触发 live resize 回调，关闭时补记一次高度。
      settingsWindowController?.persistContentHeight()
      setWorkspaceSettingsPresentationActive(false)
      return
    }
    let identifier = ObjectIdentifier(window)
    activeWorkspaceWindowOrder.removeAll { $0 == identifier }
    if let closingStore = panelLayoutStores.removeValue(forKey: identifier),
      panelSettingsBinding.isBound(to: closingStore)
    {
      let replacement = activeWorkspaceWindowOrder.reversed().lazy.compactMap {
        self.panelLayoutStores[$0]
      }.first
      panelSettingsBinding.bind(replacement)
    }
    guard let record = additionalWorkspaceWindows.removeValue(forKey: identifier) else {
      return
    }
    // 应用整体退出已在两阶段事务中统一提交；用户单独关窗则在可取消确认成功后，
    // 到这里才执行不可逆的快照和 PTY 终止。
    if !isTerminating { record.model.commitTermination() }
    dockActivityCoordinator.removeModel(record.model)
    // 附加窗口不参与下次启动恢复；关闭后清掉它的独立 suite，避免每次新建窗口留下
    // 无法再访问的 UserDefaults 域。主窗口快照仍由标准域正常保存。
    if !isTerminating {
      UserDefaults.standard.removePersistentDomain(forName: record.defaultsSuiteName)
      persistAdditionalWorkspaceSuites()
    }
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    guard !isTerminating,
      let record = additionalWorkspaceWindows[ObjectIdentifier(sender)]
    else { return true }
    return record.model.confirmTermination()
  }

  /// 设置页的“恢复默认尺寸”立即作用于主窗口，同时让后续启动使用相同尺寸。
  func applyDefaultMainWindowSize() {
    guard let window = mainWindowController?.window else { return }
    window.setContentSize(NSSize(width: 1180, height: 760))
    window.center()
  }

  @objc func showSettings(_ sender: Any?) {
    themeSwitcherPanelController?.dismiss(commit: false)
    themeSwitcherPanelController = nil
    // 设置窗口独立展示，但主工作区也必须可见；无 key window 时先走正式恢复路径。
    if NSApp.keyWindow == nil { showMainWindow() }
    setWorkspaceSettingsPresentationActive(true)
    if let settingsWindowController {
      settingsWindowController.showWindow(sender)
      settingsWindowController.window?.makeKeyAndOrderFront(sender)
      (settingsWindowController.contentViewController as? SettingsViewController)?
        .focusInitialControl()
      return
    }

    let content = SettingsViewController(
      preferences: preferences,
      panelLayoutBinding: panelSettingsBinding
    )
    let controller = AsterSettingsWindowController(
      content: content,
      appearance: preferences.preferredAppearance
    )
    guard let window = controller.window else { return }
    window.delegate = self
    settingsWindowController = controller
    controller.showWindow(sender)
    window.makeKeyAndOrderFront(sender)
    DispatchQueue.main.async { [weak content] in content?.focusInitialControl() }
  }

  /// 帮助菜单中的用户主动反馈入口。无可见工作区时先恢复主窗口，保证 sheet 有稳定宿主。
  @objc private func showFeedback(_ sender: Any?) {
    showMainWindow()
    guard let parent = NSApp.keyWindow ?? mainWindowController?.window else { return }
    let controller = FeedbackSheetController()
    feedbackSheetController = controller
    controller.present(on: parent) { [weak self] in self?.feedbackSheetController = nil }
  }

  /// 深链入口复用唯一设置窗口，并直接切到目标分类。
  func showSettings(section: SettingsViewController.Section) {
    showSettings(nil)
    (settingsWindowController?.contentViewController as? SettingsViewController)?
      .showSection(section)
  }

  /// 设置控件会广播全局配置。打开设置期间让所有工作区只就地更新现存终端，并把
  /// 结构刷新合并到设置窗口关闭时执行一次，避免独立窗口中的 NSSwitch 动画卡顿。
  private func setWorkspaceSettingsPresentationActive(_ active: Bool) {
    let controllers =
      [mainWindowController?.window?.contentViewController as? WorkspaceViewController]
      + additionalWorkspaceWindows.values.map {
        $0.controller.window?.contentViewController as? WorkspaceViewController
      }
    for controller in controllers.compactMap({ $0 }) {
      controller.setSettingsPresentationActive(active)
    }
  }

  private func applyAppearance() {
    mainWindowController?.window?.appearance = preferences.preferredAppearance
    for record in additionalWorkspaceWindows.values {
      record.controller.window?.appearance = preferences.preferredAppearance
    }
    settingsWindowController?.window?.appearance = preferences.preferredAppearance
  }

  private func synchronizeWorkspaceConfiguration() {
    for workspaceModel in [model] + additionalWorkspaceWindows.values.map(\.model) {
      workspaceModel.newTabPosition = preferences.configuration.appearance.resolvedNewTabPosition
      workspaceModel.frecencyAutoRecord = preferences.configuration.shell.resolvedFrecencyAutoRecord
      workspaceModel.recipeReplayMode = preferences.configuration.recipeReplayMode
      workspaceModel.enabledAgentProviders = AgentProvider.allCases.filter { provider in
        preferences.configuration.agents.enabledAgents.contains(provider.commandName)
      }
      workspaceModel.agentLaunchCommands =
        preferences.configuration.agents.customLaunchCommands ?? [:]
    }
  }

  private var activeWorkspaceViewController: WorkspaceViewController? {
    guard let keyWindow = NSApp.keyWindow,
      let controller = keyWindow.contentViewController as? WorkspaceViewController
    else {
      return mainWindowController?.window?.contentViewController as? WorkspaceViewController
    }
    return controller
  }

  private var activeWorkspaceModel: AppModel {
    activeWorkspaceViewController?.model ?? model
  }

  @objc private func newWindow(_ sender: Any?) {
    _ = createWorkspaceWindow(initialPane: nil, sender: sender)
  }

  /// 所有新窗口入口（菜单、命令面板、CLI `--new-window`）共用该事务。先完整创建
  /// AppModel 和可选首个 Pane，再显示窗口，用户不会看到旧窗口短暂插入错误标签。
  @discardableResult
  private func createWorkspaceWindow(initialPane: PaneDescriptor?, sender: Any?) -> Bool {
    createWorkspaceWindow(
      suiteName: AdditionalWorkspaceWindowRegistry.prefix + UUID().uuidString,
      initialPane: initialPane,
      restoring: false,
      sender: sender
    )
  }

  @discardableResult
  private func createWorkspaceWindow(
    suiteName: String,
    initialPane: PaneDescriptor?,
    initialTab: TerminalTabItem? = nil,
    restoring: Bool,
    sender: Any?
  ) -> Bool {
    guard AdditionalWorkspaceWindowRegistry.normalized([suiteName]) == [suiteName] else {
      return false
    }
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      return false
    }
    if !restoring { defaults.removePersistentDomain(forName: suiteName) }
    let windowModel = AppModel(defaults: defaults)
    configureWorkspaceModel(windowModel)
    windowModel.beginApplicationSession(
      launchBehavior: restoring ? .restoreLastSession : .newWindow)
    if let initialTab {
      windowModel.receiveTransferredTab(initialTab)
    } else if let initialPane {
      windowModel.openResourceInNewTab(initialPane)
    }
    let controller = makeWorkspaceWindow(
      model: windowModel,
      defaults: defaults,
      autosaveName: nil
    )
    guard let window = controller.window else {
      defaults.removePersistentDomain(forName: suiteName)
      return false
    }
    additionalWorkspaceWindows[ObjectIdentifier(window)] = WorkspaceWindowRecord(
      controller: controller,
      model: windowModel,
      defaultsSuiteName: suiteName
    )
    dockActivityCoordinator.addModel(windowModel)
    persistAdditionalWorkspaceSuites()
    synchronizeWorkspaceConfiguration()
    controller.showWindow(sender)
    window.makeKeyAndOrderFront(sender)
    return true
  }

  private func restoreAdditionalWorkspaceWindows() {
    let suites = AdditionalWorkspaceWindowRegistry.normalized(
      UserDefaults.standard.stringArray(forKey: additionalWorkspaceSuitesKey) ?? []
    )
    for suiteName in suites {
      _ = createWorkspaceWindow(
        suiteName: suiteName,
        initialPane: nil,
        restoring: true,
        sender: nil
      )
    }
  }

  private func persistAdditionalWorkspaceSuites() {
    let suites = additionalWorkspaceWindows.values.map(\.defaultsSuiteName).sorted()
    UserDefaults.standard.set(
      AdditionalWorkspaceWindowRegistry.normalized(suites),
      forKey: additionalWorkspaceSuitesKey
    )
  }

  /// 把 AppKit 窗口动作注入每个模型；附加窗口与主窗口因此拥有完全相同的命令面板
  /// 和 CLI 路由，而模型测试无需构造 NSWindow。
  private func configureWorkspaceModel(_ workspaceModel: AppModel) {
    workspaceModel.onTabOrderBecameManual = { [weak self] in
      self?.preferences.sidebarTabOrder = .manual
    }
    workspaceModel.onRequestNewWindow = { [weak self] descriptor in
      self?.createWorkspaceWindow(initialPane: descriptor, sender: nil) ?? false
    }
    workspaceModel.onRequestToggleWindowPin = { [weak self, weak workspaceModel] in
      guard let self, let workspaceModel else { return }
      self.togglePinWindow(for: workspaceModel)
    }
    workspaceModel.onRequestPictureInPicture = { [weak self, weak workspaceModel] follows in
      guard let self, let workspaceModel else { return }
      self.showPictureInPicture(
        model: workspaceModel,
        mode: follows ? .followActivePane : .currentPane
      )
    }
  }

  /// 标签拖放以屏幕坐标判断目标工作区。落在另一个 Aster 工作区时直接转移现有
  /// Tab；落在窗口外时创建新窗口。创建失败会把原对象放回源模型，不丢 PTY。
  func moveTab(_ tabID: UUID, from sourceModel: AppModel, toScreenPoint point: NSPoint) {
    let targetModel = NSApp.windows.reversed().compactMap { window -> AppModel? in
      guard window.isVisible, window.frame.contains(point),
        let controller = window.contentViewController as? WorkspaceViewController,
        controller.model !== sourceModel
      else { return nil }
      return controller.model
    }.first
    if let targetModel, let tab = sourceModel.detachTabForTransfer(id: tabID) {
      targetModel.receiveTransferredTab(tab)
      targetModel.persistWorkspace()
      workspaceWindow(for: targetModel)?.makeKeyAndOrderFront(nil)
      return
    }
    guard targetModel == nil, let tab = sourceModel.detachTabForTransfer(id: tabID) else { return }
    let suiteName = AdditionalWorkspaceWindowRegistry.prefix + UUID().uuidString
    if !createWorkspaceWindow(
      suiteName: suiteName,
      initialPane: nil,
      initialTab: tab,
      restoring: false,
      sender: nil
    ) {
      sourceModel.receiveTransferredTab(tab)
    }
  }

  @objc private func closeActiveWindow(_ sender: Any?) {
    NSApp.keyWindow?.performClose(sender)
  }

  // MARK: - Native menu actions

  @objc private func newTab(_ sender: Any?) {
    activeWorkspaceModel.newTab()
    if NSApp.keyWindow == nil { showMainWindow() }
  }
  @objc private func reopenLastClosedTab(_ sender: Any?) { _ = activeWorkspaceModel.reopenLastClosedTab() }
  @objc private func renameTab(_ sender: Any?) { activeWorkspaceModel.promptRenameSelectedTab() }
  @objc private func openFile(_ sender: Any?) { activeWorkspaceModel.openFile() }
  @objc private func openFolder(_ sender: Any?) { activeWorkspaceModel.openFolder() }
  @objc private func closeTab(_ sender: Any?) { activeWorkspaceModel.closeSelectedTab() }
  /// ⌘W：标签内还有分屏时只关闭聚焦面板，最后一个面板才关闭整个标签页。
  @objc private func closePaneOrTab(_ sender: Any?) { activeWorkspaceModel.closeSelectedPaneOrTab() }
  @objc private func splitRight(_ sender: Any?) { activeWorkspaceModel.splitSelectedTab(.right) }
  @objc private func splitLeft(_ sender: Any?) { activeWorkspaceModel.splitSelectedTab(.left) }
  @objc private func splitDown(_ sender: Any?) { activeWorkspaceModel.splitSelectedTab(.down) }
  @objc private func splitUp(_ sender: Any?) { activeWorkspaceModel.splitSelectedTab(.up) }
  @objc private func closePane(_ sender: Any?) { activeWorkspaceModel.closeActivePane() }
  @objc private func zoomSplit(_ sender: Any?) { activeWorkspaceModel.toggleZoomActivePane() }
  @objc private func equalizeSplits(_ sender: Any?) { activeWorkspaceModel.equalizeSplits() }
  @objc private func moveDividerUp(_ sender: Any?) { activeWorkspaceModel.moveDivider(.up) }
  @objc private func moveDividerDown(_ sender: Any?) { activeWorkspaceModel.moveDivider(.down) }
  @objc private func moveDividerLeft(_ sender: Any?) { activeWorkspaceModel.moveDivider(.left) }
  @objc private func moveDividerRight(_ sender: Any?) { activeWorkspaceModel.moveDivider(.right) }
  @objc private func focusPaneUp(_ sender: Any?) { activeWorkspaceModel.focusPane(.up) }
  @objc private func focusPaneDown(_ sender: Any?) { activeWorkspaceModel.focusPane(.down) }
  @objc private func focusPaneLeft(_ sender: Any?) { activeWorkspaceModel.focusPane(.left) }
  @objc private func focusPaneRight(_ sender: Any?) { activeWorkspaceModel.focusPane(.right) }
  @objc private func focusNextPane(_ sender: Any?) { activeWorkspaceModel.focusPane(forward: true) }
  @objc private func focusPreviousPane(_ sender: Any?) { activeWorkspaceModel.focusPane(forward: false) }
  @objc private func saveDocument(_ sender: Any?) { activeWorkspaceModel.saveActiveDocument() }
  @objc private func find(_ sender: Any?) { activeWorkspaceModel.toggleFind() }
  @objc private func globalFind(_ sender: Any?) { activeWorkspaceModel.toggleGlobalFind() }
  @objc private func commandPalette(_ sender: Any?) { activeWorkspaceModel.togglePalette() }
  @objc private func showThemeSwitcher(_ sender: Any?) {
    if let themeSwitcherPanelController {
      themeSwitcherPanelController.dismiss(commit: false)
      self.themeSwitcherPanelController = nil
      return
    }
    guard let workspace = activeWorkspaceViewController,
      let anchorWindow = workspace.view.window
    else { return }
    activeWorkspaceModel.dismissWorkspaceOverlays()
    workspace.setThemeSwitcherPresentationActive(true)
    let controller = ThemeSwitcherPanelController(preferences: preferences) {
      [weak self, weak workspace] in
      workspace?.setThemeSwitcherPresentationActive(false)
      self?.themeSwitcherPanelController = nil
    }
    themeSwitcherPanelController = controller
    // 菜单 action 发生时系统仍在收起 menu tracking window；同步 makeKey 会在菜单关闭
    // 的同一轮被主窗口抢回焦点，Panel 随即误判成“点到外部”而取消。下一轮再展示，
    // 键盘焦点和窗口生命周期才与用户看到的面板一致。
    DispatchQueue.main.async { [weak self, weak controller, weak anchorWindow] in
      guard let self, let controller, let anchorWindow,
        self.themeSwitcherPanelController === controller
      else { return }
      controller.present(relativeTo: anchorWindow)
    }
  }
  @objc private func openQuickly(_ sender: Any?) { activeWorkspaceModel.toggleOpenQuickly(filter: .all) }
  @objc private func openQuicklyCurrent(_ sender: Any?) { activeWorkspaceModel.toggleOpenQuickly(filter: .current) }
  @objc private func openRecipe(_ sender: Any?) { activeWorkspaceModel.openRecipe() }
  @objc private func saveRecipe(_ sender: Any?) { activeWorkspaceModel.saveRecipe() }
  @objc private func toggleInspector(_ sender: Any?) { activeWorkspaceModel.toggleInspector() }
  /// 折叠/展开标签栏：与垂直侧栏悬停出现的折叠按钮共用同一配置开关。
  @objc private func toggleTabBarVisibility(_ sender: Any?) {
    preferences.configuration.appearance.showTabBar.toggle()
  }
  @objc private func increaseFontSize(_ sender: Any?) { preferences.adjustFontSize(by: 1) }
  @objc private func decreaseFontSize(_ sender: Any?) { preferences.adjustFontSize(by: -1) }
  @objc private func resetFontSize(_ sender: Any?) { preferences.resetFontSize() }
  @objc private func toggleFullScreen(_ sender: Any?) {
    workspaceWindow(for: activeWorkspaceModel)?.toggleFullScreen(sender)
  }
  @objc private func toggleSecureKeyboardEntry(_ sender: Any?) {
    SecureInputCoordinator.shared.toggleManualRequest()
  }
  @objc private func toggleActivePaneReadOnly(_ sender: Any?) {
    activeWorkspaceModel.toggleActivePaneReadOnly()
  }
  @objc private func toggleComposer(_ sender: Any?) { activeWorkspaceModel.toggleComposer() }
  @objc private func togglePromptQueue(_ sender: Any?) { activeWorkspaceModel.togglePromptQueue() }
  @objc private func showAgentHistory(_ sender: Any?) { activeWorkspaceModel.toggleAgentHistory() }
  @objc private func sendToChat(_ sender: Any?) { activeWorkspaceModel.presentAgentChat() }
  @objc private func togglePinWindow(_ sender: Any?) {
    togglePinWindow(for: activeWorkspaceModel)
  }

  private func togglePinWindow(for workspaceModel: AppModel) {
    guard let window = workspaceWindow(for: workspaceModel) else { return }
    window.level = window.level == .floating ? .normal : .floating
  }
  @objc private func pictureInPictureCurrentPane(_ sender: Any?) {
    showPictureInPicture(mode: .currentPane)
  }
  @objc private func pictureInPictureFollowActivePane(_ sender: Any?) {
    showPictureInPicture(mode: .followActivePane)
  }
  @objc private func closePictureInPicture(_ sender: Any?) {
    pictureInPictureController?.close()
    pictureInPictureController = nil
  }

  private func showPictureInPicture(mode: PanePictureInPictureController.Mode) {
    showPictureInPicture(model: activeWorkspaceModel, mode: mode)
  }

  private func showPictureInPicture(
    model workspaceModel: AppModel,
    mode: PanePictureInPictureController.Mode
  ) {
    pictureInPictureController?.close()
    let controller = PanePictureInPictureController(
      model: workspaceModel, preferences: preferences, mode: mode)
    pictureInPictureController = controller
    controller.show()
  }

  private func workspaceWindow(for workspaceModel: AppModel) -> NSWindow? {
    if workspaceModel === model { return mainWindowController?.window }
    return additionalWorkspaceWindows.values.first(where: { $0.model === workspaceModel })?
      .controller.window
  }

  private func makeMainMenu() -> NSMenu {
    let menu = NSMenu()
    menu.addItem(appMenuItem())
    menu.addItem(fileMenuItem())
    menu.addItem(editMenuItem())
    menu.addItem(shellModeMenuItem())
    menu.addItem(workspaceMenuItem())
    menu.addItem(windowMenuItem())
    menu.addItem(helpMenuItem())
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

  private func helpMenuItem() -> NSMenuItem {
    let item = NSMenuItem()
    let submenu = NSMenu(title: "帮助")
    submenu.addItem(menuItem("反馈问题…", #selector(showFeedback(_:)), "", modifiers: []))
    NSApp.helpMenu = submenu
    item.submenu = submenu
    return item
  }

  private func fileMenuItem() -> NSMenuItem {
    let item = NSMenuItem()
    let submenu = NSMenu(title: "文件")
    submenu.addItem(menuItem("新建窗口", #selector(newWindow(_:)), "n"))
    submenu.addItem(menuItem("新建标签页", #selector(newTab(_:)), "t"))
    submenu.addItem(
      menuItem("重新打开最近关闭的标签页", #selector(reopenLastClosedTab(_:)), "t", modifiers: [.command, .shift]))
    submenu.addItem(menuItem("打开文件…", #selector(openFile(_:)), "o"))
    submenu.addItem(menuItem("打开文件夹…", #selector(openFolder(_:)), "", modifiers: []))
    submenu.addItem(.separator())
    submenu.addItem(menuItem("保存", #selector(saveDocument(_:)), "s"))
    submenu.addItem(menuItem("重命名标签页…", #selector(renameTab(_:)), "", modifiers: []))
    submenu.addItem(menuItem("关闭", #selector(closePaneOrTab(_:)), "w"))
    submenu.addItem(menuItem("关闭标签页", #selector(closeTab(_:)), "", modifiers: []))
    submenu.addItem(
      menuItem("关闭窗口", #selector(closeActiveWindow(_:)), "w", modifiers: [.command, .shift]))
    item.submenu = submenu
    return item
  }

  func editMenuItem() -> NSMenuItem {
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
    submenu.addItem(.separator())
    submenu.addItem(insertMenuItem())
    let importFromDevice = NSMenuItem(
      title: "Insert from iPhone",
      action: nil,
      keyEquivalent: ""
    )
    importFromDevice.identifier = NSMenuItem.importFromDeviceIdentifier
    submenu.addItem(importFromDevice)
    submenu.addItem(
      menuItem(
        "编辑器", #selector(toggleComposer(_:)), "e", modifiers: [.command, .shift],
        symbol: "rectangle.and.pencil.and.ellipsis"))
    submenu.addItem(
      menuItem(
        "Prompt 队列…", #selector(togglePromptQueue(_:)), "m", modifiers: [.command, .shift],
        symbol: "list.bullet"))
    submenu.addItem(
      menuItem(
        "发送到聊天…", #selector(sendToChat(_:)), "", modifiers: [], symbol: "message"))
    submenu.addItem(.separator())
    submenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
    submenu.addItem(.separator())
    submenu.addItem(menuItem("查找", #selector(find(_:)), "f"))
    submenu.addItem(
      menuItem("在全部 Pane 中查找", #selector(globalFind(_:)), "f", modifiers: [.command, .shift]))
    submenu.addItem(.separator())
    submenu.addItem(
      menuItem(
        "安全键盘输入", #selector(toggleSecureKeyboardEntry(_:)), "", modifiers: []))
    item.submenu = submenu
    return item
  }

  /// Otty 的“插入”只预填路径，不自动回车。文件选择和截屏都通过 responder chain
  /// 定位当前终端，因此编辑器 Pane 或只读终端会由真实接收者自动置灰。
  private func insertMenuItem() -> NSMenuItem {
    let item = NSMenuItem(title: "插入", action: nil, keyEquivalent: "")
    let submenu = NSMenu(title: "插入")
    submenu.addItem(
      responderMenuItem(
        "文件路径…", #selector(AsterTerminalView.insertFilePath(_:)), "", modifiers: []))
    submenu.addItem(
      responderMenuItem(
        "截屏", #selector(AsterTerminalView.insertScreenshot(_:)), "", modifiers: []))
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
    submenu.addItem(
      menuItem("Composer", #selector(toggleComposer(_:)), "\r", modifiers: [.command, .shift]))
    submenu.addItem(menuItem("Agent 历史", #selector(showAgentHistory(_:)), "", modifiers: []))
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
  func workspaceMenuItem() -> NSMenuItem {
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
    submenu.addItem(menuItem("主题", #selector(showThemeSwitcher(_:)), "", modifiers: []))
    submenu.addItem(
      menuItem("命令面板", #selector(commandPalette(_:)), "p", modifiers: [.command, .shift]))
    submenu.addItem(
      menuItem("Open Quickly", #selector(openQuickly(_:)), "o", modifiers: [.command, .shift]))
    submenu.addItem(menuItem("Open Quickly · 当前", #selector(openQuicklyCurrent(_:)), "j"))
    submenu.addItem(menuItem("显示/隐藏详情面板", #selector(toggleInspector(_:)), "", modifiers: []))
    submenu.addItem(menuItem("显示/隐藏标签栏", #selector(toggleTabBarVisibility(_:)), "", modifiers: []))
    submenu.addItem(.separator())
    submenu.addItem(menuItem("增大字号", #selector(increaseFontSize(_:)), "="))
    submenu.addItem(menuItem("减小字号", #selector(decreaseFontSize(_:)), "-"))
    submenu.addItem(menuItem("重置字号", #selector(resetFontSize(_:)), "0"))
    submenu.addItem(.separator())
    submenu.addItem(menuItem("Pin Window", #selector(togglePinWindow(_:)), "", modifiers: []))
    let pip = NSMenuItem(title: "Picture in Picture", action: nil, keyEquivalent: "")
    let pipMenu = NSMenu(title: "Picture in Picture")
    pipMenu.addItem(menuItem("当前 Pane", #selector(pictureInPictureCurrentPane(_:)), "", modifiers: []))
    pipMenu.addItem(menuItem("跟随活动 Pane", #selector(pictureInPictureFollowActivePane(_:)), "", modifiers: []))
    pipMenu.addItem(.separator())
    pipMenu.addItem(menuItem("关闭 Picture in Picture", #selector(closePictureInPicture(_:)), "", modifiers: []))
    pip.submenu = pipMenu
    submenu.addItem(pip)
    submenu.addItem(.separator())
    submenu.addItem(terminalScrollMenuItem())
    submenu.addItem(.separator())
    submenu.addItem(menuItem("打开 Recipe…", #selector(openRecipe(_:)), "", modifiers: []))
    submenu.addItem(menuItem("保存为 Recipe…", #selector(saveRecipe(_:)), "", modifiers: []))
    submenu.addItem(.separator())
    submenu.addItem(
      menuItem(
        "进入全屏幕", #selector(toggleFullScreen(_:)), "f", modifiers: [.function]))
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
    submenu.addItem(menuItem("新建窗口", #selector(newWindow(_:)), "n"))
    submenu.addItem(menuItem("关闭窗口", #selector(closeActiveWindow(_:)), "w", modifiers: [.command, .shift]))
    submenu.addItem(.separator())
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
    modifiers: NSEvent.ModifierFlags = .command,
    symbol: String? = nil
  ) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
    item.keyEquivalentModifierMask = modifiers
    item.target = self
    if let symbol {
      item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
    }
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
    if action == #selector(increaseFontSize(_:)) {
      return preferences.fontSize < 32
    }
    if action == #selector(decreaseFontSize(_:)) {
      return preferences.fontSize > 9
    }
    if action == #selector(resetFontSize(_:)) {
      return preferences.fontSize != AsterConfiguration.default.appearance.fontSize
    }
    if action == #selector(toggleFullScreen(_:)) {
      guard let window = workspaceWindow(for: activeWorkspaceModel) else { return false }
      menuItem.title = window.styleMask.contains(.fullScreen) ? "退出全屏幕" : "进入全屏幕"
      return true
    }
    if action == #selector(toggleActivePaneReadOnly(_:)) {
      menuItem.state = activeWorkspaceModel.activePaneIsReadOnly ? .on : .off
      return activeWorkspaceModel.selectedTab?.activeRuntime != nil
    }
    if action == #selector(togglePromptQueue(_:)) {
      return activeWorkspaceModel.canPresentPromptQueue
    }
    guard Self.splitOnlySelectors.contains(action) else { return true }
    return activeWorkspaceModel.selectedTabHasSplits
  }
}
