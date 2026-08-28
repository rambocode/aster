import Testing

@testable import AsterCore

/// Region 解析与切分测试（移植 herdr manifest/tests.rs 575-620，并补齐 codex / prompt box 各区域）。
@Suite("AgentDetectionRegion")
struct AgentDetectionRegionTests {
  static func slice(_ spec: String, _ screen: String, oscTitle: String = "", oscProgress: String = "")
    -> String
  {
    let region = AgentDetectionRegion(spec: spec)!
    return String(
      region.slice(
        AgentDetectionInput(screen: screen, oscTitle: oscTitle, oscProgress: oscProgress)))
  }

  @Test("region 名解析：14 种名字与计数形式")
  func parsesAllRegionNames() {
    #expect(AgentDetectionRegion(spec: "whole_recent") == .wholeRecent)
    #expect(AgentDetectionRegion(spec: " osc_title ") == .oscTitle)
    #expect(AgentDetectionRegion(spec: "osc_progress") == .oscProgress)
    #expect(AgentDetectionRegion(spec: "bottom_lines(3)") == .bottomLines(3))
    #expect(AgentDetectionRegion(spec: "bottom_non_empty_lines(8)") == .bottomNonEmptyLines(8))
    #expect(AgentDetectionRegion(spec: "top_non_empty_lines(20)") == .topNonEmptyLines(20))
    #expect(AgentDetectionRegion(spec: "after_last_prompt_marker") == .afterLastPromptMarker)
    #expect(AgentDetectionRegion(spec: "before_current_prompt_marker") == .beforeCurrentPromptMarker)
    #expect(
      AgentDetectionRegion(spec: "whole_recent_without_current_prompt_marker")
        == .wholeRecentWithoutCurrentPromptMarker)
    #expect(AgentDetectionRegion(spec: "current_prompt_block_marker") == .currentPromptBlockMarker)
    #expect(
      AgentDetectionRegion(spec: "after_current_prompt_block_marker") == .afterCurrentPromptBlockMarker)
    #expect(AgentDetectionRegion(spec: "prompt_box_body") == .promptBoxBody)
    #expect(AgentDetectionRegion(spec: "above_prompt_box") == .abovePromptBox)
    #expect(AgentDetectionRegion(spec: "last_non_empty_above_prompt_box") == .lastNonEmptyAbovePromptBox)
    #expect(AgentDetectionRegion(spec: "after_last_horizontal_rule") == .afterLastHorizontalRule)
    #expect(AgentDetectionRegion(spec: "after_last_promt_marker") == nil)
    #expect(AgentDetectionRegion(spec: "bottom_lines(x)") == nil)
    #expect(AgentDetectionRegion(spec: "bottom_lines(-1)") == nil)
    #expect(AgentDetectionRegion(spec: "bottom_lines()") == nil)
  }

  @Test("top_non_empty_lines 要求规范的正整数且不超过 u16::MAX")
  func topNonEmptyLinesRequiresCanonicalPositiveBoundedCount() {
    #expect(AgentDetectionRegion(spec: "top_non_empty_lines(1)") != nil)
    #expect(AgentDetectionRegion(spec: "top_non_empty_lines(65535)") != nil)
    for count in ["0", "01", "+1", "65536", "999999999999999999999999"] {
      #expect(AgentDetectionRegion(spec: "top_non_empty_lines(\(count))") == nil, "\(count)")
    }
    // bottom_* 沿用 Rust usize 解析：允许 `+1` 与前导零。
    #expect(AgentDetectionRegion(spec: "bottom_lines(+1)") == .bottomLines(1))
    #expect(AgentDetectionRegion(spec: "bottom_non_empty_lines(01)") == .bottomNonEmptyLines(1))
  }

  @Test("bottom_non_empty_lines 取底部出现的重复文本并保留尾部换行")
  func bottomNonEmptyLinesUsesBottomOccurrence() {
    #expect(
      Self.slice("bottom_non_empty_lines(2)", "marker\nold\n\nmiddle\nmarker\nnew\n")
        == "marker\nnew\n")
    // 中间夹的空行会一起带上。
    #expect(Self.slice("bottom_non_empty_lines(2)", "a\nb\n\nc") == "b\n\nc")
    #expect(Self.slice("bottom_non_empty_lines(5)", "a\nb") == "a\nb")
    #expect(Self.slice("bottom_non_empty_lines(1)", "\n  \n") == "")
  }

  @Test("top_non_empty_lines 取顶部出现的重复文本，含开头空行")
  func topNonEmptyLinesUsesTopOccurrence() {
    #expect(
      Self.slice("top_non_empty_lines(2)", "\nmarker\nold\n\nmiddle\nmarker\nnew\n")
        == "\nmarker\nold\n")
    #expect(Self.slice("top_non_empty_lines(1)", "a\nb") == "a\n")
    #expect(Self.slice("top_non_empty_lines(3)", "a\nb") == "a\nb")
    #expect(Self.slice("top_non_empty_lines(1)", "") == "")
  }

  @Test("bottom_lines 按原始行数切，末尾空行不算一行")
  func bottomLinesCountsRawLines() {
    #expect(Self.slice("bottom_lines(2)", "a\nb\nc\n") == "b\nc\n")
    #expect(Self.slice("bottom_lines(2)", "a\nb\nc") == "b\nc")
    #expect(Self.slice("bottom_lines(10)", "a\nb") == "a\nb")
    #expect(Self.slice("bottom_lines(1)", "a\n\n") == "\n")
  }

  @Test("OSC 区域读取专用字段，不看屏幕")
  func oscRegionsUseDedicatedFields() {
    #expect(Self.slice("osc_title", "screen", oscTitle: "⠋ title", oscProgress: "4;0") == "⠋ title")
    #expect(Self.slice("osc_progress", "screen", oscTitle: "t", oscProgress: "4;0") == "4;0")
    #expect(Self.slice("whole_recent", "screen", oscTitle: "t") == "screen")
  }

  @Test("codex 提示行区域：after_last / before_current / without_current")
  func codexPromptMarkerRegions() {
    let screen = "• reply\n› ask\nline\n"
    #expect(Self.slice("after_last_prompt_marker", screen) == "line\n")
    #expect(Self.slice("after_last_prompt_marker", "no prompt") == "no prompt")
    #expect(Self.slice("before_current_prompt_marker", screen) == "• reply\n")
    #expect(Self.slice("whole_recent_without_current_prompt_marker", screen) == "")

    // 提示行之后出现块标记 → 该提示已被回复，不是当前输入。
    let answered = "› ask\n• answer\n"
    #expect(Self.slice("before_current_prompt_marker", answered) == answered)
    #expect(Self.slice("whole_recent_without_current_prompt_marker", answered) == answered)
    // 单独一个 › 也算提示行；`›x` 不算。
    #expect(Self.slice("after_last_prompt_marker", "a\n›\nb") == "b")
    #expect(Self.slice("after_last_prompt_marker", "a\n›x\nb") == "a\n›x\nb")
  }

  @Test("codex 块标记区域：current_prompt_block_marker / after_current_prompt_block_marker")
  func codexBlockMarkerRegions() {
    let screen = "• first\n✓ done\n  detail\n› \n"
    #expect(Self.slice("current_prompt_block_marker", screen) == "✓ done")
    #expect(Self.slice("after_current_prompt_block_marker", screen) == "✓ done\n  detail\n› \n")
    #expect(Self.slice("current_prompt_block_marker", "no prompt") == "")
    #expect(Self.slice("after_current_prompt_block_marker", "›\n") == "")
    #expect(Self.slice("current_prompt_block_marker", "■ stop\n› x\n• later") == "")
  }

  @Test("prompt box 区域：上边框是倒数第二条横线")
  func promptBoxRegions() {
    let screen = "Done.\n\n──── (bypass permissions on) ─\n❯ typing\n  more\n────────\nfooter"
    #expect(Self.slice("prompt_box_body", screen) == "❯ typing\n  more\n")
    #expect(Self.slice("above_prompt_box", screen) == "Done.\n\n")
    #expect(Self.slice("last_non_empty_above_prompt_box", screen) == "Done.")
    #expect(Self.slice("after_last_horizontal_rule", screen) == "footer")

    // 只有一条横线：没有 prompt box。
    let single = "a\n────\nb"
    #expect(Self.slice("prompt_box_body", single) == "")
    #expect(Self.slice("above_prompt_box", single) == single)
    #expect(Self.slice("last_non_empty_above_prompt_box", single) == "b")
    #expect(Self.slice("after_last_horizontal_rule", single) == "b")
    #expect(Self.slice("after_last_horizontal_rule", "no rule") == "no rule")

    // 上边框固定取倒数第二条横线，之后的文字不属于 body。
    #expect(Self.slice("prompt_box_body", "────\nx\n────\nbody\n") == "x\n")
    #expect(Self.slice("prompt_box_body", "────\n────\nbody\n") == "")
    #expect(Self.slice("last_non_empty_above_prompt_box", "  \n────\n────\n") == "")
  }

  @Test("横线判定：整行 ─ 或至少 3 个 ─ 后带注解")
  func horizontalRuleDetection() {
    #expect(AgentDetectionRegion.isHorizontalRule("─"))
    #expect(AgentDetectionRegion.isHorizontalRule("  ──  "))
    #expect(AgentDetectionRegion.isHorizontalRule("─── note"))
    #expect(!AgentDetectionRegion.isHorizontalRule("── note"))
    #expect(!AgentDetectionRegion.isHorizontalRule(""))
    #expect(!AgentDetectionRegion.isHorizontalRule("x───"))
  }

  @Test("行拆分等价 Rust str::lines()")
  func screenLinesMatchRustLines() {
    #expect(AgentScreenLines("").count == 0)
    #expect(AgentScreenLines("\n").lines == [""])
    #expect(AgentScreenLines("a\n").lines == ["a"])
    #expect(AgentScreenLines("a").lines == ["a"])
    #expect(AgentScreenLines("a\n\n").lines == ["a", ""])
    #expect(AgentScreenLines("a\nb").lines == ["a", "b"])
  }
}
