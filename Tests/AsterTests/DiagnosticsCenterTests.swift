import AppKit
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

@Test("终端异常退出日志记录代次与规范化状态且不包含用户内容")
@MainActor
func terminalTerminationWritesPrivacySafeDiagnostics() async throws {
  _ = NSApplication.shared
  let fileManager = FileManager.default
  let root = fileManager.temporaryDirectory.appendingPathComponent(
    "AsterTerminalLifecycleDiagnostics-\(UUID().uuidString)", isDirectory: true)
  defer { try? fileManager.removeItem(at: root) }
  let diagnostics = DiagnosticsCenter(rootDirectory: root, fileManager: fileManager)
  diagnostics.start()

  let suiteName = "AsterTerminalLifecycleDiagnosticsDefaults-\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  let privateDirectory = fileManager.temporaryDirectory.appendingPathComponent(
    "private-workspace-\(UUID().uuidString)", isDirectory: true)
  try fileManager.createDirectory(at: privateDirectory, withIntermediateDirectories: true)
  defer { try? fileManager.removeItem(at: privateDirectory) }

  let session = TerminalSession(
    workingDirectory: privateDirectory.path,
    diagnostics: diagnostics
  )
  defer { session.stop(immediately: true) }
  _ = session.makeTerminalView(preferences: preferences)
  session.send("exit 7")
  for _ in 0..<100 where session.statusIsRunning {
    try await Task.sleep(for: .milliseconds(20))
  }

  #expect(session.lifecycleState == .ended(.exited(code: 7)))
  #expect(session.exitCode == 7)
  _ = diagnostics.summary()  // queue.sync：确保此前异步 record 已经写入磁盘。
  let logs = try fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
    .filter { $0.pathExtension == "jsonl" }
    .map { try String(contentsOf: $0, encoding: .utf8) }
    .joined(separator: "\n")

  #expect(logs.contains("terminal.process_started"))
  #expect(logs.contains("terminal.process_terminated"))
  #expect(logs.contains("\"outcome\":\"exited\""))
  #expect(logs.contains("\"exit_code\":\"7\""))
  #expect(logs.contains(session.id.uuidString.lowercased()))
  #expect(!logs.contains(privateDirectory.path))
  #expect(!logs.contains("exit 7"))
}
