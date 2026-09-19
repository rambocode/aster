// DroidTokenSource 的行为测试：会话累计量按 mtime 归日、项目固定为「其他」。
import Foundation
import Testing

@testable import AsterCore

@Suite("TokenSource droid 会话设置解析")
struct TokenSourceDroidTests {
  /// 手写脱敏夹具：一个带用量、一个不带用量的会话设置文件。
  private func makeHome() -> TemporaryDirectory {
    let home = TemporaryDirectory()
    home.write(
      "{\"assistantActiveTimeMs\":1234,\"providerLock\":\"…\",\"tokenUsage\":{\"inputTokens\":100,\"outputTokens\":900,\"cacheCreationTokens\":40,\"cacheReadTokens\":5000,\"thinkingTokens\":300}}",
      to: ".factory/sessions/11111111-1111-1111-1111-111111111111.settings.json")
    home.write(
      "{\"assistantActiveTimeMs\":7}",
      to: ".factory/sessions/22222222-2222-2222-2222-222222222222.settings.json")
    // 会话正文不是数据源，出现在同目录也不能被发现。
    home.write("{}", to: ".factory/sessions/11111111-1111-1111-1111-111111111111.jsonl")
    return home
  }

  @Test("只发现 .settings.json")
  func discoversSettingsFilesOnly() {
    let home = makeHome()
    let files = DroidTokenSource().discoverFiles(homeDirectory: home.url)
    #expect(files.count == 2)
    #expect(files.allSatisfy { $0.path.hasSuffix(".settings.json") })
  }

  @Test("四列直接映射，thinking 不重复计入 output")
  func mapsTokenUsage() {
    let home = makeHome()
    let source = DroidTokenSource()
    let file = source.discoverFiles(homeDirectory: home.url)
      .first { $0.path.contains("11111111") }
    let buckets = source.buckets(of: file!, context: FixedTokenScanContext())
    // 若误把 thinking 加进 output，这里会变成 1200。
    #expect(buckets.map(\.totals) == [TokenTotals(input: 100, cacheWrite: 40, cacheRead: 5000, output: 900)])
  }

  @Test("按文件修改时间归日，项目记为其他")
  func groupsByModificationDate() {
    let home = makeHome()
    let relative = ".factory/sessions/11111111-1111-1111-1111-111111111111.settings.json"
    home.setModificationDate(Date(timeIntervalSince1970: 1_772_839_800), at: relative)

    let source = DroidTokenSource()
    let file = source.discoverFiles(homeDirectory: home.url).first { $0.path.contains("11111111") }
    let buckets = source.buckets(of: file!, context: FixedTokenScanContext())
    #expect(buckets.count == 1)
    #expect(buckets[0].day == 20518)
    #expect(buckets[0].project == TokenProject.otherKey)
  }

  @Test("没有 tokenUsage 的会话不产生 bucket")
  func skipsSessionsWithoutUsage() {
    let home = makeHome()
    let source = DroidTokenSource()
    let file = source.discoverFiles(homeDirectory: home.url).first { $0.path.contains("22222222") }
    #expect(source.buckets(of: file!, context: FixedTokenScanContext()).isEmpty)
  }

  @Test("数据目录不存在时返回空")
  func missingDirectoryYieldsNothing() {
    let home = TemporaryDirectory()
    #expect(DroidTokenSource().discoverFiles(homeDirectory: home.url).isEmpty)
  }
}
