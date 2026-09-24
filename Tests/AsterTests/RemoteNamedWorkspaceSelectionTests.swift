// 远端命名工作区的选中语义：只显示选中工作区、隐藏只分离不结束、选中项消失退回第一个、按机器持久化。
import AsterCore
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 收集 `selectedWorkspaceDidChange` 通知内容的盒子。
@MainActor
private final class SelectionNotificationRecorder {
  var entries: [(machineID: UUID?, workspaceID: String?, shownTabs: [String?])] = []
}

@Suite(.serialized)
@MainActor
struct RemoteNamedWorkspaceSelectionTests {
  private typealias Samples = NamedWorkspaceSamples

  @Test("apply 只把选中工作区的标签交给标签栏，其它工作区的实例保留但不显示")
  func applyShowsOnlySelectedWorkspace() async throws {
    let fixture = try NamedWorkspaceFixture(
      scripted: [Samples.twoWorkspaces(revision: 3)], active: true)
    defer { fixture.tearDown() }

    #expect(await fixture.coordinator.refresh(machineProfileID: fixture.machineID))

    // 没有偏好时选中第一个工作区。
    #expect(fixture.shownRemoteTabIDs == ["tab-1"])
    #expect(fixture.visibleTerminals == ["term-a"])
    // 隐藏工作区的标签实例仍然存在，切回时复用而不是重建。
    #expect(fixture.tabInstance("tab-2") != nil)
    #expect(fixture.tabInstance("tab-3") != nil)
    #expect(fixture.coordinator.selectedWorkspaceTitle(machineID: fixture.machineID) == "主工作区")

    let summaries = fixture.coordinator.remoteWorkspaces(machineID: fixture.machineID)
    #expect(
      summaries == [
        RemoteWorkspaceSummary(
          workspaceID: "ws-1", title: "主工作区", tabCount: 1, terminalCount: 1, isSelected: true,
          tabTitles: ["api"]),
        RemoteWorkspaceSummary(
          workspaceID: "ws-2", title: "发布", tabCount: 2, terminalCount: 2, isSelected: false,
          tabTitles: ["build", "logs"]),
      ])
  }

  @Test("切换选中工作区：缓存命中不发网络请求，被隐藏的终端只分离、绝不 terminate")
  func selectingWorkspaceDetachesHiddenWithoutTerminate() async throws {
    let fixture = try NamedWorkspaceFixture(
      scripted: [Samples.twoWorkspaces(revision: 3)], active: true)
    defer { fixture.tearDown() }
    #expect(await fixture.coordinator.refresh(machineProfileID: fixture.machineID))
    let firstTab = try #require(fixture.tabInstance("tab-1"))
    let callsBefore = fixture.client.invocations.count

    try await fixture.coordinator.selectRemoteWorkspace(
      machineID: fixture.machineID, workspaceID: "ws-2")

    #expect(fixture.client.invocations.count == callsBefore)
    #expect(fixture.shownRemoteTabIDs == ["tab-2", "tab-3"])
    #expect(fixture.visibleTerminals == ["term-b", "term-c"])
    #expect(fixture.selectorCalls.machineIDs.isEmpty)
    // 被隐藏的终端走的是「分离」：本地显示桥拆掉，状态是 detached 而不是 ended。
    let hiddenPane = try #require(firstTab.layout.allPanes.first)
    #expect(firstTab.runtime(for: hiddenPane.id)?.terminalSession?.lifecycleState == .detached)

    // 切回 ws-1：同一个标签实例被复用。
    try await fixture.coordinator.selectRemoteWorkspace(
      machineID: fixture.machineID, workspaceID: "ws-1")
    #expect(fixture.shownRemoteTabIDs == ["tab-1"])
    #expect(fixture.tabInstance("tab-1") === firstTab)
    #expect(fixture.visibleTerminals == ["term-a"])

    // 给异步收尾（若有）一点时间，再确认从头到尾没有任何 terminate / close 请求。
    try? await Task.sleep(for: .milliseconds(100))
    #expect(fixture.client.terminatedTerminalIDs.isEmpty)
    #expect(
      !fixture.client.invocations.contains {
        $0.contains("terminate") || $0.contains("close")
      })
  }

  @Test("选中项被其它客户端关闭：退回第一个工作区，持久化并通知界面，不结束任何进程")
  func selectionFallsBackToFirstWhenWorkspaceDisappears() async throws {
    let fixture = try NamedWorkspaceFixture(
      scripted: [
        Samples.twoWorkspaces(revision: 3),
        Samples.snapshot(revision: 4, workspaces: [Samples.workspace1], terminalIDs: ["term-a"]),
      ],
      active: true)
    defer { fixture.tearDown() }
    #expect(await fixture.coordinator.refresh(machineProfileID: fixture.machineID))
    try await fixture.coordinator.selectRemoteWorkspace(
      machineID: fixture.machineID, workspaceID: "ws-2")

    let received = SelectionNotificationRecorder()
    let observer = NotificationCenter.default.addObserver(
      forName: RemoteWorkspaceCoordinator.selectedWorkspaceDidChange,
      object: fixture.coordinator, queue: nil
    ) { note in
      let machineID = note.userInfo?["machineID"] as? UUID
      let workspaceID = note.userInfo?["workspaceID"] as? String
      // 通知在发出方（主线程上的协调器）同步投递；同时记下此刻标签栏，验证先渲染后通知。
      MainActor.assumeIsolated {
        received.entries.append((machineID, workspaceID, fixture.shownRemoteTabIDs))
      }
    }
    defer { NotificationCenter.default.removeObserver(observer) }

    #expect(await fixture.coordinator.refresh(machineProfileID: fixture.machineID))

    #expect(fixture.shownRemoteTabIDs == ["tab-1"])
    #expect(fixture.coordinator.workspaces[fixture.machineID]?.selectedWorkspaceID == "ws-1")
    #expect(
      fixture.coordinator.selectionStore.selectedWorkspaceID(forMachine: fixture.machineID)
        == "ws-1")
    #expect(received.entries.count == 1)
    #expect(received.entries.first?.workspaceID == "ws-1")
    #expect(received.entries.first?.machineID == fixture.machineID)
    #expect(received.entries.first?.shownTabs == ["tab-1"])
    // 服务端已删的标签按分离语义拆本地运行态（进程由服务端负责），客户端不发 terminate。
    #expect(fixture.tabInstance("tab-2") == nil)
    try? await Task.sleep(for: .milliseconds(100))
    #expect(fixture.client.terminatedTerminalIDs.isEmpty)
  }

  @Test("选中项按机器持久化：新协调器读回上次的选中工作区")
  func selectionPersistsPerMachine() async throws {
    let machineID = UUID()
    let suiteName = "RemoteNamedWorkspace.\(UUID().uuidString)"
    let first = try NamedWorkspaceFixture(
      scripted: [Samples.twoWorkspaces(revision: 3)], active: true, machineID: machineID,
      suiteName: suiteName)
    #expect(await first.coordinator.refresh(machineProfileID: machineID))
    try await first.coordinator.selectRemoteWorkspace(machineID: machineID, workspaceID: "ws-2")
    #expect(
      first.defaults.string(forKey: RemoteWorkspaceSelectionStore.key(forMachine: machineID))
        == "ws-2")
    first.coordinator.stopAllEventSubscriptions()

    // 同一个 suite、同一台机器：新窗口 / 重启 App 后恢复 ws-2。
    let second = try NamedWorkspaceFixture(
      scripted: [Samples.twoWorkspaces(revision: 3)], active: true, machineID: machineID,
      suiteName: suiteName)
    defer { second.tearDown() }
    #expect(await second.coordinator.refresh(machineProfileID: machineID))
    #expect(second.shownRemoteTabIDs == ["tab-2", "tab-3"])

    // 别的机器不受影响。
    let other = RemoteWorkspaceSelectionStore(defaults: second.defaults)
    #expect(other.selectedWorkspaceID(forMachine: UUID()) == nil)
    other.save(nil, forMachine: machineID)
    #expect(other.selectedWorkspaceID(forMachine: machineID) == nil)
  }

  @Test("窗口不在该机器上时，选中工作区先切机器再显示")
  func selectingOnInactiveMachineSwitchesFirst() async throws {
    let fixture = try NamedWorkspaceFixture(
      scripted: [Samples.twoWorkspaces(revision: 3), Samples.twoWorkspaces(revision: 3)],
      active: false)
    defer { fixture.tearDown() }
    // 后台刷新：标签只进分组缓存，不抢当前标签栏，也没有画面订阅。
    #expect(await fixture.coordinator.refresh(machineProfileID: fixture.machineID))
    #expect(fixture.model.activeMachineID == MachineProfile.localProfileID)
    #expect(fixture.visibleTerminals.isEmpty)

    try await fixture.coordinator.selectRemoteWorkspace(
      machineID: fixture.machineID, workspaceID: "ws-2")

    #expect(fixture.selectorCalls.machineIDs == [fixture.machineID])
    #expect(fixture.model.activeMachineID == fixture.machineID)
    #expect(fixture.model.tabs.map(\.remoteTabID) == ["tab-2", "tab-3"])
    #expect(fixture.visibleTerminals == ["term-b", "term-c"])
  }

  @Test("选中已不存在的工作区：先重新取快照确认，仍没有则报错且不改选中项")
  func selectingMissingWorkspaceThrows() async throws {
    let fixture = try NamedWorkspaceFixture(
      scripted: [Samples.twoWorkspaces(revision: 3), Samples.twoWorkspaces(revision: 3)],
      active: true)
    defer { fixture.tearDown() }
    #expect(await fixture.coordinator.refresh(machineProfileID: fixture.machineID))

    await #expect(throws: RemoteWorkspaceOperationError.workspaceNotFound("ws-9")) {
      try await fixture.coordinator.selectRemoteWorkspace(
        machineID: fixture.machineID, workspaceID: "ws-9")
    }
    #expect(fixture.client.invocations.count == 2)
    #expect(fixture.shownRemoteTabIDs == ["tab-1"])
  }

  @Test("选中项解析规则：偏好存在用偏好，否则退回第一个，没有工作区为 nil")
  func resolvedWorkspaceIDRule() throws {
    let server = SessionServerReference(
      machineProfileID: UUID(), serverID: "srv-1", sessionID: "sess-1")
    let snapshot = try RemoteSnapshotDecoder.snapshot(
      try WorkspaceTransactionDecoder.envelope(Samples.twoWorkspaces(revision: 1)),
      machineProfileID: server.machineProfileID)
    let projection = try RemoteWorkspaceProjection.project(snapshot: snapshot, server: server)
    #expect(projection.resolvedWorkspaceID(preferred: "ws-2") == "ws-2")
    #expect(projection.resolvedWorkspaceID(preferred: "gone") == "ws-1")
    #expect(projection.resolvedWorkspaceID(preferred: nil) == "ws-1")
    let empty = ProjectedRemoteSession(revision: 1, workspaces: [], terminalStatusByPaneID: [:])
    #expect(empty.resolvedWorkspaceID(preferred: "ws-2") == nil)
  }
}
