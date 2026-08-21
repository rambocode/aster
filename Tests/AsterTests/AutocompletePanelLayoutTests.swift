import AppKit
import AsterCore
import Testing

@testable import Aster

/// 候选面板的布局验收。旧实现用一个空 `NSView()` 当 spacer，`NSStackView` 的默认
/// gravityAreas 分布让每行按各自内容宽度排列，类别标签的位置逐行漂移；面板宽度还
/// 写死成几乎撑满终端。这里锁住修好后的三件事：行高、宽度自适应、行内左对齐。
@MainActor
private func makeOverlay(
  candidates: [AutocompleteCandidate],
  selectedIndex: Int = 0,
  bounds: NSRect = NSRect(x: 0, y: 0, width: 1_200, height: 600)
) -> TerminalAutocompleteOverlayView {
  let overlay = TerminalAutocompleteOverlayView(frame: bounds)
  overlay.render(
    result: AutocompleteResult(candidates: candidates, ghostText: nil, replacementStart: 0),
    showInline: false,
    showPanel: true,
    selectedIndex: selectedIndex,
    caretFrame: NSRect(x: 24, y: 400, width: 8, height: 18),
    font: .monospacedSystemFont(ofSize: 12, weight: .regular),
    foreground: .black,
    background: .white,
    accent: .systemBlue
  )
  return overlay
}

@Test("候选面板宽度贴合内容，不再撑满终端")
@MainActor
func candidatePanelWidthFitsContent() {
  let shortOverlay = makeOverlay(candidates: [
    AutocompleteCandidate(insertText: "ls", kind: .learnedCommand),
    AutocompleteCandidate(insertText: "cd", kind: .learnedCommand),
  ])
  let shortWidth = shortOverlay.panel.frame.width

  let longOverlay = makeOverlay(candidates: [
    AutocompleteCandidate(
      insertText: "open ./worktrees/fix-agent-install-detection/dist/Aster.app",
      kind: .learnedCommand),
    AutocompleteCandidate(insertText: "cd", kind: .learnedCommand),
  ])
  let longWidth = longOverlay.panel.frame.width

  // 内容更长 → 面板更宽；短内容不该跟着撑到同一个写死的宽度。
  #expect(shortWidth < longWidth)
  #expect(shortWidth >= TerminalAutocompleteOverlayView.minimumPanelWidth)
  #expect(longWidth <= TerminalAutocompleteOverlayView.maximumPanelWidth)
  // 关键回归点：1200pt 宽的终端里，短候选面板不得再占掉近一半宽度。
  #expect(shortWidth < 320)
}

@Test("候选行高固定且行内元素左对齐")
@MainActor
func candidateRowsAreCompactAndLeftAligned() throws {
  let overlay = makeOverlay(candidates: [
    AutocompleteCandidate(insertText: "ls", kind: .learnedCommand),
    AutocompleteCandidate(
      insertText: "./scripts/build-app.sh", description: "构建 App", kind: .file),
    AutocompleteCandidate(insertText: "dist", kind: .folder),
  ])
  let rows = overlay.panel.arrangedSubviews.compactMap { $0 as? AutocompleteCandidateRow }
  #expect(rows.count == 3)
  overlay.layoutSubtreeIfNeeded()

  var leadingEdges: [CGFloat] = []
  for row in rows {
    #expect(row.frame.height == AutocompleteCandidateRow.height)
    // 行宽必须等于面板宽度。只看行内布局是不够的：行内可以完全左对齐，而行本身
    // 被摆到面板右侧，肉眼看到的仍是「内容整体靠右」。
    #expect(row.frame.width == overlay.panel.frame.width)
    let icon = try #require(row.subviews.compactMap { $0 as? NSImageView }.first)
    #expect(icon.image != nil, "每个候选都应有类别图标")
    // 折算到面板坐标系再比，才能同时覆盖「行内偏移」和「整行偏移」两种漂移。
    leadingEdges.append(overlay.panel.convert(icon.frame.origin, from: row).x)
  }
  // 逐行左边缘必须一致；旧实现里它会随内容宽度漂移，视觉上就是标签位置忽左忽右。
  #expect(Set(leadingEdges.map { ($0 * 100).rounded() }).count == 1)
}

@Test("选中候选只改文字色，不铺整行底色块")
@MainActor
func selectedCandidateUsesAccentTextInsteadOfFilledRow() throws {
  let overlay = makeOverlay(
    candidates: [
      AutocompleteCandidate(insertText: "ls", kind: .learnedCommand),
      AutocompleteCandidate(insertText: "cd", kind: .learnedCommand),
    ],
    selectedIndex: 0
  )
  let rows = overlay.panel.arrangedSubviews.compactMap { $0 as? AutocompleteCandidateRow }
  let selected = try #require(rows.first)
  let name = try #require(selected.subviews.compactMap { $0 as? NSTextField }.first)
  #expect(name.textColor == NSColor.systemBlue)
  // 底色保持接近全透明：选中靠文字色表达，整行反白会在终端上糊成一条亮带。
  let alpha = selected.layer?.backgroundColor?.alpha ?? 1
  #expect(alpha < 0.05)
}
