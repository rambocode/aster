import Testing

@testable import AsterCore

@Test("waitpid 状态区分正常退出、信号终止和 I/O 异常")
func terminalProcessTerminationNormalizesWaitStatus() {
  #expect(TerminalProcessTermination(rawWaitStatus: 7 << 8) == .exited(code: 7))
  #expect(
    TerminalProcessTermination(rawWaitStatus: 9 | 0x80)
      == .signaled(signal: 9, coreDumped: true)
  )
  #expect(TerminalProcessTermination(rawWaitStatus: nil) == .ioFailure)
  #expect(TerminalProcessTermination(rawWaitStatus: 0x7F) == .ioFailure)
}

@Test("终端结束原因提供 Shell 惯例退出码和异常标记")
func terminalProcessTerminationExposesShellExitCode() {
  #expect(TerminalProcessTermination.exited(code: 0).shellExitCode == 0)
  #expect(!TerminalProcessTermination.exited(code: 0).isUnexpected)
  #expect(TerminalProcessTermination.exited(code: 2).isUnexpected)
  #expect(TerminalProcessTermination.signaled(signal: 9, coreDumped: false).shellExitCode == 137)
  #expect(TerminalProcessTermination.ioFailure.shellExitCode == nil)
}

@Test("用户主动退出才自动关闭 Pane，启动即失败与异常终止保留结束卡")
func terminalProcessTerminationDecidesPaneAutoClose() {
  let threshold = TerminalProcessTermination.minimumUptimeForNonZeroAutoClose
  // 退出码 0 不看运行时长。
  #expect(TerminalProcessTermination.exited(code: 0).closesPaneAutomatically(uptime: 0))
  // 不带参数的 exit 会沿用上一条命令的非零状态码：运行够久即视为用户主动退出。
  #expect(TerminalProcessTermination.exited(code: 1).closesPaneAutomatically(uptime: threshold))
  // Shell 刚启动就非零退出（配置错误）必须留下画面。
  #expect(!TerminalProcessTermination.exited(code: 127).closesPaneAutomatically(uptime: 0.2))
  #expect(
    !TerminalProcessTermination.signaled(signal: 9, coreDumped: false)
      .closesPaneAutomatically(uptime: 600))
  #expect(!TerminalProcessTermination.ioFailure.closesPaneAutomatically(uptime: 600))
}
