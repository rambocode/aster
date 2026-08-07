import Carbon.HIToolbox
import Foundation

/// 进程级安全键盘输入协调器。Carbon 的 Secure Event Input 是全局状态，多窗口和多 Pane
/// 必须共享引用计数；任何一个自动或手动请求仍存在时都不能提前调用 Disable。
@MainActor
final class SecureInputCoordinator {
  typealias EnableSystemProtection = @MainActor () -> Bool
  typealias DisableSystemProtection = @MainActor () -> Bool

  static let shared = SecureInputCoordinator(
    enableSystemProtection: { EnableSecureEventInput() == noErr },
    disableSystemProtection: { DisableSecureEventInput() == noErr }
  )

  private let enableSystemProtection: EnableSystemProtection
  private let disableSystemProtection: DisableSystemProtection
  private var automaticOwners: Set<UUID> = []
  private var isApplicationActive = true
  private(set) var isManualRequestActive = false
  private(set) var isSystemProtectionActive = false

  var isProtectionRequested: Bool {
    isApplicationActive && (isManualRequestActive || !automaticOwners.isEmpty)
  }

  init(
    enableSystemProtection: @escaping EnableSystemProtection,
    disableSystemProtection: @escaping DisableSystemProtection
  ) {
    self.enableSystemProtection = enableSystemProtection
    self.disableSystemProtection = disableSystemProtection
  }

  func setAutomaticRequest(for owner: UUID, active: Bool) {
    if active {
      automaticOwners.insert(owner)
    } else {
      automaticOwners.remove(owner)
    }
    synchronizeSystemProtection()
  }

  func releaseAutomaticRequest(for owner: UUID) {
    automaticOwners.remove(owner)
    synchronizeSystemProtection()
  }

  func setManualRequest(active: Bool) {
    isManualRequestActive = active
    synchronizeSystemProtection()
  }

  func toggleManualRequest() {
    setManualRequest(active: !isManualRequestActive)
  }

  /// Secure Event Input 只能在本应用活动期间占用。手动开关的用户意图保留，切回
  /// Aster 后恢复；失活期间必须立即释放，避免阻断其它应用的全局快捷键。
  func setApplicationActive(_ active: Bool) {
    isApplicationActive = active
    synchronizeSystemProtection()
  }

  private func synchronizeSystemProtection() {
    if isProtectionRequested {
      if !isSystemProtectionActive {
        // 失败时保留请求但不伪报成功；后续轮询或手动操作会继续尝试启用。
        isSystemProtectionActive = enableSystemProtection()
      }
    } else if isSystemProtectionActive {
      // 关闭失败时继续报告为活动；后续 Pane 轮询或手动操作会再次同步，避免
      // 系统仍保护输入但协调器误报已释放。
      if disableSystemProtection() {
        isSystemProtectionActive = false
      }
    }
  }
}
