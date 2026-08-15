import AppKit
import AsterCore
import Foundation
import Testing

@testable import Aster

// Agent 会话标题投影回归：打开 Agent 后，标签行与标题栏胶囊应显示会话标题。
// 绑定只按 provider + session ID 精确匹配，标题清洗失败（仍等于文件名）视为无标题。

@Test("精确绑定的 Agent 会话标题投影到标签展示名，无效标题回落自动标题")
@MainActor
func agentSessionTitleProjectsToTabDisplayTitle() throws {
  let suiteName = "AgentSessionTitleProjectionTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  let terminal = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }
  let automaticTitle = tab.displayTitle

  // OSC 6974 建立精确绑定（provider + session ID），历史刷新后标题即投影到标签。
  terminal.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .processing, sessionID: "session-abc"))
  model.replaceAgentHistoriesForTesting([makeTitledHistory(id: "session-abc", title: "重构登录重连逻辑")])

  #expect(tab.displayTitle == "重构登录重连逻辑")
  #expect(tab.activeAgentSessionTitle == "重构登录重连逻辑")

  // 标题清洗后仍等于文件名（没有有效用户消息）视为无标题，不能把会话文件名当标签名。
  model.replaceAgentHistoriesForTesting([makeTitledHistory(id: "session-abc", title: "session-abc")])
  #expect(tab.displayTitle == automaticTitle)
  #expect(tab.activeAgentSessionTitle == nil)

  // 会话 ID 不匹配时不得松散借用其它会话的标题。
  terminal.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .processing, sessionID: "session-xyz"))
  model.replaceAgentHistoriesForTesting([makeTitledHistory(id: "session-abc", title: "别的会话")])
  #expect(tab.activeAgentSessionTitle == nil)
}

@Test("用户固定标签名优先于 Agent 会话标题")
@MainActor
func fixedTabNameOverridesAgentSessionTitle() throws {
  let suiteName = "AgentSessionTitleProjectionTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let preferences = AppPreferences(defaults: defaults)
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  let tab = try #require(model.selectedTab)
  let session = try #require(tab.activeSession)
  let terminal = try #require(
    session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }

  terminal.onAgentTerminalDirective?(
    AgentTerminalDirective(provider: .codex, signal: .processing, sessionID: "session-abc"))
  model.replaceAgentHistoriesForTesting([makeTitledHistory(id: "session-abc", title: "会话标题")])
  #expect(tab.displayTitle == "会话标题")

  tab.setTabTitleOverride(.name("我的固定名"))
  #expect(tab.displayTitle == "我的固定名")
  // 固定名生效期间胶囊也不显示会话标题，两处展示读同一真值。
  #expect(tab.activeAgentSessionTitle == nil)

  tab.setTabTitleOverride(.automatic)
  #expect(tab.displayTitle == "会话标题")
}

@Test("标题栏胶囊有会话标题时显示标题，工作目录退到 toolTip")
@MainActor
func titleCapsulePrefersAgentSessionTitle() {
  let button = WorkspaceTitleButton(
    programTitle: "zsh",
    workingDirectory: "/Users/mike/source",
    foregroundColor: .white,
    backgroundColor: nil
  ) { _ in }
  #expect(button.title.contains("source"))

  button.agentSessionTitle = "重构登录重连逻辑"
  #expect(button.title == "重构登录重连逻辑 ⋯")
  #expect(button.toolTip == "/Users/mike/source")

  button.agentSessionTitle = nil
  #expect(button.title.hasSuffix("⋯"))
  #expect(button.title.contains("source"))
}

@Test("从历史打开 transcript：新标签承载、标签名用会话标题、重复打开只聚焦")
@MainActor
func openingAgentTranscriptCreatesTitledTabOnce() throws {
  let suiteName = "AgentSessionTitleProjectionTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suiteName))
  defaults.removePersistentDomain(forName: suiteName)
  defer { defaults.removePersistentDomain(forName: suiteName) }
  let model = AppModel(defaults: defaults)
  model.ensureInitialTab()
  defer { model.selectedTab?.activeSession?.stop(immediately: true) }

  // openResource 只接受真实普通文件；transcript 用临时 JSONL 文件充当。
  let transcriptURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-transcript-\(UUID().uuidString).jsonl")
  try Data("{}\n".utf8).write(to: transcriptURL)
  defer { try? FileManager.default.removeItem(at: transcriptURL) }

  var history = makeTitledHistory(id: "session-open", title: "调试 tab 补全功能的目录问题")
  history = AgentSessionHistory(
    metadata: AgentSessionMetadata(
      id: history.metadata.id,
      configuration: history.metadata.configuration,
      projectDirectory: history.metadata.projectDirectory,
      title: history.metadata.title,
      createdAt: history.metadata.createdAt,
      updatedAt: history.metadata.updatedAt,
      transcriptFileURL: transcriptURL
    ),
    transcript: history.transcript
  )
  model.replaceAgentHistoriesForTesting([history])

  let initialCount = model.tabs.count
  model.openAgentTranscriptTab(history.metadata)
  #expect(model.tabs.count == initialCount + 1)
  let opened = try #require(model.selectedTab)
  let pane = try #require(opened.layout.allPanes.first)
  #expect(pane.kind == .preview)
  #expect(pane.resourcePath == transcriptURL.path)
  #expect(opened.displayTitle == "调试 tab 补全功能的目录问题")

  // 再次打开同一会话：不重复建标签，只把已有标签选中。
  model.selectedTabID = model.tabs.first?.id
  model.openAgentTranscriptTab(history.metadata)
  #expect(model.tabs.count == initialCount + 1)
  #expect(model.selectedTabID == opened.id)
}

@Test("transcript HTML 渲染：角色视觉区分、Markdown 渲染、工具折叠与转义")
func transcriptHTMLDistinguishesRolesAndCollapsesTools() {
  let entries = [
    AgentTranscriptEntry(
      sourceRecordIndex: 0,
      kind: .message(role: .user),
      timestamp: Date(timeIntervalSince1970: 0),
      text: "修复 <bug> 并 & 验证"
    ),
    AgentTranscriptEntry(
      sourceRecordIndex: 1, kind: .toolCall(name: "Bash"), timestamp: nil, text: "swift build"),
    AgentTranscriptEntry(
      sourceRecordIndex: 2, kind: .toolCall(name: "Bash"), timestamp: nil, text: "swift test"),
    AgentTranscriptEntry(
      sourceRecordIndex: 3, kind: .toolCall(name: "Edit"), timestamp: nil, text: "patch"),
    AgentTranscriptEntry(
      sourceRecordIndex: 4,
      kind: .message(role: .assistant),
      timestamp: nil,
      text: "**做了什么**\n\n- 修复完成"
    ),
  ]
  let html = AgentTranscriptHTML.body(entries: entries)
  // 用户消息进卡片且原文转义；Claude 消息按 Markdown 渲染出真实标签。
  #expect(html.contains("class=\"you\""))
  #expect(html.contains("修复 &lt;bug&gt; 并 &amp; 验证"))
  #expect(html.contains("class=\"claude\""))
  #expect(html.contains("<strong>做了什么</strong>"))
  #expect(html.contains("<li>") || html.contains("<ul>"))
  // 连续工具调用折叠为一行摘要：计数按名称聚合并保持出现顺序。
  #expect(html.contains("<details class=\"tools\">"))
  #expect(html.contains("2×Bash, 1×Edit"))
}

@Test("超大 transcript 渲染有界：总量与单条双重截断，附明确说明")
func hugeTranscriptRendersBoundedHTML() {
  // 3,000 条 × 2,000 字符 ≈ 6 MB 正文。曾经的逐条 NSTextField 实现会在这里把主线程
  // 卡死；现在拼装必须在总量上限处停下，且耗时可忽略。
  let entries = (0..<3_000).map { index in
    AgentTranscriptEntry(
      sourceRecordIndex: index,
      kind: .message(role: index % 2 == 0 ? .user : .assistant),
      timestamp: Date(),
      text: String(repeating: "内容x", count: 500)
    )
  }
  let html = AgentTranscriptHTML.body(entries: entries)
  #expect(html.count < 900_000)
  #expect(html.contains("未显示"))

  let single = AgentTranscriptHTML.body(entries: [
    AgentTranscriptEntry(
      sourceRecordIndex: 0,
      kind: .message(role: .user),
      timestamp: Date(),
      text: String(repeating: "y", count: 50_000)
    )
  ])
  #expect(single.contains("已截断"))
  #expect(single.count < 8_000)
}

/// 构造带指定标题的最小 Agent 会话历史。
@MainActor
private func makeTitledHistory(id: String, title: String) -> AgentSessionHistory {
  AgentSessionHistory(
    metadata: AgentSessionMetadata(
      id: id,
      configuration: .init(provider: .codex),
      projectDirectory: "/tmp",
      title: title,
      createdAt: .distantPast,
      updatedAt: Date(),
      transcriptFileURL: URL(fileURLWithPath: "/tmp/\(id).jsonl")
    ),
    transcript: AgentTranscriptReport(entries: [], skippedRecordCount: 0, truncatedEntryCount: 0)
  )
}
