import AppKit
import Testing

@testable import Aster
@testable import AsterCore
@testable import SwiftTerm

// 交互式上下分屏的几何与状态回归:第二个 Pane 必须真实显示(有效高度 + 终端挂载),
// 只有一条分隔线,活动 Pane 不得处于褪色态。

@MainActor
private func deepViews(_ root: NSView) -> [NSView] {
  [root] + root.subviews.flatMap { deepViews($0) }
}

@Test("交互式上下分屏后第二个 Pane 真实显示且分隔线唯一")
@MainActor
func interactiveVerticalSplitShowsSecondPane() async throws {
  let suite = "InteractiveSplitProbe.\(UUID().uuidString)"
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

  // 交互式向下拆分(菜单/快捷键同路径)。
  model.splitSelectedTab(.down)
  try await Task.sleep(for: .milliseconds(150))
  window.contentView?.layoutSubtreeIfNeeded()

  let paneIDs = tab.layout.allPanes.map(\.id)
  #expect(paneIDs.count == 2)

  // 两个终端都必须挂在窗口里,且各占据有效高度(不塌成分隔条)。
  let terminals = deepViews(controller.view).compactMap { $0 as? AsterTerminalView }
  #expect(terminals.count == 2)
  for terminal in terminals {
    #expect(terminal.window === window)
    #expect(terminal.frame.height > 100, "终端高度塌陷: \(terminal.frame)")
    #expect(terminal.frame.width > 100)
  }

  // 只应存在一个上下分屏容器,且恰有两个可见 arranged 子视图(一条分隔线)。
  let splits = deepViews(controller.view).compactMap { $0 as? PersistedSplitView }
  #expect(splits.count == 1)
  if let split = splits.first {
    #expect(split.arrangedSubviews.count == 2)
    for arranged in split.arrangedSubviews {
      #expect(arranged.frame.height > 100, "分屏子视图塌陷: \(arranged.frame)")
    }
  }

  // 拆分后焦点落在新 Pane;活动 Pane 内容不得处于褪色态,非活动 Pane 必须褪色。
  let hosts = deepViews(controller.view).compactMap { $0 as? ActivePaneHostView }
  #expect(hosts.count == 2)
  for host in hosts {
    let content = host.subviews.first {
      !String(describing: type(of: $0)).contains("DragHandle")
    }
    let alpha = content?.alphaValue ?? -1
    if host.paneID == tab.activePaneID {
      #expect(alpha == 1, "活动 Pane 不应褪色")
    } else {
      #expect(alpha < 1, "非活动 Pane 应褪色")
    }
  }
}
