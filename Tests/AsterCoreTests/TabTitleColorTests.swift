import Foundation
import Testing

@testable import AsterCore

@Test("自动颜色优先挑没被占用的索引")
func autoTitleColorPrefersUnusedIndex() {
  let used = Array(0..<(TabTitleColorPalette.options.count - 1))
  // 随机源固定取候选里的第一个；此时唯一的候选就是那个没被占用的颜色。
  let index = TabTitleColorPalette.allocateIndex(used: used, randomSource: { _ in 0 })

  #expect(index == TabTitleColorPalette.options.count - 1)
}

@Test("连续分配在调色板用完前不会撞色")
func autoTitleColorNeverRepeatsBeforePaletteIsExhausted() {
  var used: [Int] = []
  for _ in 0..<TabTitleColorPalette.options.count {
    used.append(TabTitleColorPalette.allocateIndex(used: used))
  }

  #expect(Set(used).count == TabTitleColorPalette.options.count)
}

@Test("调色板用完后从占用最少的颜色里挑")
func autoTitleColorSpreadsAfterPaletteIsExhausted() {
  // 0 号色被占两次，其余各一次：下一次分配不能再落到 0。
  let used = Array(TabTitleColorPalette.options.indices) + [0]

  for pick in 0..<TabTitleColorPalette.options.count {
    let index = TabTitleColorPalette.allocateIndex(used: used, randomSource: { _ in pick })
    #expect(index != 0)
  }
}

@Test("换一个颜色不会挑回当前颜色")
func reallocateAvoidsCurrentColor() {
  let current = 3
  for pick in 0..<TabTitleColorPalette.options.count {
    let index = TabTitleColorPalette.reallocateIndex(
      current: current, used: [current], randomSource: { _ in pick })
    #expect(index != current)
  }
}

@Test("越界索引取不到颜色")
func paletteRejectsOutOfRangeIndex() {
  #expect(TabTitleColorPalette.color(atIndex: -1) == nil)
  #expect(TabTitleColorPalette.color(atIndex: TabTitleColorPalette.options.count) == nil)
  #expect(TabTitleColorPalette.color(atIndex: 0) == TabTitleColorPalette.options[0].color)
}

@Test("随机标题颜色默认开启，写入后保持显式值")
func randomTabTitleColorsDefaultsToEnabled() {
  var configuration = ViewConfiguration()
  #expect(configuration.resolvedRandomTabTitleColors)

  configuration.randomTabTitleColors = false
  #expect(configuration.normalized().resolvedRandomTabTitleColors == false)
}

@Test("标签快照往返保留标题颜色与自动颜色索引")
func tabSnapshotRoundTripsTitleColors() throws {
  let snapshot = WorkspaceTabSnapshot(
    id: UUID(),
    title: "aster",
    layout: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: "/tmp")),
    titleColor: HexColor(red: 0x11, green: 0x22, blue: 0x33),
    autoTitleColorIndex: 5
  )

  let data = try JSONEncoder().encode(snapshot)
  let decoded = try JSONDecoder().decode(WorkspaceTabSnapshot.self, from: data)

  #expect(decoded.titleColor == snapshot.titleColor)
  #expect(decoded.autoTitleColorIndex == 5)
}

@Test("旧快照没有颜色字段：编码时不写键，解码回 nil")
func legacyTabSnapshotDecodesWithoutColorFields() throws {
  let snapshot = WorkspaceTabSnapshot(
    id: UUID(),
    title: "legacy",
    layout: .leaf(PaneDescriptor(kind: .terminal, workingDirectory: "/tmp"))
  )

  let data = try JSONEncoder().encode(snapshot)
  let object = try #require(
    try JSONSerialization.jsonObject(with: data) as? [String: Any])
  // 缺键即旧快照的形态；解码必须回落到 nil 而不是报错。
  #expect(object["titleColor"] == nil)
  #expect(object["autoTitleColorIndex"] == nil)

  let decoded = try JSONDecoder().decode(WorkspaceTabSnapshot.self, from: data)
  #expect(decoded.titleColor == nil)
  #expect(decoded.autoTitleColorIndex == nil)
}
