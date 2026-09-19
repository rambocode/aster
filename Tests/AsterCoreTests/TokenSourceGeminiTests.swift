// GeminiTokenSource 的行为测试：cached 从 input 扣除、thoughts 计入 output、.project_root 缺失。
import Foundation
import Testing

@testable import AsterCore

@Suite("TokenSource Gemini 聊天记录解析")
struct TokenSourceGeminiTests {
  /// 新版逐行格式的脱敏夹具。
  private func makeHome(projectRoot: String?) -> TemporaryDirectory {
    let home = TemporaryDirectory()
    let lines = [
      "{\"sessionId\":\"s-1\",\"projectHash\":\"h\",\"startTime\":\"2026-06-20T17:00:00.000Z\",\"lastUpdated\":\"2026-06-20T18:00:00.000Z\",\"kind\":\"chat\"}",
      "{\"type\":\"user\",\"id\":\"u-1\",\"timestamp\":\"2026-06-20T17:21:00.000Z\",\"content\":\"…\"}",
      "{\"type\":\"gemini\",\"id\":\"g-1\",\"timestamp\":\"2026-06-20T17:21:35.633Z\",\"model\":\"…\",\"content\":\"…\",\"thoughts\":\"…\",\"tokens\":{\"input\":1000,\"output\":50,\"cached\":800,\"thoughts\":30,\"tool\":7,\"total\":1087}}",
      // 同一条消息被重写一次，内容相同，按 id 去重。
      "{\"type\":\"gemini\",\"id\":\"g-1\",\"timestamp\":\"2026-06-20T17:21:35.633Z\",\"model\":\"…\",\"content\":\"…\",\"thoughts\":\"…\",\"tokens\":{\"input\":1000,\"output\":50,\"cached\":800,\"thoughts\":30,\"tool\":7,\"total\":1087}}",
      "{\"$set\":{\"lastUpdated\":\"2026-06-21T00:40:00.000Z\"}}",
      "{\"type\":\"gemini\",\"id\":\"g-2\",\"timestamp\":\"2026-06-21T00:40:00.000Z\",\"tokens\":{\"input\":12,\"output\":3,\"cached\":0,\"thoughts\":0,\"tool\":0,\"total\":15}}",
    ]
    home.write(
      lines.joined(separator: "\n") + "\n",
      to: ".gemini/tmp/alpha/chats/session-2026-06-20T17-00-abcdef12.jsonl")
    if let projectRoot { home.write(projectRoot + "\n", to: ".gemini/tmp/alpha/.project_root") }
    return home
  }

  @Test("cached 从 input 扣除，thoughts 与 tool 各归其位，总量守恒")
  func mapsTokenColumns() {
    let home = makeHome(projectRoot: "/work/alpha")
    let source = GeminiTokenSource()
    let files = source.discoverFiles(homeDirectory: home.url)
    #expect(files.count == 1)

    let buckets = source.buckets(of: files[0], context: FixedTokenScanContext())
    // input = 1000-800+7 = 207，output = 50+30 = 80，cacheWrite 恒为 0。
    let first = totals(in: buckets, day: 20624)
    #expect(first == TokenTotals(input: 207, cacheWrite: 0, cacheRead: 800, output: 80))
    #expect(first?.total == 1087)
  }

  @Test("同一条消息 id 只计一次")
  func deduplicatesByRecordID() {
    let home = makeHome(projectRoot: "/work/alpha")
    let source = GeminiTokenSource()
    let buckets = source.buckets(
      of: source.discoverFiles(homeDirectory: home.url)[0], context: FixedTokenScanContext())
    #expect(totals(in: buckets, day: 20624)?.cacheRead == 800)
    #expect(totals(in: buckets, day: 20625) == TokenTotals(input: 12, output: 3))
  }

  @Test("读取同级 .project_root 作为项目路径")
  func readsProjectRoot() {
    let home = makeHome(projectRoot: "/work/alpha")
    let source = GeminiTokenSource()
    let buckets = source.buckets(
      of: source.discoverFiles(homeDirectory: home.url)[0], context: FixedTokenScanContext())
    #expect(buckets.allSatisfy { $0.project == "/work/alpha" })
  }

  @Test(".project_root 缺失时归到其他")
  func missingProjectRootFallsBack() {
    let home = makeHome(projectRoot: nil)
    let source = GeminiTokenSource()
    let buckets = source.buckets(
      of: source.discoverFiles(homeDirectory: home.url)[0], context: FixedTokenScanContext())
    #expect(!buckets.isEmpty)
    #expect(buckets.allSatisfy { $0.project == TokenProject.otherKey })
  }

  @Test("旧版单文件 JSON 格式同样解析")
  func parsesLegacySingleFile() {
    let home = TemporaryDirectory()
    let legacy = """
      {"sessionId":"s-9","projectHash":"h","startTime":"2026-06-20T17:00:00.000Z",\
      "lastUpdated":"2026-06-20T17:30:00.000Z","kind":"chat","messages":[\
      {"type":"user","id":"u-1","timestamp":"2026-06-20T17:00:10.000Z","content":"…"},\
      {"type":"gemini","id":"g-1","timestamp":"2026-06-20T17:21:35.633Z","content":"…",\
      "tokens":{"input":500,"output":20,"cached":100,"thoughts":5,"tool":0,"total":425}}]}
      """
    home.write(legacy, to: ".gemini/tmp/legacy/chats/session-2026-06-20T17-00-99887766.json")
    home.write("/work/legacy\n", to: ".gemini/tmp/legacy/.project_root")

    let source = GeminiTokenSource()
    let files = source.discoverFiles(homeDirectory: home.url)
    #expect(files.count == 1)
    let buckets = source.buckets(of: files[0], context: FixedTokenScanContext())
    #expect(
      totals(in: buckets, day: 20624)
        == TokenTotals(input: 400, cacheWrite: 0, cacheRead: 100, output: 25))
    #expect(buckets.map(\.project) == ["/work/legacy"])
  }

  @Test("数据目录不存在时返回空")
  func missingDirectoryYieldsNothing() {
    let home = TemporaryDirectory()
    #expect(GeminiTokenSource().discoverFiles(homeDirectory: home.url).isEmpty)
  }
}
