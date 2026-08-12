import AppKit
import GhosttyKit
import Testing

@testable import Aster
@testable import AsterCore

/// 端到端复现:真实 Ghostty surface 打印 URL 后,带 Command 修饰键上报鼠标位置,
/// 验证 mouse_over_link action 能回流到 GhosttySurfaceView 并显示预览徽章。
@Test("Command 悬停真实 surface 中的 URL 显示链接预览")
@MainActor
func ghosttyCommandHoverShowsLinkPreview() async throws {
  _ = NSApplication.shared
  let suite = "AsterTests.linkhover.\(UUID().uuidString)"
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
  defer { window.orderOut(nil) }
  window.layoutIfNeeded()

  func descendants(_ view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(descendants)
  }
  var surfaceView: GhosttySurfaceView?
  for _ in 0..<200 {
    if let view = descendants(controller.view)
      .compactMap({ $0 as? GhosttySurfaceView }).first(where: { $0.surface != nil }),
      view.isProcessRunning
    {
      surfaceView = view
      break
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  let view = try #require(surfaceView, "工作区终端未启动")

  // 打印一个独占一行的 URL,并等待它进入屏幕缓冲。
  let url = "https://example.com/aster-link-hover"
  #expect(view.typeText("printf '\\n\(url)\\n'\n"))
  var rendered = false
  for _ in 0..<150 {
    if view.readText(includeScrollback: false)?.contains(url) == true {
      rendered = true
      break
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(rendered, "URL 未出现在终端缓冲中")

  // 用真实 NSEvent 走 mouseMoved(with:) 处理路径(含窗口坐标换算与修饰键提取),
  // 带 Command 扫描视口上半区;命中 URL 单元格时 core 应发出 mouse_over_link。
  outer: for yStep in stride(from: 8.0, to: min(view.bounds.height, 400), by: 8.0) {
    for xStep in stride(from: 4.0, to: min(view.bounds.width, 500), by: 8.0) {
      let localPoint = NSPoint(x: xStep, y: view.bounds.height - yStep)
      let windowPoint = view.convert(localPoint, to: nil)
      guard let event = NSEvent.mouseEvent(
        with: .mouseMoved,
        location: windowPoint,
        modifierFlags: [.command],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
      ) else { continue }
      view.mouseMoved(with: event)
      // action 经主队列异步回流,让出 runloop 再检查。
      try await Task.sleep(for: .milliseconds(1))
      if view.linkPreviewText != nil { break outer }
    }
  }
  #expect(view.linkPreviewText == url, "Command 悬停未显示链接预览")

  // 裸文件路径不在 Ghostty 的 URL 正则内,由 Aster 侧悬停检测补足。
  view.removeLinkPreview()
  let path = "/usr/local/bin"
  #expect(view.typeText("printf '\\n\(path)\\n'\n"))
  var pathRendered = false
  for _ in 0..<150 {
    if view.readText(includeScrollback: false)?.contains(path) == true {
      pathRendered = true
      break
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(pathRendered, "路径未出现在终端缓冲中")
  outerPath: for yStep in stride(from: 8.0, to: min(view.bounds.height, 500), by: 8.0) {
    for xStep in stride(from: 4.0, to: min(view.bounds.width, 500), by: 8.0) {
      let localPoint = NSPoint(x: xStep, y: view.bounds.height - yStep)
      let windowPoint = view.convert(localPoint, to: nil)
      guard let event = NSEvent.mouseEvent(
        with: .mouseMoved,
        location: windowPoint,
        modifierFlags: [.command],
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: window.windowNumber,
        context: nil,
        eventNumber: 0,
        clickCount: 0,
        pressure: 0
      ) else { continue }
      view.mouseMoved(with: event)
      try await Task.sleep(for: .milliseconds(1))
      if view.linkPreviewText == path { break outerPath }
    }
  }
  #expect(view.linkPreviewText == path, "Command 悬停未显示路径预览")
}
