import Foundation
import Testing

@testable import Aster

@Test("安全输入协调器只在首个请求和最后释放时调用系统 API")
@MainActor
func secureInputCoordinatorBalancesMultipleOwners() {
  var enables = 0
  var disables = 0
  let coordinator = SecureInputCoordinator(
    enableSystemProtection: {
      enables += 1
      return true
    },
    disableSystemProtection: {
      disables += 1
      return true
    }
  )
  let first = UUID()
  let second = UUID()

  coordinator.setAutomaticRequest(for: first, active: true)
  coordinator.setAutomaticRequest(for: first, active: true)
  coordinator.setAutomaticRequest(for: second, active: true)
  #expect(enables == 1)
  #expect(disables == 0)
  #expect(coordinator.isProtectionRequested)

  coordinator.setAutomaticRequest(for: first, active: false)
  #expect(disables == 0)
  coordinator.setAutomaticRequest(for: second, active: false)
  #expect(disables == 1)
  #expect(!coordinator.isProtectionRequested)
}

@Test("手动安全输入与自动会话请求独立叠加")
@MainActor
func secureInputCoordinatorCombinesManualAndAutomaticRequests() {
  var transitions: [String] = []
  let coordinator = SecureInputCoordinator(
    enableSystemProtection: {
      transitions.append("enable")
      return true
    },
    disableSystemProtection: {
      transitions.append("disable")
      return true
    }
  )
  let owner = UUID()

  coordinator.setManualRequest(active: true)
  coordinator.setAutomaticRequest(for: owner, active: true)
  coordinator.setManualRequest(active: false)
  #expect(transitions == ["enable"])
  #expect(coordinator.isProtectionRequested)

  coordinator.releaseAutomaticRequest(for: owner)
  #expect(transitions == ["enable", "disable"])
}

@Test("系统拒绝启用安全输入时不伪报为已保护")
@MainActor
func secureInputCoordinatorReportsEnableFailure() {
  var attempts = 0
  let coordinator = SecureInputCoordinator(
    enableSystemProtection: {
      attempts += 1
      return false
    },
    disableSystemProtection: { true }
  )

  coordinator.setManualRequest(active: true)

  #expect(attempts == 1)
  #expect(coordinator.isProtectionRequested)
  #expect(!coordinator.isSystemProtectionActive)
}

@Test("系统拒绝关闭安全输入时保留活动状态并允许重试")
@MainActor
func secureInputCoordinatorRetriesDisableFailure() {
  var disableAttempts = 0
  let coordinator = SecureInputCoordinator(
    enableSystemProtection: { true },
    disableSystemProtection: {
      disableAttempts += 1
      return disableAttempts > 1
    }
  )

  coordinator.setManualRequest(active: true)
  coordinator.setManualRequest(active: false)
  #expect(disableAttempts == 1)
  #expect(coordinator.isSystemProtectionActive)

  coordinator.setManualRequest(active: false)
  #expect(disableAttempts == 2)
  #expect(!coordinator.isSystemProtectionActive)
}

@Test("应用失活时暂停手动安全输入并在激活后恢复")
@MainActor
func secureInputCoordinatorSuspendsManualRequestWhileInactive() {
  var transitions: [String] = []
  let coordinator = SecureInputCoordinator(
    enableSystemProtection: {
      transitions.append("enable")
      return true
    },
    disableSystemProtection: {
      transitions.append("disable")
      return true
    }
  )

  coordinator.setManualRequest(active: true)
  coordinator.setApplicationActive(false)
  #expect(coordinator.isManualRequestActive)
  #expect(!coordinator.isProtectionRequested)
  #expect(!coordinator.isSystemProtectionActive)

  coordinator.setApplicationActive(true)
  #expect(coordinator.isSystemProtectionActive)
  #expect(transitions == ["enable", "disable", "enable"])
}
