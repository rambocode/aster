import Foundation
import Testing

@testable import AsterCore

/// 「视图」配置：标签规则匹配、标题模板渲染、详情面板顺序与旧配置兼容。
@Test func tabRulesResolveFirstMatchPerField() {
  let rules = [
    TabTitleRule(conditions: [TabRuleCondition(kind: .path, pattern: "~/Workplace/otty")], alias: "otty"),
    TabTitleRule(conditions: [TabRuleCondition(kind: .agent, pattern: "claude")], icon: TabRuleIcon(name: "claude")),
    TabTitleRule(conditions: [], title: "${alias|folder} · ${branch|'no-branch'}"),
  ]
  let context = TabTitleContext(
    cwd: "/Users/me/Workplace/otty/src", agent: "claude", homeDirectory: "/Users/me")
  let resolved = TabTitleRuleResolver.resolve(rules: rules, context: context)
  #expect(resolved.alias == "otty")
  #expect(resolved.icon?.name == "claude")
  #expect(
    TabTitleRuleResolver.render(template: resolved.titleTemplate!, context: context, alias: resolved.alias)
      == "otty · no-branch")
}

@Test func tabRuleConditionsAreConjunctive() {
  let rule = TabTitleRule(conditions: [
    TabRuleCondition(kind: .host, pattern: "*.prod.internal"),
    TabRuleCondition(kind: .command, pattern: "ssh*"),
  ], alias: "prod")
  let both = TabTitleContext(cwd: "/tmp", command: "ssh", host: "db.prod.internal")
  let hostOnly = TabTitleContext(cwd: "/tmp", host: "db.prod.internal")
  #expect(TabTitleRuleResolver.matches(rule, context: both))
  #expect(!TabTitleRuleResolver.matches(rule, context: hostOnly))
}

@Test func tabTitleTemplateVariables() {
  let context = TabTitleContext(
    cwd: "/Users/me/proj", file: "/Users/me/proj/README.md", shell: "zsh", index: 3, homeDirectory: "/Users/me")
  #expect(TabTitleRuleResolver.render(template: "${cwd}", context: context, alias: nil) == "~/proj")
  #expect(TabTitleRuleResolver.render(template: "${index}:${shell}", context: context, alias: nil) == "3:zsh")
  #expect(TabTitleRuleResolver.render(template: "${file}", context: context, alias: nil) == "README.md")
  #expect(TabTitleRuleResolver.render(template: "${host}", context: context, alias: nil) == nil)
  #expect(TabTitleRuleResolver.render(template: "plain", context: context, alias: nil) == "plain")
}

@Test func globMatching() {
  #expect(TabTitleRuleResolver.glob("*.md", matches: "notes.md"))
  #expect(TabTitleRuleResolver.glob("ssh *", matches: "ssh host"))
  #expect(!TabTitleRuleResolver.glob("ssh *", matches: "sshd"))
  #expect(TabTitleRuleResolver.glob("a?c", matches: "abc"))
}

@Test func detailsPanelEntriesHonorOrderAndVisibility() {
  var config = ViewConfiguration()
  let custom = DetailsPanelCustomView(kind: .web, name: "Docs", url: "http://localhost:3000")
  let hidden = DetailsPanelCustomView(kind: .tui, name: "Hidden", command: "htop", enabled: false)
  config.detailsPanelCustomViews = [custom, hidden]
  config.detailsPanelSections = [
    DetailsPanelSectionSetting(id: "git", enabled: true),
    DetailsPanelSectionSetting(id: "info", enabled: false),
    DetailsPanelSectionSetting(id: "bogus", enabled: true),
  ]
  config.detailsPanelOrder = ["custom:\(custom.id.uuidString)", "builtin:git"]
  let entries = config.resolvedDetailsPanelEntries
  #expect(entries.first == .custom(custom.id))
  #expect(entries.contains(.builtin("outline")))
  #expect(!entries.contains(.builtin("info")))
  #expect(!entries.contains(.custom(hidden.id)))
  #expect(config.resolvedDetailsPanelSections.map(\.id) == ["git", "info", "outline", "files", "history"])
}

@Test func configurationWithoutViewBlockStillDecodes() throws {
  let data = try JSONEncoder().encode(AsterConfiguration.default)
  var object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
  object.removeValue(forKey: "view")
  let stripped = try JSONSerialization.data(withJSONObject: object)
  let decoded = try JSONDecoder().decode(AsterConfiguration.self, from: stripped)
  #expect(decoded.resolvedView.resolvedBadgePlacement == .combined)
  #expect(decoded.normalized().view != nil)
}

@Test func viewConfigurationNormalizationStripsControlCharacters() {
  var config = ViewConfiguration()
  config.tabRules = [
    TabTitleRule(conditions: [TabRuleCondition(kind: .path, pattern: "")], alias: "a\u{07}b", title: "  "),
  ]
  config.detailsPanelCustomViews = [DetailsPanelCustomView(kind: .tui, name: "", command: "x")]
  let normalized = config.normalized()
  #expect(normalized.resolvedTabRules.first?.alias == "ab")
  #expect(normalized.resolvedTabRules.first?.title == nil)
  #expect(normalized.resolvedTabRules.first?.conditions.isEmpty == true)
  #expect(normalized.resolvedCustomViews.isEmpty)
}

@Test func detailsPanelViewTemplateSubstitutesPid() {
  let context = TabTitleContext(cwd: "/tmp/x", homeDirectory: "/Users/me")
  #expect(DetailsPanelViewTemplate.render("lazydocker ${cwd} ${pid}", context: context, alias: nil, pid: 42) == "lazydocker /tmp/x 42")
}
