// `cd` 等目录参数补全：符号链接目录、`..`/`~` 起点与失效历史目录的过滤。
import AsterCore
import Foundation
import Testing

@testable import Aster

@Test("cd 补全把指向目录的符号链接当作目录，不混入指向文件的链接")
@MainActor
func folderCompletionFollowsSymbolicLinks() throws {
  let root = try makeFolderCompletionDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let project = root.appendingPathComponent("project")
  let target = root.appendingPathComponent("target")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
  try Data().write(to: root.appendingPathComponent("plain.txt"))
  try FileManager.default.createSymbolicLink(
    at: project.appendingPathComponent("linked-dir"), withDestinationURL: target)
  try FileManager.default.createSymbolicLink(
    at: project.appendingPathComponent("linked-file"),
    withDestinationURL: root.appendingPathComponent("plain.txt"))
  let service = try makeFolderCompletionService(root)

  let result = service.suggestions(
    line: "cd linked", directory: project.path, sessionIdentifier: "s", controls: .init())

  #expect(result.candidates.contains { $0.insertText == "linked-dir/" && $0.kind == .folder })
  #expect(!result.candidates.contains { $0.insertText.hasPrefix("linked-file") })
}

@Test("cd .. 与 cd ~ 补成目录起点")
@MainActor
func folderCompletionOffersParentAndHome() throws {
  let root = try makeFolderCompletionDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let project = root.appendingPathComponent("project")
  try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
  let service = try makeFolderCompletionService(root)
  func query(_ line: String) -> AutocompleteResult {
    service.suggestions(line: line, directory: project.path, sessionIdentifier: "s", controls: .init())
  }

  #expect(query("cd ..").candidates.contains { $0.appendableSuffix(from: "cd ..") == "/" })
  #expect(query("cd ../..").candidates.contains { $0.appendableSuffix(from: "cd ../..") == "/" })
  #expect(query("cd ~").candidates.contains { $0.appendableSuffix(from: "cd ~") == "/" })
}

@Test("历史里已被删除的 cd 目录不再推荐，仍存在的目录和 cd - 保留")
@MainActor
func folderCompletionDropsMissingLearnedTargets() throws {
  let root = try makeFolderCompletionDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let project = root.appendingPathComponent("project")
  let gone = project.appendingPathComponent("gone")
  try FileManager.default.createDirectory(at: gone, withIntermediateDirectories: true)
  try FileManager.default.createDirectory(
    at: project.appendingPathComponent("kept"), withIntermediateDirectories: true)
  let service = try makeFolderCompletionService(root)
  for command in ["cd gone", "cd kept", "cd -", "cd typo-never-existed"] {
    service.record(
      command: command, directory: project.path, exitStatus: 0, ignorePatterns: [],
      knownOptions: [], sessionIdentifier: "s")
  }
  try FileManager.default.removeItem(at: gone)

  let result = service.suggestions(
    line: "cd ", directory: project.path, sessionIdentifier: "s", controls: .init())
  let texts = result.candidates.map(\.displayText)

  #expect(texts.contains("cd kept"))
  #expect(texts.contains("cd -"))
  #expect(!texts.contains { $0.contains("gone") || $0.contains("typo-never-existed") })
}

@Test("当前目录在本机不存在（远端会话）时不校验历史目录")
@MainActor
func folderCompletionKeepsTargetsForRemoteDirectories() throws {
  let root = try makeFolderCompletionDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try makeFolderCompletionService(root)
  let remote = "/aster-remote-\(UUID().uuidString)/work"
  service.record(
    command: "cd src", directory: remote, exitStatus: 0, ignorePatterns: [],
    knownOptions: [], sessionIdentifier: "s")

  let result = service.suggestions(
    line: "cd ", directory: remote, sessionIdentifier: "s", controls: .init())

  #expect(result.candidates.contains { $0.displayText == "cd src" })
}

@MainActor
private func makeFolderCompletionService(_ root: URL) throws -> AutocompleteService {
  try AutocompleteService(
    baseDirectory: root.appendingPathComponent("state", isDirectory: true),
    bundledSpecURL: URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/autocomplete/fig-specs.json"))
}

private func makeFolderCompletionDirectory() throws -> URL {
  // 解析 /var → /private/var，保证符号链接目标与列表路径一致。
  let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
    .appendingPathComponent("aster-folder-completion-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
