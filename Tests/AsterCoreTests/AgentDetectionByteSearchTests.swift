import Foundation
import Testing

@testable import AsterCore

/// `contains` 门的字节级子串搜索：结果必须与原先的 `String.contains` 语义一致。
@Suite("AgentDetectionByteSearch")
struct AgentDetectionByteSearchTests {
  private static func contains(_ haystack: String, _ needle: String) -> Bool {
    CompiledAgentManifest.CompiledGate.bytes(
      ContiguousArray(haystack.utf8), contain: ContiguousArray(needle.utf8))
  }

  @Test("命中位置在开头、中间、结尾都能找到")
  func findsNeedleAtAnyPosition() {
    #expect(Self.contains("esc to interrupt", "esc"))
    #expect(Self.contains("press esc to interrupt", "esc to"))
    #expect(Self.contains("press esc to interrupt", "interrupt"))
    #expect(Self.contains("interrupt", "interrupt"))
  }

  @Test("首字节重复出现时不会漏掉后面的真正匹配")
  func handlesRepeatedFirstByte() {
    #expect(Self.contains("aaab", "aab"))
    #expect(Self.contains("eesc esc", "esc e"))
    #expect(!Self.contains("aaaa", "aab"))
  }

  @Test("空 needle、过长 needle 与空文本都不命中")
  func rejectsDegenerateInputs() {
    #expect(!Self.contains("anything", ""))
    #expect(!Self.contains("", "x"))
    #expect(!Self.contains("short", "much longer needle"))
    #expect("anything".contains("") == Self.contains("anything", ""))
  }

  @Test("多字节字符按完整 UTF-8 序列匹配")
  func matchesMultibyteCharacters() {
    #expect(Self.contains("• working (4s • esc to interrupt)", "• esc"))
    #expect(Self.contains("正在思考… 按 esc 中断", "思考…"))
    #expect(!Self.contains("正在思考", "思索"))
  }

  @Test("规则的 contains 门仍然大小写不敏感")
  func containsGateStaysCaseInsensitive() throws {
    let compiled = try CompiledAgentManifest(
      manifest: AgentDetectionManifest.decode(
        json: #"""
          {"id":"codex","rules":[
            {"id":"w","state":"working","priority":1,"contains":["ESC to Interrupt"]}
          ]}
          """#))
    let hit = compiled.detect(
      AgentDetectionInput(screen: "• Working (esc TO interrupt)"))
    let miss = compiled.detect(
      AgentDetectionInput(screen: "plain prompt"))
    #expect(hit.state == .working)
    #expect(miss.state == .idle)
  }
}
