// 回退字体投影：Aster 的回退字体与系统汉字默认字体必须以多行 font-family 交给 libghostty。

import AppKit
import Foundation
import Testing

@testable import Aster

/// 每个用例使用独立的 UserDefaults 域，避免读到开发机上的真实偏好。
private func isolatedDefaults() -> UserDefaults {
  let suite = "aster.tests.ghostty-font-fallback.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

/// 取出配置文本里全部 font-family 的值，保持原有顺序。
private func fontFamilies(in configuration: String) -> [String] {
  configuration.split(separator: "\n").compactMap { line in
    line.hasPrefix("font-family = ") ? String(line.dropFirst("font-family = ".count)) : nil
  }
}

@Test("回退字体族：用户回退在前、系统汉字字体垫底，并去掉重复与非法名字")
func ghosttyFallbackFontFamiliesAreOrderedAndDeduplicated() {
  #expect(
    GhosttyConfiguration.fallbackFontFamilies(
      primary: "JetBrains Mono",
      configured: ["Menlo", "menlo", "jetbrains mono", " # ", "Sarasa Mono SC"],
      systemHan: "PingFang SC") == ["Menlo", "Sarasa Mono SC", "PingFang SC"])
  // 用户回退已经覆盖汉字时，CoreText 返回的就是它，不能再重复写一行。
  #expect(
    GhosttyConfiguration.fallbackFontFamilies(
      primary: "JetBrains Mono", configured: ["PingFang SC"], systemHan: "PingFang SC")
      == ["PingFang SC"])
  #expect(
    GhosttyConfiguration.fallbackFontFamilies(
      primary: "JetBrains Mono", configured: [], systemHan: nil).isEmpty)
}

@Test("libghostty 配置在主字体之后固定汉字回退字体，不把选择权留给运行时发现")
@MainActor
func ghosttyConfigurationPinsHanFallbackAfterPrimaryFont() throws {
  _ = NSApplication.shared
  let preferences = AppPreferences(defaults: isolatedDefaults())
  preferences.configuration.appearance.fontFamilyFallback = ["Courier New"]

  let families = fontFamilies(in: GhosttyConfiguration.make(preferences: preferences))
  let systemHan = try #require(
    GhosttyConfiguration.systemHanFallbackFamily(base: preferences.terminalFontVariants.normal))

  // 测试宿主未必注册了内置 JetBrains Mono（此时主字体是 Menlo），因此主字体取实际解析值。
  let normal = preferences.terminalFontVariants.normal
  let primary = normal.familyName ?? normal.fontName
  #expect(!systemHan.hasPrefix("."))
  #expect(systemHan != "LastResort")
  #expect(families == [primary, "Courier New", systemHan])
}
