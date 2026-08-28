import AsterCore
import Foundation

/// IPC 写门禁的唯一实现：旧 `aster pane send-text` 与 socket 控制协议共用，避免两套规则漂移。
/// 顺序固定：先看全局开关，再看敏感会话开关，最后看 Pane 自身是否可写。
enum AsterControlWriteGate {
  @MainActor
  static func blocker(
    session: TerminalSession,
    allowSendKeys: Bool,
    allowSensitiveSessions: Bool
  ) -> AsterControlError? {
    guard allowSendKeys else {
      return AsterControlError(code: .writeNotAllowed, message: "IPC Allow Send Keys 未开启。")
    }
    guard !session.isSensitiveAutomationSession || allowSensitiveSessions else {
      return AsterControlError(
        code: .sensitiveSessionNotAllowed, message: "敏感会话还需要开启 IPC Allow Sensitive Sessions。")
    }
    if let reason = session.promptWriteBlocker {
      return AsterControlError(code: .writeRejected, message: reason)
    }
    return nil
  }
}
