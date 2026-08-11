import AppKit
import Testing

@testable import Aster
@testable import AsterCore

// 设置页的响应性回归锁：
// 1. 窗口高度可拉伸并跨次记忆（宽度仍锁死）；
// 2. 切换分类只换内容区，侧栏按钮与搜索框都是同一批实例；
// 3. 搜索只过滤侧栏导航，不重建内容区；
// 4. 普通控件（开关、步进器）改配置后不重建内容区，点击反馈不被布局工作打断。

extension NSView {
  /// 整棵子树（含自身之外的所有后代），用于在视图树里定位私有类型的控件。
  fileprivate var settingsDescendants: [NSView] {
    subviews.flatMap { [$0] + $0.settingsDescendants }
  }
}

@MainActor
private func isolatedSettingsDefaults() -> UserDefaults {
  let suite = "SettingsResponsiveness.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

@MainActor
private func settingsWindow(
  _ controller: SettingsViewController, size: NSSize = SettingsViewController.defaultContentSize
) -> NSWindow {
  let window = NSWindow(
    contentRect: NSRect(origin: .zero, size: size),
    styleMask: [.titled, .resizable],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.contentView?.layoutSubtreeIfNeeded()
  return window
}

/// 侧栏导航按钮：私有类型，按类名 + 无障碍标签识别。
@MainActor
private func sidebarButtons(in controller: SettingsViewController) -> [NSButton] {
  controller.view.settingsDescendants.compactMap { view in
    guard String(describing: type(of: view)).contains("SettingsSidebarButton") else { return nil }
    return view as? NSButton
  }
}

@MainActor
private func contentDocument(in controller: SettingsViewController) throws -> NSView {
  let scroll = try #require(
    controller.view.settingsDescendants.compactMap { $0 as? NSScrollView }.first)
  return try #require(scroll.documentView)
}

@Test("设置窗口高度可拉伸并跨次打开被记住")
@MainActor
func settingsWindowRemembersHeightAcrossOpens() throws {
  let defaults = isolatedSettingsDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let first = AsterSettingsWindowController(
    content: SettingsViewController(preferences: preferences),
    appearance: nil,
    defaults: defaults
  )
  let firstWindow = try #require(first.window)
  #expect(firstWindow.contentRect(forFrameRect: firstWindow.frame).height
    == CGFloat(SettingsWindowGeometry.defaultHeight))

  // 用户拉高窗口后由 delegate 记一次。
  firstWindow.setContentSize(NSSize(width: SettingsWindowGeometry.width, height: 720))
  #expect(firstWindow.contentRect(forFrameRect: firstWindow.frame).height == 720)
  first.persistContentHeight()
  #expect(defaults.object(forKey: SettingsWindowGeometry.heightDefaultsKey) as? Double == 720)

  let second = AsterSettingsWindowController(
    content: SettingsViewController(preferences: preferences),
    appearance: nil,
    defaults: defaults
  )
  let secondWindow = try #require(second.window)
  #expect(secondWindow.contentRect(forFrameRect: secondWindow.frame).height == 720)
  // 宽度始终锁死，记忆只作用于高度。
  #expect(secondWindow.contentRect(forFrameRect: secondWindow.frame).width
    == CGFloat(SettingsWindowGeometry.width))
  #expect(secondWindow.minSize.width == secondWindow.maxSize.width)
}

@Test("屏幕放不下的记忆高度不会让窗口超出可视区域")
@MainActor
func settingsWindowClampsRememberedHeightToScreen() throws {
  let defaults = isolatedSettingsDefaults()
  defaults.set(9_000.0, forKey: SettingsWindowGeometry.heightDefaultsKey)
  let preferences = AppPreferences(defaults: defaults)
  let controller = AsterSettingsWindowController(
    content: SettingsViewController(preferences: preferences),
    appearance: nil,
    defaults: defaults
  )
  let window = try #require(controller.window)
  // 无头会话拿不到屏幕时不做上界钳制，断言退化为「不会被莫名缩小」。
  let available = NSScreen.main?.visibleFrame.height ?? .greatestFiniteMagnitude
  #expect(window.contentRect(forFrameRect: window.frame).height <= available)
}

@Test("切换分类只重建内容区，侧栏按钮与搜索框保持同一批实例")
@MainActor
func switchingSectionKeepsSidebarInstances() throws {
  let defaults = isolatedSettingsDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = settingsWindow(controller)
  defer { window.orderOut(nil) }

  let buttonsBefore = sidebarButtons(in: controller)
  let searchBefore = try #require(
    controller.view.settingsDescendants.compactMap { $0 as? NSSearchField }.first)
  let documentBefore = try contentDocument(in: controller)
  #expect(buttonsBefore.count == 9)

  // 走与用户点击完全相同的路径。
  let appearanceButton = try #require(
    buttonsBefore.first { $0.accessibilityLabel() == SettingsViewController.Section.appearance.rawValue })
  appearanceButton.performClick(nil)
  window.contentView?.layoutSubtreeIfNeeded()

  let buttonsAfter = sidebarButtons(in: controller)
  let searchAfter = try #require(
    controller.view.settingsDescendants.compactMap { $0 as? NSSearchField }.first)
  #expect(buttonsAfter.map(ObjectIdentifier.init) == buttonsBefore.map(ObjectIdentifier.init))
  #expect(searchAfter === searchBefore)
  // 内容区确实换了：文档视图是新的，且渲染的是外观页。
  #expect(try contentDocument(in: controller) !== documentBefore)
  let titles = controller.view.settingsDescendants.compactMap { ($0 as? NSTextField)?.stringValue }
  #expect(titles.contains("主题"))
}

@Test("侧栏搜索只过滤导航，不重建内容区")
@MainActor
func sidebarSearchDoesNotRebuildContent() throws {
  let defaults = isolatedSettingsDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = settingsWindow(controller)
  defer { window.orderOut(nil) }

  let documentBefore = try contentDocument(in: controller)
  let search = try #require(controller.view.settingsDescendants.compactMap { $0 as? NSSearchField }.first)
  search.stringValue = "外观"
  controller.controlTextDidChange(
    Notification(name: NSControl.textDidChangeNotification, object: search))
  window.contentView?.layoutSubtreeIfNeeded()

  #expect(sidebarButtons(in: controller).count == 1)
  #expect(try contentDocument(in: controller) === documentBefore)

  // 清空搜索恢复九个分类，内容区仍然没有被重建过。
  search.stringValue = ""
  controller.controlTextDidChange(
    Notification(name: NSControl.textDidChangeNotification, object: search))
  #expect(sidebarButtons(in: controller).count == 9)
  #expect(try contentDocument(in: controller) === documentBefore)
}

@Test("明暗切换后常驻侧栏底色跟随外观")
@MainActor
func skeletonChromeFollowsAppearance() throws {
  let defaults = isolatedSettingsDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = settingsWindow(controller)
  defer { window.orderOut(nil) }

  // 侧栏宿主：导航按钮 → 垂直栈 → 宿主。底色写在 layer 上，不会自己跟随外观。
  let shellButton = try #require(
    sidebarButtons(in: controller)
      .first { $0.accessibilityLabel() == SettingsViewController.Section.shell.rawValue })
  let host = try #require(shellButton.superview?.superview)

  preferences.appearance = .light
  controller.showSection(.shell)
  let lightCanvas = try #require(host.layer?.backgroundColor)
  let lightSelection = try #require(shellButton.layer?.backgroundColor)

  preferences.appearance = .dark
  controller.showSection(.shell)

  // 按钮实例没有被重建，但底色必须已经换成深色那套。
  #expect(sidebarButtons(in: controller).contains { $0 === shellButton })
  #expect(host.layer?.backgroundColor != lightCanvas)
  #expect(shellButton.layer?.backgroundColor != lightSelection)
}

@Test("开关与步进器改配置后不重建内容区")
@MainActor
func plainControlsDoNotRebuildContent() throws {
  let defaults = isolatedSettingsDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  let window = settingsWindow(controller)
  defer { window.orderOut(nil) }

  let documentBefore = try contentDocument(in: controller)
  let toggle = try #require(controller.view.settingsDescendants.compactMap { $0 as? NSSwitch }.first)
  let before = preferences.configuration.general.quitAfterLastWindowClosed
  toggle.performClick(nil)
  window.contentView?.layoutSubtreeIfNeeded()

  // 配置确实写进去了，但视图树没有被推倒重来。
  #expect(preferences.configuration.general.quitAfterLastWindowClosed != before)
  #expect(try contentDocument(in: controller) === documentBefore)
  #expect(controller.view.settingsDescendants.contains { $0 === toggle })

  // 字号步进器同理：数值由控件自己就地更新。
  controller.showSection(.appearance)
  window.contentView?.layoutSubtreeIfNeeded()
  let appearanceDocument = try contentDocument(in: controller)
  let stepper = try #require(controller.view.settingsDescendants.compactMap { $0 as? NSStepper }.first)
  let fontSizeBefore = preferences.fontSize
  stepper.doubleValue = fontSizeBefore + 1
  if let action = stepper.action { stepper.sendAction(action, to: stepper.target) }
  window.contentView?.layoutSubtreeIfNeeded()

  #expect(preferences.fontSize == fontSizeBefore + 1)
  #expect(try contentDocument(in: controller) === appearanceDocument)
}
