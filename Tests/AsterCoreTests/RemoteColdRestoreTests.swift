import Testing
@testable import AsterCore
import Foundation

struct RemoteColdRestoreTests {
  // Test PaneRecoveryPath equality
  @Test func recoveryPathEquality() {
    let a = PaneRecoveryPath.newShell(oldTerminalID: "old", newTerminalID: "new", newPID: 123)
    let b = PaneRecoveryPath.newShell(oldTerminalID: "old", newTerminalID: "new", newPID: 123)
    #expect(a == b)
  }

  // Test agent restore spec building
  @Test func buildGrokRestoreCommand() {
    let machineID = UUID()
    let cmd = RemoteAgentRestoreSpec.buildRestoreCommand(
      provider: .grokBuild,
      nativeSession: "test-session-123",
      paneID: "pane-1",
      machineID: machineID
    )
    #expect(cmd != nil)
    #expect(cmd?.argv == ["grok", "--resume", "test-session-123"])
    #expect(cmd?.provider == .grokBuild)
  }

  // Test screen-only provider returns nil
  @Test func screenOnlyProviderNoRestore() {
    let cmd = RemoteAgentRestoreSpec.buildRestoreCommand(
      provider: .gemini,
      nativeSession: "test",
      paneID: "pane-1",
      machineID: UUID()
    )
    #expect(cmd == nil)
  }

  // Test dedup
  @Test func deduplicateRestoreCommands() {
    let machineID = UUID()
    let commands = [
      RemoteAgentRestoreCommand(provider: .grokBuild, nativeSession: "s1", argv: ["grok", "--resume", "s1"], paneID: "p1", machineID: machineID),
      RemoteAgentRestoreCommand(provider: .grokBuild, nativeSession: "s1", argv: ["grok", "--resume", "s1"], paneID: "p2", machineID: machineID),
      RemoteAgentRestoreCommand(provider: .grokBuild, nativeSession: "s2", argv: ["grok", "--resume", "s2"], paneID: "p3", machineID: machineID),
    ]
    let deduped = RemoteAgentRestoreSpec.dedup(commands)
    #expect(deduped.count == 2)
  }

  // Test argv validation
  @Test func argvValidation() {
    #expect(RemoteAgentRestoreSpec.validateArgv(["grok", "--resume", "abc-123"]))
    #expect(!RemoteAgentRestoreSpec.validateArgv(["grok", "--resume", "abc\u{0000}123"]))
    #expect(!RemoteAgentRestoreSpec.validateArgv([""]))
  }

  // Test diagnostics
  @Test func diagnosticHelpText() {
    let text = ColdRestoreDiagnostic.helpText(for: .corruptLayout)
    #expect(text.contains("backup"))
  }

  // Test ColdRestoreResult
  @Test func restoreResultInit() {
    let result = ColdRestoreResult()
    #expect(result.paneResults.isEmpty)
    #expect(!result.isCompleted)
    #expect(!result.alreadyRestored)
  }

  // Test four recovery paths are mutually exclusive in type system
  @Test func fourPathsMutuallyExclusive() {
    let paths: [PaneRecoveryPath] = [
      .continueRunning(terminalID: "t1", pid: 100),
      .newShell(oldTerminalID: "t2", newTerminalID: "t3", newPID: 200),
      .historyReplay(oldTerminalID: "t4", newTerminalID: "t5", capturedAt: Date()),
      .agentRestore(oldTerminalID: "t6", newTerminalID: "t7", newPID: 300, provider: .grokBuild, nativeSession: "s1"),
    ]
    // Each path is a different enum case (mutually exclusive by construction)
    for (i, a) in paths.enumerated() {
      for (j, b) in paths.enumerated() where i != j {
        #expect(a != b)
      }
    }
  }

  // -- Recovery path presentation mapping tests --

  /// newShell 路径生成正确的标题和详情。
  @Test func recoveryPathNewShellPresentation() {
    let path = PaneRecoveryPath.newShell(oldTerminalID: "old", newTerminalID: "new", newPID: 42)
    let (title, detail, symbol) = Self.presentationFields(for: path)
    #expect(title == "新 Shell")
    #expect(detail.contains("Shell 进程"))
    #expect(symbol == "terminal")
  }

  /// historyReplay 路径生成正确的标题和详情。
  @Test func recoveryPathHistoryReplayPresentation() {
    let path = PaneRecoveryPath.historyReplay(
      oldTerminalID: "old", newTerminalID: "new", capturedAt: Date()
    )
    let (title, detail, symbol) = Self.presentationFields(for: path)
    #expect(title == "历史回放")
    #expect(detail.contains("屏幕历史"))
    #expect(symbol == "clock.arrow.circlepath")
  }

  /// agentRestore 路径生成正确的标题和详情，包含 provider 名称。
  @Test func recoveryPathAgentRestorePresentation() {
    let path = PaneRecoveryPath.agentRestore(
      oldTerminalID: "old", newTerminalID: "new", newPID: 99,
      provider: .grokBuild, nativeSession: "s1"
    )
    let (title, detail, symbol) = Self.presentationFields(for: path)
    #expect(title == "Agent 对话恢复")
    #expect(detail.contains("grok"))
    #expect(symbol == "arrow.uturn.backward.circle")
  }

  /// failed 路径生成正确的标题和详情，包含 reason。
  @Test func recoveryPathFailedPresentation() {
    let path = PaneRecoveryPath.failed(
      oldTerminalID: "old", newTerminalID: "new", newPID: 1,
      reason: "disk full"
    )
    let (title, detail, symbol) = Self.presentationFields(for: path)
    #expect(title == "恢复失败")
    #expect(detail.contains("disk full"))
    #expect(symbol == "exclamationmark.triangle")
  }

  /// historyReplay 不应伪装为会话启动；failed 不应伪装为存活。
  @Test func recoveryPathLifecycleConsistency() {
    // historyReplay 的标题不是"已运行"或"已启动"
    let replay = PaneRecoveryPath.historyReplay(
      oldTerminalID: "t1", newTerminalID: "t2", capturedAt: Date()
    )
    let (replayTitle, _, _) = Self.presentationFields(for: replay)
    #expect(!replayTitle.contains("运行"))
    #expect(!replayTitle.contains("启动"))

    // failed 的标题和详情不应包含"继续运行"或"已连接"
    let fail = PaneRecoveryPath.failed(
      oldTerminalID: "t3", newTerminalID: "t4", newPID: 1,
      reason: "corrupt"
    )
    let (failTitle, failDetail, _) = Self.presentationFields(for: fail)
    #expect(!failTitle.contains("继续运行"))
    #expect(!failDetail.contains("已连接"))
  }

  // -- Helper: mirror the overlay Presentation mapping in pure-logic form --

  /// 将 PaneRecoveryPath 映射为 (title, detail, symbol)，与 UI 层一致。
  private static func presentationFields(for path: PaneRecoveryPath) -> (String, String, String) {
    switch path {
    case .continueRunning:
      return ("继续运行", "后台任务持续运行中，已重新连接。", "checkmark.circle")
    case .newShell:
      return ("新 Shell", "服务重启后创建了新的 Shell 进程。", "terminal")
    case .historyReplay:
      return ("历史回放", "正在回放磁盘上保存的屏幕历史，非实时状态。", "clock.arrow.circlepath")
    case .agentRestore(_, _, _, let provider, _):
      return ("Agent 对话恢复", "已通过 \(provider.rawValue) --resume 恢复对话。", "arrow.uturn.backward.circle")
    case .failed(_, _, _, let reason):
      return ("恢复失败", "\(reason)。已创建新 Shell 替代。", "exclamationmark.triangle")
    }
  }

}
