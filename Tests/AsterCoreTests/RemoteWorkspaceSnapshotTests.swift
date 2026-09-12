import Foundation
import Testing

@testable import AsterCore

/// P4.2 客户端半边：快照解码与投影（A15）。

private let paneA = "11111111-1111-4111-8111-111111111111"
private let paneB = "22222222-2222-4222-8222-222222222222"
private let terminalA = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
private let terminalB = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"

/// 一棵「左叶 + 右叶」的分屏样例。
private func sampleLayout() -> [String: Any] {
  [
    "kind": "split", "axis": "horizontal", "ratio": 0.4,
    "first": ["kind": "leaf", "pane": ["paneID": paneA, "terminalID": terminalA, "title": "shell"]],
    "second": ["kind": "leaf", "pane": ["paneID": paneB, "terminalID": terminalB]],
  ]
}

private func sampleSnapshotResult() -> [String: Any] {
  [
    "workspaces": [
      [
        "workspaceID": "33333333-3333-4333-8333-333333333333",
        "title": "Project", "cwd": "/srv/project",
        "tabs": [
          [
            "tabID": "44444444-4444-4444-8444-444444444444", "title": "Main",
            "layout": sampleLayout(),
          ]
        ],
      ]
    ],
    "terminals": [
      ["terminalID": terminalA, "state": "running", "cwd": "/srv/project/api", "pid": 4242],
      ["terminalID": terminalB, "state": "exited", "cwd": "/srv/project", "exitCode": 0],
    ],
  ]
}

@Test func remoteWorkP4SnapshotDecodesRevisionFromEnvelope() throws {
  let line = try P4Fixtures.sessionResponse(
    operation: "session.snapshot", revision: 17, result: sampleSnapshotResult())
  let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
  let snapshot = try RemoteSnapshotDecoder.snapshot(
    json, machineProfileID: MachineProfile.localProfileID)

  // revision 是信封顶层字段（协议 §5），不在 result 内部。
  #expect(snapshot.revision == 17)
  #expect(snapshot.workspaces.count == 1)
  #expect(snapshot.terminals.count == 2)
  #expect(snapshot.terminalsByID[terminalA]?.pid == 4242)
  #expect(snapshot.terminalsByID[terminalB]?.state == .exited)
}

@Test func remoteWorkP4SnapshotToleratesUnknownOptionalFields() throws {
  var result = sampleSnapshotResult()
  var workspace = (result["workspaces"] as! [[String: Any]])[0]
  workspace["futureField"] = "ignored"
  var tab = (workspace["tabs"] as! [[String: Any]])[0]
  tab["futureTabField"] = 3
  workspace["tabs"] = [tab]
  result["workspaces"] = [workspace]
  let line = try P4Fixtures.sessionResponse(
    operation: "session.snapshot", revision: 1, result: result)
  let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]

  let snapshot = try RemoteSnapshotDecoder.snapshot(
    json, machineProfileID: MachineProfile.localProfileID)
  #expect(snapshot.workspaces[0].tabs.count == 1)
}

@Test func remoteWorkP4SnapshotReportsMissingRequiredField() throws {
  var result = sampleSnapshotResult()
  var workspace = (result["workspaces"] as! [[String: Any]])[0]
  workspace.removeValue(forKey: "cwd")
  result["workspaces"] = [workspace]
  let line = try P4Fixtures.sessionResponse(
    operation: "session.snapshot", revision: 1, result: result)
  let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]

  #expect(throws: RemoteSnapshotError.missingField("cwd")) {
    _ = try RemoteSnapshotDecoder.snapshot(json, machineProfileID: MachineProfile.localProfileID)
  }
}

@Test func remoteWorkP4LayoutDepthLimitIsEnforcedDuringDecode() throws {
  // 构造 17 层嵌套：超过协议 semanticLimits.maximumLayoutDepth = 16。
  var node: [String: Any] = ["kind": "leaf", "pane": ["paneID": paneA, "terminalID": terminalA]]
  for _ in 0..<16 {
    node = [
      "kind": "split", "axis": "vertical", "ratio": 0.5,
      "first": node,
      "second": ["kind": "leaf", "pane": ["paneID": paneB, "terminalID": terminalB]],
    ]
  }
  #expect(throws: RemoteSnapshotError.layoutTooDeep(depth: 17)) {
    _ = try RemoteSnapshotDecoder.layout(node)
  }
}

@Test func remoteWorkP4LayoutRejectsInvalidRatioAndKind() throws {
  #expect(throws: RemoteSnapshotError.invalidRatio(1.0)) {
    _ = try RemoteSnapshotDecoder.layout([
      "kind": "split", "axis": "vertical", "ratio": 1.0,
      "first": ["kind": "leaf", "pane": ["paneID": paneA, "terminalID": terminalA]],
      "second": ["kind": "leaf", "pane": ["paneID": paneB, "terminalID": terminalB]],
    ])
  }
  #expect(throws: RemoteSnapshotError.invalidLayoutKind("group")) {
    _ = try RemoteSnapshotDecoder.layout(["kind": "group"])
  }
}

@Test func remoteWorkP4LayoutNodeRoundTripsThroughCodable() throws {
  let node = try RemoteSnapshotDecoder.layout(sampleLayout())
  let data = try JSONEncoder().encode(node)
  #expect(try JSONDecoder().decode(RemoteLayoutNode.self, from: data) == node)
}

@Test func remoteWorkP4ProjectionBuildsManagedPanesOnly() throws {
  let line = try P4Fixtures.sessionResponse(
    operation: "session.snapshot", revision: 9, result: sampleSnapshotResult())
  let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
  let snapshot = try RemoteSnapshotDecoder.snapshot(
    json, machineProfileID: MachineProfile.localProfileID)

  let projected = try RemoteWorkspaceProjection.project(
    snapshot: snapshot, server: P4Fixtures.server)

  #expect(projected.revision == 9)
  let layout = projected.workspaces[0].tabs[0].layout
  let panes = layout.allPanes
  #expect(panes.count == 2)
  // 共享结构里的每个 leaf 都是受管终端 pane，且不携带任何本地资源路径。
  #expect(panes.allSatisfy { $0.kind == .terminal })
  #expect(panes.allSatisfy { $0.managedTerminal != nil })
  #expect(panes.allSatisfy { $0.resourcePath == nil })
  // paneID 跨恢复稳定：直接用服务端 paneID 作为本地 Pane 身份。
  #expect(panes.map { $0.id.uuidString.lowercased() }.sorted() == [paneA, paneB].sorted())
  // 分屏方向与比例原样保留。
  #expect(layout.axis == .horizontal)
  #expect(layout.splitRatio(at: []) == 0.4)
  // 终端 cwd 取服务端上报值，不是工作区 cwd。
  let first = panes.first { $0.id.uuidString.lowercased() == paneA }
  #expect(first?.workingDirectory == "/srv/project/api")
}

@Test func remoteWorkP4ProjectionKeepsLivenessOutOfPaneIdentity() throws {
  let line = try P4Fixtures.sessionResponse(
    operation: "session.snapshot", revision: 3, result: sampleSnapshotResult())
  let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
  let snapshot = try RemoteSnapshotDecoder.snapshot(
    json, machineProfileID: MachineProfile.localProfileID)
  let projected = try RemoteWorkspaceProjection.project(
    snapshot: snapshot, server: P4Fixtures.server)

  // paneID 存在不代表进程存活：存活只能看实测状态。
  let exitedPane = UUID(uuidString: paneB)!
  #expect(projected.terminalStatusByPaneID[exitedPane]?.state == .exited)
  let runningPane = UUID(uuidString: paneA)!
  #expect(projected.terminalStatusByPaneID[runningPane]?.state == .running)
}

@Test func remoteWorkP4ProjectionIsPureFunction() throws {
  let line = try P4Fixtures.sessionResponse(
    operation: "session.snapshot", revision: 5, result: sampleSnapshotResult())
  let json = try JSONSerialization.jsonObject(with: Data(line.utf8)) as! [String: Any]
  let snapshot = try RemoteSnapshotDecoder.snapshot(
    json, machineProfileID: MachineProfile.localProfileID)

  let first = try RemoteWorkspaceProjection.project(snapshot: snapshot, server: P4Fixtures.server)
  let second = try RemoteWorkspaceProjection.project(snapshot: snapshot, server: P4Fixtures.server)
  #expect(first == second)
}

@Test func remoteWorkP4ProjectionRejectsNonUUIDPaneID() throws {
  let node = try RemoteSnapshotDecoder.layout([
    "kind": "leaf", "pane": ["paneID": "not-a-uuid", "terminalID": terminalA],
  ])
  #expect(throws: RemoteSnapshotError.invalidIdentifier("not-a-uuid")) {
    _ = try RemoteWorkspaceProjection.project(
      node: node, server: P4Fixtures.server, terminals: [:], fallbackWorkingDirectory: "/srv")
  }
}
