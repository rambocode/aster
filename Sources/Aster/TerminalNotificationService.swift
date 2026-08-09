import AppKit
import AsterCore
import Foundation
import UserNotifications

extension Notification.Name {
  static let terminalNotificationAuthorizationDidChange = Notification.Name(
    "Aster.TerminalNotificationAuthorizationDidChange")
}

/// Session 到 macOS 通知交付层的最小接口。生产实现负责权限、前台策略和 Dock attention；
/// 测试实现可只记录已获准进入交付边界的领域通知，不触碰用户通知中心。
@MainActor
protocol TerminalNotificationPosting: AnyObject {
  func post(
    _ notification: TerminalNotification,
    category: TerminalNotificationCategory,
    configuration: ShellConfiguration,
    sourceTabIsFocused: Bool
  )
}

/// macOS 通知中心与 Dock attention 的唯一交付边界。协议解析和策略判断均在
/// `AsterCore` 完成，本类型不接触原始 PTY 字节，也不会把控制字符写入系统 UI。
@MainActor
final class TerminalNotificationService: TerminalNotificationPosting {
  static let shared = TerminalNotificationService()

  private let injectedCenter: UNUserNotificationCenter?
  private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

  init(center: UNUserNotificationCenter? = nil) {
    injectedCenter = center
  }

  func refreshAuthorizationStatus(completion: (@MainActor @Sendable () -> Void)? = nil) {
    guard let center = notificationCenter else {
      completion?()
      return
    }
    center.getNotificationSettings { [weak self] settings in
      let statusValue = settings.authorizationStatus.rawValue
      Task { @MainActor [weak self] in
        guard let self else { return }
        let next = UNAuthorizationStatus(rawValue: statusValue) ?? .notDetermined
        let changed = authorizationStatus != next
        authorizationStatus = next
        if changed {
          NotificationCenter.default.post(name: .terminalNotificationAuthorizationDidChange, object: self)
        }
        completion?()
      }
    }
  }

  var authorizationSummary: String {
    guard notificationCenterIsAvailable else { return "当前构建不可用" }
    return switch authorizationStatus {
    case .authorized, .provisional, .ephemeral: "已允许"
    case .denied: "已关闭"
    case .notDetermined: "尚未请求"
    @unknown default: "状态未知"
    }
  }

  func openSystemSettings() {
    guard let url = URL(
      string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
    ) else { return }
    NSWorkspace.shared.open(url)
  }

  func post(
    _ notification: TerminalNotification,
    category: TerminalNotificationCategory,
    configuration: ShellConfiguration,
    sourceTabIsFocused: Bool
  ) {
    let policy = TerminalNotificationPolicy(
      shellControlled: configuration.resolvedNotificationShellControlled,
      foregroundPolicy: configuration.resolvedNotifyWhileForeground,
      bounceDockIcon: configuration.resolvedBounceDockIcon,
      soundCategories: configuration.resolvedNotificationSoundCategories
    )
    guard let decision = policy.decision(
      category: category,
      applicationIsActive: NSApp.isActive,
      sourceTabIsFocused: sourceTabIsFocused
    ) else { return }

    if decision.bouncesDockIcon {
      NSApp.requestUserAttention(.informationalRequest)
    }
    deliver(notification, playsSound: decision.playsSound)
  }

  private func deliver(_ notification: TerminalNotification, playsSound: Bool) {
    guard let center = notificationCenter else { return }
    switch authorizationStatus {
    case .denied:
      return
    case .notDetermined:
      center.requestAuthorization(options: [.alert, .sound]) { [weak self] allowed, _ in
        Task { @MainActor [weak self] in
          self?.refreshAuthorizationStatus()
          if allowed { self?.schedule(notification, playsSound: playsSound) }
        }
      }
    case .authorized, .provisional, .ephemeral:
      schedule(notification, playsSound: playsSound)
    @unknown default:
      return
    }
  }

  private func schedule(_ notification: TerminalNotification, playsSound: Bool) {
    guard let center = notificationCenter else { return }
    let content = UNMutableNotificationContent()
    content.title = notification.title.isEmpty ? "Aster" : notification.title
    content.body = notification.body
    if playsSound { content.sound = .default }
    if notification.urgency == .critical {
      // Critical Alert 需要额外 entitlement；time-sensitive 是无特权构建可用的最接近映射。
      content.interruptionLevel = .timeSensitive
    }
    let identifier = notification.identifier.map { "aster.terminal.\($0)" } ?? UUID().uuidString
    center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: nil))
  }

  /// `UNUserNotificationCenter.current()` 在 SwiftPM 测试宿主中会抛 Objective-C
  /// exception（测试进程没有应用 Bundle）。因此只在真实 app bundle 中延迟解析；
  /// 注入中心仍可用于隔离测试。
  private var notificationCenterIsAvailable: Bool {
    injectedCenter != nil || Bundle.main.bundleIdentifier != nil
  }

  private var notificationCenter: UNUserNotificationCenter? {
    if let injectedCenter { return injectedCenter }
    guard Bundle.main.bundleIdentifier != nil else { return nil }
    return .current()
  }
}
