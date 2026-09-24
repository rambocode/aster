import AsterCore
import Darwin
import Foundation
import os

// 一个 broker 进程与它的控制通道（stdin/stdout 上的 JSON Lines，见 SshRuntime/PROTOCOL.md §4）。
// 只负责进程、管道与分帧：读在后台，按行回到主线程交给监管者；写在专用串行队列，不阻塞主线程。
// 通道本身不理解消息语义，也从不记录写入的内容——auth.answer 里带着秘密。

/// broker 控制通道。
@MainActor
final class SSHBrokerControlChannel {
  /// 单行上限。控制消息都很小（profiles.sync 最大），1 MiB 足够并防止异常输出撑爆内存。
  static let maximumLineBytes = 1 << 20

  private let process = Process()
  private let input = Pipe()
  private let output = Pipe()
  /// 写 stdin 的串行队列：保证命令按发送顺序到达，且 broker 读得慢时不卡主线程。
  private let writeQueue = DispatchQueue(label: "io.local.aster.ssh-broker.control-write")
  private var inputClosed = false
  /// 写 stdin 失败时的诊断回调（后台队列调用）。只带错误码，不带消息内容。
  private let onWriteFailure: @Sendable (String) -> Void

  /// broker 进程号；未启动时为 0。
  var processIdentifier: Int32 { process.processIdentifier }
  var isRunning: Bool { process.isRunning }

  /// 启动 broker 并开始读取控制通道。
  ///
  /// - Parameters:
  ///   - onLine: 每个完整行（不含换行）在主线程上按到达顺序回调一次。
  ///   - onFramingError: 单行超过上限时回调；之后的残余数据被丢弃。
  ///   - onExit: 进程退出时在主线程回调一次，参数是退出码或信号值。
  ///   - onWriteFailure: 写 stdin 失败（broker 已退出）时在后台队列回调，只带错误码。
  /// - Throws: 进程无法启动。
  init(
    executableURL: URL,
    arguments: [String],
    environment: [String: String],
    onLine: @escaping @MainActor (Data) -> Void,
    onFramingError: @escaping @MainActor (String) -> Void,
    onExit: @escaping @MainActor (Int32) -> Void,
    onWriteFailure: @escaping @Sendable (String) -> Void
  ) throws {
    self.onWriteFailure = onWriteFailure
    process.executableURL = executableURL
    process.arguments = arguments
    process.environment = environment
    process.standardInput = input
    process.standardOutput = output
    // stderr 继承 App：协议规定那里只有脱敏日志，开发构建里直接进控制台便于排障。

    // 写端关闭 SIGPIPE：broker 已退出时写入会得到 EPIPE 而不是把整个 App 杀掉。
    _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1)

    let framing = OSAllocatedUnfairLock(
      initialState: NDJSONFraming(maximumLineBytes: Self.maximumLineBytes))
    output.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      guard !data.isEmpty else {
        // EOF：摘掉读源，避免它在已关闭的管道上空转。
        handle.readabilityHandler = nil
        return
      }
      let result = framing.withLock { framing -> Result<[Data], NDJSONFraming.FramingError> in
        do { return .success(try framing.append(data)) } catch let error as NDJSONFraming.FramingError {
          return .failure(error)
        } catch {
          return .failure(.lineTooLarge(bytes: data.count))
        }
      }
      // 用主队列而不是 Task：主队列 FIFO，事件顺序与 broker 写出的顺序一致。
      DispatchQueue.main.async {
        MainActor.assumeIsolated {
          switch result {
          case .success(let lines): for line in lines { onLine(line) }
          case .failure(let error): onFramingError(String(describing: error))
          }
        }
      }
    }
    process.terminationHandler = { finished in
      let status = finished.terminationStatus
      DispatchQueue.main.async {
        MainActor.assumeIsolated { onExit(status) }
      }
    }
    do {
      try process.run()
    } catch {
      output.fileHandleForReading.readabilityHandler = nil
      throw error
    }
  }

  /// 发送一条控制命令（编码成一行 JSON 加换行）。
  ///
  /// 编码在调用线程完成，失败直接抛出；写入在串行队列里异步进行，写失败（broker 已退出）
  /// 交给 `onWriteFailure`，不带任何消息内容。
  func send(_ command: SSHBrokerCommand) throws {
    guard !inputClosed else { throw SSHBrokerError.channelClosed }
    var encoded = try command.encodedLine()
    encoded.append(0x0A)
    let line = encoded
    let handle = input.fileHandleForWriting
    let onWriteFailure = self.onWriteFailure
    writeQueue.async {
      do {
        try handle.write(contentsOf: line)
      } catch {
        onWriteFailure(String(describing: (error as NSError).code))
      }
    }
  }

  /// 关闭 stdin。broker 读到 EOF 即断开全部连接并退出（PROTOCOL §1）。
  ///
  /// 排在写队列之后执行，保证之前发出的 `shutdown` 先写完再关。
  func closeInput() {
    guard !inputClosed else { return }
    inputClosed = true
    let handle = input.fileHandleForWriting
    let onWriteFailure = self.onWriteFailure
    writeQueue.async {
      do { try handle.close() } catch {
        onWriteFailure(String(describing: (error as NSError).code))
      }
    }
  }

  /// 强制结束 broker（SIGTERM）。只用于 ready 超时等异常路径。
  func terminate() {
    guard process.isRunning else { return }
    process.terminate()
  }
}
