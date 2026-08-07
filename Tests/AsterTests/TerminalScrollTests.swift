import AppKit
import CoreGraphics
import Testing

@testable import Aster
@testable import AsterCore
@testable import SwiftTerm

@MainActor
private func populatedScrollView() -> AsterTerminalView {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 20, rows: 4)
  for index in 0..<12 {
    view.dataReceived(slice: Array("line-\(index)\r\n".utf8)[...])
  }
  return view
}

@MainActor
private func preciseScrollEvent(
  deltaY: Int32,
  units: CGScrollEventUnit = .pixel,
  phase: NSEvent.Phase = [],
  momentumPhase: NSEvent.Phase = []
) throws -> NSEvent {
  func coreGraphicsPhase(_ value: NSEvent.Phase) -> Int64 {
    switch value {
    case .began: 1
    case .changed: 2
    case .ended: 4
    case .cancelled: 8
    case .mayBegin: 128
    default: 0
    }
  }

  let event = try #require(
    CGEvent(
      scrollWheelEvent2Source: nil,
      units: units,
      wheelCount: 1,
      wheel1: deltaY,
      wheel2: 0,
      wheel3: 0
    ))
  event.setIntegerValueField(
    .scrollWheelEventScrollPhase,
    value: coreGraphicsPhase(phase)
  )
  event.setIntegerValueField(
    .scrollWheelEventMomentumPhase,
    value: coreGraphicsPhase(momentumPhase)
  )
  return try #require(NSEvent(cgEvent: event))
}

@Test("分页、首尾跳转与新输出回到底部")
@MainActor
func terminalScrollCommandsAndOutputSnap() {
  let view = populatedScrollView()
  let buffer = view.getTerminal().displayBuffer
  let initialBottom = max(0, buffer.lines.count - buffer.rows)
  #expect(buffer.yDisp == initialBottom)

  view.pageUp()
  #expect(buffer.yDisp < initialBottom)
  view.pageDown()
  #expect(buffer.yDisp == initialBottom)

  view.scrollToTop()
  #expect(buffer.yDisp == 0)
  view.scrollToBottom()
  #expect(buffer.yDisp == initialBottom)

  view.pageUp()
  view.dataReceived(slice: Array("new-output".utf8)[...])
  #expect(buffer.yDisp == max(0, buffer.lines.count - buffer.rows))
  #expect(view.viewportContentTranslationY == 0)
}

@Test("平滑滚动保留像素偏移并在手势结束时对齐行边界")
@MainActor
func smoothScrollUsesPixelOffsetAndSnapsToRows() {
  let view = populatedScrollView()
  let buffer = view.getTerminal().displayBuffer
  let cellHeight = view.caretFrame.height
  view.scrollTo(row: 2)
  view.smoothScrollEnabled = true

  view.scrollViewport(deltaY: -cellHeight / 2, precise: true)
  #expect(buffer.yDisp == 2)
  #expect(abs(view.viewportContentTranslationY - cellHeight / 2) < 0.001)

  view.scrollViewport(deltaY: 0, precise: true, gestureEnded: true)
  #expect(buffer.yDisp == 3)
  #expect(view.viewportContentTranslationY == 0)
}

@Test("触控板惯性结束才执行最终行吸附")
@MainActor
func smoothScrollWaitsForMomentumEnd() {
  #expect(
    !AsterTerminalView.scrollGestureEnded(phase: .ended, momentumPhase: .began)
  )
  #expect(
    AsterTerminalView.scrollGestureEnded(phase: [], momentumPhase: .ended)
  )
  #expect(
    AsterTerminalView.scrollGestureEnded(phase: .cancelled, momentumPhase: [])
  )
}

@Test("真实滚轮事件按 normal、alternate 与鼠标报告模式分流")
@MainActor
func scrollWheelRoutesRealEvents() throws {
  let normal = populatedScrollView()
  let normalBuffer = normal.getTerminal().displayBuffer
  normal.scrollTo(row: 2)
  let halfRow = max(1, Int32(normal.caretFrame.height / 2))
  let precise = try preciseScrollEvent(deltaY: -halfRow)
  #expect(precise.hasPreciseScrollingDeltas)
  normal.scrollWheel(with: precise)
  #expect(normalBuffer.yDisp == 2)
  #expect(normal.viewportContentTranslationY > 0)

  let ended = try preciseScrollEvent(deltaY: 0, phase: .ended)
  #expect(ended.phase == .ended)
  normal.scrollWheel(with: ended)
  #expect(normal.viewportContentTranslationY == 0)

  let alternate = populatedScrollView()
  alternate.dataReceived(slice: Array("\u{1B}[?1049h".utf8)[...])
  var alternateInput: [[UInt8]] = []
  alternate.onEncodedInput = { alternateInput.append(Array($0)) }
  let alternateUp = try preciseScrollEvent(deltaY: 2, units: .line)
  #expect(!alternateUp.hasPreciseScrollingDeltas)
  alternate.scrollWheel(with: alternateUp)
  #expect(alternate.getTerminal().isCurrentBufferAlternate)
  #expect(alternateInput == [[0x1B, 0x5B, 0x41], [0x1B, 0x5B, 0x41]])
  alternateInput.removeAll()
  alternate.scrollWheel(with: try preciseScrollEvent(deltaY: -1, units: .line))
  #expect(alternateInput == [[0x1B, 0x5B, 0x42]])

  let reporting = populatedScrollView()
  reporting.dataReceived(slice: Array("\u{1B}[?1000h".utf8)[...])
  let originalRow = reporting.getTerminal().displayBuffer.yDisp
  var mouseInput: [[UInt8]] = []
  reporting.onEncodedInput = { mouseInput.append(Array($0)) }
  reporting.scrollWheel(with: try preciseScrollEvent(deltaY: 2, units: .line))
  #expect(mouseInput.count == 2)
  #expect(mouseInput.allSatisfy { Array($0.prefix(4)) == [0x1B, 0x5B, 0x4D, 96] })
  mouseInput.removeAll()
  reporting.scrollWheel(with: try preciseScrollEvent(deltaY: -1, units: .line))
  #expect(mouseInput.count == 1)
  #expect(Array((mouseInput.first ?? []).prefix(4)) == [0x1B, 0x5B, 0x4D, 97])
  #expect(reporting.getTerminal().displayBuffer.yDisp == originalRow)
}

@Test("关闭平滑滚动后精确手势按整行累计")
@MainActor
func classicScrollAccumulatesWholeRows() {
  let view = populatedScrollView()
  let buffer = view.getTerminal().displayBuffer
  let cellHeight = view.caretFrame.height
  view.scrollTo(row: 2)
  view.smoothScrollEnabled = false

  view.scrollViewport(deltaY: -cellHeight * 0.4, precise: true)
  #expect(buffer.yDisp == 2)
  #expect(view.viewportContentTranslationY == 0)

  view.scrollViewport(deltaY: -cellHeight * 0.6, precise: true)
  #expect(buffer.yDisp == 3)
  #expect(view.viewportContentTranslationY == 0)
}

@Test("上下越界滚动按配置停靠且 alternate screen 禁用")
@MainActor
func scrollPastBoundariesHonorsModesAndAlternateScreen() {
  let view = populatedScrollView()
  let buffer = view.getTerminal().displayBuffer
  let cellHeight = view.caretFrame.height

  view.scrollPastLastLineMode = .lastLineWithContent
  view.scrollToBottom()
  view.scrollViewport(deltaY: -cellHeight * 20, precise: true, gestureEnded: true)
  #expect(buffer.yDisp == max(0, buffer.lines.count - buffer.rows))
  #expect(view.viewportContentTranslationY > 0)

  view.scrollPastFirstLineMode = .firstLineWithContent
  view.scrollToTop()
  view.scrollViewport(deltaY: cellHeight * 20, precise: true, gestureEnded: true)
  #expect(buffer.yDisp == 0)
  #expect(view.viewportContentTranslationY < 0)

  view.dataReceived(slice: Array("\u{1B}[?1049h".utf8)[...])
  view.scrollViewport(deltaY: -cellHeight * 20, precise: true)
  #expect(view.getTerminal().isCurrentBufferAlternate)
  #expect(view.viewportContentTranslationY == 0)
}

@Test("每种首尾停靠模式产生精确的字符行偏移")
@MainActor
func allScrollPastBoundaryModesUseExactStops() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 20, rows: 4)
  for index in 0..<11 {
    view.dataReceived(slice: Array("line-\(index)\r\n".utf8)[...])
  }
  view.dataReceived(slice: Array("last-content".utf8)[...])
  // 光标上移一行，使“最后内容行”“中部”和“光标行”三个停靠值互不相同。
  view.dataReceived(slice: Array("\u{1B}[1A".utf8)[...])
  let cellHeight = view.caretFrame.height

  func bottomOffset(_ mode: ScrollPastLastLineMode) -> CGFloat {
    view.scrollPastLastLineMode = mode
    view.scrollToBottom()
    view.scrollViewport(deltaY: -cellHeight * 20, precise: true, gestureEnded: true)
    return view.viewportContentTranslationY
  }

  #expect(bottomOffset(.disabled) == 0)
  #expect(bottomOffset(.lastLineWithContent) == cellHeight * 3)
  #expect(bottomOffset(.lastLineInMiddle) == cellHeight)
  #expect(bottomOffset(.cursorLine) == cellHeight * 2)

  func topOffset(_ mode: ScrollPastFirstLineMode) -> CGFloat {
    view.scrollPastFirstLineMode = mode
    view.scrollToTop()
    view.scrollViewport(deltaY: cellHeight * 20, precise: true, gestureEnded: true)
    return view.viewportContentTranslationY
  }

  #expect(topOffset(.disabled) == 0)
  #expect(topOffset(.firstLineWithContent) == -cellHeight * 3)
  #expect(topOffset(.firstLineInMiddle) == -cellHeight * 2)
  view.scrollPastLastLineMode = .disabled
  #expect(topOffset(.sameAsLastLine) == 0)
  view.scrollPastLastLineMode = .lastLineInMiddle
  #expect(topOffset(.sameAsLastLine) == -cellHeight * 2)
  view.scrollPastLastLineMode = .lastLineWithContent
  #expect(topOffset(.sameAsLastLine) == -cellHeight * 3)
  view.scrollPastLastLineMode = .cursorLine
  #expect(topOffset(.sameAsLastLine) == -cellHeight * 3)
}

@Test("Aster 滚动 responder 与配置映射驱动当前终端")
@MainActor
func asterScrollRespondersAndConfigurationMapping() {
  let view = populatedScrollView()
  let buffer = view.getTerminal().displayBuffer
  var controls = ControlConfiguration()
  controls.smoothScrolling = false
  controls.scrollPastLastLine = .cursorLine
  controls.scrollPastFirstLine = .sameAsLastLine

  view.applyScrollConfiguration(controls)
  #expect(!view.smoothScrollEnabled)
  #expect(view.scrollPastLastLineMode == .cursorLine)
  #expect(view.scrollPastFirstLineMode == .sameAsLastLine)

  view.scrollTerminalToTop(nil)
  #expect(buffer.yDisp == 0)
  view.scrollTerminalPageDown(nil)
  #expect(buffer.yDisp > 0)
  view.scrollTerminalToBottom(nil)
  #expect(buffer.yDisp == max(0, buffer.lines.count - buffer.rows))
  view.scrollTerminalPageUp(nil)
  #expect(buffer.yDisp < max(0, buffer.lines.count - buffer.rows))

  // 更严格的配置必须立即移除已有空白和半行，不能等下一次滚动事件。
  controls.smoothScrolling = true
  controls.scrollPastLastLine = .disabled
  view.applyScrollConfiguration(controls)
  view.scrollTo(row: 2)
  view.scrollViewport(deltaY: -view.caretFrame.height * 0.6, precise: true)
  #expect(view.viewportContentTranslationY > 0)
  controls.smoothScrolling = false
  view.applyScrollConfiguration(controls)
  #expect(view.viewportContentTranslationY == 0)
  #expect(buffer.yDisp == 3)

  controls.smoothScrolling = true
  controls.scrollPastLastLine = .lastLineWithContent
  view.applyScrollConfiguration(controls)
  view.scrollToBottom()
  view.scrollViewport(deltaY: -view.caretFrame.height * 20, precise: true)
  #expect(view.viewportContentTranslationY > 0)
  controls.smoothScrolling = false
  controls.scrollPastLastLine = .disabled
  view.applyScrollConfiguration(controls)
  #expect(view.viewportContentTranslationY == 0)
}

@Test("应用级命令输入同样清除选区并回到底部")
@MainActor
func terminalSessionInputsUseTerminalViewPolicies() throws {
  let suite = "TerminalScrollTests.\(UUID().uuidString)"
  let defaults = try #require(UserDefaults(suiteName: suite))
  defaults.removePersistentDomain(forName: suite)
  let preferences = AppPreferences(defaults: defaults)
  let session = TerminalSession(workingDirectory: "/tmp")
  let view = try #require(session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }
  view.resize(cols: 20, rows: 4)
  for index in 0..<12 {
    view.dataReceived(slice: Array("manual-\(index)\r\n".utf8)[...])
  }
  let buffer = view.getTerminal().displayBuffer

  func prepareHistorySelection() {
    view.selectAll()
    view.pageUp()
    #expect(view.selectionActive)
    #expect(buffer.yDisp < max(0, buffer.lines.count - buffer.rows))
  }

  prepareHistorySelection()
  session.typeText(" ")
  #expect(!view.selectionActive)
  #expect(buffer.yDisp == max(0, buffer.lines.count - buffer.rows))

  prepareHistorySelection()
  session.interrupt()
  #expect(!view.selectionActive)
  #expect(buffer.yDisp == max(0, buffer.lines.count - buffer.rows))

  prepareHistorySelection()
  session.send(":")
  #expect(!view.selectionActive)
  #expect(buffer.yDisp == max(0, buffer.lines.count - buffer.rows))
}
