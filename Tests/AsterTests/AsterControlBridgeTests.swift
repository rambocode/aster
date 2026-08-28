import AsterCore
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 桥：短 ID 分配、环境上下文、事件发布与去重、退役。
@Suite(.serialized)
@MainActor
struct AsterControlBridgeTests {
  @Test("attach 后分配 w1/t1/p1，控制上下文注入到 Session 环境")
  func assignsIdentifiersAndContext() throws {
    let workspace = try ControlTestWorkspace()
    defer { workspace.tearDown() }
    let bridge = AsterControlBridge(socketPath: "/tmp/aster-test.sock", binaryPath: "/usr/local/bin/aster-cli")
    bridge.attach(model: workspace.model)
    bridge.attach(model: workspace.model)  // 幂等
    #expect(bridge.attachedModels.count == 1)
    let session = try #require(workspace.model.selectedTab?.activeSession)
    let context = try #require(session.controlContextProvider?())
    #expect(context.windowID == "w1")
    #expect(context.tabID == "w1:t1")
    #expect(context.paneID == "w1:p1")
    #expect(context.socketPath == "/tmp/aster-test.sock")
    var environment = ["PATH": "/usr/bin"]
    context.apply(to: &environment)
    #expect(environment["ASTER_ENV"] == "1")
    #expect(environment["ASTER_PANE_ID"] == "w1:p1")
    #expect(environment["ASTER_BIN_PATH"] == "/usr/local/bin/aster-cli")
    // 完整环境拼接：ASTER_SESSION_ID 仍是 UUID，ASTER_PANE_ID 被短 ID 覆盖。
    let full = TerminalIdentityPolicy.environment(
      inherited: [:], term: "xterm", version: "1", paneIdentifier: session.id.uuidString,
      bundledTerminfoDirectories: [], controlContext: context)
    #expect(full["ASTER_SESSION_ID"] == session.id.uuidString)
    #expect(full["ASTER_PANE_ID"] == "w1:p1")
    // 未接桥的模型：不注入。
    let bare = TerminalIdentityPolicy.environment(
      inherited: [:], term: "xterm", version: "1", paneIdentifier: "x", bundledTerminfoDirectories: [])
    #expect(bare["ASTER_ENV"] == nil)
  }

  @Test("新标签/分屏/关闭发布 pane.created、pane.focused、pane.closed；关闭后 ID 退役不复用")
  func publishesLifecycleEvents() async throws {
    let workspace = try ControlTestWorkspace()
    defer { workspace.tearDown() }
    let bridge = AsterControlBridge(socketPath: "/tmp/s.sock", binaryPath: nil)
    bridge.activeModelProvider = { [weak model = workspace.model] in model }
    bridge.attach(model: workspace.model)
    var received: [AsterControlEvent] = []
    bridge.hub.subscribe(id: UUID(), kinds: []) { received.append($0) }

    workspace.model.newTab(workingDirectory: "/tmp")
    await pumpControlEvents()
    #expect(received.contains { $0.event == .paneCreated && $0.data["pane_id"]?.stringValue == "w1:p2" })
    #expect(received.contains { $0.event == .paneFocused && $0.data["pane_id"]?.stringValue == "w1:p2" })

    workspace.model.splitSelectedTab(.right)
    await pumpControlEvents()
    #expect(received.contains { $0.event == .paneCreated && $0.data["pane_id"]?.stringValue == "w1:p3" })
    #expect(try bridge.resolve(selector: "w1:t2").paneID.description == "w1:p3")

    let second = try #require(workspace.model.tabs.last)
    workspace.model.closeTab(id: second.id)
    await pumpControlEvents()
    let closedIDs = received.filter { $0.event == .paneClosed }.compactMap { $0.data["pane_id"]?.stringValue }
    #expect(Set(closedIDs) == ["w1:p2", "w1:p3"])
    #expect(bridge.registry.paneUUID(for: ControlPaneID(parsing: "w1:p2")!) == nil)
    workspace.model.newTab(workingDirectory: "/tmp")
    await pumpControlEvents()
    #expect(received.contains { $0.event == .paneCreated && $0.data["pane_id"]?.stringValue == "w1:p4" })
    // 序列号单调。
    let sequences = received.map(\.sequence)
    #expect(sequences == sequences.sorted() && Set(sequences).count == sequences.count)
  }

  @Test("agent 状态变化发布 pane.agent_status_changed 并递增 state_change_seq；重复状态不重发")
  func publishesAgentStatusChanges() async throws {
    let workspace = try ControlTestWorkspace()
    defer { workspace.tearDown() }
    let bridge = AsterControlBridge(socketPath: "/tmp/s.sock", binaryPath: nil)
    bridge.attach(model: workspace.model)
    var changes: [AsterControlEvent.AgentStatusChange] = []
    bridge.hub.subscribe(id: UUID(), kinds: [.paneAgentStatusChanged]) { event in
      if let change = try? event.data.decoded(as: AsterControlEvent.AgentStatusChange.self) { changes.append(change) }
    }
    let (_, view) = try workspace.makeActiveTerminalView()
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .processing))
    await pumpControlEvents()
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .processing))
    await pumpControlEvents()
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .awaitingInput))
    await pumpControlEvents()
    #expect(changes.map(\.status) == [.working, .blocked])
    #expect(changes.map(\.stateChangeSeq) == [1, 2])
    #expect(changes.last?.previous == .working)
    #expect(changes.last?.detection == .hook)
    #expect(changes.last?.agent?.paneID == "w1:p1")
    let record = try bridge.resolve(selector: "codex")
    #expect(bridge.agentInfo(record)?.stateChangeSeq == 2)
  }

  @Test("跨窗口转移：新窗口分配 w2:t1，旧 ID 仍可解析")
  func tabTransferKeepsAlias() async throws {
    let first = try ControlTestWorkspace()
    defer { first.tearDown() }
    let second = try ControlTestWorkspace()
    defer { second.tearDown() }
    let bridge = AsterControlBridge(socketPath: "/tmp/s.sock", binaryPath: nil)
    bridge.attach(model: first.model)
    bridge.attach(model: second.model)
    let tab = try #require(first.model.detachTabForTransfer(id: first.model.tabs[0].id))
    second.model.receiveTransferredTab(tab)
    await pumpControlEvents()
    #expect(try bridge.resolve(selector: "w2:t2").tab === tab)
    #expect(try bridge.resolve(selector: "w1:p1").tab === tab)
    #expect(try bridge.resolve(selector: "w2:p2").tab === tab)
    #expect(bridge.snapshot().windows.map(\.windowID) == ["w1", "w2"])
    #expect(bridge.snapshot().windows[1].tabs.count == 2)
  }

  @Test("事件枢纽：注册前已取消的任务立即抛 CancellationError；unsubscribe 后不再收事件")
  func hubCancellationAndUnsubscribe() async throws {
    let hub = AsterControlEventHub()
    let task = Task { @MainActor in
      try await Task.sleep(for: .milliseconds(200))
      return try await hub.waitForEvent(timeoutMilliseconds: 10_000) { _ in true }
    }
    task.cancel()
    let started = ContinuousClock.now
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(ContinuousClock.now - started < .seconds(2))

    var received = 0
    let id = UUID()
    hub.subscribe(id: id, kinds: []) { _ in received += 1 }
    hub.publish(.paneUpdated, data: [:])
    hub.unsubscribe(id: id)
    hub.publish(.paneUpdated, data: [:])
    #expect(received == 1)
    #expect(hub.subscriberCount == 0)
  }
}
