import Foundation
import Testing

@testable import AsterCore

@Test("Agent 自定义启动命令按结构化 argv 规范化且非法值回退默认")
func agentCustomLaunchCommandsAreNormalized() throws {
  var configuration = AsterConfiguration()
  configuration.agents.customLaunchCommands = [
    AgentProvider.codex.rawValue: ["env", "PROFILE=work", "codex"],
    AgentProvider.claudeCode.rawValue: ["bad\ncommand"],
    "unknown": ["unknown"],
  ]

  let normalized = configuration.normalized()

  #expect(normalized.agents.launchComponents(for: .codex) == ["env", "PROFILE=work", "codex"])
  #expect(normalized.agents.launchComponents(for: .claudeCode) == ["claude"])
  #expect(normalized.agents.customLaunchCommands?.keys.sorted() == [AgentProvider.codex.rawValue])
}

@Test("默认配置与参考应用的主工作区一致")
func defaultConfigurationMatchesReferenceWorkspace() {
  let configuration = AsterConfiguration.default

  #expect(configuration.tabBarLayout == .vertical)
  #expect(configuration.launchBehavior == .restoreLastSession)
  #expect(configuration.appearance.fontSize == 13)
  #expect(configuration.appearance.themeName == "Ayu Light")
  #expect(configuration.appearance.darkThemeName == "Ayu Dark")
  #expect(configuration.appearance.useSeparateDarkTheme)
  #expect(configuration.appearance.terminalIdentity == "auto")
  #expect(configuration.controls.allowMouseReporting)
  #expect(!configuration.controls.optionAsMeta)
  #expect(configuration.controls.resolvedOptionAsMetaMode == .off)
  #expect(configuration.controls.resolvedVTKeypadAppAllowed)
  #expect(configuration.controls.resolvedRightClickAction == .contextMenu)
  #expect(configuration.controls.resolvedBypassMouseReporting == .shift)
  #expect(configuration.controls.resolvedLinkOpenWith == .browser)
  #expect(configuration.controls.resolvedFileOpenWith == .aster)
  #expect(configuration.controls.resolvedFolderOpenWith == .aster)
  #expect(configuration.controls.resolvedSelectionBackspaceDeletes)
  #expect(!configuration.controls.trimTrailingSpaces)
  #expect(configuration.controls.resolvedShiftArrowSelection)
  #expect(configuration.controls.resolvedClearSelectionOnTyping)
  #expect(!configuration.controls.resolvedClearSelectionOnCopy)
  #expect(configuration.controls.pasteProtection)
  #expect(configuration.controls.resolvedPasteBracketedSafe)
  #expect(configuration.controls.resolvedClipboardWriteAccess == .allow)
  #expect(configuration.controls.resolvedClipboardReadAccess == .ask)
  #expect(!configuration.controls.resolvedIPCAllowSendKeys)
  #expect(!configuration.controls.resolvedIPCAllowSensitiveSessions)
  #expect(configuration.controls.resolvedScrollPastLastLine == .disabled)
  #expect(configuration.controls.resolvedScrollPastFirstLine == .disabled)
  #expect(configuration.shell.resolvedNotifyOnWatchFinish)
  #expect(configuration.shell.resolvedNotificationShellControlled)
  #expect(configuration.shell.resolvedNotifyWhileForeground == .off)
  #expect(configuration.shell.resolvedBounceDockIcon)
  #expect(!configuration.shell.resolvedSoundOnErrorExit)
  #expect(configuration.shell.resolvedNotificationSoundCategories.isEmpty)
  #expect(configuration.shell.resolvedBadgeCommandFinish)
  #expect(configuration.shell.resolvedBadgeCommandFailure)
  #expect(configuration.shell.resolvedTitleShellControlled)
  #expect(!configuration.shell.resolvedTitleReport)
  #expect(!configuration.appearance.resolvedAnimateDockIconOnProgress)
  #expect(configuration.appearance.resolvedRedDockIconOnError)
}

@Test("旧 Shell 配置缺少通知和进度字段时采用 Otty 默认值")
func legacyShellConfigurationDefaultsTerminalActivityOptions() throws {
  let data = try JSONEncoder().encode(ShellConfiguration())
  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  for key in [
    "notifyOnWatchFinish", "notificationShellControlled", "notifyWhileForeground",
    "bounceDockIcon", "soundOnErrorExit", "notificationSoundCategories",
    "badgeCommandFinish", "badgeCommandFailure", "autoProgressCommands",
    "titleShellControlled", "titleReport",
  ] {
    object.removeValue(forKey: key)
  }
  let decoded = try JSONDecoder().decode(
    ShellConfiguration.self,
    from: JSONSerialization.data(withJSONObject: object)
  )

  #expect(decoded.resolvedNotifyOnWatchFinish)
  #expect(decoded.resolvedNotificationShellControlled)
  #expect(decoded.resolvedNotifyWhileForeground == .off)
  #expect(decoded.resolvedBounceDockIcon)
  #expect(!decoded.resolvedSoundOnErrorExit)
  #expect(decoded.resolvedNotificationSoundCategories.isEmpty)
  #expect(decoded.resolvedAutoProgressCommands.contains("git push"))
  #expect(decoded.resolvedTitleShellControlled)
  #expect(!decoded.resolvedTitleReport)
}

@Test("十六进制主题色支持 RGB 和 RGBA 并拒绝非法值")
func hexColorParsesStableThemeValues() {
  #expect(HexColor("#F8F8F6")?.red == 248)
  #expect(HexColor("#8DAE62CC")?.alpha == 204)
  #expect(HexColor("wrong") == nil)
}

@Test("完整配置可以无损持久化")
func configurationRoundTripsThroughJSON() throws {
  var configuration = AsterConfiguration.default
  configuration.tabBarLayout = .bottom
  configuration.appearance.fontFamily = "JetBrains Mono"
  configuration.appearance.newTabPosition = .afterCurrent
  configuration.appearance.bidirectionalText = false
  configuration.appearance.ligatureLevel = .discretionary
  configuration.appearance.widenedEastAsianAmbiguousBlocks = [
    .arrows, .geometricShapes, .numberForms,
  ]
  configuration.appearance.blinkRenderingPolicy = .animated
  configuration.appearance.boldRendering = .synthetic
  configuration.appearance.italicRendering = .synthetic
  configuration.editor.showLineNumbers = false
  configuration.controls.scrollPastLastLine = .cursorLine
  configuration.controls.scrollPastFirstLine = .sameAsLastLine

  let encoded = try JSONEncoder().encode(configuration)
  let decoded = try JSONDecoder().decode(AsterConfiguration.self, from: encoded)

  #expect(decoded == configuration)
  #expect(decoded.appearance.resolvedNewTabPosition == .afterCurrent)
  #expect(!decoded.appearance.resolvedBidirectionalText)
  #expect(decoded.appearance.resolvedLigatureLevel == .discretionary)
  #expect(decoded.appearance.resolvedWidenedEastAsianAmbiguousBlocks == [
    .arrows, .geometricShapes, .numberForms,
  ])
  #expect(decoded.appearance.resolvedBlinkRenderingPolicy == .animated)
  #expect(decoded.appearance.resolvedBoldRendering == .synthetic)
  #expect(decoded.appearance.resolvedItalicRendering == .synthetic)
  #expect(decoded.controls.resolvedScrollPastLastLine == .cursorLine)
  #expect(decoded.controls.resolvedScrollPastFirstLine == .sameAsLastLine)
}

@Test("Unicode 与文本样式配置采用可访问且兼容的默认值")
func unicodeTextConfigurationUsesAccessibleDefaults() {
  let appearance = AppearanceConfiguration()

  #expect(appearance.resolvedBidirectionalText)
  #expect(appearance.resolvedLigatureLevel == .standard)
  #expect(appearance.resolvedWidenedEastAsianAmbiguousBlocks == [.enclosedAlphanumerics])
  #expect(appearance.resolvedBlinkRenderingPolicy == .steady)
  #expect(appearance.resolvedBoldRendering == .automatic)
  #expect(appearance.resolvedItalicRendering == .automatic)
}

@Test("外观配置保留 Otty 字体、文本与光标设置并钳制不透明度")
func appearanceConfigurationPreservesOttyAppearanceControls() throws {
  var object = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(AppearanceConfiguration()))
      as? [String: Any]
  )
  object["fontFamilyBold"] = "JetBrains Mono Bold"
  object["fontFamilyItalic"] = "JetBrains Mono Italic"
  object["fontFamilyBoldItalic"] = "JetBrains Mono Bold Italic"
  object["fontFamilyFallback"] = ["SF Mono", "Menlo"]
  object["underlineRendering"] = true
  object["fontSmoothing"] = false
  object["cursorColorOverride"] = ["red": 16, "green": 32, "blue": 48, "alpha": 255]
  object["cursorTextColorOverride"] = ["red": 240, "green": 224, "blue": 208, "alpha": 255]
  object["cursorOpacity"] = 2.5
  object["cursorBlinkMode"] = "always-off"
  object["cursorAnimation"] = "smooth"

  var configuration = AsterConfiguration.default
  configuration.appearance = try JSONDecoder().decode(
    AppearanceConfiguration.self,
    from: JSONSerialization.data(withJSONObject: object)
  )
  #expect(configuration.appearance.resolvedFontFamilyFallback == ["SF Mono", "Menlo"])
  let normalized = configuration.normalized()
  #expect(normalized.appearance.resolvedFontFamilyFallback == ["SF Mono", "Menlo"])
  let encoded = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(normalized.appearance))
      as? [String: Any]
  )

  #expect(encoded["fontFamilyBold"] as? String == "JetBrains Mono Bold")
  #expect(encoded["fontFamilyItalic"] as? String == "JetBrains Mono Italic")
  #expect(encoded["fontFamilyBoldItalic"] as? String == "JetBrains Mono Bold Italic")
  #expect((encoded["fontFamilyFallback"] as? [Any])?.compactMap { $0 as? String } == ["SF Mono", "Menlo"])
  #expect(encoded["underlineRendering"] as? Bool == true)
  #expect(encoded["fontSmoothing"] as? Bool == false)
  let cursor = encoded["cursorColorOverride"] as? [String: Int]
  let cursorText = encoded["cursorTextColorOverride"] as? [String: Int]
  #expect(cursor?["red"] == 16)
  #expect(cursor?["green"] == 32)
  #expect(cursorText?["red"] == 240)
  #expect(cursorText?["blue"] == 208)
  #expect(encoded["cursorOpacity"] as? Double == 1)
  #expect(encoded["cursorBlinkMode"] as? String == "always-off")
  #expect(encoded["cursorAnimation"] as? String == "smooth")
}

@Test("旧外观配置缺少 Unicode 与文本样式字段时采用新默认值")
func legacyAppearanceConfigurationDefaultsUnicodeTextRendering() throws {
  let data = try JSONEncoder().encode(AppearanceConfiguration())
  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  for key in [
    "bidirectionalText", "ligatureLevel", "widenedEastAsianAmbiguousBlocks",
    "blinkRenderingPolicy", "boldRendering", "italicRendering",
  ] {
    object.removeValue(forKey: key)
  }

  let decoded = try JSONDecoder().decode(
    AppearanceConfiguration.self,
    from: JSONSerialization.data(withJSONObject: object)
  )

  #expect(decoded.resolvedBidirectionalText)
  #expect(decoded.resolvedLigatureLevel == .standard)
  #expect(decoded.resolvedWidenedEastAsianAmbiguousBlocks == [.enclosedAlphanumerics])
  #expect(decoded.resolvedBlinkRenderingPolicy == .steady)
  #expect(decoded.resolvedBoldRendering == .automatic)
  #expect(decoded.resolvedItalicRendering == .automatic)
}

@Test("导入配置会规范化 Ambiguous block 标识并丢弃未知值")
func configurationNormalizesEastAsianAmbiguousBlocks() {
  var configuration = AsterConfiguration.default
  configuration.appearance.widenedEastAsianAmbiguousBlocks = [
    EastAsianAmbiguousBlock(rawValue: " ENCLOSED_ALPHANUMERICS "),
    EastAsianAmbiguousBlock(rawValue: "mathematical operators"),
    EastAsianAmbiguousBlock(rawValue: "miscellaneous-technical"),
    EastAsianAmbiguousBlock(rawValue: "not-a-unicode-block"),
  ]

  let normalized = configuration.normalized()

  #expect(normalized.appearance.resolvedWidenedEastAsianAmbiguousBlocks == [
    .enclosedAlphanumerics, .mathematicalOperators, .miscellaneousTechnical,
  ])
}

@Test("旧配置缺少新标签位置时安全回退到自动策略")
func legacyAppearanceConfigurationDefaultsNewTabPosition() throws {
  let data = try JSONEncoder().encode(AppearanceConfiguration())
  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  object.removeValue(forKey: "newTabPosition")
  let legacyData = try JSONSerialization.data(withJSONObject: object)

  let decoded = try JSONDecoder().decode(AppearanceConfiguration.self, from: legacyData)

  #expect(decoded.resolvedNewTabPosition == .automatic)
}

@Test("旧 Shell 配置缺少自动记录字段时安全回退为开启")
func legacyShellConfigurationDefaultsFrequentFolderRecording() throws {
  let data = try JSONEncoder().encode(ShellConfiguration())
  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  object.removeValue(forKey: "frecencyAutoRecord")
  let legacyData = try JSONSerialization.data(withJSONObject: object)

  let decoded = try JSONDecoder().decode(ShellConfiguration.self, from: legacyData)

  #expect(decoded.resolvedFrecencyAutoRecord)
}

@Test("旧控制配置缺少链接字段时保持默认检测与严格安全策略")
func legacyControlConfigurationDefaultsLinkSafety() throws {
  let data = try JSONEncoder().encode(ControlConfiguration())
  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  object.removeValue(forKey: "linkDetectionEnabled")
  object.removeValue(forKey: "detectAllLinkSchemes")
  object.removeValue(forKey: "customLinkSchemes")
  object.removeValue(forKey: "allowedNonStandardLinkSchemes")
  object.removeValue(forKey: "allowedExternalLinkHosts")
  object.removeValue(forKey: "allowedExecutableFileSignatures")
  let legacyData = try JSONSerialization.data(withJSONObject: object)

  let decoded = try JSONDecoder().decode(ControlConfiguration.self, from: legacyData)

  #expect(decoded.resolvedLinkDetectionEnabled)
  #expect(decoded.resolvedLinkSchemePolicy == .all)
  #expect(decoded.resolvedAllowedNonStandardLinkSchemes.isEmpty)
  #expect(decoded.resolvedAllowedExternalLinkHosts.isEmpty)
  #expect(decoded.resolvedAllowedExecutableFileSignatures.isEmpty)
}

@Test("旧控制配置缺少剪贴板字段时使用安全且兼容的默认值")
func legacyControlConfigurationDefaultsClipboardSafety() throws {
  let data = try JSONEncoder().encode(ControlConfiguration())
  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  object.removeValue(forKey: "clearSelectionOnCopy")
  object.removeValue(forKey: "shiftArrowSelection")
  object.removeValue(forKey: "clearSelectionOnTyping")
  object.removeValue(forKey: "pasteBracketedSafe")
  object.removeValue(forKey: "clipboardWriteAccess")
  object.removeValue(forKey: "clipboardReadAccess")
  let legacyData = try JSONSerialization.data(withJSONObject: object)

  let decoded = try JSONDecoder().decode(ControlConfiguration.self, from: legacyData)

  #expect(!decoded.resolvedClearSelectionOnCopy)
  #expect(decoded.resolvedShiftArrowSelection)
  #expect(decoded.resolvedClearSelectionOnTyping)
  #expect(decoded.resolvedPasteBracketedSafe)
  #expect(decoded.resolvedClipboardWriteAccess == .allow)
  #expect(decoded.resolvedClipboardReadAccess == .ask)
}

@Test("旧控制配置缺少交互字段时采用 Otty 控制页默认值")
func legacyControlConfigurationDefaultsInteractiveControls() throws {
  let data = try JSONEncoder().encode(ControlConfiguration())
  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  for key in [
    "optionAsMetaMode", "vtKeypadAppAllowed", "rightClickAction", "mouseHideWhileTyping",
    "bypassMouseReporting", "linkClickOverMouseMode", "cursorClickToMove",
    "secureInputIndication", "selectionBackspaceDeletes", "linkOpenWith", "fileOpenWith",
    "folderOpenWith", "openWithApplications",
  ] {
    object.removeValue(forKey: key)
  }
  let decoded = try JSONDecoder().decode(
    ControlConfiguration.self,
    from: JSONSerialization.data(withJSONObject: object)
  )

  #expect(decoded.resolvedOptionAsMetaMode == .off)
  #expect(decoded.resolvedVTKeypadAppAllowed)
  #expect(decoded.resolvedRightClickAction == .contextMenu)
  #expect(!decoded.resolvedMouseHideWhileTyping)
  #expect(decoded.resolvedBypassMouseReporting == .shift)
  #expect(decoded.resolvedLinkClickOverMouseMode)
  #expect(decoded.resolvedCursorClickToMove)
  #expect(decoded.resolvedSecureInputIndication)
  #expect(decoded.resolvedSelectionBackspaceDeletes)
  #expect(decoded.resolvedOpenWithApplications.isEmpty)
}

@Test("旧控制配置缺少滚动边界字段时保持传统边界")
func legacyControlConfigurationDefaultsScrollBoundaries() throws {
  let data = try JSONEncoder().encode(ControlConfiguration())
  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  object.removeValue(forKey: "scrollPastLastLine")
  object.removeValue(forKey: "scrollPastFirstLine")
  let legacyData = try JSONSerialization.data(withJSONObject: object)

  let decoded = try JSONDecoder().decode(ControlConfiguration.self, from: legacyData)

  #expect(decoded.resolvedScrollPastLastLine == .disabled)
  #expect(decoded.resolvedScrollPastFirstLine == .disabled)
}

@Test("旧控制配置缺少 Autocomplete 字段时使用隐私友好的兼容默认值")
func legacyControlConfigurationDefaultsAutocomplete() throws {
  let data = try JSONEncoder().encode(ControlConfiguration())
  var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  for key in [
    "autocompleteShortcut", "autocompleteCandidatePanel", "autocompleteInlineSuggestion",
    "autocompleteOnDeviceLearning", "autocompleteHistoryIgnore",
    "autocompleteDescriptionLanguage",
  ] {
    object.removeValue(forKey: key)
  }
  let decoded = try JSONDecoder().decode(
    ControlConfiguration.self,
    from: JSONSerialization.data(withJSONObject: object)
  )

  #expect(decoded.resolvedAutocompleteShortcut == .tab)
  #expect(decoded.resolvedAutocompleteCandidatePanel == .escape)
  #expect(decoded.resolvedAutocompleteInlineSuggestion)
  #expect(decoded.resolvedAutocompleteOnDeviceLearning)
  #expect(decoded.resolvedAutocompleteHistoryIgnore.isEmpty)
  #expect(decoded.resolvedAutocompleteDescriptionLanguage == .system)
}

@Test("配置规范化移除空白、控制字符和超限历史忽略模式")
func configurationNormalizesAutocompleteIgnorePatterns() {
  var configuration = AsterConfiguration.default
  configuration.controls.autocompleteHistoryIgnore = [
    "  ssh *  ", "", "bad\u{7}pattern", String(repeating: "x", count: 257),
  ]

  let normalized = configuration.normalized()

  #expect(normalized.controls.resolvedAutocompleteHistoryIgnore == ["ssh *"])
}

@Test("导入配置会清理非法、重复和超限的链接安全例外")
func configurationNormalizesLinkSafetyExceptions() {
  var configuration = AsterConfiguration.default
  configuration.controls.customLinkSchemes = ["VSCODE", "vscode", "bad scheme", "x"]
  configuration.controls.allowedNonStandardLinkSchemes = ["CODEX", "codex", "bad:"]
  configuration.controls.allowedExternalLinkHosts = [" Example.COM ", "bad/path"]
  configuration.controls.allowedExecutableFileSignatures = ["signature-v1", "bad\nvalue"]

  let normalized = configuration.normalized()

  #expect(normalized.controls.resolvedCustomLinkSchemes == ["vscode", "x"])
  #expect(normalized.controls.resolvedAllowedNonStandardLinkSchemes == ["codex"])
  #expect(normalized.controls.resolvedAllowedExternalLinkHosts == ["example.com"])
  #expect(normalized.controls.resolvedAllowedExecutableFileSignatures == ["signature-v1"])
}

@Test("标签栏自动隐藏只在单标签工作区生效")
func appearanceConfigurationResolvesTabBarVisibility() {
  var appearance = AppearanceConfiguration()
  appearance.showTabBar = true
  appearance.autoHideTabs = true

  #expect(!appearance.showsTabBar(tabCount: 1))
  #expect(appearance.showsTabBar(tabCount: 2))

  appearance.showTabBar = false
  #expect(!appearance.showsTabBar(tabCount: 2))
}
