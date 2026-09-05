import AppKit
import AsterCore
import Testing

@testable import Aster

/// 候选面板的布局验收。旧实现用一个空 `NSView()` 当 spacer，`NSStackView` 的默认
/// gravityAreas 分布让每行按各自内容宽度排列，类别标签的位置逐行漂移；面板宽度还
/// 写死成几乎撑满终端。这里锁住修好后的几件事：行高、宽度自适应、行内左对齐、
/// 滚动视窗、描述侧栏，以及选中态——它从「只改文字色」升级为「accent 淡染 + 前导
/// 标记条」，但仍然禁止不透明整行反白（26pt 高的行反白会在终端上糊成一条亮带）。
@MainActor
private func makeOverlay(
  candidates: [AutocompleteCandidate],
  selectedIndex: Int = 0,
  firstVisibleIndex: Int = 0,
  bounds: NSRect = NSRect(x: 0, y: 0, width: 1_200, height: 600)
) -> TerminalAutocompleteOverlayView {
  let overlay = TerminalAutocompleteOverlayView(frame: bounds)
  overlay.render(
    result: AutocompleteResult(candidates: candidates, ghostText: nil, replacementStart: 0),
    showInline: false,
    showPanel: true,
    selectedIndex: selectedIndex,
    showsSelection: true,
    firstVisibleIndex: firstVisibleIndex,
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

@Test("选中候选用 accent 淡染加前导条，不做整行反白")
@MainActor
func selectedCandidateUsesAccentWashNotInvertedRow() throws {
  let overlay = makeOverlay(
    candidates: [
      AutocompleteCandidate(insertText: "ls", kind: .learnedCommand),
      AutocompleteCandidate(insertText: "cd", kind: .learnedCommand),
    ],
    selectedIndex: 0
  )
  let rows = overlay.panel.arrangedSubviews.compactMap { $0 as? AutocompleteCandidateRow }
  #expect(rows.count == 2)
  let selected = try #require(rows.first)
  let name = try #require(selected.subviews.compactMap { $0 as? NSTextField }.first)
  #expect(name.textColor == NSColor.systemBlue)
  // 有可见底色，但绝不能是不透明反白——26pt 高的行反白会在终端上糊成一条亮带。
  let selectedAlpha = selected.layer?.backgroundColor?.alpha ?? 0
  #expect(selectedAlpha > 0.05 && selectedAlpha < 0.25)
  let unselectedAlpha = rows[1].layer?.backgroundColor?.alpha ?? 1
  #expect(unselectedAlpha < 0.05)
  // 前导条只在选中行出现，且必须很窄：宽条等于变相反白。
  overlay.layoutSubtreeIfNeeded()
  let bar = try #require(selected.selectionBar)
  #expect(bar.frame.width <= 3)
  #expect(rows[1].selectionBar == nil)
}

@Test("候选超过一屏时只渲染滚动视窗内的行并显示滚动条")
@MainActor
func candidatePanelRendersOnlyVisibleWindowRows() throws {
  let candidates = (0..<20).map {
    AutocompleteCandidate(insertText: String(format: "cmd%02d", $0), kind: .subcommand)
  }
  let overlay = makeOverlay(candidates: candidates, selectedIndex: 12, firstVisibleIndex: 5)
  let rows = overlay.panel.arrangedSubviews.compactMap { $0 as? AutocompleteCandidateRow }
  #expect(rows.count == TerminalAutocompleteOverlayView.maximumVisibleRows)
  overlay.layoutSubtreeIfNeeded()
  let firstName = try #require(rows.first?.subviews.compactMap { $0 as? NSTextField }.first)
  #expect(firstName.stringValue == "cmd05")
  #expect(overlay.scrollThumb.isHidden == false)
  #expect(overlay.scrollThumb.frame.height < overlay.panel.frame.height)
}

@Test("描述侧栏显示选中项的完整描述，行内不再重复描述")
@MainActor
func candidatePanelShowsDescriptionSidebarForSelection() throws {
  let long = "Switch branches or restore working tree files from a given commit or branch name"
  let overlay = makeOverlay(candidates: [
    AutocompleteCandidate(insertText: "checkout", description: long, kind: .subcommand),
    AutocompleteCandidate(insertText: "commit", description: "Record changes", kind: .subcommand),
  ])
  overlay.layoutSubtreeIfNeeded()
  #expect(overlay.descriptionSidebar.isHidden == false)
  #expect(
    overlay.panelContainer.frame.width
      == overlay.panel.frame.width + TerminalAutocompleteOverlayView.descriptionSidebarWidth)
  let body = overlay.descriptionSidebar.subviews.compactMap { $0 as? NSTextField }
  #expect(body.contains { $0.stringValue == long }, "侧栏必须给出未截断的完整描述")
  // 行内只剩命令名一个 label，描述交给侧栏承载。
  let rows = overlay.panel.arrangedSubviews.compactMap { $0 as? AutocompleteCandidateRow }
  let firstRow = try #require(rows.first)
  #expect(firstRow.subviews.compactMap { $0 as? NSTextField }.count == 1)
}

@Test("描述侧栏跟随当前选中行")
@MainActor
func candidatePanelSidebarFollowsSelectedRow() {
  let overlay = makeOverlay(
    candidates: [
      AutocompleteCandidate(insertText: "checkout", description: "切换分支", kind: .subcommand),
      AutocompleteCandidate(insertText: "commit", description: "记录改动", kind: .subcommand),
    ],
    selectedIndex: 1
  )
  overlay.layoutSubtreeIfNeeded()
  let labels = overlay.descriptionSidebar.subviews.compactMap { $0 as? NSTextField }
  #expect(labels.contains { $0.stringValue == "记录改动" })
  #expect(labels.contains { $0.stringValue == "commit" })
}

@Test("窄终端里放弃侧栏并退回行内描述")
@MainActor
func candidatePanelFallsBackToInlineDescriptionInNarrowTerminal() throws {
  let overlay = makeOverlay(
    candidates: [
      AutocompleteCandidate(insertText: "checkout", description: "切换分支", kind: .subcommand),
      AutocompleteCandidate(insertText: "commit", description: "记录改动", kind: .subcommand),
    ],
    bounds: NSRect(x: 0, y: 0, width: 380, height: 600)
  )
  overlay.layoutSubtreeIfNeeded()
  #expect(overlay.descriptionSidebar.isHidden)
  #expect(overlay.panelContainer.frame.maxX <= 380 - 8)
  let rows = overlay.panel.arrangedSubviews.compactMap { $0 as? AutocompleteCandidateRow }
  let firstRow = try #require(rows.first)
  let texts = firstRow.subviews.compactMap { ($0 as? NSTextField)?.stringValue }
  #expect(texts.contains("切换分支"), "没有侧栏时行内描述必须回来")
}

@Test("全部候选都没有描述时不出现侧栏")
@MainActor
func candidatePanelWithoutDescriptionsHasNoSidebar() {
  let overlay = makeOverlay(candidates: [
    AutocompleteCandidate(insertText: "ls", kind: .learnedCommand),
    AutocompleteCandidate(insertText: "cd", kind: .learnedCommand),
  ])
  overlay.layoutSubtreeIfNeeded()
  #expect(overlay.descriptionSidebar.isHidden)
  #expect(overlay.panelContainer.frame.width == overlay.panel.frame.width)
}

@Test("狭小 Pane 缩减候选行数，面板不能覆盖输入行或越过右边界")
@MainActor
func candidatePanelFitsSmallPaneWithoutCoveringInput() {
  let bounds = NSRect(x: 0, y: 0, width: 180, height: 130)
  let caret = NSRect(x: 24, y: 65, width: 0, height: 18)
  let overlay = TerminalAutocompleteOverlayView(frame: bounds)
  overlay.render(
    result: AutocompleteResult(candidates: (0..<10).map {
      AutocompleteCandidate(insertText: "command-\($0)", kind: .command)
    }, ghostText: nil, replacementStart: 0),
    showInline: false, showPanel: true, selectedIndex: 9,
    caretFrame: caret, font: .monospacedSystemFont(ofSize: 12, weight: .regular),
    foreground: .black, background: .white, accent: .systemBlue)
  #expect(!overlay.panelContainer.isHidden)
  #expect(!overlay.panelContainer.frame.intersects(caret.insetBy(dx: -1, dy: 0)))
  #expect(bounds.contains(overlay.panelContainer.frame))
  #expect(overlay.panel.arrangedSubviews.count == 2)
}
