import AsterCore
import Darwin
import Foundation

/// 把用户已经提交的 `ssh` argv 解析为 OpenSSH 最终连接端点。
///
/// 解析在后台运行并设 1 秒硬超时；主线程只接收结构化结果。命令通过固定的
/// `/usr/bin/ssh -G` 与参数数组执行，不经过 Shell，因此目标、用户名和 `-F/-o` 参数
/// 不会形成二次命令解释。失败时回退到命令中可见的 host，侧栏仍能建立远端分组。
enum SSHHostResolutionService {
  static func resolve(_ invocation: SSHCommandInvocation) async -> SSHResolvedEndpoint? {
    let worker = Task.detached(priority: .utility) { () -> SSHResolvedEndpoint? in
      if let output = runConfiguration(arguments: invocation.configurationArguments),
        let endpoint = SSHResolvedEndpoint(configurationOutput: output)
      {
        return endpoint
      }
      return SSHResolvedEndpoint(
        hostName: invocation.fallbackHostName,
        user: invocation.explicitUser
      )
    }
    return await withTaskCancellationHandler(
      operation: { await worker.value },
      onCancel: { worker.cancel() }
    )
  }

  /// 并行排空 stdout，避免 OpenSSH 输出填满 pipe；超时/取消先 TERM，再以 KILL 保底。
  /// 输出和等待均有界，错误文本直接丢弃，防止本地配置内容进入日志或 UI。
  private static func runConfiguration(arguments: [String]) -> String? {
    final class OutputBox: @unchecked Sendable {
      let lock = NSLock()
      var data = Data()
      var exceededLimit = false
    }

    guard !isCancelled, FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh") else {
      return nil
    }
    let maximumBytes = 128 * 1_024
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    process.arguments = ["-G"] + arguments
    // `ssh -G` 需要 HOME/USER 解析用户配置；保留当前应用环境，但固定工具搜索路径和
    // locale，让输出键稳定且不依赖 GUI 进程的精简 PATH。
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["LC_ALL"] = "C"
    process.environment = environment

    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let output = OutputBox()
    let finished = DispatchSemaphore(value: 0)
    pipe.fileHandleForReading.readabilityHandler = { handle in
      let chunk = handle.availableData
      guard !chunk.isEmpty else { return }
      output.lock.lock()
      if output.data.count + chunk.count > maximumBytes { output.exceededLimit = true }
      if output.data.count < maximumBytes {
        output.data.append(chunk.prefix(maximumBytes - output.data.count))
      }
      let exceededLimit = output.exceededLimit
      output.lock.unlock()
      if exceededLimit, process.isRunning { process.terminate() }
    }
    process.terminationHandler = { _ in finished.signal() }

    do {
      try process.run()
    } catch {
      pipe.fileHandleForReading.readabilityHandler = nil
      return nil
    }

    let deadline = Date().addingTimeInterval(1)
    var aborted = false
    while finished.wait(timeout: .now() + 0.025) == .timedOut {
      if isCancelled || Date() >= deadline {
        aborted = true
        break
      }
    }
    if aborted {
      process.terminate()
      if finished.wait(timeout: .now() + 0.2) == .timedOut, process.processIdentifier > 0 {
        _ = Darwin.kill(process.processIdentifier, SIGKILL)
        _ = finished.wait(timeout: .now() + 0.2)
      }
    }

    pipe.fileHandleForReading.readabilityHandler = nil
    let tail = pipe.fileHandleForReading.readDataToEndOfFile()
    output.lock.lock()
    let remaining = maximumBytes - output.data.count
    if remaining > 0 { output.data.append(tail.prefix(remaining)) }
    let data = output.data
    let exceededLimit = output.exceededLimit
    output.lock.unlock()

    guard !aborted, !exceededLimit, process.terminationReason == .exit,
      process.terminationStatus == 0
    else { return nil }
    return String(data: data, encoding: .utf8)
  }

  private static var isCancelled: Bool {
    withUnsafeCurrentTask { $0?.isCancelled == true }
  }
}
