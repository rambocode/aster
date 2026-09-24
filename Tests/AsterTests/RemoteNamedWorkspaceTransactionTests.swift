// 远端命名工作区的事务：新建 / 改名 / 关闭的参数，以及新建标签落在选中工作区。
import AsterCore
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

@Suite(.serialized)
@MainActor
struct RemoteNamedWorkspaceTransactionTests {
  private typealias Samples = NamedWorkspaceSamples
  private typealias Fixture = NamedWorkspaceFixture

  @Test("新建标签与 Agent 标签落在选中工作区，cwd 取选中工作区的服务端目录")
  func newTabsLandInSelectedWorkspace() async throws {
    let tabReply = Samples.result(
      revision: 4, Samples.leafTab("tab-9", title: "srv", pane: Samples.paneD, terminal: "term-d"))
    let fixture = try Fixture(
      scripted: [
        Samples.twoWorkspaces(revision: 3), tabReply, Samples.twoWorkspaces(revision: 4),
        tabReply, Samples.twoWorkspaces(revision: 5),
      ],
      active: true)
    defer { fixture.tearDown() }
    #expect(await fixture.coordinator.refresh(machineProfileID: fixture.machineID))
    try await fixture.coordinator.selectRemoteWorkspace(
      machineID: fixture.machineID, workspaceID: "ws-2")

    fixture.coordinator.createTab(workingDirectory: nil)
    await fixture.waitForInvocations(count: 3)
    let create = try #require(fixture.client.invocations.dropFirst().first)
    #expect(Array(create.prefix(2)) == ["tab", "create"])
    #expect(Fixture.value(of: "--workspace", in: create) == "ws-2")
    #expect(Fixture.value(of: "--cwd", in: create) == "/srv/two")

    fixture.coordinator.createAgentTab(provider: .grokBuild, workingDirectory: nil)
    await fixture.waitForInvocations(count: 5)
    let agent = try #require(fixture.client.invocations.dropFirst(3).first)
    #expect(Array(agent.prefix(2)) == ["tab", "create"])
    #expect(Fixture.value(of: "--workspace", in: agent) == "ws-2")
    #expect(Fixture.value(of: "--cwd", in: agent) == "/srv/two")
  }

  @Test("新建远端工作区：提交 workspace create，首个 Shell 落在远端 $HOME，成功后自动选中")
  func createWorkspaceSubmitsAndSelects() async throws {
    let fixture = try Fixture(
      scripted: [
        Samples.twoWorkspaces(revision: 3),
        Samples.result(revision: 4, Samples.workspace3),
        Samples.snapshot(
          revision: 4, workspaces: [Samples.workspace1, Samples.workspace2, Samples.workspace3],
          terminalIDs: ["term-a", "term-b", "term-c", "term-d"]),
      ],
      active: true)
    defer { fixture.tearDown() }
    #expect(await fixture.coordinator.refresh(machineProfileID: fixture.machineID))

    let id = try await fixture.coordinator.createRemoteWorkspace(
      machineID: fixture.machineID, title: "  实验  ")

    #expect(id == "ws-3")
    #expect(fixture.client.invocations.count == 3)
    let create = fixture.client.invocations[1]
    #expect(Array(create.prefix(2)) == ["workspace", "create"])
    #expect(Fixture.value(of: "--title", in: create) == "实验")
    #expect(Fixture.value(of: "--expected-revision", in: create) == "3")
    #expect(Fixture.value(of: "--cwd", in: create) == ManagedTerminalLaunchSpec.remoteRootDirectory)
    let separator = try #require(create.firstIndex(of: "--"))
    #expect(
      Array(create[(separator + 1)...]) == ManagedTerminalLaunchSpec.remoteArgv(landsInHome: true))
    // 自动选中并显示新工作区，选中项持久化。
    #expect(fixture.shownRemoteTabIDs == ["tab-4"])
    #expect(
      fixture.coordinator.selectionStore.selectedWorkspaceID(forMachine: fixture.machineID)
        == "ws-3")
    #expect(fixture.coordinator.remoteWorkspaces(machineID: fixture.machineID).count == 3)
  }

  @Test("重命名远端工作区：提交 workspace update；revision 冲突时按服务端 revision 重试同一意图")
  func renameWorkspaceSubmitsUpdateWithConflictRetry() async throws {
    let renamed = Samples.workspace2.replacingOccurrences(of: "发布", with: "上线")
    let fixture = try Fixture(
      scripted: [
        Samples.twoWorkspaces(revision: 3),
        "{\"type\":\"error\",\"error\":{\"code\":\"revision_conflict\",\"currentRevision\":7}}",
        Samples.result(revision: 8, renamed),
        Samples.snapshot(
          revision: 8, workspaces: [Samples.workspace1, renamed],
          terminalIDs: ["term-a", "term-b", "term-c"]),
      ],
      active: true)
    defer { fixture.tearDown() }
    #expect(await fixture.coordinator.refresh(machineProfileID: fixture.machineID))

    try await fixture.coordinator.renameRemoteWorkspace(
      machineID: fixture.machineID, workspaceID: "ws-2", title: "上线")

    let first = fixture.client.invocations[1]
    let retry = fixture.client.invocations[2]
    for argv in [first, retry] {
      #expect(Array(argv.prefix(2)) == ["workspace", "update"])
      #expect(Fixture.value(of: "--workspace", in: argv) == "ws-2")
      #expect(Fixture.value(of: "--title", in: argv) == "上线")
    }
    #expect(Fixture.value(of: "--expected-revision", in: first) == "3")
    #expect(Fixture.value(of: "--expected-revision", in: retry) == "7")
    let titles = fixture.coordinator.remoteWorkspaces(machineID: fixture.machineID).map(\.title)
    #expect(titles == ["主工作区", "上线"])
  }

  @Test("关闭选中的远端工作区：提交 workspace close，选中项退回第一个；进程由服务端结束")
  func closeWorkspaceSubmitsCloseAndFallsBack() async throws {
    let fixture = try Fixture(
      scripted: [
        Samples.twoWorkspaces(revision: 3),
        Samples.result(revision: 4, "{\"closed\":true}"),
        Samples.snapshot(revision: 4, workspaces: [Samples.workspace1], terminalIDs: ["term-a"]),
      ],
      active: true)
    defer { fixture.tearDown() }
    #expect(await fixture.coordinator.refresh(machineProfileID: fixture.machineID))
    try await fixture.coordinator.selectRemoteWorkspace(
      machineID: fixture.machineID, workspaceID: "ws-2")
    let summary = try #require(
      fixture.coordinator.remoteWorkspaces(machineID: fixture.machineID).last)
    #expect(summary.terminalCount == 2)

    try await fixture.coordinator.closeRemoteWorkspace(
      machineID: fixture.machineID, workspaceID: "ws-2")

    let close = fixture.client.invocations[1]
    #expect(Array(close.prefix(2)) == ["workspace", "close"])
    #expect(Fixture.value(of: "--workspace", in: close) == "ws-2")
    #expect(Fixture.value(of: "--expected-revision", in: close) == "3")
    #expect(fixture.shownRemoteTabIDs == ["tab-1"])
    #expect(fixture.coordinator.selectedWorkspaceTitle(machineID: fixture.machineID) == "主工作区")
    // 结束进程是服务端 `workspace.close` 的职责；客户端不再逐个 terminate。
    try? await Task.sleep(for: .milliseconds(100))
    #expect(fixture.client.terminatedTerminalIDs.isEmpty)
  }

  @Test("空白名称不提交任何事务")
  func blankTitleIsRejectedLocally() async throws {
    let fixture = try Fixture(scripted: [Samples.twoWorkspaces(revision: 3)], active: true)
    defer { fixture.tearDown() }
    #expect(await fixture.coordinator.refresh(machineProfileID: fixture.machineID))

    await #expect(throws: RemoteWorkspaceOperationError.emptyTitle) {
      _ = try await fixture.coordinator.createRemoteWorkspace(
        machineID: fixture.machineID, title: "   ")
    }
    await #expect(throws: RemoteWorkspaceOperationError.emptyTitle) {
      try await fixture.coordinator.renameRemoteWorkspace(
        machineID: fixture.machineID, workspaceID: "ws-1", title: "\n")
    }
    #expect(fixture.client.invocations.count == 1)
  }
}
