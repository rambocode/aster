import AppKit
import QuartzCore
import Testing

@testable import Aster

/// 验证 Ghostty 路径的链接预览徽章:mouse_over_link 显示/清除、格式化器与开关语义。
@MainActor
private func makeView() -> GhosttySurfaceView {
  GhosttySurfaceView(
    workingDirectory: NSHomeDirectory(),
    environment: [:],
    configurationText: ""
  )
}

@Test("mouse_over_link 显示格式化后的预览,空 URL 清除")
@MainActor
func ghosttyLinkPreviewShowsAndClears() throws {
  let view = makeView()
  view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
  view.handleCommandModifierChange(pressed: true)
  view.linkPreviewFormatter = { raw in "/expanded/\(raw)" }

  view.handleMouseOverLink("src/main.swift")
  #expect(view.linkPreviewText == "/expanded/src/main.swift")

  // 空字符串表示指针离开链接,预览必须移除;重复清除保持幂等。
  view.handleMouseOverLink("")
  #expect(view.linkPreviewText == nil)
  view.handleMouseOverLink("")
  #expect(view.linkPreviewText == nil)
}

@Test("关闭链接预览后不再显示并移除既有徽章")
@MainActor
func ghosttyLinkPreviewDisabledRemovesBadge() throws {
  let view = makeView()
  view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
  view.handleCommandModifierChange(pressed: true)

  view.handleMouseOverLink("https://example.com")
  #expect(view.linkPreviewText == "https://example.com")

  // 设置关闭时立刻移除现有徽章,后续 hover 也不再显示。
  view.linkPreviewEnabled = false
  #expect(view.linkPreviewText == nil)
  view.handleMouseOverLink("https://example.com")
  #expect(view.linkPreviewText == nil)
}

@Test("原生链接命中同步手形，关闭预览仍保留点击反馈")
@MainActor
func ghosttyNativeLinkHoverDrivesCursorIndependentlyOfPreview() {
  let view = makeView()
  view.frame = NSRect(x: 0, y: 0, width: 600, height: 400)
  view.handleCommandModifierChange(pressed: true)
  view.handleMouseOverLink("http://127.0.0.1:8899")
  #expect(view.linkPreviewText == "http://127.0.0.1:8899")
  #expect(view.linkHoverCursorActive)
  #expect(NSCursor.current === NSCursor.pointingHand)
  view.linkPreviewEnabled = false
  #expect(view.linkHoverCursorActive)
  view.linkPreviewEnabled = true
  #expect(view.linkPreviewText == "http://127.0.0.1:8899")
  view.handleMouseOverLink("")
  #expect(!view.linkHoverCursorActive)
  view.handleMouseOverLink("http://127.0.0.1:8899")
  #expect(view.linkHoverCursorActive)
  view.handleCommandModifierChange(pressed: false)
  #expect(!view.linkHoverCursorActive)
  #expect(view.linkPreviewText == nil)
  view.handleMouseOverLink("http://127.0.0.1:8899")
  #expect(!view.linkHoverCursorActive)
  #expect(view.linkPreviewText == nil, "迟到的原生回调不得重新显示预览")
}

@Test("下划线用可合成的矢量图层更新，清除后没有残留路径")
@MainActor
func ghosttyLinkUnderlineUsesShapeLayer() throws {
  let overlay = GhosttyLinkUnderlineOverlay(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
  overlay.lineColor = .black
  overlay.update(segments: [NSRect(x: 120, y: 200, width: 160, height: 18)])
  let shape = try #require(overlay.layer?.sublayers?.compactMap { $0 as? CAShapeLayer }.first)
  let path = try #require(shape.path)
  #expect(path.boundingBox == CGRect(x: 120, y: 201.5, width: 160, height: 0))
  #expect(!overlay.isHidden)
  #expect(shape.strokeColor == NSColor.black.cgColor)
  #expect(shape.animationKeys()?.isEmpty != false)
  overlay.update(segments: [])
  #expect(shape.path == nil)
  #expect(overlay.isHidden)
}

@Test("预览徽章紧凑规格：28pt 高、12pt 字，宽度够时地址完整显示，超宽才截断")
@MainActor
func ghosttyLinkPreviewBadgeIsCompactAndShowsFullURL() throws {
  let view = makeView()
  view.frame = NSRect(x: 0, y: 0, width: 800, height: 400)
  view.handleCommandModifierChange(pressed: true)
  view.handleMouseOverLink("http://127.0.0.1:8899")
  let badge = try #require(view.linkPreviewBadge)
  #expect(badge.frame.height == 28)
  #expect(badge.textField.font?.pointSize == 12)
  // 用户现场：Pane 很宽却显示成 "http://12…0.0.1:8899"。label 的 frame 必须容得下
  // intrinsicContentSize（含 cell 内边距），否则 NSTextField 会中间截断。
  badge.layoutSubtreeIfNeeded()
  let cellWidth = try #require(badge.textField.cell?.cellSize.width)
  #expect(badge.textField.frame.width >= ceil(cellWidth), "宽度充足时地址不得被截断")
  #expect(badge.textField.lineBreakMode == .byClipping, "放得下时不得启用省略号截断")
  #expect(badge.frame.width <= 800 - GhosttyLinkPreviewBadge.horizontalInset * 2)

  // 超过 Pane 可用宽度时才允许截断：徽章宽度被钳到可用宽度，并切回中间省略。
  view.frame = NSRect(x: 0, y: 0, width: 200, height: 400)
  view.layoutLinkPreviewBadge()
  #expect(badge.frame.width == 200 - GhosttyLinkPreviewBadge.horizontalInset * 2)
  #expect(badge.textField.lineBreakMode == .byTruncatingMiddle)
  #expect(badge.textField.frame.width < ceil(cellWidth))
}
