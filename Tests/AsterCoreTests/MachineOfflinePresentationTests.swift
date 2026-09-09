import Foundation
import Testing

@testable import AsterCore

/// P4.7：离线灰显、缓存时间、禁用输入/导航、重连不抢焦点、移除回 Local（A14）。

private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

private func status(
  _ state: SessionConnectionState,
  inputAllowed: Bool,
  reason: String? = nil
) -> MachineConnectionStatus {
  MachineConnectionStatus(
    profileID: UUID(),
    state: state,
    generation: 3,
    identity: nil,
    inputAllowed: inputAllowed,
    lastUpdatedAt: stamp,
    reason: reason
  )
}

@Test func remoteWorkP4OfflineKeepsStructureButBlocksInputAndNavigation() {
  let presentation = MachineOfflinePresentation.from(
    status(.reconnecting, inputAllowed: false, reason: "unreachable"))

  #expect(presentation.isStale)
  #expect(presentation.isDimmed)
  #expect(presentation.allowsInput == false)
  #expect(presentation.allowsNavigation == false)
  // 更新时间必须保留，界面据此显示「缓存于…」。
  #expect(presentation.lastUpdatedAt == stamp)
  #expect(presentation.reason == "unreachable")
}

@Test func remoteWorkP4OnlineWithoutConfirmedSnapshotStaysBlocked() {
  // 握手成功但快照未确认：仍然不允许输入与导航。
  let presentation = MachineOfflinePresentation.from(status(.online, inputAllowed: false))
  #expect(presentation.allowsInput == false)
  #expect(presentation.allowsNavigation == false)
  #expect(presentation.isStale)
}

@Test func remoteWorkP4OnlineAndConfirmedIsInteractive() {
  let presentation = MachineOfflinePresentation.from(status(.online, inputAllowed: true))
  #expect(presentation.allowsInput)
  #expect(presentation.allowsNavigation)
  #expect(!presentation.isStale)
  #expect(!presentation.isDimmed)
}

@Test func remoteWorkP4AttentionIsStaleAndBlocked() {
  let presentation = MachineOfflinePresentation.from(
    status(.attention, inputAllowed: false, reason: "host key unknown"))
  #expect(presentation.state == .attention)
  #expect(presentation.allowsInput == false)
  #expect(presentation.reason == "host key unknown")
}

@Test func remoteWorkP4ReconnectDoesNotStealActiveMachineOrFocus() {
  let active = UUID()
  let focused = UUID()
  let result = MachineActivationPolicy.afterReconnect(
    activeProfileID: active, focusedPaneID: focused)
  #expect(result.activeProfileID == active)
  #expect(result.focusedPaneID == focused)
}

@Test func remoteWorkP4DisablingAnotherMachineKeepsActiveSelection() {
  let active = UUID()
  let other = UUID()
  let result = MachineActivationPolicy.afterDisableOrRemove(
    activeProfileID: active, affectedProfileID: other)
  #expect(result.activeProfileID == active)
  #expect(result.focusChanged == false)
  #expect(result.localFailureReason == nil)
}

@Test func remoteWorkP4RemovingActiveMachineFallsBackToLocal() {
  let active = UUID()
  let result = MachineActivationPolicy.afterDisableOrRemove(
    activeProfileID: active, affectedProfileID: active)
  #expect(result.activeProfileID == MachineProfile.localProfileID)
  #expect(result.focusChanged)
  #expect(result.localFailureReason == nil)
}

@Test func remoteWorkP4BrokenLocalKeepsExplicitErrorInsteadOfJumpingToRemote() {
  let active = UUID()
  let result = MachineActivationPolicy.afterDisableOrRemove(
    activeProfileID: active,
    affectedProfileID: active,
    localFailureReason: "local session service failed to start"
  )
  // Local 不可用时保留 Local 的明确错误态，不自动跳到别的远端。
  #expect(result.activeProfileID == MachineProfile.localProfileID)
  #expect(result.localFailureReason == "local session service failed to start")
}
