import Foundation
import Testing

@testable import AsterCore

/// 检测引擎测试：规则语义 + 内置清单的真实屏幕样本（移植 herdr manifest/tests.rs 90-406、639-976）。
@Suite("AgentDetectionEngine")
struct AgentDetectionEngineTests {
  /// 内置清单编译一次，供全部用例复用。
  static let store = AgentDetectionManifestStore(overrideDirectory: nil)

  static func explain(
    _ id: String, _ screen: String, oscTitle: String = "", oscProgress: String = ""
  ) -> AgentDetectionExplain {
    store.manifest(for: id)!.explain(
      AgentDetectionInput(screen: screen, oscTitle: oscTitle, oscProgress: oscProgress))
  }

  static func compile(rulesJSON: String) throws -> CompiledAgentManifest {
    try CompiledAgentManifest(
      manifest: AgentDetectionManifest.decode(json: #"{"id":"codex","rules":[\#(rulesJSON)]}"#))
  }

  // MARK: - 规则语义

  @Test("已知 Agent 无命中时兜底 idle 且不带 visible_idle")
  func knownAgentNoMatchDefaultsToIdleFallback() {
    let explain = Self.explain("codex", "ordinary prompt text")
    #expect(explain.state == .idle)
    #expect(!explain.visibleIdle)
    #expect(explain.fallbackReason == AgentDetectionExplain.defaultKnownAgentIdleFallback)
    #expect(explain.matchedRule == nil)
    #expect(explain.manifestVersion == "2026.08.09.1")
    #expect(explain.source == "bundled")
    #expect(explain.evaluatedRules.count == 8)
  }

  @Test("gate 组合、priority 仲裁与 line_regex")
  func ruleSemanticsApplyGatesPriorityAndLineRegex() throws {
    let compiled = try Self.compile(
      rulesJSON: #"""
        {"id":"low_contains","state":"idle","priority":1,"contains":["match"]},
        {"id":"high_nested_gates","state":"working","priority":10,"contains":["match"],
         "all":[{"any":[{"regex":["w[io]n"]},{"contains":["fallback"]}]}],
         "not":[{"contains":["blocked"]}]},
        {"id":"line_regex","state":"blocked","priority":20,"line_regex":["^exact line$"]}
        """#)

    let high = compiled.explain(AgentDetectionInput(screen: "match win"))
    #expect(high.state == .working)
    #expect(high.matchedRule?.id == "high_nested_gates")
    #expect(high.evaluatedRules.map(\.matched) == [true, true, false])

    let notGate = compiled.explain(AgentDetectionInput(screen: "match win blocked"))
    #expect(notGate.state == .idle)
    #expect(notGate.matchedRule?.id == "low_contains")

    let line = compiled.explain(AgentDetectionInput(screen: "before\nexact line\nafter"))
    #expect(line.state == .blocked)
    #expect(line.matchedRule?.id == "line_regex")
    // 整块 regex 不会跨行匹配 ^...$，line_regex 才会。
    #expect(compiled.explain(AgentDetectionInput(screen: "exact line\n")).matchedRule?.id == "line_regex")
  }

  @Test("contains 大小写不敏感；regex 大小写敏感；any 为空不约束")
  func containsIsCaseInsensitiveRegexIsNot() throws {
    let compiled = try Self.compile(
      rulesJSON: #"""
        {"id":"c","state":"working","priority":1,"contains":["Esc TO Interrupt"]},
        {"id":"r","state":"blocked","priority":2,"regex":["Yes"]}
        """#)
    #expect(compiled.detect(AgentDetectionInput(screen: "esc to interrupt")).state == .working)
    #expect(compiled.detect(AgentDetectionInput(screen: "yes")).state == .idle)
    #expect(compiled.detect(AgentDetectionInput(screen: "Yes")).state == .blocked)
  }

  @Test("同优先级取先出现的规则")
  func equalPriorityKeepsFirstMatch() throws {
    let compiled = try Self.compile(
      rulesJSON: #"""
        {"id":"first","state":"working","priority":5,"contains":["x"]},
        {"id":"second","state":"blocked","priority":5,"contains":["x"]}
        """#)
    #expect(compiled.explain(AgentDetectionInput(screen: "x")).matchedRule?.id == "first")
  }

  @Test("visible 标志只在状态一致时生效；skip 规则给出 skipped_update_reason")
  func visibleFlagsRequireMatchingState() throws {
    let compiled = try Self.compile(
      rulesJSON: #"""
        {"id":"odd","state":"working","priority":5,"visible_idle":true,"visible_blocker":true,"visible_working":true,"contains":["x"]},
        {"id":"menu","state":"unknown","priority":9,"skip_state_update":true,"contains":["menu"]}
        """#)
    let odd = compiled.explain(AgentDetectionInput(screen: "x"))
    #expect(odd.visibleWorking && !odd.visibleIdle && !odd.visibleBlocker)
    let menu = compiled.explain(AgentDetectionInput(screen: "x menu"))
    #expect(menu.state == .unknown)
    #expect(menu.skipStateUpdate)
    #expect(menu.skippedUpdateReason == "matched_rule:menu")
    #expect(!menu.visibleWorking)
  }

  @Test("explain 的 JSON 视图可序列化且不含整屏内容")
  func explainJSONIsSerializable() throws {
    let explain = Self.explain("codex", String(repeating: "z", count: 1000))
    let data = try JSONSerialization.data(withJSONObject: explain.jsonObject)
    let text = String(decoding: data, as: UTF8.self)
    #expect(text.contains("\"fallback_reason\":\"default_known_agent_idle_fallback\""))
    #expect(text.contains("\"region_preview\":\"" + String(repeating: "z", count: 240) + "...\""))
    #expect(!text.contains(String(repeating: "z", count: 241)))
  }

  // MARK: - devin

  @Test("devin 清单识别 idle / working / blocked 五态")
  func devinManifestDetectsIdleWorkingAndBlockedStates() {
    let idle = Self.explain(
      "devin",
      """
      ─────────────────────────────────────────────────────
      ❭ Ask Devin to build features, fix bugs, or work on
        your code
      ─────────────────────────────────────────────────────
      SWE-1.6               Context: 16k / 200k tokens (7%)
      """)
    #expect(idle.state == .idle)
    #expect(idle.visibleIdle)

    let liveFooterIdle = Self.explain(
      "devin",
      """
      Done.

      ────────────────────────────────────────────────── (bypass permissions on) ─
      ❭
      ────────────────────────────────────────────────────────────────────────────
      Claude Opus 4.6 Thinking                                    Context: 38k / 200k tokens (18%)
      """)
    #expect(liveFooterIdle.state == .idle)
    #expect(liveFooterIdle.matchedRule?.id == "live_prompt_footer")
    #expect(liveFooterIdle.visibleIdle)

    let welcomeFooterIdle = Self.explain(
      "devin",
      """
      ⠀⠀⠀⠀⠀⣴⣾⣶⡄⠀⠀⠀⠀
      ⠀⣴⣾⣶⡾⠛⠿⠟⠃⣴⣾⣶⡄  Devin CLI
      ⠀⠛⠿⠟⠃⣴⣾⣶⡾⠛⠿⠟⠃  v2026.5.26-8
      ⠀⣤⣶⣦⡄⠻⢿⠿⢷⣤⣶⣦⡄
      ⠀⠻⢿⠿⢷⣤⣶⣦⡄⠻⢿⠿⠃  Hybrid
      ⠀⠀⠀⠀⠀⠻⢿⠿⠃⠀⠀⠀⠀

      ───────────────────────────
      ❭ Ask Devin to build
        features, fix bugs, or
        work on your code
      ───────────────────────────
      Claude Opus Looking for
      4.6 Thinkingplan mode? /
                  plan
      """)
    #expect(welcomeFooterIdle.state == .idle)
    #expect(welcomeFooterIdle.matchedRule?.id == "welcome_prompt_footer")
    #expect(welcomeFooterIdle.visibleIdle)

    let working = Self.explain(
      "devin",
      """
      ◔ Reading shell 91b655
        │ Timeout: 35s

      ⠀⡆ Running tools · 27s (esc to interrupt)
      ─────────────────────────────────────────────────────
      ❭ Guide Devin while it works
      """)
    #expect(working.state == .working)
    #expect(working.visibleWorking)

    let trustPrompt = Self.explain(
      "devin",
      """
      Do you trust the authors of this directory?
      For security, devin should not be run in directories
      with untrusted content.
      ❭ 1 Yes, trust /private/tmp/devin-hook-probe
      · 2 No, exit
      """)
    #expect(trustPrompt.state == .blocked)
    #expect(trustPrompt.visibleBlocker)

    let permissionPrompt = Self.explain(
      "devin",
      """
      ⏺ Running command
        └ $ sleep 30

      ❭ 1 Yes  (Approve once)
      · 2 Yes, allow `sleep` commands
      · 3 Yes, always allow `sleep` commands
      · 4 No
      ↑↓ select · ↵ confirm · esc cancel
      """)
    #expect(permissionPrompt.state == .blocked)
    #expect(permissionPrompt.visibleBlocker)
  }

  // MARK: - muse

  @Test("muse 清单要求成对出现的实时控件")
  func museManifestRequiresCompleteLiveControls() {
    let working = Self.explain(
      "muse",
      """
      ⟩ hello

      ◆ Working (0s · esc to interrupt)

      ────────────────
      ⟩
      ────────────────
      gpt-5.4 · minimal · /workspace
      """)
    #expect(working.state == .working)
    #expect(working.visibleWorking)

    let picker = Self.explain(
      "muse",
      """
      Which option should I use?

      › 1. Alpha
        2. Beta

      Enter to select · ↑/↓ to move · Tab for an optional note · Esc to interrupt

      ────────────────
      ⟩
      ────────────────
      gpt-5.4 · minimal · /workspace
      """)
    #expect(picker.state == .blocked)
    #expect(picker.visibleBlocker)

    let commandApproval = Self.explain(
      "muse",
      """
      Would you like to run the following command?

      $ printf muse-safe-probe

      › 1. Allow this stage once (y)
        2. Always allow in this workspace: printf muse-safe-probe ... (p)
        3. Abort the entire command (esc)
      ────────────────
      gpt-5.4 · minimal · /workspace
      """)
    #expect(commandApproval.state == .blocked)
    #expect(commandApproval.visibleBlocker)

    let networkApproval = Self.explain(
      "muse",
      """
      network: example.com:443 https
      requested by:
      $ curl -fsS https://example.com

      › 1. Yes, proceed (y)
        2. Yes, don't ask again this session (p)  example.com:443 (https)
        3. No, and tell Muse Code what to do differently (esc)
      ────────────────
      gpt-5.4 · minimal · /workspace
      """)
    #expect(networkApproval.state == .blocked)
    #expect(networkApproval.visibleBlocker)

    let menu = Self.explain(
      "muse",
      """
      Theme

      ⟩ Default (active)
        Dynamic

      ↑↓ move · enter save · esc go back
      """)
    #expect(menu.state == .unknown)
    #expect(menu.skipStateUpdate)
    #expect(!menu.visibleBlocker)

    let ordinaryReply = Self.explain(
      "muse",
      """
      ⟩ say the phrase

      ◆ Yes, proceed

      ────────────────
      ⟩
      ────────────────
      gpt-5.4 · minimal · /workspace
      """)
    #expect(ordinaryReply.state == .idle)
    #expect(ordinaryReply.visibleIdle)
  }

  // MARK: - claude OSC

  @Test("claude：OSC 标题盲文前缀为 working")
  func claudeOSCTitleBraillePrefixIsWorking() {
    let result = Self.explain("claude", "", oscTitle: "⠂ project")
    #expect(result.state == .working)
    #expect(result.matchedRule?.id == "osc_title_working")
    #expect(result.visibleWorking)
  }

  @Test("claude：OSC 标题半圆帧为 working")
  func claudeOSCTitleHalfCircleFramesAreWorking() {
    for frame in ["◐", "◓", "◑", "◒"] {
      let result = Self.explain("claude", "", oscTitle: "\(frame) Initial conversation with Claude")
      #expect(result.state == .working, "frame \(frame)")
      #expect(result.matchedRule?.id == "osc_title_working", "frame \(frame)")
      #expect(result.visibleWorking, "frame \(frame)")
    }
  }

  @Test("claude：OSC 标题 ✳ 静态前缀为 idle")
  func claudeOSCTitleStaticPrefixIsIdle() {
    let result = Self.explain("claude", "", oscTitle: "✳ Claude Code")
    #expect(result.state == .idle)
    #expect(result.matchedRule?.id == "osc_title_idle")
    #expect(result.visibleIdle)
  }

  @Test("claude：OSC 进度 4;3 单独不构成 working")
  func claudeOSCProgress43AloneDoesNotForceWorking() {
    let result = Self.explain("claude", "", oscProgress: "4;3;")
    #expect(result.state == .idle)
    #expect(result.fallbackReason == AgentDetectionExplain.defaultKnownAgentIdleFallback)
    #expect(!result.visibleWorking)
  }

  @Test("claude：屏幕阻塞表单压过过期的 OSC 进度")
  func claudeBlockerScreenOutranksStaleOSCProgress() {
    let screen = "──────────\n  1. Yes\n  2. No\n\nEnter to select · ↑/↓ to navigate · Esc to cancel\n"
    let result = Self.explain("claude", screen, oscTitle: "✳ Task title", oscProgress: "4;3;")
    #expect(result.state == .blocked)
    #expect(result.visibleBlocker)
  }

  @Test("claude：OSC 进度 4;0 为 idle")
  func claudeOSCProgress40IsIdle() {
    let result = Self.explain("claude", "", oscProgress: "4;0;")
    #expect(result.state == .idle)
    #expect(result.matchedRule?.id == "osc_progress_idle")
  }

  @Test("claude：bash 权限提示压过 OSC idle 标题")
  func claudeBlockerScreenOutranksOSCIdleTitle() {
    let screen =
      "do you want to proceed?\nbash command: rm -rf /tmp/test\n❯ 1. Yes\n   2. No\n\nEsc to cancel · Tab to amend · ctrl+e to explain\n"
    let result = Self.explain("claude", screen, oscTitle: "✳ Claude Code")
    #expect(result.state == .blocked)
    #expect(result.matchedRule?.id == "bash_permission_prompt")
    #expect(result.visibleBlocker)
  }

  @Test("claude：空 OSC + 空屏幕为 idle 兜底")
  func claudeEmptyOSCEmptyScreenIsIdleFallback() {
    let result = Self.explain("claude", "")
    #expect(result.state == .idle)
    #expect(result.fallbackReason == AgentDetectionExplain.defaultKnownAgentIdleFallback)
    #expect(!result.visibleIdle)
  }

  @Test("claude：提示框内 ❯ 为 visible idle，后台 MCP 任务为 working")
  func claudePromptBoxAndBackgroundTasks() {
    let promptBox = Self.explain(
      "claude",
      """
      ⏺ Done.

      ──────────────────────────────
      ❯
      ──────────────────────────────
        ? for shortcuts
      """)
    #expect(promptBox.state == .idle)
    #expect(promptBox.matchedRule?.id == "live_prompt_box")
    #expect(promptBox.visibleIdle)

    let mcp = Self.explain(
      "claude",
      """
      ✻ Summarizing results · 2 MCP tasks still running

      ──────────────────────────────
      ❯
      ──────────────────────────────
      """)
    #expect(mcp.state == .working)
    #expect(mcp.matchedRule?.id == "background_mcp_task_working")
  }

  // MARK: - codex OSC

  @Test("codex：OSC 标题盲文 spinner 为 working")
  func codexOSCTitleBrailleSpinnerIsWorking() {
    let result = Self.explain("codex", "", oscTitle: "⠋ llm-proxy")
    #expect(result.state == .working)
    #expect(result.matchedRule?.id == "osc_title_working")
    #expect(result.visibleWorking)
  }

  @Test("codex：OSC 标题 Action Required 为 blocked")
  func codexOSCTitleActionRequiredIsBlocked() {
    let result = Self.explain("codex", "", oscTitle: "[ . ] Action Required | llm-proxy")
    #expect(result.state == .blocked)
    #expect(result.matchedRule?.id == "osc_title_blocked")
    #expect(result.visibleBlocker)
  }

  @Test("codex：普通 OSC 标题为 idle")
  func codexOSCTitlePlainIsIdle() {
    let result = Self.explain("codex", "", oscTitle: "llm-proxy")
    #expect(result.state == .idle)
    #expect(result.matchedRule?.id == "osc_title_idle")
    #expect(result.visibleIdle)
  }

  @Test("codex：trust_directory 只认顶部实时区域")
  func codexTrustDirectoryRequiresLiveTopRegion() {
    let screen = """
      > You are in C:\\Users\\user\\project

      Do you trust the contents of this
      directory? Working with untrusted
      contents comes with higher risk of
      prompt injection. Trusting the
      directory allows project-local config,
      hooks, and exec policies to load.

      › 1. Yes, continue
        2. No, quit

      Press enter to continue

      """
    let result = Self.explain("codex", screen, oscTitle: "project")
    #expect(result.state == .blocked)
    #expect(result.matchedRule?.id == "trust_directory")
    #expect(result.visibleBlocker)

    let transcript = """
      › > You are in C:\\Users\\user\\project

      Do you trust the contents of this
      directory? Working with untrusted contents comes with higher risk.

      """
    let stale = Self.explain("codex", transcript, oscTitle: "project")
    #expect(stale.state == .idle)
    #expect(stale.matchedRule?.id != "trust_directory")
    #expect(!stale.visibleBlocker)
  }

  @Test("codex：后台终端提示不压过 OSC idle")
  func codexBackgroundTerminalScreenDoesNotOverrideOSCIdle() {
    let screen = "background terminal running · /ps to view · /stop to close\n"
    let result = Self.explain("codex", screen, oscTitle: "llm-proxy")
    #expect(result.state == .idle)
    #expect(result.matchedRule?.id == "osc_title_idle")
    #expect(result.visibleIdle)
  }

  @Test("codex：静态 OSC 标题下屏幕 working 兜底生效")
  func codexScreenWorkingFallbackHandlesStaticOSCTitle() {
    let screen = """
      • I’ll run it and wait for completion.

      ◦ Working (1m 16s • esc to interrupt) · 1 background…

      › Use /skills to list available skills

      gpt-5.6-sol default · /work

      """
    let result = Self.explain("codex", screen, oscTitle: "project")
    #expect(result.state == .working)
    #expect(result.matchedRule?.id == "screen_working_fallback")
    #expect(result.visibleWorking)
  }

  @Test("codex：OSC working 优先于屏幕兜底")
  func codexOSCWorkingRemainsPreferredOverScreenFallback() {
    let screen = "• Working (4s • esc to interrupt)\n\n› Use /skills to list available skills\n\ngpt-5.6-sol default · /work\n"
    let result = Self.explain("codex", screen, oscTitle: "⠸ project")
    #expect(result.state == .working)
    #expect(result.matchedRule?.id == "osc_title_working")
    #expect(result.visibleWorking)
  }

  @Test("codex：屏幕强阻塞压过 working 兜底")
  func codexScreenBlockerOutranksWorkingFallback() {
    let screen = "• Working (4s • esc to interrupt)\n› 1. Yes, proceed\nPress enter to confirm or esc to cancel\n"
    let result = Self.explain("codex", screen, oscTitle: "project")
    #expect(result.state == .blocked)
    #expect(result.matchedRule?.id == "live_strong_blocker")
    #expect(result.visibleBlocker)
    #expect(!result.visibleWorking)
  }

  @Test("codex：弱阻塞压过 working 兜底")
  func codexWeakBlockerOutranksWorkingFallback() {
    let screen = "• Working (4s • esc to interrupt)\ndo you want to continue? [y/n]\n› Use /skills to list available skills\n"
    let result = Self.explain("codex", screen, oscTitle: "project")
    #expect(result.state == .blocked)
    #expect(result.matchedRule?.id == "weak_blocker")
    #expect(!result.visibleWorking)
  }

  @Test("codex：transcript viewer 压过 working 兜底且 skip")
  func codexTranscriptViewerOutranksWorkingFallback() {
    let screen = "• Working (4s • esc to interrupt)\n› transcript\n↑/↓ to scroll · pgup/pgdn to move · home/end to jump · q to quit · esc to edit prev\n"
    let result = Self.explain("codex", screen, oscTitle: "project")
    #expect(result.state == .unknown)
    #expect(result.matchedRule?.id == "transcript_viewer")
    #expect(result.skipStateUpdate)
    #expect(!result.visibleWorking)
  }

  @Test("codex：working 兜底忽略过期与提示行文本")
  func codexScreenWorkingFallbackIgnoresStaleAndPromptText() {
    let screens = [
      "◦ Working (1m 16s • esc to interrupt)\n■ Conversation interrupted\n› Use /skills to list available skills\ngpt-5.6-sol default · /work\n",
      "› Explain the text ◦ Working (1m 16s • esc to interrupt)\ngpt-5.6-sol default · /work\n",
      "  ◦ Working (1m 16s • esc to interrupt)\n› Use /skills to list available skills\ngpt-5.6-sol default · /work\n",
    ]
    for screen in screens {
      let result = Self.explain("codex", screen, oscTitle: "project")
      #expect(result.state == .idle, Comment(rawValue: screen))
      #expect(result.matchedRule?.id == "osc_title_idle", Comment(rawValue: screen))
      #expect(result.visibleIdle, Comment(rawValue: screen))
      #expect(!result.visibleWorking, Comment(rawValue: screen))
    }
  }

  @Test("codex：working 兜底忽略被中断的短屏幕")
  func codexScreenWorkingFallbackIgnoresInterruptedShortTerminal() {
    let screen = "◦ Working (1m 16s • esc to interrupt)\n■ Conversation interrupted\n›\n"
    let result = Self.explain("codex", screen, oscTitle: "project")
    #expect(result.state == .idle)
    #expect(result.matchedRule?.id == "osc_title_idle")
    #expect(result.visibleIdle)
    #expect(!result.visibleWorking)
  }

  @Test("codex：OSC working 压过弱阻塞屏幕")
  func codexOSCWorkingBeatsWeakBlockerScreen() {
    let result = Self.explain("codex", "do you want to continue? [y/n]\n", oscTitle: "⠋ llm-proxy")
    #expect(result.state == .working)
    #expect(result.matchedRule?.id == "osc_title_working")
  }

  // MARK: - 其它内置清单冒烟

  @Test("hermes：⚠ 前缀规则（\\u{} 改写）可命中")
  func hermesWarningPrefixRuleCompilesAndMatches() throws {
    let compiled = try #require(Self.store.manifest(for: "hermes"))
    let rule = try #require(
      compiled.manifest.rules.first { $0.regex.contains { $0.contains("\\u{fe0e}") } })
    let regex = try AgentDetectionRegex.compile(rule.regex[0])
    let sample = "⚠\u{fe0f} Approve edit?"
    #expect(regex.firstMatch(in: sample, range: NSRange(location: 0, length: sample.utf16.count)) != nil)
  }

  @Test("全部内置清单对空屏幕都兜底为 idle 且不崩溃")
  func allBundledManifestsFallbackToIdleOnEmptyScreen() {
    for id in Self.store.manifestIDs {
      let result = Self.explain(id, "")
      #expect(result.state == .idle, Comment(rawValue: id))
      #expect(result.fallbackReason == AgentDetectionExplain.defaultKnownAgentIdleFallback, Comment(rawValue: id))
    }
  }

  // MARK: - store

  @Test("override 目录：有效覆盖优先，坏文件回落 bundled 并给 warning")
  func storeOverridePrecedenceAndFallback() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("aster-agent-detection-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = AgentDetectionManifestStore(overrideDirectory: dir)
    #expect(store.manifest(for: "codex")?.source == "bundled")
    #expect(store.manifest(for: "nonexistent") == nil)

    try #"{"id":"codex","version":"9999.01.01.1","rules":[{"id":"test","state":"blocked","contains":["local-ready"]}]}"#
      .write(to: dir.appendingPathComponent("codex.json"), atomically: true, encoding: .utf8)
    // 未 reload 前仍用缓存。
    #expect(store.manifest(for: "codex")?.source == "bundled")
    store.reload()
    let overridden = try #require(store.manifest(for: "codex"))
    #expect(overridden.source == dir.appendingPathComponent("codex.json").path)
    #expect(overridden.manifest.version == "9999.01.01.1")
    #expect(overridden.detect(AgentDetectionInput(screen: "local-ready")).state == .blocked)
    #expect(store.summaries.first { $0.id == "codex" }?.version == "9999.01.01.1")

    // 解析失败 → 回落 bundled + warning。
    try "id = ".write(to: dir.appendingPathComponent("codex.json"), atomically: true, encoding: .utf8)
    store.reload()
    let fallback = try #require(store.manifest(for: "codex"))
    #expect(fallback.source == "bundled")
    #expect(fallback.warning?.contains("could not be loaded") == true)
    #expect(fallback.explain(AgentDetectionInput(screen: "")).warning != nil)

    // id 不匹配 → 回落 bundled + warning。
    try #"{"id":"claude","rules":[{"id":"t","state":"idle","contains":["x"]}]}"#
      .write(to: dir.appendingPathComponent("codex.json"), atomically: true, encoding: .utf8)
    store.reload()
    #expect(store.manifest(for: "codex")?.warning?.contains("does not match") == true)

    // 别名匹配 → 接受。
    try #"{"id":"claude-code","rules":[{"id":"t","state":"idle","contains":["x"]}]}"#
      .write(to: dir.appendingPathComponent("claude.json"), atomically: true, encoding: .utf8)
    store.reload()
    #expect(store.manifest(for: "claude")?.source != "bundled")
  }
}

/// 快路径 `detect` 与详尽路径 `explain` 的一致性、兜底标记与性能基线。
@Suite("AgentDetectionEngine.fastPath")
struct AgentDetectionEngineFastPathTests {
  static let store = AgentDetectionEngineTests.store

  @Test("detect 与 explain.detection 对真实样本给出相同结论")
  func detectMatchesExplain() throws {
    let samples: [(String, AgentDetectionInput)] = [
      ("codex", AgentDetectionInput(screen: "• Working (4s • esc to interrupt)\n› 1. Yes, proceed\nPress enter to confirm or esc to cancel\n", oscTitle: "project")),
      ("codex", AgentDetectionInput(screen: "do you want to continue? [y/n]\n", oscTitle: "⠋ llm-proxy")),
      ("codex", AgentDetectionInput(screen: "• Working (4s • esc to interrupt)\n› transcript\n↑/↓ to scroll · pgup/pgdn to move · home/end to jump · q to quit · esc to edit prev\n", oscTitle: "project")),
      ("claude", AgentDetectionInput(screen: "", oscTitle: "✳ Claude Code")),
      ("claude", AgentDetectionInput(screen: "──────────\n  1. Yes\n  2. No\n\nEnter to select · ↑/↓ to navigate · Esc to cancel\n", oscTitle: "✳ Task title", oscProgress: "4;3;")),
      ("muse", AgentDetectionInput(screen: "Theme\n\n⟩ Default (active)\n  Dynamic\n\n↑↓ move · enter save · esc go back")),
      ("devin", AgentDetectionInput(screen: "ordinary text")),
    ]
    for (id, input) in samples {
      let compiled = try #require(Self.store.manifest(for: id))
      #expect(compiled.detect(input) == compiled.explain(input).detection, Comment(rawValue: id))
    }
  }

  @Test("未命中规则的 idle 标记 isFallbackIdle；规则命中的 idle 不标记")
  func fallbackIdleFlag() throws {
    let codex = try #require(Self.store.manifest(for: "codex"))
    let fallback = codex.detect(AgentDetectionInput(screen: "ordinary prompt text"))
    #expect(fallback.state == .idle && fallback.isFallbackIdle && !fallback.visibleIdle)
    let ruled = codex.detect(AgentDetectionInput(screen: "", oscTitle: "llm-proxy"))
    #expect(ruled.state == .idle && !ruled.isFallbackIdle && ruled.visibleIdle)
  }

  @Test("claude 清单 24 行输入 detect 1000 次的耗时基线")
  func detectThroughputBaseline() throws {
    let claude = try #require(Self.store.manifest(for: "claude"))
    var lines: [String] = []
    for index in 0..<20 { lines.append("⏺ Read(src/file\(index).swift) · 1.2k tokens · done") }
    lines += ["", "──────────────────────────────", "❯ ", "──────────────────────────────"]
    let input = AgentDetectionInput(screen: lines.joined(separator: "\n"), oscTitle: "✳ Claude Code")
    _ = claude.detect(input)
    let started = ContinuousClock.now
    for _ in 0..<1000 { _ = claude.detect(input) }
    let elapsed = started.duration(to: .now)
    // debug 构建本机实测约 330ms（≈330µs/次，ICU 正则占绝大头）；生产每 300ms 才跑一次。
    // 上限 600ms 只防止回归到「每条规则重复拆行 + 小写 + 预览」的量级，并容忍 CI 抖动。
    #expect(elapsed < .milliseconds(600), "1000 次 detect 耗时 \(elapsed)")
  }
}
