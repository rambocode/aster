import Foundation
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

@Test("给无宽度边框设置颜色时自动启用一像素边框")
func applyingBorderColorMakesTheResultVisible() throws {
  let theme = makeSparseTheme()
  let probe = HexColor("#0A0B0CFF")!

  let container = theme.applyingColor(probe, toSlot: "container.border")
  #expect(container.style.container.borderColor == probe)
  #expect(container.style.container.borderWidth == 1)

  let tab = theme.applyingColor(probe, toSlot: "tab.activeBorderColor")
  #expect(tab.style.tab.activeBorderColor == probe)
  #expect(tab.style.tab.activeBorderWidth == 1)
}

@Test("标签改色同步继承字段但保留横向专属覆盖")
func applyingTabColorRespectsHorizontalOverrides() throws {
  var theme = makeSparseTheme()
  let inherited = HexColor("#111111FF")!
  let horizontalOnly = HexColor("#222222FF")!
  let probe = HexColor("#0A0B0CFF")!
  theme.style.tab.foreground = inherited
  theme.style.tab.hoverBackground = inherited
  theme.style.horizontalTab = TerminalTabStyle(
    foreground: inherited,
    hoverBackground: horizontalOnly
  )

  let foreground = theme.applyingColor(probe, toSlot: "tab.foreground")
  #expect(foreground.style.tab.foreground == probe)
  #expect(foreground.style.horizontalTab?.foreground == probe)

  let hover = theme.applyingColor(probe, toSlot: "tab.hoverBackground")
  #expect(hover.style.tab.hoverBackground == probe)
  #expect(hover.style.horizontalTab?.hoverBackground == horizontalOnly)

  let border = theme.applyingColor(probe, toSlot: "tab.activeBorderColor")
  #expect(border.style.horizontalTab?.activeBorderColor == probe)
  #expect(border.style.horizontalTab?.activeBorderWidth == 1)
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

@Test("标签悬停与选中在主题未声明时回退到 Otty 原生叠加色")
func tabSlotsFallBackToNativeChromeOverlays() throws {
  let theme = makeSparseTheme()
  let slots = theme.colorSlots
  func slot(_ id: String) throws -> ThemeColorSlot {
    try #require(slots.first { $0.id == id })
  }
  // 浅色模式：hover = 黑 4%、active = 黑 6%——不能与侧栏底同色，否则选中不可见。
  #expect(try slot("tab.hoverBackground").resolved == TerminalThemeMode.light.nativeTabHoverBackground)
  #expect(try slot("tab.activeBackground").resolved == TerminalThemeMode.light.nativeTabActiveBackground)
  // 主题显式声明 panel.surface 时，选中标签优先用 surface（Otty 级联）。
  var surfaced = theme
  surfaced.palette.panelSurface = HexColor("#E8E8E8FF")!
  let surfacedSlots = surfaced.colorSlots
  let active = try #require(surfacedSlots.first { $0.id == "tab.activeBackground" })
  #expect(active.resolved == HexColor("#E8E8E8FF")!)
}

@Test("Otty 解析器对终端-only 主题使用原生 chrome 而不是终端背景")
func parserDerivesNativeChromeForTerminalOnlyThemes() throws {
  let source = """
  [meta]
  name = "Terminal Only"
  mode = "dark"

  [terminal]
  foreground = "#F8F8F2"
  background = "#282A36"
  palette = [
      "#000000", "#FF5555", "#50FA7B", "#F1FA8C",
      "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
      "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5",
      "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF",
  ]
  """
  let theme = try ThemeFileParser.parse(
    data: Data(source.utf8), sourceName: "terminal-only")
  #expect(theme.palette.panelBackground == TerminalThemeMode.dark.nativeChromeBackground)
  #expect(theme.palette.panelSurface == nil)
  #expect(theme.palette.secondaryForeground == TerminalThemeMode.dark.nativeSecondaryForeground)
  #expect(theme.style.sidebarPadding == nil)
}

@Test("Otty 解析器读取 sidebar.padding 与 tab 高度供行几何使用")
func parserReadsSidebarPaddingAndTabHeight() throws {
  let source = """
  [meta]
  name = "Padded"
  mode = "light"

  [terminal]
  foreground = "#111111"
  background = "#FFFFFF"
  palette = [
      "#000000", "#FF5555", "#50FA7B", "#F1FA8C",
      "#BD93F9", "#FF79C6", "#8BE9FD", "#F8F8F2",
      "#6272A4", "#FF6E6E", "#69FF94", "#FFFFA5",
      "#D6ACFF", "#FF92DF", "#A4FFFF", "#FFFFFF",
  ]

  [sidebar]
  padding = 0.0

  [tab]
  height = 32.0
  radius = 0.0
  """
  let theme = try ThemeFileParser.parse(data: Data(source.utf8), sourceName: "padded")
  #expect(theme.style.sidebarPadding == 0)
  #expect(theme.style.tab.height == 32)
  #expect(theme.style.tab.radius == 0)
}

@Test("内置主题序列化成主题文件后可被解析器无损读回")
func builtInThemesRoundTripThroughOttySerializer() throws {
  for builtin in TerminalThemeCatalog.builtIns {
    let source = ThemeFileSerializer.serialize(builtin)
    let parsed = try ThemeFileParser.parse(
      data: Data(source.utf8), sourceName: builtin.id)
    #expect(parsed.name == builtin.name, "\(builtin.id) name")
    #expect(parsed.mode == builtin.mode, "\(builtin.id) mode")
    #expect(parsed.palette == builtin.palette, "\(builtin.id) palette")
    // 解析器对 tab-bar.tab 做逐字段继承（缺失键回填 [tab] 基础值），因此横向标签
    // 只比较继承后的有效值；其余样式必须严格相等。
    func inherited(_ style: TerminalThemeStyle) -> TerminalThemeStyle {
      var copy = style
      guard var horizontal = copy.horizontalTab else { return copy }
      let base = copy.tab
      horizontal.foreground = horizontal.foreground ?? base.foreground
      horizontal.hoverBackground = horizontal.hoverBackground ?? base.hoverBackground
      horizontal.activeBackground = horizontal.activeBackground ?? base.activeBackground
      horizontal.activeForeground = horizontal.activeForeground ?? base.activeForeground
      horizontal.activeBorderColor = horizontal.activeBorderColor ?? base.activeBorderColor
      horizontal.activeShadow = horizontal.activeShadow ?? base.activeShadow
      horizontal.height = horizontal.height ?? base.height
      copy.horizontalTab = horizontal
      return copy
    }
    #expect(inherited(parsed.style) == inherited(builtin.style), "\(builtin.id) style")
  }
}
