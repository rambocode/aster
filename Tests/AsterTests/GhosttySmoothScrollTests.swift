// 验证触控板像素滚动的手势收尾、对齐动画、配置投影与滚动量换算。
import AppKit
import CoreGraphics
import Foundation
import Testing

@testable import Aster

/// 模拟引擎的视觉滚动位置：整数行加小数行，snap 按过半进位取整。
@MainActor
private final class FakeScrollEngine {
  var position: Double
  var snapCount = 0
  var scrolled: [Double] = []

  init(position: Double) { self.position = position }

  func attach(to settler: GhosttyScrollSettler) {
    settler.readPosition = { [unowned self] in self.position }
    settler.scrollRows = { [unowned self] delta in
      self.scrolled.append(delta)
      self.position += delta
    }
    settler.snap = { [unowned self] in
      self.snapCount += 1
      let row = self.position.rounded(.down)
      self.position = self.position - row >= 0.5 ? row + 1 : row
    }
  }
}

@Test("手势阶段归类：惯性期间保持小数行，惯性或手势结束才对齐")
func ghosttyScrollGesturePhaseClassifiesAppKitPhases() {
  typealias Phase = GhosttyScrollGesturePhase
  #expect(Phase.classify(phase: .began, momentumPhase: []) == .tracking)
  #expect(Phase.classify(phase: .changed, momentumPhase: []) == .tracking)
  #expect(Phase.classify(phase: .mayBegin, momentumPhase: []) == .tracking)
  #expect(Phase.classify(phase: .ended, momentumPhase: []) == .fingerLifted)
  #expect(Phase.classify(phase: .cancelled, momentumPhase: []) == .ended)
  #expect(Phase.classify(phase: [], momentumPhase: .began) == .tracking)
  #expect(Phase.classify(phase: [], momentumPhase: .changed) == .tracking)
  #expect(Phase.classify(phase: [], momentumPhase: .ended) == .ended)
  #expect(Phase.classify(phase: [], momentumPhase: .cancelled) == .ended)
  #expect(Phase.classify(phase: [], momentumPhase: []) == .untracked)
}

@Test("对齐动画过半进到下一行，否则回到当前行，结束时精确落在整行")
@MainActor
func ghosttyScrollSettlerAnimatesToNearestRow() {
  let settler = GhosttyScrollSettler()
  let down = FakeScrollEngine(position: 10.7)
  down.attach(to: settler)
  settler.settle(animated: true, now: 0)
  #expect(settler.isSettling)
  settler.advance(to: 0.06)
  #expect(down.position > 10.7 && down.position < 11)
  settler.advance(to: 0.2)
  #expect(down.position == 11)
  #expect(down.snapCount == 1)
  #expect(!settler.isSettling)

  let up = FakeScrollEngine(position: 4.2)
  up.attach(to: settler)
  settler.settle(animated: true, now: 1)
  settler.advance(to: 1.03)
  #expect(up.position < 4.2 && up.position > 4)
  settler.advance(to: 1.5)
  #expect(up.position == 4)
  #expect(up.snapCount == 1)
}

@Test("已对齐时不启动动画；非动画对齐直接取整")
@MainActor
func ghosttyScrollSettlerSkipsAlignedAndSnapsImmediately() {
  let settler = GhosttyScrollSettler()
  let aligned = FakeScrollEngine(position: 7)
  aligned.attach(to: settler)
  settler.settle(animated: true, now: 0)
  #expect(!settler.isSettling)
  #expect(aligned.snapCount == 0)

  let fractional = FakeScrollEngine(position: 7.6)
  fractional.attach(to: settler)
  settler.settle(animated: false)
  #expect(fractional.position == 8)
  #expect(fractional.scrolled.isEmpty)
  #expect(!settler.isSettling)
}

@Test("动画期间视口被别处挪动时直接落到整行，不再叠加旧增量")
@MainActor
func ghosttyScrollSettlerStopsWhenViewportMovesElsewhere() {
  let settler = GhosttyScrollSettler()
  let engine = FakeScrollEngine(position: 20.3)
  engine.attach(to: settler)
  settler.settle(animated: true, now: 0)
  settler.advance(to: 0.03)
  let applied = engine.scrolled.count
  // 用户输入让视口回到底部。
  engine.position = 120
  settler.advance(to: 0.06)
  #expect(engine.scrolled.count == applied)
  #expect(engine.position == 120)
  #expect(!settler.isSettling)
}

@Test("新手势中断等待与动画，保留当前小数行")
@MainActor
func ghosttyScrollSettlerInterruptsOnNewGesture() {
  let settler = GhosttyScrollSettler()
  let engine = FakeScrollEngine(position: 3.4)
  engine.attach(to: settler)
  settler.settle(animated: true, now: 0)
  settler.advance(to: 0.03)
  let position = engine.position
  settler.handle(.tracking)
  #expect(!settler.isSettling)
  settler.advance(to: 0.2)
  #expect(engine.position == position)
  #expect(engine.snapCount == 0)

  // 抬手后先等惯性；惯性开始（tracking）就取消等待。
  settler.handle(.fingerLifted)
  #expect(settler.isSettling)
  settler.handle(.tracking)
  #expect(!settler.isSettling)
}

@Test("抬手后没有惯性跟上，稍等片刻再对齐")
@MainActor
func ghosttyScrollSettlerSettlesAfterFingerLiftGrace() async throws {
  let settler = GhosttyScrollSettler()
  let engine = FakeScrollEngine(position: 9.8)
  engine.attach(to: settler)
  settler.handle(.fingerLifted)
  #expect(engine.snapCount == 0)
  // 测试里没有显示器帧回调，由兜底定时器完成对齐。
  for _ in 0..<50 where engine.snapCount == 0 {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(engine.position == 10)
  #expect(engine.snapCount == 1)
  #expect(!settler.isSettling)
}

@Test("平滑滚动开关投影为 Ghostty 的 aster-smooth-scroll 配置")
@MainActor
func ghosttyConfigurationProjectsSmoothScrolling() {
  let suite = "aster.tests.ghostty-smooth-scroll.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let preferences = AppPreferences(defaults: defaults)
  #expect(GhosttyConfiguration.make(preferences: preferences).contains("aster-smooth-scroll = true\n"))
  preferences.configuration.controls.smoothScrolling = false
  #expect(GhosttyConfiguration.make(preferences: preferences).contains("aster-smooth-scroll = false\n"))
}

@Test("触控板滚动量按 backing scale 换算成像素，滚轮格数不换算")
@MainActor
func ghosttyScrollDeltasConvertPreciseDeltasToPixels() throws {
  let view = GhosttySurfaceView(workingDirectory: "/tmp", environment: [:], configurationText: "")
  let scale = Double(NSScreen.main?.backingScaleFactor ?? 1)

  let precise = try #require(
    CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 12, wheel2: 0, wheel3: 0))
  precise.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
  precise.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: 12)
  let preciseEvent = try #require(NSEvent(cgEvent: precise))
  #expect(preciseEvent.hasPreciseScrollingDeltas)
  let preciseY: Double = view.ghosttyScrollDeltas(for: preciseEvent).y
  #expect(preciseY == Double(preciseEvent.scrollingDeltaY) * scale)

  let wheel = try #require(
    CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 2, wheel2: 0, wheel3: 0))
  let wheelEvent = try #require(NSEvent(cgEvent: wheel))
  #expect(!wheelEvent.hasPreciseScrollingDeltas)
  let wheelY: Double = view.ghosttyScrollDeltas(for: wheelEvent).y
  #expect(wheelY == Double(wheelEvent.scrollingDeltaY))
}
