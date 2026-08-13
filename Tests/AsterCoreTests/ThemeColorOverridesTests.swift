import Foundation
import Testing

@testable import AsterCore

private func makeBaseTheme() -> TerminalTheme {
  TerminalTheme(
    id: "test.base",
    name: "Base",
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
    isBuiltIn: true
  )
}

@Test("覆盖叠在原主题之上，原主题本身不变")
func overridesLayerOnTopWithoutMutatingBase() throws {
  let base = makeBaseTheme()
  var overrides = ThemeColorOverrides()
  overrides.set(HexColor("#FF0000FF")!, for: "sidebar.background")

  let resolved = base.applyingOverrides(overrides)

  #expect(resolved.style.sidebarBackground == HexColor("#FF0000FF")!)
  // 内置真值表不能被就地改写。
  #expect(base.style.sidebarBackground == nil)
  #expect(base.isBuiltIn)
  #expect(resolved.id == base.id, "覆盖不改变主题身份，仍然是同一套主题")
}

@Test("清掉覆盖后完整回到原主题")
func clearingOverridesRestoresBase() {
  let base = makeBaseTheme()
  var library = ThemeOverrideLibrary()
  library.setColor(HexColor("#FF0000FF")!, slotID: "sidebar.background", themeID: base.id)
  library.setColor(HexColor("#00FF00FF")!, slotID: "titlebar.background", themeID: base.id)
  #expect(base.applyingOverrides(library.overrides(for: base.id)) != base)

  library.clearAll(themeID: base.id)
  #expect(base.applyingOverrides(library.overrides(for: base.id)) == base)
}

@Test("逐条撤销覆盖，覆盖清空后不再占用条目")
func clearingSingleSlotDropsEmptyEntry() {
  let base = makeBaseTheme()
  var library = ThemeOverrideLibrary()
  library.setColor(HexColor("#FF0000FF")!, slotID: "sidebar.background", themeID: base.id)
  library.setColor(HexColor("#00FF00FF")!, slotID: "titlebar.background", themeID: base.id)

  library.clearColor(slotID: "sidebar.background", themeID: base.id)
  #expect(library.overrides(for: base.id).colors.count == 1)
  library.clearColor(slotID: "titlebar.background", themeID: base.id)
  #expect(library.overridesByThemeID[base.id] == nil)
}

@Test("覆盖序列化成带 otty-added 注释的追加段")
func overridesSerializeToOttySection() throws {
  var overrides = ThemeColorOverrides()
  overrides.set(HexColor("#FFFFFFFF")!, for: "interface.window")
  overrides.set(HexColor("#FFFFFFFF")!, for: "titlebar.background")

  let section = makeBaseTheme().ottyOverrideSection(overrides)

  #expect(section.contains("[window]"))
  #expect(section.contains("# otty-added: window.background"))
  #expect(section.contains("background = \"#ffffff\""))
  #expect(section.contains("[titlebar]"))
  #expect(section.contains("# otty-added: titlebar.background"))
  // 同一 section 的多个键合并在一个段落里，不重复写段头。
  #expect(section.components(separatedBy: "[titlebar]").count == 2)
}

@Test("Aster 自有的界面 token 不写进 Otty 文件")
func interfaceOnlyTokensAreNotSerialized() {
  var overrides = ThemeColorOverrides()
  overrides.set(HexColor("#123456FF")!, for: "interface.tertiaryForeground")
  // Otty 没有这个键，写进去只会让它解析出未知键；覆盖仍然保留在应用内。
  #expect(makeBaseTheme().ottyOverrideSection(overrides).isEmpty)
  #expect(OttyThemeKeyMap.entry(for: "interface.tertiaryForeground") == nil)
  #expect(OttyThemeKeyMap.entry(for: "interface.window")?.section == "window")
}

@Test("重写覆盖段时先剥掉上一轮内容，不会越堆越多")
func rewritingStripsPreviousOverrideSection() {
  let base = """
    [terminal]
    background = "#ffffff"
    """
  let firstPass = base + "\n\n" + ThemeOverrideFileWriter.marker + "\n[window]\nbackground = \"#111111\"\n"

  let stripped = ThemeOverrideFileWriter.strippingPreviousOverrides(from: firstPass)

  #expect(stripped.contains("[terminal]"))
  #expect(stripped.contains(ThemeOverrideFileWriter.marker) == false)
  #expect(stripped.contains("#111111") == false)
  // 没有 marker 的文件原样返回，不能吃掉用户手写的内容。
  #expect(ThemeOverrideFileWriter.strippingPreviousOverrides(from: base) == base)
}

@Test("覆盖应用顺序稳定，与写入次序无关")
func overrideApplicationIsDeterministic() {
  let base = makeBaseTheme()
  var a = ThemeColorOverrides()
  a.set(HexColor("#111111FF")!, for: "sidebar.foreground")
  a.set(HexColor("#222222FF")!, for: "interface.foreground")
  var b = ThemeColorOverrides()
  b.set(HexColor("#222222FF")!, for: "interface.foreground")
  b.set(HexColor("#111111FF")!, for: "sidebar.foreground")

  // 两者写的是同一个字段，顺序不定会让结果抖动；排序后必须一致。
  #expect(base.applyingOverrides(a) == base.applyingOverrides(b))
}

@Test("ANSI 与主题字体作为原主题参数覆盖，不创建新身份")
func ansiAndFontsOverrideOriginalThemeIdentity() throws {
  let base = makeBaseTheme()
  var overrides = ThemeColorOverrides()
  overrides.setANSIColor(HexColor("#123456FF")!, at: 3)
  overrides.setFontFamilies(["JetBrains Mono", "Menlo"], for: .regular)
  overrides.setFontFamilies(["JetBrains Mono Bold"], for: .bold)

  let resolved = base.applyingOverrides(overrides)

  #expect(resolved.id == base.id)
  #expect(resolved.isBuiltIn)
  #expect(resolved.palette.ansiColors[3] == HexColor("#123456FF")!)
  #expect(resolved.style.fontFamilies == ["JetBrains Mono", "Menlo"])
  #expect(resolved.style.fontFamilyBold == "JetBrains Mono Bold")
  #expect(base.palette.ansiColors[3] == HexColor("#000000FF")!)
  #expect(base.style.fontFamilies == nil)

  let section = base.ottyOverrideSection(overrides)
  #expect(section.contains("# otty-added: terminal.palette"))
  #expect(section.contains("#123456"))
  #expect(section.contains("# otty-added: token.font-mono"))
  #expect(section.contains("font-mono = [\"JetBrains Mono\", \"Menlo\"]"))
  #expect(section.contains("font-mono-bold = [\"JetBrains Mono Bold\"]"))
}

@Test("追加参数可被 Otty 解析器按最后声明重新载入")
func managedParametersRoundTripThroughOttyParser() throws {
  let base = makeBaseTheme()
  var overrides = ThemeColorOverrides()
  overrides.setANSIColor(HexColor("#123456FF")!, at: 3)
  overrides.setFontFamilies(["JetBrains Mono", "Menlo"], for: .regular)
  overrides.setFontFamilies([], for: .bold)
  let source = """
    [meta]
    name = "Round Trip"
    mode = "light"

    [terminal]
    foreground = "#2a2b33"
    background = "#ffffff"
    palette = ["#000000", "#000000", "#000000", "#000000", "#000000", "#000000", "#000000", "#000000", "#000000", "#000000", "#000000", "#000000", "#000000", "#000000", "#000000", "#000000"]

    [token]
    font-mono = ["Old Font"]
    font-mono-bold = ["Old Bold"]

    \(ThemeOverrideFileWriter.marker)
    \(base.ottyOverrideSection(overrides))
    """

  let parsed = try OttyThemeParser.parse(data: Data(source.utf8), sourceName: "round-trip")

  #expect(parsed.palette.ansiColors[3] == HexColor("#123456FF")!)
  #expect(parsed.style.fontFamilies == ["JetBrains Mono", "Menlo"])
  #expect(parsed.style.fontFamilyBold == nil)
}

@Test("旧版只有颜色的覆盖数据可无损迁移")
func legacyColorOnlyOverridesRemainDecodable() throws {
  let data = Data(
    #"{"colors":{"terminal.foreground":{"red":18,"green":52,"blue":86,"alpha":255}}}"#.utf8
  )

  let decoded = try JSONDecoder().decode(ThemeColorOverrides.self, from: data)

  #expect(decoded["terminal.foreground"] == HexColor("#123456FF")!)
  #expect(decoded.ansiColors.isEmpty)
  #expect(decoded.fontFamiliesByRole.isEmpty)
}
