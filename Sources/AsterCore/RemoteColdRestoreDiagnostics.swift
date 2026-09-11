import Foundation

/// P6.6 冷恢复诊断与用户帮助。

/// 冷恢复诊断结果。
public struct ColdRestoreDiagnostic: Equatable, Sendable {
  public enum Issue: String, Equatable, Sendable {
    case corruptLayout = "corrupt_layout"
    case incompatibleVersion = "incompatible_version"
    case missingLayout = "missing_layout"
    case diskFull = "disk_full"
    case serviceNotRunning = "service_not_running"
    case restoreAlreadyCompleted = "restore_already_completed"
    case agentCLINotFound = "agent_cli_not_found"
    case agentRestoreFailed = "agent_restore_failed"
  }

  public let issue: Issue
  public let detail: String
  public let recoveryHint: String

  public init(issue: Issue, detail: String, recoveryHint: String) {
    self.issue = issue
    self.detail = detail
    self.recoveryHint = recoveryHint
  }

  /// 为常见问题生成用户帮助文本。
  public static func helpText(for issue: Issue) -> String {
    switch issue {
    case .corruptLayout:
      return "Layout data is damaged. A backup may be available; restart the service to attempt recovery."
    case .incompatibleVersion:
      return "Layout was created by a newer version. Update the service binary to restore."
    case .missingLayout:
      return "No layout data found. A fresh session will be created."
    case .diskFull:
      return "Disk is full. Free space and restart the service."
    case .serviceNotRunning:
      return "The service is not running. Start it to begin recovery."
    case .restoreAlreadyCompleted:
      return "Recovery was already completed by another client."
    case .agentCLINotFound:
      return "Agent CLI not found on the remote machine. A new shell was created instead."
    case .agentRestoreFailed:
      return "Agent session restore failed. A new shell was created instead."
    }
  }
}
