import AppKit
import Carbon
import Testing

@testable import Aster

@MainActor
@Test func quickTerminalGeometryRespectsEdgesAndNegativeScreenOrigins() {
  let screen = NSRect(x: -1440, y: 24, width: 1440, height: 876)
  #expect(
    QuickTerminalController.frame(in: screen, position: "top", fraction: 0.5)
      == NSRect(x: -1440, y: 462, width: 1440, height: 438))
  #expect(QuickTerminalController.frame(in: screen, position: "bottom", fraction: 0.5).minY == 24)
  #expect(QuickTerminalController.frame(in: screen, position: "right", fraction: 0.5).maxX == 0)
  #expect(QuickTerminalController.frame(in: screen, position: "left", fraction: 0.5).minX == -1440)
  let center = QuickTerminalController.frame(in: screen, position: "center", fraction: 0.5)
  #expect(center.midX == screen.midX)
  #expect(center.midY == screen.midY)
  #expect(QuickTerminalController.frame(in: screen, position: "top", fraction: .nan).height == 438)
  #expect(QuickTerminalController.frame(in: screen, position: "left", fraction: 20).width == 1440)
}

@MainActor
@Test func quickTerminalGeometryAppliesMarginAndManualSize() {
  let screen = NSRect(x: 0, y: 100, width: 1600, height: 900)
  // 边距只内缩不贴边的两侧：顶部显示时左右留白，上沿必须完全贴住可见区域顶端。
  let top = QuickTerminalController.frame(in: screen, position: "top", fraction: 0.5, margin: 20)
  #expect(top == NSRect(x: 20, y: 550, width: 1560, height: 450))
  #expect(top.maxY == screen.maxY)
  let bottom = QuickTerminalController.frame(
    in: screen, position: "bottom", fraction: 0.5, margin: 20)
  #expect(bottom.minY == screen.minY)
  #expect(bottom.minX == 20)
  #expect(bottom.width == 1560)
  // 左右显示时反过来：上下留白，侧沿完全贴边。
  let right = QuickTerminalController.frame(in: screen, position: "right", fraction: 0.5, margin: 20)
  #expect(right.maxX == screen.maxX)
  #expect(right.height == 860)
  #expect(right.minY == 120)
  // 居中显示不贴任何边，四周都留白。
  let center = QuickTerminalController.frame(
    in: screen, position: "center", fraction: 1, margin: 20)
  #expect(center == screen.insetBy(dx: 20, dy: 20))

  // 手动尺寸覆盖百分比，但仍按位置贴边、另一轴居中，并夹紧在可用区域与下限之间。
  let manual = QuickTerminalController.frame(
    in: screen, position: "top", fraction: 0.5, margin: 20,
    manualSize: NSSize(width: 900, height: 300))
  #expect(manual.size == NSSize(width: 900, height: 300))
  #expect(manual.maxY == screen.maxY)
  #expect(manual.midX == screen.midX)
  let clamped = QuickTerminalController.frame(
    in: screen, position: "left", fraction: 0.5, margin: 20,
    manualSize: NSSize(width: 10, height: 100_000))
  #expect(clamped.width == QuickTerminalController.minimumSize.width)
  #expect(clamped.height == 860)
  #expect(clamped.minX == screen.minX)

  // 非法边距与越界边距都不能把窗口挤空；上界按短边三分之一夹紧。
  #expect(
    QuickTerminalController.frame(in: screen, position: "top", fraction: 0.5, margin: .nan)
      == QuickTerminalController.frame(in: screen, position: "top", fraction: 0.5))
  let huge = QuickTerminalController.frame(
    in: screen, position: "center", fraction: 1, margin: 10_000)
  #expect(huge.width == 1000)
  #expect(huge.height == 300)
}

@MainActor
@Test func quickTerminalManualResizePersistsUntilLayoutSettingChanges() throws {
  let suite = "QuickTerminalResizeTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let preferences = AppPreferences(defaults: defaults)
  preferences.setCompatibilityValue(.number(0), forKey: "quickTerminal.animationDuration")
  preferences.setCompatibilityValue(.bool(false), forKey: "quickTerminal.autohide")
  let controller = QuickTerminalController(preferences: preferences)
  defer { controller.shutdown() }
  controller.show()
  let window = try #require(controller.window)
  #expect(window.styleMask.contains(.resizable))
  #expect(window.minSize == QuickTerminalController.minimumSize)
  // 只能改大小，不能被拖走：位置始终由「位置」设置推导。
  #expect(!window.isMovable)
  #expect(!window.isMovableByWindowBackground)

  // 终端内容不贴窗口边：host 装在内边距容器里，四边各留 contentInset。
  let container = try #require(window.contentView)
  let host = try #require(container.subviews.first)
  let inset = QuickTerminalController.contentInset
  #expect(host.frame == container.bounds.insetBy(dx: inset, dy: inset))

  let resized = NSSize(width: 700, height: 350)
  window.setContentSize(resized)
  controller.windowDidEndLiveResize(
    Notification(name: NSWindow.didEndLiveResizeNotification, object: window))
  #expect(preferences.quickTerminalManualSize == window.frame.size)

  // 与布局无关的设置变化不能丢掉手动尺寸。
  preferences.setCompatibilityValue(.bool(false), forKey: "quickTerminal.followSpaces")
  controller.refresh()
  #expect(preferences.quickTerminalManualSize == resized)
  #expect(window.frame.size == resized)

  // 改动位置属于布局设置，手动尺寸作废并回到百分比基准。
  preferences.setCompatibilityValue(.string("bottom"), forKey: "quickTerminal.position")
  controller.refresh()
  #expect(preferences.quickTerminalManualSize == nil)
  #expect(window.frame.size != resized)
}

@MainActor
@Test func quickTerminalHideAndRapidReopenPreserveSession() async throws {
  let suite = "QuickTerminalTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let preferences = AppPreferences(defaults: defaults)
  preferences.setCompatibilityValue(.number(0.05), forKey: "quickTerminal.animationDuration")
  preferences.setCompatibilityValue(.bool(false), forKey: "quickTerminal.autohide")
  let controller = QuickTerminalController(preferences: preferences)
  defer { controller.shutdown() }
  controller.refresh()
  #expect(controller.session == nil)
  controller.show()
  let session = try #require(controller.session)
  let window = try #require(controller.window)
  #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
  #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
  controller.hide(restoreFocus: false)
  controller.show()
  try await Task.sleep(for: .milliseconds(150))
  #expect(controller.isPresented)
  #expect(window.isVisible)
  #expect(controller.session === session)
  #expect(controller.window === window)
  for _ in 0..<40 where !session.isRunning { try await Task.sleep(for: .milliseconds(50)) }
  #expect(session.isRunning)
  session.send("export ASTER_QUICK_TEST=retained")
  controller.hide(restoreFocus: false)
  try await Task.sleep(for: .milliseconds(100))
  controller.show()
  session.send("printf 'quick-%s-end\\n' \"$ASTER_QUICK_TEST\"")
  var output = ""
  for _ in 0..<60 {
    output = session.textSnapshot().lines.joined(separator: "\n")
    if output.contains("quick-retained-end") { break }
    try await Task.sleep(for: .milliseconds(50))
  }
  #expect(output.contains("quick-retained-end"))
  controller.windowDidResignKey(
    Notification(name: NSWindow.didResignKeyNotification, object: window))
  #expect(controller.isPresented)
  preferences.setCompatibilityValue(.bool(true), forKey: "quickTerminal.autohide")
  controller.windowDidResignKey(
    Notification(name: NSWindow.didResignKeyNotification, object: window))
  try await Task.sleep(for: .milliseconds(150))
  #expect(!controller.isPresented)
  #expect(!window.isVisible)
  #expect(controller.session === session)
  controller.shutdown()
  controller.shutdown()
  #expect(controller.session == nil)
  #expect(controller.window == nil)
}

@MainActor
@Test func quickTerminalHotKeyReportsConflictAndReleasesRegistration() {
  let first = QuickTerminalHotKey()
  let second = QuickTerminalHotKey()
  defer {
    first.stop()
    second.stop()
  }
  let status = first.configure(shortcut: "controlOptionSpace")
  // 外部应用占用也必须明确报错；隔离注册成功时进一步验证本进程内冲突及释放。
  if status == noErr {
    #expect(second.configure(shortcut: "controlOptionSpace") != noErr)
    first.stop()
    #expect(second.configure(shortcut: "controlOptionSpace") == noErr)
    #expect(second.configure(shortcut: "none") == noErr)
    #expect(first.configure(shortcut: "controlOptionSpace") == noErr)
  }
  #expect(first.configure(shortcut: "invalid") == OSStatus(paramErr))
}

@MainActor
@Test func quickTerminalMenuCloseDoesNotCloseWorkspaceTab() async throws {
  let suite = "QuickTerminalMenuTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.general.closeWindowConfirmation = .never
  preferences.setCompatibilityValue(.number(0), forKey: "quickTerminal.animationDuration")
  preferences.setCompatibilityValue(.bool(false), forKey: "quickTerminal.autohide")
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tabID = model.selectedTab?.id
  let delegate = AsterAppDelegate(model: model, preferences: preferences)
  let oldWindowsMenu = NSApp.windowsMenu
  defer {
    _ = delegate.applicationShouldTerminate(NSApp)
    NSApp.windowsMenu = oldWindowsMenu
  }
  let menu = delegate.makeMainMenu()
  let items = menu.items.flatMap { $0.submenu?.items ?? [] }
  let toggle = try #require(items.first { $0.title == "Quick Terminal" })
  #expect(NSApp.sendAction(try #require(toggle.action), to: toggle.target, from: toggle))
  let panel = try #require(NSApp.keyWindow)
  #expect(panel.title == "Aster Quick Terminal")
  let close = try #require(
    items.first {
      $0.keyEquivalent == "w" && $0.keyEquivalentModifierMask == [.command]
    })
  #expect(NSApp.sendAction(try #require(close.action), to: close.target, from: close))
  try await Task.sleep(for: .milliseconds(50))
  #expect(!panel.isVisible)
  #expect(model.selectedTab?.id == tabID)
}
