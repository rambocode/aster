import Foundation

/// 流式 SSH 执行：stdin 从本地文件读、stdout 直接落盘，全程不把整份数据放进内存。
///
/// `RemoteSSHProcessRunner` 把两路输出都收进内存，适合控制命令；远端文件的上传与
/// 下载体量可达数百 MiB，必须走本文件这条流式通道，并且带三重保护：字节上限、
/// 超时、失败时删除半截落盘文件（半截文件比没有文件更危险，用户会当成完整副本）。

/// 流式 SSH 执行接口。测试注入替身，生产用 `RemoteSSHStreamRunner`。
public protocol RemoteSSHStreaming: Sendable {
  /// 执行一次 `ssh`。
  ///
  /// - Parameters:
  ///   - arguments: 完整 argv（不含可执行文件本身）。
  ///   - stdinFile: 作为子进程标准输入的本地文件；nil 表示 `/dev/null`。
  ///   - stdoutFile: 标准输出落盘目标；nil 表示只在内存里保留有界输出。
  ///   - maximumBytes: 标准输出字节上限，超出立即终止并按失败处理。
  ///   - timeout: 整体超时秒数。
  /// - Returns: 退出码与两路输出；落盘模式下 `standardOutput` 为空串。
  func stream(
    arguments: [String],
    stdinFile: URL?,
    stdoutFile: URL?,
    maximumBytes: Int,
    timeout: TimeInterval
  ) throws -> RemoteSSHResult
}

/// 真实流式执行器。可执行文件路径可注入，便于测试用 `/bin/cat` 之类的替身验证上限与清理。
public struct RemoteSSHStreamRunner: RemoteSSHStreaming {
  /// 被执行的二进制。默认固定 `/usr/bin/ssh`，不从 PATH 搜索，避免被环境劫持。
  public var executablePath: String

  public init(executablePath: String = RemoteSSHInvocation.executablePath) {
    self.executablePath = executablePath
  }

  public func stream(
    arguments: [String],
    stdinFile: URL?,
    stdoutFile: URL?,
    maximumBytes: Int,
    timeout: TimeInterval
  ) throws -> RemoteSSHResult {
    guard FileManager.default.isExecutableFile(atPath: executablePath) else {
      throw RemoteSSHError(kind: .transportFailure, target: "", detail: "缺少 \(executablePath)")
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executablePath)
    process.arguments = arguments
    // 与 RemoteSSHProcessRunner 保持一致：固定工具路径与 locale 让 stderr 关键字可分类，
    // 同时保留 HOME/SSH_AUTH_SOCK 以便复用用户的 known_hosts、密钥与 agent。
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["LC_ALL"] = "C"
    process.environment = environment

    let input: FileHandle
    if let stdinFile {
      guard let handle = FileHandle(forReadingAtPath: stdinFile.path) else {
        throw RemoteSSHError(kind: .transportFailure, target: "", detail: "本地文件不可读")
      }
      input = handle
    } else {
      input = FileHandle.nullDevice
    }
    defer { if stdinFile != nil { try? input.close() } }
    process.standardInput = input

    let sink = try RemoteSSHStreamSink(destination: stdoutFile, maximumBytes: maximumBytes)
    let out = Pipe()
    let err = Pipe()
    process.standardOutput = out
    process.standardError = err

    do { try process.run() } catch {
      sink.discard()
      throw RemoteSSHError(kind: .transportFailure, target: "", detail: "无法启动 \(executablePath)")
    }

    out.fileHandleForReading.readabilityHandler = { sink.appendOutput($0.availableData) }
    err.fileHandleForReading.readabilityHandler = { sink.appendDiagnostics($0.availableData) }

    // 轮询而不是 waitUntilExit：既要在超时后主动终止，也要在上限触发时立刻收手，
    // 不能等到远端把整份数据传完。
    let deadline = Date().addingTimeInterval(timeout)
    var overflowed = false
    while process.isRunning {
      if sink.didOverflow {
        overflowed = true
        break
      }
      if Date() >= deadline { break }
      usleep(20_000)
    }

    if process.isRunning || overflowed {
      let timedOut = !overflowed
      process.terminate()
      let killDeadline = Date().addingTimeInterval(2)
      while process.isRunning && Date() < killDeadline { usleep(20_000) }
      out.fileHandleForReading.readabilityHandler = nil
      err.fileHandleForReading.readabilityHandler = nil
      sink.discard()
      throw RemoteSSHError(
        kind: timedOut ? .timeout : .transportFailure,
        target: "",
        detail: timedOut ? "ssh 超时" : "输出超过 \(maximumBytes) 字节上限"
      )
    }

    process.waitUntilExit()
    sink.appendOutput(out.fileHandleForReading.availableData)
    sink.appendDiagnostics(err.fileHandleForReading.availableData)
    out.fileHandleForReading.readabilityHandler = nil
    err.fileHandleForReading.readabilityHandler = nil

    // 收尾阶段仍可能越界（最后一次 availableData 把计数推过上限）。
    if sink.didOverflow {
      sink.discard()
      throw RemoteSSHError(
        kind: .transportFailure, target: "", detail: "输出超过 \(maximumBytes) 字节上限")
    }
    if let failure = sink.writeFailure {
      sink.discard()
      throw RemoteSSHError(kind: .transportFailure, target: "", detail: failure)
    }
    let diagnostics = sink.diagnosticsText
    guard process.terminationStatus == 0 else {
      sink.discard()
      throw RemoteSSHError(
        kind: RemoteSSHDiagnostics.classify(
          standardError: diagnostics, exitStatus: process.terminationStatus),
        target: "",
        detail: RemoteSSHDiagnostics.redact(diagnostics),
        exitStatus: process.terminationStatus
      )
    }
    sink.finish()
    return RemoteSSHResult(
      exitStatus: process.terminationStatus,
      standardOutput: sink.outputText,
      standardError: diagnostics
    )
  }
}

/// stdout/stderr 落地缓冲。readability handler 在任意队列回调，所以自带锁。
///
/// 失败语义集中在这里：一旦越界或写盘失败就立即停止写入，`discard()` 负责删掉半截
/// 文件，避免调用方拿到一个看起来正常的残缺副本。
private final class RemoteSSHStreamSink: @unchecked Sendable {
  private let lock = NSLock()
  private let destination: URL?
  private let maximumBytes: Int
  private var handle: FileHandle?
  private var writtenBytes = 0
  private var memoryOutput = Data()
  private var diagnostics = Data()
  private var overflowed = false
  private var failure: String?
  private var finished = false

  init(destination: URL?, maximumBytes: Int) throws {
    self.destination = destination
    self.maximumBytes = max(maximumBytes, 0)
    guard let destination else { return }
    let manager = FileManager.default
    try manager.createDirectory(
      at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    if manager.fileExists(atPath: destination.path) {
      try manager.removeItem(at: destination)
    }
    guard manager.createFile(atPath: destination.path, contents: nil, attributes: [.posixPermissions: 0o600]),
      let handle = FileHandle(forWritingAtPath: destination.path)
    else {
      throw RemoteSSHError(kind: .transportFailure, target: "", detail: "无法创建本地文件")
    }
    self.handle = handle
  }

  func appendOutput(_ chunk: Data) {
    guard !chunk.isEmpty else { return }
    lock.lock()
    defer { lock.unlock() }
    guard !overflowed, failure == nil else { return }
    if writtenBytes + chunk.count > maximumBytes {
      overflowed = true
      return
    }
    writtenBytes += chunk.count
    guard let handle else {
      memoryOutput.append(chunk)
      return
    }
    do {
      try handle.write(contentsOf: chunk)
    } catch {
      failure = "写入本地文件失败"
    }
  }

  func appendDiagnostics(_ chunk: Data) {
    guard !chunk.isEmpty else { return }
    lock.lock()
    // 诊断只保留有界前缀：分类不需要全文，也避免异常远端输出撑爆内存。
    if diagnostics.count < 8192 { diagnostics.append(chunk.prefix(8192 - diagnostics.count)) }
    lock.unlock()
  }

  var didOverflow: Bool {
    lock.lock()
    defer { lock.unlock() }
    return overflowed
  }

  var writeFailure: String? {
    lock.lock()
    defer { lock.unlock() }
    return failure
  }

  var outputText: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: memoryOutput, as: UTF8.self)
  }

  var diagnosticsText: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: diagnostics, as: UTF8.self)
  }

  /// 正常收尾：关闭文件句柄，保留落盘内容。
  func finish() {
    lock.lock()
    defer { lock.unlock() }
    guard !finished else { return }
    finished = true
    try? handle?.close()
    handle = nil
  }

  /// 失败收尾：关闭句柄并删除半截文件。
  func discard() {
    lock.lock()
    defer { lock.unlock() }
    finished = true
    try? handle?.close()
    handle = nil
    memoryOutput = Data()
    guard let destination else { return }
    try? FileManager.default.removeItem(at: destination)
  }
}
