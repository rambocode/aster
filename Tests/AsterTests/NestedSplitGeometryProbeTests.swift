import AppKit
import Testing

@testable import Aster
@testable import AsterCore
@testable import SwiftTerm

// 嵌套分屏几何回归:已有左右两个 Pane 时聚焦第一个再拆分,新 Pane 必须占据有效宽度,
// 不得塌成一条分隔条(实测缺陷:新 Pane 只剩 6pt)。

@MainActor
private func deepViews(_ root: NSView) -> [NSView] {
  [root] + root.subviews.flatMap { deepViews($0) }
}

@Test("两 Pane 下聚焦第一个再拆分,新 Pane 占据有效宽度")
@MainActor
func nestedSplitFromFirstPaneShowsNewPane() async throws {
  let suite = "NestedSplitProbe.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 1_200, height: 800),
    styleMask: [.titled, .resizable, .fullSizeContentView],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.contentView?.layoutSubtreeIfNeeded()
  let tab = try #require(model.selectedTab)
  defer {
    for runtime in tab.runtimes.values { runtime.terminalSession?.stop(immediately: true) }
    window.orderOut(nil)
  }
  try await Task.sleep(for: .milliseconds(120))

  // 第一次拆分:A | B。
  let firstPane = tab.activePaneID
  model.splitSelectedTab(.right)
  try await Task.sleep(for: .milliseconds(150))
  window.contentView?.layoutSubtreeIfNeeded()
  #expect(tab.layout.allPanes.count == 2)

  // 聚焦回第一个 Pane,再拆分:(A | New) | B。
  tab.setActivePane(firstPane)
  try await Task.sleep(for: .milliseconds(60))
  model.splitSelectedTab(.right)
  try await Task.sleep(for: .milliseconds(150))
  window.contentView?.layoutSubtreeIfNeeded()
  try await Task.sleep(for: .milliseconds(60))

  let paneIDs = tab.layout.allPanes.map(\.id)
  #expect(paneIDs.count == 3)
  let newPane = tab.activePaneID
  #expect(newPane != firstPane)

  // 症状断言:三个 Pane 宿主与终端都必须占据有效宽度,不得塌成分隔条。
  let hosts = deepViews(controller.view).compactMap { $0 as? ActivePaneHostView }
  #expect(hosts.count == 3)
  for host in hosts {
    #expect(host.frame.width > 100, "Pane \(host.paneID) 宽度塌陷: \(host.frame)")
    #expect(host.frame.height > 100, "Pane \(host.paneID) 高度塌陷: \(host.frame)")
  }
  let terminals = deepViews(controller.view).compactMap { $0 as? AsterTerminalView }
  #expect(terminals.count == 3)
  for terminal in terminals {
    #expect(terminal.frame.width > 100, "终端宽度塌陷: \(terminal.frame)")
  }
}
