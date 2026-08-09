import Foundation

/// 每个终端 Pane 独占的异步输出消息总线。
///
/// PTY 读取线程只能调用 `enqueue(_:)`，绝不直接触碰 AppKit 或 SwiftTerm 网格。总线在
/// 主线程按有界批次交付字节，因而鼠标、键盘和其它窗口事件能穿插在连续输出之间。字节
/// 序列仍严格保持原顺序；当等待队列达到上限时，生产者暂停，最终让内核 PTY 形成背压，
/// 而不是以丢失输出或无限内存换取表面流畅。
final class TerminalOutputMessageBus: @unchecked Sendable {
  /// 与 SwiftTerm 的 PTY 单次读取上限一致。保留读取边界能避免把同一批 ANSI 更新拆成
  /// 多个可见中间帧；交付只发生在主 RunLoop 的空闲阶段，不再靠切碎字节换取响应性。
  static let defaultBatchByteLimit = 128 * 1_024
  /// 总线自身的硬上限必须小于无限制缓存；达到上限后读取线程等待主线程排空一部分。
  static let defaultPendingByteLimit = 4 * 1_024 * 1_024

  private let condition = NSCondition()
  private let batchByteLimit: Int
  private let pendingByteLimit: Int
  private let resumeByteLimit: Int
  private let interBatchDelay: DispatchTimeInterval
  private let consume: ([UInt8]) -> Void
  private let mainRunLoop: CFRunLoop
  private var deliveryObserver: CFRunLoopObserver?

  private var chunks: [[UInt8]] = []
  private var firstChunkOffset = 0
  private var pendingByteCount = 0
  private var deliveryScheduled = false
  private var deliveryReady = false
  private var deferUntilNextIdleCycle = false
  private var finishRequested = false
  private var completionHandlers: [() -> Void] = []

  init(
    batchByteLimit: Int = TerminalOutputMessageBus.defaultBatchByteLimit,
    pendingByteLimit: Int = TerminalOutputMessageBus.defaultPendingByteLimit,
    interBatchDelay: DispatchTimeInterval = .milliseconds(8),
    consume: @escaping ([UInt8]) -> Void
  ) {
    precondition(Thread.isMainThread, "TerminalOutputMessageBus 必须在主线程构造")
    precondition(batchByteLimit > 0)
    precondition(pendingByteLimit >= batchByteLimit)
    self.batchByteLimit = batchByteLimit
    self.pendingByteLimit = pendingByteLimit
    // 只在积压明显降低后才唤醒读取方，防止高频跨线程 wake-up 造成新的调度风暴。
    resumeByteLimit = pendingByteLimit / 2
    self.interBatchDelay = interBatchDelay
    self.consume = consume
    mainRunLoop = CFRunLoopGetMain()

    // 默认模式的 beforeWaiting 位于 AppKit 输入源、主队列任务和计时器之后。终端每轮
    // 最多消费一个有界批次；eventTracking 等嵌套交互循环不会解析终端输出，因此
    // Panel 仍走原生事件链，不订阅也不等待终端消息。
    let observer = CFRunLoopObserverCreateWithHandler(
      kCFAllocatorDefault,
      CFRunLoopActivity.beforeWaiting.rawValue,
      true,
      0
    ) { [weak self] _, _ in
      self?.deliverNextBatchIfReady()
    }
    deliveryObserver = observer
    CFRunLoopAddObserver(mainRunLoop, observer, .defaultMode)
  }

  deinit {
    if let deliveryObserver {
      CFRunLoopRemoveObserver(mainRunLoop, deliveryObserver, .defaultMode)
    }
  }

  /// 从 PTY 专用串行队列发布原始字节。此调用可能在队列已满时等待，但不会阻塞主线程。
  func enqueue(_ bytes: ArraySlice<UInt8>) {
    guard !bytes.isEmpty else { return }

    condition.lock()
    var startIndex = bytes.startIndex
    while startIndex != bytes.endIndex {
      while pendingByteCount >= pendingByteLimit {
        condition.wait()
      }

      // 一次 PTY 回调通常只有 128 KiB；即使底层实现或测试传入更大切片，也按剩余
      // 容量分段复制，保证总线持有的待消费字节永远不超过硬上限。
      let availableCapacity = pendingByteLimit - pendingByteCount
      let endIndex = bytes.index(
        startIndex,
        offsetBy: min(availableCapacity, bytes.distance(from: startIndex, to: bytes.endIndex))
      )
      let chunk = Array(bytes[startIndex..<endIndex])
      chunks.append(chunk)
      pendingByteCount += chunk.count
      startIndex = endIndex
      // 首批同样等待一个很短的合并窗口：DispatchIO 可能把一次读取分成多个 partial
      // 回调，这些字节应在同一显示帧交给 SwiftTerm，而不是逐片触发重绘。
      scheduleDeliveryLocked(after: .now() + interBatchDelay)
    }
    condition.unlock()
  }

  /// 请求结束当前输出流。进程退出通知会等到已经排队的输出都进入主线程后再交付，避免
  /// 最后一段终端文本被“进程已退出”的 UI 状态抢先覆盖。若底层 PTY 的尾部读取与退出
  /// 观察存在竞态，`enqueue(_:)` 仍接受那一小段迟到字节，以数据完整性优先于丢弃输出。
  func finish(afterDraining completion: @escaping () -> Void) {
    condition.lock()
    finishRequested = true
    completionHandlers.append(completion)
    if pendingByteCount == 0 {
      scheduleDeliveryLocked(after: .now())
    }
    condition.broadcast()
    condition.unlock()
  }

  private func scheduleDeliveryLocked(after deadline: DispatchTime) {
    guard !deliveryScheduled else { return }
    deliveryScheduled = true
    DispatchQueue.main.asyncAfter(deadline: deadline) { [weak self] in
      self?.markDeliveryReady()
    }
  }

  /// 主队列计时器只标记“可消费”，不解析字节。再等待一个完整 idle cycle，保证同一轮
  /// 已排队的 Panel/AppKit 任务全部先完成，然后由 beforeWaiting observer 交付输出。
  private func markDeliveryReady() {
    precondition(Thread.isMainThread)
    condition.lock()
    deliveryReady = true
    deferUntilNextIdleCycle = true
    condition.unlock()
    CFRunLoopWakeUp(mainRunLoop)
  }

  /// 只由主 RunLoop 的 beforeWaiting observer 调用。每轮最多提交一个批次；若仍有积压，
  /// 下一批重新经过合并窗口和 idle cycle，不会形成持续占用主队列的终端消息链。
  private func deliverNextBatchIfReady() {
    precondition(Thread.isMainThread)

    condition.lock()
    guard deliveryReady else {
      condition.unlock()
      return
    }
    if deferUntilNextIdleCycle {
      deferUntilNextIdleCycle = false
      condition.unlock()
      CFRunLoopWakeUp(mainRunLoop)
      return
    }

    let batch: [UInt8]
    var completions: [() -> Void] = []
    deliveryReady = false
    deliveryScheduled = false
    batch = takeBatchLocked()
    if pendingByteCount <= resumeByteLimit {
      condition.broadcast()
    }
    if pendingByteCount > 0 {
      scheduleDeliveryLocked(after: .now() + interBatchDelay)
    } else if finishRequested {
      completions = completionHandlers
      completionHandlers.removeAll()
    }
    condition.unlock()

    if !batch.isEmpty { consume(batch) }
    completions.forEach { $0() }
  }

  private func takeBatchLocked() -> [UInt8] {
    var remaining = batchByteLimit
    var result: [UInt8] = []
    result.reserveCapacity(batchByteLimit)

    while remaining > 0, !chunks.isEmpty {
      let chunk = chunks[0]
      let available = chunk.count - firstChunkOffset
      let count = min(available, remaining)
      result.append(contentsOf: chunk[firstChunkOffset..<(firstChunkOffset + count)])
      firstChunkOffset += count
      pendingByteCount -= count
      remaining -= count

      if firstChunkOffset == chunk.count {
        chunks.removeFirst()
        firstChunkOffset = 0
      }
    }
    return result
  }
}
