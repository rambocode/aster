import Foundation
import Testing

@testable import AsterCore

/// 固定 session id 让行 id 断言稳定。
private let timelineSessionID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
private let timelineEpoch = Date(timeIntervalSince1970: 1_700_000_000)

/// 构造一条事件；只写测试关心的字段，其余走默认值。
private func event(
  _ sequence: Int,
  _ kind: MemoryEventKind,
  command: String? = nil,
  workingDirectory: String? = nil,
  exitStatus: Int? = nil,
  outputExcerpt: String? = nil,
  source: MemoryEventSource? = nil,
  payload: String? = nil
) -> RecordedEvent {
  RecordedEvent(
    sessionID: timelineSessionID,
    sequence: sequence,
    timestamp: timelineEpoch.addingTimeInterval(TimeInterval(sequence)),
    kind: kind,
    command: command,
    workingDirectory: workingDirectory,
    exitStatus: exitStatus,
    outputExcerpt: outputExcerpt,
    source: source,
    payload: payload
  )
}

@Test("命令吸收其完成事件与输出摘录，合成单行并带退出状态")
func timelineMergesCommandFinishedAndOutput() throws {
  let rows = SessionTimelineProjection.rows(for: [
    event(1, .shellCommand, command: "swift build", workingDirectory: "/repo"),
    event(2, .commandOutput, outputExcerpt: "error: no such module\n第二行"),
    event(3, .commandFinished, exitStatus: 1),
  ])

  #expect(rows.count == 1)
  let row = try #require(rows.first)
  #expect(row.kind == .command)
  #expect(row.title == "swift build")
  #expect(row.subtitle == "/repo")
  #expect(row.status == .failed(1))
  #expect(row.status.displayText == "✗ 1")
  #expect(row.status.isFailure)
  #expect(row.detail?.excerpt == "error: no such module\n第二行")
  // 调用方没有提供 artifact 集合时不得给出「查看全文」入口。
  #expect(row.detail?.artifactRelativePath == nil)
  #expect(row.id == "\(timelineSessionID.uuidString)#1")
}

@Test("完成事件只归属窗口内的命令，不跨越下一条命令配对")
func timelineDoesNotPairAcrossNextCommand() throws {
  let rows = SessionTimelineProjection.rows(for: [
    event(1, .shellCommand, command: "first"),
    event(2, .shellCommand, command: "second"),
    event(3, .commandFinished, exitStatus: 0),
  ])

  #expect(rows.map(\.title) == ["first", "second"])
  // 第一条没有落在自己窗口内的完成事件，只能是运行中；退出码属于第二条。
  #expect(rows[0].status == .running)
  #expect(rows[1].status == .succeeded)
}

@Test("shell 未提供退出码时按未知状态显示，绝不猜成功")
func timelineNeverGuessesSuccessWithoutExitStatus() throws {
  let rows = SessionTimelineProjection.rows(for: [
    event(1, .shellCommand, command: "ssh remote"),
    event(2, .commandFinished, exitStatus: nil),
  ])

  #expect(rows.count == 1)
  #expect(rows[0].status == .finishedUnknown)
  #expect(rows[0].status.isFailure == false)
  #expect(rows[0].status.displayText == "—")
}

@Test("session 起止事件不产生时间线行，孤立事件仍各自成行")
func timelineSkipsSessionBoundariesButKeepsOrphans() throws {
  let rows = SessionTimelineProjection.rows(for: [
    event(1, .sessionStarted),
    event(2, .commandFinished, exitStatus: 130),
    event(3, .commandOutput, outputExcerpt: "interrupted"),
    event(4, .sessionEnded),
  ])

  #expect(rows.count == 2)
  #expect(rows[0].kind == .command)
  #expect(rows[0].title == "(未知命令)")
  #expect(rows[0].status == .failed(130))
  #expect(rows[1].kind == .output)
  #expect(rows[1].title == "输出摘录")
  #expect(rows[1].subtitle == "interrupted")
}

@Test("artifact 仍存在时才给出查看全文的相对路径")
func timelineExposesArtifactOnlyWhenPresent() throws {
  let path = MemoryTranscriptLayout.relativePath(sessionID: timelineSessionID, sequence: 2)
  let events = [
    event(1, .shellCommand, command: "make test"),
    event(2, .commandOutput, outputExcerpt: "tail"),
  ]

  let without = SessionTimelineProjection.rows(for: events)
  #expect(without[0].detail?.artifactRelativePath == nil)

  let with = SessionTimelineProjection.rows(for: events, artifactPaths: [path])
  #expect(with[0].detail?.artifactRelativePath == path)
  // 配额轮转删掉的正文不该留下死链接。
  let stale = SessionTimelineProjection.rows(for: events, artifactPaths: ["transcripts/other.txt"])
  #expect(stale[0].detail?.artifactRelativePath == nil)
}

@Test("transcript 补录的工具调用与文件事件从 payload 取名并标注来源")
func timelineProjectsTranscriptEvents() throws {
  let rows = SessionTimelineProjection.rows(for: [
    event(
      1, .agentToolCall, source: .transcript,
      payload: #"{"tool":"Edit","path":"/repo/Sources/App.swift"}"#),
    event(
      2, .fileModified, source: .transcript,
      payload: #"{"path":"/repo/Sources/App.swift"}"#),
    event(3, .fileRead, source: .transcript, payload: #"{"file_path":"/repo/README.md"}"#),
  ])

  #expect(rows.map(\.kind) == [.toolCall, .fileModified, .fileRead])
  #expect(rows[0].title == "Edit")
  #expect(rows[0].subtitle == "/repo/Sources/App.swift")
  #expect(rows[1].title == "App.swift")
  #expect(rows[1].subtitle == "/repo/Sources/App.swift")
  #expect(rows[2].title == "README.md")
  // 来自 Agent 自己的记录而非终端实测，视图必须能区分。
  #expect(rows.allSatisfy { $0.isTranscriptSourced })
  #expect(rows[0].symbol == SessionTimelineRowKind.toolCall.symbol)
}

@Test("payload 缺失或格式漂移时降级为可读占位，不丢行")
func timelineToleratesBrokenPayload() throws {
  let rows = SessionTimelineProjection.rows(for: [
    event(1, .agentToolCall, source: .transcript, payload: "not json"),
    event(2, .fileRead, source: .transcript, payload: nil),
  ])

  #expect(rows.count == 2)
  #expect(rows[0].title == "工具调用")
  #expect(rows[0].subtitle.isEmpty)
  #expect(rows[1].title == "(未知文件)")
}

@Test("git 快照按分支与脏文件数投影，无分支时显示 detached")
func timelineProjectsGitSnapshot() throws {
  let payload = try #require(
    GitSnapshotPayload(branch: "main", commit: "abcdef1234567", dirtyFileCount: 3).jsonString())
  let detached = try #require(
    GitSnapshotPayload(branch: nil, commit: nil, dirtyFileCount: 0).jsonString())
  let rows = SessionTimelineProjection.rows(for: [
    event(1, .gitStateSnapshot, source: .git, payload: payload),
    event(2, .gitStateSnapshot, source: .git, payload: detached),
  ])

  #expect(rows[0].title == "main")
  #expect(rows[0].subtitle == "abcdef1 · 3 处改动")
  #expect(rows[1].title == "detached")
  #expect(rows[1].subtitle.isEmpty)
}

@Test("Agent 状态行显示 provider 与关联的 agent session")
func timelineProjectsAgentState() throws {
  let rows = SessionTimelineProjection.rows(for: [
    event(
      1, .agentStateChanged, command: "claude", source: .agentHook,
      payload: #"{"agent_session_id":"abc-123"}"#),
    event(2, .agentStateChanged, source: .agentHook),
  ])

  #expect(rows[0].title == "claude")
  #expect(rows[0].subtitle == "session abc-123")
  #expect(rows[1].title == "Agent 状态更新")
}

@Test("标题清洗掉控制字符与换行并限长")
func timelineSanitizesUntrustedText() throws {
  let noisy = "echo \u{1B}[31mred\u{1B}[0m\nsecond\tline"
  let long = String(repeating: "x", count: 400)
  let rows = SessionTimelineProjection.rows(for: [
    event(1, .shellCommand, command: noisy),
    event(2, .shellCommand, command: long),
  ])

  #expect(rows[0].title == "echo [31mred[0m second line")
  #expect(rows[0].title.contains("\u{1B}") == false)
  #expect(rows[0].title.contains("\n") == false)
  #expect(rows[1].title.count == SessionTimelineProjection.maximumTitleLength + 1)
  #expect(rows[1].title.hasSuffix("…"))
}

@Test("行按 seq 升序输出，乱序输入不会打乱时间线")
func timelineSortsBySequence() throws {
  let rows = SessionTimelineProjection.rows(for: [
    event(5, .shellCommand, command: "third"),
    event(1, .shellCommand, command: "first"),
    event(3, .shellCommand, command: "second"),
  ])

  #expect(rows.map(\.sequence) == [1, 3, 5])
  #expect(rows.map(\.title) == ["first", "second", "third"])
}

@Test("会话时长文本按量级切换单位，未结束返回 nil")
func timelineFormatsDuration() throws {
  let start = timelineEpoch
  #expect(SessionTimelineProjection.durationText(from: start, to: nil) == nil)
  #expect(SessionTimelineProjection.durationText(from: start, to: start.addingTimeInterval(42)) == "42 秒")
  #expect(SessionTimelineProjection.durationText(from: start, to: start.addingTimeInterval(600)) == "10 分钟")
  #expect(
    SessionTimelineProjection.durationText(from: start, to: start.addingTimeInterval(3_600))
      == "1 小时")
  #expect(
    SessionTimelineProjection.durationText(from: start, to: start.addingTimeInterval(7_500))
      == "2 小时 5 分")
}

@Test("空事件流产生空时间线")
func timelineHandlesEmptyInput() {
  #expect(SessionTimelineProjection.rows(for: []).isEmpty)
}
