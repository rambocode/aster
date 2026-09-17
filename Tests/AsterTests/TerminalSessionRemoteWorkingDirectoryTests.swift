// 远端 OSC 7 在 TerminalSession 的落地回归：远端目录必须被保留成独立投影，
// 返回本地 Shell 或 Pane 结束时必须完整清除，Ghostty 路径必须真的能收到远端上报。

import AppKit
import AsterCore
import Combine
import Testing

@testable import Aster
@testable import SwiftTerm

@Test("SwiftTerm 远端 OSC 7 记录远端目录并在回到本地时清除")
@MainActor
func terminalSessionKeepsRemoteWorkingDirectoryFromSwiftTerm() async throws {
  let endpoint = try #require(SSHResolvedEndpoint(hostName: "127.0.0.1", user: "root", port: 22))
  let session = TerminalSession(workingDirectory: "/tmp", sshEndpointResolver: { _ in endpoint })
  let source = AsterTerminalView(frame: .zero)

  session.send("ssh root@ubuntu@orb")
  for _ in 0..<20 where session.sshRemoteEndpoint == nil { await Task.yield() }

  session.hostCurrentDirectoryUpdate(source: source, directory: "file://ubuntu/var/log")
  for _ in 0..<20 where session.remoteWorkingDirectory == nil { await Task.yield() }

  #expect(session.remoteWorkingDirectory == RemoteWorkingDirectory(host: "ubuntu", path: "/var/log"))
  #expect(!session.currentWorkingDirectoryIsLocal)
  // 远端路径绝不能污染本机相对路径基准。
  #expect(session.currentWorkingDirectory == "/tmp")
  #expect(session.sshInvocation?.destination == "root@ubuntu@orb")

  session.hostCurrentDirectoryUpdate(source: source, directory: "file://localhost/Users/mike")
  for _ in 0..<20 where session.remoteWorkingDirectory != nil { await Task.yield() }

  #expect(session.remoteWorkingDirectory == nil)
  #expect(session.currentWorkingDirectoryIsLocal)
  #expect(session.currentWorkingDirectory == "/Users/mike")
  #expect(session.sshRemoteEndpoint == nil)
  #expect(session.sshInvocation == nil)
  #expect(session.remoteInspectionContext == nil)
  session.stop(immediately: true)
}

@Test("远端上下文只在端点与命令都成立时投影，Pane 停止后清空")
@MainActor
func terminalSessionProjectsRemoteInspectionContextForSSH() async throws {
  let endpoint = try #require(
    SSHResolvedEndpoint(hostName: "127.0.0.1", user: "root@ubuntu", port: 32_222))
  let session = TerminalSession(workingDirectory: "/tmp", sshEndpointResolver: { _ in endpoint })
  let source = AsterTerminalView(frame: .zero)

  // 只有远端目录、没有 ssh 命令时不成立上下文：旁路连接没有可复用的 argv。
  session.hostCurrentDirectoryUpdate(source: source, directory: "file://ubuntu/etc")
  for _ in 0..<20 where session.remoteWorkingDirectory == nil { await Task.yield() }
  #expect(session.remoteInspectionContext == nil)

  session.send("ssh -p 32222 root@ubuntu@orb")
  for _ in 0..<20 where session.sshRemoteEndpoint == nil { await Task.yield() }

  let context = try #require(session.remoteInspectionContext)
  guard case .ssh(let invocation, let resolved) = context else {
    Issue.record("远端上下文应为 ssh，实际为 \(context)")
    return
  }
  #expect(resolved == endpoint)
  #expect(invocation.configurationArguments == ["-p", "32222", "root@ubuntu@orb"])
  #expect(context.displayLabel == "127.0.0.1")

  session.stop(immediately: true)
  #expect(session.remoteInspectionContext == nil)
  #expect(session.remoteWorkingDirectory == nil)
  #expect(session.sshInvocation == nil)
}

@Test("无效 OSC 7 只降级本地标记，不产生远端目录")
@MainActor
func terminalSessionIgnoresInvalidWorkingDirectoryReports() async {
  let session = TerminalSession(workingDirectory: "/tmp")
  let source = AsterTerminalView(frame: .zero)

  session.hostCurrentDirectoryUpdate(source: source, directory: "https://example.com/home/mike")
  for _ in 0..<20 where session.currentWorkingDirectoryIsLocal { await Task.yield() }

  #expect(session.remoteWorkingDirectory == nil)
  #expect(!session.currentWorkingDirectoryIsLocal)
  #expect(session.currentWorkingDirectory == "/tmp")
  session.stop(immediately: true)
}

/// 计划 §10 第一条风险的实测：Ghostty 核心会丢弃 host 非本机的 OSC 7，
/// Aster 的 OSC observer 在 termio 原始字节层扫描，必须仍然收到该上报。
@Test("真实 Ghostty surface 的远端 OSC 7 仍到达 Aster observer")
@MainActor
func ghosttyObserverReceivesRemoteWorkingDirectoryOSC() async throws {
  _ = NSApplication.shared
  let suite = "AsterTests.remotepwd.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  defer { defaults.removePersistentDomain(forName: suite) }
  let model = AppModel(defaults: defaults)
  let preferences = AppPreferences(defaults: defaults)
  model.ensureInitialTab()
  defer { model.tabs.forEach { $0.stop(immediately: true) } }
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
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)

  // 远端上下文事件必须走独立通道：详情面板据它切换模式，Git/History 页不受影响。
  var remoteContextEvents: [UUID] = []
  let subscription = tab.remoteContextChanged.sink { remoteContextEvents.append($0) }
  defer { subscription.cancel() }

  // printf 后保持命令运行：命令结束会触发 precmd 再发一条本机 OSC 7，把远端投影清掉。
  #expect(view.typeText("printf '\\033]7;file://fakehost/tmp\\007'; sleep 5\n"))
  for _ in 0..<200 where session.remoteWorkingDirectory == nil {
    try await Task.sleep(for: .milliseconds(20))
  }

  #expect(
    session.remoteWorkingDirectory == RemoteWorkingDirectory(host: "fakehost", path: "/tmp"),
    "Ghostty observer 未收到远端 OSC 7：\(String(describing: session.remoteWorkingDirectory))"
  )
  #expect(!session.currentWorkingDirectoryIsLocal)

  for _ in 0..<50 where remoteContextEvents.isEmpty {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(remoteContextEvents.contains(tab.activePaneID))
}
