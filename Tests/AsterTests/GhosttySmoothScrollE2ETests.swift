// 在真实 Ghostty surface 上验证像素滚动：停在小数行、命中测试跟随偏移、手势结束后对齐整行。
import AppKit
import CoreGraphics
import Foundation
@preconcurrency import GhosttyKit
import Testing

@testable import Aster

/// 独立 defaults suite，避免污染 .standard。
@MainActor
private func isolatedDefaults() -> UserDefaults {
  let suite = "GhosttySmoothScrollE2ETests.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  return defaults
}

private extension NSView {
  var smoothScrollDescendants: [NSView] {
    subviews + subviews.flatMap(\.smoothScrollDescendants)
  }
}

/// 构造一次触控板滚动事件。`phase` 取 CGScrollPhase 的原始值：1 开始、2 变化、4 结束。
private func trackpadScroll(deltaY: Double, phase: Int64) throws -> NSEvent {
  let event = try #require(
    CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 0, wheel2: 0, wheel3: 0))
  event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
  event.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
  event.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: deltaY)
  event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: deltaY)
  return try #require(NSEvent(cgEvent: event))
}

/// 在窗口里挂一个运行中的 Ghostty Pane，并写满 scrollback。
@MainActor
private func makeScrolledSurface(
  smoothScrolling: Bool
) async throws -> (TerminalSession, NSWindow, GhosttySurfaceView) {
  _ = NSApplication.shared
  let preferences = AppPreferences(defaults: isolatedDefaults())
  preferences.configuration.controls.autocompleteOnDeviceLearning = false
  preferences.configuration.controls.smoothScrolling = smoothScrolling
  // 拖选会触发 copy-on-select，测试不能改写用户的系统剪贴板。
  preferences.configuration.controls.copyOnSelect = false
  let session = TerminalSession(workingDirectory: "/tmp")
  let host = session.makeTerminalHost(preferences: preferences)
  let view = try #require(
    ([host] + host.smoothScrollDescendants).compactMap { $0 as? GhosttySurfaceView }.first)
  let window = NSWindow(
    contentRect: NSRect(x: 0, y: 0, width: 720, height: 420),
    styleMask: [.titled],
    backing: .buffered,
    defer: false
  )
  host.frame = window.contentView?.bounds ?? .zero
  host.autoresizingMask = [.width, .height]
  window.contentView?.addSubview(host)
  window.layoutIfNeeded()
  window.makeKeyAndOrderFront(nil)
  view.createSurface()
  for _ in 0..<100 where !view.isProcessRunning {
    try await Task.sleep(for: .milliseconds(20))
  }
  #expect(view.typeText("seq 1 400\n"))
  for _ in 0..<200 where (view.bufferInfo()?.screen_rows ?? 0) < 380 {
    try await Task.sleep(for: .milliseconds(20))
  }
  // 等输出与提示符都落定：视口基准必须在滚动前固定，否则后续输出会挪动「底部」。
  var stableRows: UInt64 = 0
  var stablePolls = 0
  for _ in 0..<100 where stablePolls < 5 {
    try await Task.sleep(for: .milliseconds(20))
    let rows = view.bufferInfo()?.screen_rows ?? 0
    stablePolls = rows == stableRows ? stablePolls + 1 : 0
    stableRows = rows
  }
  return (session, window, view)
}

/// 单元格高度（点）。
@MainActor
private func cellHeightPoints(_ view: GhosttySurfaceView) throws -> CGFloat {
  let surface = try #require(view.surface)
  let size = ghostty_surface_size(surface)
  let scale = view.window?.backingScaleFactor ?? 1
  return CGFloat(size.cell_height_px) / scale
}

@Test("真实 surface：触控板滚动停在小数行，点选按偏移落在画面对应的行，抬手后对齐整行")
@MainActor
func ghosttySmoothScrollFollowsPixelsAndSettlesOnRealSurface() async throws {
  let (session, window, view) = try await makeScrolledSurface(smoothScrolling: true)
  defer {
    window.orderOut(nil)
    session.stop(immediately: true)
  }
  let surface = try #require(view.surface)
  let start = try #require(view.bufferInfo())
  #expect(start.screen_rows >= 380)
  let bottom = Double(start.screen_rows - UInt64(start.viewport_rows))
  #expect(Double(start.viewport_top) == bottom)

  // 向上（查看历史）滚 2.4 行：视觉位置 bottom - 2.4，即整数行 bottom - 3、小数行 0.6。
  let cellHeight = try cellHeightPoints(view)
  let began = try trackpadScroll(deltaY: 0, phase: 1)
  #expect(began.phase == .began)
  view.scrollWheel(with: began)
  let changed = try trackpadScroll(deltaY: Double(cellHeight) * 2.4, phase: 2)
  #expect(changed.phase == .changed)
  #expect(changed.hasPreciseScrollingDeltas)
  view.scrollWheel(with: changed)

  let fraction = ghostty_aster_surface_scroll_row_frac(surface)
  let moved = try #require(view.bufferInfo())
  #expect(fraction > 0.55 && fraction < 0.65)
  #expect(Double(moved.viewport_top) == bottom - 3)
  #expect(view.scrollRowOffset(cellHeight: cellHeight) > 0)

  // 命中测试跟随渲染器已画出的帧；给 renderer 线程一点时间发布这一帧的小数行。
  try await Task.sleep(for: .milliseconds(150))

  // 指针在视口第 1.5 行处按下并横向拖动：网格上移 0.6 行后，画面上这里是第 2 行。
  let rowPointY = view.bounds.maxY - cellHeight * 1.5
  let downPoint = view.convert(NSPoint(x: 20, y: rowPointY), to: nil)
  let dragPoint = view.convert(NSPoint(x: 120, y: rowPointY), to: nil)
  let mouseDown = try #require(
    NSEvent.mouseEvent(
      with: .leftMouseDown, location: downPoint, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
  let mouseDragged = try #require(
    NSEvent.mouseEvent(
      with: .leftMouseDragged, location: dragPoint, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
  let mouseUp = try #require(
    NSEvent.mouseEvent(
      with: .leftMouseUp, location: dragPoint, modifierFlags: [], timestamp: 0,
      windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
  view.mouseDown(with: mouseDown)
  view.mouseDragged(with: mouseDragged)
  view.mouseUp(with: mouseUp)
  var selection = ghostty_aster_buffer_range_s()
  #expect(ghostty_aster_surface_get_selection(surface, &selection))
  #expect(selection.start.screen_row == moved.viewport_top + 2)
  ghostty_aster_surface_clear_selection(surface)

  // 抬手、没有惯性：稍后对齐到最近的整行（0.6 过半，进到下一行）。
  let ended = try trackpadScroll(deltaY: 0, phase: 4)
  #expect(ended.phase == .ended)
  view.scrollWheel(with: ended)
  for _ in 0..<60 where ghostty_aster_surface_scroll_row_frac(surface) != 0 {
    try await Task.sleep(for: .milliseconds(20))
  }
  let settled = try #require(view.bufferInfo())
  #expect(ghostty_aster_surface_scroll_row_frac(surface) == 0)
  #expect(Double(settled.viewport_top) == bottom - 2)
  #expect(!view.ghosttyScrollSettler.isSettling)
}

@Test("真实 surface：关闭平滑滚动后触控板仍按整行滚动，不留小数行")
@MainActor
func ghosttySmoothScrollDisabledKeepsWholeRows() async throws {
  let (session, window, view) = try await makeScrolledSurface(smoothScrolling: false)
  defer {
    window.orderOut(nil)
    session.stop(immediately: true)
  }
  let surface = try #require(view.surface)
  let start = try #require(view.bufferInfo())
  let cellHeight = try cellHeightPoints(view)
  view.scrollWheel(with: try trackpadScroll(deltaY: 0, phase: 1))
  view.scrollWheel(with: try trackpadScroll(deltaY: Double(cellHeight) * 2.4, phase: 2))
  let moved = try #require(view.bufferInfo())
  #expect(ghostty_aster_surface_scroll_row_frac(surface) == 0)
  // 按行模式截断到 2 行，余量留待下一次事件累积。
  #expect(moved.viewport_top == start.viewport_top - 2)
}
