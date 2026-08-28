import Foundation
import Testing

@testable import AsterCore

/// 短 ID 解析与注册表行为。
struct AsterControlIdentityTests {
  @Test("selector 解析：短 ID、legacy UUID、current、agent name")
  func selectorParsing() {
    #expect(ControlTargetSelector(parsing: "w1") == .window(.init(number: 1)))
    #expect(ControlTargetSelector(parsing: "w12:t3") == .tab(.init(window: .init(number: 12), number: 3)))
    #expect(ControlTargetSelector(parsing: " w1:p5 ") == .pane(.init(window: .init(number: 1), number: 5)))
    #expect(ControlTargetSelector(parsing: "w1:x5") == nil)
    #expect(ControlTargetSelector(parsing: "w:p5") == nil)
    #expect(ControlTargetSelector(parsing: "w1:p") == nil)
    #expect(ControlTargetSelector(parsing: "W1") == nil)

    let uuid = UUID()
    #expect(ControlTargetSelector(parsing: "p_\(uuid.uuidString)") == .legacyPaneUUID(uuid))
    #expect(ControlTargetSelector(parsing: uuid.uuidString.lowercased()) == .legacyPaneUUID(uuid))
    #expect(ControlTargetSelector(parsing: "current") == .current)
    #expect(ControlTargetSelector(parsing: "builder-2") == .agentName("builder-2"))
    #expect(ControlTargetSelector(parsing: "w") == .agentName("w"))
    #expect(ControlTargetSelector(parsing: "Builder") == nil)
    #expect(ControlTargetSelector(parsing: "1abc") == nil)
    #expect(ControlTargetSelector(parsing: String(repeating: "a", count: 33)) == nil)
    #expect(ControlTargetSelector(parsing: "") == nil)
    #expect(ControlTargetSelector(parsing: "w99999999999999999999") == nil)

    #expect(ControlPaneID(parsing: "w1:p5")?.description == "w1:p5")
    #expect(ControlTabID(parsing: "w1:t2")?.description == "w1:t2")
    #expect(ControlWindowID(parsing: "w3")?.description == "w3")
    #expect(ControlPaneID(parsing: "w1:t5") == nil)
  }

  @Test("短 ID 作为 JSON 字符串编解码")
  func shortIDsEncodeAsStrings() throws {
    let id = ControlPaneID(window: .init(number: 2), number: 7)
    let data = try JSONEncoder().encode([id])
    #expect(String(decoding: data, as: UTF8.self) == #"["w2:p7"]"#)
    #expect(try JSONDecoder().decode([ControlPaneID].self, from: data) == [id])
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(ControlPaneID.self, from: Data(#""w2:t7""#.utf8))
    }
  }

  @Test("注册表：编号只增不复用，退役后不可解析")
  func registryNumbersAreMonotonic() {
    var registry = ControlIdentityRegistry()
    let window = UUID()
    let paneA = UUID()
    let paneB = UUID()
    #expect(registry.windowNumber(for: window) == 1)
    #expect(registry.windowNumber(for: window) == 1)
    #expect(registry.paneID(for: paneA, inWindow: window).description == "w1:p1")
    #expect(registry.paneID(for: paneB, inWindow: window).description == "w1:p2")
    #expect(registry.paneID(for: paneA, inWindow: window).description == "w1:p1")
    #expect(registry.paneUUID(for: ControlPaneID(parsing: "w1:p1")!) == paneA)

    registry.retire(pane: paneA)
    #expect(registry.paneUUID(for: ControlPaneID(parsing: "w1:p1")!) == nil)
    #expect(registry.currentPaneID(for: paneA) == nil)
    // 新 pane 不会拿到已退役的 p1。
    #expect(registry.paneID(for: UUID(), inWindow: window).description == "w1:p3")

    let tab = UUID()
    #expect(registry.tabID(for: tab, inWindow: window).description == "w1:t1")
    registry.retire(tab: tab)
    #expect(registry.tabUUID(for: ControlTabID(parsing: "w1:t1")!) == nil)
    #expect(registry.tabID(for: UUID(), inWindow: window).description == "w1:t2")

    // 第二个窗口独立编号。
    let window2 = UUID()
    #expect(registry.paneID(for: UUID(), inWindow: window2).description == "w2:p1")
  }

  @Test("跨窗口转移：新 ID 生效，旧 ID 保留为别名直到退役")
  func registryKeepsAliasesAcrossWindowMoves() {
    var registry = ControlIdentityRegistry()
    let window1 = UUID()
    let window2 = UUID()
    let pane = UUID()
    let original = registry.paneID(for: pane, inWindow: window1)
    #expect(original.description == "w1:p1")
    let moved = registry.paneID(for: pane, inWindow: window2)
    #expect(moved.description == "w2:p1")
    #expect(registry.currentPaneID(for: pane) == moved)
    #expect(registry.paneUUID(for: original) == pane)
    #expect(registry.paneUUID(for: moved) == pane)
    #expect(registry.isAlias(original))
    #expect(!registry.isAlias(moved))
    // 移回原窗口会拿到新编号，w1:p1 不复用。
    let back = registry.paneID(for: pane, inWindow: window1)
    #expect(back.description == "w1:p2")
    #expect(registry.paneUUID(for: original) == pane)

    registry.retire(pane: pane)
    #expect(registry.paneUUID(for: original) == nil)
    #expect(registry.paneUUID(for: moved) == nil)
    #expect(registry.paneUUID(for: back) == nil)

    let tab = UUID()
    let tabOriginal = registry.tabID(for: tab, inWindow: window1)
    let tabMoved = registry.tabID(for: tab, inWindow: window2)
    #expect(tabOriginal.description == "w1:t1")
    #expect(tabMoved.description == "w2:t1")
    #expect(registry.tabUUID(for: tabOriginal) == tab)
    #expect(registry.currentTabID(for: tab) == tabMoved)
  }
}
