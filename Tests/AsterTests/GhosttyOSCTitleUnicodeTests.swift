import AppKit
import Testing

@testable import Aster
@testable import AsterCore

/// 回归:OSC 0/2 标题包含续字节为 0x9C 的 UTF-8 字符(如 Claude Code 的 "✳"，
/// E2 9C B3)时,Aster OSC observer 不得把 0x9C 当作 ST 提前截断,标题不得出现 U+FFFD。
@Test("OSC 标题中的 ✳ 不被 0x9C 截断为乱码")
@MainActor
func ghosttyOSCTitleKeepsMultibyteCharacters() async throws {
  _ = NSApplication.shared
  let suite = "AsterTests.osctitle.\(UUID().uuidString)"
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
  let session = try #require(model.selectedTab?.activeSession)

  // printf 后保持命令运行,避免 zsh precmd 立刻用 cwd 覆盖标题导致轮询漏过瞬态。
  #expect(view.typeText("printf '\\033]0;\\xe2\\x9c\\xb3 Aster Title\\007'; sleep 5\n"))
  var title = ""
  for _ in 0..<150 {
    title = session.terminalTitle
    if title.contains("Aster Title") || title.contains("\u{FFFD}") { break }
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(title == "✳ Aster Title", "标题被截断或乱码: \(title)")
  #expect(!title.contains("\u{FFFD}"))
}
