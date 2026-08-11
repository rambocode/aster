import Foundation

/// 每个终端 Pane 独占的异步输出消息总线。
///
/// PTY 读取线程只能调用 `enqueue(_:)`，绝不直接触碰 AppKit 或 SwiftTerm 网格。总线在
/// 主线程按有界批次交付字节，因而鼠标、键盘和其它窗口事件能穿插在连续输出之间。字节
/// 序列仍严格保持原顺序；当等待队列达到上限时，生产者暂停，最终让内核 PTY 形成背压，
/// 而不是以丢失输出或无限内存换取表面流畅。
final class TerminalOutputMessageBus: @unchecked Sendable {
  /// Ghostty 的 macOS PTY pipeline 以 64 KiB 作为 gather/parse 交接上限：足以摊薄
  /// syscall 与 parser 固定成本，又能限制一次主线程 VT 解析占用。SwiftTerm 会把同一
  /// display frame 内的多次 feed 合并成一次 redraw，所以这里无需用 128 KiB 单次解析
  /// 来避免中间帧。
  static let defaultBatchByteLimit = 64 * 1_024
  /// 总线自身的硬上限必须小于无限制缓存；达到上限后读取线程等待主线程排空一部分。
  static let defaultPendingByteLimit = 4 * 1_024 * 1_024
  /// macOS PTY 在饱和写入时通常按约 1 KiB 交付。低于该值视为交互输出，立即交给下一
  /// 个 RunLoop idle；达到该值才使用很短的合并窗口吸收连续 bulk 片段。
  static let defaultBulkByteThreshold = 1_024

  private let condition = NSCondition()
  private let batchByteLimit: Int
  private let pendingByteLimit: Int
  private let resumeByteLimit: Int
  private let bulkByteThreshold: Int
  private let bulkCoalescingDelay: DispatchTimeInterval
  private let consume: ([UInt8]) -> Void
  private let mainRunLoop: CFRunLoop
  private var deliveryObserver: CFRunLoopObserver?

  private var chunks: [[UInt8]] = []
  private var firstChunkIndex = 0
  private var firstChunkOffset = 0
  private var pendingByteCount = 0
  private var deliveryScheduled = false
  private var deliveryReady = false
  private var deferUntilNextIdleCycle = false
  private var finishRequested = false
  private var completionHandlers: [() -> Void] = []
  private var enqueuedByteCount: UInt64 = 0
  private var deliveredByteCount: UInt64 = 0
  private var barriers: [(afterByteCount: UInt64, completion: @MainActor () -> Void)] = []

  init(
    batchByteLimit: Int = TerminalOutputMessageBus.defaultBatchByteLimit,
    pendingByteLimit: Int = TerminalOutputMessageBus.defaultPendingByteLimit,
    bulkByteThreshold: Int = TerminalOutputMessageBus.defaultBulkByteThreshold,
    bulkCoalescingDelay: DispatchTimeInterval = .milliseconds(3),
    consume: @escaping ([UInt8]) -> Void
  ) {
    precondition(Thread.isMainThread, "TerminalOutputMessageBus 必须在主线程构造")
    precondition(batchByteLimit > 0)
    precondition(pendingByteLimit >= batchByteLimit)
    precondition(bulkByteThreshold > 0 && bulkByteThreshold <= batchByteLimit)
    self.batchByteLimit = batchByteLimit
    self.pendingByteLimit = pendingByteLimit
    // 只在积压明显降低后才唤醒读取方，防止高频跨线程 wake-up 造成新的调度风暴。
    resumeByteLimit = pendingByteLimit / 2
    self.bulkByteThreshold = bulkByteThreshold
    self.bulkCoalescingDelay = bulkCoalescingDelay
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
      enqueuedByteCount &+= UInt64(chunk.count)
      startIndex = endIndex
      // 交互式短输出不增加固定延迟；饱和流才用 3 ms 合并窗口吸收 DispatchIO 的相邻
      // partial 回调。这个窗口仍远低于一帧，并与 Ghostty 的 gather budget 一致。
      let delay: DispatchTimeInterval = pendingByteCount < bulkByteThreshold
        ? .nanoseconds(0) : bulkCoalescingDelay
      scheduleDeliveryLocked(after: .now() + delay)
    }
    condition.unlock()
  }

  /// 在此前已入队的所有字节消费后，于主线程执行一次语义事件。Ghostty 用它保证同一
  /// PTY 流中的 OSC 事件不会越过 Autocomplete 的原始输出，即使字节被拆成多个批次。
  func enqueueBarrier(_ completion: @escaping @MainActor () -> Void) {
    condition.lock()
    barriers.append((enqueuedByteCount, completion))
    scheduleDeliveryLocked(after: .now())
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
    var barrierCompletions: [@MainActor () -> Void] = []
    deliveryReady = false
    deliveryScheduled = false
    batch = takeBatchLocked()
    deliveredByteCount &+= UInt64(batch.count)
    while let first = barriers.first, first.afterByteCount <= deliveredByteCount {
      barrierCompletions.append(first.completion)
      barriers.removeFirst()
    }
    if pendingByteCount <= resumeByteLimit {
      condition.broadcast()
    }
    if pendingByteCount > 0 {
      // 已经形成 backlog 后不再人为等待合并；RunLoop idle seam 本身会保证每轮最多
      // 一个批次，让 AppKit 事件穿插，同时避免旧实现每 64 KiB 固定停顿 8 ms。
      scheduleDeliveryLocked(after: .now())
    } else if finishRequested {
      completions.append(contentsOf: completionHandlers)
      completionHandlers.removeAll()
    }
    condition.unlock()

    if !batch.isEmpty { consume(batch) }
    MainActor.assumeIsolated {
      barrierCompletions.forEach { $0() }
    }
    completions.forEach { $0() }
  }

  private func takeBatchLocked() -> [UInt8] {
    var remaining = batchByteLimit
    var result: [UInt8] = []
    result.reserveCapacity(batchByteLimit)

    while remaining > 0, firstChunkIndex < chunks.count {
      let chunk = chunks[firstChunkIndex]
      let available = chunk.count - firstChunkOffset
      let count = min(available, remaining)
      result.append(contentsOf: chunk[firstChunkOffset..<(firstChunkOffset + count)])
      firstChunkOffset += count
      pendingByteCount -= count
      remaining -= count

      if firstChunkOffset == chunk.count {
        firstChunkIndex += 1
        firstChunkOffset = 0
      }
    }

    // `Array.removeFirst()` 每消费一个 PTY partial chunk 都会搬移剩余元素，持续输出时
    // 会退化成 O(n²)。这里使用读游标，并仅在完全排空或已跨过半数且数量足够大时
    // 批量压缩一次；字节所有权和背压计数不变。
    if firstChunkIndex == chunks.count {
      chunks.removeAll(keepingCapacity: true)
      firstChunkIndex = 0
    } else if firstChunkIndex >= 64, firstChunkIndex * 2 >= chunks.count {
      chunks.removeFirst(firstChunkIndex)
      firstChunkIndex = 0
    }
    return result
  }
}
