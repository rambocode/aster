// IME bridge adapted from umputun/agterm and thdxg/macterm (MIT).

import AppKit
import GhosttyKit

// MARK: - NSTextInputClient

extension GhosttySurfaceView: NSTextInputClient {
  func insertText(_ string: Any, replacementRange: NSRange) {
    let text = (string as? String) ?? (string as? NSAttributedString)?.string ?? ""
    guard !text.isEmpty else { return }
    markedTextRange = NSRange(location: NSNotFound, length: 0)
    if let surface { ghostty_surface_preedit(surface, nil, 0) }

    if currentKeyEvent != nil {
      keyTextAccumulator.append(text)
    } else if let surface {
      text.withCString {
        var key = ghostty_input_key_s()
        key.action = GHOSTTY_ACTION_PRESS
        key.text = $0
        _ = ghostty_surface_key(surface, key)
      }
    }
  }

  func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
    guard let surface else { return }
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
  ) -> NSAttributedString? {
    nil
  }

  func validAttributesForMarkedText() -> [NSAttributedString.Key] {
    [.underlineStyle, .backgroundColor]
  }

  func characterIndex(for point: NSPoint) -> Int { NSNotFound }

  func firstRect(
    forCharacterRange range: NSRange,
    actualRange: NSRangePointer?
  ) -> NSRect {
    guard let surface else { return .zero }
    var x = 0.0
    var y = 0.0
    var width = 0.0
    var height = 0.0
    ghostty_surface_ime_point(surface, &x, &y, &width, &height)
    let viewPoint = NSPoint(x: x, y: bounds.height - y)
    let screenPoint = window?.convertPoint(toScreen: convert(viewPoint, to: nil)) ?? viewPoint
    return NSRect(x: screenPoint.x, y: screenPoint.y - height, width: width, height: height)
  }
}
