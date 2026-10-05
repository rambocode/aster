// 界面字号缩放入口、加深文字色与设置页桥接的应用层测试。
// `InterfaceScale` 与 `ThemeRuntime` 是进程级状态，每个用例结束前都要还原，避免影响后续用例。
import AppKit
import AsterCore
import Foundation
import Testing
import WebKit

@testable import Aster

@Test("默认档下界面字体与系统字体完全一致，测试与旧截图不受影响")
@MainActor
func interfaceFontMatchesSystemFontAtStandardScale() {
  #expect(InterfaceScale.current == .standard)
  #expect(NSFont.interface(ofSize: 11.5, weight: .medium) == NSFont.systemFont(ofSize: 11.5, weight: .medium))
  #expect(NSFont.interfaceMonospaced(ofSize: 10.5) == NSFont.monospacedSystemFont(ofSize: 10.5, weight: .regular))
  #expect(InterfaceScale.length(28) == 28)
  #expect(makeLabel("x", size: 12).font?.pointSize == 12)
}

@Test("放大档位下字号取整到半点，尺寸取整到整点，带上限的尺寸不越界")
@MainActor
func interfaceScaleRoundsFontsAndLengths() {
  InterfaceScale.install(.largest)
  defer { InterfaceScale.install(.standard) }

  #expect(InterfaceScale.font(11) == 16.5)
  #expect(InterfaceScale.font(10.5) == 16)
  #expect(InterfaceScale.length(28) == 42)
  #expect(InterfaceScale.length(28, max: 32) == 32)
  #expect(NSFont.interface(ofSize: 12).pointSize == 18)
  // makeLabel 内部缩放一次，调用方传的仍是默认档字号。
  #expect(makeLabel("x", size: 12).font?.pointSize == 18)

  InterfaceScale.install(.small)
  #expect(InterfaceScale.font(10) == 9)
}

@Test("只有新档位与生效档位不同时才提示重启")
@MainActor
func interfaceScaleRelaunchPromptOnlyWhenScaleChanges() {
  #expect(!InterfaceScale.relaunchRequired(for: .standard))
  #expect(InterfaceScale.relaunchRequired(for: .large))
}

@Test("加深界面文字只影响次要与三级色，关闭后恢复主题原色")
@MainActor
func themeRuntimeStrengthensSecondaryTextOnlyWhenEnabled() throws {
  let suite = "InterfaceScale.contrast.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let preferences = AppPreferences(defaults: defaults)
  defer { ThemeRuntime.shared.setStrengthensText(false) }
  let light = try #require(NSAppearance(named: .aqua))

  func hex(_ role: ThemeRuntime.Role) -> HexColor {
    HexColor(nsColor: ThemeRuntime.shared.color(for: role, appearance: light))
  }

  // 系统「增强对比度」已开的机器上基线本来就是加深的，这里直接操纵运行时来隔离开关语义。
  ThemeRuntime.shared.setStrengthensText(false)
  let plainSecondary = hex(.secondary)
  let plainForeground = hex(.foreground)
  let plainPanel = hex(.panel)

  preferences.configuration.appearance.interfaceHighContrastText = true
  #expect(preferences.strengthensInterfaceText)
  let strongSecondary = hex(.secondary)
  #expect(strongSecondary != plainSecondary)
  #expect(hex(.foreground) == plainForeground)
  #expect(hex(.panel) == plainPanel)
  if plainPanel.alpha == 255 {
    #expect(
      InterfaceTextContrast.contrastRatio(strongSecondary, plainPanel)
        >= InterfaceTextContrast.minimumRatio)
  }

  ThemeRuntime.shared.setStrengthensText(false)
  #expect(hex(.secondary) == plainSecondary)
}

@Test("设置页写入界面字号后配置、快照与网页缩放同步，五档都在网页选项里")
@MainActor
func settingsBridgeRoundTripsInterfaceTextSettings() throws {
  let suite = "InterfaceScale.settings.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let preferences = AppPreferences(defaults: defaults)
  defer { ThemeRuntime.shared.setStrengthensText(false) }
  let controller = SettingsViewController(preferences: preferences)
  controller.loadViewIfNeeded()
  let webView = try #require(controller.settingsWebViewForTesting)
  let script = try String(
    contentsOf: repositoryRoot().appendingPathComponent("Resources/settings-ui/settings.js"),
    encoding: .utf8)
  #expect(webView.pageZoom == 1)

  for scale in InterfaceTextScale.allCases {
    try controller.applySettingForTesting(key: "appearance.interfaceTextScale", value: scale.rawValue)
    #expect(preferences.configuration.appearance.resolvedInterfaceTextScale == scale)
    let values = try #require(controller.settingsSnapshotForTesting()["values"] as? [String: Any])
    #expect(values["appearance.interfaceTextScale"] as? String == scale.rawValue)
    #expect(script.contains("[\"\(scale.rawValue)\""))
    // 设置页不等重启：写入后网页立刻按新档位缩放。
    #expect(abs(webView.pageZoom - CGFloat(scale.factor)) < 0.001)
  }
  #expect(throws: (any Error).self) {
    try controller.applySettingForTesting(key: "appearance.interfaceTextScale", value: "huge")
  }

  try controller.applySettingForTesting(key: "appearance.interfaceHighContrastText", value: true)
  #expect(preferences.configuration.appearance.resolvedInterfaceHighContrastText)
  let values = try #require(controller.settingsSnapshotForTesting()["values"] as? [String: Any])
  #expect(values["appearance.interfaceHighContrastText"] as? Bool == true)
  #expect(values["appearance.interfaceStrongTextActive"] as? Bool == true)
}

/// 仓库根目录，用于读取打包前的资源文件。
private func repositoryRoot() -> URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
