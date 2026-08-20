import Darwin
import Foundation
import Testing

@testable import AsterCore

@Test func documentBufferTracksDirtyStateAndSavesAtomically() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let file = directory.appendingPathComponent("note.md")
  try "hello".write(to: file, atomically: true, encoding: .utf8)
  var buffer = try DocumentBuffer.load(from: file)
  #expect(buffer.text == "hello")
  #expect(!buffer.isDirty)

  buffer.updateText("hello, Aster")
  #expect(buffer.isDirty)
  try buffer.save()
  #expect(!buffer.isDirty)
  #expect(try String(contentsOf: file, encoding: .utf8) == "hello, Aster")

  buffer.updateText("unsaved rename")
  let renamed = directory.appendingPathComponent("renamed.md")
  try FileManager.default.moveItem(at: file, to: renamed)
  var relocated = buffer.relocated(to: renamed)
  #expect(relocated.isDirty)
  #expect(relocated.text == "unsaved rename")
  try relocated.save()
  #expect(try String(contentsOf: renamed, encoding: .utf8) == "unsaved rename")
}

@Test func recipeStoreRoundTripsAndRejectsWrongExtension() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let pane = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")
  let recipe = WorkspaceRecipe(
    name: "Review",
    tabs: [RecipeTab(title: "Review", layout: .leaf(pane), commands: ["git status"])],
    replayMode: .confirmOnce
  )
  let file = directory.appendingPathComponent("Review.asterrecipe")
  try RecipeStore.save(recipe, to: file)
  #expect(try RecipeStore.load(from: file) == recipe)

  #expect(throws: RecipeStoreError.invalidFileExtension) {
    try RecipeStore.save(recipe, to: directory.appendingPathComponent("Review.json"))
  }
}

@Test func recipeStoreRejectsDuplicatePaneIdentifiersAndExcessiveDepth() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let duplicateID = UUID()
  let left = PaneDescriptor(id: duplicateID, kind: .terminal, workingDirectory: "/tmp")
  let right = PaneDescriptor(id: duplicateID, kind: .terminal, workingDirectory: "/tmp")
  let duplicateRecipe = WorkspaceRecipe(
    name: "Bad",
    tabs: [
      RecipeTab(
        title: "Bad",
        layout: .split(axis: .horizontal, first: .leaf(left), second: .leaf(right), ratio: 0.5))
    ],
    replayMode: .skip
  )
  let duplicateURL = directory.appendingPathComponent("duplicate.asterrecipe")
  try JSONEncoder().encode(duplicateRecipe).write(to: duplicateURL)
  #expect(throws: RecipeStoreError.duplicatePaneIdentifier) {
    try RecipeStore.load(from: duplicateURL)
  }

  var deepLayout = PaneLayout.leaf(PaneDescriptor(kind: .terminal, workingDirectory: "/tmp"))
  for _ in 0..<20 {
    deepLayout = .split(
      axis: .vertical,
      first: deepLayout,
      second: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")),
      ratio: 0.5
    )
  }
  let deepURL = directory.appendingPathComponent("deep.asterrecipe")
  try JSONEncoder().encode(
    WorkspaceRecipe(
      name: "Deep", tabs: [RecipeTab(title: "Deep", layout: deepLayout)], replayMode: .skip)
  ).write(to: deepURL)
  #expect(throws: RecipeStoreError.layoutTooDeep) {
    try RecipeStore.load(from: deepURL)
  }
}

@Test func recipeStoreRejectsNamedPipeBeforeReading() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let pipe = directory.appendingPathComponent("blocked.asterrecipe")
  let result = pipe.path.withCString { Darwin.mkfifo($0, 0o600) }
  #expect(result == 0)
  #expect(throws: RecipeStoreError.notRegularFile) {
    try RecipeStore.load(from: pipe)
  }
}

@Test func recipeStoreLimitsCumulativeEditorResources() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  func makeSparseFile(named name: String) throws -> URL {
    let url = directory.appendingPathComponent(name)
    FileManager.default.createFile(atPath: url.path, contents: Data())
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: 20 * 1_024 * 1_024)
    try handle.close()
    return url
  }

  let firstFile = try makeSparseFile(named: "first.txt")
  let secondFile = try makeSparseFile(named: "second.txt")
  let first = PaneDescriptor(
    kind: .editor, workingDirectory: directory.path, resourcePath: firstFile.path)
  let second = PaneDescriptor(
    kind: .editor, workingDirectory: directory.path, resourcePath: secondFile.path)
  let recipe = WorkspaceRecipe(
    name: "Oversized",
    tabs: [
      RecipeTab(
        title: "Oversized",
        layout: .split(
          axis: .horizontal, first: .leaf(first), second: .leaf(second), ratio: 0.5))
    ],
    replayMode: .skip
  )

  #expect(throws: RecipeStoreError.editorResourcesTooLarge) {
    try RecipeStore.validate(recipe)
  }
}

@Test func sessionSnapshotOnlyPersistsRebuildableWorkspaceState() throws {
  let pane = PaneDescriptor(kind: .editor, workingDirectory: "/tmp", resourcePath: "/tmp/a.md")
  let snapshot = WorkspaceSnapshot(
    selectedTabID: UUID(),
    tabs: [WorkspaceTabSnapshot(id: UUID(), title: "Docs", layout: .leaf(pane))]
  )
  let data = try JSONEncoder().encode(snapshot)
  let restored = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
  #expect(restored == snapshot)
  #expect(restored.tabs[0].layout.allPanes[0].resourcePath == "/tmp/a.md")
}

// 恢复重连依赖快照携带的 Agent 会话身份；本测试锁定编码往返与旧快照兼容两条底线。
@Test func workspaceSnapshotRoundTripsAgentSessionsAndDecodesLegacyJSON() throws {
  let pane = PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")
  let tab = WorkspaceTabSnapshot(
    id: UUID(),
    title: "Shell",
    layout: .leaf(pane),
    agentSessions: [
      WorkspacePaneAgentSession(paneID: pane.id, provider: .claudeCode, sessionID: "abc-123")
    ]
  )
  let snapshot = WorkspaceSnapshot(selectedTabID: tab.id, tabs: [tab])
  let data = try JSONEncoder().encode(snapshot)
  let restored = try JSONDecoder().decode(WorkspaceSnapshot.self, from: data)
  #expect(restored == snapshot)
  #expect(restored.tabs[0].agentSessions?.first?.provider == .claudeCode)
  #expect(restored.tabs[0].agentSessions?.first?.sessionID == "abc-123")

  // 没有 agentSessions 字段的旧快照必须继续解码为 nil，不得报错或改变布局。
  let legacy = WorkspaceTabSnapshot(id: tab.id, title: "Shell", layout: .leaf(pane))
  var legacyJSON = try JSONSerialization.jsonObject(
    with: JSONEncoder().encode(legacy)) as? [String: Any] ?? [:]
  legacyJSON.removeValue(forKey: "agentSessions")
  let legacyData = try JSONSerialization.data(withJSONObject: legacyJSON)
  let decodedLegacy = try JSONDecoder().decode(WorkspaceTabSnapshot.self, from: legacyData)
  #expect(decodedLegacy.agentSessions == nil)
  #expect(decodedLegacy.layout == legacy.layout)
}
