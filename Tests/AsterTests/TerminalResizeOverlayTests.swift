import AppKit
import Foundation
import Testing

@testable import Aster

/// 验证网格尺寸提示:显示文本、连续调整的顺延与收起,以及首次/稳定期的抑制规则。

@Test("show 显示列 x 行并保持可见")
@MainActor
func resizeOverlayShowsGridSize() {
  let overlay = TerminalResizeOverlay(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
  #expect(overlay.isHidden)

  overlay.show(columns: 75, rows: 24)

  #expect(!overlay.isHidden)
  #expect(overlay.displayedText == "75 x 24")
  #expect(overlay.alphaValue == 1)
}

@Test("连续调整更新文本,不会因为上一次淡出而变暗")
@MainActor
func resizeOverlayKeepsOpaqueAcrossConsecutiveShows() {
  let overlay = TerminalResizeOverlay(frame: NSRect(x: 0, y: 0, width: 400, height: 300))

  overlay.show(columns: 80, rows: 24)
  overlay.alphaValue = 0.3  // 模拟淡出动画进行到一半
  overlay.show(columns: 75, rows: 24)

  #expect(overlay.displayedText == "75 x 24")
  #expect(overlay.alphaValue == 1)
  #expect(!overlay.isHidden)
}

@Test("hideImmediately 立刻收起并复位透明度")
@MainActor
func resizeOverlayHidesImmediately() {
  let overlay = TerminalResizeOverlay(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
  overlay.show(columns: 75, rows: 24)

  overlay.hideImmediately()

  #expect(overlay.isHidden)
  #expect(overlay.alphaValue == 1)
}

@Test("提示层不接收鼠标事件")
@MainActor
func resizeOverlayIsTransparentToMouse() {
  let overlay = TerminalResizeOverlay(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
  overlay.show(columns: 75, rows: 24)

  #expect(overlay.hitTest(NSPoint(x: 200, y: 150)) == nil)
}

@Test("首次网格与稳定期内的变化都不提示")
@MainActor
func resizeAnnouncerSuppressesInitialSettling() {
  var announcer = TerminalResizeAnnouncer()
  let start = Date()

  #expect(announcer.shouldAnnounce(columns: 80, rows: 24, now: start) == false)
  #expect(announcer.shouldAnnounce(columns: 75, rows: 24, now: start.addingTimeInterval(0.1)) == false)
  #expect(announcer.shouldAnnounce(columns: 70, rows: 24, now: start.addingTimeInterval(0.4)) == false)
}

@Test("稳定期之后的行列变化才提示,重复尺寸不提示")
@MainActor
func resizeAnnouncerReportsRealChanges() {
  var announcer = TerminalResizeAnnouncer()
  let start = Date()
  _ = announcer.shouldAnnounce(columns: 80, rows: 24, now: start)
  let settled = start.addingTimeInterval(TerminalResizeAnnouncer.settleInterval)

  #expect(announcer.shouldAnnounce(columns: 80, rows: 24, now: settled) == false)
  #expect(announcer.shouldAnnounce(columns: 75, rows: 24, now: settled) == true)
  #expect(announcer.shouldAnnounce(columns: 75, rows: 24, now: settled) == false)
  #expect(announcer.shouldAnnounce(columns: 75, rows: 20, now: settled) == true)
}
