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
