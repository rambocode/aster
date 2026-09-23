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
    let fallbackFonts = fallbackFontFamilies(
      primary: font,
      configured: appearance.resolvedFontFamilyFallback,
      systemHan: systemHanFallbackFamily(base: preferences.terminalFontVariants.normal))
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
      // Aster 提供环境与登录参数，直接托管子进程才能获得真实退出状态。
      "aster-direct-child = true",
      "font-family = \(font)",
    ]
    // 回退字体必须紧跟主字体写成多行 font-family：libghostty 先按这个顺序查已加载字体，
    // 全部缺字才走运行时发现。不写的话，第一个触发发现的符号（如 `⏺`、`，`）会按
    // “等宽 + 字形最多”选中任意已装字体（例如日文版 Sarasa Mono J），之后所有汉字都
    // 粘在那个字体上，出现日文字形、个别简体字又窄又淡。
    lines += fallbackFonts.map { "font-family = \($0)" }
    lines += [
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
      // 触控板按像素滚动主屏 scrollback；滚轮、alternate screen 与鼠标上报仍按整行。
      "aster-smooth-scroll = \(boolean(controls.smoothScrolling))",
      "aster-scroll-past-last-line = \(scrollPastLastLine(controls.resolvedScrollPastLastLine))",
      "aster-scroll-past-first-line = \(scrollPastFirstLine(controls.resolvedScrollPastFirstLine, last: controls.resolvedScrollPastLastLine))",
      "right-click-action = \(controls.resolvedRightClickAction.rawValue)",
      "cursor-click-to-move = \(boolean(controls.resolvedCursorClickToMove))",
      // 普通文字 URL 与路径由 Aster 侧统一识别（下划线、预览、Command 点击、scheme 策略），
      // 关闭 Ghostty 自带的 URL 正则避免双重下划线与绕过 scheme 白名单；OSC 8 不受影响。
      "link-url = false",
      "title-report = \(boolean(shell.resolvedTitleReport))",
      "scrollback-limit = \(scrollbackBytes)",
      "shell-integration = \(shell.shellIntegration ? "detect" : "none")",
      // 右侧固定留出滚动条槽位：网格不伸进槽里，滚动条出现或消失都不遮字，也不触发 reflow。
      "window-padding-x = 0,\(Int(GhosttyScrollbar.reservedWidth))",
      "window-padding-y = 0",
      "unfocused-split-opacity = \(format(appearance.resolvedUnfocusedSplitOpacity))",
      "confirm-close-surface = false",
    ]
    for (index, color) in theme.ansiColors.enumerated() {
      lines.append("palette = \(index)=\(rgb(color))")
    }
    return lines.joined(separator: "\n") + "\n"
  }

  /// 「滚过末尾」投影为 Ghostty 的 `aster-scroll-past-last-line` 值。
  static func scrollPastLastLine(_ mode: TerminalScrollPastLastLine) -> String {
    switch mode {
    case .disabled: "disabled"
    case .lastLineWithContent: "last-line-with-content"
    case .lastLineInMiddle: "last-line-in-middle"
    case .cursorLine: "cursor-line"
    }
  }

  /// 「滚过开头」投影为 `aster-scroll-past-first-line` 值。「与末尾相同」按末尾模式换算，
  /// 规则与 SwiftTerm 适配器一致：末尾停在中部时开头也停中部，其余停在底部。
  static func scrollPastFirstLine(
    _ mode: TerminalScrollPastFirstLine, last: TerminalScrollPastLastLine
  ) -> String {
    switch mode {
    case .disabled: return "disabled"
    case .firstLineWithContent: return "first-line-with-content"
    case .firstLineInMiddle: return "first-line-in-middle"
    case .sameAsLastLine:
      switch last {
      case .disabled: return "disabled"
      case .lastLineInMiddle: return "first-line-in-middle"
      case .lastLineWithContent, .cursorLine: return "first-line-with-content"
      }
    }
  }

  /// C surface command 是 Shell 文本。双引号兼容 Ghostty 的 Shell 探测器，
  /// 同时转义所有会被 /bin/sh 展开的字符；每个路径/参数仍是单独一个 argv 元素。
  static func launchCommand(shell: String, arguments: [String]) -> String {
    ([shell] + arguments).map { value in
      let escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "$", with: "\\$")
        .replacingOccurrences(of: "`", with: "\\`")
      return "\"" + escaped + "\""
    }.joined(separator: " ")
  }

  /// 汇总写给 libghostty 的回退字体族：用户配置的回退在前，系统汉字默认字体垫底；
  /// 去掉与主字体或彼此重复的条目（不分大小写），非法字体名直接丢弃。
  static func fallbackFontFamilies(
    primary: String, configured: [String], systemHan: String?
  ) -> [String] {
    var seen: Set<String> = [primary.lowercased()]
    return (configured + [systemHan].compactMap { $0 }).compactMap { raw in
      let name = safeText(raw, fallback: "")
      guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { return nil }
      return name
    }
  }

  /// 询问 CoreText：当前语言环境下，`base` 缺汉字时系统会落到哪个字体族。
  ///
  /// 用系统答案而不是硬编码语言表：简体、繁体、日文、韩文用户各自得到本地字形，
  /// `base` 的 cascade 里已有覆盖汉字的用户回退字体时也会原样返回它（随后被去重）。
  /// LastResort 与以 `.` 开头的隐藏系统字体不是可写入配置的稳定名字，视为没有答案。
  static func systemHanFallbackFamily(base: NSFont) -> String? {
    let probe = "一" as CFString
    let resolved = CTFontCreateForString(
      base as CTFont, probe, CFRange(location: 0, length: CFStringGetLength(probe)))
    let family = CTFontCopyFamilyName(resolved) as String
    guard family != "LastResort", !family.hasPrefix(".") else { return nil }
    return family
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
