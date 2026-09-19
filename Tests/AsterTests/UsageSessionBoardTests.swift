import AppKit
import AsterCore
import Combine
import Foundation
import Testing
import os

@testable import Aster

/// 假的会话数据源：测试直接改 `entries` 再 `emit()`。
@MainActor
private final class StubBoardSource: UsageSessionBoardDataSource {
  var entries: [UsageSessionEntry] = []
  private(set) var focused: [UUID] = []
  private let subject = PassthroughSubject<Void, Never>()

  func sessions() -> [UsageSessionEntry] { entries }
  var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
  func focus(paneID: UUID) { focused.append(paneID) }
  func emit() { subject.send(()) }
}

/// 假采样器：每拍把 uptime 推进 1 秒，给进程树记 0.5 秒 CPU（= 50%）。
///
/// 计数用锁保护：采样闭包在后台线程执行，测试在主线程读结果。
private struct StubSampler: Sendable {
  let ticks = OSAllocatedUnfairLock(initialState: 0)

  func sample() -> ProcessSample {
    let tick = ticks.withLock { value -> Int in
      value += 1
      return value
    }
    let cpu = Double(tick) * 0.5
    return ProcessSample(
      uptime: Double(tick),
      readings: [
        100: ProcessReading(
          pid: 100, parentPID: 1, cpuSeconds: cpu, memoryBytes: 400 * 1024 * 1024),
        101: ProcessReading(
          pid: 101, parentPID: 100, cpuSeconds: 0, memoryBytes: 112 * 1024 * 1024),
      ])
  }
}

@MainActor
private func makeEntry(
  _ id: UUID, status: AgentControlStatus, title: String, pid: Int32? = 100
) -> UsageSessionEntry {
  UsageSessionEntry(
    id: id, provider: .claudeCode, status: status, title: title,
    workingDirectory: NSHomeDirectory() + "/project", rootProcessIdentifier: pid)
}

/// 造一个页面控制器：采样器换成假的，间隔可压到毫秒级。
@MainActor
private func makeController(
  _ source: StubBoardSource, interval: Duration = .seconds(3)
) -> UsageSessionBoardSectionController {
  let stub = StubSampler()
  return UsageSessionBoardSectionController(
    dataSource: source, sampler: { stub.sample() }, sampleInterval: interval)
}

/// 轮询等待条件成立：采样是异步的，不能靠固定 sleep 赌时间。
@MainActor
private func waitUntil(timeout: Duration = .seconds(3), _ condition: () -> Bool) async {
  let deadline = ContinuousClock.now.advanced(by: timeout)
  while !condition() {
    if ContinuousClock.now >= deadline { return }
    try? await Task.sleep(for: .milliseconds(5))
  }
}

/// 在视图树里按 identifier 找一个视图。
@MainActor
private func findView(_ identifier: String, in root: NSView) -> NSView? {
  if root.identifier?.rawValue == identifier { return root }
  for subview in root.subviews {
    if let found = findView(identifier, in: subview) { return found }
  }
  return nil
}

@Suite("UsageSessionBoard 会话看板页")
@MainActor
struct UsageSessionBoardSectionTests {
  @Test("激活后渲染卡片，等待输入的排最前")
  func 激活渲染() {
    let source = StubBoardSource()
    let idle = UUID()
    let blocked = UUID()
    source.entries = [
      makeEntry(idle, status: .idle, title: "alpha"),
      makeEntry(blocked, status: .blocked, title: "zeta"),
    ]
    let controller = makeController(source)
    controller.activate()
    defer { controller.suspend() }

    #expect(controller.cardsInOrder.map(\.entryID) == [blocked, idle])
    #expect(controller.cardsInOrder.first?.statusText == "等待输入")
    #expect(controller.cardsInOrder.first?.showsBlockedAccent == true)
    #expect(controller.cardsInOrder.last?.statusText == "空闲")
    #expect(controller.cardsInOrder.last?.showsBlockedAccent == false)
    #expect(controller.cardsInOrder.first?.titleText == "zeta")
    #expect(controller.cardsInOrder.first?.directoryText == "~/project")
  }

  @Test("指标列是三等分的，标签在上数值在下")
  func 指标三等分列() {
    let source = StubBoardSource()
    let id = UUID()
    source.entries = [makeEntry(id, status: .working, title: "alpha")]
    let controller = makeController(source)
    controller.activate()
    defer { controller.suspend() }

    let card = controller.cardsInOrder.first
    let columns = card?.metricColumns ?? []
    #expect(card?.metricsDistribution == .fillEqually)
    #expect(columns.count == 3)
    #expect(columns.map(\.nameText) == ["CPU", "内存", "进程"])
    // 每列都是「标签在上、数值在下」的纵向两行。
    #expect(columns.allSatisfy({ $0.orientation == .vertical }))
    #expect(columns.map(\.orderedTexts.count) == [2, 2, 2])
    #expect(columns.first?.orderedTexts.first == "CPU")
    #expect(columns.first?.orderedTexts.last == card?.cpuText)
    #expect(findView("usage-session-metric-cpu", in: controller.view) != nil)
  }

  @Test("还没有采样结果时三列都是破折号")
  func 首帧指标破折号() {
    let source = StubBoardSource()
    let id = UUID()
    source.entries = [makeEntry(id, status: .working, title: "alpha")]
    // 间隔给足，保证断言发生在第一拍采样回来之前。
    let controller = makeController(source, interval: .seconds(60))
    controller.activate()
    defer { controller.suspend() }

    let card = controller.cardsInOrder.first
    #expect(card?.cpuText == "—")
    #expect(card?.memoryText == "—")
    #expect(card?.processText == "—")
  }

  @Test("等待输入的卡片有红竖线与红色徽标，其余用中性色")
  func 等待输入红色标记() {
    let source = StubBoardSource()
    let blocked = UUID()
    let working = UUID()
    source.entries = [
      makeEntry(blocked, status: .blocked, title: "zeta"),
      makeEntry(working, status: .working, title: "alpha"),
    ]
    let controller = makeController(source)
    controller.activate()
    defer { controller.suspend() }

    #expect(controller.cardsInOrder.first?.showsBlockedAccent == true)
    #expect(controller.cardsInOrder.first?.statusTextColor == NSColor.systemRed)
    #expect(controller.cardsInOrder.last?.showsBlockedAccent == false)
    #expect(controller.cardsInOrder.last?.statusTextColor == AsterTheme.secondaryInk)
    #expect(findView("usage-session-status-badge", in: controller.view) != nil)
  }

  @Test("目录中间截断")
  func 目录中间截断() {
    let source = StubBoardSource()
    let id = UUID()
    source.entries = [makeEntry(id, status: .working, title: "alpha")]
    let controller = makeController(source)
    controller.activate()
    defer { controller.suspend() }

    #expect(controller.cardsInOrder.first?.directoryTruncatesMiddle == true)
    #expect(controller.cardsInOrder.first?.directoryText == "~/project")
  }

  @Test("没有会话时显示空态且不采样")
  func 空态不采样() {
    let source = StubBoardSource()
    let controller = makeController(source)
    controller.activate()
    defer { controller.suspend() }

    #expect(controller.cardsInOrder.isEmpty)
    #expect(controller.hasScheduledPoll == false)
    #expect(findView("usage-session-empty", in: controller.view) != nil)
  }

  @Test("状态变化原地更新，不换位也不重建卡片")
  func 原地更新不换位() {
    let source = StubBoardSource()
    let first = UUID()
    let second = UUID()
    source.entries = [
      makeEntry(first, status: .idle, title: "alpha"),
      makeEntry(second, status: .idle, title: "zeta"),
    ]
    let controller = makeController(source)
    controller.activate()
    defer { controller.suspend() }
    #expect(controller.cardsInOrder.map(\.entryID) == [first, second])
    let secondCard = controller.cardsInOrder.last

    // zeta 变成「等待输入」：优先级最高，但座位冻结，位置不动。
    source.entries = [
      makeEntry(first, status: .idle, title: "alpha"),
      makeEntry(second, status: .blocked, title: "zeta"),
    ]
    source.emit()

    #expect(controller.cardsInOrder.map(\.entryID) == [first, second])
    #expect(controller.cardsInOrder.last === secondCard)
    #expect(controller.cardsInOrder.last?.statusText == "等待输入")
    #expect(controller.cardsInOrder.last?.showsBlockedAccent == true)
  }

  @Test("重新激活时按优先级重排座位")
  func 重新激活重排() {
    let source = StubBoardSource()
    let first = UUID()
    let second = UUID()
    source.entries = [
      makeEntry(first, status: .idle, title: "alpha"),
      makeEntry(second, status: .idle, title: "zeta"),
    ]
    let controller = makeController(source)
    controller.activate()
    source.entries = [
      makeEntry(first, status: .idle, title: "alpha"),
      makeEntry(second, status: .blocked, title: "zeta"),
    ]
    source.emit()
    #expect(controller.cardsInOrder.map(\.entryID) == [first, second])

    controller.suspend()
    controller.activate()
    defer { controller.suspend() }
    #expect(controller.cardsInOrder.map(\.entryID) == [second, first])
  }

  @Test("会话消失后卡片移除")
  func 会话消失() {
    let source = StubBoardSource()
    let first = UUID()
    let second = UUID()
    source.entries = [
      makeEntry(first, status: .idle, title: "alpha"),
      makeEntry(second, status: .idle, title: "zeta"),
    ]
    let controller = makeController(source)
    controller.activate()
    defer { controller.suspend() }

    source.entries = [makeEntry(second, status: .idle, title: "zeta")]
    source.emit()
    #expect(controller.cardsInOrder.map(\.entryID) == [second])
  }

  @Test("点击卡片跳到对应 Pane")
  func 点击跳转() {
    let source = StubBoardSource()
    let id = UUID()
    source.entries = [makeEntry(id, status: .working, title: "alpha")]
    let controller = makeController(source)
    controller.activate()
    defer { controller.suspend() }

    controller.cardsInOrder.first?.performClick(nil)
    #expect(source.focused == [id])
  }

  @Test("有会话时开始采样，第二拍起有 CPU 数字")
  func 采样节拍() async {
    let source = StubBoardSource()
    let id = UUID()
    source.entries = [makeEntry(id, status: .working, title: "alpha")]
    let controller = makeController(source, interval: .milliseconds(20))
    controller.activate()
    defer { controller.suspend() }
    #expect(controller.hasScheduledPoll)

    // 第一拍没有上一份样本，CPU 只能是破折号，内存与进程数已经可用。
    await waitUntil { controller.cardsInOrder.first?.memoryText == "512 MB" }
    #expect(controller.cardsInOrder.first?.cpuText == "—")
    #expect(controller.cardsInOrder.first?.processText == "2")

    await waitUntil { controller.cardsInOrder.first?.cpuText == "50%" }
    #expect(controller.cardsInOrder.first?.cpuText == "50%")
    #expect(controller.cardsInOrder.first?.memoryText == "512 MB")
    #expect(controller.cardsInOrder.first?.processText == "2")
  }

  @Test("拿不到根进程的卡片占用显示破折号")
  func 无根进程() async {
    let source = StubBoardSource()
    let id = UUID()
    source.entries = [makeEntry(id, status: .working, title: "alpha", pid: nil)]
    let controller = makeController(source, interval: .milliseconds(20))
    controller.activate()
    defer { controller.suspend() }

    // 采了好几拍也拿不到根进程，占用一直是破折号。
    try? await Task.sleep(for: .milliseconds(80))
    #expect(controller.cardsInOrder.first?.cpuText == "—")
    #expect(controller.cardsInOrder.first?.memoryText == "—")
    #expect(controller.cardsInOrder.first?.processText == "—")
  }

  @Test("挂起后停止采样，迟到的采样结果不落到界面")
  func 挂起丢弃迟到结果() async {
    let source = StubBoardSource()
    let id = UUID()
    source.entries = [makeEntry(id, status: .working, title: "alpha")]
    // 采样闭包卡在信号量上，模拟「结果比 suspend 还晚回来」。
    let gate = DispatchSemaphore(value: 0)
    let stub = StubSampler()
    let controller = UsageSessionBoardSectionController(
      dataSource: source,
      sampler: {
        gate.wait()
        return stub.sample()
      },
      sampleInterval: .milliseconds(20))
    controller.activate()

    await waitUntil { controller.isSampling }
    controller.suspend()
    #expect(controller.hasScheduledPoll == false)

    gate.signal()
    // 给迟到的结果足够时间回到主线程；它应当被世代校验挡下。
    try? await Task.sleep(for: .milliseconds(80))
    #expect(controller.cardsInOrder.first?.cpuText == "—")
    #expect(controller.cardsInOrder.first?.memoryText == "—")
    #expect(controller.cardsInOrder.first?.processText == "—")
    #expect(controller.hasScheduledPoll == false)
  }
}
