import Foundation

/// 可序列化的 8-bit RGBA 颜色，配置层不依赖 AppKit，便于主题导入、测试和迁移。
public struct HexColor: Codable, Equatable, Sendable {
  public var red: UInt8
  public var green: UInt8
  public var blue: UInt8
  public var alpha: UInt8

  public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 255) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  public init?(_ value: String) {
    let digits = value.hasPrefix("#") ? String(value.dropFirst()) : value
    guard digits.count == 6 || digits.count == 8,
      let raw = UInt64(digits, radix: 16)
    else { return nil }

    if digits.count == 6 {
      red = UInt8((raw >> 16) & 0xFF)
      green = UInt8((raw >> 8) & 0xFF)
      blue = UInt8(raw & 0xFF)
      alpha = 255
    } else {
      red = UInt8((raw >> 24) & 0xFF)
      green = UInt8((raw >> 16) & 0xFF)
      blue = UInt8((raw >> 8) & 0xFF)
      alpha = UInt8(raw & 0xFF)
    }
  }

  public var stringValue: String {
    String(format: "#%02X%02X%02X%02X", red, green, blue, alpha)
  }
}

public enum LaunchBehavior: String, CaseIterable, Codable, Equatable, Sendable {
  case newWindow
  case restoreLastSession
}

public enum CloseConfirmation: String, CaseIterable, Codable, Equatable, Sendable {
  case always
  case runningProcess
  case multipleTabs
  case never
}

public enum CursorStyle: String, CaseIterable, Codable, Equatable, Sendable {
  case block
  case bar
  case underline
  case hollowBlock
}

/// 光标闪烁与终端程序控制之间的优先级。`default*` 只设置初始状态，之后接受
/// DECSCUSR / DEC mode 12；`always*` 则把用户设置作为最终真值。
public enum TerminalCursorBlinkMode: String, CaseIterable, Codable, Equatable, Sendable {
  case defaultOff = "default-off"
  case defaultOn = "default-on"
  case alwaysOff = "always-off"
  case alwaysOn = "always-on"

  public var initiallyBlinks: Bool {
    self == .defaultOn || self == .alwaysOn
  }

  public var pinsProgramControl: Bool {
    self == .alwaysOff || self == .alwaysOn
  }
}

/// 光标移动反馈。当前只有关闭与同一行平滑移动两种稳定语义。
public enum TerminalCursorAnimation: String, CaseIterable, Codable, Equatable, Sendable {
  case off
  case smooth
}

/// OpenType 连字级别。Raw value 是 Aster JSON 配置的稳定持久化契约，渲染层可将
/// `standard` 映射到标准连字和 contextual alternates，将 `discretionary` 再扩展到 dlig。
public enum TerminalLigatureLevel: String, CaseIterable, Codable, Equatable, Sendable {
  case none
  case standard
  case discretionary
}

/// SGR 5/6 文本的渲染策略。默认把 blink 文本稳定显示，避免无意闪烁造成可访问性问题。
public enum TerminalBlinkRenderingPolicy: String, CaseIterable, Codable, Equatable, Sendable {
  case steady
  case animated
}

/// 粗体与斜体请求的字形选择策略。`synthetic` 仅在真实字形不可用时由渲染层合成，
/// `primaryFontOnly` 则禁止从 fallback 字体借用对应样式。
public enum TerminalTextStyleRendering: String, CaseIterable, Codable, Equatable, Sendable {
  case automatic
  case disabled
  case primaryFontOnly = "primary-font-only"
  case synthetic
}

/// 可选择加宽的 East-Asian-Ambiguous Unicode block。
///
/// 这里使用可保留原始字符串的值类型，而不是封闭枚举：配置导入阶段可以先成功解码
/// 新版本或手写的 block 标识，再由 `AsterConfiguration.normalized()` 统一规范化、过滤。
/// 这样既不会让一个未知值导致整份配置无法读取，也不会把未知 block 传给渲染层。
public struct EastAsianAmbiguousBlock: RawRepresentable, CaseIterable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public static let enclosedAlphanumerics = Self(rawValue: "enclosed-alphanumerics")
  public static let numberForms = Self(rawValue: "number-forms")
  public static let mathematicalOperators = Self(rawValue: "math-operators")
  public static let miscellaneousTechnical = Self(rawValue: "misc-technical")
  public static let miscellaneousSymbols = Self(rawValue: "misc-symbols")
  public static let dingbats = Self(rawValue: "dingbats")
  public static let arrows = Self(rawValue: "arrows")
  public static let geometricShapes = Self(rawValue: "geometric-shapes")

  public static let allCases: [Self] = [
    .enclosedAlphanumerics,
    .numberForms,
    .mathematicalOperators,
    .miscellaneousTechnical,
    .miscellaneousSymbols,
    .dingbats,
    .arrows,
    .geometricShapes,
  ]

  /// 把大小写、空白、下划线和常见 Unicode block 全名统一成 Aster 的稳定标识；
  /// 返回 nil 表示该输入不是当前版本支持的可加宽 block。
  public var normalizedKnownValue: Self? {
    let identifier = rawValue
      .lowercased()
      .split(whereSeparator: { $0.isWhitespace || $0 == "_" || $0 == "-" })
      .joined(separator: "-")
    return switch identifier {
    case "enclosed-alphanumerics": .enclosedAlphanumerics
    case "number-forms": .numberForms
    case "math-operators", "mathematical-operators": .mathematicalOperators
    case "misc-technical", "miscellaneous-technical": .miscellaneousTechnical
    case "misc-symbols", "miscellaneous-symbols": .miscellaneousSymbols
    case "dingbats": .dingbats
    case "arrows": .arrows
    case "geometric-shapes": .geometricShapes
    default: nil
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    self.init(rawValue: try container.decode(String.self))
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    try container.encode(rawValue)
  }
}

/// 普通屏滚过最新内容后的停靠位置。枚举值保持稳定，供配置文件持久化和迁移使用。
public enum TerminalScrollPastLastLine: String, CaseIterable, Codable, Equatable, Sendable {
  case disabled
  case lastLineWithContent
  case lastLineInMiddle
  case cursorLine
}

/// 普通屏滚过最早内容后的停靠位置；alternate screen 始终忽略该设置。
public enum TerminalScrollPastFirstLine: String, CaseIterable, Codable, Equatable, Sendable {
  case disabled
  case sameAsLastLine
  case firstLineWithContent
  case firstLineInMiddle
}

/// 接受当前补全候选的键盘方案。Raw value 与配置文件中的稳定值保持一致。
public enum AutocompleteShortcut: String, CaseIterable, Codable, Equatable, Sendable {
  case tab
  case tabAndRightArrow = "tab+right-arrow"
  case controlSpace = "ctrl+space"
  case disabled = "disable"
}

/// 候选面板的显示策略；inline suggestion 不受禁用面板影响。
public enum AutocompleteCandidatePanel: String, CaseIterable, Codable, Equatable, Sendable {
  case disabled = "disable"
  case automatic = "auto"
  case escape
  case optionEscape = "option-escape"
}

/// 内置规格描述的首选语言。`system` 由 UI 层根据当前语言环境解析。
public enum AutocompleteDescriptionLanguage: String, CaseIterable, Codable, Equatable, Sendable {
  case system
  case english
  case chinese

  public func resolved(preferredLanguageIdentifiers: [String]) -> AutocompleteDescriptionLanguage {
    guard self == .system else { return self }
    let primary = preferredLanguageIdentifiers.first?.lowercased() ?? "en"
    return primary == "zh" || primary.hasPrefix("zh-") ? .chinese : .english
  }
}

public struct GeneralConfiguration: Codable, Equatable, Sendable {
  public var language = "system"
  public var quitAfterLastWindowClosed = false
  public var newWindowWhenAllClosed = false
  public var closeTabConfirmation = CloseConfirmation.runningProcess
  public var closeWindowConfirmation = CloseConfirmation.runningProcess
  public var closePaneConfirmation = CloseConfirmation.runningProcess
}

public struct ShellConfiguration: Codable, Equatable, Sendable {
  public var shellIntegration = true
  public var sshIntegration = true
  /// 可选字段兼容 0.4.x 配置；缺失时按 Otty 默认值开启自动记录。
  public var frecencyAutoRecord: Bool? = true
  public var restoreMultiplexerSessions = true
  public var restoreAgentSessions = true
  public var restoreProcesses = false
  public var notifyOnFinish = false
  public var notifyOnError = true
  public var terminalBell = true
  public var badgeExitStatus = true
  public var badgeAwaitingInput = true
  /// 以下字段均保持可选以兼容 0.4.x 的单块 JSON 配置；resolved 属性提供 Otty 默认值。
  public var notifyOnWatchFinish: Bool? = true
  public var notificationShellControlled: Bool? = true
  public var notifyWhileForeground: NotificationForegroundPolicy? = .off
  public var bounceDockIcon: Bool? = true
  public var soundOnErrorExit: Bool? = false
  public var notificationSoundCategories: Set<TerminalNotificationCategory>? = []
  public var badgeCommandFinish: Bool? = true
  public var badgeCommandFailure: Bool? = true
  public var autoProgressCommands: [String]? = AutomaticProgressMatcher.defaultPrefixes
  public var titleShellControlled: Bool? = true
  public var titleReport: Bool? = false

  public var resolvedFrecencyAutoRecord: Bool {
    frecencyAutoRecord ?? true
  }

  public var resolvedNotifyOnWatchFinish: Bool { notifyOnWatchFinish ?? true }
  public var resolvedNotificationShellControlled: Bool { notificationShellControlled ?? true }
  public var resolvedNotifyWhileForeground: NotificationForegroundPolicy {
    notifyWhileForeground ?? .off
  }
  public var resolvedBounceDockIcon: Bool { bounceDockIcon ?? true }
  public var resolvedSoundOnErrorExit: Bool { soundOnErrorExit ?? false }
  public var resolvedNotificationSoundCategories: Set<TerminalNotificationCategory> {
    notificationSoundCategories ?? []
  }
  public var resolvedBadgeCommandFinish: Bool { badgeCommandFinish ?? true }
  public var resolvedBadgeCommandFailure: Bool { badgeCommandFailure ?? badgeExitStatus }
  public var resolvedAutoProgressCommands: [String] {
    autoProgressCommands ?? AutomaticProgressMatcher.defaultPrefixes
  }
  public var resolvedTitleShellControlled: Bool { titleShellControlled ?? true }
  public var resolvedTitleReport: Bool { titleReport ?? false }
}

public struct ControlConfiguration: Codable, Equatable, Sendable {
  public var optionAsMeta = false
  public var allowMouseReporting = true
  public var focusFollowsMouse = false
  public var copyOnSelect = false
  public var trimTrailingSpaces = false
  public var pasteProtection = true
  public var smoothScrolling = true
  /// 可选字段兼容旧配置；缺失时保持传统边界，不产生额外空白区域。
  public var scrollPastLastLine: TerminalScrollPastLastLine? = .disabled
  public var scrollPastFirstLine: TerminalScrollPastFirstLine? = .disabled
  public var showLinkPreviews = true
  public var secureInputAutomatically = true
  /// 可选字段兼容旧配置；缺失时采用 Otty 的选择、复制与剪贴板安全默认值。
  public var shiftArrowSelection: Bool? = true
  public var clearSelectionOnTyping: Bool? = true
  public var clearSelectionOnCopy: Bool? = false
  public var pasteBracketedSafe: Bool? = true
  public var clipboardWriteAccess: ClipboardAccess? = .allow
  public var clipboardReadAccess: ClipboardAccess? = .ask
  /// 可选字段保证 0.4.x 配置可继续解码。nil 均按 Otty 的安全默认值解释。
  public var linkDetectionEnabled: Bool? = true
  public var detectAllLinkSchemes: Bool? = true
  public var customLinkSchemes: Set<String>? = []
  public var allowedNonStandardLinkSchemes: Set<String>? = []
  /// 可选字段兼容早期配置；缺失时采用 Otty 的补全默认行为。
  public var autocompleteShortcut: AutocompleteShortcut? = .tab
  public var autocompleteCandidatePanel: AutocompleteCandidatePanel? = .escape
  public var autocompleteInlineSuggestion: Bool? = true
  public var autocompleteOnDeviceLearning: Bool? = true
  public var autocompleteHistoryIgnore: [String]? = []
  public var autocompleteDescriptionLanguage: AutocompleteDescriptionLanguage? = .system
  /// Pane IPC 写入默认关闭；敏感会话必须在第一层写权限之外再次显式放行。
  public var ipcAllowSendKeys: Bool? = false
  public var ipcAllowSensitiveSessions: Bool? = false

  public init() {}

  public var resolvedLinkDetectionEnabled: Bool { linkDetectionEnabled ?? true }

  public var resolvedShiftArrowSelection: Bool { shiftArrowSelection ?? true }

  public var resolvedClearSelectionOnTyping: Bool { clearSelectionOnTyping ?? true }

  public var resolvedClearSelectionOnCopy: Bool { clearSelectionOnCopy ?? false }

  public var resolvedScrollPastLastLine: TerminalScrollPastLastLine {
    scrollPastLastLine ?? .disabled
  }

  public var resolvedScrollPastFirstLine: TerminalScrollPastFirstLine {
    scrollPastFirstLine ?? .disabled
  }

  public var resolvedPasteBracketedSafe: Bool { pasteBracketedSafe ?? true }

  public var resolvedClipboardWriteAccess: ClipboardAccess { clipboardWriteAccess ?? .allow }

  public var resolvedClipboardReadAccess: ClipboardAccess { clipboardReadAccess ?? .ask }

  public var resolvedCustomLinkSchemes: Set<String> {
    customLinkSchemes ?? []
  }

  public var resolvedLinkSchemePolicy: LinkSchemePolicy {
    (detectAllLinkSchemes ?? true) ? .all : .custom(resolvedCustomLinkSchemes)
  }

  public var resolvedAllowedNonStandardLinkSchemes: Set<String> {
    allowedNonStandardLinkSchemes ?? []
  }

  public var resolvedAutocompleteShortcut: AutocompleteShortcut {
    autocompleteShortcut ?? .tab
  }

  public var resolvedAutocompleteCandidatePanel: AutocompleteCandidatePanel {
    autocompleteCandidatePanel ?? .escape
  }

  public var resolvedAutocompleteInlineSuggestion: Bool {
    autocompleteInlineSuggestion ?? true
  }

  public var resolvedAutocompleteOnDeviceLearning: Bool {
    autocompleteOnDeviceLearning ?? true
  }

  public var resolvedAutocompleteHistoryIgnore: [String] {
    autocompleteHistoryIgnore ?? []
  }

  public var resolvedAutocompleteDescriptionLanguage: AutocompleteDescriptionLanguage {
    autocompleteDescriptionLanguage ?? .system
  }

  public var resolvedIPCAllowSendKeys: Bool { ipcAllowSendKeys ?? false }

  public var resolvedIPCAllowSensitiveSessions: Bool { ipcAllowSensitiveSessions ?? false }

  public var resolvedTargetSecurityPolicy: TargetSecurityPolicy {
    TargetSecurityPolicy(
      allowedNonStandardSchemes: resolvedAllowedNonStandardLinkSchemes
    )
  }
}

public struct EditorConfiguration: Codable, Equatable, Sendable {
  public var lineWrap = true
  public var showLineNumbers = true
  public var showVisibleWhitespace = false
  public var tabSize = 4
  public var scrollPastEnd = true
  public var vimKeyBindings = false
  public var previewRichDocuments = true
}

public struct AppearanceConfiguration: Codable, Equatable, Sendable {
  public var themeName = "Ayu Light"
  public var darkThemeName = "Ayu Dark"
  public var useSeparateDarkTheme = true
  public var fontFamily = "JetBrains Mono"
  /// 空值表示让 AppKit 从普通字体自动匹配对应字重/字形；显式值覆盖自动匹配。
  public var fontFamilyBold: String?
  public var fontFamilyItalic: String?
  public var fontFamilyBoldItalic: String?
  /// 用户 fallback 位于内置 Nerd Symbols 之后、系统级级联之前。
  public var fontFamilyFallback: [String]?
  /// 逐样式 fallback 为空时继承常规 fallback；显式空数组表示该样式不追加用户字体。
  public var fontFamilyFallbackBold: [String]?
  public var fontFamilyFallbackItalic: [String]?
  public var fontFamilyFallbackBoldItalic: [String]?
  public var fontSize = 13.0
  public var lineHeight = 1.08
  public var foreground = HexColor("#202124")!
  public var background = HexColor("#FCFCFB")!
  public var darkForeground = HexColor("#E8E8E6")!
  public var darkBackground = HexColor("#171817")!
  public var accent = HexColor("#84A957")!
  public var cursor = HexColor("#5B73FF")!
  public var selection = HexColor("#B8CEF099")!
  public var cursorStyle = CursorStyle.block
  /// 旧版布尔字段保留用于解码迁移；新代码统一读取 `resolvedCursorBlinkMode`。
  public var cursorBlink = true
  /// 新字段保持可选以兼容 0.4.x JSON；所有消费者应使用下方 resolved 属性。
  public var bidirectionalText: Bool? = true
  public var ligatureLevel: TerminalLigatureLevel? = .standard
  public var widenedEastAsianAmbiguousBlocks: Set<EastAsianAmbiguousBlock>? = [
    .enclosedAlphanumerics
  ]
  public var blinkRenderingPolicy: TerminalBlinkRenderingPolicy? = .steady
  public var boldRendering: TerminalTextStyleRendering? = .automatic
  public var italicRendering: TerminalTextStyleRendering? = .automatic
  public var underlineRendering: Bool? = true
  public var fontSmoothing: Bool? = true
  public var cursorColorOverride: HexColor?
  public var cursorTextColorOverride: HexColor?
  public var cursorOpacity: Double? = 1
  public var cursorBlinkMode: TerminalCursorBlinkMode? = .defaultOn
  public var cursorAnimation: TerminalCursorAnimation? = .off
  /// `auto` 在 Pane 启动时解析为保守的 xterm-256color；自定义值必须存在 terminfo。
  public var terminalIdentity = "auto"
  public var showTabBar = true
  public var autoHideTabs = false
  /// 可选字段用于兼容 0.4.x 配置；缺失时等价于 Otty 的 `auto`。
  public var newTabPosition: NewTabPosition? = .automatic
  /// 旧配置兼容字段。AppKit 层仅用它初始化尚无窗口级 Panel 状态的工作区。
  public var sidebarWidth = 220.0
  public var showStatusBar = true
  public var windowWidth = 1180.0
  public var windowHeight = 760.0
  /// Dock 聚合状态默认只标红错误；旋转动画需要用户主动开启。
  public var animateDockIconOnProgress: Bool? = false
  public var redDockIconOnError: Bool? = true

  public func showsTabBar(tabCount: Int) -> Bool {
    showTabBar && !(autoHideTabs && tabCount <= 1)
  }

  public var resolvedNewTabPosition: NewTabPosition {
    newTabPosition ?? .automatic
  }

  public var resolvedBidirectionalText: Bool { bidirectionalText ?? true }
  public var resolvedLigatureLevel: TerminalLigatureLevel { ligatureLevel ?? .standard }
  public var resolvedWidenedEastAsianAmbiguousBlocks: Set<EastAsianAmbiguousBlock> {
    widenedEastAsianAmbiguousBlocks ?? [.enclosedAlphanumerics]
  }
  public var resolvedBlinkRenderingPolicy: TerminalBlinkRenderingPolicy {
    blinkRenderingPolicy ?? .steady
  }
  public var resolvedBoldRendering: TerminalTextStyleRendering { boldRendering ?? .automatic }
  public var resolvedItalicRendering: TerminalTextStyleRendering { italicRendering ?? .automatic }
  public var resolvedUnderlineRendering: Bool { underlineRendering ?? true }
  public var resolvedFontSmoothing: Bool { fontSmoothing ?? true }
  public var resolvedFontFamilyFallback: [String] { fontFamilyFallback ?? [] }
  public var resolvedFontFamilyFallbackBold: [String] {
    fontFamilyFallbackBold ?? resolvedFontFamilyFallback
  }
  public var resolvedFontFamilyFallbackItalic: [String] {
    fontFamilyFallbackItalic ?? resolvedFontFamilyFallback
  }
  public var resolvedFontFamilyFallbackBoldItalic: [String] {
    fontFamilyFallbackBoldItalic ?? resolvedFontFamilyFallback
  }
  public var resolvedCursorOpacity: Double { min(max(cursorOpacity ?? 1, 0.1), 1) }
  public var resolvedCursorBlinkMode: TerminalCursorBlinkMode {
    cursorBlinkMode ?? (cursorBlink ? .defaultOn : .defaultOff)
  }
  public var resolvedCursorAnimation: TerminalCursorAnimation { cursorAnimation ?? .off }

  public var resolvedAnimateDockIconOnProgress: Bool { animateDockIconOnProgress ?? false }
  public var resolvedRedDockIconOnError: Bool { redDockIconOnError ?? true }
}

public struct AgentConfiguration: Codable, Equatable, Sendable {
  public var enabledAgents = ["claude", "codex", "kimi"]
  /// key 为 AgentProvider.rawValue，value 为结构化 argv（首项是可执行文件）。可选字段
  /// 保持旧配置可解码；命令不以 shell 字符串保存，避免恢复时重新解释 `$()` 等语法。
  public var customLaunchCommands: [String: [String]]?
  public var badgeProcessing = true
  public var badgeTaskComplete = true
  public var badgeAwaitingInput = true
  public var notifyTaskComplete = true
  public var notifyAwaitingInput = true
  public var preventSleepWhileProcessing = false
  public var resumeSessions = true

  public func launchComponents(for provider: AgentProvider) -> [String] {
    guard let components = customLaunchCommands?[provider.rawValue],
      let executable = components.first,
      (try? AgentLaunchPrefix(executable: executable, arguments: Array(components.dropFirst()))) != nil
    else { return [provider.commandName] }
    return components
  }
}

/// Aster 的完整用户配置。持久化入口在解码后统一规范化所有外部可控数值。
public struct AsterConfiguration: Codable, Equatable, Sendable {
  public var general = GeneralConfiguration()
  public var shell = ShellConfiguration()
  public var controls = ControlConfiguration()
  public var editor = EditorConfiguration()
  public var appearance = AppearanceConfiguration()
  public var agents = AgentConfiguration()
  public var tabBarLayout = TabBarLayout.vertical
  public var launchBehavior = LaunchBehavior.restoreLastSession
  /// Aster 内保存的 Recipe 默认可信，可自动重放；可选字段兼容旧版单一重放策略。
  public var savedRecipeReplayMode: RecipeReplayMode? = .automatic
  /// 外部文件继续使用旧字段，保证历史配置解码和运行时语义不变。
  public var recipeReplayMode = RecipeReplayMode.confirmOnce

  public var resolvedSavedRecipeReplayMode: RecipeReplayMode {
    savedRecipeReplayMode ?? .automatic
  }

  public init() {}

  public static let `default` = AsterConfiguration()

  /// 约束导入文件和 UserDefaults 中的异常值，防止超大窗口、不可见侧栏或非法 TERM
  /// 破坏应用布局。配置校验成功后才会整体替换当前值。
  public func normalized() -> AsterConfiguration {
    var result = self
    result.appearance.fontSize = min(max(result.appearance.fontSize, 9), 32)
    result.appearance.sidebarWidth = min(max(result.appearance.sidebarWidth, 180), 360)
    result.appearance.lineHeight = min(max(result.appearance.lineHeight, 0.8), 2)
    result.appearance.windowWidth = min(max(result.appearance.windowWidth, 820), 3_840)
    result.appearance.windowHeight = min(max(result.appearance.windowHeight, 520), 2_160)
    // 旧配置的 nil 在导入边界固化为当前默认值；Ambiguous block 同时接受常见外部
    // 拼写，但只保留当前渲染层能识别的稳定标识。空集合是用户主动关闭全部加宽，
    // 因此必须原样保留，不能回填 enclosed alphanumerics。
    result.appearance.bidirectionalText = result.appearance.resolvedBidirectionalText
    result.appearance.ligatureLevel = result.appearance.resolvedLigatureLevel
    result.appearance.blinkRenderingPolicy = result.appearance.resolvedBlinkRenderingPolicy
    result.appearance.boldRendering = result.appearance.resolvedBoldRendering
    result.appearance.italicRendering = result.appearance.resolvedItalicRendering
    result.appearance.underlineRendering = result.appearance.resolvedUnderlineRendering
    result.appearance.fontSmoothing = result.appearance.resolvedFontSmoothing
    result.appearance.cursorOpacity = result.appearance.resolvedCursorOpacity
    result.appearance.cursorBlinkMode = result.appearance.resolvedCursorBlinkMode
    result.appearance.cursorAnimation = result.appearance.resolvedCursorAnimation
    result.appearance.fontFamilyFallback = Self.normalizedFontFamilies(
      result.appearance.resolvedFontFamilyFallback)
    result.appearance.fontFamilyFallbackBold = Self.normalizedFontFamilies(
      result.appearance.resolvedFontFamilyFallbackBold)
    result.appearance.fontFamilyFallbackItalic = Self.normalizedFontFamilies(
      result.appearance.resolvedFontFamilyFallbackItalic)
    result.appearance.fontFamilyFallbackBoldItalic = Self.normalizedFontFamilies(
      result.appearance.resolvedFontFamilyFallbackBoldItalic)
    result.appearance.widenedEastAsianAmbiguousBlocks = Set(
      result.appearance.resolvedWidenedEastAsianAmbiguousBlocks.compactMap(\.normalizedKnownValue)
    )
    result.editor.tabSize = min(max(result.editor.tabSize, 2), 8)
    if result.appearance.fontFamily.utf8.count > 128 {
      result.appearance.fontFamily = AppearanceConfiguration().fontFamily
    }
    result.appearance.fontFamilyBold = Self.normalizedOptionalFontFamily(
      result.appearance.fontFamilyBold)
    result.appearance.fontFamilyItalic = Self.normalizedOptionalFontFamily(
      result.appearance.fontFamilyItalic)
    result.appearance.fontFamilyBoldItalic = Self.normalizedOptionalFontFamily(
      result.appearance.fontFamilyBoldItalic)
    let term = result.appearance.terminalIdentity
    if term.isEmpty || term.utf8.count > 64
      || term.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) })
    {
      result.appearance.terminalIdentity = AppearanceConfiguration().terminalIdentity
    }
    if result.general.language.utf8.count > 32 { result.general.language = "system" }
    result.controls.customLinkSchemes = Self.normalizedSchemes(
      result.controls.resolvedCustomLinkSchemes)
    result.controls.allowedNonStandardLinkSchemes = Self.normalizedSchemes(
      result.controls.resolvedAllowedNonStandardLinkSchemes)
    result.controls.autocompleteHistoryIgnore = Array(
      result.controls.resolvedAutocompleteHistoryIgnore.lazy
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter {
          !$0.isEmpty && $0.utf8.count <= 256
            && !$0.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        }
        .prefix(64)
    )
    result.shell.autoProgressCommands = Array(
      result.shell.resolvedAutoProgressCommands.lazy
        .map { $0.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
        .filter { !$0.isEmpty && $0.utf8.count <= 128 }
        .prefix(128)
    )
    if let commands = result.agents.customLaunchCommands {
      result.agents.customLaunchCommands = commands.reduce(into: [:]) { normalized, entry in
        guard let provider = AgentProvider(rawValue: entry.key),
          let executable = entry.value.first,
          entry.value.allSatisfy({ component in
            !component.unicodeScalars.contains(where: {
              CharacterSet.controlCharacters.contains($0)
            })
          }),
          (try? AgentLaunchPrefix(
            executable: executable,
            arguments: Array(entry.value.dropFirst())
          )) != nil
        else { return }
        normalized[provider.rawValue] = entry.value
      }
    }
    return result
  }

  /// 字体名称来自配置文件和文本框。拒绝控制字符、限制长度并去重，避免把异常名称
  /// 传入 CoreText 或让 fallback 级联无限增长。
  private static func normalizedOptionalFontFamily(_ value: String?) -> String? {
    guard let value else { return nil }
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.utf8.count <= 128,
      !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    else { return nil }
    return trimmed
  }

  private static func normalizedFontFamilies(_ values: [String]) -> [String] {
    var seen: Set<String> = []
    var result: [String] = []
    for value in values {
      guard let normalized = normalizedOptionalFontFamily(value),
        seen.insert(normalized).inserted
      else { continue }
      result.append(normalized)
      if result.count == 16 { break }
    }
    return result
  }

  private static func normalizedSchemes(_ schemes: Set<String>) -> Set<String> {
    Set(
      schemes.lazy
        .map { $0.lowercased() }
        .filter(LinkSchemePolicy.isSyntacticallyValid)
        .sorted()
        .prefix(64)
    )
  }
}
