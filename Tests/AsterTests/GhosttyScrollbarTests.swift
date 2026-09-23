// 验证终端滚动条的显示条件、滑块换算与拖动回调。
import AppKit
import Foundation
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

@Test("滚动条平时淡出且点击穿透，只有视口滚动才淡入，输出增长不闪出")
@MainActor
func ghosttyScrollbarRevealsOnlyOnViewportScroll() {
  let scrollbar = GhosttyScrollbar(frame: NSRect(x: 0, y: 0, width: 16, height: 300))
  scrollbar.apply(GhosttyScrollbarState(total: 200, offset: 160, length: 40))
  #expect(!scrollbar.isHidden)
  #expect(!scrollbar.isRevealed)
  #expect(scrollbar.hitTest(NSPoint(x: 8, y: 150)) == nil)
  // 停在底部时输出增长：total 与 offset 一起变，不算用户滚动。
  scrollbar.apply(GhosttyScrollbarState(total: 210, offset: 170, length: 40))
  #expect(!scrollbar.isRevealed)
  // 内容不变、视口上移才淡入。
  scrollbar.apply(GhosttyScrollbarState(total: 210, offset: 100, length: 40))
  #expect(scrollbar.isRevealed)
}

@Test("Ghostty 配置在右侧留出与滚动条同宽的槽位，文字不会进入滚动条下方")
@MainActor
func ghosttyConfigurationReservesScrollbarGutter() {
  let suite = "aster.tests.ghostty-scrollbar-gutter.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defer { defaults.removePersistentDomain(forName: suite) }
  let text = GhosttyConfiguration.make(preferences: AppPreferences(defaults: defaults))
  #expect(text.contains("window-padding-x = 0,\(Int(GhosttyScrollbar.reservedWidth))\n"))
  #expect(GhosttyScrollbar.width == GhosttyScrollbar.reservedWidth)
}
