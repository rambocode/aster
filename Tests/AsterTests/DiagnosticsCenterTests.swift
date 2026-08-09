import Foundation
import Testing

@testable import Aster

@Test("诊断日志过滤敏感属性且反馈包只包含脱敏文件")
func diagnosticsRedactSensitiveAttributesAndBuildArchive() throws {
  let fileManager = FileManager.default
  let root = fileManager.temporaryDirectory.appendingPathComponent(
    "AsterDiagnosticsTests-\(UUID().uuidString)", isDirectory: true)
  defer { try? fileManager.removeItem(at: root) }

  let diagnostics = DiagnosticsCenter(rootDirectory: root, fileManager: fileManager)
  diagnostics.start()
  diagnostics.record(
    "test.operation_failed", level: .error, category: .integration,
    attributes: ["state": "retryable", "path": "/private/project", "token": "secret-value"],
    error: NSError(domain: "AsterDiagnosticsTests", code: 17, userInfo: [
      NSLocalizedDescriptionKey: "contains a private path /private/project",
    ])
  )
  diagnostics.finish(reason: "test_complete")

  let summary = diagnostics.summary()
  #expect(summary.fileCount == 1)
  let logURL = try #require(
    try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).first)
  let log = try String(contentsOf: logURL, encoding: .utf8)
  #expect(log.contains("retryable"))
  #expect(!log.contains("/private/project"))
  #expect(!log.contains("secret-value"))
  #expect(!log.contains("contains a private path"))

  let archive = try diagnostics.makeFeedbackArchive(note: "复现步骤：打开设置后失败")
  defer { try? fileManager.removeItem(at: archive) }
  let extracted = fileManager.temporaryDirectory.appendingPathComponent(
    "AsterDiagnosticsExtracted-\(UUID().uuidString)", isDirectory: true)
  defer { try? fileManager.removeItem(at: extracted) }
  try fileManager.createDirectory(at: extracted, withIntermediateDirectories: true)
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
  process.arguments = ["-x", "-k", archive.path, extracted.path]
  try process.run()
  process.waitUntilExit()
  #expect(process.terminationStatus == 0)

  let contents = extracted.appendingPathComponent("Aster-Diagnostics", isDirectory: true)
  #expect(fileManager.fileExists(atPath: contents.appendingPathComponent("manifest.json").path))
  #expect(fileManager.fileExists(atPath: contents.appendingPathComponent("user-note.txt").path))
  #expect(!fileManager.fileExists(atPath: contents.appendingPathComponent("configuration.json").path))
}
