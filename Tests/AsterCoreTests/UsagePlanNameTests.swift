import Foundation
import Testing

@testable import AsterCore

// 订阅档位标识 → 展示名。各家格式不同但形状一样：小写下划线分段。

@Suite("UsagePlanName")
struct UsagePlanNameTests {
  @Test("Claude 的 rateLimitTier 剥掉 default_ / claude_ 前缀后分段首字母大写")
  func claudeTierNames() throws {
    let cases = [
      ("default_claude_max_20x", "Max 20x"),
      ("default_claude_max_5x", "Max 5x"),
      ("default_claude_pro", "Pro"),
      ("claude_pro", "Pro"),
      ("max_20x", "Max 20x"),
    ]
    for (raw, expected) in cases {
      #expect(
        UsagePlanName.normalized(raw, strippingPrefixes: ["default_", "claude_"]) == expected,
        "\(raw)")
    }
  }

  // `20x` 不能被整体 capitalized 成 `20X`，所以只大写每段首字母。
  @Test("只大写每段首字母，数字开头的段原样保留")
  func onlyFirstLetterIsUppercased() {
    #expect(UsagePlanName.normalized("business_starter") == "Business Starter")
    #expect(UsagePlanName.normalized("20x") == "20x")
    #expect(UsagePlanName.normalized("MAX_20X") == "Max 20x")
  }

  @Test("Codex 的 planType 直接分段大写，不剥前缀")
  func codexPlanTypes() {
    #expect(UsagePlanName.normalized("pro") == "Pro")
    #expect(UsagePlanName.normalized("plus") == "Plus")
    #expect(UsagePlanName.normalized("team") == "Team")
    #expect(UsagePlanName.normalized("enterprise") == "Enterprise")
  }

  @Test("空值、超长、剥完为空一律返回 nil")
  func rejectsUnusableInput() {
    #expect(UsagePlanName.normalized(nil) == nil)
    #expect(UsagePlanName.normalized("") == nil)
    #expect(UsagePlanName.normalized("   ") == nil)
    #expect(UsagePlanName.normalized("___") == nil)
    #expect(UsagePlanName.normalized(String(repeating: "a", count: 65)) == nil)
    // 分段过多说明拿到的不是档位标识。
    #expect(UsagePlanName.normalized("a_b_c_d_e_f_g") == nil)
    // 前缀等于整个值时不剥，避免剥成空串。
    #expect(UsagePlanName.normalized("default_", strippingPrefixes: ["default_"]) == "Default")
  }
}

@Suite("UsagePlanNameFromCredentials")
struct ClaudePlanNameTests {
  @Test("优先 rateLimitTier，缺失时退到 subscriptionType")
  func prefersRateLimitTier() {
    let full = Data(
      #"{"claudeAiOauth":{"accessToken":"tok","rateLimitTier":"default_claude_max_20x","subscriptionType":"max"}}"#
        .utf8)
    #expect(ClaudeAccountQuotaParser.planName(fromCredentials: full) == "Max 20x")

    let tierless = Data(#"{"claudeAiOauth":{"accessToken":"tok","subscriptionType":"max"}}"#.utf8)
    #expect(ClaudeAccountQuotaParser.planName(fromCredentials: tierless) == "Max")

    // tier 存在但是空串：不能因此吞掉 subscriptionType。
    let emptyTier = Data(
      #"{"claudeAiOauth":{"rateLimitTier":"","subscriptionType":"pro"}}"#.utf8)
    #expect(ClaudeAccountQuotaParser.planName(fromCredentials: emptyTier) == "Pro")
  }

  @Test("扁平结构与缺字段")
  func flatAndMissing() {
    // 没有 claudeAiOauth 包装的老格式。
    #expect(
      ClaudeAccountQuotaParser.planName(
        fromCredentials: Data(#"{"rateLimitTier":"default_claude_pro"}"#.utf8)) == "Pro")
    #expect(ClaudeAccountQuotaParser.planName(fromCredentials: Data("{}".utf8)) == nil)
    #expect(ClaudeAccountQuotaParser.planName(fromCredentials: Data("not json".utf8)) == nil)
  }
}
