import AsterCore
import Foundation
import Testing

/// 造一个临时 home，按 provider 布局写入会话文件；返回 home 与清理闭包。
private func makeHome() throws -> URL {
  let home = FileManager.default.temporaryDirectory
    .appendingPathComponent("AgentSessionFileLocatorTests.\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
  return home
}

private func write(_ url: URL, _ contents: String, modifiedAt: Date) throws {
  try FileManager.default.createDirectory(
    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try contents.write(to: url, atomically: true, encoding: .utf8)
  try FileManager.default.setAttributes([.modificationDate: modifiedAt], ofItemAtPath: url.path)
}

@Test("Claude 项目目录名把所有非字母数字字符换成 -")
func locatorEncodesClaudeProjectDirectory() {
  #expect(
    AgentSessionFileLocator.claudeProjectDirectoryName(for: "/Users/me/source/project/aster")
      == "-Users-me-source-project-aster")
  #expect(
    AgentSessionFileLocator.claudeProjectDirectoryName(for: "/Users/me/aster/.claude/worktrees/x")
      == "-Users-me-aster--claude-worktrees-x")
  #expect(AgentSessionFileLocator.claudeProjectDirectoryName(for: "/tmp/a b_c") == "-tmp-a-b-c")
}

@Test("Claude：命令开始后写过的最新 jsonl 就是本次会话；只有旧文件时报 latestUnknown；无目录报 none")
func locatorResolvesClaudeSessionByModificationTime() throws {
  let home = try makeHome()
  defer { try? FileManager.default.removeItem(at: home) }
  let project = "/Users/me/proj"
  let directory = home.appendingPathComponent(".claude/projects/-Users-me-proj", isDirectory: true)
  let started = Date()
  try write(directory.appendingPathComponent("old-session.jsonl"), "{}", modifiedAt: started.addingTimeInterval(-3_600))
  try write(directory.appendingPathComponent("aaaa-1111.jsonl"), "{}", modifiedAt: started.addingTimeInterval(20))
  try write(directory.appendingPathComponent("bbbb-2222.jsonl"), "{}", modifiedAt: started.addingTimeInterval(40))
  // 非 jsonl、隐藏文件不算会话。
  try write(directory.appendingPathComponent("notes.txt"), "x", modifiedAt: started.addingTimeInterval(90))

  #expect(
    AgentSessionFileLocator.resolve(
      provider: .claudeCode, projectDirectory: project + "/", homeDirectory: home, startedAfter: started)
      == .session(id: "bbbb-2222"))
  // 本次运行更晚开始：两个新文件都在窗口之前，只剩「该目录有会话但不是本次的」。
  #expect(
    AgentSessionFileLocator.resolve(
      provider: .claudeCode, projectDirectory: project, homeDirectory: home,
      startedAfter: started.addingTimeInterval(120))
      == .latestUnknown)
  // 不传开始时刻：直接取最新。
  #expect(
    AgentSessionFileLocator.resolve(
      provider: .claudeCode, projectDirectory: project, homeDirectory: home, startedAfter: nil)
      == .session(id: "bbbb-2222"))
  #expect(
    AgentSessionFileLocator.resolve(
      provider: .claudeCode, projectDirectory: "/Users/me/other", homeDirectory: home, startedAfter: started)
      == .none)
  // 其它 provider 不支持文件定位。
  #expect(
    AgentSessionFileLocator.resolve(
      provider: .gemini, projectDirectory: project, homeDirectory: home, startedAfter: started) == .none)
}

@Test("Codex：按日期目录扫 rollout，首行 session_meta 的 cwd 匹配项目目录才算")
func locatorResolvesCodexRolloutByCwd() throws {
  let home = try makeHome()
  defer { try? FileManager.default.removeItem(at: home) }
  var calendar = Calendar(identifier: .gregorian)
  calendar.timeZone = .current
  let parts = calendar.dateComponents([.year, .month, .day], from: Date())
  let day = home.appendingPathComponent(
    String(format: ".codex/sessions/%04d/%02d/%02d", parts.year!, parts.month!, parts.day!),
    isDirectory: true)
  let started = Date()
  func meta(id: String, cwd: String) -> String {
    #"{"timestamp":"t","type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)"}}"# + "\n{\"type\":\"other\"}\n"
  }
  try write(day.appendingPathComponent("rollout-2026-09-06T10-00-00-other.jsonl"),
    meta(id: "other-1", cwd: "/Users/me/elsewhere"), modifiedAt: started.addingTimeInterval(30))
  try write(day.appendingPathComponent("rollout-2026-09-06T09-00-00-mine.jsonl"),
    meta(id: "mine-1", cwd: "/Users/me/proj"), modifiedAt: started.addingTimeInterval(10))
  try write(day.appendingPathComponent("rollout-2026-09-05T09-00-00-old.jsonl"),
    meta(id: "old-1", cwd: "/Users/me/proj"), modifiedAt: started.addingTimeInterval(-7_200))

  #expect(
    AgentSessionFileLocator.resolve(
      provider: .codex, projectDirectory: "/Users/me/proj", homeDirectory: home, startedAfter: started)
      == .session(id: "mine-1"))
  #expect(
    AgentSessionFileLocator.resolve(
      provider: .codex, projectDirectory: "/Users/me/proj", homeDirectory: home,
      startedAfter: started.addingTimeInterval(60))
      == .latestUnknown)
  #expect(
    AgentSessionFileLocator.resolve(
      provider: .codex, projectDirectory: "/Users/me/nothing", homeDirectory: home, startedAfter: started)
      == .none)
}
