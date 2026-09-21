// 终端 Pane 滚动条的挂载与位置同步。
import AppKit
@preconcurrency import GhosttyKit

extension GhosttySurfaceView {
  // MARK: - Scrollbar

  /// 创建贴右边缘、随 Pane 高度伸缩的滚动条；拖动结果直接滚动 Ghostty 视口。
  func makeGhosttyScrollbar() -> GhosttyScrollbar {
    let width = GhosttyScrollbar.width
    let scrollbar = GhosttyScrollbar(
      frame: NSRect(x: bounds.maxX - width, y: 0, width: width, height: bounds.height))
    scrollbar.autoresizingMask = [.minXMargin, .height]
    scrollbar.onScrollToRow = { [weak self] row in
      guard let self, let surface = self.surface else { return }
      _ = ghostty_aster_surface_scroll_to_row(surface, row)
    }
    return scrollbar
  }

  /// 应用 libghostty 上报的 scrollback 位置。内容不足一屏时滚动条保持隐藏。
  func handleScrollbar(_ state: GhosttyScrollbarState) {
    let scrollbar = ghosttyScrollbar
    if scrollbar.superview !== self {
      // 懒创建时 bounds 可能还是零尺寸，挂载前按当前尺寸重新定位。
      let width = GhosttyScrollbar.width
      scrollbar.frame = NSRect(x: bounds.maxX - width, y: 0, width: width, height: bounds.height)
      addSubview(scrollbar, positioned: .above, relativeTo: nil)
    }
    scrollbar.apply(state)
  }
}
