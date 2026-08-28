import Foundation

/// 屏幕检测得出的 Agent 状态（与 herdr `AgentState` 对应）。
public enum AgentScreenState: String, Equatable, Sendable, Codable {
  case idle, working, blocked, unknown

  init(_ ruleState: AgentDetectionRuleState?) {
    switch ruleState {
    case .idle: self = .idle
    case .working: self = .working
    case .blocked: self = .blocked
    case .unknown, nil: self = .unknown
    }
  }
}

/// 检测引擎输入：屏幕快照 + 终端标题 / 进度 OSC 原文。没有 OSC 数据时传空串即可。
public struct AgentDetectionInput: Equatable, Sendable {
  public var screen: String
  public var oscTitle: String
  public var oscProgress: String

  public init(screen: String, oscTitle: String = "", oscProgress: String = "") {
    self.screen = screen
    self.oscTitle = oscTitle
    self.oscProgress = oscProgress
  }
}

/// 检测结果的精简形式，供状态机消费。
public struct AgentScreenDetection: Equatable, Sendable {
  public var state: AgentScreenState
  public var skipStateUpdate: Bool
  public var visibleIdle: Bool
  public var visibleBlocker: Bool
  public var visibleWorking: Bool
  /// idle 来自「未命中任何规则」的兜底而非规则结论；调用方可对这种 idle 叠加启发式。
  public var isFallbackIdle: Bool

  public init(
    state: AgentScreenState,
    skipStateUpdate: Bool = false,
    visibleIdle: Bool = false,
    visibleBlocker: Bool = false,
    visibleWorking: Bool = false,
    isFallbackIdle: Bool = false
  ) {
    self.state = state
    self.skipStateUpdate = skipStateUpdate
    self.visibleIdle = visibleIdle
    self.visibleBlocker = visibleBlocker
    self.visibleWorking = visibleWorking
    self.isFallbackIdle = isFallbackIdle
  }
}

/// 检测的完整解释：命中规则、每条规则的求值证据、兜底原因等，用于调试菜单与诊断记录。
public struct AgentDetectionExplain: Equatable, Sendable {
  /// 未命中任何规则时的兜底原因（已知 Agent 默认视为 idle）。
  public static let defaultKnownAgentIdleFallback = "default_known_agent_idle_fallback"

  public struct MatchedRule: Equatable, Sendable {
    public var id: String
    public var priority: Int32
    public var region: String
    public var state: AgentScreenState
  }

  public struct RuleEvidence: Equatable, Sendable {
    public var contains: [String]
    public var regex: [String]
    public var lineRegex: [String]
    public var allCount: Int
    public var anyCount: Int
    public var notCount: Int
    public var regionBytes: Int
    public var regionPreview: String
  }

  public struct EvaluatedRule: Equatable, Sendable {
    public var id: String
    public var priority: Int32
    public var region: String
    public var evidence: RuleEvidence
    public var state: AgentScreenState
    public var matched: Bool
  }

  public var agentID: String
  public var state: AgentScreenState
  public var source: String?
  public var matchedRule: MatchedRule?
  public var visibleIdle: Bool
  public var visibleBlocker: Bool
  public var visibleWorking: Bool
  public var skipStateUpdate: Bool
  public var skippedUpdateReason: String?
  public var fallbackReason: String?
  public var evaluatedRules: [EvaluatedRule]
  public var warning: String?
  public var manifestVersion: String?

  /// 折叠成状态机需要的精简结果。
  public var detection: AgentScreenDetection {
    AgentScreenDetection(
      state: state,
      skipStateUpdate: skipStateUpdate,
      visibleIdle: visibleIdle,
      visibleBlocker: visibleBlocker,
      visibleWorking: visibleWorking,
      isFallbackIdle: matchedRule == nil && state == .idle)
  }

  /// 与 herdr `explain_to_json_value` 同构的 JSON 对象（snake_case 键），用于调试展示。
  public var jsonObject: [String: Any] {
    let matched: Any = matchedRule.map {
      [
        "id": $0.id, "priority": Int($0.priority), "region": $0.region,
        "state": $0.state.rawValue,
      ] as [String: Any]
    } ?? NSNull()
    let rules: [[String: Any]] = evaluatedRules.map { rule in
      [
        "id": rule.id,
        "priority": Int(rule.priority),
        "region": rule.region,
        "state": rule.state.rawValue,
        "matched": rule.matched,
        "evidence": [
          "contains": rule.evidence.contains,
          "regex": rule.evidence.regex,
          "line_regex": rule.evidence.lineRegex,
          "all_count": rule.evidence.allCount,
          "any_count": rule.evidence.anyCount,
          "not_count": rule.evidence.notCount,
          "region_bytes": rule.evidence.regionBytes,
          "region_preview": rule.evidence.regionPreview,
        ] as [String: Any],
      ]
    }
    return [
      "agent": agentID,
      "state": state.rawValue,
      "manifest_source": source ?? NSNull(),
      "manifest_version": manifestVersion ?? NSNull(),
      "matched_rule": matched,
      "visible_idle": visibleIdle,
      "visible_blocker": visibleBlocker,
      "visible_working": visibleWorking,
      "skip_state_update": skipStateUpdate,
      "skipped_update_reason": skippedUpdateReason ?? NSNull(),
      "fallback_reason": fallbackReason ?? NSNull(),
      "warning": warning ?? NSNull(),
      "evaluated_rules": rules,
    ]
  }
}

/// 编译后的清单：正则只在构造时编译一次，之后每次读屏直接求值。
///
/// 求值语义（移植 herdr `evaluate_loaded_manifest` / `compiled_gate_matches`）：
/// - `contains`：区域文本小写化后必须全部包含（needle 也在编译时小写化）。
/// - `regex`：对整块区域文本 firstMatch；`line_regex`：任一行匹配即可。
/// - `all` 全部满足、`any` 至少一个（为空则不约束）、`not` 任一满足即否决。
/// - 多条规则命中时取 priority 最大者；同值取先出现者。
/// - 无命中 → idle 兜底，`fallbackReason = default_known_agent_idle_fallback`。
/// - `visibleX` 只在结果 state == X 时才为真，避免规则误配时泄漏证据。
public final class CompiledAgentManifest: @unchecked Sendable {
  public let manifest: AgentDetectionManifest
  /// 来源说明（bundled / override 路径），仅用于 explain 展示。
  public let source: String
  /// 加载期警告（例如 override 解析失败回落 bundled），仅用于 explain 展示。
  public let warning: String?

  private let compiledRules: [CompiledRule]
  private let regions: [AgentDetectionRegion]

  /// 编译清单；清单未通过 `validate()` 或正则无法编译时抛错。
  public init(manifest: AgentDetectionManifest, source: String = "bundled", warning: String? = nil)
    throws
  {
    try manifest.validate()
    self.manifest = manifest
    self.source = source
    self.warning = warning
    var rules: [CompiledRule] = []
    var regions: [AgentDetectionRegion] = []
    for rule in manifest.rules {
      guard let region = AgentDetectionRegion(spec: rule.region) else {
        throw AgentDetectionManifestError.invalid("rule \(rule.id) uses invalid region: \(rule.region)")
      }
      regions.append(region)
      do {
        rules.append(CompiledRule(gate: try CompiledGate(rule.rootGate)))
      } catch {
        throw AgentDetectionManifestError.invalid("rule \(rule.id) could not be compiled: \(error)")
      }
    }
    self.compiledRules = rules
    self.regions = regions
  }

  /// 精简检测结果（热路径，每 300ms 一次）：行拆分只做一次，各 region 的切片 / 小写文本 /
  /// 行数组按 region 记忆化，不生成 evidence 与预览。
  public func detect(_ input: AgentDetectionInput) -> AgentScreenDetection {
    let cache = RegionTextCache(input: input)
    guard let rule = matchedRule(using: cache) else {
      return AgentScreenDetection(state: .idle, isFallbackIdle: true)
    }
    let state = AgentScreenState(rule.state)
    return AgentScreenDetection(
      state: state,
      skipStateUpdate: rule.skipStateUpdate,
      visibleIdle: rule.visibleIdle && state == .idle,
      visibleBlocker: rule.visibleBlocker && state == .blocked,
      visibleWorking: rule.visibleWorking && state == .working)
  }

  /// priority 仲裁：只有严格更高的优先级才能替换已命中的规则，保证同值时保留先出现者。
  private func matchedRule(using cache: RegionTextCache) -> AgentDetectionRule? {
    var matched: AgentDetectionRule?
    for (index, rule) in manifest.rules.enumerated() {
      guard compiledRules[index].matches(cache.text(for: regions[index])) else { continue }
      if let previous = matched, previous.priority >= rule.priority { continue }
      matched = rule
    }
    return matched
  }

  /// 完整解释：逐条规则求值、记录证据并做 priority 仲裁（调试路径，不在轮询里用）。
  public func explain(_ input: AgentDetectionInput) -> AgentDetectionExplain {
    let cache = RegionTextCache(input: input)
    var matched: (rule: AgentDetectionRule, index: Int)?
    var evaluated: [AgentDetectionExplain.EvaluatedRule] = []

    for (index, rule) in manifest.rules.enumerated() {
      let regionText = cache.text(for: regions[index])
      let isMatch = compiledRules[index].matches(regionText)
      evaluated.append(
        AgentDetectionExplain.EvaluatedRule(
          id: rule.id,
          priority: rule.priority,
          region: rule.region,
          evidence: Self.evidence(for: rule, regionText: regionText.text),
          state: AgentScreenState(rule.state),
          matched: isMatch))
      guard isMatch else { continue }
      if let previous = matched, previous.rule.priority >= rule.priority { continue }
      matched = (rule, index)
    }

    guard let matched else {
      return AgentDetectionExplain(
        agentID: manifest.id,
        state: .idle,
        source: source,
        matchedRule: nil,
        visibleIdle: false,
        visibleBlocker: false,
        visibleWorking: false,
        skipStateUpdate: false,
        skippedUpdateReason: nil,
        fallbackReason: AgentDetectionExplain.defaultKnownAgentIdleFallback,
        evaluatedRules: evaluated,
        warning: warning,
        manifestVersion: manifest.version)
    }

    let rule = matched.rule
    let state = AgentScreenState(rule.state)
    return AgentDetectionExplain(
      agentID: manifest.id,
      state: state,
      source: source,
      matchedRule: .init(id: rule.id, priority: rule.priority, region: rule.region, state: state),
      visibleIdle: rule.visibleIdle && state == .idle,
      visibleBlocker: rule.visibleBlocker && state == .blocked,
      visibleWorking: rule.visibleWorking && state == .working,
      skipStateUpdate: rule.skipStateUpdate,
      skippedUpdateReason: rule.skipStateUpdate ? "matched_rule:\(rule.id)" : nil,
      fallbackReason: nil,
      evaluatedRules: evaluated,
      warning: warning,
      manifestVersion: manifest.version)
  }

  /// 规则证据：只记录规则声明与区域大小/预览，不记录整块屏幕内容。
  static func evidence(for rule: AgentDetectionRule, regionText: String)
    -> AgentDetectionExplain.RuleEvidence
  {
    AgentDetectionExplain.RuleEvidence(
      contains: rule.contains,
      regex: rule.regex,
      lineRegex: rule.lineRegex,
      allCount: rule.all.count,
      anyCount: rule.any.count,
      notCount: rule.not.count,
      regionBytes: regionText.utf8.count,
      regionPreview: boundedPreview(regionText))
  }

  /// 预览最多 240 个字符，超出加 `...`。
  static func boundedPreview(_ text: String) -> String {
    let maxChars = 240
    var preview = String(text.prefix(maxChars))
    if text.count > maxChars { preview += "..." }
    return preview
  }

  // MARK: - 区域文本缓存

  /// 一块区域文本及其惰性派生物：小写副本（contains）与行数组（line_regex）。
  /// 同一 region 被多条规则引用时只算一次。
  final class RegionText {
    let text: String
    private(set) lazy var lower: String = text.lowercased()
    /// 交给 NSRegularExpression 的副本：先桥接成 NSString 再包回 String，之后每次
    /// firstMatch 的 String→NSString 桥接就是 O(1)，避免每条规则都整块拷贝。
    private(set) lazy var regexText: String = (text as NSString) as String
    private(set) lazy var regexUTF16Length: Int = (text as NSString).length
    private(set) lazy var lines: [(text: String, utf16Length: Int)] =
      AgentScreenLines(text).lines.map { line in
        let bridged = String(line) as NSString
        return (bridged as String, bridged.length)
      }

    init(_ text: Substring) { self.text = String(text) }
  }

  /// 单次输入的 region 记忆化：屏幕只拆一次行，每种 region 只切一次。
  final class RegionTextCache {
    private let input: AgentDetectionInput
    private lazy var lines = AgentScreenLines(input.screen)
    private var cache: [AgentDetectionRegion: RegionText] = [:]

    init(input: AgentDetectionInput) { self.input = input }

    func text(for region: AgentDetectionRegion) -> RegionText {
      if let cached = cache[region] { return cached }
      let built = RegionText(region.slice(input, lines: lines))
      cache[region] = built
      return built
    }
  }

  // MARK: - 编译结构

  struct CompiledRule {
    let gate: CompiledGate

    func matches(_ region: RegionText) -> Bool {
      gate.matches(region)
    }
  }

  struct CompiledGate {
    let all: [CompiledGate]
    let any: [CompiledGate]
    let not: [CompiledGate]
    let contains: [String]
    let regex: [NSRegularExpression]
    let lineRegex: [NSRegularExpression]

    init(_ gate: AgentDetectionGate) throws {
      all = try gate.all.map(CompiledGate.init)
      any = try gate.any.map(CompiledGate.init)
      not = try gate.not.map(CompiledGate.init)
      contains = gate.contains.map { $0.lowercased() }
      regex = try gate.regex.map(AgentDetectionRegex.compile)
      lineRegex = try gate.lineRegex.map(AgentDetectionRegex.compile)
    }

    func matches(_ region: RegionText) -> Bool {
      if !contains.isEmpty {
        let lower = region.lower
        if !contains.allSatisfy({ lower.contains($0) }) { return false }
      }
      if !regex.isEmpty {
        let text = region.regexText
        let length = region.regexUTF16Length
        if !regex.allSatisfy({ $0.hasMatch(in: text, utf16Length: length) }) { return false }
      }
      if !lineRegex.isEmpty {
        let lines = region.lines
        if !lineRegex.allSatisfy({ pattern in
          lines.contains { pattern.hasMatch(in: $0.text, utf16Length: $0.utf16Length) }
        }) {
          return false
        }
      }
      if !all.allSatisfy({ $0.matches(region) }) { return false }
      if !any.isEmpty, !any.contains(where: { $0.matches(region) }) { return false }
      if not.contains(where: { $0.matches(region) }) { return false }
      return true
    }
  }
}

extension NSRegularExpression {
  /// 整段文本是否存在匹配（NSRange 用 UTF-16 长度，由调用方缓存）。
  fileprivate func hasMatch(in text: String, utf16Length: Int) -> Bool {
    firstMatch(in: text, range: NSRange(location: 0, length: utf16Length)) != nil
  }
}
