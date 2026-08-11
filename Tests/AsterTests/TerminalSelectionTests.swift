import AppKit
import Testing

@testable import Aster
@testable import AsterCore
@testable import SwiftTerm

@MainActor
private func mouseEvent(
  _ type: NSEvent.EventType,
  at point: NSPoint,
  modifiers: NSEvent.ModifierFlags = []
) throws -> NSEvent {
  try #require(
    NSEvent.mouseEvent(
      with: type,
      location: point,
      modifierFlags: modifiers,
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ))
}

@Test("Shift+左右箭头从终端光标按字符扩展并可反向收拢")
@MainActor
func keyboardSelectionExtendsByCharacterFromCursor() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.dataReceived(slice: Array("abcd".utf8)[...])

  #expect(view.extendSelection(.left, rectangular: false))
  #expect(view.getSelection() == "d")
  #expect(view.extendSelection(.left, rectangular: false))
  #expect(view.getSelection() == "cd")
  #expect(view.extendSelection(.right, rectangular: false))
  #expect(view.getSelection() == "d")
  #expect(view.extendSelection(.right, rectangular: false))
  #expect(!view.selectionActive)
}

@Test("Option+Shift+箭头生成逐行矩形选区")
@MainActor
func keyboardSelectionSupportsRectangularRanges() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.dataReceived(slice: Array("abcd\r\nwxyz".utf8)[...])

  #expect(view.extendSelection(.left, rectangular: true))
  #expect(view.extendSelection(.up, rectangular: true))
  #expect(view.getSelection() == "d\nz")
}

@Test("矩形复制把短行尾部空单元格转换为空格")
@MainActor
func rectangularSelectionNormalizesEmptyCells() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 10, rows: 2)
  view.dataReceived(slice: Array("a\r\nb".utf8)[...])
  view.selection.setSelection(
    start: Position(col: 0, row: 0),
    end: Position(col: 3, row: 1)
  )
  view.selection.preparePointerSelection(rectangular: true)

  #expect(view.getSelection() == "a  \nb  ")
  #expect(!view.getSelection()!.contains("\u{0}"))
}

@Test("程序化矩形选区保留矩形语义并按列复制")
@MainActor
func programmaticRectangularSelectionCopiesColumns() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 12, rows: 3)
  view.dataReceived(slice: Array("abcd\r\nefgh\r\n".utf8)[...])

  view.setSelection(
    start: Position(col: 1, row: 0),
    end: Position(col: 3, row: 1),
    rectangular: true
  )

  #expect(view.isSelectionRectangular)
  #expect(view.getSelection() == "bc\nfg")
}

@Test("输入时是否清除选区由终端设置控制")
@MainActor
func typingSelectionCleanupIsConfigurable() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.dataReceived(slice: Array("abc".utf8)[...])
  let key = try #require(
    NSEvent.keyEvent(
      with: .keyDown,
      location: .zero,
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      characters: "x",
      charactersIgnoringModifiers: "x",
      isARepeat: false,
      keyCode: 7
    ))

  view.clearSelectionOnTyping = false
  view.selectAll()
  view.keyDown(with: key)
  #expect(view.selectionActive)

  view.clearSelectionOnTyping = true
  view.keyDown(with: key)
  #expect(!view.selectionActive)
}

@Test("鼠标拖选从按下单元格开始且 Shift 点击继续扩展")
@MainActor
func pointerSelectionPreservesMouseDownAnchor() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 10, rows: 2)
  view.dataReceived(slice: Array("abcdef".utf8)[...])
  let cellWidth = view.caretFrame.width
  let cellHeight = view.caretFrame.height
  let rowCenter = view.bounds.height - cellHeight / 2
  let startPoint = NSPoint(x: cellWidth / 2, y: rowCenter)
  let dragPoint = NSPoint(x: cellWidth * 3.5, y: rowCenter)
  let shiftPoint = NSPoint(x: cellWidth * 5.5, y: rowCenter)

  view.mouseDown(with: try mouseEvent(.leftMouseDown, at: startPoint))
  view.mouseDragged(with: try mouseEvent(.leftMouseDragged, at: dragPoint))
  #expect(view.getSelection() == "abc")

  view.mouseDown(with: try mouseEvent(.leftMouseDown, at: shiftPoint, modifiers: [.shift]))
  #expect(view.getSelection() == "abcde")
}

@Test("鼠标报告手势锁定路由且 Option 不泄漏终端事件")
@MainActor
func mouseGestureRoutingPreventsPartialReports() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.dataReceived(slice: Array("abcd\r\nwxyz".utf8)[...])
  view.dataReceived(slice: Array("\u{1B}[?1000h".utf8)[...])
  view.allowMouseReporting = true
  var encodedInput: [UInt8] = []
  view.onEncodedInput = { encodedInput.append(contentsOf: $0) }

  let start = try #require(
    NSEvent.mouseEvent(
      with: .leftMouseDown,
      location: NSPoint(x: 1, y: 1),
      modifierFlags: [.option],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 1,
      clickCount: 1,
      pressure: 1
    ))
  let drag = try #require(
    NSEvent.mouseEvent(
      with: .leftMouseDragged,
      location: NSPoint(x: 40, y: 40),
      // 松开 Option 不得把已经归属原生选择的手势切回终端报告。
      modifierFlags: [],
      timestamp: 0,
      windowNumber: 0,
      context: nil,
      eventNumber: 2,
      clickCount: 1,
      pressure: 1
    ))
  let up = try mouseEvent(.leftMouseUp, at: NSPoint(x: 40, y: 40))

  view.mouseDown(with: start)
  view.mouseDragged(with: drag)
  view.mouseUp(with: up)
  #expect(view.selectionActive)
  #expect(view.isSelectionRectangular)
  #expect(encodedInput.isEmpty)

  // 反向修改修饰键也不能吞掉 release：无修饰键按下后，整个手势归终端所有。
  encodedInput.removeAll()
  view.mouseDown(with: try mouseEvent(.leftMouseDown, at: NSPoint(x: 1, y: 1)))
  let bytesAfterPress = encodedInput.count
  view.mouseDragged(
    with: try mouseEvent(.leftMouseDragged, at: NSPoint(x: 40, y: 40), modifiers: [.option]))
  view.mouseUp(
    with: try mouseEvent(.leftMouseUp, at: NSPoint(x: 40, y: 40), modifiers: [.option]))
  #expect(bytesAfterPress > 0)
  #expect(encodedInput.count > bytesAfterPress)

  // Shift 默认绕过报告；程序用 XTSHIFTESCAPE 捕获 Shift 后则完整报告该手势。
  view.dataReceived(slice: Array("\u{1B}[>0s".utf8)[...])
  encodedInput.removeAll()
  view.mouseDown(
    with: try mouseEvent(.leftMouseDown, at: NSPoint(x: 1, y: 1), modifiers: [.shift]))
  view.mouseUp(
    with: try mouseEvent(.leftMouseUp, at: NSPoint(x: 1, y: 1), modifiers: [.shift]))
  #expect(encodedInput.isEmpty)

  view.dataReceived(slice: Array("\u{1B}[>1s".utf8)[...])
  view.mouseDown(
    with: try mouseEvent(.leftMouseDown, at: NSPoint(x: 1, y: 1), modifiers: [.shift]))
  view.mouseUp(
    with: try mouseEvent(.leftMouseUp, at: NSPoint(x: 1, y: 1), modifiers: [.shift]))
  #expect(!encodedInput.isEmpty)
}

@Test("鼠标报告开启时 Command 点击链接仍由本地完整处理")
@MainActor
func commandClickLinkBypassesMouseReporting() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 20, rows: 2)
  view.linkHighlightMode = .alwaysWithModifier
  view.dataReceived(
    slice: Array("\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\".utf8)[...])
  view.dataReceived(slice: Array("\u{1B}[?1000h".utf8)[...])
  var encodedInput: [UInt8] = []
  var opened: [(String, DetectedTargetSource)] = []
  view.onEncodedInput = { encodedInput.append(contentsOf: $0) }
  view.onRequestOpenTarget = { opened.append(($0, $1)) }
  let payload = view.getTerminal().getCharData(col: 0, row: 0)?.getPayload() as? String
  #expect(payload != nil)
  #expect(payload.flatMap(OSC8Payload.link(from:)) == "https://example.com")
  let pixelSize = try #require(view.cellSizeInPixels(source: view.getTerminal()))
  let scale = max(NSScreen.main?.backingScaleFactor ?? 1, 1)
  let point = NSPoint(
    x: CGFloat(pixelSize.width) / scale / 2,
    y: view.bounds.height - CGFloat(pixelSize.height) / scale / 2
  )

  view.mouseDown(
    with: try mouseEvent(.leftMouseDown, at: point, modifiers: [.command]))
  view.mouseUp(
    with: try mouseEvent(.leftMouseUp, at: point, modifiers: [.command]))

  #expect(encodedInput.isEmpty)
  #expect(opened.count == 1)
  #expect(opened.first?.0 == "https://example.com")
  #expect(opened.first?.1 == .osc8)
}

@Test("相对本地文件链接预览显示可实际打开的完整路径")
@MainActor
func relativeFileLinkPreviewUsesResolvedAbsolutePath() throws {
  let suite = "RelativeFileLinkPreview.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  let preferences = AppPreferences(defaults: defaults)
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-link-preview-\(UUID().uuidString)", isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }
  let session = TerminalSession(workingDirectory: directory.path)
  let view = try #require(session.makeTerminalView(preferences: preferences) as? AsterTerminalView)
  defer { session.stop(immediately: true) }
  view.resize(cols: 40, rows: 2)
  view.dataReceived(slice: Array("README.md".utf8)[...])

  view.reportLink(at: Position(col: 0, row: 0))

  #expect(
    view.urlPreview?.stringValue
      == directory.appendingPathComponent("README.md").path
  )
}

@Test("终端底部链接预览使用独立于主题的明暗反转浮层")
@MainActor
func linkPreviewUsesFixedAppearanceAwareBadge() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.appearance = NSAppearance(named: .aqua)
  // 故意使用高饱和主题色，证明链接浮层没有继续复用终端前景/背景。
  view.nativeForegroundColor = .systemPink
  view.nativeBackgroundColor = .systemCyan
  view.resize(cols: 80, rows: 24)
  view.dataReceived(slice: Array("https://example.test/a/very/long/path".utf8)[...])
  view.reportLink(at: Position(col: 0, row: 0))

  let label = try #require(view.urlPreview)
  let badge = try #require(label.superview)
  try #require(badge !== view, "链接文字必须位于独立圆角背景容器内")
  #expect(abs(badge.frame.minX - 16) < 0.5)
  #expect(abs(badge.frame.minY) < 0.5)
  #expect(abs(badge.frame.height - 52) < 0.5)
  #expect(abs((badge.layer?.cornerRadius ?? 0) - 12) < 0.5)

  func rgba(_ color: NSColor?) throws -> (CGFloat, CGFloat, CGFloat, CGFloat) {
    let rgb = try #require(color?.usingColorSpace(.deviceRGB))
    return (rgb.redComponent, rgb.greenComponent, rgb.blueComponent, rgb.alphaComponent)
  }

  let lightBackground = try rgba(badge.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
  let lightText = try rgba(label.textColor)
  #expect(max(lightBackground.0, lightBackground.1, lightBackground.2) < 0.05)
  #expect(abs(lightBackground.3 - 0.78) < 0.02)
  #expect(min(lightText.0, lightText.1, lightText.2) > 0.95)
  #expect(abs(lightText.3 - 0.96) < 0.02)

  badge.appearance = NSAppearance(named: .darkAqua)
  let darkBackground = try rgba(badge.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
  let darkText = try rgba(label.textColor)
  #expect(min(darkBackground.0, darkBackground.1, darkBackground.2) > 0.95)
  #expect(abs(darkBackground.3 - 0.82) < 0.02)
  #expect(max(darkText.0, darkText.1, darkText.2) < 0.05)
  #expect(abs(darkText.3 - 0.90) < 0.02)
}

@Test("终端链接使用连续实线下划线")
@MainActor
func terminalLinksUseSolidUnderline() throws {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  let attributes = try #require(view.getAttributes(.empty, withUrl: true))

  #expect(
    attributes[SwiftTermUnderlineStyleKey] as? Int
      == Int(UnderlineStyle.single.rawValue)
  )
}

@Test("可点击链接使用手形指针且非链接保持文本指针")
@MainActor
func clickableTerminalLinkUsesPointingHandCursor() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 40, rows: 2)
  view.linkReporting = .implicit
  view.linkHighlightMode = .hoverWithModifier
  view.dataReceived(
    slice: Array("\u{1B}]8;;https://example.com\u{1B}\\link\u{1B}]8;;\u{1B}\\ plain".utf8)[...])
  let linkPosition = Position(col: 0, row: 0)
  view.updateHoverLink(at: linkPosition, commandOverride: true)

  #expect(view.shouldUseLinkPointer(at: linkPosition, hasCommandModifier: true))
  #expect(!view.shouldUseLinkPointer(at: linkPosition, hasCommandModifier: false))
  #expect(!view.shouldUseLinkPointer(at: Position(col: 8, row: 0), hasCommandModifier: true))

  view.linkReporting = .none
  #expect(!view.shouldUseLinkPointer(at: linkPosition, hasCommandModifier: true))
}

@Test("Aster responder 动作按设置驱动线性与矩形扩选")
@MainActor
func asterSelectionRespondersHonorConfiguration() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.dataReceived(slice: Array("abcd".utf8)[...])
  let item = NSMenuItem(
    title: "向左扩展",
    action: #selector(AsterTerminalView.extendSelectionLeft(_:)),
    keyEquivalent: ""
  )

  view.shiftArrowSelectionEnabled = false
  #expect(!view.validateUserInterfaceItem(item))

  view.shiftArrowSelectionEnabled = true
  #expect(view.validateUserInterfaceItem(item))
  view.extendSelectionLeft(nil)
  #expect(view.getSelection() == "d")

  view.selectNone()
  view.extendRectangularSelectionLeft(nil)
  #expect(view.getSelection() == "d")
  #expect(view.isSelectionRectangular)

  // 收拢到原锚点后再向反方向扩展，必须保留锚点并选中另一侧字符。
  let reverse = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  reverse.dataReceived(slice: Array("abcd\u{1B}[2D".utf8)[...])
  reverse.extendSelectionLeft(nil)
  #expect(reverse.getSelection() == "b")
  reverse.extendSelectionRight(nil)
  #expect(!reverse.selectionActive)
  reverse.extendSelectionRight(nil)
  #expect(reverse.selectionActive)
  #expect(reverse.getSelection() == "c")
}

@Test("Aster 四个方向 responder 映射到正确选区焦点")
@MainActor
func asterDirectionalSelectionRespondersMapCorrectly() {
  func makeView() -> AsterTerminalView {
    let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
    view.resize(cols: 8, rows: 3)
    view.dataReceived(slice: Array("abc\r\ndef\r\nghi".utf8)[...])
    return view
  }

  let left = makeView()
  let leftBuffer = left.getTerminal().displayBuffer
  let leftCursor = Position(col: leftBuffer.x, row: leftBuffer.yBase + leftBuffer.y)
  left.extendSelectionLeft(nil)
  #expect(left.selectionActive)
  #expect(left.selection.end == Position(col: leftCursor.col - 1, row: leftCursor.row))

  let right = makeView()
  let rightBuffer = right.getTerminal().displayBuffer
  let rightCursor = Position(col: rightBuffer.x, row: rightBuffer.yBase + rightBuffer.y)
  right.extendSelectionRight(nil)
  #expect(right.selectionActive)
  #expect(right.selection.end == Position(col: rightCursor.col + 1, row: rightCursor.row))

  let up = makeView()
  let upBuffer = up.getTerminal().displayBuffer
  let upCursor = Position(col: upBuffer.x, row: upBuffer.yBase + upBuffer.y)
  up.extendSelectionUp(nil)
  #expect(up.selectionActive)
  #expect(up.selection.end == Position(col: upCursor.col, row: upCursor.row - 1))

  let down = makeView()
  down.dataReceived(slice: Array("\u{1B}[1A".utf8)[...])
  let downBuffer = down.getTerminal().displayBuffer
  let downCursor = Position(col: downBuffer.x, row: downBuffer.yBase + downBuffer.y)
  down.extendSelectionDown(nil)
  #expect(down.selectionActive)
  #expect(down.selection.end == Position(col: downCursor.col, row: downCursor.row + 1))
}

@Test("Selection 与 Scroll 菜单注册精确功能键和修饰符")
@MainActor
func terminalMenusExposeExactKeyboardContracts() throws {
  func functionKey(_ value: Int) -> String {
    String(Character(UnicodeScalar(UInt32(value))!))
  }

  let delegate = AsterAppDelegate()
  let selection = try #require(delegate.selectionMenuItem().submenu)
  let directions: [(Selector, Selector, Int)] = [
    (#selector(AsterTerminalView.extendSelectionLeft(_:)),
      #selector(AsterTerminalView.extendRectangularSelectionLeft(_:)), NSLeftArrowFunctionKey),
    (#selector(AsterTerminalView.extendSelectionRight(_:)),
      #selector(AsterTerminalView.extendRectangularSelectionRight(_:)), NSRightArrowFunctionKey),
    (#selector(AsterTerminalView.extendSelectionUp(_:)),
      #selector(AsterTerminalView.extendRectangularSelectionUp(_:)), NSUpArrowFunctionKey),
    (#selector(AsterTerminalView.extendSelectionDown(_:)),
      #selector(AsterTerminalView.extendRectangularSelectionDown(_:)), NSDownArrowFunctionKey),
  ]
  #expect(selection.items.count == directions.count * 2)
  for (index, direction) in directions.enumerated() {
    let linear = selection.items[index * 2]
    let rectangular = selection.items[index * 2 + 1]
    #expect(linear.action == direction.0)
    #expect(linear.keyEquivalent == functionKey(direction.2))
    #expect(linear.keyEquivalentModifierMask == [.shift])
    #expect(rectangular.action == direction.1)
    #expect(rectangular.keyEquivalent == functionKey(direction.2))
    #expect(rectangular.keyEquivalentModifierMask == [.shift, .option])
  }

  let scroll = try #require(delegate.terminalScrollMenuItem().submenu)
  let scrollContracts: [(Int, Selector, Int)] = [
    (0, #selector(AsterTerminalView.scrollTerminalPageUp(_:)), NSPageUpFunctionKey),
    (1, #selector(AsterTerminalView.scrollTerminalPageDown(_:)), NSPageDownFunctionKey),
    (3, #selector(AsterTerminalView.scrollTerminalToTop(_:)), NSHomeFunctionKey),
    (4, #selector(AsterTerminalView.scrollTerminalToBottom(_:)), NSEndFunctionKey),
  ]
  #expect(scroll.items.count == 8)
  #expect(scroll.items[2].isSeparatorItem)
  for (index, action, key) in scrollContracts {
    #expect(scroll.items[index].action == action)
    #expect(scroll.items[index].keyEquivalent == functionKey(key))
    #expect(scroll.items[index].keyEquivalentModifierMask == [.shift])
  }
  #expect(scroll.items[5].isSeparatorItem)
  #expect(scroll.items[6].action == #selector(AsterTerminalView.scrollToPreviousCommand(_:)))
  #expect(scroll.items[6].keyEquivalent == functionKey(NSPageUpFunctionKey))
  #expect(scroll.items[6].keyEquivalentModifierMask == [.command])
  #expect(scroll.items[7].action == #selector(AsterTerminalView.scrollToNextCommand(_:)))
  #expect(scroll.items[7].keyEquivalent == functionKey(NSPageDownFunctionKey))
  #expect(scroll.items[7].keyEquivalentModifierMask == [.command])
}

@Test("键盘选区覆盖四个方向、跨行和缓冲区边界")
@MainActor
func keyboardSelectionCoversDirectionalBoundaries() {
  let view = AsterTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 320))
  view.resize(cols: 4, rows: 3)
  view.dataReceived(slice: Array("a\r\nb\r\nc".utf8)[...])

  view.selectNone()
  #expect(view.selection.extendFromCursor(Position(col: 0, row: 1), direction: .left, rectangular: false))
  #expect(view.selection.end == Position(col: 3, row: 0))

  view.selectNone()
  #expect(view.selection.extendFromCursor(Position(col: 3, row: 1), direction: .right, rectangular: false))
  #expect(view.selection.end == Position(col: 0, row: 2))

  view.selectNone()
  #expect(view.selection.extendFromCursor(Position(col: 2, row: 1), direction: .up, rectangular: false))
  #expect(view.selection.end == Position(col: 2, row: 0))

  view.selectNone()
  #expect(view.selection.extendFromCursor(Position(col: 2, row: 1), direction: .down, rectangular: false))
  #expect(view.selection.end == Position(col: 2, row: 2))

  view.selectNone()
  #expect(!view.selection.extendFromCursor(Position(col: 0, row: 0), direction: .left, rectangular: false))
  #expect(!view.selectionActive)
  #expect(!view.selection.extendFromCursor(Position(col: 2, row: 0), direction: .up, rectangular: false))
  #expect(!view.selectionActive)

  let lastRow = view.getTerminal().displayBuffer.lines.count - 1
  view.selectNone()
  #expect(!view.selection.extendFromCursor(
    Position(col: 3, row: lastRow), direction: .right, rectangular: false))
  #expect(!view.selection.extendFromCursor(
    Position(col: 2, row: lastRow), direction: .down, rectangular: false))
}
