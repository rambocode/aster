import Foundation

/// 终端任务的协议级状态。该值只描述一个 Pane，不持有 AppKit 视图或进程对象。
public enum TerminalProgressState: Equatable, Sendable {
  case clear
  case determinate(percent: Int)
  case error(percent: Int?)
  case indeterminate
  case finished(exitCode: Int, watched: Bool, notificationSuppressed: Bool = false)

  public var isWorking: Bool {
    switch self {
    case .determinate, .indeterminate: true
    case .clear, .error, .finished: false
    }
  }

  public var reportsError: Bool {
    switch self {
    case .error: true
    case let .finished(exitCode, _, _): exitCode != 0
    case .clear, .determinate, .indeterminate: false
    }
  }
}

/// 解析 ConEmu `OSC 9;4` 以及 Aster/Otty 的完成扩展。
public enum TerminalProgressParser {
  public static func parseOSC9(_ payload: String) -> TerminalProgressState? {
    let parts = payload.split(separator: ";", omittingEmptySubsequences: false)
    guard parts.count >= 2, parts[0] == "4", let state = Int(parts[1]) else { return nil }

    switch state {
    case 0:
      return .clear
    case 1:
      guard parts.count >= 3, !parts[2].isEmpty else {
        return .determinate(percent: 0)
      }
      guard let percent = Int(parts[2]) else { return nil }
      return .determinate(percent: min(max(percent, 0), 100))
    case 2:
      guard parts.count >= 3, !parts[2].isEmpty else { return .error(percent: nil) }
      guard let percent = Int(parts[2]) else { return nil }
      return .error(percent: min(max(percent, 0), 100))
    case 3:
      return .indeterminate
    case 4:
      // Otty 明确忽略 paused/warning；nil 也防止它覆盖仍由其它来源维护的状态。
      return nil
    case 5:
      guard parts.count >= 3, let exitCode = Int(parts[2]) else { return nil }
      let tags = parts.dropFirst(3)
      return .finished(
        exitCode: exitCode,
        watched: tags.contains("watch"),
        notificationSuppressed: tags.contains("quiet")
      )
    default:
      return nil
    }
  }
}

/// 按空白分词匹配自动进度命令，避免 `git push` 错命中 `git pushd`。
public struct AutomaticProgressMatcher: Equatable, Sendable {
  public static let defaultPrefixes = [
    "curl", "wget", "rsync", "scp",
    "git fetch", "git pull", "git push", "git clone",
    "brew install", "brew update", "brew upgrade",
    "npm install", "pnpm install", "yarn install", "bun install",
    "pip install", "pip3 install",
    "cargo build", "cargo install", "cargo update",
    "docker pull", "docker push", "docker build",
    "apt install", "apt update", "apt upgrade",
    "apt-get install", "apt-get update", "apt-get upgrade",
  ]

  public let prefixes: [String]

  public init(prefixes: [String] = Self.defaultPrefixes) {
    self.prefixes = prefixes
  }

  public func matches(_ command: String) -> Bool {
    let commandParts = command.split(whereSeparator: \.isWhitespace).map(String.init)
    guard !commandParts.isEmpty else { return false }
    return prefixes.contains { prefix in
      let prefixParts = prefix.split(whereSeparator: \.isWhitespace).map(String.init)
      return !prefixParts.isEmpty
        && commandParts.count >= prefixParts.count
        && commandParts.prefix(prefixParts.count).elementsEqual(prefixParts)
    }
  }
}

/// 检测停留在输出尾部的常见交互提示；调用方必须额外满足约 1.5 秒静默窗口。
public enum AwaitingInputPromptDetector {
  private static let patterns = [
    #"(?i)(?:password|passphrase)(?:\s+for\s+[^:]+)?\s*:\s*$"#,
    #"(?i)(?:\[(?:y/n|y/N|Y/n)\]|\((?:yes/no|y/n)\))\s*\??\s*$"#,
    #"(?i)press\s+(?:enter|return)(?:\s+to\s+[^\r\n]*)?\s*$"#,
  ]

  public static func matches(_ outputTail: String) -> Bool {
    let normalized = outputTail.replacingOccurrences(of: "\r", with: "")
    guard let tail = normalized.split(separator: "\n", omittingEmptySubsequences: false).last else {
      return false
    }
    let line = String(tail)
    guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
    return patterns.contains { line.range(of: $0, options: .regularExpression) != nil }
  }
}

public enum TerminalNotificationUrgency: Int, Codable, Equatable, Sendable {
  case low = 0
  case normal = 1
  case critical = 2
}

/// 已完成安全解码、可交给系统通知层的不可变消息。
public struct TerminalNotification: Equatable, Sendable {
  public let identifier: String?
  public let title: String
  public let body: String
  public let urgency: TerminalNotificationUrgency

  public init(
    identifier: String? = nil,
    title: String,
    body: String,
    urgency: TerminalNotificationUrgency = .normal
  ) {
    self.identifier = identifier
    self.title = title
    self.body = body
    self.urgency = urgency
  }
}

public enum TerminalNotificationParser {
  public static let maximumChunkBytes = 8_192

  public static func parseOSC9(_ payload: String) -> TerminalNotification? {
    guard payload.utf8.count <= maximumChunkBytes, !payload.isEmpty else { return nil }
    return TerminalNotification(title: "Aster", body: sanitized(payload), urgency: .normal)
  }

  public static func parseOSC777(_ payload: String) -> TerminalNotification? {
    guard payload.utf8.count <= maximumChunkBytes else { return nil }
    let parts = payload.split(separator: ";", omittingEmptySubsequences: false)
    guard parts.count >= 3, parts[0] == "notify" else { return nil }
    return TerminalNotification(
      title: sanitized(String(parts[1])),
      body: sanitized(parts.dropFirst(2).joined(separator: ";")),
      urgency: .normal
    )
  }

  /// 丢弃 C0/C1 控制字符，阻止终端转义序列穿透到通知中心；保留普通 Unicode 文本。
  static func sanitized(_ value: String) -> String {
    String(value.unicodeScalars.filter { scalar in
      let value = scalar.value
      return value >= 0x20 && value != 0x7f && !(0x80...0x9f).contains(value)
    })
  }
}

public enum KittyNotificationResult: Equatable, Sendable {
  case notification(TerminalNotification)
  case response(String)
}

/// 有界重组 Kitty `OSC 99`。未完成分片只存在于当前会话内，Session 销毁即释放。
public struct KittyNotificationAssembler: Sendable {
  private struct Partial: Sendable {
    var title = ""
    var body = ""
    var urgency = TerminalNotificationUrgency.normal
  }

  private var partials: [String: Partial] = [:]
  private let maximumTotalBytes = 65_536
  /// 限制并发分片 ID 数，防止子进程用大量永不结束的通知占用会话内存。
  public static let maximumPendingNotifications = 64
  /// 所有未完成通知共享的字节预算；单条消息仍受 `maximumTotalBytes` 的独立限制。
  public static let maximumPendingBytes = 262_144

  public init() {}

  public var pendingNotificationCount: Int { partials.count }

  public mutating func consume(_ payload: String) -> KittyNotificationResult? {
    guard payload.utf8.count <= TerminalNotificationParser.maximumChunkBytes,
      let separator = payload.firstIndex(of: ";")
    else { return nil }

    let metadataText = String(payload[..<separator])
    let rawPayload = String(payload[payload.index(after: separator)...])
    var metadata: [String: String] = [:]
    for field in metadataText.split(separator: ":", omittingEmptySubsequences: false) {
      let pair = field.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      if pair.count == 2 { metadata[String(pair[0])] = String(pair[1]) }
    }

    let identifier = TerminalNotificationParser.sanitized(metadata["i"] ?? "")
    if metadata["p"] == "?" {
      return .response("\u{1B}]99;i=\(identifier):p=?;ok\u{1B}\\")
    }

    let decodedPayload: String
    if metadata["e"] == "1" {
      guard let data = Data(base64Encoded: rawPayload),
        let text = String(data: data, encoding: .utf8)
      else {
        partials.removeValue(forKey: identifier)
        return nil
      }
      decodedPayload = text
    } else {
      decodedPayload = rawPayload
    }

    var partial = partials[identifier] ?? Partial()
    if let rawUrgency = metadata["u"], let urgencyValue = Int(rawUrgency),
      let urgency = TerminalNotificationUrgency(rawValue: urgencyValue)
    {
      partial.urgency = urgency
    }
    switch metadata["p"] ?? "title" {
    case "body": partial.body += decodedPayload
    case "title": partial.title += decodedPayload
    default: break  // 已知但无系统映射的 payload 类型按 kitty 兼容策略忽略。
    }

    guard partial.title.utf8.count + partial.body.utf8.count <= maximumTotalBytes else {
      partials.removeValue(forKey: identifier)
      return nil
    }
    if metadata["d"] == "0" {
      let previousBytes = partials[identifier].map(Self.byteCount) ?? 0
      let pendingBytes = partials.values.reduce(0) { $0 + Self.byteCount($1) }
      let projectedBytes = pendingBytes - previousBytes + Self.byteCount(partial)
      guard (partials[identifier] != nil || partials.count < Self.maximumPendingNotifications),
        projectedBytes <= Self.maximumPendingBytes
      else {
        // 超限时仅丢弃当前 ID，既释放它已有的分片，也不干扰其它正常通知。
        partials.removeValue(forKey: identifier)
        return nil
      }
      partials[identifier] = partial
      return nil
    }

    partials.removeValue(forKey: identifier)
    return .notification(
      TerminalNotification(
        identifier: identifier.isEmpty ? nil : identifier,
        title: TerminalNotificationParser.sanitized(partial.title),
        body: TerminalNotificationParser.sanitized(partial.body),
        urgency: partial.urgency
      )
    )
  }

  private static func byteCount(_ partial: Partial) -> Int {
    partial.title.utf8.count + partial.body.utf8.count
  }
}

public enum NotificationForegroundPolicy: String, CaseIterable, Codable, Equatable, Sendable {
  case off
  case always
  case tabUnfocused = "tab-unfocused"
}

public enum TerminalNotificationCategory: String, CaseIterable, Codable, Hashable, Sendable {
  case errorExit
  case commandFinish
  case application
}

public struct NotificationDeliveryDecision: Equatable, Sendable {
  public let playsSound: Bool
  public let bouncesDockIcon: Bool

  public init(playsSound: Bool, bouncesDockIcon: Bool) {
    self.playsSound = playsSound
    self.bouncesDockIcon = bouncesDockIcon
  }
}

/// 将配置与当前焦点状态归并为一次通知投递决定，便于脱离 AppKit 做完整策略测试。
public struct TerminalNotificationPolicy: Equatable, Sendable {
  public let shellControlled: Bool
  public let foregroundPolicy: NotificationForegroundPolicy
  public let bounceDockIcon: Bool
  public let soundCategories: Set<TerminalNotificationCategory>

  public init(
    shellControlled: Bool,
    foregroundPolicy: NotificationForegroundPolicy = .off,
    bounceDockIcon: Bool = true,
    soundCategories: Set<TerminalNotificationCategory> = []
  ) {
    self.shellControlled = shellControlled
    self.foregroundPolicy = foregroundPolicy
    self.bounceDockIcon = bounceDockIcon
    self.soundCategories = soundCategories
  }

  public func decision(
    category: TerminalNotificationCategory,
    applicationIsActive: Bool,
    sourceTabIsFocused: Bool
  ) -> NotificationDeliveryDecision? {
    if category == .application && !shellControlled { return nil }
    if applicationIsActive {
      switch foregroundPolicy {
      case .off: return nil
      case .always: break
      case .tabUnfocused where sourceTabIsFocused: return nil
      case .tabUnfocused: break
      }
    }
    return NotificationDeliveryDecision(
      playsSound: soundCategories.contains(category),
      bouncesDockIcon: bounceDockIcon && !applicationIsActive
    )
  }
}

public enum TerminalBadgeState: Equatable, Sendable {
  case none
  case running(percent: Int?)
  case completed
  case finished
  case error
  case awaitingInput
}

public enum TerminalBadgeResolver {
  public static func resolve(
    progress: TerminalProgressState,
    awaitingInput: Bool,
    lastExitCode: Int?
  ) -> TerminalBadgeState {
    if progress.reportsError { return .error }
    if awaitingInput { return .awaitingInput }
    switch progress {
    case let .determinate(percent): return .running(percent: percent)
    case .indeterminate: return .running(percent: nil)
    case let .finished(exitCode, _, _): return exitCode == 0 ? .finished : .error
    case .clear, .error:
      if let lastExitCode { return lastExitCode == 0 ? .finished : .error }
      return .none
    }
  }
}

public enum TerminalBadgeDirective: Equatable, Sendable {
  case set(TerminalBadgeState)
  case clear

  public init?(payload: String) {
    guard payload.utf8.count <= 64 else { return nil }
    switch payload {
    case "Badge=running": self = .set(.running(percent: nil))
    case "Badge=completed": self = .set(.completed)
    case "Badge=finished", "Badge=unread": self = .set(.finished)
    case "Badge=error": self = .set(.error)
    case "Badge=awaiting-input": self = .set(.awaitingInput)
    case "Badge=clear": self = .clear
    default: return nil
    }
  }
}

public enum DockActivityState: Equatable, Sendable {
  case idle
  case working
  case error
}

public enum DockActivityResolver {
  public static func resolve(
    badges: [TerminalBadgeState],
    animateOnProgress: Bool,
    redOnError: Bool
  ) -> DockActivityState {
    if redOnError, badges.contains(.error) { return .error }
    if animateOnProgress,
      badges.contains(where: {
        if case .running = $0 { return true }
        return false
      })
    {
      return .working
    }
    return .idle
  }
}
