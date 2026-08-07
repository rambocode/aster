import AppKit

/// 终端模式的轻量覆盖层。它不接受鼠标事件，也不持有业务状态；View 每次状态变化时
/// 直接重绘 pill、Vi 光标和 Hint 标签，避免重建整个工作区或干扰 SwiftTerm 响应链。
@MainActor
final class TerminalPaneModeHUD: NSView {
  struct HintLabel {
    let text: String
    let frame: NSRect
  }

  private let pill = NSTextField(labelWithString: "")
  private let keyHints = NSTextField(wrappingLabelWithString: "")
  private let cursor = NSView()
  private var hintLabels: [NSTextField] = []

  override init(frame frameRect: NSRect) {
    super.init(frame: frameRect)
    autoresizingMask = [.width, .height]

    pill.font = .monospacedSystemFont(ofSize: 10, weight: .bold)
    pill.textColor = .white
    pill.alignment = .center
    pill.wantsLayer = true
    pill.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.92).cgColor
    pill.layer?.cornerRadius = 8
    addSubview(pill)

    keyHints.font = .monospacedSystemFont(ofSize: 10, weight: .medium)
    keyHints.textColor = .white
    keyHints.maximumNumberOfLines = 3
    keyHints.wantsLayer = true
    keyHints.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.78).cgColor
    keyHints.layer?.cornerRadius = 7
    addSubview(keyHints)

    cursor.wantsLayer = true
    cursor.layer?.borderColor = NSColor.controlAccentColor.cgColor
    cursor.layer?.borderWidth = 2
    cursor.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
    addSubview(cursor)
    isHidden = true
  }

  required init?(coder: NSCoder) { nil }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  func update(
    pillText: String?,
    detail: String?,
    showsKeyHints: Bool,
    cursorFrame: NSRect?,
    hints: [HintLabel]
  ) {
    let hasContent = pillText != nil || cursorFrame != nil || !hints.isEmpty
    isHidden = !hasContent

    pill.isHidden = pillText == nil
    if let pillText {
      let fullText = detail.map { "\(pillText)  \($0)" } ?? pillText
      pill.stringValue = fullText
      let width = max(82, min(240, pill.intrinsicContentSize.width + 22))
      pill.frame = NSRect(x: bounds.maxX - width - 12, y: bounds.maxY - 34, width: width, height: 22)
    }

    keyHints.isHidden = !showsKeyHints
    if showsKeyHints {
      keyHints.stringValue = "h/j/k/l 移动   w/b/e 单词   0/$ 行首尾   v/V/⌃v 选择\nH/M/L 屏幕   gg/G 缓冲区   ⌃u/⌃d 半页   /? nN 查找   f 链接"
      keyHints.frame = NSRect(x: 12, y: 12, width: min(620, bounds.width - 24), height: 42)
    }

    cursor.isHidden = cursorFrame == nil
    if let cursorFrame { cursor.frame = cursorFrame }

    for label in hintLabels { label.removeFromSuperview() }
    hintLabels = hints.map { hint in
      let label = NSTextField(labelWithString: hint.text.uppercased())
      label.font = .monospacedSystemFont(ofSize: 9, weight: .bold)
      label.textColor = .black
      label.alignment = .center
      label.wantsLayer = true
      label.layer?.backgroundColor = NSColor.systemYellow.cgColor
      label.layer?.cornerRadius = 3
      label.frame = hint.frame
      addSubview(label)
      return label
    }
  }
}
