import Foundation

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

  /// 非零退出码至少运行这么久（秒）才算「用户主动退出」，见 `closesPaneAutomatically`。
  public static let minimumUptimeForNonZeroAutoClose: TimeInterval = 3

  /// Shell 结束后是否应自动关闭所在 Pane，而不是保留最后画面并显示结束卡。
  ///
  /// - 退出码 0：用户主动 `exit` / Ctrl+D，直接关闭。
  /// - 非零退出码：不带参数的 `exit` 会沿用上一条命令的状态码，所以不能一律当成异常；
  ///   但 Shell 刚启动就以非零码退出（配置写错、可执行文件缺失）时必须留下画面供排查，
  ///   因此只有运行时间达到 `minimumUptimeForNonZeroAutoClose` 才关闭。
  /// - 信号终止与 I/O 异常：不是用户意图，始终保留结束卡。
  ///
  /// - Parameter uptime: 进程从启动到结束的秒数。
  public func closesPaneAutomatically(uptime: TimeInterval) -> Bool {
    switch self {
    case .exited(let code):
      code == 0 || uptime >= Self.minimumUptimeForNonZeroAutoClose
    case .signaled, .ioFailure:
      false
    }
  }
}
