// 验证终端滚动条的显示条件、滑块换算与拖动回调。
import AppKit
import Testing

@testable import Aster

@Test("内容不足一屏时滚动条隐藏，超出后才显示")
@MainActor
func ghosttyScrollbarShowsOnlyWhenContentOverflows() {
  let scrollbar = GhosttyScrollbar(frame: NSRect(x: 0, y: 0, width: 16, height: 300))
  #expect(scrollbar.isHidden)
  scrollbar.apply(GhosttyScrollbarState(total: 40, offset: 0, length: 40))
  #expect(scrollbar.isHidden)
  scrollbar.apply(GhosttyScrollbarState(total: 200, offset: 160, length: 40))
  #expect(!scrollbar.isHidden)
  #expect(scrollbar.knobProportion == 0.2)
  #expect(scrollbar.doubleValue == 1)
  // 回到 alternate screen 之类只有一屏的状态时再次隐藏。
  scrollbar.apply(GhosttyScrollbarState(total: 40, offset: 0, length: 40))
  #expect(scrollbar.isHidden)
}

@Test("滑块位置与视口首行双向换算，越界时夹到有效范围")
func ghosttyScrollbarStateMapsPositionToRow() {
  let state = GhosttyScrollbarState(total: 140, offset: 50, length: 40)
  #expect(state.maximumOffset == 100)
  #expect(state.position == 0.5)
  #expect(state.row(at: 0) == 0)
  #expect(state.row(at: 0.5) == 50)
  #expect(state.row(at: 1) == 100)
  #expect(state.row(at: 1.7) == 100)
  #expect(state.row(at: -1) == 0)
  let empty = GhosttyScrollbarState(total: 0, offset: 0, length: 0)
  #expect(!empty.isScrollable)
  #expect(empty.knobProportion == 1)
}

@Test("终端视图收到滚动条上报后挂上贴右边缘的滚动条")
@MainActor
func ghosttySurfaceMountsScrollbarOnReport() {
  let view = GhosttySurfaceView(workingDirectory: "/tmp", environment: [:], configurationText: "")
  view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
  view.handleScrollbar(GhosttyScrollbarState(total: 500, offset: 0, length: 30))
  let scrollbar = view.ghosttyScrollbar
  #expect(scrollbar.superview === view)
  #expect(!scrollbar.isHidden)
  #expect(scrollbar.frame.maxX == view.bounds.maxX)
  #expect(scrollbar.frame.height == view.bounds.height)
  #expect(scrollbar.doubleValue == 0)
}
