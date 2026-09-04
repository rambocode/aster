import Foundation
import Testing

@testable import AsterCore

@Test("workspaceFileScannerSkipsHiddenFilesAndBlacklistedDirectories")
func workspaceFileScannerSkipsHiddenFilesAndBlacklistedDirectories() throws {
  let manager = FileManager.default
  let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  let nodeModules = root.appendingPathComponent("node_modules", isDirectory: true)
  try manager.createDirectory(at: nodeModules, withIntermediateDirectories: true)
  try Data().write(to: root.appendingPathComponent("README.md"))
  try Data().write(to: root.appendingPathComponent(".hidden"))
  try Data().write(to: nodeModules.appendingPathComponent("package.json"))
  defer { try? manager.removeItem(at: root) }

  let files = WorkspaceFileScanner.scan(root: root.path)

  #expect(files.map(\.name) == ["README.md"])
}

@Test("workspaceFileScannerStopsAtMaximumFiles")
func workspaceFileScannerStopsAtMaximumFiles() throws {
  let manager = FileManager.default
  let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  try manager.createDirectory(at: root, withIntermediateDirectories: true)
  for index in 0..<20 {
    try Data().write(to: root.appendingPathComponent("file-\(index).txt"))
  }
  defer { try? manager.removeItem(at: root) }

  let files = WorkspaceFileScanner.scan(root: root.path, limits: .init(maximumFiles: 5))

  #expect(files.count == 5)
}

@Test("workspaceFileScannerRespectsMaximumDepth")
func workspaceFileScannerRespectsMaximumDepth() throws {
  let manager = FileManager.default
  let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  let shallow = root.appendingPathComponent("level1", isDirectory: true)
  let deep = shallow.appendingPathComponent("level2", isDirectory: true)
  try manager.createDirectory(at: deep, withIntermediateDirectories: true)
  try Data().write(to: shallow.appendingPathComponent("shallow.txt"))
  try Data().write(to: deep.appendingPathComponent("deep.txt"))
  defer { try? manager.removeItem(at: root) }

  let files = WorkspaceFileScanner.scan(root: root.path, limits: .init(maximumDepth: 2))

  #expect(files.map(\.name) == ["shallow.txt"])
}

@Test("workspaceFileScannerBuildsRelativeParentFromRootName")
func workspaceFileScannerBuildsRelativeParentFromRootName() throws {
  let manager = FileManager.default
  let rootName = "project-wiki-\(UUID().uuidString)"
  let root = manager.temporaryDirectory.appendingPathComponent(rootName, isDirectory: true)
  let demo = root.appendingPathComponent("demo", isDirectory: true)
  let deep = demo.appendingPathComponent("deep", isDirectory: true)
  try manager.createDirectory(at: deep, withIntermediateDirectories: true)
  try Data().write(to: root.appendingPathComponent("README.md"))
  try Data().write(to: demo.appendingPathComponent("a.txt"))
  try Data().write(to: deep.appendingPathComponent("b.txt"))
  defer { try? manager.removeItem(at: root) }

  let files = WorkspaceFileScanner.scan(root: root.path)
  let byName = Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.relativeParent) })

  #expect(byName["README.md"] == rootName)
  #expect(byName["a.txt"] == "\(rootName)/demo")
  #expect(byName["b.txt"] == "\(rootName)/demo/deep")
}

@Test("workspaceFileScannerSortsByDepthThenLocalizedName")
func workspaceFileScannerSortsByDepthThenLocalizedName() throws {
  let manager = FileManager.default
  let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  let nested = root.appendingPathComponent("nested", isDirectory: true)
  try manager.createDirectory(at: nested, withIntermediateDirectories: true)
  try Data().write(to: root.appendingPathComponent("Zebra.txt"))
  try Data().write(to: root.appendingPathComponent("apple.txt"))
  try Data().write(to: nested.appendingPathComponent("anything.txt"))
  defer { try? manager.removeItem(at: root) }

  let files = WorkspaceFileScanner.scan(root: root.path)

  #expect(files.map(\.name) == ["apple.txt", "Zebra.txt", "anything.txt"])
  #expect(files.map(\.depth) == [1, 1, 2])
}

@Test("workspaceFileScannerReturnsEmptyForMissingOrInvalidRoot")
func workspaceFileScannerReturnsEmptyForMissingOrInvalidRoot() throws {
  let manager = FileManager.default
  let missing = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString).path
  let file = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
  try Data().write(to: file)
  defer { try? manager.removeItem(at: file) }

  #expect(WorkspaceFileScanner.scan(root: "") == [])
  #expect(WorkspaceFileScanner.scan(root: missing) == [])
  #expect(WorkspaceFileScanner.scan(root: file.path) == [])
}
