import AsterCore
import Foundation

/// 单条 socket 连接：DispatchSourceRead 读 + NDJSON 分帧 + 串行写队列。所有 fd 操作都在
/// server 的 ioQueue 上；dispatcher 在 MainActor 产出响应后经 `send` 回到 ioQueue 写出。
final class AsterControlConnection: @unchecked Sendable {
  let id = UUID()
  private let fd: Int32
  private let ioQueue: DispatchQueue
  private var framing: NDJSONFraming
  private var readSource: DispatchSourceRead?
  private var closed = false
  /// 正在处理的请求任务（含等待类）；连接关闭时全部取消，避免主线程残留等待。
  private var tasks: [UUID: Task<Void, Never>] = [:]
  private let onRequest: @Sendable (AsterControlRequest, AsterControlConnection) -> Void
  private let onClose: @Sendable (AsterControlConnection) -> Void
  /// MainActor 侧的等待计数（AsterControlClient）；只在主线程读写。
  private var _pendingWaits = 0

  init(
    fd: Int32, ioQueue: DispatchQueue,
    onRequest: @escaping @Sendable (AsterControlRequest, AsterControlConnection) -> Void,
    onClose: @escaping @Sendable (AsterControlConnection) -> Void
  ) {
    self.fd = fd
    self.ioQueue = ioQueue
    self.framing = NDJSONFraming()
    self.onRequest = onRequest
    self.onClose = onClose
  }

  /// 开始读取；必须在 ioQueue 上调用。
  func start() {
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: ioQueue)
    source.setEventHandler { [weak self] in self?.readAvailable() }
    source.setCancelHandler { [fd] in _ = Darwin.close(fd) }
    readSource = source
    source.resume()
  }

  private func readAvailable() {
    var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
    let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
    if count <= 0 {
      if count < 0, errno == EAGAIN || errno == EINTR { return }
      close()
      return
    }
    let lines: [Data]
    do {
      lines = try framing.append(Data(buffer[0..<count]))
    } catch {
      // 超限：回一条 request_too_large 再断开，客户端能看到原因。
      writeLine(
        AsterControlResponse(
          id: nil, error: AsterControlError(code: .requestTooLarge, message: "单行请求超过 \(AsterControlProtocol.maximumRequestBytes) 字节")))
      close()
      return
    }
    for line in lines {
      do {
        let request = try JSONDecoder().decode(AsterControlRequest.self, from: line)
        onRequest(request, self)
      } catch {
        // id 尽量从原始 JSON 里捞出来，让客户端能对上号。
        let id = (try? JSONDecoder().decode(JSONValue.self, from: line))?["id"]
        let code: AsterControlErrorCode = id == nil && (try? JSONDecoder().decode(JSONValue.self, from: line)) == nil ? .parseError : .invalidRequest
        writeLine(AsterControlResponse(id: id, error: AsterControlError(code: code, message: "请求无法解析: \(error)")))
      }
    }
  }

  /// 登记一个处理任务；完成后自动注销。
  func track(_ make: @escaping @Sendable () async -> Void) {
    let taskID = UUID()
    let task = Task { [weak self] in
      await make()
      self?.ioQueue.async { self?.tasks[taskID] = nil }
    }
    ioQueue.async { [weak self] in
      guard let self, !self.closed else {
        task.cancel()
        return
      }
      self.tasks[taskID] = task
    }
  }

  /// 线程安全的写：切到 ioQueue 串行写出；EPIPE 等错误直接关闭连接。
  func send(_ response: AsterControlResponse) {
    ioQueue.async { [weak self] in self?.writeLine(response) }
  }

  func send(_ event: AsterControlEvent) {
    ioQueue.async { [weak self] in self?.writeLine(event) }
  }

  /// 待写出的数据上限：慢客户端积压超过它直接断开，而不是让 ioQueue 陪它等。
  static let maximumPendingWriteBytes = 4 * 1_024 * 1_024
  private var pendingWrites = Data()
  private var writeSource: DispatchSourceWrite?

  /// 编码成一行并尽量立即写出；内核缓冲满（EAGAIN）时把余量放进 pendingWrites，由
  /// DispatchSourceWrite 在可写时续写。任何一步都不阻塞 ioQueue。
  private func writeLine<T: Encodable>(_ value: T) {
    guard !closed, let data = try? JSONEncoder().encode(value) else { return }
    pendingWrites.append(NDJSONFraming.frame(data))
    flushPendingWrites()
  }

  private func flushPendingWrites() {
    while !pendingWrites.isEmpty {
      let written = pendingWrites.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
      if written > 0 {
        pendingWrites.removeFirst(written)
        continue
      }
      if written < 0, errno == EINTR { continue }
      if written < 0, errno == EAGAIN {
        guard pendingWrites.count <= Self.maximumPendingWriteBytes else {
          close()
          return
        }
        armWriteSource()
        return
      }
      close()
      return
    }
    // 全部写完：停掉写源，避免空转唤醒。
    writeSource?.cancel()
    writeSource = nil
  }

  private func armWriteSource() {
    guard writeSource == nil else { return }
    let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: ioQueue)
    source.setEventHandler { [weak self] in self?.flushPendingWrites() }
    writeSource = source
    source.resume()
  }

  /// 测试用：当前积压字节数。
  var pendingWriteBytes: Int { ioQueue.sync { pendingWrites.count } }

  /// 关闭连接：取消读源（cancel handler 负责 close(fd)）、取消任务、通知 server。
  func close() {
    guard !closed else { return }
    closed = true
    for task in tasks.values { task.cancel() }
    tasks.removeAll()
    writeSource?.cancel()
    writeSource = nil
    readSource?.cancel()
    readSource = nil
    onClose(self)
  }
}

/// dispatcher 侧接口：事件推送走 ioQueue，等待计数只在主线程使用。
extension AsterControlConnection: AsterControlClient {
  var clientID: UUID { id }

  var pendingWaits: Int {
    get { _pendingWaits }
    set { _pendingWaits = newValue }
  }

  func sendEvent(_ event: AsterControlEvent) {
    send(event)
  }
}
