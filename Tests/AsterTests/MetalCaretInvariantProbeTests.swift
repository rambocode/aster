import AppKit
import Metal
import Testing

@testable import Aster
@testable import AsterCore
@testable import SwiftTerm

// Metal 渲染期间 AppKit caretView 必须保持隐藏:Metal 自绘光标,caretView 复显
// 会在真光标旁边多出一块整格色块(错位蓝块/灰块包竖线的现场形态)。

@Test("Metal 激活后经历完整生命周期 caretView 始终隐藏")
@MainActor
func metalKeepsCaretViewHiddenAcrossLifecycle() async throws {
  guard MTLCreateSystemDefaultDevice() != nil else { return }
  let suite = "MetalCaretProbe.\(UUID().uuidString)"
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
  try await Task.sleep(for: .milliseconds(150))

  let session = try #require(tab.activeRuntime?.terminalSession)
  let terminal = try #require(session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  // 生产默认使用 Core Graphics；此用例显式打开 vendored Metal backend，确保保留下来的
  // 后端回归测试不会因默认策略变化而变成无断言的空测试。
  try terminal.setUseMetal(true)
  #expect(terminal.metalView != nil)

  func report(_ step: String) {
    if terminal.metalView != nil {
      #expect(terminal.caretView?.isHidden == true, "\(step): Metal 激活时 caretView 不得可见")
    }
  }

  report("初始挂载")
  terminal.dataReceived(slice: Array("prompt$ ".utf8)[...])
  terminal.updateCursorPosition()
  report("输出后")
  session.apply(preferences: preferences)
  report("应用配置后")
  session.setPaneActive(false)
  report("Pane 失活后")
  session.setPaneActive(true)
  report("Pane 激活后")
  terminal.setWindowActive(false)
  terminal.setWindowActive(true)
  report("窗口焦点往返后")
  // 工作区刷新会把终端宿主摘下再挂回(拆分/主题切换的真实路径)。
  model.splitSelectedTab(.right)
  try await Task.sleep(for: .milliseconds(200))
  window.contentView?.layoutSubtreeIfNeeded()
  report("拆分刷新后")
}
