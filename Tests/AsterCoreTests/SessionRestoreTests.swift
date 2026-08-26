import AsterCore
import Foundation
import Testing

@Test("OSC 88 载荷解析:query / restart= / clear,拒绝控制字符")
func terminalResumeProtocolParsesDirectives() {
  #expect(TerminalResumeProtocol.parse("query") == .query)
  #expect(TerminalResumeProtocol.parse("?") == .query)
  #expect(TerminalResumeProtocol.parse("clear") == .clear)
  #expect(TerminalResumeProtocol.parse("restart=nvim .") == .declare("nvim ."))
  #expect(TerminalResumeProtocol.parse("resume=ssh host") == .declare("ssh host"))
  #expect(TerminalResumeProtocol.parse("claude --resume abc") == .declare("claude --resume abc"))
  #expect(TerminalResumeProtocol.parse("restart=") == .clear)
  #expect(TerminalResumeProtocol.parse("restart=rm\u{1B}[0m -rf") == nil)
  #expect(TerminalResumeProtocol.supportedResponse == "\u{1B}]88;supported;v=1\u{07}")
}

@Test("快照规划:OSC 88 声明优先,复用器换算为 attach,其余记为进程")
func sessionRestorePlannerSnapshotCommands() {
  let pane = UUID()
  let declared = SessionRestorePlanner.snapshotCommand(
    paneID: pane, foregroundCommand: "tmux new -s work", resumeProtocolCommand: "nvim .")
  #expect(declared == WorkspacePaneRestoreCommand(paneID: pane, command: "nvim .", source: .resumeProtocol))

  let tmux = SessionRestorePlanner.snapshotCommand(
    paneID: pane, foregroundCommand: "tmux new -s work", resumeProtocolCommand: nil)
  #expect(tmux?.command == "tmux attach -t 'work'")
  #expect(tmux?.source == .multiplexer)
  #expect(SessionRestorePlanner.multiplexerAttachCommand(for: "tmux") == "tmux attach")
  #expect(SessionRestorePlanner.multiplexerAttachCommand(for: "tmux a -t dev") == "tmux attach -t 'dev'")
  #expect(SessionRestorePlanner.multiplexerAttachCommand(for: "screen -S main") == "screen -r 'main'")
  #expect(SessionRestorePlanner.multiplexerAttachCommand(for: "/usr/bin/screen -r") == "screen -r")
  #expect(SessionRestorePlanner.multiplexerAttachCommand(for: "vim") == nil)

  let process = SessionRestorePlanner.snapshotCommand(
    paneID: pane, foregroundCommand: "npm run dev", resumeProtocolCommand: nil)
  #expect(process == WorkspacePaneRestoreCommand(paneID: pane, command: "npm run dev", source: .process))
  #expect(SessionRestorePlanner.snapshotCommand(paneID: pane, foregroundCommand: nil, resumeProtocolCommand: nil) == nil)
  #expect(SessionRestorePlanner.snapshotCommand(paneID: pane, foregroundCommand: "  ", resumeProtocolCommand: nil) == nil)
}

@Test("恢复阶段按设置决定:复用器开关、协议开关、进程模式与白名单前缀")
func sessionRestorePlannerHonoursSettings() {
  let pane = UUID()
  var shell = AsterConfiguration().shell
  let mux = WorkspacePaneRestoreCommand(paneID: pane, command: "tmux attach", source: .multiplexer)
  let proto = WorkspacePaneRestoreCommand(paneID: pane, command: "nvim .", source: .resumeProtocol)
  let proc = WorkspacePaneRestoreCommand(paneID: pane, command: "npm run dev", source: .process)

  // 默认:复用器开、协议关、进程不重启
  #expect(SessionRestorePlanner.shouldRestore(mux, shell: shell))
  #expect(!SessionRestorePlanner.shouldRestore(proto, shell: shell))
  #expect(!SessionRestorePlanner.shouldRestore(proc, shell: shell))

  shell.restoreMultiplexerSessions = false
  shell.terminalResumeProtocol = true
  #expect(!SessionRestorePlanner.shouldRestore(mux, shell: shell))
  #expect(SessionRestorePlanner.shouldRestore(proto, shell: shell))

  shell.restoreProcesses = true
  shell.restoreProcessesScope = .whitelist
  shell.restoreProcessAllowlist = "npm run, cargo watch"
  #expect(SessionRestorePlanner.shouldRestore(proc, shell: shell))
  #expect(!SessionRestorePlanner.shouldRestore(
    WorkspacePaneRestoreCommand(paneID: pane, command: "npm runner", source: .process), shell: shell))
  #expect(!SessionRestorePlanner.shouldRestore(
    WorkspacePaneRestoreCommand(paneID: pane, command: "sleep 100", source: .process), shell: shell))
  shell.restoreProcessesScope = .all
  #expect(SessionRestorePlanner.shouldRestore(
    WorkspacePaneRestoreCommand(paneID: pane, command: "sleep 100", source: .process), shell: shell))

  // 快照往返:恢复命令字段可编解码,旧快照缺失该字段也能解码
  let snapshot = WorkspaceTabSnapshot(
    id: UUID(), title: "t",
    layout: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")),
    restoreCommands: [proc])
  let data = try! JSONEncoder().encode(snapshot)
  #expect(try! JSONDecoder().decode(WorkspaceTabSnapshot.self, from: data).restoreCommands == [proc])
}
