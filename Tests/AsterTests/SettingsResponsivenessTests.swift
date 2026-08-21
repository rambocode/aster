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
  // 根视图不再是 WebView 本身：fullSizeContentView 下要在它上面压一条透明拖拽条，
  // 否则标题栏区域的 mouseDown 会被 WebKit 吃掉，窗口拖不动。
  #expect(webView.superview === controller.view)
  #expect(controller.view.subviews.contains {
    $0.identifier == SettingsViewController.titlebarDragStripIdentifier
  })
  #expect(controller.view.subviews.last is SettingsTitlebarDragStrip)
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

@Test("智能体快照下发 Otty 风格图标、CLI 绝对路径与独立集成状态")
@MainActor
func settingsAgentSnapshotContainsDetectionEvidence() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "AsterSettingsAgentSnapshot-\(UUID().uuidString)",
    isDirectory: true
  )
  defer { try? FileManager.default.removeItem(at: root) }
  let home = root.appendingPathComponent("home", isDirectory: true)
  let bin = root.appendingPathComponent("bin", isDirectory: true)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
  let codexPath = bin.appendingPathComponent(AgentProvider.codex.commandName)
  try "#!/bin/sh\nexit 0\n".write(to: codexPath, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes(
    [.posixPermissions: NSNumber(value: 0o755)],
    ofItemAtPath: codexPath.path
  )
  let controller = SettingsViewController(
    preferences: AppPreferences(defaults: isolatedSettingsDefaults()),
    agentSetupService: AgentSetupService(
      homeDirectory: home,
      executableSearchDirectories: [bin]
    )
  )
  controller.loadViewIfNeeded()

  let snapshot = controller.settingsSnapshotForTesting()
  let agents = try #require(snapshot["agents"] as? [[String: Any]])
  let codex = try #require(agents.first { $0["id"] as? String == AgentProvider.codex.rawValue })
  let cursor = try #require(agents.first { $0["id"] as? String == AgentProvider.cursorCLI.rawValue })
  let omp = try #require(agents.first { $0["id"] as? String == AgentProvider.omp.rawValue })
  #expect(codex["executablePath"] as? String == codexPath.path)
  #expect(codex["icon"] as? String == "codex")
  #expect(codex["integrated"] as? Bool == false)
  #expect(cursor["name"] as? String == "Cursor CLI")
  #expect(omp["name"] as? String == "omp")
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
  preferences.appearance = .light
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
  #expect(preferences.activeTheme.id == darkTheme.id)
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

@Test("Shell 页派生键：恢复进程三档与 TERM 下拉往返")
@MainActor
func settingsBridgeHandlesShellDerivedKeys() throws {
  let defaults = isolatedSettingsDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let controller = SettingsViewController(preferences: preferences)
  controller.loadViewIfNeeded()

  // 恢复进程：三档下拉映射 restoreProcesses 布尔 + scope 兼容字段。
  try controller.applySettingForTesting(key: "shell.restoreProcessesMode", value: "all")
  #expect(preferences.configuration.shell.restoreProcesses)
  #expect(preferences.settingsCompatibility["shell.restoreProcessesScope"]?.jsonValue as? String == "all")
  try controller.applySettingForTesting(key: "shell.restoreProcessesMode", value: "whitelist")
  #expect(preferences.settingsCompatibility["shell.restoreProcessesScope"]?.jsonValue as? String == "whitelist")
  try controller.applySettingForTesting(key: "shell.restoreProcessesMode", value: "none")
  #expect(!preferences.configuration.shell.restoreProcesses)
  #expect(throws: (any Error).self) {
    try controller.applySettingForTesting(key: "shell.restoreProcessesMode", value: "sometimes")
  }

  // TERM：预置项直接写身份名；从预置项切“自定义”清空占位（空值按 auto 解析）；
  // 已是自定义值时切“自定义”保持不变。
  try controller.applySettingForTesting(key: "appearance.terminalIdentityMode", value: "xterm-ghostty")
  #expect(preferences.configuration.appearance.terminalIdentity == "xterm-ghostty")
  try controller.applySettingForTesting(key: "appearance.terminalIdentityMode", value: "custom")
  #expect(preferences.configuration.appearance.terminalIdentity.isEmpty)
  try controller.applySettingForTesting(key: "appearance.terminalIdentity", value: "wezterm")
  try controller.applySettingForTesting(key: "appearance.terminalIdentityMode", value: "custom")
  #expect(preferences.configuration.appearance.terminalIdentity == "wezterm")
  try controller.applySettingForTesting(key: "appearance.terminalIdentityMode", value: "auto")
  #expect(preferences.configuration.appearance.terminalIdentity == "auto")
  #expect(throws: (any Error).self) {
    try controller.applySettingForTesting(key: "appearance.terminalIdentityMode", value: "vt100")
  }
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

// MARK: - 软件更新

/// 替身更新器，让「更新」四行的全部接线在不联网、不打包成 .app 的前提下可测。
@MainActor
private final class StubSoftwareUpdateController: SoftwareUpdateControlling {
  var automaticallyChecksForUpdates = false
  var automaticallyDownloadsUpdates = false
  var canCheckForUpdates = true
  var status: SoftwareUpdateStatus = .idle
  var lastCheckDate: Date?
  private(set) var checkCount = 0
  private(set) var channelChanges: [UpdateChannel] = []
  private(set) var startCount = 0

  func start() { startCount += 1 }

  func checkForUpdates() {
    checkCount += 1
    status = .checking
  }

  func channelDidChange(to channel: UpdateChannel) {
    channelChanges.append(channel)
  }
}

/// 锁死真值归属：两个自动开关只进 Sparkle，通道只进 AppPreferences 的独立键。
/// 任何一天有人把它们「顺手」搬进 AsterConfiguration 或兼容字段，这条会红。
@Test("更新开关写进 Sparkle 控制面，通道写进偏好并跨启动保留")
@MainActor
func settingsBridgeRoutesUpdateSettingsToUpdaterAndPreferences() throws {
  let defaults = isolatedSettingsDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let stub = StubSoftwareUpdateController()
  let controller = SettingsViewController(preferences: preferences, updateController: stub)
  controller.loadViewIfNeeded()

  try controller.applySettingForTesting(key: "update.automaticallyChecks", value: true)
  try controller.applySettingForTesting(key: "update.automaticallyDownloads", value: true)
  #expect(stub.automaticallyChecksForUpdates)
  #expect(stub.automaticallyDownloadsUpdates)
  // 不进强类型配置，也不进 Otty 兼容字段。
  #expect(preferences.configuration == AsterConfiguration.default)
  #expect(preferences.settingsCompatibility["update.automaticallyChecks"] == nil)
  #expect(preferences.settingsCompatibility["update.automaticallyDownloads"] == nil)
  #expect(preferences.settingsCompatibility["update.channel"] == nil)

  try controller.applySettingForTesting(key: "update.channel", value: "preview")
  #expect(preferences.updateChannel == .preview)
  #expect(stub.channelChanges == [.preview])
  #expect(AppPreferences(defaults: defaults).updateChannel == .preview)
  #expect(AppPreferences.updateChannel(from: defaults) == .preview)

  #expect(throws: (any Error).self) {
    try controller.applySettingForTesting(key: "update.channel", value: "nightly")
  }
  #expect(throws: (any Error).self) {
    try controller.applySettingForTesting(key: "update.automaticallyChecks", value: "true")
  }
}

/// 状态点、取反派生键与 capability 都是网页渲染的输入，错了不会报错、只会静默失真。
@Test("更新快照下发状态点、派生禁用键与 capability")
@MainActor
func settingsSnapshotExposesUpdateStatusAndCapability() throws {
  let defaults = isolatedSettingsDefaults()
  let preferences = AppPreferences(defaults: defaults)
  let stub = StubSoftwareUpdateController()
  let controller = SettingsViewController(preferences: preferences, updateController: stub)
  controller.loadViewIfNeeded()

  stub.status = .available(version: "9.9.9")
  var snapshot = controller.settingsSnapshotForTesting()
  var values = try #require(snapshot["values"] as? [String: Any])
  #expect((values["update.statusText"] as? String)?.contains("9.9.9") == true)
  #expect(values["update.statusState"] as? String == "updateAvailable")
  #expect(values["update.channel"] as? String == "stable")
  // 自动检查关闭 → 派生禁用键为真，网页据此把「自动下载并安装」置灰。
  #expect(values["update.automaticChecksDisabled"] as? Bool == true)
  let capabilities = try #require(snapshot["capabilities"] as? [String: Bool])
  #expect(capabilities["softwareUpdate"] == true)

  stub.automaticallyChecksForUpdates = true
  snapshot = controller.settingsSnapshotForTesting()
  values = try #require(snapshot["values"] as? [String: Any])
  #expect(values["update.automaticallyChecks"] as? Bool == true)
  #expect(values["update.automaticChecksDisabled"] as? Bool == false)

  // 开发构建：没有 updater，整组置灰并说明原因。
  let bare = SettingsViewController(preferences: preferences, updateController: nil)
  bare.loadViewIfNeeded()
  let bareSnapshot = bare.settingsSnapshotForTesting()
  let bareCapabilities = try #require(bareSnapshot["capabilities"] as? [String: Bool])
  #expect(bareCapabilities["softwareUpdate"] == false)
  let bareValues = try #require(bareSnapshot["values"] as? [String: Any])
  #expect(bareValues["update.statusText"] as? String == SoftwareUpdateStatus.unavailable.statusText)
}

@Test("现在检查按钮走 action allowlist 且检查进行中不重入")
@MainActor
func settingsUpdateActionTriggersCheck() throws {
  let preferences = AppPreferences(defaults: isolatedSettingsDefaults())
  let stub = StubSoftwareUpdateController()
  let controller = SettingsViewController(preferences: preferences, updateController: stub)
  controller.loadViewIfNeeded()

  controller.applyThemeActionForTesting("checkForUpdates", payload: [:])
  #expect(stub.checkCount == 1)

  // Sparkle 在一次更新会话进行中时 canCheckForUpdates 为假；此时再点不应重复发起。
  stub.canCheckForUpdates = false
  controller.applyThemeActionForTesting("checkForUpdates", payload: [:])
  #expect(stub.checkCount == 1)
}

/// 网页清单与 Swift 桥是两份手写清单，只能靠文本断言保持一致。
@Test("更新分区的清单键与 Swift 桥一一对应且排在关于之前")
func settingsUpdateSectionMatchesBridge() throws {
  let script = try String(
    contentsOf: URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/settings-ui/settings.js"),
    encoding: .utf8)

  #expect(script.contains("{ title: \"更新\", rows: ["))
  #expect(script.contains("action(\"checkForUpdates\""))
  #expect(script.contains("update.automaticallyChecks"))
  #expect(script.contains("update.automaticallyDownloads"))
  #expect(script.contains("update.channel"))
  #expect(script.contains("options.updateChannel"))
  #expect(script.contains("statusKey: \"update.statusText\""))
  #expect(script.contains("statusStateKey: \"update.statusState\""))
  #expect(script.contains("disabledWhen: \"update.automaticChecksDisabled\""))
  #expect(script.contains("capability: \"softwareUpdate\""))

  let updateGroup = try #require(script.range(of: "{ title: \"更新\", rows: ["))
  let aboutGroup = try #require(script.range(of: "{ title: \"关于\", rows: ["))
  #expect(updateGroup.lowerBound < aboutGroup.lowerBound)

  // 状态键加了但颜色规则漏了的话，状态点会静默变成中性灰而不会报错。
  let style = try String(
    contentsOf: URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/settings-ui/settings.css"),
    encoding: .utf8)
  #expect(style.contains("[data-state=\"upToDate\"]"))
  #expect(style.contains("[data-state=\"updateAvailable\"]"))
  #expect(style.contains("[data-state=\"failed\"]"))
}
