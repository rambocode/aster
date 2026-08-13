import AppKit
@preconcurrency import GhosttyKit

extension GhosttySurfaceView: @preconcurrency NSTextInputClient {
  /// libghostty 返回已经移除 content scale 的逻辑坐标：x 是 cursor 单元格中点，
  /// y 是以左上角为原点的单元格底边。Inline suggestion 必须使用这个底边转换后的
  /// 当前行框，不能按系统 IME 候选窗的矩形再向下偏移一格。
  var textCursorFrameInViewCoordinates: NSRect {
    guard let surface else { return .zero }
    var x = 0.0
    var y = 0.0
    var width = 0.0
    var height = 0.0
    ghostty_surface_ime_point(surface, &x, &y, &width, &height)
    return NSRect(
      x: x,
      y: bounds.height - y,
      width: width,
      height: height
    )
  }

  /// `NSTextInputClient` 的候选窗矩形位于 cursor 底边以下；它与同一行显示的 inline
  /// suggestion 不是同一个纵向锚点，但二者共享 libghostty 已去 scale 的原始几何。
  var imeFrameInViewCoordinates: NSRect {
    let cursorFrame = textCursorFrameInViewCoordinates
    return cursorFrame.offsetBy(dx: 0, dy: -cursorFrame.height)
  }

  func insertText(_ string: Any, replacementRange: NSRange) {
    let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    guard !text.isEmpty, !readOnly else { return }
    markedTextRange = NSRange(location: NSNotFound, length: 0)
    if let surface { ghostty_surface_preedit(surface, nil, 0) }

    if currentKeyEvent != nil {
      keyTextAccumulator.append(text)
    } else if let surface {
      onUserInput?()
      text.withCString {
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.text = $0
        _ = ghostty_surface_key(surface, key)
      }
    }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    guard let surface, !readOnly else { return }
    let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    markedTextRange =
      text.isEmpty
      ? NSRange(location: NSNotFound, length: 0)
      : NSRange(location: 0, length: text.utf16.count)
    selectedTextRange = selectedRange
    text.withCString { ghostty_surface_preedit(surface, $0, UInt(text.utf8.count)) }
  }

  func unmarkText() {
    markedTextRange = NSRange(location: NSNotFound, length: 0)
    if let surface { ghostty_surface_preedit(surface, nil, 0) }
  }

  func selectedRange() -> NSRange { selectedTextRange }
  func markedRange() -> NSRange { markedTextRange }
  func hasMarkedText() -> Bool { markedTextRange.location != NSNotFound }

  func attributedSubstring(
    forProposedRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSAttributedString? { nil }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    [.underlineStyle, .backgroundColor]
  }

  func characterIndex(for point: NSPoint) -> Int { NSNotFound }

  func firstRect(
    forCharacterRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSRect {
    guard surface != nil else { return .zero }
    let localFrame = imeFrameInViewCoordinates
    let windowPoint = convert(localFrame.origin, to: nil)
    let screenPoint = window?.convertPoint(toScreen: windowPoint) ?? localFrame.origin
    return NSRect(origin: screenPoint, size: localFrame.size)
  }
}
