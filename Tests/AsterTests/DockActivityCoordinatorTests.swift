// Dock 任务状态聚合器的点击行为测试：只有真正标红的未确认错误才允许切换标签。

import AppKit
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

@Test("Dock 图标标红时点击跳到失败标签，确认后再切回 Aster 不再抢焦点")
@MainActor
func dockClickSelectsUnacknowledgedErrorTabOnlyOnce() async throws {
  let (suiteName, defaults) = try dockActivityDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.appearance.redDockIconOnError = true
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let errorTab = try #require(model.selectedTab)
  let session = try #require(errorTab.activeSession)
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  model.newTab(workingDirectory: "/tmp")
  let workingTab = try #require(model.selectedTab)
  #expect(workingTab.id != errorTab.id)

  let coordinator = DockActivityCoordinator(model: model, preferences: preferences)
  coordinator.start()
  defer {
    coordinator.stop()
    session.stop(immediately: true)
  }

  terminalView.onTerminalBadgeDirective?(.set(.error))
  try await Task.sleep(for: .milliseconds(50))
  #expect(coordinator.currentState == .error)

  // 新错误让图标变红，这一次点击跳到失败标签是用户预期的行为。
  #expect(coordinator.acknowledgeAndSelectNextError())
  #expect(model.selectedTab?.id == errorTab.id)
  try await Task.sleep(for: .milliseconds(50))
  #expect(coordinator.currentState == .idle)

  // 用户回到自己正在用的标签后再切回 Aster：错误已确认，焦点必须留在原处。
  model.select(workingTab)
  #expect(!coordinator.acknowledgeAndSelectNextError())
  #expect(model.selectedTab?.id == workingTab.id)
}

@Test("关闭出错标红时切回 Aster 不跳转到失败标签")
@MainActor
func dockClickKeepsFocusWhenRedIconDisabled() async throws {
  let (suiteName, defaults) = try dockActivityDefaults()
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  preferences.configuration.appearance.redDockIconOnError = false
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let errorTab = try #require(model.selectedTab)
  let session = try #require(errorTab.activeSession)
  let terminalView = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView
  )
  model.newTab(workingDirectory: "/tmp")
  let workingTab = try #require(model.selectedTab)

  let coordinator = DockActivityCoordinator(model: model, preferences: preferences)
  coordinator.start()
  defer {
    coordinator.stop()
    session.stop(immediately: true)
  }

  terminalView.onTerminalBadgeDirective?(.set(.error))
  try await Task.sleep(for: .milliseconds(50))
  // 图标没有任何错误提示，点击就只是普通的「切回应用」。
  #expect(coordinator.currentState == .idle)
  #expect(!coordinator.acknowledgeAndSelectNextError())
  #expect(model.selectedTab?.id == workingTab.id)
}

@MainActor
private func dockActivityDefaults() throws -> (String, UserDefaults) {
  let suiteName = "DockActivityCoordinatorTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  return (suiteName, defaults)
}
