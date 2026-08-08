import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("文件写操作不覆盖同名项并在重命名后保留内容")
func workspaceFileActionServiceCreatesAndRenamesSafely() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-file-actions-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  let service = WorkspaceFileActionService()

  let created = try #require(try service.createFile(named: "note.md", in: root).newURL)
  try Data("hello".utf8).write(to: created)
  #expect(throws: WorkspaceFileActionError.alreadyExists("note.md")) {
    try service.createFile(named: "note.md", in: root)
  }
  let renamed = try #require(try service.rename(created, to: "renamed.md").newURL)
  #expect(!FileManager.default.fileExists(atPath: created.path))
  #expect(try String(contentsOf: renamed, encoding: .utf8) == "hello")
  #expect(try service.createDirectory(named: "Docs", in: root).newURL?.hasDirectoryPath == true)
}

@Test("废纸篓动作通过可注入边界执行且不永久删除")
func workspaceFileActionServiceUsesTrashBoundary() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-file-trash-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  let source = root.appendingPathComponent("note.txt")
  try Data().write(to: source)
  var received: URL?
  let destination = root.appendingPathComponent("recoverable.txt")
  let service = WorkspaceFileActionService(trashItem: { url in
    received = url
    try FileManager.default.moveItem(at: url, to: destination)
    return destination
  })

  let mutation = try service.moveToTrash(source)
  #expect(received == source)
  #expect(mutation.kind == .trashed)
  #expect(mutation.newURL == destination)
  #expect(FileManager.default.fileExists(atPath: destination.path))
}

@Test("文件动作拒绝符号链接与特殊项目")
func workspaceFileActionServiceRejectsSymbolicLinks() throws {
  let root = FileManager.default.temporaryDirectory.appendingPathComponent(
    "aster-file-link-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
  defer { try? FileManager.default.removeItem(at: root) }
  let target = root.appendingPathComponent("target.txt")
  let link = root.appendingPathComponent("link.txt")
  try Data().write(to: target)
  try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
  let service = WorkspaceFileActionService()

  #expect(throws: WorkspaceFileActionError.unsafeItem) {
    try service.rename(link, to: "renamed.txt")
  }
  #expect(throws: WorkspaceFileActionError.unsafeItem) {
    try service.moveToTrash(link)
  }
}
