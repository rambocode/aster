import Testing

@testable import AsterCore

/// 只声明必需字段的最小主题：其余 token 全部处于「未显式设置」状态。
private func makeSparseTheme() -> TerminalTheme {
  TerminalTheme(
    id: "test.sparse",
    name: "Sparse",
    mode: .light,
    palette: TerminalThemePalette(
      windowBackground: HexColor("#FFFFFFFF")!,
      containerBackground: HexColor("#F2F2F2FF")!,
      panelBackground: HexColor("#EEEEEEFF")!,
      foreground: HexColor("#2A2B33FF")!,
      secondaryForeground: HexColor("#6B7280FF")!,
      accent: HexColor("#3B82F6FF")!,
      cursor: HexColor("#111111FF")!,
      selection: HexColor("#B3D7FFFF")!,
      ansiColors: (0..<16).map { _ in HexColor("#000000FF")! }
    ),
    style: TerminalThemeStyle(),
    isBuiltIn: false
  )
}

@Test("色板列出全部 token 且按分组顺序排列")
func colorSlotsCoverEveryGroupInOrder() throws {
  let slots = makeSparseTheme().colorSlots
  #expect(slots.count == 29)
  #expect(Set(slots.map(\.id)).count == slots.count)
  // 分组顺序必须与 ThemeColorGroup.allCases 一致，界面直接按段渲染。
  let groups = slots.map(\.group).reduce(into: [ThemeColorGroup]()) { result, group in
    if result.last != group { result.append(group) }
  }
  #expect(groups == ThemeColorGroup.allCases)
}

@Test("未声明的 token 标记为派生并回退到可用颜色")
func unsetTokensAreMarkedDerived() throws {
  let theme = makeSparseTheme()
  let slots = theme.colorSlots
  func slot(_ id: String) throws -> ThemeColorSlot {
    try #require(slots.first { $0.id == id })
  }

  // 终端前景/背景是必需字段，永远算显式。
  #expect(try slot("terminal.foreground").isDerived == false)
  #expect(try slot("terminal.background").isDerived == false)
  // 界面窗口底色没写时跟随 panel，属于派生。
  let window = try slot("interface.window")
  #expect(window.isDerived)
  #expect(window.resolved == theme.palette.panelBackground)
  // 侧栏三个 token 都没写，全部派生。
  #expect(try slot("sidebar.background").isDerived)
  #expect(try slot("sidebar.foreground").isDerived)
  #expect(try slot("sidebar.border").isDerived)
  // 边框类 token 用 border 画法。
  #expect(try slot("container.border").kind == .border)
  #expect(try slot("panel.border").kind == .border)
}

@Test("写回某个 token 后它变成显式值，不再跟随 window")
func applyingColorMakesSlotExplicit() throws {
  let theme = makeSparseTheme()
  let red = HexColor("#FF0000FF")!
  let updated = theme.applyingColor(red, toSlot: "sidebar.background")

  let slot = try #require(updated.colorSlots.first { $0.id == "sidebar.background" })
  #expect(slot.isDerived == false)
  #expect(slot.resolved == red)
  #expect(updated.style.sidebarBackground == red)
  // 其它 token 不受影响。
  #expect(updated.palette == theme.palette)
}

@Test("每个 slot 都能被写回，未知 id 不改动主题")
func everySlotIsWritableAndUnknownIsIgnored() throws {
  let theme = makeSparseTheme()
  let probe = HexColor("#0A0B0CFF")!
  for slot in theme.colorSlots {
    let updated = theme.applyingColor(probe, toSlot: slot.id)
    let rewritten = try #require(updated.colorSlots.first { $0.id == slot.id })
    #expect(rewritten.resolved == probe, "slot \(slot.id) 未被写回")
    #expect(rewritten.isDerived == false, "slot \(slot.id) 写回后仍算派生")
  }
  #expect(theme.applyingColor(probe, toSlot: "nope.nope") == theme)
}

@Test("改 window 一侧只带动仍在派生的 token")
func changingWindowMovesOnlyDerivedTokens() throws {
  let green = HexColor("#00FF00FF")!
  var theme = makeSparseTheme()
  // 侧栏背景显式声明，窗口底色保持未声明。
  theme.style.sidebarBackground = green
  theme.palette.panelBackground = HexColor("#123456FF")!

  func resolved(_ id: String) throws -> HexColor {
    try #require(theme.colorSlots.first { $0.id == id }).resolved
  }
  // 显式声明过的侧栏背景不跟随。
  #expect(try resolved("sidebar.background") == green)
  // 仍在派生的窗口底色跟着 panel 走——这正是「改 window 其它颜色跟着变」的语义。
  #expect(try resolved("interface.window") == HexColor("#123456FF")!)
  #expect(try #require(theme.colorSlots.first { $0.id == "sidebar.background" }).isDerived == false)
  #expect(try #require(theme.colorSlots.first { $0.id == "interface.window" }).isDerived)
}

@Test("tooltip 使用短写色值并标注派生来源")
func tooltipShowsTokenAndHex() throws {
  let slots = makeSparseTheme().colorSlots
  let foreground = try #require(slots.first { $0.id == "terminal.foreground" })
  #expect(foreground.tooltip == "前景色 · terminal.foreground = \"#2a2b33\"")
  let window = try #require(slots.first { $0.id == "interface.window" })
  #expect(window.tooltip.contains("跟随 Window 派生"))
}
