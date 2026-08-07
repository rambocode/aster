import AsterPTY
import Darwin
import Foundation

/// PTY 生命周期中可能公开给调用方的失败。
public enum PTYShellError: Error, LocalizedError, Sendable {
  case createFailed(code: Int32)
  case workingDirectoryFailed(code: Int32)
  case shellLaunchFailed(code: Int32)
  case notRunning
  case inputQueueFull
  case writeFailed(code: Int32)
  case resizeFailed(code: Int32)

  public var errorDescription: String? {
    switch self {
    case .createFailed(let code):
      "无法创建 PTY：\(String(cString: strerror(code)))"
    case .workingDirectoryFailed(let code):
      "无法进入会话工作目录：\(String(cString: strerror(code)))"
    case .shellLaunchFailed(let code):
      "无法执行已配置的 Shell：\(String(cString: strerror(code)))"
    case .notRunning:
      "PTY 会话未运行"
    case .inputQueueFull:
      "输入内容过大，请缩短后重试"
    case .writeFailed(let code):
      "无法写入 PTY：\(String(cString: strerror(code)))"
    case .resizeFailed(let code):
      "无法调整 PTY 尺寸：\(String(cString: strerror(code)))"
    }
  }
}

/// 一个最小、线程安全的 macOS PTY shell 进程边界。
///
/// 所有字节读取都发生在专用队列，输出通过 `@Sendable` 回调交给调用方；调用方
/// 决定如何切回 UI executor。`stop()` 具备幂等性，可以从错误恢复或清理路径重复调用。
public final class PTYShellProcess: @unchecked Sendable {
  public typealias OutputHandler = @Sendable (String) -> Void

  private let stateLock = NSLock()
  private let writeQueue = DispatchQueue(label: "io.local.aster-terminal.pty-write")
  private let onError: @Sendable (PTYShellError) -> Void
  private var masterFileDescriptor: Int32
  private var childProcessID: pid_t
  private var readSource: DispatchSourceRead?
  private var processSource: DispatchSourceProcess?
  private var pendingWriteBytes = 0
  private var ptyReachedEOF = false
  private var pendingExitCode: Int32?
  private var exitDrainWorkItem: DispatchWorkItem?

  private static let maximumPendingWriteBytes = 1_048_576
  private static let writeTimeout: TimeInterval = 2
  private static let exitDrainDeadline = DispatchTimeInterval.milliseconds(250)

  /// 仅用于诊断和生命周期测试；调用方不应直接向该 PID 发送信号。
  var processIdentifier: pid_t {
    stateLock.withLock { childProcessID }
  }

  public init(
    workingDirectory: String,
    shell: String = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh",
    onOutput: @escaping OutputHandler,
    onError: @escaping @Sendable (PTYShellError) -> Void = { _ in },
    onExit: @escaping @Sendable (Int32) -> Void = { _ in }
  ) throws {
    self.onError = onError
    var master: Int32 = -1
    var startupStage: Int32 = 0
    var startupError: Int32 = 0
    let arguments = Self.launchArguments(forShell: shell)
    var environment = ProcessInfo.processInfo.environment
    environment["TERM"] = "xterm-256color"
    environment["COLORTERM"] = "truecolor"
    environment["PROMPT"] = "%F{green}●%f %1~ %# "
    environment["RPROMPT"] = ""
    let environmentEntries = environment.map { "\($0.key)=\($0.value)" }
    let pid = Self.spawn(
      workingDirectory: workingDirectory,
      shell: shell,
      arguments: arguments,
      environment: environmentEntries,
      masterFileDescriptor: &master,
      startupStage: &startupStage,
      startupError: &startupError
    )

    guard pid >= 0 else {
      switch startupStage {
      case Int32(ASTER_STARTUP_STAGE_CHDIR):
        throw PTYShellError.workingDirectoryFailed(code: startupError)
      case Int32(ASTER_STARTUP_STAGE_EXEC):
        throw PTYShellError.shellLaunchFailed(code: startupError)
      default:
        throw PTYShellError.createFailed(code: errno)
      }
    }

    masterFileDescriptor = master
    childProcessID = pid
    observe(
      fileDescriptor: master,
      processIdentifier: pid,
      onOutput: onOutput,
      onExit: onExit
    )
  }

  deinit {
    stop()
  }

  /// 写入一条命令并补充换行，让交互式 shell 执行它。
  public func send(_ command: String) throws {
    let payload = Data((command + "\n").utf8)
    try enqueueWrite(payload)
  }

  /// 发送终端 Ctrl+C 控制字符，中断当前前台进程组。
  public func interrupt() throws {
    try enqueueWrite(Data([3]))
  }

  /// 返回 shell 进程当前工作目录。进程已结束或系统查询失败时返回 `nil`。
  public func currentWorkingDirectory() -> String? {
    stateLock.withLock {
      guard childProcessID > 0 else { return nil }
      var buffer = [CChar](repeating: 0, count: Int(PATH_MAX))
      let result = aster_process_working_directory(
        childProcessID,
        &buffer,
        buffer.count
      )
      guard result == 0 else { return nil }
      let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
      return String(decoding: buffer[..<end].map(UInt8.init(bitPattern:)), as: UTF8.self)
    }
  }

  /// 更新终端网格大小。内核会向前台进程组发送 SIGWINCH，让 TUI 与换行宽度同步。
  public func resize(columns: Int, rows: Int) throws {
    try stateLock.withLock {
      guard masterFileDescriptor >= 0 else { throw PTYShellError.notRunning }
      var size = winsize(
        ws_row: UInt16(clamping: max(rows, 2)),
        ws_col: UInt16(clamping: max(columns, 2)),
        ws_xpixel: 0,
        ws_ypixel: 0
      )
      guard ioctl(masterFileDescriptor, TIOCSWINSZ, &size) == 0 else {
        throw PTYShellError.resizeFailed(code: errno)
      }
    }
  }

  /// 终止子进程并关闭读源与文件描述符。重复调用不会产生额外副作用。
  public func stop() {
    let state = stateLock.withLock {
      () -> (DispatchSourceRead?, DispatchSourceProcess?, DispatchWorkItem?, pid_t, Int32) in
      let current = (
        readSource,
        processSource,
        exitDrainWorkItem,
        childProcessID,
        masterFileDescriptor
      )
      readSource = nil
      processSource = nil
      exitDrainWorkItem = nil
      pendingExitCode = nil
      childProcessID = -1
      masterFileDescriptor = -1
      return current
    }

    state.0?.cancel()
    state.1?.cancel()
    state.2?.cancel()
    let processIdentifier = state.3
    if processIdentifier > 0 {
      DispatchQueue.global(qos: .utility).async {
        Self.terminateAndReap(processIdentifier: processIdentifier)
      }
    } else if state.0 == nil, state.4 >= 0 {
      // 正常路径由 DispatchSource 的 cancel handler 关闭描述符；只有读源尚未
      // 建立的异常边界才需要在这里直接关闭。
      Darwin.close(state.4)
    }
  }

  private func observe(
    fileDescriptor: Int32,
    processIdentifier: pid_t,
    onOutput: @escaping OutputHandler,
    onExit: @escaping @Sendable (Int32) -> Void
  ) {
    let decoder = UTF8StreamDecoder()
    let source = DispatchSource.makeReadSource(
      fileDescriptor: fileDescriptor,
      queue: DispatchQueue.global(qos: .userInitiated)
    )
    source.setEventHandler { [weak self] in
      var buffer = [UInt8](repeating: 0, count: 16_384)
      let count = Darwin.read(fileDescriptor, &buffer, buffer.count)
      if count == -1, errno == EAGAIN || errno == EWOULDBLOCK {
        return
      }
      guard count > 0 else {
        self?.handlePTYEOF(readSource: source, onExit: onExit)
        return
      }
      let text = decoder.append(Data(buffer.prefix(count)))
      if !text.isEmpty {
        onOutput(text)
      }
    }
    source.setCancelHandler { [weak self] in
      self?.stateLock.withLock {
        if self?.masterFileDescriptor == fileDescriptor {
          self?.masterFileDescriptor = -1
          self?.readSource = nil
        }
      }
      Darwin.close(fileDescriptor)
    }
    let childSource = DispatchSource.makeProcessSource(
      identifier: processIdentifier,
      eventMask: .exit,
      queue: DispatchQueue.global(qos: .utility)
    )
    childSource.setEventHandler { [weak self] in
      var status: Int32 = 0
      let result = Self.waitForExit(processIdentifier: processIdentifier, status: &status)
      guard result == processIdentifier, let self else {
        childSource.cancel()
        return
      }

      let shouldNotify = self.stateLock.withLock {
        guard self.childProcessID == processIdentifier else { return false }
        self.childProcessID = -1
        self.processSource = nil
        let exitCode = Self.normalizedExitCode(from: status)
        if self.ptyReachedEOF {
          self.pendingExitCode = nil
          return true
        }
        self.pendingExitCode = exitCode
        return false
      }
      childSource.cancel()
      if shouldNotify {
        onExit(Self.normalizedExitCode(from: status))
      } else {
        let drainWork = DispatchWorkItem { [weak self] in
          self?.finishExitAfterDrainDeadline(readSource: source, onExit: onExit)
        }
        let shouldSchedule = self.stateLock.withLock {
          guard self.pendingExitCode != nil else { return false }
          self.exitDrainWorkItem?.cancel()
          self.exitDrainWorkItem = drainWork
          return true
        }
        if shouldSchedule {
          DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + Self.exitDrainDeadline,
            execute: drainWork
          )
        }
      }
    }
    stateLock.withLock {
      readSource = source
      processSource = childSource
    }
    source.resume()
    childSource.resume()
  }

  /// 输入只在主 actor 做容量校验，真正写入在串行队列执行。PTY 为非阻塞模式，
  /// 因此前台程序停止读取 stdin 时不会冻结界面；队列上限和超时提供明确背压。
  private func enqueueWrite(_ data: Data) throws {
    try stateLock.withLock {
      guard masterFileDescriptor >= 0 else { throw PTYShellError.notRunning }
      guard pendingWriteBytes + data.count <= Self.maximumPendingWriteBytes else {
        throw PTYShellError.inputQueueFull
      }
      pendingWriteBytes += data.count
    }
    writeQueue.async { [weak self] in self?.performWrite(data) }
  }

  private func performWrite(_ data: Data) {
    defer {
      stateLock.withLock { pendingWriteBytes -= data.count }
    }
    let deadline = Date().addingTimeInterval(Self.writeTimeout)
    data.withUnsafeBytes { bytes in
      guard let baseAddress = bytes.baseAddress else { return }
      var offset = 0
      while offset < bytes.count {
        var writeError: Int32 = 0
        let count = stateLock.withLock { () -> Int in
          guard masterFileDescriptor >= 0 else { return -2 }
          let result = Darwin.write(
            masterFileDescriptor,
            baseAddress.advanced(by: offset),
            bytes.count - offset
          )
          if result == -1 { writeError = errno }
          return result
        }
        if count > 0 {
          offset += count
        } else if count == -2 {
          return
        } else if count == -1, writeError == EINTR {
          continue
        } else if count == -1, writeError == EAGAIN || writeError == EWOULDBLOCK {
          guard Date() < deadline else {
            onError(.writeFailed(code: ETIMEDOUT))
            return
          }
          usleep(5_000)
        } else {
          onError(.writeFailed(code: writeError))
          return
        }
      }
    }
  }

  private func handlePTYEOF(
    readSource: DispatchSourceRead,
    onExit: @escaping @Sendable (Int32) -> Void
  ) {
    let exitCode = stateLock.withLock { () -> Int32? in
      ptyReachedEOF = true
      exitDrainWorkItem?.cancel()
      exitDrainWorkItem = nil
      defer { pendingExitCode = nil }
      return pendingExitCode
    }
    readSource.cancel()
    if let exitCode {
      onExit(exitCode)
    }
  }

  private func finishExitAfterDrainDeadline(
    readSource: DispatchSourceRead,
    onExit: @escaping @Sendable (Int32) -> Void
  ) {
    let exitCode = stateLock.withLock { () -> Int32? in
      guard let exitCode = pendingExitCode else { return nil }
      pendingExitCode = nil
      exitDrainWorkItem = nil
      if masterFileDescriptor >= 0 {
        masterFileDescriptor = -1
        self.readSource = nil
      }
      return exitCode
    }
    guard let exitCode else { return }
    readSource.cancel()
    onExit(exitCode)
  }

  /// 不同 shell 对登录交互模式的参数约定并不相同。Aster 保留用户的 shell 配置，
  /// 与从 Terminal.app 打开新的登录 shell 保持一致。
  static func launchArguments(forShell shell: String) -> [String] {
    switch URL(fileURLWithPath: shell).lastPathComponent {
    case "zsh":
      [shell, "-l", "-i"]
    case "bash":
      [shell, "--login", "-i"]
    case "fish":
      [shell, "--login", "--interactive"]
    default:
      [shell, "-l", "-i"]
    }
  }

  /// 所有 Swift 字符串与数组都在 fork 之前转换成稳定的 C 缓冲区。真正的子分支
  /// 位于 AsterPTY C 模块，只执行 chdir/execve/_exit 等 async-signal-safe 调用。
  private static func spawn(
    workingDirectory: String,
    shell: String,
    arguments: [String],
    environment: [String],
    masterFileDescriptor: inout Int32,
    startupStage: inout Int32,
    startupError: inout Int32
  ) -> pid_t {
    var cArguments = arguments.map { strdup($0) as UnsafeMutablePointer<CChar>? }
    var cEnvironment = environment.map { strdup($0) as UnsafeMutablePointer<CChar>? }
    cArguments.append(nil)
    cEnvironment.append(nil)
    defer {
      for pointer in cArguments.compactMap({ $0 }) { free(pointer) }
      for pointer in cEnvironment.compactMap({ $0 }) { free(pointer) }
    }

    return workingDirectory.withCString { directory in
      shell.withCString { executable in
        cArguments.withUnsafeMutableBufferPointer { argumentsBuffer in
          cEnvironment.withUnsafeMutableBufferPointer { environmentBuffer in
            aster_spawn_pty(
              directory,
              executable,
              argumentsBuffer.baseAddress,
              environmentBuffer.baseAddress,
              &masterFileDescriptor,
              &startupStage,
              &startupError,
              40,
              140
            )
          }
        }
      }
    }
  }

  /// 直接监听子进程退出，不依赖 PTY EOF；即使后台后代仍持有 slave 端，也能立即
  /// 更新会话状态并回收 shell。
  private static func waitForExit(processIdentifier: pid_t, status: inout Int32) -> pid_t {
    var result: pid_t
    repeat {
      result = waitpid(processIdentifier, &status, 0)
    } while result == -1 && errno == EINTR
    return result
  }

  /// 把 waitpid 原始状态规范化为 shell 常见退出码：正常退出使用 0...255，信号
  /// 终止使用 128 + signal，便于 UI 给出稳定、可理解的反馈。
  private static func normalizedExitCode(from status: Int32) -> Int32 {
    let terminatingSignal = status & 0x7F
    if terminatingSignal == 0 {
      return (status >> 8) & 0xFF
    }
    return 128 + terminatingSignal
  }

  /// 主动关闭时先温和发送 SIGHUP，并给 shell 最多 500ms 清理；仍未退出则升级为
  /// SIGKILL。回收发生在后台 utility 队列，不阻塞窗口关闭或主 actor。
  private static func terminateAndReap(processIdentifier: pid_t) {
    _ = Darwin.kill(processIdentifier, SIGHUP)
    var status: Int32 = 0

    for _ in 0..<50 {
      let result = waitpid(processIdentifier, &status, WNOHANG)
      if result == processIdentifier || (result == -1 && errno == ECHILD) {
        return
      }
      if result == -1 && errno != EINTR {
        return
      }
      usleep(10_000)
    }

    _ = Darwin.kill(processIdentifier, SIGKILL)
    while waitpid(processIdentifier, &status, 0) == -1, errno == EINTR {}
  }
}

extension NSLock {
  fileprivate func withLock<T>(_ operation: () throws -> T) rethrows -> T {
    lock()
    defer { unlock() }
    return try operation()
  }
}
