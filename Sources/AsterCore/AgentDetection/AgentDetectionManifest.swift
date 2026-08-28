import Foundation

/// Agent 屏幕检测清单的数据模型与校验，移植自 herdr `src/detect/manifest.rs`。
///
/// 一份清单对应一个 Agent（`id`），由若干规则组成；每条规则在指定屏幕区域上用
/// contains / regex / line_regex 与 all / any / not 门组合判定，并给出状态与优先级。
/// JSON 键保持 herdr TOML 的 snake_case，方便用户直接照抄上游清单做本地覆盖。
public struct AgentDetectionManifest: Codable, Equatable, Sendable {
  public var id: String
  public var version: String?
  public var minEngineVersion: UInt32?
  public var updatedAt: String?
  public var aliases: [String]
  public var rules: [AgentDetectionRule]

  enum CodingKeys: String, CodingKey {
    case id, version, aliases, rules
    case minEngineVersion = "min_engine_version"
    case updatedAt = "updated_at"
  }

  public init(
    id: String,
    version: String? = nil,
    minEngineVersion: UInt32? = nil,
    updatedAt: String? = nil,
    aliases: [String] = [],
    rules: [AgentDetectionRule]
  ) {
    self.id = id
    self.version = version
    self.minEngineVersion = minEngineVersion
    self.updatedAt = updatedAt
    self.aliases = aliases
    self.rules = rules
  }

  /// 缺省字段按 herdr serde default 补齐（aliases / rules 允许缺省为空数组）。
  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    version = try container.decodeIfPresent(String.self, forKey: .version)
    minEngineVersion = try container.decodeIfPresent(UInt32.self, forKey: .minEngineVersion)
    updatedAt = try container.decodeIfPresent(String.self, forKey: .updatedAt)
    aliases = try container.decodeIfPresent([String].self, forKey: .aliases) ?? []
    rules = try container.decodeIfPresent([AgentDetectionRule].self, forKey: .rules) ?? []
  }

  /// 从 JSON 文本解码并校验；等价于 herdr `parse_manifest`。
  public static func decode(json: String) throws -> AgentDetectionManifest {
    let manifest: AgentDetectionManifest
    do {
      manifest = try AgentDetectionStrictJSONDecoder.decode(AgentDetectionManifest.self, from: json)
    } catch let error as AgentDetectionManifestError {
      throw error
    } catch {
      throw AgentDetectionManifestError.invalidJSON(String(describing: error))
    }
    try manifest.validate()
    return manifest
  }

  /// 清单是否服务于给定 Agent id（本体 id 或任一别名）。
  public func matches(agentID: String) -> Bool {
    id == agentID || aliases.contains(agentID)
  }
}

/// 规则可声明的状态；`unknown` 主要配合 `skip_state_update` 表示“保持上一状态”。
public enum AgentDetectionRuleState: String, Codable, Equatable, Sendable {
  case idle, working, blocked, unknown
}

/// 单条检测规则：区域 + 匹配门 + 状态与优先级。
public struct AgentDetectionRule: Codable, Equatable, Sendable {
  public var id: String
  public var state: AgentDetectionRuleState?
  public var priority: Int32
  public var region: String
  public var visibleIdle: Bool
  public var visibleBlocker: Bool
  public var visibleWorking: Bool
  public var skipStateUpdate: Bool
  public var all: [AgentDetectionGate]
  public var any: [AgentDetectionGate]
  public var not: [AgentDetectionGate]
  public var contains: [String]
  public var regex: [String]
  public var lineRegex: [String]

  /// herdr 默认区域：整块最近屏幕内容。
  public static let defaultRegion = "whole_recent"

  enum CodingKeys: String, CodingKey {
    case id, state, priority, region, all, any, not, contains, regex
    case visibleIdle = "visible_idle"
    case visibleBlocker = "visible_blocker"
    case visibleWorking = "visible_working"
    case skipStateUpdate = "skip_state_update"
    case lineRegex = "line_regex"
  }

  public init(
    id: String,
    state: AgentDetectionRuleState? = nil,
    priority: Int32 = 0,
    region: String = AgentDetectionRule.defaultRegion,
    visibleIdle: Bool = false,
    visibleBlocker: Bool = false,
    visibleWorking: Bool = false,
    skipStateUpdate: Bool = false,
    all: [AgentDetectionGate] = [],
    any: [AgentDetectionGate] = [],
    not: [AgentDetectionGate] = [],
    contains: [String] = [],
    regex: [String] = [],
    lineRegex: [String] = []
  ) {
    self.id = id
    self.state = state
    self.priority = priority
    self.region = region
    self.visibleIdle = visibleIdle
    self.visibleBlocker = visibleBlocker
    self.visibleWorking = visibleWorking
    self.skipStateUpdate = skipStateUpdate
    self.all = all
    self.any = any
    self.not = not
    self.contains = contains
    self.regex = regex
    self.lineRegex = lineRegex
  }

  /// 缺省字段按 herdr serde default 补齐。
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    state = try c.decodeIfPresent(AgentDetectionRuleState.self, forKey: .state)
    priority = try c.decodeIfPresent(Int32.self, forKey: .priority) ?? 0
    region = try c.decodeIfPresent(String.self, forKey: .region) ?? Self.defaultRegion
    visibleIdle = try c.decodeIfPresent(Bool.self, forKey: .visibleIdle) ?? false
    visibleBlocker = try c.decodeIfPresent(Bool.self, forKey: .visibleBlocker) ?? false
    visibleWorking = try c.decodeIfPresent(Bool.self, forKey: .visibleWorking) ?? false
    skipStateUpdate = try c.decodeIfPresent(Bool.self, forKey: .skipStateUpdate) ?? false
    all = try c.decodeIfPresent([AgentDetectionGate].self, forKey: .all) ?? []
    any = try c.decodeIfPresent([AgentDetectionGate].self, forKey: .any) ?? []
    not = try c.decodeIfPresent([AgentDetectionGate].self, forKey: .not) ?? []
    contains = try c.decodeIfPresent([String].self, forKey: .contains) ?? []
    regex = try c.decodeIfPresent([String].self, forKey: .regex) ?? []
    lineRegex = try c.decodeIfPresent([String].self, forKey: .lineRegex) ?? []
  }

  /// 规则顶层的匹配条件视作一个根 gate，便于与嵌套 gate 共用校验与求值逻辑。
  public var rootGate: AgentDetectionGate {
    AgentDetectionGate(
      all: all, any: any, not: not, contains: contains, regex: regex, lineRegex: lineRegex)
  }
}

/// 匹配门：contains / regex / line_regex 直接条件，加 all / any / not 嵌套组合。
public struct AgentDetectionGate: Codable, Equatable, Sendable {
  public var all: [AgentDetectionGate]
  public var any: [AgentDetectionGate]
  public var not: [AgentDetectionGate]
  public var contains: [String]
  public var regex: [String]
  public var lineRegex: [String]

  enum CodingKeys: String, CodingKey {
    case all, any, not, contains, regex
    case lineRegex = "line_regex"
  }

  public init(
    all: [AgentDetectionGate] = [],
    any: [AgentDetectionGate] = [],
    not: [AgentDetectionGate] = [],
    contains: [String] = [],
    regex: [String] = [],
    lineRegex: [String] = []
  ) {
    self.all = all
    self.any = any
    self.not = not
    self.contains = contains
    self.regex = regex
    self.lineRegex = lineRegex
  }

  /// 缺省字段按 herdr serde default 补齐。
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    all = try c.decodeIfPresent([AgentDetectionGate].self, forKey: .all) ?? []
    any = try c.decodeIfPresent([AgentDetectionGate].self, forKey: .any) ?? []
    not = try c.decodeIfPresent([AgentDetectionGate].self, forKey: .not) ?? []
    contains = try c.decodeIfPresent([String].self, forKey: .contains) ?? []
    regex = try c.decodeIfPresent([String].self, forKey: .regex) ?? []
    lineRegex = try c.decodeIfPresent([String].self, forKey: .lineRegex) ?? []
  }

  /// 是否含正向条件（contains/regex/line_regex/all/any 任一非空）。
  var hasPositiveMatcher: Bool {
    !contains.isEmpty || !regex.isEmpty || !lineRegex.isEmpty || !all.isEmpty || !any.isEmpty
  }

  /// 是否含任意条件（含 not）。
  var hasAnyMatcher: Bool { hasPositiveMatcher || !not.isEmpty }

  /// 直接 matcher 数量（不含嵌套）。
  var directMatcherCount: Int { contains.count + regex.count + lineRegex.count }
}

/// 清单解析 / 校验错误。
public enum AgentDetectionManifestError: Error, Equatable, CustomStringConvertible, Sendable {
  case invalidJSON(String)
  case unknownField(String)
  case invalid(String)

  public var description: String {
    switch self {
    case .invalidJSON(let detail): return "invalid manifest JSON: \(detail)"
    case .unknownField(let detail): return "unknown manifest field: \(detail)"
    case .invalid(let detail): return detail
    }
  }
}

// MARK: - 校验

/// 与 herdr `manifest.rs` 一致的复杂度上限。
public enum AgentDetectionManifestLimits {
  public static let maxRulesPerManifest = 128
  public static let maxGateDepth = 8
  public static let maxTotalGates = 512
  public static let maxMatchersPerGate = 32
  public static let maxTotalMatchers = 1024
  public static let maxMatcherChars = 512
  /// `top_non_empty_lines(N)` 区域自该引擎版本起可用。
  public static let topNonEmptyLinesEngineVersion: UInt32 = 3
  /// 当前引擎版本，对应 herdr `MANIFEST_ENGINE_VERSION`。
  public static let engineVersion: UInt32 = 3
}

extension AgentDetectionManifest {
  /// 移植 herdr `validate_manifest`：规则数、skip 规则中性、region 名、gate 复杂度、正则可编译。
  public func validate() throws {
    if rules.isEmpty {
      throw AgentDetectionManifestError.invalid("manifest must contain at least one rule")
    }
    if rules.count > AgentDetectionManifestLimits.maxRulesPerManifest {
      throw AgentDetectionManifestError.invalid(
        "manifest contains \(rules.count) rules, max is \(AgentDetectionManifestLimits.maxRulesPerManifest)"
      )
    }
    var complexity = ManifestComplexity()
    for rule in rules {
      if rule.id.trimmingCharacters(in: .whitespaces).isEmpty {
        throw AgentDetectionManifestError.invalid("manifest rule id must not be empty")
      }
      // skip_state_update 规则必须是 unknown 且不带任何 visible 证据：它只表示“保持上一状态”，
      // 若带状态或 visible 标志会让发布层误以为拿到了新证据。
      if rule.skipStateUpdate {
        if rule.state != .unknown {
          throw AgentDetectionManifestError.invalid(
            "rule \(rule.id) uses skip_state_update without state = \"unknown\"")
        }
        if rule.visibleIdle || rule.visibleBlocker || rule.visibleWorking {
          throw AgentDetectionManifestError.invalid(
            "rule \(rule.id) uses skip_state_update with visible state evidence")
        }
      }
      guard AgentDetectionRegion(spec: rule.region) != nil else {
        throw AgentDetectionManifestError.invalid(
          "rule \(rule.id) uses invalid region: \(rule.region.trimmingCharacters(in: .whitespaces))")
      }
      if rule.region.trimmingCharacters(in: .whitespaces).hasPrefix("top_non_empty_lines("),
        let minEngineVersion,
        minEngineVersion < AgentDetectionManifestLimits.topNonEmptyLinesEngineVersion
      {
        throw AgentDetectionManifestError.invalid(
          "rule \(rule.id) uses top_non_empty_lines but min_engine_version is below \(AgentDetectionManifestLimits.topNonEmptyLinesEngineVersion)"
        )
      }
      do {
        try Self.validateGate(rule.rootGate, context: "rule", depth: 0, complexity: &complexity)
      } catch let error as AgentDetectionManifestError {
        throw AgentDetectionManifestError.invalid(
          "rule \(rule.id) has invalid matcher gates: \(error.description)")
      }
    }
  }

  /// 累计整份清单的 gate / matcher 数量。
  struct ManifestComplexity {
    var totalGates = 0
    var totalMatchers = 0
  }

  /// 正向 gate 校验（对应 herdr `validate_gate`）。
  static func validateGate(
    _ gate: AgentDetectionGate, context: String, depth: Int, complexity: inout ManifestComplexity
  ) throws {
    if depth > AgentDetectionManifestLimits.maxGateDepth {
      throw AgentDetectionManifestError.invalid(
        "\(context) exceeds max gate depth \(AgentDetectionManifestLimits.maxGateDepth)")
    }
    complexity.totalGates += 1
    if complexity.totalGates > AgentDetectionManifestLimits.maxTotalGates {
      throw AgentDetectionManifestError.invalid(
        "manifest exceeds max gate count \(AgentDetectionManifestLimits.maxTotalGates)")
    }
    try validateMatcherLimits(gate, context: context, complexity: &complexity)
    if !gate.hasPositiveMatcher {
      throw AgentDetectionManifestError.invalid("\(context) must contain a positive matcher")
    }
    try validateRegexPatterns(gate.regex, context: context, field: "regex")
    try validateRegexPatterns(gate.lineRegex, context: context, field: "line_regex")
    for nested in gate.all {
      try validateGate(nested, context: "all gate", depth: depth + 1, complexity: &complexity)
    }
    for nested in gate.any {
      try validateGate(nested, context: "any gate", depth: depth + 1, complexity: &complexity)
    }
    for nested in gate.not {
      if !nested.hasAnyMatcher {
        throw AgentDetectionManifestError.invalid("\(context) contains an empty not gate")
      }
      try validateNotGate(nested, depth: depth + 1, complexity: &complexity)
    }
  }

  /// not gate 校验（对应 herdr `validate_not_gate`）：允许只含 not，但不能为空。
  static func validateNotGate(
    _ gate: AgentDetectionGate, depth: Int, complexity: inout ManifestComplexity
  ) throws {
    if depth > AgentDetectionManifestLimits.maxGateDepth {
      throw AgentDetectionManifestError.invalid(
        "not gate exceeds max gate depth \(AgentDetectionManifestLimits.maxGateDepth)")
    }
    complexity.totalGates += 1
    if complexity.totalGates > AgentDetectionManifestLimits.maxTotalGates {
      throw AgentDetectionManifestError.invalid(
        "manifest exceeds max gate count \(AgentDetectionManifestLimits.maxTotalGates)")
    }
    try validateMatcherLimits(gate, context: "not gate", complexity: &complexity)
    if !gate.hasAnyMatcher {
      throw AgentDetectionManifestError.invalid("not gate must contain a matcher")
    }
    try validateRegexPatterns(gate.regex, context: "not gate", field: "regex")
    try validateRegexPatterns(gate.lineRegex, context: "not gate", field: "line_regex")
    for nested in gate.all {
      try validateGate(nested, context: "not all gate", depth: depth + 1, complexity: &complexity)
    }
    for nested in gate.any {
      try validateGate(nested, context: "not any gate", depth: depth + 1, complexity: &complexity)
    }
    for nested in gate.not {
      try validateNotGate(nested, depth: depth + 1, complexity: &complexity)
    }
  }

  /// 单个 gate 的 matcher 数量与长度上限（对应 herdr `validate_matcher_limits`）。
  static func validateMatcherLimits(
    _ gate: AgentDetectionGate, context: String, complexity: inout ManifestComplexity
  ) throws {
    let count = gate.directMatcherCount
    if count > AgentDetectionManifestLimits.maxMatchersPerGate {
      throw AgentDetectionManifestError.invalid(
        "\(context) has \(count) direct matchers, max is \(AgentDetectionManifestLimits.maxMatchersPerGate)"
      )
    }
    complexity.totalMatchers += count
    if complexity.totalMatchers > AgentDetectionManifestLimits.maxTotalMatchers {
      throw AgentDetectionManifestError.invalid(
        "manifest exceeds max matcher count \(AgentDetectionManifestLimits.maxTotalMatchers)")
    }
    for value in gate.contains + gate.regex + gate.lineRegex
    where value.count > AgentDetectionManifestLimits.maxMatcherChars {
      throw AgentDetectionManifestError.invalid(
        "\(context) matcher exceeds max length \(AgentDetectionManifestLimits.maxMatcherChars)")
    }
  }

  /// 正则必须能被 ICU（NSRegularExpression）编译。
  static func validateRegexPatterns(_ patterns: [String], context: String, field: String) throws {
    for pattern in patterns {
      do {
        _ = try AgentDetectionRegex.compile(pattern)
      } catch {
        throw AgentDetectionManifestError.invalid(
          "\(context) contains invalid \(field) pattern \"\(pattern)\": \(error)")
      }
    }
  }
}

// MARK: - 正则编译

/// 统一的正则编译入口：把 herdr（Rust regex 语法）里 ICU 不认识的写法做最小改写。
public enum AgentDetectionRegex {
  /// 编译一条清单正则。
  ///
  /// 唯一的改写：Rust 的 `\u{hhhh}` 码点写法 → ICU 的 `\x{hhhh}`；其余（`\x{}`、
  /// `\p{Alphabetic}`、`(?i)(?m)(?s)`、`\A`、`\b`）ICU 原生支持。
  /// 不开 `.useUnicodeWordBoundaries`，保持与 Rust `\b` 的简单词边界语义一致。
  public static func compile(_ pattern: String) throws -> NSRegularExpression {
    try NSRegularExpression(pattern: normalize(pattern))
  }

  /// `\u{hhhh}` → `\x{hhhh}`。只在反斜杠未被转义时替换（`\\u{` 不动）。
  static func normalize(_ pattern: String) -> String {
    guard pattern.contains("\\u{") else { return pattern }
    var output = ""
    let iterator = Array(pattern)
    var index = 0
    var pendingBackslash = false
    while index < iterator.count {
      let ch = iterator[index]
      if pendingBackslash {
        // 已消费一个 `\`：若紧跟 `u{`，改写为 `x{`；否则原样输出。
        if ch == "u", index + 1 < iterator.count, iterator[index + 1] == "{" {
          output.append("x")
        } else {
          output.append(ch)
        }
        pendingBackslash = false
      } else if ch == "\\" {
        output.append(ch)
        pendingBackslash = true
      } else {
        output.append(ch)
      }
      index += 1
    }
    return output
  }
}

// MARK: - 严格 JSON 解码

/// 拒绝未知字段的 JSON 解码：模仿 herdr serde `deny_unknown_fields`，拼错的键必须硬失败。
enum AgentDetectionStrictJSONDecoder {
  static let manifestKeys: Set<String> = [
    "id", "version", "min_engine_version", "updated_at", "aliases", "rules",
  ]
  static let ruleKeys: Set<String> = [
    "id", "state", "priority", "region", "visible_idle", "visible_blocker", "visible_working",
    "skip_state_update", "all", "any", "not", "contains", "regex", "line_regex",
  ]
  static let gateKeys: Set<String> = ["all", "any", "not", "contains", "regex", "line_regex"]

  /// 先用 JSONSerialization 扫一遍键名，再交给 JSONDecoder 做类型解码。
  static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
    guard let data = json.data(using: .utf8) else {
      throw AgentDetectionManifestError.invalidJSON("not UTF-8")
    }
    let object: Any
    do {
      object = try JSONSerialization.jsonObject(with: data)
    } catch {
      throw AgentDetectionManifestError.invalidJSON(error.localizedDescription)
    }
    guard let root = object as? [String: Any] else {
      throw AgentDetectionManifestError.invalidJSON("manifest must be a JSON object")
    }
    try checkUnknownKeys(root, allowed: manifestKeys, context: "manifest")
    if let rules = root["rules"] as? [Any] {
      for rule in rules {
        guard let rule = rule as? [String: Any] else { continue }
        try checkUnknownKeys(rule, allowed: ruleKeys, context: "rule")
        try checkGateKeys(in: rule)
      }
    }
    do {
      return try JSONDecoder().decode(type, from: data)
    } catch {
      throw AgentDetectionManifestError.invalidJSON(String(describing: error))
    }
  }

  /// 递归检查 all/any/not 内的 gate 是否只用了允许的键。
  static func checkGateKeys(in container: [String: Any]) throws {
    for key in ["all", "any", "not"] {
      guard let gates = container[key] as? [Any] else { continue }
      for gate in gates {
        guard let gate = gate as? [String: Any] else { continue }
        try checkUnknownKeys(gate, allowed: gateKeys, context: "\(key) gate")
        try checkGateKeys(in: gate)
      }
    }
  }

  static func checkUnknownKeys(_ object: [String: Any], allowed: Set<String>, context: String)
    throws
  {
    let unknown = Set(object.keys).subtracting(allowed)
    if let first = unknown.sorted().first {
      throw AgentDetectionManifestError.unknownField("\(context) has unknown field `\(first)`")
    }
  }
}
