import Foundation
import Testing

@testable import AsterCore

@Test("文件分类覆盖富预览、源码、二进制和可信 Agent transcript")
func fileDocumentClassifierCoversPresentationKinds() {
  #expect(
    FileDocumentClassifier.classify(fileName: "README.md", prefix: Data("# Aster".utf8))
      == .markdown)
  #expect(
    FileDocumentClassifier.classify(fileName: "manual.rst", prefix: Data("Title".utf8))
      == .restructuredText)
  #expect(
    FileDocumentClassifier.classify(fileName: "icon.svg", prefix: Data("<svg/>".utf8)) == .svg)
  #expect(FileDocumentClassifier.classify(fileName: "photo.webp", prefix: Data()) == .image)
  #expect(FileDocumentClassifier.classify(fileName: "change.patch", prefix: Data()) == .diff)
  #expect(
    FileDocumentClassifier.classify(fileName: "unknown", prefix: Data("plain text".utf8))
      == .sourceText)
  #expect(FileDocumentClassifier.classify(fileName: "unknown", prefix: Data([0, 1, 2])) == .binary)
  #expect(
    FileDocumentClassifier.classify(
      fileName: "session.jsonl",
      prefix: Data(),
      trustedAgentProvider: .codex
    ) == .agentTranscript
  )
}

@Test("文件名与相对路径边界拒绝路径穿越并按组件计算")
func fileItemNameAndRelativePathBoundaries() throws {
  #expect(try FileItemNameValidator.validate(" note.md ") == "note.md")
  #expect(throws: FileItemNameError.reserved) { try FileItemNameValidator.validate("..") }
  #expect(throws: FileItemNameError.containsPathSeparator) {
    try FileItemNameValidator.validate("../secret")
  }
  #expect(
    WorkspaceRelativePath.make(
      target: URL(fileURLWithPath: "/tmp/project/Sources/main.swift"),
      relativeTo: URL(fileURLWithPath: "/tmp/project")
    ) == "Sources/main.swift"
  )
  #expect(
    WorkspaceRelativePath.make(
      target: URL(fileURLWithPath: "/tmp/project-other/file"),
      relativeTo: URL(fileURLWithPath: "/tmp/project")
    ) == nil
  )
}

@Test("Hex 行同时保留地址、分组字节和可打印字符")
func hexLineFormatterProducesStableColumns() {
  let bytes: [UInt8] = Array("Aster\n".utf8)
  let line = HexLineFormatter.line(offset: 16, bytes: bytes[...])
  #expect(line.hasPrefix("00000010"))
  #expect(line.contains("41 73 74 65 72 0A"))
  #expect(line.hasSuffix("|Aster.|"))
}
