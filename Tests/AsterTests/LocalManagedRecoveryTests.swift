import AsterCore
import Foundation
import Testing

@testable import Aster

/// Local 受管 Pane 的结束卡按钮以前只有远端协调器响应；本机没有协调器，两个按钮都是死的。
@MainActor
private func makeModelWithDeadManagedTab() -> (AppModel, TerminalTabItem, TerminalSession) {
  let model = AppModel(defaults: UserDefaults(suiteName: "aster-local-managed-\(UUID().uuidString)")!)
  let reference = ManagedTerminalReference(
    server: SessionServerReference(
      machineProfileID: MachineProfile.localProfileID, serverID: "srv-local", sessionID: "default"),
    terminalID: "dead-terminal")
  let descriptor = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp", managedTerminal: reference)
  let tab = TerminalTabItem(
    snapshot: WorkspaceTabSnapshot(id: UUID(), title: "managed", layout: .leaf(descriptor)))
  model.receiveTransferredTab(tab)
  let session = tab.runtime(for: descriptor.id)!.terminalSession!
  // 测试环境不是打包 App，绑定器不会自动绑；直接模拟「引用存在但服务端已回收」。
  session.bindManagedTerminal(reference)
  session.simulateManagedExitForTesting(code: nil)
  return (model, tab, session)
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
  for _ in 0..<200 {
    if condition() { return }
    try? await Task.sleep(for: .milliseconds(10))
  }
}

@Test("Local 受管 Pane 点「重新启动 Shell」：清掉受管引用并换回原生 Shell")
@MainActor
func localManagedPaneRestartFallsBackToNativeShell() async throws {
  let (model, tab, session) = makeModelWithDeadManagedTab()
  #expect(session.isManagedTerminal)
  #expect(tab.layout.allPanes.first?.managedTerminal != nil)

  // 结束卡按钮就是 session.restart()；受管路径只发通知，由 AppModel 在 Local 上接手。
  _ = session.restart()
  await waitUntil { !session.isManagedTerminal }
  #expect(!session.isManagedTerminal)
  #expect(tab.layout.allPanes.first?.managedTerminal == nil)
  #expect(model.tabs.contains { $0.id == tab.id })
}

@Test("Local 受管 Pane 点「关闭标签」：标签被本地关闭")
@MainActor
func localManagedPaneCloseRemovesTab() async throws {
  let (model, tab, session) = makeModelWithDeadManagedTab()
  #expect(model.tabs.contains { $0.id == tab.id })
  session.requestManagedClose()
  await waitUntil { !model.tabs.contains { $0.id == tab.id } }
  #expect(!model.tabs.contains { $0.id == tab.id })
}
