import AppKit
import Testing

@testable import Aster
@testable import AsterCore

// 字体设置回归:隐藏系统字体名不进入解析与 UI;主题逐样式字体参与解析链;
// 字体页各 scope 提供选择器而不是手输文本框。

@MainActor
private func isolatedPreferences() throws -> AppPreferences {
  let suite = "FontSettings.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  return AppPreferences(defaults: defaults)
}

@Test("配置里的隐藏系统字体名被视为未设置并自愈回自动匹配")
@MainActor
func hiddenSystemFontNamesAreSanitized() throws {
  let preferences = try isolatedPreferences()
  let clean = preferences.terminalFontVariants

  // 历史缺陷:自动匹配关闭时把 .AppleSystemUIFontMonospaced-* 固化进了配置。
  preferences.configuration.appearance.fontFamilyBold = ".AppleSystemUIFontMonospaced-Bold"
  preferences.configuration.appearance.fontFamilyItalic = ".AppleSystemUIFontMonospaced-RegularItalic"
  preferences.configuration.appearance.fontFamilyBoldItalic = ".SFNS-BoldItalic"
  let polluted = preferences.terminalFontVariants

  #expect(polluted.bold.fontName == clean.bold.fontName)
  #expect(polluted.italic.fontName == clean.italic.fontName)
  #expect(polluted.boldItalic.fontName == clean.boldItalic.fontName)
}

@Test("主题逐样式字体进入解析链,全局显式设置仍然优先")
@MainActor
func themeStyleFontsParticipateInResolution() throws {
  let preferences = try isolatedPreferences()
  // 走设置页同一条编辑路径:复制内置主题得到可编辑副本,再写入逐样式字体。
  var editable = preferences.duplicateTheme(preferences.activeTheme)
  editable.style.fontFamilyBold = "Menlo-Bold"
  #expect(preferences.updateTheme(editable))

  // 全局无显式粗体 → 用主题的 Menlo-Bold。
  preferences.configuration.appearance.fontFamilyBold = nil
  #expect(preferences.terminalFontVariants.bold.fontName == "Menlo-Bold")

  // 全局显式设置优先于主题。
  preferences.configuration.appearance.fontFamilyBold = "Courier"
  #expect(preferences.terminalFontVariants.bold.fontName.hasPrefix("Courier"))
}

@Test("Otty 主题的 token.font-mono-bold 系列键被解析进主题样式")
func ottyThemeParsesStyleFontKeys() throws {
  let toml = """
    [token]
    font-mono = ["JetBrains Mono", "monospace"]
    font-mono-bold = "Menlo-Bold"
    font-mono-italic = "Menlo-Italic"
    font-mono-bold-italic = "Menlo-BoldItalic"
    background = "#101010"
    foreground = "#f0f0f0"
    """
  let theme = try OttyThemeParser.parse(data: Data(toml.utf8), sourceName: "probe.ottytheme")
  #expect(theme.style.fontFamilies == ["JetBrains Mono", "monospace"])
  #expect(theme.style.fontFamilyBold == "Menlo-Bold")
  #expect(theme.style.fontFamilyItalic == "Menlo-Italic")
  #expect(theme.style.fontFamilyBoldItalic == "Menlo-BoldItalic")
}

@Test("字体页全局与主题 scope 使用字体选择器,不再要求手输字体名")
@MainActor
func fontScopesOfferPickers() throws {
  let preferences = try isolatedPreferences()
  let controller = SettingsViewController(preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 700, height: 460),
    styleMask: [.titled], backing: .buffered, defer: false)
  window.contentViewController = controller
  defer { window.orderOut(nil) }

  func pickerCount() -> Int {
    controller.view.descendantTree.count {
      String(describing: type(of: $0)).contains("FontComboBox")
    }
  }

  controller.fontScope = .global
  controller.showSection(.appearance)
  window.contentView?.layoutSubtreeIfNeeded()
  // 全局:主字体选择器始终存在;默认自动匹配开启,逐样式选择器隐藏。
  #expect(pickerCount() == 1)

  // 关闭自动匹配后展开三个逐样式选择器(总计 4 个)。
  preferences.configuration.appearance.fontFamilyBold = "Menlo-Bold"
  controller.showSection(.appearance)
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(pickerCount() == 4)

  controller.fontScope = .theme
  controller.showSection(.appearance)
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(pickerCount() >= 1, "主题 scope 应提供字体选择器")
}

extension NSView {
  fileprivate var descendantTree: [NSView] {
    subviews.flatMap { [$0] + $0.descendantTree }
  }
}
