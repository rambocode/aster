import Foundation
import Testing

@testable import AsterCore

/// P2.1：受管终端引用与旧工作区兼容解码。
///
/// 旧数据没有 `managedTerminal` 字段，必须解码成本地非受管 Pane；损坏的引用同样
/// 退回本地模式，而不是让整份布局解码失败或编造一个身份。

private func legacyPaneJSON() -> [String: Any] {
  ["id": UUID().uuidString, "kind": "terminal", "workingDirectory": "/tmp"]
}

@Test func remotePaneDescriptorDecodesLegacyLayoutAsLocal() throws {
  let data = try JSONSerialization.data(withJSONObject: legacyPaneJSON())
  let pane = try JSONDecoder().decode(PaneDescriptor.self, from: data)
  #expect(pane.managedTerminal == nil)
  #expect(pane.kind == .terminal)
  #expect(pane.workingDirectory == "/tmp")
}

@Test func remotePaneDescriptorDropsCorruptManagedReference() throws {
  var payload = legacyPaneJSON()
  payload["managedTerminal"] = ["terminalID": "only-id"]
  let data = try JSONSerialization.data(withJSONObject: payload)
  let pane = try JSONDecoder().decode(PaneDescriptor.self, from: data)
  #expect(pane.managedTerminal == nil)
}

@Test func remotePaneDescriptorRoundTripsManagedReference() throws {
  let reference = ManagedTerminalReference(
    server: SessionServerReference(
      machineProfileID: MachineProfile.localProfileID,
      serverID: "bc2d4ef4-ca4e-435e-ab6d-409a79805fc8",
      sessionID: "83dfae3a-991d-4f16-8e69-ddaca142b563"
    ),
    terminalID: "ad70419d-5259-47c0-89ab-159eecb0caae"
  )
  let pane = PaneDescriptor(
    kind: .terminal, workingDirectory: "/tmp", managedTerminal: reference)
  let encoded = try JSONEncoder().encode(pane)
  let decoded = try JSONDecoder().decode(PaneDescriptor.self, from: encoded)
  #expect(decoded.managedTerminal == reference)

  // 本地 Pane 不写出该键，旧版本客户端仍能读回同一份布局。
  let localEncoded = try JSONEncoder().encode(
    PaneDescriptor(kind: .terminal, workingDirectory: "/tmp"))
  let json = try JSONSerialization.jsonObject(with: localEncoded) as? [String: Any]
  #expect(json?["managedTerminal"] == nil)
}

@Test func remoteLayoutKeepsManagedReferenceThroughSplitAndUpdate() throws {
  let reference = ManagedTerminalReference(
    server: SessionServerReference(
      machineProfileID: MachineProfile.localProfileID, serverID: "s", sessionID: "n"),
    terminalID: "t1"
  )
  let root = PaneDescriptor(kind: .terminal, workingDirectory: "/a", managedTerminal: reference)
  let added = PaneDescriptor(kind: .terminal, workingDirectory: "/b")
  let layout = PaneLayout.leaf(root).splitting(
    paneID: root.id, direction: .right, with: added)
  let panes = try #require(layout).allPanes
  #expect(panes.first(where: { $0.id == root.id })?.managedTerminal == reference)
  #expect(panes.first(where: { $0.id == added.id })?.managedTerminal == nil)
}
