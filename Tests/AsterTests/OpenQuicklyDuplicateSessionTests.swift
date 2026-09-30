// Open Quickly 候选 id 唯一性：不同目录下同名会话文件不能让浮层崩溃。
import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

/// 一条只含一个用户提问的会话历史；`directory` 决定 transcript 所在目录。
private func sameNamedHistory(in directory: String) -> AgentSessionHistory {
  AgentSessionHistory(
    metadata: AgentSessionMetadata(
      id: "journal",
      configuration: .init(provider: .claudeCode),
      projectDirectory: directory,
      title: "journal @ \(directory)",
      createdAt: .distantPast,
      updatedAt: Date(),
      transcriptFileURL: URL(fileURLWithPath: "\(directory)/journal.jsonl")),
    transcript: AgentTranscriptReport(
      entries: [
        AgentTranscriptEntry(
          sourceRecordIndex: 0, kind: .message(role: .user), timestamp: Date(), text: "hello from \(directory)")
      ],
      skippedRecordCount: 0, truncatedEntryCount: 0))
}

@Test("两个目录里都有 journal.jsonl 时 Open Quickly 不崩溃，两条会话都列出")
@MainActor
func openQuicklyKeepsSameNamedSessionsFromDifferentDirectories() throws {
  _ = NSApplication.shared
  let suite = "AsterOpenQuicklyDuplicate.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defer { defaults.removePersistentDomain(forName: suite) }
  let model = AppModel(defaults: defaults)
  model.replaceAgentHistoriesForTesting([
    sameNamedHistory(in: "/tmp/aster-dup-a"), sameNamedHistory(in: "/tmp/aster-dup-b"),
  ])

  let controller = OpenQuicklyOverlayViewController(model: model)
  controller.loadViewIfNeeded()

  let ids = controller.targetIDsForTesting
  #expect(Set(ids).count == ids.count)
  #expect(ids.filter { $0.hasPrefix("agent:claudeCode:") }.count == 2)
}
