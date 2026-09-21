import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

// 运行中会话的标题探测回归：标题在首条 prompt 后才写盘，标签要在几秒内跟上，
// 且不能靠全量历史扫描；没有 prompt 的会话不应反复读盘。

/// 临时主目录，带 Claude 会话文件的读写辅助。
private struct ProbeHome {
  let url: URL

  init() throws {
    url = FileManager.default.temporaryDirectory
      .appendingPathComponent("AgentSessionTitleProbeTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
  }

  func remove() { try? FileManager.default.removeItem(at: url) }

  /// 该项目目录下某会话的 transcript 路径（按 Claude 的目录编码）。
  func transcriptURL(project: String, sessionID: String) -> URL {
    url.appendingPathComponent(".claude/projects", isDirectory: true)
      .appendingPathComponent(
        AgentSessionFileLocator.claudeProjectDirectoryName(for: project), isDirectory: true)
      .appendingPathComponent("\(sessionID).jsonl")
  }

  /// 覆盖写 transcript：每个元素一行 JSONL。
  func write(_ lines: [String], project: String, sessionID: String) throws {
    let file = transcriptURL(project: project, sessionID: sessionID)
    try FileManager.default.createDirectory(
      at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data((lines.joined(separator: "\n") + "\n").utf8).write(to: file)
  }
}

private let userLine = #"{"type":"user","message":{"role":"user","content":"分页点两次才跳"}}"#

private func aiTitleLine(_ title: String) -> String {
  #"{"type":"ai-title","aiTitle":"\#(title)"}"#
}

@Test("探测只读一个会话文件：有标题记录才返回，/rename 的名字优先")
func probeReadsProviderTitleFromSingleTranscript() throws {
  let home = try ProbeHome()
  defer { home.remove() }
  let project = "/Users/me/app"

  // 只有用户消息、还没有标题记录：视为没有标题，不拿 prompt 冒充。
  try home.write([userLine], project: project, sessionID: "s-1")
  #expect(
    AgentSessionTitleProbe.titleSynchronously(
      provider: .claudeCode, sessionID: "s-1", workingDirectory: project, homeDirectory: home.url)
      == nil)

  try home.write([userLine, aiTitleLine("分页响应延迟")], project: project, sessionID: "s-1")
  #expect(
    AgentSessionTitleProbe.titleSynchronously(
      provider: .claudeCode, sessionID: "s-1", workingDirectory: project, homeDirectory: home.url)
      == "分页响应延迟")

  try home.write(
    [userLine, aiTitleLine("分页响应延迟"), #"{"type":"custom-title","customTitle":"我起的名"}"#],
    project: project, sessionID: "s-1")
  #expect(
    AgentSessionTitleProbe.titleSynchronously(
      provider: .claudeCode, sessionID: "s-1", workingDirectory: project, homeDirectory: home.url)
      == "我起的名")
}

@Test("Pane 已经 cd 到子目录时仍能按 session ID 找到启动目录下的会话文件")
func probeFindsTranscriptWhenWorkingDirectoryDrifted() throws {
  let home = try ProbeHome()
  defer { home.remove() }
  try home.write([aiTitleLine("候选人列表")], project: "/Users/me/app", sessionID: "s-2")

  #expect(
    AgentSessionTitleProbe.titleSynchronously(
      provider: .claudeCode, sessionID: "s-2", workingDirectory: "/Users/me/app/frontend",
      homeDirectory: home.url) == "候选人列表")
}

@Test("标题落在大文件尾部也能读到，且不整读文件")
func probeReadsTitleFromTailOfLargeTranscript() throws {
  let home = try ProbeHome()
  defer { home.remove() }
  // 约 1MB 的填充行把标题挤出文件头范围。
  let filler = #"{"type":"assistant","text":"\#(String(repeating: "x", count: 4_000))"}"#
  let lines = Array(repeating: filler, count: 260) + [aiTitleLine("尾部标题"), filler]
  try home.write(lines, project: "/Users/me/app", sessionID: "s-3")

  #expect(
    AgentSessionTitleProbe.titleSynchronously(
      provider: .claudeCode, sessionID: "s-3", workingDirectory: "/Users/me/app",
      homeDirectory: home.url) == "尾部标题")
}

@Test("session ID 带路径分隔符时拒绝拼路径")
func probeRejectsSessionIDThatEscapesProjectsRoot() throws {
  let home = try ProbeHome()
  defer { home.remove() }
  try home.write([aiTitleLine("不该被读到")], project: "/Users/me/app", sessionID: "s-4")

  for hostile in ["../-Users-me-app/s-4", "a/b", ".hidden", ""] {
    #expect(
      AgentSessionTitleProbe.claudeTranscriptURL(
        sessionID: hostile, workingDirectory: "/Users/me/app", homeDirectory: home.url) == nil)
  }
}

@Test("prompt 提交后标题稍后才写盘：重试序列把它接到标签上，单次探测不重试")
@MainActor
func trackerRetriesUntilTitleAppearsAfterPromptSubmitted() async throws {
  let home = try ProbeHome()
  defer { home.remove() }
  let project = "/Users/me/app"
  let paneID = UUID()
  let tracker = AgentSessionTitleTracker()
  tracker.retryDelays = [.milliseconds(30), .milliseconds(30), .milliseconds(30), .milliseconds(30)]
  tracker.bindingProvider = { id in
    id == paneID
      ? .init(
        provider: .claudeCode, sessionID: "s-5", workingDirectory: project, homeDirectory: home.url)
      : nil
  }
  var changes = 0
  tracker.onTitlesChanged = { changes += 1 }
  try home.write([userLine], project: project, sessionID: "s-5")

  // 刚打开会话、没有 prompt：只读一次，落空后不再读。
  tracker.probe(paneID: paneID, retrying: false)
  try await Task.sleep(for: .milliseconds(80))
  try home.write([userLine, aiTitleLine("晚到的标题")], project: project, sessionID: "s-5")
  try await Task.sleep(for: .milliseconds(120))
  #expect(tracker.title(provider: .claudeCode, sessionID: "s-5") == nil)

  // prompt 提交：第一次落空，标题写盘后的下一次重试读到。
  try home.write([userLine], project: project, sessionID: "s-5")
  tracker.probe(paneID: paneID, retrying: true)
  try await Task.sleep(for: .milliseconds(45))
  try home.write([userLine, aiTitleLine("晚到的标题")], project: project, sessionID: "s-5")
  try await waitUntil { tracker.title(provider: .claudeCode, sessionID: "s-5") != nil }
  #expect(tracker.title(provider: .claudeCode, sessionID: "s-5") == "晚到的标题")
  #expect(changes == 1)
}

@Test("重试用尽仍无标题才上报，供上层决定是否兜底重扫历史")
@MainActor
func trackerReportsExhaustedRetriesOnlyForRetrySeries() async throws {
  let home = try ProbeHome()
  defer { home.remove() }
  let paneID = UUID()
  let tracker = AgentSessionTitleTracker()
  tracker.retryDelays = [.milliseconds(10), .milliseconds(10)]
  tracker.bindingProvider = { _ in
    .init(
      provider: .claudeCode, sessionID: "s-6", workingDirectory: "/Users/me/app",
      homeDirectory: home.url)
  }
  var exhausted: [UUID] = []
  tracker.onRetriesExhausted = { exhausted.append($0) }

  tracker.probe(paneID: paneID, retrying: false)
  try await Task.sleep(for: .milliseconds(80))
  #expect(exhausted.isEmpty)

  tracker.probe(paneID: paneID, retrying: true)
  try await waitUntil { !exhausted.isEmpty }
  #expect(exhausted == [paneID])
}

@Test("Claude 会话提交首条 prompt 后，标签标题无需切换标签即可出现")
@MainActor
func claudeSessionTitleAppearsOnTabAfterFirstPrompt() async throws {
  let home = try ProbeHome()
  defer { home.remove() }
  let suiteName = "AgentSessionTitleProbeTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.agentSessionTitleTracker.retryDelays = Array(repeating: .milliseconds(30), count: 20)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  session.agentHomeDirectory = home.url
  let terminal = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }
  let project = session.resolvedCurrentWorkingDirectory()
  var titleEvents: [String] = []
  let subscription = tab.titleChanged.sink { titleEvents.append($0) }
  defer { subscription.cancel() }

  // 打开会话但还没提问：绑定建立，没有标题，也不会出现标题。
  terminal.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .claudeCode, signal: .idle, sessionID: "live-1"))
  try await Task.sleep(for: .milliseconds(100))
  #expect(tab.activeAgentSessionTitle == nil)

  // 提交 prompt：transcript 先只有用户消息，标题稍后追加。
  try home.write([userLine], project: project, sessionID: "live-1")
  terminal.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .claudeCode, signal: .processing, sessionID: "live-1"))
  try await Task.sleep(for: .milliseconds(60))
  try home.write([userLine, aiTitleLine("候选人列表分页响应延迟")], project: project, sessionID: "live-1")

  try await waitUntil { tab.activeAgentSessionTitle != nil }
  #expect(tab.displayTitle == "候选人列表分页响应延迟")
  // 走的是行内局部刷新通道，侧栏行不用等整树重建（切换标签）才更新。
  #expect(titleEvents.contains("候选人列表分页响应延迟"))
}

/// 轮询等待条件成立，最多 3 秒；超时由调用处的 #expect 报出具体差异。
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
  for _ in 0..<150 where !condition() {
    try await Task.sleep(for: .milliseconds(20))
  }
}
