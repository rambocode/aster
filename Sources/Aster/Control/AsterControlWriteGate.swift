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
    if let denied = policyBlocker(
      session: session, allowSendKeys: allowSendKeys,
      allowSensitiveSessions: allowSensitiveSessions)
    {
      return denied
    }
    if let reason = session.promptWriteBlocker {
      return AsterControlError(code: .writeRejected, message: reason)
    }
    return nil
  }

  /// 只做与 Pane 显示通道无关的策略判断：全局写开关与敏感会话开关。
  ///
  /// 受管终端的 `session.detach` / `session.end` 用这一段而不是完整的 `blocker`：它们不是
  /// 向 surface 键入，而是对服务端终端的生命周期动作。显示桥退出只说明本地显示通道断了，
  /// 服务端进程通常仍在运行；用 `promptWriteBlocker`（“终端进程已退出”）拦住，会让掉桥的
  /// 受管 Pane 再也无法被 CLI 分离或结束。存活判断改由服务端真实状态回答。
  @MainActor
  static func policyBlocker(
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
    return nil
  }
}
