import AsterCore
import Testing

@Test("关闭确认策略按设置、运行进程与标签数决定是否询问")
func closeConfirmationPolicyMatchesSettings() {
  #expect(CloseConfirmation.always.requiresConfirmation(hasRunningProcess: false, tabCount: 1))
  #expect(!CloseConfirmation.never.requiresConfirmation(hasRunningProcess: true, tabCount: 5))
  #expect(CloseConfirmation.runningProcess.requiresConfirmation(hasRunningProcess: true, tabCount: 1))
  #expect(!CloseConfirmation.runningProcess.requiresConfirmation(hasRunningProcess: false, tabCount: 5))
  #expect(CloseConfirmation.multipleTabs.requiresConfirmation(hasRunningProcess: false, tabCount: 2))
  #expect(!CloseConfirmation.multipleTabs.requiresConfirmation(hasRunningProcess: true, tabCount: 1))
}
