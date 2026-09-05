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
  private var previousApplication: NSRunningApplication?
  private var animationGeneration = 0
  private var reportedShortcutFailure: String?
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
      alert.messageText = "Quick Terminal 快捷键无法注册"
      alert.informativeText = "快捷键可能已被其他应用占用。请在设置中更换快捷键；仍可通过“窗口 → Quick Terminal”打开。"
      alert.runModal()
    } else if status == noErr {
      reportedShortcutFailure = nil
    }
    guard let window else { return }
    window.collectionBehavior =
      flag("followSpaces", true)
      ? [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
      : [.moveToActiveSpace, .fullScreenAuxiliary, .ignoresCycle]
    window.appearance = preferences.preferredAppearance
    if let session { _ = session.makeTerminalHost(preferences: preferences) }
    if isPresented { positionWindow() }
  }

  func toggle() {
    if isPresented { hide() } else { show() }
  }

  func show() {
    guard !isPresented else { return }
    if let app = NSWorkspace.shared.frontmostApplication,
      app.processIdentifier != ProcessInfo.processInfo.processIdentifier
    {
      previousApplication = app
    } else {
      previousApplication = nil
    }
    if window == nil {
      let panel = QuickTerminalPanel(
        contentRect: NSRect(x: 0, y: 0, width: 800, height: 400),
        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
      panel.title = "Aster Quick Terminal"
      panel.isReleasedWhenClosed = false
      panel.hidesOnDeactivate = false
      panel.isFloatingPanel = true
      panel.level = .floating
      panel.isExcludedFromWindowsMenu = true
      panel.delegate = self
      panel.onHide = { [weak self] in self?.hide() }
      window = panel
      let terminal = TerminalSession(workingDirectory: workingDirectory())
      session = terminal
      panel.contentView = terminal.makeTerminalHost(preferences: preferences)
    }
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
      }
    }
  }

  private var animationDuration: Double {
    if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return 0 }
    let value = preferences.compatibilityNumber(
      forKey: "quickTerminal.animationDuration", default: 0.15)
    return value.isFinite ? min(max(value, 0), 1) : 0.15
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
      Self.frame(in: screen.visibleFrame, position: text("position", "top"), fraction: fraction),
      display: true)
  }

  /// 使用屏幕可见区域，兼容负坐标副屏并避开菜单栏与 Dock；非法导入值按默认值归一。
  static func frame(in screen: NSRect, position: String, fraction: Double) -> NSRect {
    let ratio = fraction.isFinite ? min(max(fraction, 0.1), 1) : 0.5
    var frame = screen
    switch position {
    case "left", "right":
      frame.size.width *= ratio
      if position == "right" { frame.origin.x = screen.maxX - frame.width }
    case "center":
      frame.size.width *= ratio
      frame.size.height *= ratio
      frame.origin = NSPoint(x: screen.midX - frame.width / 2, y: screen.midY - frame.height / 2)
    default:
      frame.size.height *= ratio
      if position != "bottom" { frame.origin.y = screen.maxY - frame.height }
    }
    return frame
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
    alert.messageText = "退出 Quick Terminal？"
    alert.informativeText = "退出应用会结束 Quick Terminal 中的 Shell 和运行中的任务。"
    alert.addButton(withTitle: "退出")
    alert.addButton(withTitle: "取消")
    return alert.runModal() == .alertFirstButtonReturn
  }

  func commitTermination() { shutdown() }

  func shutdown() {
    hotKey.stop()
    animationGeneration += 1
    isPresented = false
    window?.orderOut(nil)
    session?.stop(immediately: true)
    session = nil
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
