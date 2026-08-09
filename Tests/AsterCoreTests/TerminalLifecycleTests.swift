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
