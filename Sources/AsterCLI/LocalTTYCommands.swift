import Darwin
import Foundation

// 不经过 App、直接向当前 TTY 写 OSC 的本地命令：`watch` 与 `tab badge`。
// 语义逐条对照旧 sh 启动器（Sources/Aster/AutocompleteService.swift 的 AsterCLIScript）：
// 用法错误退出 64（EX_USAGE），watch 透传被包装命令的退出码。

/// 本地 TTY 命令的处理结果：nil 表示 argv 不是本地命令，应继续交给 socket。
enum LocalTTYCommands {
  /// 旧脚本约定的用法错误码。
  static let usageExitCode: Int32 = 64

  /// 尝试把 legacy argv 当作本地命令执行；命中则返回进程退出码。
  /// 只匹配 argv 首元素（旧脚本只检查 `$1`），`aster -q watch …` 之类前置全局选项仍走服务端。
  static func run(_ argv: [String]) -> Int32? {
    guard let first = argv.first else { return nil }
    if first == "watch" {
      return runWatch(Array(argv.dropFirst()))
    }
    if first == "tab", argv.count >= 2, argv[1] == "badge" {
      return runTabBadge(Array(argv.dropFirst(2)))
    }
    return nil
  }

  // MARK: - watch

  /// `aster watch [-q|--quiet] <command> [args...]`：先发 OSC 9;4;3（任务开始），
  /// 跑完命令再发 OSC 9;4;5;<status>;watch[;quiet]（任务结束），退出码原样透传。
  private static func runWatch(_ input: [String]) -> Int32 {
    var arguments = input
    var quiet = false
    if let flag = arguments.first, flag == "-q" || flag == "--quiet" {
      quiet = true
      arguments.removeFirst()
    }
    guard !arguments.isEmpty else {
      writeStandardError("usage: aster watch [-q|--quiet] <command> [args ...]\n")
      return usageExitCode
    }
    writeTTY("\u{1B}]9;4;3\u{07}")
    let status = runChildCommand(arguments)
    writeTTY("\u{1B}]9;4;5;\(status);watch\(quiet ? ";quiet" : "")\u{07}")
    return status
  }

  /// 通过 `/usr/bin/env` 按 PATH 查找并执行命令，继承 stdio 与控制终端。
  /// 被信号杀死时按 shell 惯例返回 128+signal，与旧脚本 `$?` 语义一致。
  private static func runChildCommand(_ arguments: [String]) -> Int32 {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = arguments
    do {
      try process.run()
    } catch {
      writeStandardError("aster: cannot run \(arguments[0]): \(error.localizedDescription)\n")
      return 126
    }
    process.waitUntilExit()
    if process.terminationReason == .uncaughtSignal {
      return 128 + process.terminationStatus
    }
    return process.terminationStatus
  }

  // MARK: - tab badge

  /// 允许的徽章种类，与旧脚本 case 列表一致。
  private static let badgeKinds: Set<String> = [
    "running", "completed", "finished", "unread", "error", "awaiting-input",
  ]

  /// `aster tab badge --kind <kind>` / `aster tab badge --clear`：写 OSC 6974;Badge=…。
  private static func runTabBadge(_ arguments: [String]) -> Int32 {
    if arguments.first == "--clear" {
      writeTTY("\u{1B}]6974;Badge=clear\u{07}")
      return 0
    }
    guard arguments.count == 2, arguments[0] == "--kind" else {
      writeStandardError(
        "usage: aster tab badge --kind running|completed|finished|unread|error|awaiting-input\n"
          + "       aster tab badge --clear\n")
      return usageExitCode
    }
    let kind = arguments[1]
    guard badgeKinds.contains(kind) else {
      writeStandardError("aster: invalid badge kind: \(kind)\n")
      return usageExitCode
    }
    writeTTY("\u{1B}]6974;Badge=\(kind)\u{07}")
    return 0
  }

  // MARK: - 输出

  /// OSC 优先写 /dev/tty：即便 stdout 被重定向到文件或管道，序列也能抵达终端而不污染输出。
  /// 没有控制终端（如被无 tty 的脚本调用）时退回 stdout，保持旧脚本行为。
  private static func writeTTY(_ sequence: String) {
    let bytes = Array(sequence.utf8)
    let tty = open("/dev/tty", O_WRONLY | O_NOCTTY)
    let descriptor = tty >= 0 ? tty : STDOUT_FILENO
    _ = bytes.withUnsafeBufferPointer { write(descriptor, $0.baseAddress, $0.count) }
    if tty >= 0 { close(tty) }
  }

  private static func writeStandardError(_ text: String) {
    FileHandle.standardError.write(Data(text.utf8))
  }
}
