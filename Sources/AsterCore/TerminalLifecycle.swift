/// 本地 Shell 的最终结束原因。
///
/// SwiftTerm 的 forkpty 路径把 `waitpid` 原始状态交给宿主，而不是直接交付退出码。
/// 该值必须先在领域边界规范化，否则 `exit 7` 会被错误显示为 `1792`，信号终止也会
/// 被误当成普通退出。I/O 层无法取得子进程状态时使用 `ioFailure`。
public enum TerminalProcessTermination: Equatable, Sendable {
  case exited(code: Int32)
  case signaled(signal: Int32, coreDumped: Bool)
  case ioFailure

  /// 从 `waitpid` 原始状态创建稳定的结束原因；nil 表示 PTY/I/O 提前中断且没有状态。
  public init(rawWaitStatus: Int32?) {
    guard let status = rawWaitStatus else {
      self = .ioFailure
      return
    }

    let lowBits = status & 0x7F
    if lowBits == 0 {
      self = .exited(code: (status >> 8) & 0xFF)
    } else if lowBits == 0x7F {
      // 进程停止状态不是最终退出；SwiftTerm 的 exit monitor 理论上不会产生该值。
      // 若底层违背契约，按连接异常处理，避免把 127 错报成终止信号。
      self = .ioFailure
    } else {
      self = .signaled(signal: lowBits, coreDumped: (status & 0x80) != 0)
    }
  }

  /// Shell 惯例中的退出码：信号终止映射为 `128 + signal`，I/O 异常没有退出码。
  public var shellExitCode: Int32? {
    switch self {
    case .exited(let code): code
    case .signaled(let signal, _): 128 + signal
    case .ioFailure: nil
    }
  }

  public var isUnexpected: Bool {
    switch self {
    case .exited(let code): code != 0
    case .signaled, .ioFailure: true
    }
  }
}
