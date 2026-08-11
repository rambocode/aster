import AppKit
import AsterCore

/// 将 Aster 的全局外观/控制设置投影为 libghostty 配置文本。
///
/// 这是两个配置模型之间唯一的转换 seam。未知或无法等价表达的 Aster 设置不会写入
/// Ghostty 配置；调用方可据此明确禁用旧引擎专属功能，而不是散落兼容分支。
enum GhosttyConfiguration {
  @MainActor
  static func make(preferences: AppPreferences) -> String {
    let appearance = preferences.configuration.appearance
    let controls = preferences.configuration.controls
    let shell = preferences.configuration.shell
    let theme = preferences.activeTheme.palette
    let font = safeText(
      preferences.terminalFontVariants.normal.familyName
        ?? preferences.terminalFontVariants.normal.fontName,
      fallback: "Menlo"
    )
    let cursorStyle =
      switch appearance.cursorStyle {
      case .bar: "bar"
      case .underline: "underline"
      case .hollowBlock: "block_hollow"
      case .block: "block"
      }
    let blinkMode = appearance.resolvedCursorBlinkMode
    let scrollbackLines = Int(
      min(
        max(
          preferences.compatibilityNumber(forKey: "advanced.scrollbackLines", default: 10_000),
          1_000
        ), 1_000_000))
    // 固定的 Ghostty revision 仍以 byte 为单位；按每行 1 KiB 做有界投影，升级到
    // 公开 lines 配置前不能写入较新 revision 才认识的 `scrollback-limit-lines`。
    let scrollbackBytes = scrollbackLines * 1_000
    let lineHeightAdjustment = Int(((appearance.lineHeight - 1) * 100).rounded())
    let mouseShiftCapture =
      switch controls.resolvedBypassMouseReporting {
      case .shift: "never"
      case .none: "always"
      case .control, .option, .controlShift, .command:
        // Ghostty 目前只公开 Shift capture 配置；其它 Aster 修饰键无法等价投影，
        // 保持 Ghostty 可被前台程序动态协商的默认行为。
        "false"
      }

    var lines = [
      "font-family = \(font)",
      "font-size = \(format(appearance.fontSize))",
      "adjust-cell-height = \(lineHeightAdjustment)%",
      "foreground = \(rgb(theme.foreground))",
      "background = \(rgb(theme.windowBackground))",
      "background-opacity = \(format(Double(theme.windowBackground.alpha) / 255))",
      "cursor-color = \(rgb(preferences.configuration.appearance.cursorColorOverride ?? theme.cursor))",
      "cursor-text = \(rgb(preferences.configuration.appearance.cursorTextColorOverride ?? theme.cursorText ?? theme.windowBackground))",
      "cursor-opacity = \(format(appearance.resolvedCursorOpacity))",
      "cursor-style = \(cursorStyle)",
      "cursor-style-blink = \(boolean(blinkMode.initiallyBlinks))",
      "selection-background = \(rgb(theme.selection))",
      "selection-foreground = \(rgb(theme.selectionForeground ?? theme.windowBackground))",
      "selection-clear-on-typing = \(boolean(controls.resolvedClearSelectionOnTyping))",
      "selection-clear-on-copy = \(boolean(controls.resolvedClearSelectionOnCopy))",
      "clipboard-trim-trailing-spaces = \(boolean(controls.trimTrailingSpaces))",
      "copy-on-select = \(controls.copyOnSelect ? "clipboard" : "false")",
      // libghostty 始终进入 confirm callback，由 Aster 现有 allow/ask/deny 策略做最终判定。
      "clipboard-read = ask",
      "clipboard-write = ask",
      // Aster 在调用 surface_text 前显示自己的有界安全预览，关闭 Ghostty 的第二重提示。
      "clipboard-paste-protection = false",
      "clipboard-paste-bracketed-safe = \(boolean(controls.resolvedPasteBracketedSafe))",
      "macos-option-as-alt = \(controls.resolvedOptionAsMetaMode.rawValue)",
      "mouse-hide-while-typing = \(boolean(controls.resolvedMouseHideWhileTyping))",
      "focus-follows-mouse = false",
      "mouse-shift-capture = \(mouseShiftCapture)",
      "right-click-action = \(controls.resolvedRightClickAction.rawValue)",
      "cursor-click-to-move = \(boolean(controls.resolvedCursorClickToMove))",
      "link-url = \(boolean(controls.resolvedLinkDetectionEnabled))",
      "title-report = \(boolean(shell.resolvedTitleReport))",
      "scrollback-limit = \(scrollbackBytes)",
      "shell-integration = \(shell.shellIntegration ? "detect" : "none")",
      "window-padding-x = 0",
      "window-padding-y = 0",
      "unfocused-split-opacity = 1",
      "confirm-close-surface = false",
    ]
    for (index, color) in theme.ansiColors.enumerated() {
      lines.append("palette = \(index)=\(rgb(color))")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  private static func rgb(_ color: HexColor) -> String {
    String(format: "#%02x%02x%02x", color.red, color.green, color.blue)
  }

  private static func boolean(_ value: Bool) -> String { value ? "true" : "false" }

  private static func format(_ value: Double) -> String {
    String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
  }

  /// Ghostty 的逐行配置没有通用引号转义；字体名只接受单行可打印文本。
  private static func safeText(_ value: String, fallback: String) -> String {
    let filtered = value.unicodeScalars.filter {
      !CharacterSet.controlCharacters.contains($0) && $0 != "#"
    }
    let result = String(String.UnicodeScalarView(filtered))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return result.isEmpty ? fallback : String(result.prefix(256))
  }
}
