import Foundation

/// 安装事务的真实 SSH 执行器。
///
/// 上传用 `ssh ... 'cat > <staging>'` 而不是 scp：staging 路径由客户端计算，用
/// stdin 管道可以保证只写这一个绝对路径，也不依赖远端存在 scp/sftp 子系统。
/// 传输是否完整由远端自己复核摘要与大小决定，不以 exit 0 作为完整性证据。
public struct RemoteSSHInstallExecutor: RemoteInstallExecuting {
  public var transport: RemoteSessionTransport
  public var runner: any RemoteSSHRunning
  /// 单条远端命令的超时。
  public var commandTimeout: TimeInterval
  /// 上传超时。大产物需要更长的窗口，所以与命令超时分开。
  public var uploadTimeout: TimeInterval

  public init(
    transport: RemoteSessionTransport,
    runner: any RemoteSSHRunning = RemoteSSHProcessRunner(),
    commandTimeout: TimeInterval = 30,
    uploadTimeout: TimeInterval = 300
  ) {
    self.transport = transport
    self.runner = runner
    self.commandTimeout = commandTimeout
    self.uploadTimeout = uploadTimeout
  }

  public func runRemote(_ argv: [String]) throws -> RemoteSSHResult {
    try runner.run(
      arguments: transport.sshArguments(remoteCommand: argv), timeout: commandTimeout)
  }

  /// 把本地文件写入远端绝对路径。
  ///
  /// `umask 077` 保证临时文件不对组/其他用户开放；写入失败（例如空间不足）由远端
  /// Shell 的非零退出码与 stderr 反映，调用方据此归类。
  public func upload(localPath: String, remotePath: String) throws {
    guard let input = FileHandle(forReadingAtPath: localPath) else {
      throw RemoteInstallError.uploadFailed("本地产物不可读")
    }
    defer { try? input.close() }

    let remoteCommand = [
      "/bin/sh", "-c",
      "umask 077; cat > \(RemoteSSHInvocation.quote(remotePath))",
    ]
    let process = Process()
    process.executableURL = URL(fileURLWithPath: RemoteSSHInvocation.executablePath)
    process.arguments = transport.sshArguments(remoteCommand: remoteCommand)
    var environment = ProcessInfo.processInfo.environment
    environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
    environment["LC_ALL"] = "C"
    process.environment = environment
    process.standardInput = input
    let err = Pipe()
    process.standardOutput = FileHandle.nullDevice
    process.standardError = err

    do { try process.run() } catch {
      throw RemoteInstallError.uploadFailed("无法启动 ssh")
    }
    // stderr 必须并行排空：上传期间管道写满会让 ssh 阻塞，表现成假死的“上传中断”。
    let buffer = RemoteUploadDiagnostics()
    err.fileHandleForReading.readabilityHandler = { buffer.append($0.availableData) }
    let deadline = Date().addingTimeInterval(uploadTimeout)
    while process.isRunning && Date() < deadline { usleep(50_000) }
    if process.isRunning {
      process.terminate()
      let killDeadline = Date().addingTimeInterval(2)
      while process.isRunning && Date() < killDeadline { usleep(20_000) }
      err.fileHandleForReading.readabilityHandler = nil
      throw RemoteInstallError.uploadFailed("上传超时")
    }
    process.waitUntilExit()
    buffer.append(err.fileHandleForReading.availableData)
    err.fileHandleForReading.readabilityHandler = nil

    let diagnostics = buffer.text
    guard process.terminationStatus == 0 else {
      if diagnostics.lowercased().contains("no space left on device") {
        throw RemoteInstallError.insufficientSpace
      }
      let kind = RemoteSSHDiagnostics.classify(
        standardError: diagnostics, exitStatus: process.terminationStatus)
      throw RemoteInstallError.uploadFailed(
        "ssh \(kind.rawValue) (\(process.terminationStatus))")
    }
  }
}

/// 上传期间的 stderr 缓冲；readability handler 在任意队列回调，必须自带锁。
private final class RemoteUploadDiagnostics: @unchecked Sendable {
  private let lock = NSLock()
  private var data = Data()

  func append(_ chunk: Data) {
    guard !chunk.isEmpty else { return }
    lock.lock()
    // 只保留有界前缀：诊断不需要全文，也避免异常远端输出撑爆内存。
    if data.count < 8192 { data.append(chunk.prefix(8192 - data.count)) }
    lock.unlock()
  }

  var text: String {
    lock.lock()
    defer { lock.unlock() }
    return String(decoding: data, as: UTF8.self)
  }
}
