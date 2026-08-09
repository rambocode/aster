import Foundation
import Testing

@testable import Aster

@Test("终端输出消息总线按字节顺序分批，并在末批后交付结束事件")
@MainActor
func terminalOutputMessageBusPreservesOrderAndDefersCompletion() async throws {
  let probe = TerminalOutputMessageBusProbe()
  let bus = TerminalOutputMessageBus(
    batchByteLimit: 3,
    pendingByteLimit: 12,
    interBatchDelay: .milliseconds(1)
  ) { probe.appendBatch($0) }

  let bytes = Array("terminal-event-bus".utf8)
  // PTY 回调在专属输出队列中生产；主线程仅负责分批消费。
  // 若在这里主线程生产超过上限的数据，背压会故意等待主线程消费，
  // 因而不能覆盖实际生产模型。
  let producer = Task.detached(priority: .userInitiated) {
    bus.enqueue(bytes[...])
    bus.finish { probe.markFinished() }
  }

  try await waitForTerminalOutputBus { probe.isFinished }
  _ = await producer.value

  #expect(probe.batches.flatMap { $0 } == bytes)
  #expect(probe.batches.allSatisfy { !$0.isEmpty && $0.count <= 3 })
  #expect(probe.isFinished)
}

@Test("终端输出消息总线在批次间让出主线程给界面事件")
@MainActor
func terminalOutputMessageBusYieldsBetweenBatches() async throws {
  let probe = TerminalOutputMessageBusProbe()
  let bus = TerminalOutputMessageBus(
    batchByteLimit: 2,
    pendingByteLimit: 12,
    interBatchDelay: .milliseconds(1)
  ) { _ in
    guard probe.recordBatchAndReturnCount() == 1 else { return }
    // 这模拟用户已经点到详情页签：事件必须在后续输出批次前得到主线程机会。
    DispatchQueue.main.async {
      probe.recordInterfaceEvent(after: probe.batchCount)
    }
  }

  let bytes = Array(repeating: UInt8(ascii: "x"), count: 12)
  // 与真实 LocalProcess 回调一致，从后台生产输出；消费仍在主线程执行。
  let producer = Task.detached(priority: .userInitiated) {
    bus.enqueue(bytes[...])
  }

  try await waitForTerminalOutputBus { probe.batchCount == 6 }
  _ = await producer.value

  #expect(probe.interfaceEventBatchCount == 1)
}

@Test("待处理界面事件会优先于终端输出交付")
@MainActor
func terminalOutputMessageBusDefersForPendingInterfaceEvent() async throws {
  let probe = TerminalOutputMessageBusProbe()
  let interaction = TerminalOutputInteractionProbe(isPending: true)
  let bus = TerminalOutputMessageBus(
    batchByteLimit: 8,
    pendingByteLimit: 32,
    interBatchDelay: .milliseconds(1),
    shouldDeferDelivery: { interaction.isPending }
  ) { probe.appendBatch($0) }
  let bytes = Array("panel-click".utf8)
  let producer = Task.detached(priority: .userInitiated) {
    bus.enqueue(bytes[...])
  }

  // 连续等待多个交付周期，确认有点击/键盘事件排队时不会抢先解析终端输出。
  try await Task.sleep(for: .milliseconds(8))
  #expect(probe.batches.isEmpty)

  interaction.isPending = false
  try await waitForTerminalOutputBus { probe.batches.flatMap { $0 } == bytes }
  _ = await producer.value
}

@Test("单次 PTY 读取只形成一次可见终端更新")
@MainActor
func terminalOutputMessageBusKeepsOnePtyReadInOneVisualBatch() async throws {
  let probe = TerminalOutputMessageBusProbe()
  let bus = TerminalOutputMessageBus { probe.appendBatch($0) }
  // SwiftTerm LocalProcess 的单次读取上限是 128 KiB。把它拆成许多 8 KiB feed 会让
  // ANSI 进度绘制的中间状态逐帧暴露，终端 Pane 就会高频闪烁。
  let bytes = Array(repeating: UInt8(ascii: "x"), count: 128 * 1_024)
  let production = Task.detached(priority: .userInitiated) {
    bus.enqueue(bytes[...])
    bus.finish { probe.markFinished() }
  }

  try await waitForTerminalOutputBus { probe.isFinished }
  _ = await production.value

  #expect(probe.batches.count == 1)
  #expect(probe.batches.first?.count == bytes.count)
}

@MainActor
private func waitForTerminalOutputBus(
  timeout: Duration = .seconds(1),
  condition: @escaping () -> Bool
) async throws {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while !condition() {
    guard clock.now < deadline else {
      throw TerminalOutputMessageBusTestError.timedOut
    }
    try await Task.sleep(for: .milliseconds(2))
  }
}

private enum TerminalOutputMessageBusTestError: Error {
  case timedOut
}

/// 在后台生产者与主线程消费者之间安全记录测试结果，避免测试自身制造数据竞争。
private final class TerminalOutputMessageBusProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storedBatches: [[UInt8]] = []
  private var storedFinished = false
  private var storedInterfaceEventBatchCount: Int?

  var batches: [[UInt8]] {
    lock.withLock { storedBatches }
  }

  var isFinished: Bool {
    lock.withLock { storedFinished }
  }

  var batchCount: Int {
    lock.withLock { storedBatches.count }
  }

  var interfaceEventBatchCount: Int? {
    lock.withLock { storedInterfaceEventBatchCount }
  }

  func appendBatch(_ bytes: [UInt8]) {
    lock.withLock { storedBatches.append(bytes) }
  }

  func markFinished() {
    lock.withLock { storedFinished = true }
  }

  func recordBatchAndReturnCount() -> Int {
    lock.withLock {
      storedBatches.append([])
      return storedBatches.count
    }
  }

  func recordInterfaceEvent(after batchCount: Int) {
    lock.withLock { storedInterfaceEventBatchCount = batchCount }
  }
}

/// 模拟 NSApplication 事件队列是否已有直接用户交互，状态由锁保护以匹配总线边界。
private final class TerminalOutputInteractionProbe: @unchecked Sendable {
  private let lock = NSLock()
  private var storedIsPending: Bool

  init(isPending: Bool) {
    storedIsPending = isPending
  }

  var isPending: Bool {
    get { lock.withLock { storedIsPending } }
    set { lock.withLock { storedIsPending = newValue } }
  }
}
