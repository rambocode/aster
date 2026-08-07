import Foundation
import Testing

@testable import AsterCore

@Test("默认配置与参考应用的主工作区一致")
func defaultConfigurationMatchesReferenceWorkspace() {
  let configuration = AsterConfiguration.default

  #expect(configuration.tabBarLayout == .vertical)
  #expect(configuration.launchBehavior == .restoreLastSession)
  #expect(configuration.appearance.fontSize == 13)
  #expect(configuration.appearance.themeName == "Ayu Light")
  #expect(configuration.appearance.darkThemeName == "Ayu Dark")
  #expect(configuration.appearance.useSeparateDarkTheme)
  #expect(configuration.appearance.terminalIdentity == "xterm-256color")
  #expect(configuration.controls.allowMouseReporting)
  #expect(configuration.controls.optionAsMeta)
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
  configuration.editor.showLineNumbers = false

  let encoded = try JSONEncoder().encode(configuration)
  let decoded = try JSONDecoder().decode(AsterConfiguration.self, from: encoded)

  #expect(decoded == configuration)
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
