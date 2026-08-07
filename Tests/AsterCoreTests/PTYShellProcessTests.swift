import Foundation
import Testing

@testable import AsterCore

#if canImport(Darwin)
  import Darwin
#endif

private actor OutputCollector {
  private(set) var text = ""

  func append(_ chunk: String) {
    text += chunk
  }
}

private actor ExitCollector {
  private(set) var exitCode: Int32?

  func markExited(code: Int32) {
    exitCode = code
  }
}

private final class ExitSnapshotCollector: @unchecked Sendable {
  private let lock = NSLock()
  private var output = ""
  private(set) var outputAtExit: String?

  func append(_ chunk: String) {
    lock.lock()
    output += chunk
    lock.unlock()
  }

  func markExited() {
    lock.lock()
    outputAtExit = output
    lock.unlock()
  }

  func snapshot() -> String? {
    lock.lock()
    defer { lock.unlock() }
    return outputAtExit
  }
}

/// 这些用例会启动真实的交互式登录 Shell，并共享用户的 Shell 启动配置。串行执行
/// 可避免十余个并发 zsh 同时加载 prompt/plugin 后超过每个用例的 1 秒条件等待；
/// 测试仍然覆盖真实 PTY，而不是通过增加超时掩盖启动争用。
@Suite(.serialized)
struct PTYShellProcessTests {
  @Test("PTY 可以执行真实 shell 命令并返回输出", .timeLimit(.minutes(1)))
  func ptyExecutesShellCommand() async throws {
    let collector = OutputCollector()
    let process = try PTYShellProcess(
      workingDirectory: FileManager.default.temporaryDirectory.path,
      onOutput: { chunk in
        Task { await collector.append(chunk) }
      }
    )
    defer { process.stop() }

    try process.send("printf 'ASTER_PTY_READY\\n'; exit")

    for _ in 0..<50 {
      if await collector.text.contains("ASTER_PTY_READY") {
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }

    Issue.record("等待 PTY 输出超时，实际输出：\(await collector.text)")
  }

  @Test("shell 退出时会通知会话层", .timeLimit(.minutes(1)))
  func ptyReportsShellExit() async throws {
    let exitCollector = ExitCollector()
    let process = try PTYShellProcess(
      workingDirectory: FileManager.default.temporaryDirectory.path,
      onOutput: { _ in },
      onExit: { code in
        Task { await exitCollector.markExited(code: code) }
      }
    )
    defer { process.stop() }

    try process.send("exit")

    for _ in 0..<50 {
      if await exitCollector.exitCode != nil {
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }

    Issue.record("shell 已退出，但会话层未收到通知")
  }

  @Test("不同 shell 使用各自支持的交互参数")
  func shellSpecificLaunchArguments() {
    #expect(PTYShellProcess.launchArguments(forShell: "/bin/zsh") == ["/bin/zsh", "-l", "-i"])
    #expect(
      PTYShellProcess.launchArguments(forShell: "/bin/bash") == [
        "/bin/bash", "--login", "-i",
      ])
    #expect(
      PTYShellProcess.launchArguments(forShell: "/opt/homebrew/bin/fish") == [
        "/opt/homebrew/bin/fish", "--login", "--interactive",
      ])
    #expect(PTYShellProcess.launchArguments(forShell: "/bin/ksh") == ["/bin/ksh", "-l", "-i"])
  }

  @Test("shell 退出后子进程会被回收", .timeLimit(.minutes(1)))
  func exitedShellIsReaped() async throws {
    let exitCollector = ExitCollector()
    let process = try PTYShellProcess(
      workingDirectory: FileManager.default.temporaryDirectory.path,
      onOutput: { _ in },
      onExit: { code in Task { await exitCollector.markExited(code: code) } }
    )
    defer { process.stop() }
    let childPID = process.processIdentifier

    try process.send("exit")
    for _ in 0..<50 {
      if await exitCollector.exitCode != nil { break }
      try await Task.sleep(for: .milliseconds(20))
    }
    try await Task.sleep(for: .milliseconds(20))

    var status: Int32 = 0
    errno = 0
    let result = waitpid(childPID, &status, WNOHANG)
    #expect(result == -1)
    #expect(errno == ECHILD)
  }

  @Test("直接 shell 退出不会等待继承 PTY 的后台进程", .timeLimit(.minutes(1)))
  func directShellExitIsReportedIndependentlyFromPTYEOF() async throws {
    let exitCollector = ExitCollector()
    let process = try PTYShellProcess(
      workingDirectory: FileManager.default.temporaryDirectory.path,
      shell: "/bin/zsh",
      onOutput: { _ in },
      onExit: { code in Task { await exitCollector.markExited(code: code) } }
    )
    defer { process.stop() }

    // 后台进程继承 slave PTY，并在父 shell 退出后继续持有它。退出通知必须来自
    // 直接子进程状态，而不是等待 slave 端最终关闭产生 EOF。
    try process.send("sleep 3 &!; exit 7")

    for _ in 0..<50 {
      if await exitCollector.exitCode == 7 { return }
      try await Task.sleep(for: .milliseconds(20))
    }

    Issue.record(
      "直接 shell 已退出，但 1 秒内未收到退出码 7；实际：\(String(describing: await exitCollector.exitCode))"
    )
  }

  @Test("无法执行 shell 时返回独立的启动错误")
  func invalidShellReportsStartupError() {
    do {
      _ = try PTYShellProcess(
        workingDirectory: FileManager.default.temporaryDirectory.path,
        shell: "/definitely/missing/aster-shell",
        onOutput: { _ in }
      )
      Issue.record("无效 shell 没有抛出启动错误")
    } catch PTYShellError.shellLaunchFailed(let code) {
      #expect(code == ENOENT)
    } catch {
      Issue.record("无效 shell 返回了错误的失败类型：\(error)")
    }
  }

  @Test("无法进入工作目录时返回独立的启动错误")
  func invalidWorkingDirectoryReportsStartupError() {
    do {
      _ = try PTYShellProcess(
        workingDirectory: "/definitely/missing/aster-directory",
        shell: "/bin/zsh",
        onOutput: { _ in }
      )
      Issue.record("无效工作目录没有抛出启动错误")
    } catch PTYShellError.workingDirectoryFailed(let code) {
      #expect(code == ENOENT)
    } catch {
      Issue.record("无效工作目录返回了错误的失败类型：\(error)")
    }
  }

  @Test("成功启动后的 126 和 127 是普通 shell 退出码", arguments: [Int32(126), Int32(127)])
  func reservedExitCodesRemainNormalShellExitCodes(expectedCode: Int32) async throws {
    let exitCollector = ExitCollector()
    let process = try PTYShellProcess(
      workingDirectory: FileManager.default.temporaryDirectory.path,
      onOutput: { _ in },
      onExit: { code in Task { await exitCollector.markExited(code: code) } }
    )
    defer { process.stop() }

    try process.send("exit \(expectedCode)")
    for _ in 0..<60 {
      if await exitCollector.exitCode == expectedCode { return }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("shell 退出码 \(expectedCode) 没有原样上报")
  }

  @Test("shell 退出通知前会排空 PTY 末尾输出", .timeLimit(.minutes(1)))
  func exitNotificationFollowsPTYDrain() async throws {
    let collector = ExitSnapshotCollector()
    let process = try PTYShellProcess(
      workingDirectory: FileManager.default.temporaryDirectory.path,
      onOutput: { collector.append($0) },
      onExit: { _ in collector.markExited() }
    )
    defer { process.stop() }

    try process.send("yes x | head -c 50000; printf 'ASTER_TAIL\\n'; exit")
    for _ in 0..<100 {
      if let snapshot = collector.snapshot() {
        #expect(snapshot.contains("ASTER_TAIL"))
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("等待包含末尾输出的退出通知超时")
  }

  @Test("PTY 背压不会阻塞发送线程或 stop", .timeLimit(.minutes(1)))
  func largeInputDoesNotBlockCallerOrStop() async throws {
    let process = try PTYShellProcess(
      workingDirectory: FileManager.default.temporaryDirectory.path,
      onOutput: { _ in }
    )
    try process.send("sleep 5")
    try await Task.sleep(for: .milliseconds(50))

    let clock = ContinuousClock()
    let sendStart = clock.now
    try process.send(String(repeating: "x", count: 524_288))
    let sendDuration = sendStart.duration(to: clock.now)
    let stopStart = clock.now
    process.stop()
    let stopDuration = stopStart.duration(to: clock.now)

    #expect(sendDuration < .milliseconds(500))
    #expect(stopDuration < .milliseconds(500))
  }

  @Test("shell 执行 cd 后可以读取新的当前目录", .timeLimit(.minutes(1)))
  func currentWorkingDirectoryTracksShell() async throws {
    let process = try PTYShellProcess(
      workingDirectory: FileManager.default.homeDirectoryForCurrentUser.path,
      onOutput: { _ in }
    )
    defer { process.stop() }

    try process.send("cd /tmp")
    for _ in 0..<50 {
      if process.currentWorkingDirectory().map({ URL(fileURLWithPath: $0).lastPathComponent })
        == "tmp"
      {
        return
      }
      try await Task.sleep(for: .milliseconds(20))
    }

    Issue.record("cd /tmp 后仍报告目录：\(process.currentWorkingDirectory() ?? "nil")")
  }

  @Test("运行中的 PTY 可以同步窗口网格尺寸")
  func ptyAcceptsWindowResize() throws {
    let process = try PTYShellProcess(
      workingDirectory: FileManager.default.temporaryDirectory.path,
      onOutput: { _ in }
    )
    defer { process.stop() }

    try process.resize(columns: 96, rows: 32)
  }
}
