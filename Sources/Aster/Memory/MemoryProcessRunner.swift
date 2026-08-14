import Foundation

/// 记录层专用的有界子进程执行器。
///
/// 语义与 `WorkspaceInspectionService.run` 一致（绝对路径、超时、输出上限、可取消、
/// `terminationHandler` + 信号量而非 `waitUntilExit`），但刻意独立实现：
/// 记录层可以在任意后台 actor 上调用，不应与工作区检查面板共享私有状态或取消域。
///
/// 主线程禁止调用本类型的任何方法——`DispatchSemaphore.wait` 会阻塞调用线程，
/// 在主线程上等同于 `waitUntilExit`（engineering-pitfalls：runloop 泵与阻塞等待）。
enum MemoryProcessRunner {
  /// 执行一条只读命令并返回有界标准输出。失败、超时、取消一律返回 nil，
  /// 调用方按「信息缺失」处理，绝不把错误抛给终端路径。
  static func run(
    executable: String,
    arguments: [String],
    timeout: TimeInterval = 2,
    maximumBytes: Int = 64 * 1_024
  ) -> String? {
    /// 读端缓冲：`readabilityHandler` 在专用队列上回调，必须加锁与主体隔离。
    final class OutputBox: @unchecked Sendable {
      let lock = NSLock()
      var data = Data()
    }

    guard FileManager.default.isExecutableFile(atPath: executable), maximumBytes > 0 else {
      return nil
    }
    guard !isCancelled else { return nil }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    // 固定最小环境：不继承用户 shell 的 GIT_* 变量，避免探测结果随会话漂移。
    process.environment = [
      "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
      "LC_ALL": "C",
      "GIT_OPTIONAL_LOCKS": "0",
    ]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let output = OutputBox()
    let finished = DispatchSemaphore(value: 0)
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      output.lock.lock()
      let remaining = maximumBytes - output.data.count
      if remaining > 0 { output.data.append(chunk.prefix(remaining)) }
      let full = output.data.count >= maximumBytes
      output.lock.unlock()
      if full, process.isRunning { process.terminate() }
    }
    process.terminationHandler = { _ in finished.signal() }
    do {
      try process.run()
    } catch {
      pipe.fileHandleForReading.readabilityHandler = nil
      return nil
    }

    // `DispatchSemaphore.wait` 不响应 Swift Task 取消，短周期轮询同时观察 deadline 与
    // 取消标记；两者共用同一条终止流程，保证不留下超时后仍在跑的 git 子进程。
    let deadline = Date().addingTimeInterval(max(0.1, timeout))
    var aborted = false
    while finished.wait(timeout: .now() + 0.025) == .timedOut {
      if isCancelled || Date() >= deadline {
        aborted = true
        break
      }
    }
    if aborted {
      process.terminate()
      if finished.wait(timeout: .now() + 0.25) == .timedOut, process.processIdentifier > 0 {
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        _ = finished.wait(timeout: .now() + 0.25)
      }
    }
    pipe.fileHandleForReading.readabilityHandler = nil
    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
    output.lock.lock()
    let remaining = maximumBytes - output.data.count
    if remaining > 0 { output.data.append(tail.prefix(remaining)) }
    let data = output.data
    output.lock.unlock()
    guard !aborted, process.terminationStatus == 0 else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static var isCancelled: Bool {
    withUnsafeCurrentTask { $0?.isCancelled == true }
  }
}
