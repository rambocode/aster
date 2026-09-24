// 使用频次（全局 / 目录两层）、命令间上下文转移与脏历史过滤对补全排序的影响。
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

@Test("其它目录的使用习惯让新目录里的命令名优先补常用命令")
@MainActor
func usageRankingPrefersGloballyUsedCommandName() throws {
  let root = try makeUsageRankingDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try makeUsageRankingService(root)
  let fresh = root.appendingPathComponent("fresh").path
  let before = service.suggestions(
    line: "cl", directory: fresh, sessionIdentifier: "s", controls: .init())
  #expect(before.candidates.first?.insertText != "claude")

  for _ in 0..<3 {
    service.record(
      command: "claude --continue", directory: root.appendingPathComponent("other").path,
      exitStatus: 0, ignorePatterns: [], knownOptions: [], sessionIdentifier: "s")
  }
  let after = service.suggestions(
    line: "cl", directory: fresh, sessionIdentifier: "s", controls: .init())

  #expect(after.candidates.first?.insertText == "claude")
  #expect(after.ghostText == "aude")
}

@Test("常用子命令在同前缀子命令中靠前")
@MainActor
func usageRankingPrefersUsedSubcommand() throws {
  let root = try makeUsageRankingDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try makeUsageRankingService(root)
  let fresh = root.appendingPathComponent("fresh").path
  let before = service.suggestions(
    line: "git ch", directory: fresh, sessionIdentifier: "s", controls: .init())
  #expect(before.candidates.first?.insertText != "cherry-pick")

  for hash in ["a1", "b2"] {
    service.record(
      command: "git cherry-pick \(hash)", directory: root.appendingPathComponent("other").path,
      exitStatus: 0, ignorePatterns: [], knownOptions: [], sessionIdentifier: "s")
  }
  let after = service.suggestions(
    line: "git ch", directory: fresh, sessionIdentifier: "s", controls: .init())

  #expect(after.candidates.first?.insertText == "cherry-pick")
}

@Test("用过的参数值跨目录补出，有活数据的槽位（git 分支）不混入别的仓库的值")
@MainActor
func usageRankingOffersGlobalArgumentValues() throws {
  let root = try makeUsageRankingDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try makeUsageRankingService(root)
  let other = root.appendingPathComponent("other").path
  for command in ["ssh build-mac", "git checkout feat/elsewhere"] {
    service.record(
      command: command, directory: other, exitStatus: 0, ignorePatterns: [],
      knownOptions: [], sessionIdentifier: "s")
  }
  let fresh = root.appendingPathComponent("fresh").path
  func query(_ line: String) -> AutocompleteResult {
    service.suggestions(line: line, directory: fresh, sessionIdentifier: "s", controls: .init())
  }

  #expect(query("ssh b").candidates.contains { $0.displayText == "build-mac" })
  #expect(!query("git checkout f").candidates.contains { $0.displayText == "feat/elsewhere" })
}

@Test("上一条命令决定下一条的推荐：git add 之后先推荐 git commit")
@MainActor
func usageRankingUsesPreviousCommandContext() throws {
  let root = try makeUsageRankingDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try makeUsageRankingService(root)
  let project = root.appendingPathComponent("project").path
  func run(_ command: String, exitStatus: Int = 0) {
    service.record(
      command: command, directory: project, exitStatus: exitStatus, ignorePatterns: [],
      knownOptions: [], sessionIdentifier: "s")
  }
  for _ in 0..<3 {
    run("git add .")
    run("git commit -m wip")
  }
  run("git add .")

  let afterAdd = service.suggestions(
    line: "git ", directory: project, sessionIdentifier: "s", controls: .init())
  #expect(afterAdd.candidates.first?.resultingLine(from: "git ")?.hasPrefix("git commit") == true)

  // 失败的命令断开上下文：不再按 git add 的转移加分。
  run("git add missing-file", exitStatus: 1)
  let afterFailure = service.suggestions(
    line: "git ", directory: project, sessionIdentifier: "s", controls: .init())
  let commitScore = afterFailure.candidates.first {
    $0.resultingLine(from: "git ") == "git commit -m wip"
  }?.score
  let addScore = afterAdd.candidates.first {
    $0.resultingLine(from: "git ") == "git commit -m wip"
  }?.score
  #expect(commitScore != nil && addScore != nil && commitScore! < addScore!)
}

@Test("清空历史同时清空命令转移")
@MainActor
func usageRankingClearsTransitionsWithHistory() throws {
  let root = try makeUsageRankingDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try makeUsageRankingService(root)
  let project = root.appendingPathComponent("project").path
  for command in ["ls", "pwd", "ls", "pwd", "ls"] {
    service.record(
      command: command, directory: project, exitStatus: 0, ignorePatterns: [],
      knownOptions: [], sessionIdentifier: "s")
  }
  let transitionsURL = root.appendingPathComponent("state/transitions.json")
  #expect(FileManager.default.fileExists(atPath: transitionsURL.path))

  try service.clearLearning()
  let reloaded = try makeUsageRankingService(root)

  let data = try Data(contentsOf: transitionsURL)
  let table = try JSONDecoder().decode(AutocompleteTransitionTable.self, from: data)
  #expect(table.counts.isEmpty)
  #expect(reloaded.suggestions(
    line: "", directory: project, sessionIdentifier: "s", controls: .init()
  ).candidates.isEmpty)
}

@Test("终端应答残留与 TUI 的 ! 前缀不进入学习")
@MainActor
func usageRankingRejectsImplausibleCommands() throws {
  let root = try makeUsageRankingDirectory()
  defer { try? FileManager.default.removeItem(at: root) }
  let service = try makeUsageRankingService(root)
  func record(_ command: String) -> Bool {
    service.record(
      command: command, directory: root.path, exitStatus: 0, ignorePatterns: [],
      knownOptions: [], sessionIdentifier: "s")
  }

  #expect(!record("11;rgb:ffff/ffff/ffff>|ghostty 1.3.2"))
  #expect(!record("! ssh host uptime"))
  #expect(record("ls -la"))
  #expect(AutocompleteLearningDatabase.isPlausibleCommand("7z x archive.7z"))
  #expect(AutocompleteLearningDatabase.isPlausibleCommand("2to3 script.py"))
}

@Test("转移加分：只出现一次的巧合不加分，重复出现才加分且有上限")
func transitionTableDiscountsSingleObservation() throws {
  let spec = AutocompleteSpecDatabase(sourceRevision: "test", commands: [])
  var table = AutocompleteTransitionTable()
  table.record(previous: "make", next: "ls", specDatabase: spec)
  let once = table.bonus(previous: "make", candidateLine: "ls -la", specDatabase: spec)
  for _ in 0..<50 { table.record(previous: "make", next: "ls", specDatabase: spec) }
  let many = table.bonus(previous: "make", candidateLine: "ls", specDatabase: spec)

  #expect(once < 20)
  #expect(many > once)
  #expect(many <= AutocompleteTransitionTable.maximumBonus)
  #expect(table.bonus(previous: "pwd", candidateLine: "ls", specDatabase: spec) == 0)
}

@MainActor
private func makeUsageRankingService(_ root: URL) throws -> AutocompleteService {
  try AutocompleteService(
    baseDirectory: root.appendingPathComponent("state", isDirectory: true),
    bundledSpecURL: URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .appendingPathComponent("Resources/autocomplete/fig-specs.json"))
}

private func makeUsageRankingDirectory() throws -> URL {
  let url = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-usage-ranking-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  return url
}
