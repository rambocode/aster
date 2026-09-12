import Foundation
import Testing

@testable import AsterCore

/// P4.2a：混合布局的受管终端子树映射与本地资源关联（A15.4）。

private func managedReference(_ terminalID: String) -> ManagedTerminalReference {
  ManagedTerminalReference(server: P4Fixtures.server, terminalID: terminalID)
}

/// 混合布局：受管终端 + 本地编辑器 + 本地 Web + 未托管终端。
private func mixedLayout() -> (
  layout: PaneLayout, managedA: UUID, managedB: UUID, editor: UUID, web: UUID, plainTerminal: UUID
) {
  let managedA = PaneDescriptor(
    kind: .terminal, workingDirectory: "/srv/a", managedTerminal: managedReference("term-a"))
  let managedB = PaneDescriptor(
    kind: .terminal, workingDirectory: "/srv/b", managedTerminal: managedReference("term-b"))
  let editor = PaneDescriptor(
    kind: .editor, workingDirectory: "/home/me", resourcePath: "/home/me/secret-notes.md")
  let web = PaneDescriptor(
    kind: .web, workingDirectory: "/home/me", resourcePath: "https://internal.example.com/board")
  let plainTerminal = PaneDescriptor(kind: .terminal, workingDirectory: "/home/me/local")

  let layout = PaneLayout.split(
    axis: .horizontal,
    first: .split(axis: .vertical, first: .leaf(managedA), second: .leaf(editor), ratio: 0.6),
    second: .split(
      axis: .vertical,
      first: .split(axis: .horizontal, first: .leaf(web), second: .leaf(managedB), ratio: 0.3),
      second: .leaf(plainTerminal),
      ratio: 0.7
    ),
    ratio: 0.5
  )
  return (layout, managedA.id, managedB.id, editor.id, web.id, plainTerminal.id)
}

@Test func remoteWorkP4SubmissionContainsOnlyManagedTerminals() throws {
  let fixture = mixedLayout()
  let submission = ManagedSubtreeMapping.submission(for: fixture.layout)

  let node = try #require(submission.layout)
  let paneIDs = Set(node.allPanes.map(\.paneID))
  #expect(paneIDs == [fixture.managedA.uuidString.lowercased(), fixture.managedB.uuidString.lowercased()])
  #expect(node.allPanes.map(\.terminalID).sorted() == ["term-a", "term-b"])
  // 本地文件/Web/未托管终端全部被排除，留在来源客户端。
  #expect(
    Set(submission.retainedLocalPaneIDs)
      == [fixture.editor, fixture.web, fixture.plainTerminal])
}

@Test func remoteWorkP4SubmissionPayloadCarriesNoLocalResourcePath() throws {
  let fixture = mixedLayout()
  let submission = ManagedSubtreeMapping.submission(for: fixture.layout)
  let node = try #require(submission.layout)

  // 直接检查真正会被序列化提交的载荷：不含 resourcePath，也不含任何本地路径/URL。
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  let payload = String(decoding: try encoder.encode(node), as: UTF8.self)
  #expect(!payload.contains("resourcePath"))
  #expect(!payload.contains("secret-notes.md"))
  #expect(!payload.contains("internal.example.com"))
  #expect(!payload.contains("/home/me"))
  #expect(!payload.contains("editor"))
  #expect(!payload.contains("web"))
  #expect(payload.contains("term-a"))
}

@Test func remoteWorkP4SubtreeCollapsesSplitsWhenOneSideIsLocal() throws {
  let managed = PaneDescriptor(
    kind: .terminal, workingDirectory: "/srv", managedTerminal: managedReference("only"))
  let local = PaneDescriptor(kind: .fileBrowser, workingDirectory: "/home/me")
  let layout = PaneLayout.split(
    axis: .vertical, first: .leaf(local), second: .leaf(managed), ratio: 0.25)

  // 本地一侧被整体剪掉后，受管一侧提升，不留下只有一个子节点的空分隔容器。
  let node = try #require(ManagedSubtreeMapping.extractManagedSubtree(from: layout))
  #expect(node == .leaf(RemotePane(paneID: managed.id.uuidString.lowercased(), terminalID: "only")))
}

@Test func remoteWorkP4SubtreeIsNilWithoutAnyManagedTerminal() {
  let layout = PaneLayout.split(
    axis: .vertical,
    first: .leaf(PaneDescriptor(kind: .editor, workingDirectory: "/a", resourcePath: "/a/b.txt")),
    second: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: "/a")),
    ratio: 0.5)
  #expect(ManagedSubtreeMapping.extractManagedSubtree(from: layout) == nil)
}

@Test func remoteWorkP4SourceClientRestoresLocalAssociationsOnMerge() throws {
  // 来源客户端的受管终端 Pane 上还挂着一个本地资源关联。
  let associationPaneID = UUID()
  let managed = PaneDescriptor(
    id: associationPaneID, kind: .terminal, workingDirectory: "/home/me/project",
    resourcePath: "/home/me/project/README.md",
    managedTerminal: managedReference("term-x"))
  let localLayout = PaneLayout.leaf(managed)
  let associations = ManagedSubtreeMapping.captureLocalAssociations(in: localLayout)
  #expect(associations[associationPaneID]?.resourcePath == "/home/me/project/README.md")

  // 服务端共享结构里没有 resourcePath。
  let shared = try RemoteWorkspaceProjection.project(
    node: try #require(ManagedSubtreeMapping.extractManagedSubtree(from: localLayout)),
    server: P4Fixtures.server,
    terminals: [:],
    fallbackWorkingDirectory: "/srv"
  )
  #expect(shared.allPanes[0].resourcePath == nil)

  // 来源客户端按 paneID 恢复自己的关联。
  let restored = ManagedSubtreeMapping.merge(shared: shared, localAssociations: associations)
  #expect(restored.allPanes[0].resourcePath == "/home/me/project/README.md")
  #expect(restored.allPanes[0].workingDirectory == "/home/me/project")
  #expect(restored.allPanes[0].managedTerminal?.terminalID == "term-x")

  // 其他客户端没有这些关联，只得到终端共享结构，本地资源字段为空。
  let other = ManagedSubtreeMapping.merge(shared: shared, localAssociations: [:])
  #expect(other.allPanes[0].resourcePath == nil)
}

@Test func remoteWorkP4CaptureIgnoresPlainManagedTerminals() {
  let managed = PaneDescriptor(
    kind: .terminal, workingDirectory: "/srv", managedTerminal: managedReference("term-y"))
  // 没有本地资源的受管终端不产生本地关联，避免把共享状态复制成本地状态。
  #expect(ManagedSubtreeMapping.captureLocalAssociations(in: .leaf(managed)).isEmpty)
}
