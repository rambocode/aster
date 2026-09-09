import Foundation
import Testing

@testable import AsterCore

/// P4.6：客户端独立焦点、画面兴趣集合与「先快照后交互」（A15.1/A15.3）。

private let surfaceA = "term-a"
private let surfaceB = "term-b"

@Test func remoteWorkP4ClientsDoNotStealEachOthersFocus() {
  var first = ClientSurfaceInterest(clientID: "client-1")
  var second = ClientSurfaceInterest(clientID: "client-2")
  let paneOne = UUID()
  let paneTwo = UUID()

  first.focus(paneID: paneOne)
  second.focus(paneID: paneTwo)

  // 两个客户端各持一份状态，彼此没有共享可变量，所以焦点互不影响。
  #expect(first.focusedPaneID == paneOne)
  #expect(second.focusedPaneID == paneTwo)
}

@Test func remoteWorkP4HiddenSurfaceCancelsSubscription() {
  var interest = ClientSurfaceInterest(clientID: "client-1")
  _ = interest.becameVisible(terminalID: surfaceA)
  interest.confirmSnapshot(terminalID: surfaceA)
  #expect(interest.visibleSurfaces == [surfaceA])

  let intents = interest.becameHidden(terminalID: surfaceA)
  #expect(intents == [.unsubscribe(terminalID: surfaceA)])
  #expect(interest.visibleSurfaces.isEmpty)
  #expect(interest.gate(terminalID: surfaceA) == .closed)
  // 隐藏只取消画面订阅：结构与 Agent 事件订阅是会话级的，不在本类型内被取消。
  #expect(!interest.allowsInteraction(terminalID: surfaceA))
}

@Test func remoteWorkP4VisibleAgainRequiresSnapshotBeforeInteraction() {
  var interest = ClientSurfaceInterest(clientID: "client-1")

  let intents = interest.becameVisible(terminalID: surfaceA)
  #expect(intents == [.subscribe(terminalID: surfaceA), .requestSnapshot(terminalID: surfaceA)])
  // 快照确认之前不放行交互。
  #expect(interest.gate(terminalID: surfaceA) == .awaitingSnapshot)
  #expect(!interest.allowsInteraction(terminalID: surfaceA))

  interest.confirmSnapshot(terminalID: surfaceA)
  #expect(interest.gate(terminalID: surfaceA) == .open)
  #expect(interest.allowsInteraction(terminalID: surfaceA))
}

@Test func remoteWorkP4AlreadyVisibleSurfaceOnlyRefetchesSnapshot() {
  var interest = ClientSurfaceInterest(clientID: "client-1")
  _ = interest.becameVisible(terminalID: surfaceA)
  interest.confirmSnapshot(terminalID: surfaceA)

  let intents = interest.becameVisible(terminalID: surfaceA)
  #expect(intents == [.requestSnapshot(terminalID: surfaceA)])
  #expect(interest.gate(terminalID: surfaceA) == .awaitingSnapshot)
}

@Test func remoteWorkP4ResizeOnlyFromVisibleWriteLeaseHolder() {
  var interest = ClientSurfaceInterest(clientID: "client-1")

  // 不可见 → 拒绝。
  #expect(interest.resizeDecision(terminalID: surfaceA) == .rejected(.notVisible))

  _ = interest.becameVisible(terminalID: surfaceA)
  // 可见但没有写租约（只读观察者）→ 拒绝。
  #expect(interest.resizeDecision(terminalID: surfaceA) == .rejected(.noWriteLease))

  interest.acquireWriteLease(terminalID: surfaceA)
  // 有租约但快照还没确认 → 拒绝。
  #expect(interest.resizeDecision(terminalID: surfaceA) == .rejected(.gateNotOpen))

  interest.confirmSnapshot(terminalID: surfaceA)
  #expect(interest.resizeDecision(terminalID: surfaceA) == .allowed)

  interest.releaseWriteLease(terminalID: surfaceA)
  #expect(interest.resizeDecision(terminalID: surfaceA) == .rejected(.noWriteLease))
}

@Test func remoteWorkP4ConnectionLossClosesAllGatesAndLeases() {
  var interest = ClientSurfaceInterest(clientID: "client-1")
  _ = interest.becameVisible(terminalID: surfaceA)
  _ = interest.becameVisible(terminalID: surfaceB)
  interest.confirmSnapshot(terminalID: surfaceA)
  interest.confirmSnapshot(terminalID: surfaceB)
  interest.acquireWriteLease(terminalID: surfaceA)

  let intents = interest.connectionLost()
  #expect(
    intents == [.unsubscribe(terminalID: surfaceA), .unsubscribe(terminalID: surfaceB)])
  #expect(!interest.allowsInteraction(terminalID: surfaceA))
  #expect(!interest.allowsInteraction(terminalID: surfaceB))
  #expect(interest.resizeDecision(terminalID: surfaceA) == .rejected(.noWriteLease))
}

@Test func remoteWorkP4HidingUnknownSurfaceProducesNoIntent() {
  var interest = ClientSurfaceInterest(clientID: "client-1")
  #expect(interest.becameHidden(terminalID: surfaceA).isEmpty)
}
