import AppKit
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

  view.handleMouseOverLink("https://example.com")
  #expect(view.linkPreviewText == "https://example.com")

  // 设置关闭时立刻移除现有徽章,后续 hover 也不再显示。
  view.linkPreviewEnabled = false
  #expect(view.linkPreviewText == nil)
  view.handleMouseOverLink("https://example.com")
  #expect(view.linkPreviewText == nil)
}
