import Testing

@testable import Aster

private final class TerminationParticipantStub: WorkspaceTerminationParticipant {
  let allowsTermination: Bool
  private(set) var confirmationCount = 0
  private(set) var commitCount = 0

  init(allowsTermination: Bool) {
    self.allowsTermination = allowsTermination
  }

  func confirmTermination() -> Bool {
    confirmationCount += 1
    return allowsTermination
  }

  func commitTermination() {
    commitCount += 1
  }
}

@Test("多窗口退出先完成全部确认，任一取消时不提交任何窗口")
@MainActor
func terminationTransactionHasNoPartialCommit() {
  let first = TerminationParticipantStub(allowsTermination: true)
  let cancelled = TerminationParticipantStub(allowsTermination: false)

  #expect(!WorkspaceTerminationTransaction.commit([first, cancelled]))
  #expect(first.confirmationCount == 1)
  #expect(cancelled.confirmationCount == 1)
  #expect(first.commitCount == 0)
  #expect(cancelled.commitCount == 0)
}

@Test("全部窗口确认后统一提交一次")
@MainActor
func terminationTransactionCommitsEveryParticipant() {
  let first = TerminationParticipantStub(allowsTermination: true)
  let second = TerminationParticipantStub(allowsTermination: true)

  #expect(WorkspaceTerminationTransaction.commit([first, second]))
  #expect(first.commitCount == 1)
  #expect(second.commitCount == 1)
}
