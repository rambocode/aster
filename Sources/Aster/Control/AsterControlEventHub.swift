import AsterCore
import Foundation

/// 控制协议事件枢纽：单调序列号、512 条环形回放缓冲、订阅者扇出与一次性等待者。
/// 全部在 MainActor 上运行——事件源（AppModel/TerminalSession 的 Combine 发布）本就在主线程。
@MainActor
final class AsterControlEventHub {
  static let replayCapacity = 512

  /// 回放结果：`truncated` 表示 `after` 之后有事件已被环形缓冲挤掉，客户端应改用 snapshot 重同步。
  struct Replay {
    let events: [AsterControlEvent]
    let truncated: Bool
  }

  let capacity: Int

  /// 订阅者：按种类过滤后把事件交给 sink（sink 内部再切到 socket 写队列）。
  struct Subscriber {
    let kinds: Set<AsterControlEventKind>
    let sink: (AsterControlEvent) -> Void
  }

  private struct Waiter {
    let predicate: (AsterControlEvent) -> Bool
    let continuation: CheckedContinuation<AsterControlEvent, Error>
  }

  private(set) var sequence: UInt64 = 0
  private var buffer: [AsterControlEvent] = []
  private var subscribers: [UUID: Subscriber] = [:]
  private var waiters: [UUID: Waiter] = [:]

  init(capacity: Int = AsterControlEventHub.replayCapacity) {
    self.capacity = max(1, capacity)
  }

  /// 发布事件：分配序列号、入环形缓冲、唤醒等待者、扇出给订阅者。
  @discardableResult
  func publish(_ kind: AsterControlEventKind, data: JSONValue) -> AsterControlEvent {
    sequence += 1
    let event = AsterControlEvent(sequence: sequence, event: kind, data: data)
    buffer.append(event)
    if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
    // 先取快照再遍历：等待者的 continuation 恢复后可能同步注册新等待者。
    for (id, waiter) in waiters where waiter.predicate(event) {
      waiters[id] = nil
      waiter.continuation.resume(returning: event)
    }
    for subscriber in subscribers.values where subscriber.kinds.isEmpty || subscriber.kinds.contains(kind) {
      subscriber.sink(event)
    }
    return event
  }

  /// 便捷发布：强类型 payload。
  @discardableResult
  func publish<T: Encodable>(_ kind: AsterControlEventKind, encoding value: T) -> AsterControlEvent? {
    guard let data = try? JSONValue(encoding: value) else { return nil }
    return publish(kind, data: data)
  }

  /// 序列号之后的事件回放（用于断线重连与 events.wait after_sequence）。
  func replay(after sequenceNumber: UInt64) -> [AsterControlEvent] {
    replayResult(after: sequenceNumber).events
  }

  /// 带截断标记的回放：`after+1` 早于环中最旧序列号即说明中间有事件已丢失。
  func replayResult(after sequenceNumber: UInt64) -> Replay {
    let firstAvailable = buffer.first?.sequence ?? (sequence + 1)
    let truncated = sequenceNumber + 1 < firstAvailable
    return Replay(events: buffer.filter { $0.sequence > sequenceNumber }, truncated: truncated)
  }

  func subscribe(id: UUID, kinds: [AsterControlEventKind], sink: @escaping (AsterControlEvent) -> Void) {
    subscribers[id] = Subscriber(kinds: Set(kinds), sink: sink)
  }

  func unsubscribe(id: UUID) {
    subscribers[id] = nil
  }

  var subscriberCount: Int { subscribers.count }

  /// 等待第一条满足谓词的事件；超时抛 `timeout`，任务取消抛 CancellationError。
  /// `after` 不为 nil 时先查回放缓冲，避免在注册等待者前刚好错过的事件永远等不到。
  func waitForEvent(
    after: UInt64? = nil,
    timeoutMilliseconds: Int,
    predicate: @escaping (AsterControlEvent) -> Bool
  ) async throws -> AsterControlEvent {
    if let after, let replayed = replay(after: after).first(where: predicate) {
      return replayed
    }
    // 任务在注册等待者之前已被取消（连接刚断开）时直接抛出，不让等待者挂到超时。
    try Task.checkCancellation()
    let id = UUID()
    let timeoutTask = Task { [weak self] in
      try? await Task.sleep(for: .milliseconds(timeoutMilliseconds))
      guard !Task.isCancelled else { return }
      self?.resumeWaiter(id: id, throwing: AsterControlError(code: .timeout, message: "等待事件超时"))
    }
    defer { timeoutTask.cancel() }
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        waiters[id] = Waiter(predicate: predicate, continuation: continuation)
        // onCancel 可能在 waiter 注册之前就已触发（那时 resumeWaiter 找不到目标直接返回），
        // 注册后再查一次取消位，保证不会留下只能靠超时收尾的孤儿等待者。
        if Task.isCancelled { resumeWaiter(id: id, throwing: CancellationError()) }
      }
    } onCancel: {
      Task { @MainActor [weak self] in self?.resumeWaiter(id: id, throwing: CancellationError()) }
    }
  }

  private func resumeWaiter(id: UUID, throwing error: Error) {
    guard let waiter = waiters.removeValue(forKey: id) else { return }
    waiter.continuation.resume(throwing: error)
  }
}
