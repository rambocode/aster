import AppKit
import GhosttyKit
import Testing

@testable import Aster
@testable import AsterCore

/// 端到端复现 0.6.6 的「点一下就进入选择模式」：点击切换 Pane 焦点会触发工作区整树刷新，
/// 终端视图在一次点击中途被拆下再装回，AppKit 不再送 mouseUp；Ghostty 以为左键仍按着，
/// 之后每次移动鼠标都在拉选区。修复后视图拆离窗口时自行补发 RELEASE。
@Test("终端视图在点击中途被整树刷新拆装后，移动鼠标不再拉出选区")
@MainActor
func ghosttyClickSurvivesWorkspaceRefreshWithoutStickySelection() async throws {
  _ = NSApplication.shared
  let suite = "AsterTests.clickrelease.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  let controller = WorkspaceViewController(model: model, preferences: preferences)
  controller.loadViewIfNeeded()

  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
  )
  window.contentViewController = controller
  window.makeKeyAndOrderFront(nil)
  defer {
    for tab in model.tabs { tab.stop(immediately: true) }
    window.orderOut(nil)
    defaults.removePersistentDomain(forName: suite)
  }
  window.layoutIfNeeded()

  func descendants(_ view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants)
  }
  func findSurfaceView() -> GhosttySurfaceView? {
    descendants(controller.view)
      .compactMap({ $0 as? GhosttySurfaceView }).first(where: { $0.surface != nil })
  }
  var surfaceView: GhosttySurfaceView?
  for _ in 0..<200 {
    if let view = findSurfaceView(), view.isProcessRunning {
      surfaceView = view
      break
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  let view = try #require(surfaceView, "工作区终端未启动")
  let surface = try #require(view.surface)

  // 打几行文字，让选区落在有内容的单元格上。
  let marker = "aster-click-release-marker"
  #expect(view.typeText("for i in 1 2 3 4 5 6; do echo \(marker); done\n"))
  var rendered = false
  for _ in 0..<150 {
    let lines = view.readText(includeScrollback: false)?.split(separator: "\n") ?? []
    if lines.filter({ $0.trimmingCharacters(in: .whitespaces) == marker }).count >= 6 {
      rendered = true
      break
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  try #require(rendered, "等待输出行进入屏幕缓冲")

  func mouseEvent(_ type: NSEvent.EventType, at local: NSPoint) throws -> NSEvent {
    try #require(NSEvent.mouseEvent(
      with: type, location: view.convert(local, to: nil), modifierFlags: [],
      timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
      context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
  }
  // 单击左上角（不松手）。
  let pressPoint = NSPoint(x: 6, y: view.bounds.height - 6)
  view.mouseDown(with: try mouseEvent(.leftMouseDown, at: pressPoint))
  #expect(view.leftMouseReleasePending)

  // 模拟点击切换焦点引发的整树刷新：Pane 树连同终端视图被拆下再装回，mouseUp 不会再送到。
  controller.scheduleRefresh()
  try await Task.sleep(for: .milliseconds(120))
  let reattached = try #require(findSurfaceView(), "刷新后终端视图应被装回")
  #expect(reattached === view, "Session 长期持有的终端视图应被复用")
  #expect(!view.leftMouseReleasePending, "拆离窗口时必须已补发 RELEASE")

  // 之后单纯移动鼠标（无按键）到远处：不能拉出选区。
  let farPoint = NSPoint(x: min(view.bounds.width - 6, 400), y: max(6, view.bounds.height - 120))
  view.mouseMoved(with: try mouseEvent(.mouseMoved, at: farPoint))
  try await Task.sleep(for: .milliseconds(60))
  #expect(!ghostty_surface_has_selection(surface), "移动鼠标不应在无按键时扩展选区")
}
