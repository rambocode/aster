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

  public var resolvedFrecencyAutoRecord: Bool {
    frecencyAutoRecord ?? true
  }
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
  public var cursorBlink = true
  /// `auto` 在 Pane 启动时解析为保守的 xterm-256color；自定义值必须存在 terminfo。
  public var terminalIdentity = "auto"
  public var showTabBar = true
  public var autoHideTabs = false
  /// 可选字段用于兼容 0.4.x 配置；缺失时等价于 Otty 的 `auto`。
  public var newTabPosition: NewTabPosition? = .automatic
  public var sidebarWidth = 220.0
  public var showStatusBar = true
  public var windowWidth = 1180.0
  public var windowHeight = 760.0

  public func showsTabBar(tabCount: Int) -> Bool {
    showTabBar && !(autoHideTabs && tabCount <= 1)
  }

  public var resolvedNewTabPosition: NewTabPosition {
    newTabPosition ?? .automatic
  }
}

public struct AgentConfiguration: Codable, Equatable, Sendable {
  public var enabledAgents = ["claude", "codex", "kimi"]
  public var badgeProcessing = true
  public var badgeTaskComplete = true
  public var badgeAwaitingInput = true
  public var notifyTaskComplete = true
  public var notifyAwaitingInput = true
  public var preventSleepWhileProcessing = false
  public var resumeSessions = true
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
  public var recipeReplayMode = RecipeReplayMode.confirmOnce

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
    result.editor.tabSize = min(max(result.editor.tabSize, 2), 8)
    if result.appearance.fontFamily.utf8.count > 128 {
      result.appearance.fontFamily = AppearanceConfiguration().fontFamily
    }
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
