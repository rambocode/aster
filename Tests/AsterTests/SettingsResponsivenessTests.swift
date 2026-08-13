import AppKit
import Testing
import WebKit

@testable import Aster
@testable import AsterCore

// 网页设置页的回归锁聚焦边界而不是 DOM 实现细节：窗口几何、单一 WebKit 宿主、
// Swift 快照完整性、强类型字段写入和 Otty 扩展字段持久化。

@MainActor
private func isolatedSettingsDefaults() -> UserDefaults {
  let suite = "SettingsWebView.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

@Test("设置窗口宽高可拉伸并跨次打开被记住")
@MainActor
func settingsWindowRemembersSizeAcrossOpens() throws {
  let defaults = isolatedSettingsDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let first = AsterSettingsWindowController(
    content: SettingsViewController(preferences: preferences),
    appearance: nil,
    defaults: defaults
  )
  let firstWindow = try #require(first.window)
  #expect(firstWindow.contentRect(forFrameRect: firstWindow.frame).size == SettingsViewController.defaultContentSize)

  firstWindow.setContentSize(NSSize(width: 940, height: 720))
  first.persistContentSize()

  let second = AsterSettingsWindowController(
    content: SettingsViewController(preferences: preferences),
    appearance: nil,
    defaults: defaults
  )
  let secondWindow = try #require(second.window)
  #expect(secondWindow.contentRect(forFrameRect: secondWindow.frame).size == NSSize(width: 940, height: 720))
  #expect(secondWindow.styleMask.contains(.resizable))
}

@Test("屏幕放不下的记忆高度不会让窗口超出可视区域")
@MainActor
func settingsWindowClampsRememberedHeightToScreen() throws {
  let defaults = isolatedSettingsDefaults()
  defaults.set(9_000.0, forKey: SettingsWindowGeometry.heightDefaultsKey)
  let controller = AsterSettingsWindowController(
    content: SettingsViewController(preferences: AppPreferences(defaults: defaults)),
    appearance: nil,
    defaults: defaults
  )
  let window = try #require(controller.window)
  let available = NSScreen.main?.visibleFrame.height ?? .greatestFiniteMagnitude
  #expect(window.contentRect(forFrameRect: window.frame).height <= available)
}

@Test("设置页使用单一非持久化 WKWebView 宿主")
@MainActor
func settingsUsesOneEphemeralWebView() throws {
  let defaults = isolatedSettingsDefaults()
  let controller = SettingsViewController(preferences: AppPreferences(defaults: defaults))
  controller.loadViewIfNeeded()

  let webView = try #require(controller.settingsWebViewForTesting)
  #expect(controller.view === webView)
  #expect(!webView.configuration.websiteDataStore.isPersistent)
  #expect(webView.identifier?.rawValue == "settings-web-view")
  #expect(controller.sections.count == 9)
}

@MainActor
private func evaluateString(_ script: String, in webView: WKWebView) async throws -> String {
  try await withCheckedThrowingContinuation { continuation in
    webView.evaluateJavaScript(script) { result, error in
      if let error { continuation.resume(throwing: error) }
      else { continuation.resume(returning: result as? String ?? "") }
    }
  }
}

@Test("本地设置文档通过 CSP 加载并渲染九类导航")
@MainActor
func settingsDocumentLoadsAndRendersNavigation() async throws {
  let defaults = isolatedSettingsDefaults()
  let controller = SettingsViewController(preferences: AppPreferences(defaults: defaults))
  controller.loadViewIfNeeded()
  let webView = try #require(controller.settingsWebViewForTesting)

  var count = 0
  for _ in 0..<100 {
    if let value = Int(try await evaluateString(
      "String(document.querySelectorAll('.nav-item').length)",
      in: webView
    )) {
      count = value
      if count == 9 { break }
    }
    try await Task.sleep(for: .milliseconds(20))
  }

  #expect(count == 9)
  #expect(try await evaluateString("document.querySelector('.page-title')?.textContent ?? ''", in: webView) == "通用")
  #expect(Int(try await evaluateString("String(document.querySelectorAll('.setting-row').length)", in: webView)) ?? 0 > 10)

  _ = try await evaluateString(
    "document.querySelector('[data-section=\"appearance\"]')?.click(); 'ok'",
    in: webView
  )
  for _ in 0..<50 {
    if try await evaluateString("document.querySelector('.page-title')?.textContent ?? ''", in: webView) == "外观" {
      break
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(Int(try await evaluateString("String(document.querySelectorAll('.layout-choice').length)", in: webView)) == 3)
  #expect(Int(try await evaluateString("String(document.querySelectorAll('.theme-token-pill').length)", in: webView)) ?? 0 >= 8)
  #expect(Int(try await evaluateString("String(document.querySelectorAll('.font-scope-tabs button').length)", in: webView)) == 4)
  #expect(try await evaluateString("String(Boolean(document.querySelector('.cursor-preview')))", in: webView) == "true")
  #expect(try await evaluateString("String(Boolean(document.querySelector('.dock-icon-preview')))", in: webView) == "true")
  // range 必须先写 min/max 再写 value；否则浏览器会按默认 0...100 截断 220pt 和 1.0 等真值。
  #expect(try await evaluateString(
    "document.querySelector('[data-setting-key=\"appearance.sidebarWidth\"] input')?.value ?? ''",
    in: webView
  ) == "220")
  #expect(try await evaluateString(
    "document.querySelector('[data-setting-key=\"appearance.cursorOpacity\"] input')?.value ?? ''",
    in: webView
  ) == "1")
}

@Test("设置网页资源包含严格 CSP 和九个分类清单")
func settingsWebAssetsAreBundledAndSelfContained() throws {
  let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/settings-ui", isDirectory: true)
  let html = try String(contentsOf: directory.appendingPathComponent("index.html"), encoding: .utf8)
  let script = try String(contentsOf: directory.appendingPathComponent("settings.js"), encoding: .utf8)
  let style = try String(contentsOf: directory.appendingPathComponent("settings.css"), encoding: .utf8)

  #expect(html.contains("default-src 'none'"))
  #expect(html.contains("connect-src 'none'"))
  #expect(!html.contains("http://") && !html.contains("https://"))
  for section in ["general", "shell", "controls", "editor", "agents", "appearance", "recipes", "shortcuts", "advanced"] {
    #expect(script.contains("id: \"\(section)\""))
  }
  let controlGroupTitles = ["自动补全", "选择", "滚动", "打开方式", "链接协议", "键盘", "鼠标", "安全输入", "剪贴板"]
  var previousGroupOffset = script.startIndex
  for title in controlGroupTitles {
    let offset = try #require(script.range(of: "{ title: \"\(title)\"", range: previousGroupOffset..<script.endIndex))
    previousGroupOffset = offset.upperBound
  }
  #expect(style.contains("grid-template-columns: 200px minmax(0, 1fr)"))
  #expect(script.contains("window.webkit?.messageHandlers?.asterSettings"))
  #expect(script.contains("[\"light\", \"明亮主题\"]"))
  #expect(script.contains("[\"dark\", \"黑暗主题\"]"))
  #expect(script.contains("filter(item => item.mode === mode)"))
}

@Test("网页桥快照覆盖九类真实设置并标记 Windows 限制")
@MainActor
func settingsSnapshotContainsRuntimeValuesAndCapabilities() throws {
  let defaults = isolatedSettingsDefaults()
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.editor.tabSize = 6
  let controller = SettingsViewController(preferences: preferences)
  controller.loadViewIfNeeded()

  let snapshot = controller.settingsSnapshotForTesting()
  let values = try #require(snapshot["values"] as? [String: Any])
  let capabilities = try #require(snapshot["capabilities"] as? [String: Bool])
  let themes = try #require(snapshot["themes"] as? [[String: Any]])
  let agents = try #require(snapshot["agents"] as? [[String: Any]])
  let themeEditor = try #require(snapshot["themeEditor"] as? [String: Any])
  let computedFonts = try #require(snapshot["computedFonts"] as? [String: String])

  #expect(values["editor.tabSize"] as? Int == 6)
  #expect(values["general.closeTabConfirmation"] as? String == "runningProcess")
  #expect(values["advanced.scrollbackLines"] as? Double == 10_000)
  #expect(capabilities["windowsTextRendering"] == false)
  #expect(themes.count == 24)
  #expect(themes.filter { $0["mode"] as? String == "light" }.count == 9)
  #expect(themes.filter { $0["mode"] as? String == "dark" }.count == 15)
  #expect(agents.count == AgentProvider.allCases.count)
  #expect((themeEditor["ansi"] as? [String])?.count == 16)
  #expect(computedFonts.values.allSatisfy { !$0.isEmpty })
}

@Test("网页主题编辑把黑暗主题参数追加到原配置而不创建副本")
@MainActor
func settingsThemeActionsUseOverridesForDarkTheme() throws {
  let defaults = isolatedSettingsDefaults()
  let themesDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("AsterThemeOverrides-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: themesDirectory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: themesDirectory) }

  let preferences = AppPreferences(
    defaults: defaults,
    ottyThemesDirectoryURL: themesDirectory
  )
  preferences.configuration.appearance.useSeparateDarkTheme = false
  let darkTheme = try #require(TerminalThemeCatalog.theme(named: "Ayu Dark"))
  let themeFile = themesDirectory
    .appendingPathComponent(darkTheme.id)
    .appendingPathExtension("ottytheme")
  try "[meta]\nname = \"Ayu Dark\"\n".write(to: themeFile, atomically: true, encoding: .utf8)

  let controller = SettingsViewController(preferences: preferences)
  controller.loadViewIfNeeded()
  controller.applyThemeActionForTesting("selectTheme", payload: ["id": darkTheme.id])
  controller.applyThemeActionForTesting(
    "setThemeANSIColor",
    payload: ["themeID": darkTheme.id, "index": 3, "color": "#123456"]
  )
  controller.applyThemeActionForTesting(
    "setThemeFont",
    payload: ["themeID": darkTheme.id, "role": "regular", "value": "Menlo"]
  )

  let overrides = preferences.themeOverrides(for: darkTheme.id)
  #expect(preferences.configuration.appearance.darkThemeName == "Ayu Dark")
  #expect(preferences.configuration.appearance.useSeparateDarkTheme)
  #expect(preferences.themeLibrary.customThemes.isEmpty)
  #expect(overrides.ansiColors[3] == HexColor("#123456"))
  #expect(overrides.fontFamilies(for: .regular)?.first == "Menlo")
  #expect(preferences.darkTheme.id == darkTheme.id)
  #expect(preferences.darkTheme.palette.ansiColors[3] == HexColor("#123456"))
  #expect(preferences.darkTheme.style.fontFamilies?.first == "Menlo")

  let reloaded = AppPreferences(
    defaults: defaults,
    ottyThemesDirectoryURL: themesDirectory
  )
  #expect(reloaded.darkTheme.id == darkTheme.id)
  #expect(reloaded.darkTheme.palette.ansiColors[3] == HexColor("#123456"))
  #expect(reloaded.darkTheme.style.fontFamilies?.first == "Menlo")

  let persisted = try String(contentsOf: themeFile, encoding: .utf8)
  #expect(persisted.contains(ThemeOverrideFileWriter.marker))
  #expect(persisted.contains("# otty-added: terminal.palette"))
  #expect(persisted.contains("# otty-added: token.font-mono"))
}

@Test("网页桥写入强类型字段并持久化扩展字段")
@MainActor
func settingsBridgeWritesTypedAndCompatibilityValues() throws {
  let defaults = isolatedSettingsDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  controller.loadViewIfNeeded()

  try controller.applySettingForTesting(key: "editor.tabSize", value: 7)
  try controller.applySettingForTesting(key: "controls.clipboardReadAccess", value: "deny")
  try controller.applySettingForTesting(key: "controls.optionAsMetaMode", value: "left")
  try controller.applySettingForTesting(key: "controls.rightClickAction", value: "copy-or-paste")
  try controller.applySettingForTesting(key: "controls.bypassMouseReporting", value: "ctrl+shift")
  try controller.applySettingForTesting(key: "controls.selectionBackspaceDeletes", value: false)
  try controller.applySettingForTesting(key: "advanced.scrollbackLines", value: 240_000)
  try controller.applySettingForTesting(key: "appearance.windowsTextRendering", value: "clearType")
  try controller.applySettingForTesting(key: "appearance.fontFamilyFallbackBold", value: "Menlo, Monaco")

  #expect(preferences.configuration.editor.tabSize == 7)
  #expect(preferences.configuration.controls.resolvedClipboardReadAccess == .deny)
  #expect(preferences.configuration.controls.resolvedOptionAsMetaMode == .left)
  #expect(preferences.configuration.controls.resolvedRightClickAction == .copyOrPaste)
  #expect(preferences.configuration.controls.resolvedBypassMouseReporting == .controlShift)
  #expect(!preferences.configuration.controls.resolvedSelectionBackspaceDeletes)
  #expect(preferences.configuration.appearance.resolvedFontFamilyFallbackBold == ["Menlo", "Monaco"])
  let reloaded = AppPreferences(defaults: defaults)
  #expect(reloaded.settingsCompatibility["advanced.scrollbackLines"]?.jsonValue as? Double == 240_000)
  #expect(reloaded.settingsCompatibility["appearance.windowsTextRendering"]?.jsonValue as? String == "clearType")
}

@Test("网页桥覆盖通知、链接、宽字符、Agent 与菜单快捷键")
@MainActor
func settingsBridgeCoversCompositeAndDynamicSettings() throws {
  let defaults = isolatedSettingsDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  controller.loadViewIfNeeded()

  try controller.applySettingForTesting(key: "shell.notificationSound.commandFinish", value: true)
  try controller.applySettingForTesting(key: "controls.linkDetectionEnabled", value: false)
  try controller.applySettingForTesting(key: "advanced.widened.arrows", value: true)
  try controller.applySettingForTesting(key: "agents.enabled.openCode", value: true)
  try controller.applySettingForTesting(key: "agents.launchCommand.openCode", value: "opencode --continue")
  try controller.applySettingForTesting(key: "shortcuts.new-window", value: "⌥⇧N")
  #expect(throws: (any Error).self) {
    try controller.applySettingForTesting(key: "advanced.scrollbackLines", value: -1)
  }
  #expect(throws: (any Error).self) {
    try controller.applySettingForTesting(key: "controls.mouseHideWhileTyping", value: "true")
  }

  #expect(preferences.configuration.shell.resolvedNotificationSoundCategories.contains(.commandFinish))
  #expect(!preferences.configuration.controls.resolvedLinkDetectionEnabled)
  #expect(preferences.configuration.appearance.resolvedWidenedEastAsianAmbiguousBlocks.contains(.arrows))
  #expect(preferences.configuration.agents.enabledAgents.contains(AgentProvider.openCode.commandName))
  #expect(preferences.configuration.agents.launchComponents(for: .openCode) == ["opencode", "--continue"])

  let menu = NSMenu(title: "测试")
  let item = NSMenuItem(title: "新建窗口", action: nil, keyEquivalent: "n")
  menu.addItem(item)
  ShortcutOverrideApplier.apply(to: menu, values: preferences.settingsCompatibility)
  #expect(item.keyEquivalent == "n")
  #expect(item.keyEquivalentModifierMask == [.option, .shift])
}

@Test("网页桥将 Panel 宽度写回最近活动工作区")
@MainActor
func settingsBridgeUpdatesBoundPanelWidths() throws {
  let defaults = isolatedSettingsDefaults()
  let store = WorkspacePanelLayoutStore(defaults: defaults, legacySidebarWidth: 230)
  let binding = WorkspacePanelSettingsBinding()
  binding.bind(store)
  let controller = SettingsViewController(
    preferences: AppPreferences(defaults: defaults),
    panelLayoutBinding: binding
  )
  controller.loadViewIfNeeded()

  try controller.applySettingForTesting(key: "appearance.sidebarWidth", value: 310)
  try controller.applySettingForTesting(key: "appearance.inspectorWidth", value: 420)

  #expect(store.state.sidebarWidth == 310)
  #expect(store.state.inspectorWidth == 420)
}
