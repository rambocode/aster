import AsterCore
import Foundation
import Testing

@testable import Aster
@testable import AsterCore

/// 方法分发：只读、写门禁、agent 语义与等待。用隔离 defaults 的 AppModel + 真实 TerminalSession。
@Suite(.serialized)
@MainActor
struct AsterControlDispatcherTests {
  private struct Fixture {
    let workspace: ControlTestWorkspace
    let bridge: AsterControlBridge
    let dispatcher: AsterControlDispatcher
    let client: ControlFakeClient
    var policy: AsterControlDispatcher.Policy

    func call(_ method: String, _ params: JSONValue? = nil) async -> AsterControlResponse {
      await dispatcher.handle(controlRequest(method, params), client: client)
    }
  }

  private final class PolicyBox {
    var policy = AsterControlDispatcher.Policy(allowSendKeys: true, allowSensitiveSessions: false, shell: AsterConfiguration().shell)
  }

  private func makeFixture(allowSendKeys: Bool = true) throws -> (Fixture, PolicyBox) {
    let workspace = try ControlTestWorkspace()
    let bridge = AsterControlBridge(socketPath: "/tmp/test.sock", binaryPath: "/tmp/aster-cli")
    bridge.activeModelProvider = { [weak model = workspace.model] in model }
    bridge.attach(model: workspace.model)
    let box = PolicyBox()
    box.policy.allowSendKeys = allowSendKeys
    let dispatcher = AsterControlDispatcher(bridge: bridge, version: "9.9.9") { box.policy }
    dispatcher.promptStallMilliseconds = 1_000
    dispatcher.startSettleMilliseconds = 300
    let fixture = Fixture(workspace: workspace, bridge: bridge, dispatcher: dispatcher, client: ControlFakeClient(), policy: box.policy)
    return (fixture, box)
  }

  @Test("ping / snapshot / agent.list 空 / 未知方法 / 协议版本不匹配")
  func readOnlyBasics() async throws {
    let (fixture, _) = try makeFixture()
    defer { fixture.workspace.tearDown() }
    let ping = await fixture.call("server.ping")
    #expect(ping.result?["protocol"]?.intValue == 1)
    #expect(ping.result?["version"]?.stringValue == "9.9.9")

    let snapshot = await fixture.call("session.snapshot")
    let decoded = try #require(snapshot.result).decoded(as: SessionSnapshot.self)
    #expect(decoded.windows.count == 1)
    #expect(decoded.windows[0].windowID == "w1")
    #expect(decoded.windows[0].tabs.first?.tabID == "w1:t1")
    #expect(decoded.windows[0].tabs.first?.panes.first?.paneID == "w1:p1")

    let list = await fixture.call("agent.list")
    #expect(list.result?["agents"]?.arrayValue?.isEmpty == true)

    #expect(await fixture.call("agent.explode").error?.code == .methodNotFound)
    let mismatch = await fixture.dispatcher.handle(
      AsterControlRequest(id: 1, method: "server.ping", protocolVersion: 7), client: fixture.client)
    #expect(mismatch.error?.code == .protocolMismatch)
    #expect(await fixture.call("agent.get", ["target": "w9:p9"]).error?.code == .notFound)
    #expect(await fixture.call("agent.get", ["target": "w1:p1"]).error?.code == .agentNotFound)
    #expect(await fixture.call("agent.get", ["target": "builder"]).error?.code == .agentNotFound)
    #expect(await fixture.call("agent.read", ["target": "w1:p1", "lines": 0]).error?.code == .invalidParams)
  }

  @Test("hook 注入后 agent.list/get 反映状态；prompt 对 blocked 返回 agent_blocked 且不写 PTY")
  func agentStatusAndBlockedPrompt() async throws {
    let (fixture, _) = try makeFixture()
    defer { fixture.workspace.tearDown() }
    let (session, view) = try fixture.workspace.makeActiveTerminalView()
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .processing, sessionID: "s1"))
    await pumpControlEvents()

    let list = await fixture.call("agent.list")
    let agents = try #require(list.result?["agents"]).decoded(as: [AgentInfo].self)
    #expect(agents.count == 1)
    #expect(agents[0].agent == "codex")
    #expect(agents[0].agentStatus == .working)
    #expect(agents[0].detection == .hook)
    #expect(agents[0].sessionID == "s1")
    #expect(agents[0].paneID == "w1:p1")

    // agent name / current 都能解析到同一 pane。
    #expect(await fixture.call("agent.get", ["target": "codex"]).result?["pane_id"]?.stringValue == "w1:p1")
    #expect(await fixture.call("agent.get", ["target": "current"]).result?["pane_id"]?.stringValue == "w1:p1")

    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .awaitingInput))
    await pumpControlEvents()
    #expect(await fixture.call("agent.get", ["target": "w1:p1"]).result?["agent_status"]?.stringValue == "blocked")

    let prompt = await fixture.call("agent.prompt", ["target": "w1:p1", "text": "continue"])
    #expect(prompt.error?.code == .agentBlocked)
    // 没有写入 PTY：写入会触发用户输入回调把状态翻回 processing。
    #expect(session.agentTaskState == .awaitingInput)

    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .idle))
    await pumpControlEvents()
    let done = await fixture.call("agent.get", ["target": "w1:p1"])
    #expect(done.result?["agent_status"]?.stringValue == "done")
    // focus 标记已看见：done → idle；read 不改变状态。
    _ = await fixture.call("agent.read", ["target": "w1:p1"])
    #expect(session.agentTaskCompletionUnread)
    _ = await fixture.call("agent.focus", ["target": "w1:p1"])
    #expect(!session.agentTaskCompletionUnread)
    await pumpControlEvents()
    #expect(await fixture.call("agent.get", ["target": "w1:p1"]).result?["agent_status"]?.stringValue == "idle")
  }

  @Test("写门禁：write_not_allowed / write_rejected（只读）")
  func writeGate() async throws {
    let (fixture, box) = try makeFixture(allowSendKeys: false)
    defer { fixture.workspace.tearDown() }
    _ = try fixture.workspace.makeActiveTerminalView()
    #expect(await fixture.call("pane.send_text", ["pane": "w1:p1", "text": "ls"]).error?.code == .writeNotAllowed)
    #expect(await fixture.call("pane.send_keys", ["pane": "w1:p1", "keys": ["enter"]]).error?.code == .writeNotAllowed)
    // focus 不是写操作，门禁关闭也允许。
    #expect(await fixture.call("pane.focus", ["pane": "w1:p1"]).error == nil)

    box.policy.allowSendKeys = true
    let runtime = try #require(fixture.workspace.model.selectedTab?.activeRuntime)
    runtime.setReadOnly(true)
    #expect(await fixture.call("pane.send_text", ["pane": "w1:p1", "text": "ls"]).error?.code == .writeRejected)
    runtime.setReadOnly(false)
    #expect(await fixture.call("pane.send_text", ["pane": "w1:p1", "text": "\u{1B}[A"]).error?.code == .invalidParams)
  }

  @Test("pane.send_text 真实 PTY 回显，pane.read / wait_for_output 能读到")
  func sendTextAndReadEcho() async throws {
    let (fixture, _) = try makeFixture()
    defer { fixture.workspace.tearDown() }
    _ = try fixture.workspace.makeActiveTerminalView()
    let marker = "aster-ctl-\(UUID().uuidString.prefix(6))"
    // 用 printf 拼接避免命令行本身（回显）先于输出命中。
    let command = "printf '%s\\n' \(marker.prefix(9))\"\(marker.dropFirst(9))\""
    let sent = await fixture.call("pane.send_text", ["pane": "current", "text": .string(command), "enter": true])
    #expect(sent.error == nil)
    let expected = "\n\(marker)"
    let waited = await fixture.call("pane.wait_for_output", ["pane": "w1:p1", "match": .string(expected), "timeout_ms": 8_000])
    #expect(waited.error == nil, "\(String(describing: waited.error))")
    #expect(waited.result?["matched"]?.stringValue == expected)
    let read = await fixture.call("pane.read", ["pane": "w1:p1", "source": "recent", "lines": 50])
    #expect(read.result?["text"]?.stringValue?.contains(marker) == true)
    let missing = await fixture.call("pane.wait_for_output", ["pane": "w1:p1", "match": .string("never-appears-\(marker)"), "timeout_ms": 300])
    #expect(missing.error?.code == .timeout)
  }

  @Test("agent.wait 解析：立即命中、事件到达、agent 退出、too_many_waits")
  func agentWait() async throws {
    let (fixture, _) = try makeFixture()
    defer { fixture.workspace.tearDown() }
    let (_, view) = try fixture.workspace.makeActiveTerminalView()
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .claudeCode, signal: .processing))
    await pumpControlEvents()

    #expect(await fixture.call("agent.wait", ["target": "w1:p1", "until": ["working"]]).result?["status"]?.stringValue == "working")
    #expect(await fixture.call("agent.wait", ["target": "w1:p1", "timeout_ms": 200]).error?.code == .timeout)

    let waiting = Task { await fixture.call("agent.wait", ["target": "w1:p1", "timeout_ms": 5_000]) }
    await pumpControlEvents()
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .claudeCode, signal: .idle))
    let resolved = await waiting.value
    #expect(resolved.result?["status"]?.stringValue == "done")
    #expect(fixture.client.pendingWaits == 0)

    fixture.client.pendingWaits = AsterControlDispatcher.maximumPendingWaitsPerClient
    #expect(await fixture.call("agent.wait", ["target": "w1:p1", "timeout_ms": 10]).error?.code == .tooManyWaits)
    fixture.client.pendingWaits = 0

    // 等待中 pane 被关闭 → agent_not_running（TerminalSession 拒绝其它 provider 抢占，换人路径无法在此模拟）。
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .claudeCode, signal: .processing))
    await pumpControlEvents()
    let replaced = Task { await fixture.call("agent.wait", ["target": "w1:p1", "timeout_ms": 5_000]) }
    await pumpControlEvents()
    fixture.workspace.model.newTab(workingDirectory: "/tmp")
    let first = try #require(fixture.workspace.model.tabs.first)
    fixture.workspace.model.closeTab(id: first.id)
    #expect(await replaced.value.error?.code == .agentNotRunning)

  }

  @Test("agent.prompt --wait：写入后无状态变化 → agent_prompt_stalled；有变化则等到目标态")
  func promptWait() async throws {
    let (fixture, _) = try makeFixture()
    defer { fixture.workspace.tearDown() }
    let (session, view) = try fixture.workspace.makeActiveTerminalView()
    // 这里的「agent」其实是真实 shell：prompt 若被 shell 执行，OSC 133 commandStart 会按命令名
    // 重新识别 provider 并清掉 hook 权威，让假 agent「退出」。先让 `cat` 占住前台读 stdin，
    // 之后所有 prompt 都只进 cat，不再产生 commandStart（真实 agent TUI 自己持有 PTY，无此问题）。
    _ = await fixture.call("pane.send_text", ["pane": "w1:p1", "text": "cat", "enter": true])
    // zsh 启动与 shell integration 加载可能超过数百毫秒；必须等到 cat 真正成为前台进程
    // （commandStart 已发生）再注入 hook，否则迟到的 commandStart 会清掉 provider。
    for _ in 0..<100 where !session.hasForegroundCommand { await pumpControlEvents(milliseconds: 100) }
    #expect(session.hasForegroundCommand)
    await pumpControlEvents(milliseconds: 200)
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .processing))
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .idle))
    await pumpControlEvents()
    // idle(done) 状态下发 prompt：用户输入回调会把 unread 清掉 → 状态从 done 变 idle，
    // 这算一次变化，但之后没有 processing → 等待超时。
    let stalled = await fixture.call("agent.prompt", ["target": "w1:p1", "text": "hi", "wait": ["timeout_ms": 400, "until": ["blocked"]]])
    #expect(stalled.error?.code == .timeout || stalled.error?.code == .agentPromptStalled, "\(String(describing: stalled.error))")

    let waiting = Task { await fixture.call("agent.prompt", ["target": "w1:p1", "text": "go", "wait": ["timeout_ms": 5_000]]) }
    await pumpControlEvents(milliseconds: 100)
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .processing))
    await pumpControlEvents(milliseconds: 100)
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .awaitingInput))
    let resolved = await waiting.value
    #expect(resolved.result?["status"]?.stringValue == "blocked", "\(String(describing: resolved.error))")
  }

  @Test("events.subscribe/wait 与 notification.show")
  func eventsAndNotification() async throws {
    let (fixture, _) = try makeFixture()
    defer { fixture.workspace.tearDown() }
    let recorder = ControlNotificationRecorder()
    fixture.dispatcher.notificationPoster = recorder
    let subscribed = await fixture.call("events.subscribe", ["kinds": ["pane.created"]])
    #expect(subscribed.error == nil)
    fixture.workspace.model.newTab(workingDirectory: "/tmp")
    await pumpControlEvents()
    #expect(fixture.client.events.contains { $0.event == .paneCreated && $0.data["pane_id"]?.stringValue == "w1:p2" })

    let waiting = Task { await fixture.call("events.wait", ["kind": "pane.closed", "timeout_ms": 5_000]) }
    await pumpControlEvents()
    let secondTab = try #require(fixture.workspace.model.tabs.last)
    fixture.workspace.model.closeTab(id: secondTab.id)
    let closed = await waiting.value
    #expect(closed.result?["event"]?.stringValue == "pane.closed")
    #expect(closed.result?["data"]?["pane_id"]?.stringValue == "w1:p2")
    // 退役后旧 ID 不可解析。
    #expect(await fixture.call("pane.read", ["pane": "w1:p2"]).error?.code == .notFound)

    let shown = await fixture.call("notification.show", ["title": "Hi\u{07}", "body": "b", "urgency": "critical"])
    #expect(shown.error == nil)
    #expect(recorder.records.last?.notification.title == "Hi")
    #expect(recorder.records.last?.notification.urgency == .critical)
  }

  @Test("agent.start：忙 pane 返回 pane_busy；未知 kind 返回 invalid_params")
  func agentStartGuards() async throws {
    let (fixture, _) = try makeFixture()
    defer { fixture.workspace.tearDown() }
    let (_, view) = try fixture.workspace.makeActiveTerminalView()
    #expect(await fixture.call("agent.start", ["kind": "not-an-agent"]).error?.code == .invalidParams)
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .processing))
    await pumpControlEvents()
    #expect(await fixture.call("agent.start", ["pane": "w1:p1", "kind": "claudeCode"]).error?.code == .paneBusy)
    #expect(AsterControlDispatcher.provider(forKind: "claude") == .claudeCode)
    #expect(AsterControlDispatcher.provider(forKind: "codex") == .codex)
  }

  @Test("非终端 pane 读写返回 pane_not_terminal；已退出终端写入返回 pane_not_running")
  func paneKindAndLifecycleErrors() async throws {
    let (fixture, _) = try makeFixture()
    defer { fixture.workspace.tearDown() }
    let (session, _) = try fixture.workspace.makeActiveTerminalView()
    let tab = try #require(fixture.workspace.model.selectedTab)
    tab.split(direction: .right, kind: .fileBrowser, resourcePath: "/tmp", workingDirectory: "/tmp")
    await pumpControlEvents()
    #expect(await fixture.call("pane.read", ["pane": "w1:p2"]).error?.code == .paneNotTerminal)
    #expect(await fixture.call("pane.send_text", ["pane": "w1:p2", "text": "x"]).error?.code == .paneNotTerminal)
    #expect(await fixture.call("agent.get", ["target": "w1:p2"]).error?.code == .agentNotFound)
    let snapshot = try #require(await fixture.call("session.snapshot").result).decoded(as: SessionSnapshot.self)
    #expect(snapshot.windows[0].tabs[0].panes.map(\.kind) == [.terminal, .fileBrowser])

    session.stop(immediately: true)
    await pumpControlEvents(milliseconds: 200)
    #expect(await fixture.call("pane.send_text", ["pane": "w1:p1", "text": "x"]).error?.code == .paneNotRunning)
    #expect(await fixture.call("pane.send_keys", ["pane": "w1:p1", "keys": ["enter"]]).error?.code == .paneNotRunning)
  }

  @Test("回归：缓冲里已有非目标状态事件时 agent.wait 不死循环，超时后返回 timeout")
  func agentWaitDoesNotSpinOnBufferedNonTargetEvent() async throws {
    let (fixture, _) = try makeFixture()
    defer { fixture.workspace.tearDown() }
    let (_, view) = try fixture.workspace.makeActiveTerminalView()
    // 先制造 idle → working 的状态事件进回放缓冲。
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .processing))
    await pumpControlEvents()
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .idle))
    await pumpControlEvents()
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .processing))
    await pumpControlEvents()
    let started = ContinuousClock.now
    let waited = await fixture.call("agent.wait", ["target": "w1:p1", "until": ["done"], "timeout_ms": 300])
    #expect(waited.error?.code == .timeout)
    #expect(ContinuousClock.now - started < .seconds(3))
    // 等待中的任务被取消（连接断开）也应立即结束，而不是等到超时。
    let cancelled = Task { await fixture.call("agent.wait", ["target": "w1:p1", "until": ["done"], "timeout_ms": 60_000]) }
    await pumpControlEvents()
    cancelled.cancel()
    let cancelStarted = ContinuousClock.now
    _ = await cancelled.value
    #expect(ContinuousClock.now - cancelStarted < .seconds(2))
  }

  @Test("state_change_seq 只随真实变化递增：连续读取不变")
  func stateChangeSequenceStableAcrossReads() async throws {
    let (fixture, _) = try makeFixture()
    defer { fixture.workspace.tearDown() }
    let (_, view) = try fixture.workspace.makeActiveTerminalView()
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .processing))
    await pumpControlEvents()
    var sequences: [Int?] = []
    for _ in 0..<3 {
      sequences.append(await fixture.call("agent.get", ["target": "w1:p1"]).result?["state_change_seq"]?.intValue)
      _ = await fixture.call("agent.list")
    }
    #expect(sequences == [1, 1, 1])
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .awaitingInput))
    await pumpControlEvents()
    #expect(await fixture.call("agent.get", ["target": "w1:p1"]).result?["state_change_seq"]?.intValue == 2)
    #expect(await fixture.call("agent.get", ["target": "w1:p1"]).result?["state_change_seq"]?.intValue == 2)
  }

  @Test("agent 名字：登记后可按名解析、事件带名、重名返回 agent_name_taken、agent 退出后清除")
  func agentNames() async throws {
    let (fixture, _) = try makeFixture()
    defer { fixture.workspace.tearDown() }
    let (session, view) = try fixture.workspace.makeActiveTerminalView()
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .processing))
    await pumpControlEvents()
    #expect(await fixture.call("agent.get", ["target": "w1:p1"]).result?["name"] == nil)
    #expect(await fixture.call("agent.get", ["target": "reviewer"]).error?.code == .agentNotFound)

    let paneUUID = try #require(fixture.workspace.model.selectedTab?.activePaneID)
    fixture.bridge.setAgentName("reviewer", paneUUID: paneUUID)
    #expect(await fixture.call("agent.get", ["target": "reviewer"]).result?["pane_id"]?.stringValue == "w1:p1")
    #expect(await fixture.call("agent.get", ["target": "w1:p1"]).result?["name"]?.stringValue == "reviewer")
    #expect(await fixture.call("agent.get", ["target": "codex"]).result?["name"]?.stringValue == "reviewer")

    // 事件带名字。
    var changes: [AsterControlEvent.AgentStatusChange] = []
    fixture.bridge.hub.subscribe(id: UUID(), kinds: [.paneAgentStatusChanged]) { event in
      if let change = try? event.data.decoded(as: AsterControlEvent.AgentStatusChange.self) { changes.append(change) }
    }
    view.onAgentTerminalDirective?(AgentTerminalDirective(provider: .codex, signal: .awaitingInput))
    await pumpControlEvents()
    #expect(changes.last?.agent?.name == "reviewer")

    // 在另一个空闲 shell pane 上用同名启动 → agent_name_taken（早于 pane_busy 判定）。
    fixture.workspace.model.newTab(workingDirectory: "/tmp")
    let second = try #require(fixture.workspace.model.selectedTab?.activeSession)
    _ = try #require(second.makeTerminalView(preferences: fixture.workspace.preferences) as? AsterTerminalView)
    await pumpControlEvents()
    #expect(await fixture.call("agent.start", ["pane": "w1:p2", "kind": "codex", "name": "reviewer"]).error?.code == .agentNameTaken)

    // pane 关闭 → 名字清除、按名解析失败。
    _ = session
    let firstTab = try #require(fixture.workspace.model.tabs.first)
    fixture.workspace.model.closeTab(id: firstTab.id)
    await pumpControlEvents(milliseconds: 200)
    #expect(fixture.bridge.agentName(for: paneUUID) == nil)
    #expect(await fixture.call("agent.get", ["target": "reviewer"]).error?.code == .agentNotFound)
  }

  @Test("send_text 的 enter 追加 CR（与 send_keys enter 一致）")
  func sendTextEnterIsCarriageReturn() throws {
    #expect(try AsterControlDispatcher.bytes(forSendText: "ls", enter: true) == Array("ls".utf8) + [13])
    #expect(try AsterControlDispatcher.bytes(forSendText: "ls", enter: false) == Array("ls".utf8))
    #expect(try AsterControlDispatcher.bytes(forSendText: "", enter: true) == [13])
  }

  @Test("events.wait --after-sequence 超出回放缓冲返回 replay_gap；spinner 标题不触发 pane.updated")
  func replayGapAndSpinnerTitles() async throws {
    let workspace = try ControlTestWorkspace()
    defer { workspace.tearDown() }
    let bridge = AsterControlBridge(hub: AsterControlEventHub(capacity: 4), socketPath: "/tmp/s.sock", binaryPath: nil)
    bridge.activeModelProvider = { [weak model = workspace.model] in model }
    bridge.attach(model: workspace.model)
    let dispatcher = AsterControlDispatcher(bridge: bridge, version: "t") {
      .init(allowSendKeys: true, allowSensitiveSessions: false, shell: AsterConfiguration().shell)
    }
    let client = ControlFakeClient()
    for _ in 0..<6 { workspace.model.newTab(workingDirectory: "/tmp") }
    await pumpControlEvents()
    #expect(bridge.hub.sequence >= 6)
    let gap = await dispatcher.handle(controlRequest("events.wait", ["after_sequence": 1, "timeout_ms": 100]), client: client)
    #expect(gap.error?.code == .replayGap)
    let recent = await dispatcher.handle(controlRequest("events.wait", ["after_sequence": .number(Double(bridge.hub.sequence - 1)), "timeout_ms": 100]), client: client)
    #expect(recent.error == nil)
    #expect(bridge.hub.replayResult(after: bridge.hub.sequence).truncated == false)

    // 同一标题只是 spinner 前缀变化：投影后的 title 相同，不发 pane.updated。
    let (session, view) = try workspace.makeActiveTerminalView()
    view.titleShellControlled = true
    // 让 PTY 启动引起的 running/cwd 变化先发完，再观察标题引起的 pane.updated。
    await pumpControlEvents(milliseconds: 400)
    var titles: [String] = []
    bridge.hub.subscribe(id: UUID(), kinds: [.paneUpdated]) { titles.append($0.data["title"]?.stringValue ?? "") }
    for spinner in ["✳", "✶", "✻", "⠋"] {
      session.setTerminalTitle(source: view, title: "\(spinner) Claude Code")
      await pumpControlEvents(milliseconds: 60)
    }
    #expect(session.terminalTitle == "⠋ Claude Code")
    // 事件里永远是剥掉 spinner 的标题；四次 spinner 翻转最多只有首次（"Shell" → "Claude Code"）
    // 触发标题更新，其余事件（若有）来自 PTY 启动尾声的 running/cwd 变化，标题不变。
    #expect(titles.allSatisfy { $0 == "Claude Code" })
    #expect(titles.filter { $0 == "Claude Code" }.count <= 2)
    let beforeVim = titles.count
    session.setTerminalTitle(source: view, title: "vim README.md")
    await pumpControlEvents(milliseconds: 60)
    #expect(titles.count == beforeVim + 1)
    #expect(titles.last == "vim README.md")
  }

  @Test("workflow.execute 桥接旧 CLI：参数错误 exit 64，capture 成功")
  func workflowExecute() async throws {
    let (fixture, _) = try makeFixture()
    defer { fixture.workspace.tearDown() }
    _ = try fixture.workspace.makeActiveTerminalView()
    let bad = await fixture.call("workflow.execute", ["argv": ["bogus"], "cwd": "/tmp"])
    #expect(bad.result?["exit_code"]?.intValue == 64)
    let capture = await fixture.call("workflow.execute", ["argv": ["pane", "capture", "--lines", "5"], "cwd": "/tmp"])
    #expect(capture.result?["exit_code"]?.intValue == 0, "\(String(describing: capture.result))")
    // 短 ID / current 也能作为旧 CLI 的 --pane（ASTER_PANE_ID 现在是 w1:p1）。
    for selector in ["w1:p1", "current", "w1:t1", "w1"] {
      let byShortID = await fixture.call("workflow.execute", ["argv": ["pane", "capture", "--pane", .string(selector), "--lines", "5"], "cwd": "/tmp"])
      #expect(byShortID.result?["exit_code"]?.intValue == 0, "\(selector): \(String(describing: byShortID.result))")
    }
    let missing = await fixture.call("workflow.execute", ["argv": ["pane", "capture", "--pane", "w9:p9"], "cwd": "/tmp"])
    #expect(missing.result?["exit_code"]?.intValue == 69)
  }
}

/// 通知记录器（与 AgentTerminalLifecycleTests 的私有实现同形）。
@MainActor
private final class ControlNotificationRecorder: TerminalNotificationPosting {
  struct Record {
    let notification: TerminalNotification
    let category: TerminalNotificationCategory
  }
  private(set) var records: [Record] = []
  func post(_ notification: TerminalNotification, category: TerminalNotificationCategory, configuration: ShellConfiguration, sourceTabIsFocused: Bool) {
    records.append(Record(notification: notification, category: category))
  }
}
