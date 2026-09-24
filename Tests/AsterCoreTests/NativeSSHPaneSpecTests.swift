import Foundation
import Testing

@testable import AsterCore

// PaneDescriptor.nativeSSH 的编解码与旧数据兼容。

@Test("PaneDescriptor 带 nativeSSH 往返编解码")
func paneDescriptorRoundTripsNativeSSH() throws {
  let hostID = UUID()
  for spec in [NativeSSHPaneSpec.host(hostID), try #require(NativeSSHPaneSpec.target("ssh://me@box:2222"))] {
    let pane = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp", nativeSSH: spec)
    let decoded = try JSONDecoder().decode(PaneDescriptor.self, from: JSONEncoder().encode(pane))
    #expect(decoded == pane)
    #expect(decoded.nativeSSH == spec)
  }
}

@Test("普通 Pane 不写出 nativeSSH 键，旧数据解码为 nil")
func paneDescriptorWithoutNativeSSHStaysCompatible() throws {
  let pane = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")
  let json = try #require(String(data: JSONEncoder().encode(pane), encoding: .utf8))
  #expect(!json.contains("nativeSSH"))

  let legacy = #"{"id":"\#(UUID().uuidString)","kind":"terminal","workingDirectory":"/tmp"}"#
  let decoded = try JSONDecoder().decode(PaneDescriptor.self, from: Data(legacy.utf8))
  #expect(decoded.nativeSSH == nil)
  #expect(decoded.managedTerminal == nil)
}

@Test("损坏的 nativeSSH 退回普通本地 Pane，不让整份布局解码失败")
func paneDescriptorDropsCorruptNativeSSH() throws {
  let id = UUID().uuidString
  for body in [#"{}"#, #"{"hostID":"\#(UUID().uuidString)","target":"box"}"#, #"{"target":"-oProxyCommand=x"}"#, #"{"target":""}"#] {
    let raw = #"{"id":"\#(id)","kind":"terminal","workingDirectory":"/tmp","nativeSSH":\#(body)}"#
    let decoded = try JSONDecoder().decode(PaneDescriptor.self, from: Data(raw.utf8))
    #expect(decoded.nativeSSH == nil, "\(body)")
  }
}

@Test("nativeSSH 目标校验与 client 目标映射")
func nativeSSHPaneSpecTargets() throws {
  let id = UUID()
  #expect(NativeSSHPaneSpec.host(id).clientTarget == .host(id))
  #expect(try #require(NativeSSHPaneSpec.target("orb")).clientTarget == .text("orb"))
  #expect(NativeSSHPaneSpec.target("") == nil)
  #expect(NativeSSHPaneSpec.target("-J evil") == nil)
  #expect(NativeSSHPaneSpec.target("a b") == nil)
}

@Test("迁移到受管终端时跳过原生 SSH Pane")
func managedMigrationSkipsNativeSSHPanes() throws {
  let local = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")
  let ssh = PaneDescriptor(
    kind: .terminal, workingDirectory: "/tmp", nativeSSH: try #require(NativeSSHPaneSpec.target("orb")))
  let tab = WorkspaceTabSnapshot(
    id: UUID(), title: "t",
    layout: .split(axis: .horizontal, first: .leaf(local), second: .leaf(ssh), ratio: 0.5))
  #expect(ManagedTerminalMigration.candidates(in: [tab]).map(\.paneID) == [local.id])
}
