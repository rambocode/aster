// 顶条缩放入口、真实工作区布局和快捷键设置的行为回归。
import AppKit
import Testing

@testable import Aster
@testable import AsterCore

@MainActor
private func zoomViews<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
  ((root as? T).map { [$0] } ?? [])
    + root.subviews.flatMap { zoomViews(type, in: $0) }
}

@MainActor
private func captureZoomWindow(_ window: NSWindow, name: String) async throws {
  guard let directory = ProcessInfo.processInfo.environment["ASTER_PANE_ZOOM_EVIDENCE_DIR"] else {
    return
  }
  try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
  window.makeKeyAndOrderFront(nil)
  window.contentView?.layoutSubtreeIfNeeded()
  try await Task.sleep(for: .milliseconds(250))
  for host in zoomViews(ActivePaneHostView.self, in: window.contentView ?? NSView()) {
    host.updateChromeReveal(pointerInView: NSPoint(x: host.bounds.maxX - 28, y: host.bounds.maxY - 7))
  }
  try await Task.sleep(for: .milliseconds(180))
  // 只捕获隔离测试窗口，保留 Metal 终端和原生控件的实际呈现。
  let capture = Process()
  capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
  let appearance = window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    ? "dark" : "light"
  capture.arguments = ["-x", "-o", "-l", String(window.windowNumber),
    URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(appearance).png").path]
  try capture.run()
  capture.waitUntilExit()
  #expect(capture.terminationStatus == 0)
}

@Test("顶条放大点击所属 Pane，填满右侧内容区；再次点击恢复拆分比例和运行态",
  arguments: [NSAppearance.Name.aqua, .darkAqua])
@MainActor
func paneZoomButtonExpandsItsPaneAndRestoresLayout(appearance: NSAppearance.Name) async throws {
  let suite = "PaneZoom.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  preferences.tabBarLayout = .vertical
  preferences.appearance = appearance == .darkAqua ? .dark : .light
  preferences.configuration.appearance.useSeparateDarkTheme = true
  preferences.setCompatibilityValue(.string("/bin/sh"), forKey: "general.shell")
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let firstID = tab.activePaneID
  model.splitSelectedTab(.right)
  model.splitSelectedTab(.down)
  tab.updateSplitRatio(at: [], ratio: 0.37)
  let originalLayout = tab.layout
  let originalRuntimes = tab.runtimes
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered, defer: false)
  window.contentViewController = controller
  window.appearance = NSAppearance(named: appearance)
  defer {
    for runtime in tab.runtimes.values { runtime.terminalSession?.stop(immediately: true) }
    window.orderOut(nil)
  }
  try await Task.sleep(for: .milliseconds(180))
  window.contentView?.layoutSubtreeIfNeeded()
  let session = try #require(tab.runtime(for: firstID)?.terminalSession)
  let surface = try #require(session.pictureInPictureSurface)
  session.send("printf 'Pane layout regression: %s%s\\n' PANE_ZOOM_ READY")
  for _ in 0..<150 where surface.readText(includeScrollback: false)?.contains("PANE_ZOOM_READY") != true {
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(surface.readText(includeScrollback: false)?.contains("PANE_ZOOM_READY") == true)
  let hosts = zoomViews(ActivePaneHostView.self, in: controller.view)
  #expect(hosts.count == 3)
  let target = try #require(hosts.first { $0.paneID == firstID })
  #expect(!target.isActivePane)
  let originalFrame = controller.view.convert(target.bounds, from: target)
  let contentFrames = hosts.map { controller.view.convert($0.bounds, from: $0) }
  let contentFrame = try #require(contentFrames.first).union(
    contentFrames.dropFirst().reduce(.null) { $0.union($1) })
  for host in hosts {
    let button = try #require(zoomViews(PaneZoomButton.self, in: host).first)
    #expect(button.hitTest(button.frame.origin) == nil)
    #expect(button.image != nil)
    #expect(button.toolTip == "\(L("缩放拆分"))  ⇧⌘↩")
    host.updateChromeReveal(pointerInView: NSPoint(x: host.bounds.maxX - 28, y: host.bounds.maxY - 7))
    #expect(button.isRevealed)
    #expect(button.hitTest(NSPoint(x: button.frame.midX, y: button.frame.midY)) === button)
    let close = try #require(zoomViews(PaneCloseButton.self, in: host).first)
    #expect(button.frame.maxX < close.frame.minX)
    host.updateChromeReveal(pointerInView: nil)
    #expect(!button.isRevealed)
  }
  // 设置仍打开时也更新提示；普通快捷键变更不重建 Pane host。
  controller.setSettingsPresentationActive(true)
  let settings = SettingsViewController(preferences: preferences)
  try settings.applySettingForTesting(key: "shortcuts.zoom-pane", value: "⌃⌥Z")
  try await Task.sleep(for: .milliseconds(100))
  #expect(zoomViews(ActivePaneHostView.self, in: controller.view).contains { $0 === target })
  #expect(zoomViews(PaneZoomButton.self, in: target).first?.toolTip == "\(L("缩放拆分"))  ⌃⌥Z")
  target.updateChromeReveal(pointerInView: NSPoint(x: target.bounds.maxX - 28, y: target.bounds.maxY - 7))
  try await captureZoomWindow(window, name: "split")
  let zoom = try #require(zoomViews(PaneZoomButton.self, in: target).first)
  zoom.performClick(nil)
  try await Task.sleep(for: .milliseconds(180))
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(tab.activePaneID == firstID)
  #expect(tab.zoomedPaneID == firstID)
  let zoomedHosts = zoomViews(ActivePaneHostView.self, in: controller.view)
  #expect(zoomedHosts.count == 1)
  let zoomedHost = try #require(zoomedHosts.first)
  let zoomedFrame = controller.view.convert(zoomedHost.bounds, from: zoomedHost)
  #expect(abs(zoomedFrame.minX - contentFrame.minX) < 1)
  #expect(abs(zoomedFrame.minY - contentFrame.minY) < 1)
  #expect(abs(zoomedFrame.width - contentFrame.width) < 1)
  #expect(abs(zoomedFrame.height - contentFrame.height) < 1)
  let restore = try #require(zoomViews(PaneZoomButton.self, in: zoomedHost).first)
  #expect(restore.image != nil)
  zoomedHost.updateChromeReveal(pointerInView: NSPoint(x: zoomedHost.bounds.maxX - 28, y: zoomedHost.bounds.maxY - 7))
  try await captureZoomWindow(window, name: "zoomed")
  restore.performClick(nil)
  try await Task.sleep(for: .milliseconds(180))
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(tab.zoomedPaneID == nil)
  #expect(tab.layout == originalLayout)
  #expect(tab.runtimes.keys == originalRuntimes.keys)
  for (id, runtime) in originalRuntimes { #expect(tab.runtimes[id] === runtime) }
  #expect(session.pictureInPictureSurface === surface)
  #expect(surface.readText(includeScrollback: true)?.contains("PANE_ZOOM_READY") == true)
  let restoredHosts = zoomViews(ActivePaneHostView.self, in: controller.view)
  #expect(restoredHosts.count == 3)
  let restored = try #require(restoredHosts.first { $0.paneID == firstID })
  let restoredFrame = controller.view.convert(restored.bounds, from: restored)
  #expect(abs(restoredFrame.width - originalFrame.width) < 1)
  #expect(abs(restoredFrame.height - originalFrame.height) < 1)
  try await captureZoomWindow(window, name: "restored")
  // 窄窗口仍能放大；退出后关闭其它 Pane，单 Pane 不再显示缩放入口。
  window.setContentSize(NSSize(width: 720, height: 480))
  window.contentView?.layoutSubtreeIfNeeded()
  let narrowZoom = try #require(zoomViews(PaneZoomButton.self, in: restored).first)
  narrowZoom.performClick(nil)
  try await Task.sleep(for: .milliseconds(180))
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(zoomViews(ActivePaneHostView.self, in: controller.view).count == 1)
  try await captureZoomWindow(window, name: "narrow-zoomed")
  tab.toggleZoom()
  while tab.layout.allPanes.count > 1 {
    guard tab.closeActivePane() else {
      Issue.record("测试 Pane 未能关闭")
      break
    }
  }
  try await Task.sleep(for: .milliseconds(180))
  #expect(zoomViews(PaneZoomButton.self, in: controller.view).isEmpty)
}

@Test("缩放拆分快捷键在设置中可修改、持久化并应用到菜单")
@MainActor
func paneZoomShortcutPersistsAndUpdatesMenu() throws {
  let suite = "PaneZoomShortcut.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let preferences = AppPreferences(defaults: defaults)
  let settings = SettingsViewController(preferences: preferences)
  let rows = try #require(settings.settingsSnapshotForTesting()["shortcuts"] as? [[String: Any]])
  let zoom = try #require(rows.first { $0["id"] as? String == "zoom-pane" })
  #expect(zoom["keys"] as? String == "⇧⌘↩")
  try settings.applySettingForTesting(key: "shortcuts.zoom-pane", value: "⌃⌥Z")
  #expect(throws: (any Error).self) {
    try settings.applySettingForTesting(key: "shortcuts.zoom-pane", value: "invalid")
  }
  let reloaded = AppPreferences(defaults: defaults)
  #expect(reloaded.settingsCompatibility["shortcuts.zoom-pane"]?.jsonValue as? String == "⌃⌥Z")
  let menu = NSMenu(title: "显示")
  let item = NSMenuItem(title: L("缩放拆分"), action: nil, keyEquivalent: "\r")
  item.keyEquivalentModifierMask = [.shift, .command]
  menu.addItem(item)
  ShortcutOverrideApplier.apply(to: menu, values: reloaded.settingsCompatibility)
  #expect(item.keyEquivalent == "z")
  #expect(item.keyEquivalentModifierMask == [.control, .option])
}
