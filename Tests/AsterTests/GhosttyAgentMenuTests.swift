import AppKit
import Testing

@testable import Aster
@testable import AsterCore

/// 验证 Ghostty 引擎路径下「Shell 里调用 Agent」主链路:lifecycle hook 的 OSC 6974
/// 经真实 surface 进入 TerminalSession,聚焦 Pane 能产出 Shell 菜单所需的会话上下文。
@Test("Ghostty 路径下 OSC 6974 建立 Agent 会话上下文")
@MainActor
func ghosttyAgentLifecycleEstablishesMenuContext() async throws {
  _ = NSApplication.shared
  let suite = "AsterTests.agent.\(UUID().uuidString)"
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

  func agentTestDescendants(_ view: NSView) -> [NSView] {
    view.subviews + view.subviews.flatMap(agentTestDescendants)
  }
  var surfaceView: GhosttySurfaceView?
  for _ in 0..<200 {
    if let view = agentTestDescendants(controller.view)
      .compactMap({ $0 as? GhosttySurfaceView }).first(where: { $0.surface != nil }),
      view.isProcessRunning
    {
      surfaceView = view
      break
    }
    try await Task.sleep(for: .milliseconds(20))
  }
  _ = try #require(surfaceView, "工作区终端未启动")
  let session = try #require(model.selectedTab?.activeSession)

  // Surface 的进程 running 只表示 PTY 已创建，zsh 仍可能正在加载配置。必须等真实
  // OSC 133 prompt marker 建立 Shell Integration 后再注入命令，否则低负载机器上会把
  // 测试文本写进尚未进入输入态的启动窗口，形成与 renderer 无关的时序假失败。
  for _ in 0..<150 where !session.shellIntegrationDetected {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(session.shellIntegrationDetected)

  // Hook 是向所属 TTY 写原始字节，不经过键盘布局或输入法。这里走生产的自动化字节
  // 入口，避免用逐键 typeText 把输入法时序误当成 OSC lifecycle 回归。
  let directive =
    "printf '\\033]6974;AgentState=processing;Provider=claudeCode;SessionID=test-session-42\\007'\n"
  #expect(session.sendAutomationBytes(Array(directive.utf8)))
  for _ in 0..<150 where session.activeAgentProvider == nil {
    try await Task.sleep(for: .milliseconds(20))
  }

  #expect(session.activeAgentProvider == .claudeCode)
  #expect(session.activeAgentSessionID == "test-session-42")
  let context = try #require(model.focusedAgentSessionContext, "Shell 菜单缺少 Agent 上下文")
  #expect(context.provider == .claudeCode)
  #expect(context.sessionID == "test-session-42")
}
