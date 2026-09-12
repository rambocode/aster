import AppKit
import Foundation
import Testing

@testable import Aster

/// 每个用例使用独立的 UserDefaults 域，避免读到开发机上的真实偏好。
private func isolatedDefaults() -> UserDefaults {
  let suite = "aster.tests.ghostty-config-diagnostics.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

@Test("libghostty 配置诊断只作警告：未知字段不阻断启动，并给出去路径的可读摘要")
@MainActor
func ghosttyConfigurationDiagnosticsAreNonFatal() throws {
  _ = NSApplication.shared
  let preferences = AppPreferences(defaults: isolatedDefaults())
  let base = GhosttyConfiguration.make(preferences: preferences)

  #expect(GhosttyApp.shared.prepare(configurationText: base + "aster-no-such-field = 1\n"))
  #expect(GhosttyApp.shared.isReady)
  #expect(GhosttyApp.shared.startupError == nil)
  #expect(GhosttyApp.shared.configurationDiagnostics.contains { $0.contains("aster-no-such-field") })
  let warning = try #require(GhosttyApp.shared.configurationWarning)
  #expect(warning.contains("aster-no-such-field"))
  #expect(!warning.contains("/"))

  // 修正配置后诊断随之清空，警告条不再显示。
  #expect(GhosttyApp.shared.prepare(configurationText: base))
  #expect(GhosttyApp.shared.configurationDiagnostics.isEmpty)
  #expect(GhosttyApp.shared.configurationWarning == nil)
}

@Test("配置诊断摘要去掉临时文件路径与行号，非文件型诊断原样保留")
@MainActor
func ghosttyConfigurationDiagnosticPrefixStripped() {
  #expect(
    GhosttyApp.stripConfigurationFilePrefix(
      "/var/folders/x/aster-ghostty-ABC.conf:1:aster-direct-child: unknown field")
      == "aster-direct-child: unknown field")
  #expect(
    GhosttyApp.stripConfigurationFilePrefix("font-family: not found") == "font-family: not found")
}
