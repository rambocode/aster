import Foundation
import Testing

@testable import AsterCore

/// 清单模型与校验测试：内置清单全部可用；各类非法清单被拒绝（移植 herdr manifest/tests.rs 409-637）。
@Suite("AgentDetectionManifest")
struct AgentDetectionManifestTests {
  /// 用最简 JSON 组装一份 codex 清单，rules 由调用方给。
  static func manifestJSON(rules: String, header: String = "") -> String {
    #"{"id":"codex",\#(header)"rules":[\#(rules)]}"#
  }

  @Test("全部内置清单可解码、可校验、正则可编译")
  func bundledManifestsDecodeValidateAndCompile() throws {
    #expect(AgentDetectionBundledManifests.all.count == 21)
    for (id, json) in AgentDetectionBundledManifests.all {
      let manifest = try AgentDetectionManifest.decode(json: json)
      #expect(manifest.id == id)
      #expect(manifest.version != nil)
      #expect(!manifest.rules.isEmpty)
      let compiled = try CompiledAgentManifest(manifest: manifest)
      #expect(compiled.manifest.id == id)
    }
  }

  @Test("内置清单覆盖 herdr 的 21 个 Agent id")
  func bundledManifestIDsMatchHerdr() {
    let expected: Set<String> = [
      "amp", "agy", "claude", "cline", "codex", "cursor", "devin", "droid", "gemini", "grok",
      "hermes", "kilo", "kimi", "kiro", "maki", "muse", "opencode", "pi", "qodercli", "qwen",
      "copilot",
    ]
    #expect(Set(AgentDetectionBundledManifests.all.keys) == expected)
  }

  @Test("解码保留 snake_case 字段与默认值")
  func decodeAppliesDefaults() throws {
    let manifest = try AgentDetectionManifest.decode(
      json: Self.manifestJSON(rules: #"{"id":"r","contains":["x"]}"#))
    let rule = try #require(manifest.rules.first)
    #expect(rule.priority == 0)
    #expect(rule.region == "whole_recent")
    #expect(rule.state == nil)
    #expect(!rule.visibleIdle && !rule.visibleBlocker && !rule.visibleWorking)
    #expect(!rule.skipStateUpdate)
    #expect(manifest.aliases.isEmpty)
    #expect(manifest.minEngineVersion == nil)

    let full = try AgentDetectionManifest.decode(
      json: #"""
        {"id":"claude","version":"2026.08.21.1","min_engine_version":2,"updated_at":"x",
         "aliases":["claude-code"],
         "rules":[{"id":"r","state":"blocked","priority":5,"region":"osc_title",
                   "visible_blocker":true,"line_regex":["^a"],"not":[{"contains":["b"]}]}]}
        """#)
    #expect(full.aliases == ["claude-code"])
    #expect(full.minEngineVersion == 2)
    #expect(full.matches(agentID: "claude-code"))
    #expect(!full.matches(agentID: "codex"))
    let rule2 = try #require(full.rules.first)
    #expect(rule2.state == .blocked)
    #expect(rule2.lineRegex == ["^a"])
    #expect(rule2.not == [AgentDetectionGate(contains: ["b"])])
  }

  @Test("拒绝未知字段、空 rules、错误 region、坏正则（含嵌套）")
  func rejectsUnknownFieldsEmptyRulesInvalidRegionsAndRegexes() {
    // 拼错的 contain（对应 deny_unknown_fields）
    #expect(throws: AgentDetectionManifestError.self) {
      try AgentDetectionManifest.decode(
        json: Self.manifestJSON(rules: #"{"id":"typo","state":"working","contain":["Working"]}"#))
    }
    // 嵌套 gate 的未知字段
    #expect(throws: AgentDetectionManifestError.self) {
      try AgentDetectionManifest.decode(
        json: Self.manifestJSON(
          rules: #"{"id":"typo","state":"working","any":[{"contain":["Working"]}]}"#))
    }
    // 没有任何 matcher 的规则
    #expect(throws: AgentDetectionManifestError.self) {
      try AgentDetectionManifest.decode(
        json: Self.manifestJSON(rules: #"{"id":"empty","state":"working"}"#))
    }
    // 没有规则
    #expect(throws: AgentDetectionManifestError.self) {
      try AgentDetectionManifest.decode(json: #"{"id":"codex"}"#)
    }
    // region 拼错
    #expect(throws: AgentDetectionManifestError.self) {
      try AgentDetectionManifest.decode(
        json: Self.manifestJSON(
          rules:
            #"{"id":"bad_region","state":"working","region":"after_last_promt_marker","contains":["Working"]}"#
        ))
    }
    // 坏正则
    #expect(throws: AgentDetectionManifestError.self) {
      try AgentDetectionManifest.decode(
        json: Self.manifestJSON(rules: #"{"id":"bad_regex","state":"working","regex":["["]}"#))
    }
    // 嵌套坏正则
    #expect(throws: AgentDetectionManifestError.self) {
      try AgentDetectionManifest.decode(
        json: Self.manifestJSON(
          rules: #"{"id":"bad_nested_regex","state":"working","any":[{"line_regex":["["]}]}"#))
    }
    // 非法 state
    #expect(throws: AgentDetectionManifestError.self) {
      try AgentDetectionManifest.decode(
        json: Self.manifestJSON(rules: #"{"id":"bad_state","state":"busy","contains":["x"]}"#))
    }
    // 空 rule id
    #expect(throws: AgentDetectionManifestError.self) {
      try AgentDetectionManifest.decode(
        json: Self.manifestJSON(rules: #"{"id":"  ","state":"idle","contains":["x"]}"#))
    }
    // 空 not gate
    #expect(throws: AgentDetectionManifestError.self) {
      try AgentDetectionManifest.decode(
        json: Self.manifestJSON(rules: #"{"id":"empty_not","contains":["x"],"not":[{}]}"#))
    }
    // 非 JSON
    #expect(throws: AgentDetectionManifestError.self) {
      try AgentDetectionManifest.decode(json: "id = ")
    }
  }

  @Test("skip_state_update 规则必须保持中性")
  func keepsSkipRulesNeutral() throws {
    #expect(throws: AgentDetectionManifestError.self) {
      try AgentDetectionManifest.decode(
        json: Self.manifestJSON(
          rules: #"{"id":"bad_skip_state","state":"idle","skip_state_update":true,"contains":["menu"]}"#
        ))
    }
    #expect(throws: AgentDetectionManifestError.self) {
      try AgentDetectionManifest.decode(
        json: Self.manifestJSON(
          rules:
            #"{"id":"bad_skip_visible","state":"unknown","skip_state_update":true,"visible_blocker":true,"contains":["menu"]}"#
        ))
    }
    // 合法形态
    let ok = try AgentDetectionManifest.decode(
      json: Self.manifestJSON(
        rules: #"{"id":"menu","state":"unknown","skip_state_update":true,"contains":["menu"]}"#))
    #expect(ok.rules[0].skipStateUpdate)
  }

  @Test("拒绝超过 128 条规则")
  func rejectsExcessiveRuleCount() {
    let rules = (0..<129).map { #"{"id":"rule_\#($0)","state":"idle","contains":["ready"]}"# }
    #expect(throws: AgentDetectionManifestError.self) {
      try AgentDetectionManifest.decode(json: Self.manifestJSON(rules: rules.joined(separator: ",")))
    }
    let okRules = (0..<128).map { #"{"id":"rule_\#($0)","state":"idle","contains":["ready"]}"# }
    #expect(throws: Never.self) {
      try AgentDetectionManifest.decode(
        json: Self.manifestJSON(rules: okRules.joined(separator: ",")))
    }
  }

  @Test("拒绝超过 8 层的 gate 嵌套")
  func rejectsExcessiveGateDepth() {
    // 规则本身是第 0 层，再嵌 9 层 all → 第 9 层超限。
    var nested = #"{"contains":["9"]}"#
    for level in stride(from: 8, through: 1, by: -1) {
      nested = #"{"contains":["\#(level)"],"all":[\#(nested)]}"#
    }
    #expect(throws: AgentDetectionManifestError.self) {
      try AgentDetectionManifest.decode(
        json: Self.manifestJSON(
          rules: #"{"id":"deep","state":"idle","contains":["ready"],"all":[\#(nested)]}"#))
    }
    // 少一层即合法。
    var shallow = #"{"contains":["8"]}"#
    for level in stride(from: 7, through: 1, by: -1) {
      shallow = #"{"contains":["\#(level)"],"all":[\#(shallow)]}"#
    }
    #expect(throws: Never.self) {
      try AgentDetectionManifest.decode(
        json: Self.manifestJSON(
          rules: #"{"id":"deep","state":"idle","contains":["ready"],"all":[\#(shallow)]}"#))
    }
  }

  @Test("拒绝单 gate 超过 32 个 matcher")
  func rejectsExcessiveMatchers() {
    let matchers = (0..<33).map { #""m\#($0)""# }.joined(separator: ",")
    #expect(throws: AgentDetectionManifestError.self) {
      try AgentDetectionManifest.decode(
        json: Self.manifestJSON(rules: #"{"id":"many","state":"idle","contains":[\#(matchers)]}"#))
    }
  }

  @Test("拒绝超过 512 字符的 matcher")
  func rejectsOverlongMatcher() {
    let long = String(repeating: "a", count: 513)
    #expect(throws: AgentDetectionManifestError.self) {
      try AgentDetectionManifest.decode(
        json: Self.manifestJSON(rules: #"{"id":"long","state":"idle","contains":["\#(long)"]}"#))
    }
  }

  @Test("top_non_empty_lines 声明低于引擎 3 时被拒绝")
  func topNonEmptyLinesRequiresEngineThreeWhenDeclared() {
    #expect(throws: AgentDetectionManifestError.self) {
      try AgentDetectionManifest.decode(
        json: #"""
          {"id":"grok","version":"1","min_engine_version":2,
           "rules":[{"id":"background","state":"working","region":" top_non_empty_lines(1) ","contains":["active"]}]}
          """#)
    }
    // 未声明 min_engine_version 或 ≥3 即可用；region 允许两端空白。
    #expect(throws: Never.self) {
      try AgentDetectionManifest.decode(
        json: #"""
          {"id":"grok","version":"1","min_engine_version":3,
           "rules":[{"id":"background","state":"working","region":" top_non_empty_lines(1) ","contains":["active"]}]}
          """#)
    }
  }

  @Test("正则语法归一化：\\u{hhhh} 改写为 ICU 的 \\x{hhhh}")
  func regexNormalizesRustCodepointEscapes() throws {
    #expect(AgentDetectionRegex.normalize(#"^⚠[\u{fe0e}\u{fe0f}]?"#) == #"^⚠[\x{fe0e}\x{fe0f}]?"#)
    #expect(AgentDetectionRegex.normalize(#"\\u{fe0e}"#) == #"\\u{fe0e}"#)
    #expect(AgentDetectionRegex.normalize(#"\x{2800}\p{Alphabetic}"#) == #"\x{2800}\p{Alphabetic}"#)
    let regex = try AgentDetectionRegex.compile(#"^⚠[\u{fe0e}\u{fe0f}]?(?:\s|$)"#)
    #expect(regex.firstMatch(in: "⚠\u{fe0f} warn", range: NSRange(location: 0, length: 7)) != nil)
  }
}
