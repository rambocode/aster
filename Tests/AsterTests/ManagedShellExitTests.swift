// 受管终端（本机后台保活 / 远端机器）里 Shell 结束后的 Pane 去留与结束卡文案。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 使用独立 UserDefaults suite 建一个带单标签的工作区，避免污染真实工作区快照。
@MainActor
private func makeExitWorkspace() throws -> (model: AppModel, tab: TerminalTabItem) {
  let suite = "AsterManagedShellExitTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  return (model, tab)
}

/// 关闭动作延后一轮主队列执行；让出若干轮直到条件成立，避免依赖固定延时。
@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
  for _ in 0..<500 where !condition() {
    try? await Task.sleep(for: .milliseconds(10))
  }
}

/// 构造一个指向给定机器的受管终端引用；只用于绑定到会话，不触达真实服务。
private func makeManagedReference(machineProfileID: UUID) -> ManagedTerminalReference {
  ManagedTerminalReference(
    server: SessionServerReference(
      machineProfileID: machineProfileID, serverID: "srv-test", sessionID: "default"),
    terminalID: "terminal-\(UUID().uuidString)")
}

/// 按服务端对账结果构造「进程已退出」的解析值。
private func exitedResolution(
  _ reference: ManagedTerminalReference, code: Int32?
) -> ManagedTerminalResolution {
  .exited(ManagedTerminalStatus(reference: reference, state: .exited, exitCode: code))
}

/// 递归收集结束卡里所有文本与图标描述，用来断言文案。
@MainActor
private func overlayTexts(_ view: NSView) -> [String] {
  var texts: [String] = []
  if let field = view as? NSTextField { texts.append(field.stringValue) }
  if let image = view as? NSImageView, let label = image.image?.accessibilityDescription {
    texts.append(label)
  }
  for subview in view.subviews { texts.append(contentsOf: overlayTexts(subview)) }
  return texts
}

@Test("远端受管终端的进程退出后保留结束卡，不自动关闭 Pane")
@MainActor
func remoteManagedExitKeepsPane() async throws {
  let (model, tab) = try makeExitWorkspace()
  let firstPane = tab.activePaneID
  model.splitSelectedTab(.right)
  let session = try #require(tab.runtime(for: firstPane)?.terminalSession)
  // 注册一个走 SSH 传输的协调器：远端判定看传输实现，这里只构造、不连接。
  let machineID = UUID()
  ManagedTerminalCoordinatorRegistry.register(
    ManagedTerminalCoordinator(
      environment: [ManagedTerminalCoordinator.remoteTargetEnvironmentKey: "192.0.2.1"],
      machineProfileID: machineID),
    for: machineID)
  defer { ManagedTerminalCoordinatorRegistry.reset(machineProfileID: machineID) }
  let reference = makeManagedReference(machineProfileID: machineID)
  session.bindManagedTerminal(reference)
  #expect(!session.isLocalManagedTerminal)

  session.simulateManagedExitResolutionForTesting(
    exitedResolution(reference, code: 0), bridgeCode: 0, uptime: 60)
  for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(10)) }

  #expect(tab.layout.allPanes.count == 2)
  let overlay = try #require(TerminalLifecycleOverlayView(session: session))
  let texts = overlayTexts(overlay)
  #expect(texts.contains(L("远端进程已结束")))
}

@Test("本机后台保活的 Pane 里 exit 0 后像普通 Pane 一样关闭")
@MainActor
func localManagedExitClosesPane() async throws {
  let (model, tab) = try makeExitWorkspace()
  let firstPane = tab.activePaneID
  model.splitSelectedTab(.right)
  let secondPane = tab.activePaneID
  let session = try #require(tab.runtime(for: firstPane)?.terminalSession)
  let reference = makeManagedReference(machineProfileID: MachineProfile.localProfileID)
  session.bindManagedTerminal(reference)
  #expect(session.isLocalManagedTerminal)

  session.simulateManagedExitResolutionForTesting(
    exitedResolution(reference, code: 0), bridgeCode: 0, uptime: 60)
  await waitUntil { tab.layout.allPanes.count == 1 }

  #expect(tab.layout.allPanes.map(\.id) == [secondPane])
  #expect(model.tabs.contains { $0 === tab })
}

@Test("本机后台保活的 Pane 只是显示桥分离时不关闭，也不算结束")
@MainActor
func localManagedBridgeDetachKeepsPane() async throws {
  let (model, tab) = try makeExitWorkspace()
  let firstPane = tab.activePaneID
  model.splitSelectedTab(.right)
  let session = try #require(tab.runtime(for: firstPane)?.terminalSession)
  let reference = makeManagedReference(machineProfileID: MachineProfile.localProfileID)
  session.bindManagedTerminal(reference)

  session.simulateManagedExitResolutionForTesting(
    .attached(ManagedTerminalStatus(reference: reference, state: .running)),
    bridgeCode: 0, uptime: 60)
  for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(10)) }

  #expect(tab.layout.allPanes.count == 2)
  #expect(session.lifecycleState == .detached)
}

@Test("本机后台保活的结束卡用本机文案，不出现「远端」")
@MainActor
func localManagedEndedCardHasNoRemoteWording() async throws {
  let (model, tab) = try makeExitWorkspace()
  let firstPane = tab.activePaneID
  model.splitSelectedTab(.right)
  let session = try #require(tab.runtime(for: firstPane)?.terminalSession)
  let reference = makeManagedReference(machineProfileID: MachineProfile.localProfileID)
  session.bindManagedTerminal(reference)

  // 刚启动就非零退出：保留结束卡，便于检查文案。
  session.simulateManagedExitResolutionForTesting(
    exitedResolution(reference, code: 127), bridgeCode: 0, uptime: 0.2)
  for _ in 0..<20 { try? await Task.sleep(for: .milliseconds(10)) }
  #expect(tab.layout.allPanes.count == 2)
  let exited = overlayTexts(try #require(TerminalLifecycleOverlayView(session: session)))
  #expect(exited.contains(L("Shell 异常退出")))
  #expect(!exited.joined().contains("远端"))

  // 服务端已回收：补充说明同样不能说「远端」。
  session.simulateManagedExitResolutionForTesting(.missing(reference), bridgeCode: nil, uptime: 60)
  let missing = overlayTexts(try #require(TerminalLifecycleOverlayView(session: session)))
  #expect(!missing.joined().contains("远端"))
  #expect(missing.contains { $0.contains(L("Shell 已结束，后台保活服务已回收该终端。")) })
}
