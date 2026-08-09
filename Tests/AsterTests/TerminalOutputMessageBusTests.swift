import Foundation
import AppKit
import Metal
import Testing

@testable import Aster
@testable import SwiftTerm

@Test("终端输出消息总线按字节顺序分批，并在末批后交付结束事件")
@MainActor
func terminalOutputMessageBusPreservesOrderAndDefersCompletion() async throws {
  let probe = TerminalOutputMessageBusProbe()
  let bus = TerminalOutputMessageBus(
    batchByteLimit: 3,
    pendingByteLimit: 12,
    bulkByteThreshold: 3,
    bulkCoalescingDelay: .milliseconds(1)
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
    bulkByteThreshold: 2,
    bulkCoalescingDelay: .milliseconds(1)
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

@Test("终端输出先到达时主线程界面任务仍优先执行")
@MainActor
func terminalOutputMessageBusRunsInterfaceTaskBeforeDelivery() async throws {
  let probe = TerminalOutputMessageBusProbe()
  let bus = TerminalOutputMessageBus(
    batchByteLimit: 8,
    pendingByteLimit: 32,
    bulkByteThreshold: 8,
    bulkCoalescingDelay: .nanoseconds(0)
  ) { probe.appendBatchRecordingInterfaceOrder($0) }
  let bytes = Array("panel-click".utf8)
  let producer = Task.detached(priority: .userInitiated) {
    bus.enqueue(bytes[...])
    // 模拟终端消息已经排期后到达的 Panel 主线程任务。输出消费必须等本轮 RunLoop
    // 的界面任务处理完，而不是靠终端总线理解或窥视 Panel 事件。
    DispatchQueue.main.async { probe.markInterfaceTaskCompleted() }
    bus.finish { probe.markFinished() }
  }

  try await waitForTerminalOutputBus { probe.isFinished }
  _ = await producer.value

  #expect(probe.batches.flatMap { $0 } == bytes)
  #expect(probe.firstBatchSawCompletedInterfaceTask)
}

@Test("单次 PTY 读取按 64 KiB 解析预算分批且保持字节顺序")
@MainActor
func terminalOutputMessageBusBoundsOnePtyReadAcrossParserBatches() async throws {
  let probe = TerminalOutputMessageBusProbe()
  let bus = TerminalOutputMessageBus { probe.appendBatch($0) }
  // SwiftTerm LocalProcess 的单次读取上限是 128 KiB。总线按 Ghostty 同级的 64 KiB
  // parse budget 拆成两批；SwiftTerm 的 pending display 会把同一帧 feed 合成一次绘制。
  let bytes = Array(repeating: UInt8(ascii: "x"), count: 128 * 1_024)
  let production = Task.detached(priority: .userInitiated) {
    bus.enqueue(bytes[...])
    bus.finish { probe.markFinished() }
  }

  try await waitForTerminalOutputBus { probe.isFinished }
  _ = await production.value

  #expect(probe.batches.count == 2)
  #expect(probe.batches.allSatisfy { $0.count == 64 * 1_024 })
  #expect(probe.batches.flatMap { $0 } == bytes)
}

@Test("大量 PTY partial chunk 使用游标排空且不改变顺序")
@MainActor
func terminalOutputMessageBusDrainsManyPartialChunksInLinearOrder() async throws {
  let probe = TerminalOutputMessageBusProbe()
  let bus = TerminalOutputMessageBus(
    batchByteLimit: 1_024,
    pendingByteLimit: 128 * 1_024,
    bulkByteThreshold: 1_024,
    bulkCoalescingDelay: .nanoseconds(0)
  ) { probe.appendBatch($0) }
  let chunks = (0..<2_048).map { index in
    Array(repeating: UInt8(index % 251), count: 32)
  }
  let expected = chunks.flatMap { $0 }
  let producer = Task.detached(priority: .userInitiated) {
    for chunk in chunks { bus.enqueue(chunk[...]) }
    bus.finish { probe.markFinished() }
  }

  try await waitForTerminalOutputBus { probe.isFinished }
  _ = await producer.value

  #expect(probe.batches.flatMap { $0 } == expected)
  #expect(probe.batches.allSatisfy { $0.count <= 1_024 })
}

@Test("终端进入窗口后优先启用 dirty-row Metal renderer")
@MainActor
func terminalViewActivatesMetalRendererWhenAttachedToWindow() {
  guard MTLCreateSystemDefaultDevice() != nil else { return }
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
  )
  let view = AsterTerminalView(frame: window.contentView?.bounds ?? .zero)
  window.contentView?.addSubview(view)

  #expect(view.isUsingMetalRenderer)
}

@Test("修改字号会立即请求 Metal renderer 绘制新帧")
@MainActor
func terminalFontChangeRequestsMetalRedraw() throws {
  guard MTLCreateSystemDefaultDevice() != nil else { return }
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
  )
  let view = AsterTerminalView(frame: window.contentView?.bounds ?? .zero)
  window.contentView?.addSubview(view)
  _ = try #require(view.metalView)
  var displayRequestCount = 0
  view.onMetalDisplayRequest = { displayRequestCount += 1 }

  let nextSize = view.font.pointSize + 1
  let nextFont = NSFont.monospacedSystemFont(ofSize: nextSize, weight: .regular)
  view.setFonts(normal: nextFont, bold: nextFont, italic: nextFont, boldItalic: nextFont)

  #expect(view.font.pointSize == nextSize)
  #expect(displayRequestCount == 1)
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
  private var storedInterfaceTaskCompleted = false
  private var storedFirstBatchSawCompletedInterfaceTask: Bool?

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

  var firstBatchSawCompletedInterfaceTask: Bool {
    lock.withLock { storedFirstBatchSawCompletedInterfaceTask == true }
  }

  func appendBatch(_ bytes: [UInt8]) {
    lock.withLock { storedBatches.append(bytes) }
  }

  func markFinished() {
    lock.withLock { storedFinished = true }
  }

  func markInterfaceTaskCompleted() {
    lock.withLock { storedInterfaceTaskCompleted = true }
  }

  func appendBatchRecordingInterfaceOrder(_ bytes: [UInt8]) {
    lock.withLock {
      if storedFirstBatchSawCompletedInterfaceTask == nil {
        storedFirstBatchSawCompletedInterfaceTask = storedInterfaceTaskCompleted
      }
      storedBatches.append(bytes)
    }
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
