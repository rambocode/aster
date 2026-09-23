// 触控板像素滚动的收尾：整个手势（含惯性）结束后，把小数行平滑对齐到最近的整行。
import AppKit
import QuartzCore

/// 一次精确滚动事件在手势生命周期中的位置，决定何时把小数行对齐到整行。
///
/// 惯性有独立的生命周期：手指抬起后若随即进入惯性，在抬手那一刻对齐会让画面顿一下；
/// 只有惯性结束、被取消，或抬手后没有惯性跟上，才算整个手势结束。
enum GhosttyScrollGesturePhase: Equatable {
  /// 手指仍在触控板上，或惯性仍在滑动：保持小数行。
  case tracking
  /// 手指抬起、尚无惯性：稍等片刻，没有惯性跟上再对齐。
  case fingerLifted
  /// 惯性结束或被取消、手势被取消：立即对齐。
  case ended
  /// 没有阶段信息的精确设备：空闲一段时间后对齐。
  case untracked

  /// 按 AppKit 的手指阶段与惯性阶段归类。
  static func classify(phase: NSEvent.Phase, momentumPhase: NSEvent.Phase) -> Self {
    if momentumPhase.contains(.ended) || momentumPhase.contains(.cancelled) { return .ended }
    if !momentumPhase.isEmpty { return .tracking }
    if phase.contains(.cancelled) { return .ended }
    if phase.contains(.ended) { return .fingerLifted }
    if phase.isEmpty { return .untracked }
    return .tracking
  }
}

/// 把小数行滚动位置平滑对齐到最近的整行。
///
/// 对齐用约 120ms 的 ease-out 动画、按显示器节奏推进。用户再次触碰或滚动时立即停下，
/// 保留当前位置交给新手势；动画期间视口被别的操作挪动（输入回到底部、scrollback 裁剪）
/// 时直接精确对齐并结束，绝不在新视口上继续叠加旧的增量。
@MainActor
final class GhosttyScrollSettler: NSObject {
  /// 抬手后等待惯性开始的时间。惯性通常在一两帧内到达；60Hz 下留足余量，
  /// 否则对齐先开始、又被随后到达的惯性打断，画面会顿一下。
  static let fingerLiftGrace: TimeInterval = 0.08
  /// 没有阶段信息的设备停止滚动多久后对齐。
  static let untrackedIdleDelay: TimeInterval = 0.25
  /// 对齐动画时长。
  static let settleDuration: CFTimeInterval = 0.12
  /// 帧回调迟迟不来（窗口被遮挡、显示器休眠）时，多久后直接落到整行。
  static let settleFallbackDelay: TimeInterval = 0.25
  /// 判断视口是否被别处挪动的容差（行）。
  static let positionTolerance = 1e-3

  /// 当前视觉滚动位置（整数行 + 小数行）；nil 表示 surface 不可用。
  var readPosition: @MainActor () -> Double? = { nil }
  /// 按小数行滚动视口（向下为正）。
  var scrollRows: @MainActor (Double) -> Void = { _ in }
  /// 精确对齐到最近整行。
  var snap: @MainActor () -> Void = {}
  /// 创建显示器同步的帧回调；测试可以不设置，改为直接调用 `advance(to:)`。
  var makeDisplayLink: (@MainActor (GhosttyScrollSettler) -> CADisplayLink?)?

  private var pendingTimer: Timer?
  private var fallbackTimer: Timer?
  private var displayLink: CADisplayLink?
  private var animation: Animation?

  private struct Animation {
    var startPosition: Double
    var total: Double
    var applied: Double
    var startTime: CFTimeInterval
  }

  /// 是否正在等待或执行对齐。
  var isSettling: Bool { pendingTimer != nil || animation != nil }

  /// 用户再次触碰或滚动：停止等待与动画，保留当前位置。
  func interrupt() {
    pendingTimer?.invalidate()
    pendingTimer = nil
    stopAnimation()
  }

  /// 处理一次已交给引擎的精确滚动事件。任何新事件都先停下正在进行的等待或动画。
  func handle(_ phase: GhosttyScrollGesturePhase) {
    interrupt()
    switch phase {
    case .tracking:
      break
    case .fingerLifted:
      schedule(after: Self.fingerLiftGrace)
    case .untracked:
      schedule(after: Self.untrackedIdleDelay)
    case .ended:
      settle(animated: true)
    }
  }

  /// 立即开始对齐；`animated == false` 用于视图离开窗口、关闭平滑滚动等不适合动画的场合。
  /// `now` 是动画起点，第一帧就按经过的时间推进，不白等一帧。
  func settle(animated: Bool, now: CFTimeInterval = CACurrentMediaTime()) {
    interrupt()
    guard let position = readPosition() else { return }
    let fraction = position - position.rounded(.down)
    guard fraction > 0 else { return }
    guard animated else {
      snap()
      return
    }
    // 过半对齐到下一行，否则回到当前行；与引擎 `snapScrollRow` 的取整规则一致。
    let total = fraction >= 0.5 ? 1 - fraction : -fraction
    animation = Animation(startPosition: position, total: total, applied: 0, startTime: now)
    if let makeDisplayLink, let link = makeDisplayLink(self) {
      link.add(to: .main, forMode: .common)
      displayLink = link
    }
    // 帧回调只在视图可见时到达；兜底保证小数行不会悬在半路。
    fallbackTimer = makeTimer(after: Self.settleFallbackDelay) { settler in
      settler.fallbackTimer = nil
      if settler.animation != nil { settler.finish() }
    }
  }

  /// 推进一帧对齐动画。`timestamp` 是这一帧的目标呈现时间。
  func advance(to timestamp: CFTimeInterval) {
    guard var animation else { return }
    let progress = min(1, max(0, (timestamp - animation.startTime) / Self.settleDuration))
    guard let current = readPosition(),
      abs(current - (animation.startPosition + animation.applied)) <= Self.positionTolerance
    else {
      // 视口已被别处挪动：不再叠加增量，直接落到整行。
      finish()
      return
    }
    if progress >= 1 {
      finish()
      return
    }
    let target = animation.total * Self.easeOut(progress)
    scrollRows(target - animation.applied)
    animation.applied = target
    self.animation = animation
  }

  /// ease-out cubic：起步快、收尾慢，贴近系统滚动减速的观感。
  static func easeOut(_ progress: Double) -> Double {
    let remaining = 1 - min(1, max(0, progress))
    return 1 - remaining * remaining * remaining
  }

  @objc func displayLinkFired(_ link: CADisplayLink) {
    advance(to: link.targetTimestamp)
  }

  private func schedule(after delay: TimeInterval) {
    pendingTimer?.invalidate()
    pendingTimer = makeTimer(after: delay) { settler in
      settler.pendingTimer = nil
      settler.settle(animated: true)
    }
  }

  /// 在主 RunLoop 的 common 模式里挂一次性定时器，事件跟踪期间也会触发。
  private func makeTimer(
    after delay: TimeInterval,
    _ action: @escaping @MainActor (GhosttyScrollSettler) -> Void
  ) -> Timer {
    let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        action(self)
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    return timer
  }

  private func finish() {
    stopAnimation()
    snap()
  }

  private func stopAnimation() {
    animation = nil
    fallbackTimer?.invalidate()
    fallbackTimer = nil
    displayLink?.invalidate()
    displayLink = nil
  }
}
