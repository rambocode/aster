import Foundation
import Testing

@testable import AsterCore

/// aster-cli 参数解析：新语法、全局选项、legacy 回落与错误消息。
struct AsterCLIArgumentsTests {
  private func parse(_ argv: [String]) throws -> AsterCLIArguments {
    try AsterCLIArguments.parse(argv)
  }

  private func command(_ argv: [String]) throws -> AsterCLICommand {
    try parse(argv).command
  }

  @Test("全局选项与 help/version/skill")
  func globalOptions() throws {
    let parsed = try parse(["aster", "--json", "--socket", "/tmp/a.sock", "--allow-outside", "agent", "list"])
    #expect(parsed.format == .json)
    #expect(parsed.socketPath == "/tmp/a.sock")
    #expect(parsed.allowOutside)
    #expect(parsed.command == .agentList)
    #expect(parsed.requiresAsterEnv)

    #expect(try parse(["--format", "json", "session", "snapshot"]).format == .json)
    #expect(try command([]) == .help)
    #expect(try command(["--help"]) == .help)
    #expect(try command(["-h"]) == .help)
    #expect(try command(["--version"]) == .version)
    #expect(try command(["--skill"]) == .skill)
    #expect(try command(["session", "snapshot"]) == .sessionSnapshot)
    #expect(!(try parse(["session", "snapshot"]).requiresAsterEnv))
    #expect(throws: AsterCLIArgumentError.self) { try parse(["--socket", "relative.sock", "agent", "list"]) }
    #expect(throws: AsterCLIArgumentError.self) { try parse(["--format", "yaml", "agent", "list"]) }
    #expect(throws: AsterCLIArgumentError.self) { try parse(["bogus"]) }
    #expect(try command(["session"]) == .help)
    // 子命令之后的 --json / --format 同样生效（SKILL.md 写法），`--` 之后的不算。
    #expect(try parse(["agent", "list", "--json"]).format == .json)
    #expect(try parse(["agent", "get", "w1:p1", "--format", "json"]).format == .json)
    #expect(try parse(["agent", "start", "r", "--kind", "codex", "--", "--json"]).command == .agentStart(.init(kind: "codex", name: "r", args: ["--json"])))
  }

  @Test("agent 子命令")
  func agentCommands() throws {
    #expect(try command(["agent", "get", "builder"]) == .agentGet(.init(target: "builder")))
    #expect(try command(["agent", "get", "--current"]) == .agentGet(.init(target: "current")))
    #expect(try command(["agent", "focus", "w1:p2"]) == .agentFocus(.init(target: "w1:p2")))
    #expect(
      try command(["agent", "read", "w1:p2", "--source", "recent", "--lines", "50"])
        == .agentRead(.init(target: "w1:p2", source: .recent, lines: 50)))
    #expect(
      try command(["agent", "read", "--current", "--lines=5"])
        == .agentRead(.init(target: "current", source: .visible, lines: 5)))

    #expect(
      try command(["agent", "prompt", "builder", "fix", "the", "tests"])
        == .agentPrompt(target: "builder", text: "fix the tests", wait: nil))
    #expect(
      try command(["agent", "prompt", "builder", "go", "--wait", "--until", "done,blocked", "--timeout", "9000"])
        == .agentPrompt(target: "builder", text: "go", wait: .init(until: [.done, .blocked], timeoutMs: 9000)))
    // --timeout 隐含 --wait。
    #expect(
      try command(["agent", "prompt", "builder", "go", "--timeout", "10"])
        == .agentPrompt(target: "builder", text: "go", wait: .init(until: [], timeoutMs: 10)))
    #expect(
      try command(["agent", "prompt", "--current", "--stdin"])
        == .agentPrompt(target: "current", text: nil, wait: nil))
    #expect(
      try command(["agent", "prompt", "--current", "fix", "it"])
        == .agentPrompt(target: "current", text: "fix it", wait: nil))
    #expect(
      try command(["agent", "send-keys", "--current", "C-c"])
        == .agentSendKeys(.init(target: "current", keys: ["C-c"])))
    #expect(throws: AsterCLIArgumentError.self) { try command(["agent", "get", "--current", "builder"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["agent", "prompt", "builder"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["agent", "prompt", "builder", "x", "--stdin"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["agent", "prompt", "builder", "x", "--until", "unknown"]) }

    #expect(
      try command(["agent", "wait", "w1:p1", "--until", "idle", "--timeout", "100"])
        == .agentWait(.init(target: "w1:p1", until: [.idle], timeoutMs: 100)))
    #expect(try command(["agent", "wait", "w1:p1"]) == .agentWait(.init(target: "w1:p1")))
    #expect(
      try command(["agent", "send-keys", "w1:p1", "C-c", "Enter"])
        == .agentSendKeys(.init(target: "w1:p1", keys: ["C-c", "Enter"])))
    #expect(throws: AsterCLIArgumentError.self) { try command(["agent", "send-keys", "w1:p1"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["agent", "send-keys", "w1:p1", "nope"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["agent", "get", "Bad Name"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["agent", "list", "extra"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["agent", "explode"]) }
    #expect(try command(["agent"]) == .help)

    // SKILL.md 语法：`agent start <name> --kind <kind>`；kind 接受 rawValue / 命令名 / 别名并归一为 rawValue。
    #expect(
      try command(["agent", "start", "builder", "--kind", "claudeCode", "--pane", "w1:p3", "--timeout", "5000", "--", "--model", "opus"])
        == .agentStart(.init(pane: "w1:p3", kind: "claudeCode", name: "builder", args: ["--model", "opus"], timeoutMs: 5000)))
    #expect(try command(["agent", "start", "reviewer", "--kind", "codex", "--current"]) == .agentStart(.init(pane: "current", kind: "codex", name: "reviewer")))
    #expect(try command(["agent", "start", "r", "--kind", "claude"]) == .agentStart(.init(kind: "claudeCode", name: "r")))
    #expect(try command(["agent", "start", "r", "--kind", "Claude-Code"]) == .agentStart(.init(kind: "claudeCode", name: "r")))
    #expect(throws: AsterCLIArgumentError.self) { try command(["agent", "start"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["agent", "start", "reviewer"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["agent", "start", "reviewer", "--kind", "nope"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["agent", "start", "reviewer", "--kind", "codex", "--current", "--pane", "w1:p1"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["agent", "start", "Bad", "--kind", "codex"]) }
    // 只写命令组等同 --help（SKILL.md 用它学语法），不是参数错误。
    for group in ["agent", "pane", "events", "notification", "session"] {
      #expect(try command([group]) == .help)
    }
    // send-text 两个位置参数时首个是 pane。
    #expect(try command(["pane", "send-text", "w1:p2", "just test", "--enter"]) == .paneSendText(pane: "w1:p2", text: "just test", enter: true))
  }

  @Test("pane 子命令")
  func paneCommands() throws {
    #expect(try command(["pane", "read"]) == .paneRead(pane: nil, source: .visible, lines: nil))
    #expect(try command(["pane", "read", "--current", "--lines", "5"]) == .paneRead(pane: "current", source: .visible, lines: 5))
    #expect(try command(["pane", "read", "w1:p2", "--source", "recent"]) == .paneRead(pane: "w1:p2", source: .recent, lines: nil))
    #expect(try command(["pane", "read", "--pane", "w1:p2"]) == .paneRead(pane: "w1:p2", source: .visible, lines: nil))
    #expect(throws: AsterCLIArgumentError.self) { try command(["pane", "read", "w1:p2", "--pane", "w1:p3"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["pane", "read", "--source", "ansi"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["pane", "read", "--lines", "-3"]) }
    #expect(!(try parse(["pane", "read"]).requiresAsterEnv))

    #expect(
      try command(["pane", "send-text", "--pane", "w1:p2", "echo hi", "--enter"])
        == .paneSendText(pane: "w1:p2", text: "echo hi", enter: true))
    #expect(try command(["pane", "send-text", "ls"]) == .paneSendText(pane: nil, text: "ls", enter: false))
    #expect(try command(["pane", "send-text", "--current", "--enter"]) == .paneSendText(pane: "current", text: "", enter: true))
    #expect(throws: AsterCLIArgumentError.self) { try command(["pane", "send-text", "--current"]) }
    // 两个位置参数：首个是 pane（SKILL.md 写法）；三个则仍是错误。
    #expect(try command(["pane", "send-text", "a", "b"]) == .paneSendText(pane: "a", text: "b", enter: false))
    #expect(throws: AsterCLIArgumentError.self) { try command(["pane", "send-text", "a", "b", "c"]) }
    #expect(try command(["pane", "send-keys", "--pane", "w1:p2", "up", "enter"]) == .paneSendKeys(pane: "w1:p2", keys: ["up", "enter"]))
    #expect(try command(["pane", "focus", "w1:p2"]) == .paneFocus(pane: "w1:p2"))
    #expect(try command(["pane", "focus"]) == .paneFocus(pane: nil))
    #expect(
      try command(["pane", "wait-output", "--current", "--match", "$ ", "--timeout", "3000", "--lines", "20"])
        == .paneWaitForOutput(pane: "current", match: "$ ", regex: nil, source: .visible, lines: 20, timeoutMs: 3000))
    #expect(
      try command(["pane", "wait-output", "w1:p1", "--regex", "^done$", "--source", "recent"])
        == .paneWaitForOutput(pane: "w1:p1", match: nil, regex: "^done$", source: .recent, lines: nil, timeoutMs: nil))
    #expect(throws: AsterCLIArgumentError.self) { try command(["pane", "wait-output", "w1:p1"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["pane", "wait-output", "--match", "a", "--regex", "b"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["pane", "wait-output", "--regex", "["]) }
    #expect(try command(["pane"]) == .help)
    #expect(throws: AsterCLIArgumentError.self) { try command(["pane", "split"]) }
  }

  @Test("events 与 notification")
  func eventsAndNotification() throws {
    #expect(try command(["events", "subscribe"]) == .eventsSubscribe(.init(kinds: [])))
    #expect(
      try command(["events", "subscribe", "--kind", "pane.updated", "--kind", "pane.closed,pane.exited"])
        == .eventsSubscribe(.init(kinds: [.paneUpdated, .paneClosed, .paneExited])))
    #expect(throws: AsterCLIArgumentError.self) { try command(["events", "subscribe", "--kind", "tab.created"]) }
    #expect(
      try command(["events", "wait", "--kind", "pane.agent_status_changed", "--pane", "w1:p1", "--after-sequence", "12", "--timeout", "500"])
        == .eventsWait(.init(kind: .paneAgentStatusChanged, pane: "w1:p1", afterSequence: 12, timeoutMs: 500)))
    #expect(try command(["events", "wait", "--current"]) == .eventsWait(.init(kind: nil, pane: "current")))
    #expect(throws: AsterCLIArgumentError.self) { try command(["events", "wait", "extra"]) }
    #expect(try command(["events"]) == .help)
    #expect(try parse(["events", "wait"]).requiresAsterEnv)

    #expect(
      try command(["notification", "show", "Build done", "--body", "all green", "--urgency", "critical"])
        == .notificationShow(.init(title: "Build done", body: "all green", urgency: .critical)))
    #expect(try command(["notification", "show", "t"]) == .notificationShow(.init(title: "t")))
    #expect(throws: AsterCLIArgumentError.self) { try command(["notification", "show"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["notification", "show", "t", "--urgency", "loud"]) }
    #expect(throws: AsterCLIArgumentError.self) { try command(["notification", "hide"]) }
    #expect(try parse(["notification", "show", "t"]).requiresAsterEnv)
  }

  @Test("旧语法整体落到 legacy，且能被 WorkflowCLIParser 解析")
  func legacyCommandsFallThrough() throws {
    let legacyArgvs: [[String]] = [
      ["open", ".", "--command", "npm run dev"],
      ["view", "README.md", "--right"],
      ["edit", "notes.md"],
      ["watch", "--", "sleep", "1"],
      ["jump", "proj"],
      ["learn", "/tmp"],
      ["ignore", "/tmp"],
      ["pane", "run", "--", "ls"],
      ["pane", "exec", "--pane", "p_\(UUID().uuidString)", "--", "ls"],
      ["pane", "capture", "--lines", "5"],
      ["pane", "send-text", "--from-file", "/tmp/x"],
      ["pane", "send-text", "--stdin"],
      ["pane", "send-keys", "--", "up"],
    ]
    let parser = WorkflowCLIParser(currentDirectory: "/tmp")
    for argv in legacyArgvs {
      let parsed = try parse(["aster"] + argv)
      #expect(parsed.command == .legacy(argv), "\(argv)")
      #expect(!parsed.requiresAsterEnv)
      // 旧解析器必须仍能吃下同一份 argv（watch/pane 需要目录存在的除外）。
      _ = try parser.parse(argv)
    }
    // 全局 --json/--quiet 前缀保留在 legacy argv 里，交给旧解析器处理。
    #expect(try command(["--json", "pane", "capture"]) == .legacy(["--json", "pane", "capture"]))
    #expect(try command(["--quiet", "watch", "--", "ls"]) == .legacy(["--quiet", "watch", "--", "ls"]))
    #expect(try command(["--format", "json", "pane", "run", "--", "ls"]) == .legacy(["--format", "json", "pane", "run", "--", "ls"]))
  }

  @Test("错误消息可读；参数数量与长度上限")
  func errorMessagesAndLimits() {
    do {
      _ = try parse(["agent", "read"])
      Issue.record("应当报错")
    } catch let error as AsterCLIArgumentError {
      #expect(error.message.contains("agent read"))
      #expect(error.description == error.message)
    } catch {
      Issue.record("错误类型不对: \(error)")
    }
    #expect(throws: AsterCLIArgumentError.self) {
      try parse(Array(repeating: "x", count: AsterCLIArguments.maximumArguments + 1))
    }
    #expect(throws: AsterCLIArgumentError.self) {
      try parse(["agent", "get", String(repeating: "a", count: AsterCLIArguments.maximumArgumentBytes + 1)])
    }
    #expect(AsterCLIArguments.usage.contains("agent prompt"))
  }
}
