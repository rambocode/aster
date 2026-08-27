import Foundation

// MARK: - 标签页标题规则

/// 标签规则的匹配维度，对齐 Otty「视图 → 标签页与标题定制」的条件类型。
/// Raw value 是配置文件中的稳定标识。
public enum TabRuleMatchKind: String, CaseIterable, Codable, Equatable, Sendable {
  case path
  case command
  case agent
  case host
  case file
}

/// 单条匹配条件：`pattern` 为 glob（`*`、`?`），路径类会先展开 `~`。
public struct TabRuleCondition: Codable, Equatable, Hashable, Sendable {
  public var kind: TabRuleMatchKind
  public var pattern: String

  public init(kind: TabRuleMatchKind, pattern: String) {
    self.kind = kind
    self.pattern = pattern
  }
}

/// 标签图标：图标集名称（`Resources/settings-ui/tab-icons/<name>.svg`）或 emoji 二选一，
/// 可附带一个着色。两者都空表示未设置。
public struct TabRuleIcon: Codable, Equatable, Sendable {
  public var name: String?
  public var emoji: String?
  public var color: HexColor?

  public init(name: String? = nil, emoji: String? = nil, color: HexColor? = nil) {
    self.name = name
    self.emoji = emoji
    self.color = color
  }

  public var isEmpty: Bool {
    (name ?? "").isEmpty && (emoji ?? "").isEmpty
  }
}

/// 一条标签定制规则：匹配条件全部成立时提供别名 / 图标 / 标题模板中的任意几项。
/// 「按项排列」把它投影成三张独立列表，「按项目排列」把它当成一个项目整体编辑。
/// 数组顺序即优先级，靠前者优先。
public struct TabTitleRule: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var conditions: [TabRuleCondition]
  public var alias: String?
  public var icon: TabRuleIcon?
  public var title: String?

  public init(
    id: UUID = UUID(),
    conditions: [TabRuleCondition] = [],
    alias: String? = nil,
    icon: TabRuleIcon? = nil,
    title: String? = nil
  ) {
    self.id = id
    self.conditions = conditions
    self.alias = alias
    self.icon = icon
    self.title = title
  }

  public var hasAlias: Bool { !(alias ?? "").isEmpty }
  public var hasIcon: Bool { !(icon?.isEmpty ?? true) }
  public var hasTitle: Bool { !(title ?? "").isEmpty }
}

/// 设置页里规则的排列方式（纯 UI 状态，但需跨启动保留）。
public enum TabRuleArrangement: String, CaseIterable, Codable, Equatable, Sendable {
  case byItem
  case byProject
}

/// 标签上图标与状态角标的摆放方式。`combined` 共用一个指示位，`separate` 图标在左、角标在右。
public enum TabBadgePlacement: String, CaseIterable, Codable, Equatable, Sendable {
  case combined
  case separate
}

// MARK: - 详情面板

/// 详情面板内置页的显示与顺序设置；`id` 对应 `DetailsPanelViewController.Section` 的稳定名。
public struct DetailsPanelSectionSetting: Codable, Equatable, Identifiable, Sendable {
  public var id: String
  public var enabled: Bool

  public init(id: String, enabled: Bool) {
    self.id = id
    self.enabled = enabled
  }

  /// 内置页的默认顺序；未列出的 id 一律视为未知并忽略。
  public static let builtinIDs = ["info", "outline", "git", "files", "history"]

  public static let defaults = builtinIDs.map { DetailsPanelSectionSetting(id: $0, enabled: true) }
}

/// 自定义详情视图类型：面板内终端程序或网页。
public enum DetailsPanelCustomViewKind: String, CaseIterable, Codable, Equatable, Sendable {
  case tui
  case web
}

/// 用户添加的详情面板视图。`command` / `url` / `folder` 支持 `${cwd}` 等变量。
public struct DetailsPanelCustomView: Codable, Equatable, Identifiable, Sendable {
  public var id: UUID
  public var kind: DetailsPanelCustomViewKind
  public var name: String
  public var command: String
  public var url: String
  public var mobile: Bool
  public var folder: String
  public var enabled: Bool

  public init(
    id: UUID = UUID(),
    kind: DetailsPanelCustomViewKind,
    name: String,
    command: String = "",
    url: String = "",
    mobile: Bool = false,
    folder: String = "",
    enabled: Bool = true
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.command = command
    self.url = url
    self.mobile = mobile
    self.folder = folder
    self.enabled = enabled
  }
}

/// 详情面板一条页签的排序项：内置页或自定义视图。
public enum DetailsPanelEntry: Equatable, Sendable {
  case builtin(String)
  case custom(UUID)
}

// MARK: - 视图配置

/// 「视图」分类的全部设置。字段均为可选以兼容旧配置文件；通过 `resolved*` 读取默认值。
public struct ViewConfiguration: Codable, Equatable, Sendable {
  public var rulesArrangement: TabRuleArrangement?
  public var tabRules: [TabTitleRule]?
  public var badgePlacement: TabBadgePlacement?
  public var webPanePersistData: Bool?
  public var detailsPanelSections: [DetailsPanelSectionSetting]?
  public var detailsPanelCustomViews: [DetailsPanelCustomView]?
  /// 内置页与自定义视图混排后的整体顺序（`builtin:<id>` / `custom:<uuid>`）。
  /// 缺省时内置页在前、自定义视图按添加顺序在后。
  public var detailsPanelOrder: [String]?

  public init() {}

  public var resolvedRulesArrangement: TabRuleArrangement { rulesArrangement ?? .byItem }
  public var resolvedTabRules: [TabTitleRule] { tabRules ?? [] }
  public var resolvedBadgePlacement: TabBadgePlacement { badgePlacement ?? .combined }
  public var resolvedWebPanePersistData: Bool { webPanePersistData ?? true }
  public var resolvedCustomViews: [DetailsPanelCustomView] { detailsPanelCustomViews ?? [] }

  /// 内置页设置：补齐缺失的内置 id（按默认顺序追加、默认开启），丢弃未知 id 和重复项。
  public var resolvedDetailsPanelSections: [DetailsPanelSectionSetting] {
    var seen: Set<String> = []
    var result: [DetailsPanelSectionSetting] = []
    for item in detailsPanelSections ?? [] where DetailsPanelSectionSetting.builtinIDs.contains(item.id) {
      guard seen.insert(item.id).inserted else { continue }
      result.append(item)
    }
    for id in DetailsPanelSectionSetting.builtinIDs where !seen.contains(id) {
      result.append(DetailsPanelSectionSetting(id: id, enabled: true))
    }
    return result
  }

  /// 面板页签的最终顺序（仅包含启用项）。
  public var resolvedDetailsPanelEntries: [DetailsPanelEntry] {
    let sections = resolvedDetailsPanelSections
    let customViews = resolvedCustomViews
    return allDetailsPanelEntries.filter { entry in
      switch entry {
      case .builtin(let id): return sections.first { $0.id == id }?.enabled ?? false
      case .custom(let id): return customViews.first { $0.id == id }?.enabled ?? false
      }
    }
  }

  /// 面板页签的完整顺序（含隐藏项，供设置页列表使用）。`detailsPanelOrder` 里未提到的项
  /// 按默认规则补在末尾。
  public var allDetailsPanelEntries: [DetailsPanelEntry] {
    let sections = resolvedDetailsPanelSections
    let customViews = resolvedCustomViews
    var remaining: [DetailsPanelEntry] =
      sections.map { .builtin($0.id) } + customViews.map { .custom($0.id) }
    var ordered: [DetailsPanelEntry] = []
    for token in detailsPanelOrder ?? [] {
      let entry: DetailsPanelEntry?
      if token.hasPrefix("builtin:") {
        entry = .builtin(String(token.dropFirst("builtin:".count)))
      } else if token.hasPrefix("custom:"), let id = UUID(uuidString: String(token.dropFirst("custom:".count))) {
        entry = .custom(id)
      } else {
        entry = nil
      }
      guard let entry, let index = remaining.firstIndex(of: entry) else { continue }
      ordered.append(remaining.remove(at: index))
    }
    ordered.append(contentsOf: remaining)
    return ordered
  }

  /// 导入 / 反序列化边界的清理：控制字符、超长字段、超量规则一律裁掉，避免用户文件
  /// 把异常内容带进侧栏与详情面板。
  public func normalized() -> ViewConfiguration {
    var result = self
    result.tabRules = resolvedTabRules.prefix(256).compactMap { rule -> TabTitleRule? in
      var rule = rule
      rule.conditions = rule.conditions.prefix(16).compactMap { condition in
        let pattern = Self.clean(condition.pattern, limit: 1_024)
        return pattern.isEmpty ? nil : TabRuleCondition(kind: condition.kind, pattern: pattern)
      }
      rule.alias = rule.alias.map { Self.clean($0, limit: 128) }.flatMap { $0.isEmpty ? nil : $0 }
      rule.title = rule.title.map { Self.clean($0, limit: 512) }.flatMap { $0.isEmpty ? nil : $0 }
      if var icon = rule.icon {
        icon.name = icon.name.map { Self.clean($0, limit: 64) }.flatMap { $0.isEmpty ? nil : $0 }
        icon.emoji = icon.emoji.map { String(Self.clean($0, limit: 32).prefix(2)) }.flatMap { $0.isEmpty ? nil : $0 }
        rule.icon = icon.isEmpty ? nil : icon
      }
      return rule
    }
    result.detailsPanelCustomViews = resolvedCustomViews.prefix(64).compactMap { view -> DetailsPanelCustomView? in
      var view = view
      view.name = Self.clean(view.name, limit: 64)
      view.command = Self.clean(view.command, limit: 2_048)
      view.url = Self.clean(view.url, limit: 4_096)
      view.folder = Self.clean(view.folder, limit: 1_024)
      return view.name.isEmpty ? nil : view
    }
    result.detailsPanelSections = resolvedDetailsPanelSections
    result.detailsPanelOrder = (detailsPanelOrder ?? []).prefix(512).map { Self.clean($0, limit: 64) }
    return result
  }

  private static func clean(_ value: String, limit: Int) -> String {
    let visible = value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }
    var result = ""
    var bytes = 0
    for character in String(String.UnicodeScalarView(visible)) {
      let size = String(character).utf8.count
      guard bytes + size <= limit else { break }
      result.append(character)
      bytes += size
    }
    return result.trimmingCharacters(in: .whitespacesAndNewlines)
  }
}

// MARK: - 规则解析

/// 解析规则时可用的标签上下文。所有字段都是展示层已经拥有的值，解析本身不做 I/O
/// （git 分支由调用方按目录缓存后传入）。
public struct TabTitleContext: Equatable, Sendable {
  public var cwd: String
  public var file: String?
  public var command: String?
  public var agent: String?
  public var host: String?
  public var user: String?
  public var branch: String?
  public var programTitle: String?
  public var shell: String
  public var index: Int
  public var homeDirectory: String

  public init(
    cwd: String,
    file: String? = nil,
    command: String? = nil,
    agent: String? = nil,
    host: String? = nil,
    user: String? = nil,
    branch: String? = nil,
    programTitle: String? = nil,
    shell: String = "zsh",
    index: Int = 1,
    homeDirectory: String = NSHomeDirectory()
  ) {
    self.cwd = cwd
    self.file = file
    self.command = command
    self.agent = agent
    self.host = host
    self.user = user
    self.branch = branch
    self.programTitle = programTitle
    self.shell = shell
    self.index = index
    self.homeDirectory = homeDirectory
  }

  /// 工作目录最后一段；根目录或空目录时为空串。
  public var folder: String {
    let trimmed = cwd.hasSuffix("/") && cwd.count > 1 ? String(cwd.dropLast()) : cwd
    let last = (trimmed as NSString).lastPathComponent
    return last == "/" ? "" : last
  }

  /// 主目录缩写为 `~` 的工作目录。
  public var abbreviatedCwd: String {
    guard !homeDirectory.isEmpty else { return cwd }
    if cwd == homeDirectory { return "~" }
    if cwd.hasPrefix(homeDirectory + "/") { return "~" + cwd.dropFirst(homeDirectory.count) }
    return cwd
  }
}

/// 规则解析结果：三个字段各自独立取「最先匹配且提供该字段」的规则。
public struct TabTitleResolution: Equatable, Sendable {
  public var alias: String?
  public var icon: TabRuleIcon?
  public var titleTemplate: String?

  public init(alias: String? = nil, icon: TabRuleIcon? = nil, titleTemplate: String? = nil) {
    self.alias = alias
    self.icon = icon
    self.titleTemplate = titleTemplate
  }

  public var isEmpty: Bool { alias == nil && icon == nil && titleTemplate == nil }
}

/// 标签定制规则的匹配与模板渲染。纯函数，可在 AsterCore 测试中独立验证。
public enum TabTitleRuleResolver {
  /// 逐条评估规则；条件为空的规则匹配所有标签。三个字段各取首个命中值。
  public static func resolve(rules: [TabTitleRule], context: TabTitleContext) -> TabTitleResolution {
    var result = TabTitleResolution()
    for rule in rules where matches(rule, context: context) {
      if result.alias == nil, rule.hasAlias { result.alias = rule.alias }
      if result.icon == nil, rule.hasIcon { result.icon = rule.icon }
      if result.titleTemplate == nil, rule.hasTitle { result.titleTemplate = rule.title }
      if result.alias != nil, result.icon != nil, result.titleTemplate != nil { break }
    }
    return result
  }

  /// 规则的全部条件都必须成立（AND）。
  public static func matches(_ rule: TabTitleRule, context: TabTitleContext) -> Bool {
    rule.conditions.allSatisfy { matches($0, context: context) }
  }

  /// 单条条件匹配。路径条件对目录本身及其子目录都成立，模式里的 `~` 先展开成主目录。
  public static func matches(_ condition: TabRuleCondition, context: TabTitleContext) -> Bool {
    let pattern = condition.pattern.trimmingCharacters(in: .whitespaces)
    guard !pattern.isEmpty else { return true }
    switch condition.kind {
    case .path:
      let expanded = expandTilde(pattern, home: context.homeDirectory)
      let target = context.cwd
      if glob(expanded, matches: target) { return true }
      // 不含通配符的路径视作前缀：`~/Workplace/otty` 也应命中它的子目录。
      guard !expanded.contains("*"), !expanded.contains("?") else { return false }
      let prefix = expanded.hasSuffix("/") ? expanded : expanded + "/"
      return target.hasPrefix(prefix)
    case .command:
      guard let command = context.command, !command.isEmpty else { return false }
      return glob(pattern, matches: command)
    case .agent:
      guard let agent = context.agent, !agent.isEmpty else { return false }
      return glob(pattern, matches: agent)
    case .host:
      guard let host = context.host, !host.isEmpty else { return false }
      return glob(pattern, matches: host)
    case .file:
      guard let file = context.file, !file.isEmpty else { return false }
      return glob(pattern, matches: file) || glob(pattern, matches: (file as NSString).lastPathComponent)
    }
  }

  /// 渲染标题模板。`${var}` 直接替换；`${a|b|'literal'}` 取第一个非空值。未知变量视为空。
  /// 结果为空时返回 nil，让调用方回落到自动标题。
  public static func render(template: String, context: TabTitleContext, alias: String?) -> String? {
    var output = ""
    var cursor = template.startIndex
    while cursor < template.endIndex {
      guard template[cursor...].hasPrefix("${"),
        let close = template[cursor...].firstIndex(of: "}")
      else {
        output.append(template[cursor])
        cursor = template.index(after: cursor)
        continue
      }
      let inner = template[template.index(cursor, offsetBy: 2)..<close]
      output.append(resolveExpression(String(inner), context: context, alias: alias))
      cursor = template.index(after: close)
    }
    let trimmed = output.trimmingCharacters(in: .whitespaces)
    return trimmed.isEmpty ? nil : trimmed
  }

  /// `${…}` 内部：按 `|` 拆成候选，单引号包裹的候选是字面量。
  private static func resolveExpression(_ expression: String, context: TabTitleContext, alias: String?) -> String {
    for candidate in expression.split(separator: "|", omittingEmptySubsequences: false) {
      let token = candidate.trimmingCharacters(in: .whitespaces)
      if token.hasPrefix("'"), token.hasSuffix("'"), token.count >= 2 {
        let literal = String(token.dropFirst().dropLast())
        if !literal.isEmpty { return literal }
        continue
      }
      let value = variable(token, context: context, alias: alias)
      if !value.isEmpty { return value }
    }
    return ""
  }

  /// 模板变量表，与 Otty `${…}` 变量一一对应。
  public static let variableNames = [
    "alias", "cwd", "folder", "user", "host", "agent", "branch", "command", "title", "shell", "index", "file",
  ]

  public static func variable(_ name: String, context: TabTitleContext, alias: String?) -> String {
    switch name {
    case "alias": return alias ?? ""
    case "cwd": return context.abbreviatedCwd
    case "folder": return context.folder
    case "user": return context.user ?? NSUserName()
    case "host": return context.host ?? ""
    case "agent": return context.agent ?? ""
    case "branch": return context.branch ?? ""
    case "command": return context.command ?? ""
    case "title": return context.programTitle ?? ""
    case "shell": return context.shell
    case "index": return String(context.index)
    case "file": return context.file.map { ($0 as NSString).lastPathComponent } ?? ""
    default: return ""
    }
  }

  static func expandTilde(_ pattern: String, home: String) -> String {
    if pattern == "~" { return home }
    if pattern.hasPrefix("~/") { return home + pattern.dropFirst() }
    return pattern
  }

  /// 最小 glob：`*` 匹配任意串（含 `/`），`?` 匹配单字符；大小写敏感。
  public static func glob(_ pattern: String, matches value: String) -> Bool {
    let p = Array(pattern)
    let v = Array(value)
    var pi = 0, vi = 0
    var starP = -1, starV = -1
    while vi < v.count {
      if pi < p.count, p[pi] == "*" {
        starP = pi
        starV = vi
        pi += 1
      } else if pi < p.count, p[pi] == "?" || p[pi] == v[vi] {
        pi += 1
        vi += 1
      } else if starP >= 0 {
        pi = starP + 1
        starV += 1
        vi = starV
      } else {
        return false
      }
    }
    while pi < p.count, p[pi] == "*" { pi += 1 }
    return pi == p.count
  }
}

/// 自定义详情视图里 `${cwd}` 等变量的替换；与标题模板共用变量表，另加 `pid`。
public enum DetailsPanelViewTemplate {
  public static func render(_ template: String, context: TabTitleContext, alias: String?, pid: Int32?) -> String {
    var output = ""
    var cursor = template.startIndex
    while cursor < template.endIndex {
      guard template[cursor...].hasPrefix("${"),
        let close = template[cursor...].firstIndex(of: "}")
      else {
        output.append(template[cursor])
        cursor = template.index(after: cursor)
        continue
      }
      let name = template[template.index(cursor, offsetBy: 2)..<close].trimmingCharacters(in: .whitespaces)
      switch name {
      case "pid": output.append(pid.map(String.init) ?? "")
      case "cwd": output.append(context.cwd)
      case "file": output.append(context.file ?? "")
      default: output.append(TabTitleRuleResolver.variable(name, context: context, alias: alias))
      }
      cursor = template.index(after: close)
    }
    return output
  }
}
