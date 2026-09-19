import AppKit
import AsterCore

/// Quick Terminal 的窗口策略。只改变窗口展示，隐藏不会结束 Shell 或重建 surface。
@MainActor
final class QuickTerminalController: NSObject, NSWindowDelegate, WorkspaceTerminationParticipant {
  private let preferences: AppPreferences
  private let hotKey = QuickTerminalHotKey()
  private(set) var window: NSPanel?
  private(set) var session: TerminalSession?
  private(set) var isPresented = false
  var ownsKeyWindow: Bool { window?.isKeyWindow == true }
  /// 终端 host 的内边距容器。窗口 contentView 就是它，host 按 `contentInset` 内缩。
  private var terminalContainer: NSView?
  private var previousApplication: NSRunningApplication?
  private var animationGeneration = 0
  private var reportedShortcutFailure: String?
  /// Shell 已自行退出、等待收尾的标记。隐藏动画结束后才真正丢弃会话。
  private var pendingSessionDiscard = false
  var workingDirectory: () -> String = { FileManager.default.homeDirectoryForCurrentUser.path }

  init(preferences: AppPreferences) {
    self.preferences = preferences
    super.init()
    hotKey.onToggle = { [weak self] in self?.toggle() }
  }

  private func text(_ name: String, _ fallback: String) -> String {
    preferences.compatibilityString(forKey: "quickTerminal.\(name)", default: fallback)
  }

  private func flag(_ name: String, _ fallback: Bool) -> Bool {
    guard case .bool(let value) = preferences.settingsCompatibility["quickTerminal.\(name)"] else {
      return fallback
    }
    return value
  }

  /// 设置热更新不启动终端。快捷键冲突明确提示，用户仍能经窗口菜单呼出。
  func refresh() {
    let shortcut = text("shortcut", "none")
    let status = hotKey.configure(shortcut: shortcut)
    if status != noErr, reportedShortcutFailure != shortcut {
      reportedShortcutFailure = shortcut
      let alert = NSAlert()
      alert.messageText = L("Quick Terminal 快捷键无法注册")
      alert.informativeText = L("快捷键可能已被其他应用占用。请在设置中更换快捷键；仍可通过“窗口 → Quick Terminal”打开。")
      alert.runModal()
    } else if status == noErr {
      reportedShortcutFailure = nil
    }
    reconcileManualSize()
    guard let window else { return }
    window.collectionBehavior =
      flag("followSpaces", true)
      ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
      : [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
    window.appearance = preferences.preferredAppearance
    if let session {
      let host = session.makeTerminalHost(preferences: preferences)
      // Host 由 session 长期复用，重建后可能不在内边距容器里；不重挂就会丢掉内边距。
      if host.superview !== terminalContainer { installTerminalHost(host) }
    }
    synchronizeTerminalBackground()
    if isPresented { positionWindow() }
  }

  func toggle() {
    if isPresented { hide() } else { show() }
  }

  func show() {
    guard !isPresented else { return }
    // 上一轮 Shell 退出后的收尾还没跑完就被再次呼出：先丢弃，否则会把已结束的画面拿出来。
    if pendingSessionDiscard { discardSession() }
    if let app = NSWorkspace.shared.frontmostApplication,
      app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    {
      previousApplication = app
    } else {
      previousApplication = nil
    }
    if window == nil {
      // 必须是 .titled + .fullSizeContentView，不能用 .borderless：borderless 窗口没有
      // 边缘拖拽区域，加 .resizable 也调不了大小。隐藏标题文字与红绿灯后外观与
      // borderless 一致，同时拿到系统圆角和四边 resize 手柄。
      let panel = QuickTerminalPanel(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
        styleMask: [.titled, .resizable, .fullSizeContentView, .nonactivatingPanel],
        backing: .buffered, defer: false)
      panel.title = "Aster Quick Terminal"
      panel.titleVisibility = .hidden
      panel.titlebarAppearsTransparent = true
      // 位置只由「位置」设置决定。透明标题栏默认可拖动窗口，必须两个开关一起关掉，
      // 否则用户能把窗口拖离设定的边缘，下次呼出又跳回去，看起来像丢了位置。
      panel.isMovable = false
      panel.isMovableByWindowBackground = false
      for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
        panel.standardWindowButton(button)?.isHidden = true
      }
      panel.minSize = Self.minimumSize
      panel.isReleasedWhenClosed = false
      panel.hidesOnDeactivate = false
      panel.isFloatingPanel = true
      panel.level = .floating
      panel.isExcludedFromWindowsMenu = true
      panel.delegate = self
      panel.onHide = { [weak self] in self?.hide() }
      window = panel
      let container = NSView()
      container.wantsLayer = true
      terminalContainer = container
      // 先挂 contentView 再装 host：容器此时才拿到 contentRect，host 的初始 frame 才算得对。
      panel.contentView = container
    }
    installSession()
    guard let window else { return }
    refresh()
    positionWindow()
    isPresented = true
    animationGeneration += 1
    window.alphaValue = 0
    window.makeKeyAndOrderFront(nil)
    _ = session?.focus()
    NSAnimationContext.runAnimationGroup { context in
      context.duration = animationDuration
      window.animator().alphaValue = 1
    }
  }

  /// 创建会话并把终端 host 装进内边距容器。
  ///
  /// 窗口在 Shell 退出后保留而会话被丢弃，所以建窗口和建会话必须分开，呼出时才能只补建缺的那一半。
  private func installSession() {
    guard window != nil, session == nil else { return }
    let terminal = TerminalSession(workingDirectory: workingDirectory())
    // 用户主动结束 Shell（`exit` / Ctrl+D）时收起窗口。信号终止、启动即失败不走这条回调，
    // 画面保留供排查，仍可经窗口菜单显式重启。
    terminal.onRequestCloseAfterExit = { [weak self] in self?.handleShellExit() }
    session = terminal
    installTerminalHost(terminal.makeTerminalHost(preferences: preferences))
  }

  /// Shell 自行退出：收起窗口并丢弃会话，下次呼出得到一个干净的 Shell。
  ///
  /// 回调发自会话自己的退出处理，必须延后一轮再销毁 surface，否则会在它收尾前释放内存。
  /// 窗口不销毁：淡出动画还要用它，位置与尺寸记忆也留着。
  private func handleShellExit() {
    pendingSessionDiscard = true
    DispatchQueue.main.async { [weak self] in
      guard let self, self.pendingSessionDiscard else { return }
      // 已经隐藏时没有动画可等，直接收尾；否则等淡出结束再拆 surface，避免露出空白窗口。
      if self.isPresented { self.hide() } else { self.discardSession() }
    }
  }

  /// 丢弃当前会话并清空终端容器。窗口、快捷键与尺寸记忆都保留。
  private func discardSession() {
    pendingSessionDiscard = false
    guard let session else { return }
    session.onRequestCloseAfterExit = nil
    self.session = nil
    session.stop(immediately: true)
    // stop() 只放弃对 host 的引用，不会把它摘出视图树；留着会挡住下一个会话的终端。
    terminalContainer?.subviews.forEach { $0.removeFromSuperview() }
  }

  /// 隐藏是可逆的展示操作；只有 shutdown 才销毁进程。代次阻止旧动画隐藏新窗口。
  func hide(restoreFocus: Bool = true) {
    guard isPresented, let window else { return }
    isPresented = false
    animationGeneration += 1
    let generation = animationGeneration
    NSAnimationContext.runAnimationGroup { context in
      context.duration = animationDuration
      window.animator().alphaValue = 0
    } completionHandler: { [weak self] in
      MainActor.assumeIsolated {
        guard let self, self.animationGeneration == generation, !self.isPresented else { return }
        window.orderOut(nil)
        if restoreFocus { self.previousApplication?.activate(options: []) }
        self.previousApplication = nil
        if self.pendingSessionDiscard { self.discardSession() }
      }
    }
  }

  private var animationDuration: Double {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return 0 }
    let value = preferences.compatibilityNumber(
      forKey: "quickTerminal.animationDuration", default: 0.15)
    return value.isFinite ? min(max(value, 0), 1) : 0.15
  }

  /// 与屏幕边缘的间距。0 表示贴边，上界按屏幕短边的三分之一夹紧，避免导入的大值把窗口挤空。
  private var margin: Double {
    let value = preferences.compatibilityNumber(forKey: "quickTerminal.margin", default: 12)
    return value.isFinite ? min(max(value, 0), 200) : 12
  }

  /// 布局设置的指纹。只要用户在设置里改了位置、尺寸或边距，手动拖拽出的尺寸就不再适用。
  private var layoutSignature: String {
    let fraction = preferences.compatibilityNumber(forKey: "quickTerminal.size", default: 50)
    return "\(text("position", "top"))|\(fraction)|\(margin)"
  }

  /// 设置里的布局字段变化时丢弃手动尺寸，回到百分比基准。签名为 nil 是首次读取（含重启
  /// 后第一次），此时必须保留记忆，否则每次启动都会把用户拖好的尺寸重置掉。
  private func reconcileManualSize() {
    let signature = layoutSignature
    guard preferences.quickTerminalLayoutSignature != signature else { return }
    if preferences.quickTerminalLayoutSignature != nil { preferences.quickTerminalManualSize = nil }
    preferences.quickTerminalLayoutSignature = signature
  }

  private func positionWindow() {
    let screen: NSScreen?
    switch text("screen", "main") {
    case "mouse":
      screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
    case "macos-menu-bar": screen = NSScreen.screens.first
    default: screen = NSScreen.main
    }
    guard let screen else { return }
    let fraction = preferences.compatibilityNumber(forKey: "quickTerminal.size", default: 50) / 100
    window?.setFrame(
      Self.frame(
        in: screen.visibleFrame, position: text("position", "top"), fraction: fraction,
        margin: margin, manualSize: preferences.quickTerminalManualSize),
      display: true)
  }

  /// 手动拖拽的下限。低于这个尺寸的终端已经无法阅读，同时给 Ghostty surface 留出有效网格。
  static let minimumSize = NSSize(width: 320, height: 160)

  /// 终端内容与窗口边缘之间的内边距。Ghostty surface 自己不留白，这里包一层容器实现，
  /// 只作用于 Quick Terminal，不去改全局的 `window-padding-*`（那会影响所有工作区 Pane）。
  static let contentInset: CGFloat = 20

  /// 把终端 host 装进内边距容器。用 autoresizing 而不是约束：host 在工作区路径下是
  /// frame 挂载的长期复用视图，混用约束会在它被移来移去时留下互相冲突的布局规则。
  /// `[.width, .height]` 让 host 随容器变化而四边内边距保持固定。
  private func installTerminalHost(_ host: NSView) {
    guard let container = terminalContainer else { return }
    host.removeFromSuperview()
    host.translatesAutoresizingMaskIntoConstraints = true
    host.autoresizingMask = [.width, .height]
    host.frame = container.bounds.insetBy(dx: Self.contentInset, dy: Self.contentInset)
    container.addSubview(host)
  }

  /// 内边距区域露出的是容器和窗口自身的背景，必须跟着终端背景色走，否则换主题后
  /// 窗口四周会留一圈系统窗口色的边。
  private func synchronizeTerminalBackground() {
    let color = NSColor(preferences.activeTheme.palette.windowBackground)
    terminalContainer?.layer?.backgroundColor = color.cgColor
    window?.backgroundColor = color
  }

  /// 使用屏幕可见区域，兼容负坐标副屏并避开菜单栏与 Dock；非法导入值按默认值归一。
  /// `margin` 只内缩「不贴边的那两侧」：顶部显示时左右留边距而上沿完全置顶，左右显示时
  /// 上下留边距而侧沿完全贴边，居中显示才四周都留。`manualSize` 是用户拖拽出的尺寸，
  /// 存在时覆盖百分比但仍夹紧在可用区域内。尺寸和位置分两步算：先定尺寸，再按 position
  /// 贴边（另一轴居中），这样手动改过副轴尺寸后窗口不会偏到一角。
  static func frame(
    in screen: NSRect, position: String, fraction: Double, margin: Double = 0,
    manualSize: NSSize? = nil
  ) -> NSRect {
    let ratio = fraction.isFinite ? min(max(fraction, 0.1), 1) : 0.5
    let limit = min(screen.width, screen.height) / 3
    let inset = margin.isFinite ? min(max(margin, 0), max(limit, 0)) : 0
    let area =
      switch position {
      case "left", "right": screen.insetBy(dx: 0, dy: inset)
      case "center": screen.insetBy(dx: inset, dy: inset)
      default: screen.insetBy(dx: inset, dy: 0)
      }
    var size = area.size
    switch position {
    case "left", "right": size.width *= ratio
    case "center":
      size.width *= ratio
      size.height *= ratio
    default: size.height *= ratio
    }
    if let manualSize, manualSize.width.isFinite, manualSize.height.isFinite {
      size.width = min(max(manualSize.width, minimumSize.width), area.width)
      size.height = min(max(manualSize.height, minimumSize.height), area.height)
    }
    var origin = NSPoint(x: area.midX - size.width / 2, y: area.midY - size.height / 2)
    switch position {
    case "left": origin.x = area.minX
    case "right": origin.x = area.maxX - size.width
    case "bottom": origin.y = area.minY
    case "center": break
    default: origin.y = area.maxY - size.height
    }
    return NSRect(origin: origin, size: size)
  }

  /// 拖拽结束才落盘：live resize 期间频繁写 UserDefaults 既浪费又会让手感发涩。
  func windowDidEndLiveResize(_ notification: Notification) {
    guard let window, isPresented else { return }
    preferences.quickTerminalManualSize = window.frame.size
  }

  func windowDidResignKey(_ notification: Notification) {
    guard window?.attachedSheet == nil, flag("autohide", true) else { return }
    hide(restoreFocus: false)
  }

  func windowShouldClose(_ sender: NSWindow) -> Bool {
    hide()
    return false
  }

  /// 自然退出保留最后画面，用户经窗口菜单显式重启。
  var canRestart: Bool { session?.canRestart == true }

  func restart() {
    if session?.restart() == true { _ = session?.focus() }
  }

  func confirmTermination() -> Bool {
    guard session?.isRunning == true else { return true }
    let policy = preferences.configuration.general.closeWindowConfirmation
    guard
      policy.requiresConfirmation(
        hasRunningProcess: session?.hasRunningCommand == true, tabCount: 1)
    else { return true }
    let alert = NSAlert()
    alert.messageText = L("退出 Quick Terminal？")
    alert.informativeText = L("退出应用会结束 Quick Terminal 中的 Shell 和运行中的任务。")
    alert.addButton(withTitle: L("退出"))
    alert.addButton(withTitle: L("取消"))
    return alert.runModal() == .alertFirstButtonReturn
  }

  func commitTermination() { shutdown() }

  func shutdown() {
    hotKey.stop()
    animationGeneration += 1
    pendingSessionDiscard = false
    isPresented = false
    window?.orderOut(nil)
    session?.stop(immediately: true)
    session = nil
    terminalContainer = nil
    window = nil
    previousApplication = nil
  }
}

@MainActor
private final class QuickTerminalPanel: NSPanel {
  var onHide: (() -> Void)?
  override var canBecomeKey: Bool { true }
  override var canBecomeMain: Bool { false }
  override func performClose(_ sender: Any?) { onHide?() }
}
