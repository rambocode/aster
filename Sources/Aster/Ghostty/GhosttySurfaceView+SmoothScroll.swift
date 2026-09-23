// 终端 Pane 的像素滚动：精确滚动量换算、小数行收尾对齐，以及叠加层需要的网格偏移。
import AppKit
@preconcurrency import GhosttyKit

extension GhosttySurfaceView {
  // MARK: - Smooth scroll

  /// 小数行收尾器，按需创建。只从事件处理路径调用，不在拆离与销毁路径调用。
  var ghosttyScrollSettler: GhosttyScrollSettler {
    if let existingScrollSettler { return existingScrollSettler }
    let settler = makeScrollSettler()
    existingScrollSettler = settler
    return settler
  }

  /// 创建小数行收尾器。读写都走当前 surface，surface 销毁后全部变成空操作。
  private func makeScrollSettler() -> GhosttyScrollSettler {
    let settler = GhosttyScrollSettler()
    settler.readPosition = { [weak self] in self?.smoothScrollPosition() }
    settler.scrollRows = { [weak self] delta in
      guard let surface = self?.surface else { return }
      _ = ghostty_aster_surface_scroll_rows(surface, delta)
    }
    settler.snap = { [weak self] in
      guard let surface = self?.surface else { return }
      ghostty_aster_surface_snap_scroll_row(surface)
    }
    settler.makeDisplayLink = { [weak self] settler in
      self?.displayLink(
        target: settler, selector: #selector(GhosttyScrollSettler.displayLinkFired(_:)))
    }
    return settler
  }

  /// 视觉滚动位置：视口首行（从 scrollback 顶端算起）加小数行。
  func smoothScrollPosition() -> Double? {
    guard let surface, let info = bufferInfo() else { return nil }
    return Double(info.viewport_top) + ghostty_aster_surface_scroll_row_frac(surface)
  }

  /// 小数行让网格整体上移的距离（点）。命中测试与叠加层必须加上它，才能和渲染对齐；
  /// 此时视口下方还多画了一行，可见行数按 `viewport_rows + 1` 计算。
  func scrollRowOffset(cellHeight: CGFloat) -> CGFloat {
    guard let surface else { return 0 }
    return CGFloat(ghostty_aster_surface_scroll_row_frac(surface)) * cellHeight
  }

  /// 交给 Ghostty 的滚动量。Ghostty 把精确滚动量当作像素，AppKit 给的是点；
  /// 按 backing scale 换算后内容才跟手 1:1，否则 Retina 屏上只走手指一半的距离。
  /// 滚轮的离散格数不换算。
  func ghosttyScrollDeltas(for event: NSEvent) -> (x: Double, y: Double) {
    guard event.hasPreciseScrollingDeltas else {
      return (event.scrollingDeltaX, event.scrollingDeltaY)
    }
    let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 1
    return (event.scrollingDeltaX * scale, event.scrollingDeltaY * scale)
  }

  /// 精确滚动事件交给引擎之后调用：按手势阶段决定何时把小数行对齐到整行。
  func trackSmoothScrollGesture(_ event: NSEvent) {
    guard smoothScrollingEnabled, event.hasPreciseScrollingDeltas else { return }
    ghosttyScrollSettler.handle(
      .classify(phase: event.phase, momentumPhase: event.momentumPhase))
  }
}
