import Darwin
import CryptoKit
import Foundation
import Testing

@testable import AsterCore

private struct OttyThemeSignature {
  let name: String
  let mode: TerminalThemeMode
  let sha256: String
}

/// 将 Otty 1.3.1 原始 `.astertheme` 中的终端前景、背景与 ANSI 16 色压成稳定签名。
/// 测试以原始主题文件为真值，可以同时发现漏主题、改名、错色或 ANSI 顺序颠倒。
private let otty131ThemeSignatures: [OttyThemeSignature] = [
  .init(name: "April", mode: .light, sha256: "e3d7723d0842c5cd324f5377050f616c755cc1e8f3a0c84ca2c12450460e03bc"),
  .init(name: "April Dark", mode: .dark, sha256: "fdb0301c527276469e89f6f21df455505791878780f3167b9e0b536e407239c8"),
  .init(name: "Ayu Dark", mode: .dark, sha256: "9fc9542e34cc03c2259ce8187425396c54a31bad86e0ffd6db92ba6c4c9f4a6c"),
  .init(name: "Ayu Light", mode: .light, sha256: "182a92a2fd33fbfc9840ad30e086ec85a5e6e15a10d536ffa7288958bffb1d79"),
  .init(name: "Catppuccin Mocha", mode: .dark, sha256: "163088ca23f8f47ef6a34005b93634aa61afcecaf14db0a63f47e612ea5a8f0a"),
  .init(name: "Dracula", mode: .dark, sha256: "d1c9b325a66a751ee332516a3c28a130593039143baae85c64a455216894854a"),
  .init(name: "Floating Card", mode: .light, sha256: "f65dea31e9231b6713f852ba3ab1a69c4c80018b2e308c588a127ce7f5587836"),
  .init(name: "Glass Dark", mode: .dark, sha256: "03235dd379ea2c822cb8585d0b6e48b71e810da187a94d20f3be621592ceadf5"),
  .init(name: "Glass Light", mode: .light, sha256: "a0c978ddd9e21c0e30ec1aae32bae1f6d9c3011f796fede492e63fc595c1cc35"),
  .init(name: "Gruvbox Dark", mode: .dark, sha256: "7b62770329ce94b40da1b5af3155127c4fb47b7c0f1ed91b9428c0563c3c7290"),
  .init(name: "Monokai Classic", mode: .dark, sha256: "3b489ce9110f2d6a4f2945d998b1e6c6c90ed0980c1b52d36f13c9055c7ab623"),
  .init(name: "Newsprint", mode: .light, sha256: "560a0dec63dca71b0a813405f9fba4a14c4c124f5dc0784bf7cdfe7808c2cdeb"),
  .init(name: "Night", mode: .dark, sha256: "e0a68e17d954dd446f95564445b37e2fde1383068576c60ecd335e7ad53a9e78"),
  .init(name: "Nord", mode: .dark, sha256: "1c163bb2ccd26f0736b39620ca511b98a64d252a51483cdf2883077b7c193ccb"),
  .init(name: "One Dark", mode: .dark, sha256: "c9b6995a7aefde4e4a0434148979b59fc9c66c8865fcd3cea663723e3f3849e1"),
  .init(name: "One Light", mode: .light, sha256: "24829a1329c1ec2dc9096d7702536e37a11c5fa519f2c9d60be8f96995c619a9"),
  .init(name: "Owl", mode: .dark, sha256: "4f47c005fd7a9e874bbbbf09226c7c0cf96409799b8b0a5d808ef59f3798fe83"),
  .init(name: "Paper", mode: .light, sha256: "399cec604fea84584b0ba38e6b9befe9e4423705ca8df0e49cb486b26b536771"),
  .init(name: "Pink", mode: .light, sha256: "03e5631a0d56c17f2927a67cd50711824e20fc3ece603ea9cfa3e4f8b8d734d6"),
  .init(name: "Rosé Pine", mode: .dark, sha256: "f7f729515cf2d3bb88f0ebf3eaf89956261856ef60f9e2a251d49b0f33dcd7c6"),
  .init(name: "Seafoam Pastel", mode: .dark, sha256: "c9ddb57679ac6f1e434c6e896a73d28193cf1e5cb6b9e0f6d8abb93c57d40991"),
  .init(name: "Solarized Dark", mode: .dark, sha256: "1e25d5749a924c73d68ab3f6adefb42736913394acc9697ea5261c28bfb386cf"),
  .init(name: "Solarized Light", mode: .light, sha256: "2892590c850fa5f1355d5ac78c06eedbb7523c562c4a99324773fa487e859124"),
  .init(name: "Tokyo Night", mode: .dark, sha256: "449a7cbe12c2f3e0fc1064405d85793616b4bd601c704c0c29112c0728ac92d0"),
]

private func terminalColorSignature(_ theme: TerminalTheme) -> String {
  let values = [theme.palette.foreground, theme.palette.windowBackground]
    + theme.palette.ansiColors
  let canonical = values.map(\.stringValue).joined(separator: "|")
  return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
}

@Test("内置主题逐套匹配 Otty 1.3.1 原始终端色表")
func builtInThemesExactlyMatchOtty131TerminalColors() throws {
  let actual = TerminalThemeCatalog.builtIns
  #expect(actual.count == otty131ThemeSignatures.count)
  #expect(Set(actual.map(\.name)) == Set(otty131ThemeSignatures.map(\.name)))

  for expected in otty131ThemeSignatures {
    let theme = try #require(TerminalThemeCatalog.theme(named: expected.name))
    #expect(theme.mode == expected.mode)
    #expect(terminalColorSignature(theme) == expected.sha256)
  }
}

@Test("Otty 显式定义的光标与选区颜色不会被近似值覆盖")
func explicitOttyCursorAndSelectionColorsArePreserved() throws {
  let floating = try #require(TerminalThemeCatalog.theme(named: "Floating Card"))
  #expect(floating.palette.cursor == HexColor("#18181B"))
  #expect(floating.palette.selection == HexColor("#E4E4E7"))

  let nord = try #require(TerminalThemeCatalog.theme(named: "Nord"))
  #expect(nord.palette.cursor == HexColor("#E5E9F0"))
  #expect(nord.palette.cursorText == HexColor("#2E3440"))
  #expect(nord.palette.selectionForeground == HexColor("#2E3440"))
  #expect(nord.palette.selection == HexColor("#E5E9F0"))

  let pink = try #require(TerminalThemeCatalog.theme(named: "Pink"))
  #expect(pink.palette.cursor == HexColor("#CC8595"))
  #expect(pink.palette.cursorText == HexColor("#F5F0F0"))
  #expect(pink.palette.selectionForeground == HexColor("#2A2422"))
  #expect(pink.palette.selection == HexColor("#EDC4BE"))

  let glass = try #require(TerminalThemeCatalog.theme(named: "Glass Light"))
  #expect(glass.palette.windowBackground == HexColor("#00000000"))
  #expect(glass.palette.material == .glass)
  // SwiftTerm 的内部颜色类型没有 alpha；透明主题必须使用 Otty 的 surface 作为
  // 终端栅格合成底色，否则透明黑会被错误渲染成纯黑。
  #expect(glass.palette.renderedTerminalBackground == HexColor("#F7FBFD"))
}

@Test("浅色主题未显式声明选区时使用终端前景的百分之三十透明度")
func lightThemeDefaultSelectionUsesTranslucentForeground() throws {
  let names = ["April", "Ayu Light", "Newsprint", "One Light", "Paper", "Solarized Light"]
  for name in names {
    let theme = try #require(TerminalThemeCatalog.theme(named: name))
    #expect(theme.palette.selection.red == theme.palette.foreground.red, "\(name) 选区红色通道错误")
    #expect(theme.palette.selection.green == theme.palette.foreground.green, "\(name) 选区绿色通道错误")
    #expect(theme.palette.selection.blue == theme.palette.foreground.blue, "\(name) 选区蓝色通道错误")
    #expect(theme.palette.selection.alpha == 77, "\(name) 选区透明度错误")
  }
}

@Test("Otty 显式界面样式令牌会逐项保留")
func explicitOttyInterfaceStyleTokensArePreserved() throws {
  let floating = try #require(TerminalThemeCatalog.theme(named: "Floating Card"))
  #expect(floating.style.radius == 8)
  #expect(floating.style.sidebarBackground == HexColor("#FFFFFF00"))
  #expect(floating.style.tab.radius == 6)
  #expect(floating.style.tab.activeBackground == HexColor("#FFFFFFE6"))
  #expect(floating.style.tab.activeFontWeight == 700)
  #expect(floating.style.container.radius == 15)
  #expect(floating.style.container.margin == ThemeInsets(top: 4, leading: 16, bottom: 16, trailing: 16))
  #expect(floating.style.container.padding == ThemeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
  #expect(
    floating.style.container.shadow
      == ThemeShadow(
        x: 0, y: 1.5, blur: 6, color: try #require(HexColor("#0000002E"))))

  let glass = try #require(TerminalThemeCatalog.theme(named: "Glass Light"))
  #expect(glass.style.radius == 12)
  #expect(glass.style.tab.radius == 4)
  #expect(glass.style.tab.activeBackground == HexColor("#AAAAAA3A"))
  #expect(glass.style.tab.activeBorderColor == HexColor("#2E3E4A24"))
  #expect(glass.style.container.radius == 0)
  #expect(glass.style.container.margin == .zero)
  #expect(glass.style.container.padding == ThemeInsets(all: 8))

  let april = try #require(TerminalThemeCatalog.theme(named: "April"))
  #expect(april.style.tab.radius == 0)
  #expect(april.style.tab.height == 32)
  #expect(april.style.tab.activeBackground == HexColor("#14934B2F"))
  #expect(april.style.tab.activeFontWeight == 500)
}

@Test("浅色主题的横向标签逐字段继承 Otty 基础标签样式")
func lightThemeHorizontalTabsInheritBaseTabStyle() throws {
  for name in ["Newsprint", "Paper"] {
    let theme = try #require(TerminalThemeCatalog.theme(named: name))
    let horizontal = try #require(theme.style.horizontalTab)

    // Otty 的 `[tab-bar.tab]` 只覆盖圆角和高度；颜色、字重、边框等未声明字段
    // 必须继续继承 `[tab]`，否则把标签栏切到顶部或底部就会丢失该主题的视觉。
    #expect(horizontal.foreground == theme.style.tab.foreground, "\(name) 横向标签文字色未继承")
    #expect(horizontal.hoverBackground == theme.style.tab.hoverBackground, "\(name) 横向悬停色未继承")
    #expect(horizontal.activeBackground == theme.style.tab.activeBackground, "\(name) 横向选中色未继承")
    #expect(horizontal.activeForeground == theme.style.tab.activeForeground, "\(name) 横向选中文字未继承")
    #expect(horizontal.activeBorderColor == theme.style.tab.activeBorderColor, "\(name) 横向边框未继承")
    #expect(horizontal.activeBorderWidth == theme.style.tab.activeBorderWidth, "\(name) 横向边框宽度未继承")
    #expect(horizontal.activeFontWeight == theme.style.tab.activeFontWeight, "\(name) 横向字重未继承")
  }
}

@Test("内置主题目录覆盖参考应用的浅色与深色主题")
func builtInThemeCatalogContainsReferenceThemes() throws {
  let themes = TerminalThemeCatalog.builtIns
  let names = Set(themes.map(\.name))

  #expect(themes.count >= 18)
  #expect(Set(themes.map(\.id)).count == themes.count)
  #expect(names.isSuperset(of: ["April", "Ayu Light", "Paper", "Pink", "Ayu Dark", "Dracula"]))
  #expect(themes.allSatisfy { $0.palette.ansiColors.count == 16 })
  #expect(try #require(TerminalThemeCatalog.theme(named: "Ayu Light")).mode == .light)
  #expect(try #require(TerminalThemeCatalog.theme(named: "Ayu Dark")).mode == .dark)
}

@Test("主题文件可以安全往返并拒绝命名管道")
func terminalThemeStoreRoundTripsAndRejectsNamedPipe() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  // 主题文件只有 TOML 一种格式，id 由文件名承载：往返时文件名必须与 id 一致，
  // 否则读回来的是同一套颜色、不同的身份。
  var theme = try #require(TerminalThemeCatalog.theme(named: "Paper"))
  theme.id = "my-paper"
  theme.name = "My Paper"
  theme.isBuiltIn = false
  let file = directory.appendingPathComponent("my-paper.astertheme")

  try TerminalThemeStore.save(theme, to: file)
  // 解析器会把「未声明即继承」的样式键回填成有效值，因此往返后不做逐字段全等，
  // 只保证身份与颜色真值一致——那才是主题文件承载的内容。
  // 解析器给导入的主题生成带内容指纹的稳定 id；调用方（主题目录扫描）再按文件名
  // 覆写成 stem，这里只验证 id 稳定可复现。
  let restored = try TerminalThemeStore.load(from: file)
  #expect(restored.id == (try TerminalThemeStore.load(from: file)).id)
  #expect(restored.id.hasPrefix("aster-my-paper-"))
  #expect(restored.name == theme.name)
  #expect(restored.mode == theme.mode)
  #expect(restored.palette == theme.palette)

  let pipe = directory.appendingPathComponent("blocked.astertheme")
  #expect(pipe.path.withCString { Darwin.mkfifo($0, 0o600) } == 0)
  #expect(throws: TerminalThemeStoreError.notRegularFile) {
    try TerminalThemeStore.load(from: pipe)
  }
}

@Test("Otty TOML 主题导入保留终端色表与界面样式")
func terminalThemeStoreImportsOttyThemeFiles() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let file = directory.appendingPathComponent("studio-glass.astertheme")
  try """
    [meta]
    name = "Studio Glass"
    mode = "dark"

    [terminal]
    foreground = "#F7F8FF"
    background = "none"
    palette = [
      "#252A35", "#FF8A8A", "#A8D46F", "#E8C778",
      "#8DB7FF", "#D1A3FF", "#7FD6C2", "#E3E6F0",
      "#747B8E", "#FFB0A8", "#C8EA90", "#F2DA9A",
      "#B2CCFF", "#E0C2FF", "#A3E6D8", "#FFFFFF",
    ]
    cursor = "#F7F8FF"
    cursor-text = "#252A35"
    selection-foreground = "#252A35"
    selection-background = "rgba(187, 201, 237, 0.75)"

    [token]
    foreground = "#F7F8FF"
    secondary = "#C9CEDB"
    tertiary = "#8E95A8"
    accent = "#B4D979"
    radius = 12
    font-mono = ["JetBrains Mono", "Menlo", "monospace"]

    [panel]
    background = "#444445"
    surface = "#40434B"
    border = "#6B7286"

    [window]
    material = "vibrancy-regular"

    [sidebar]
    background = "rgba(37, 40, 50, 0.36)"
    border-right = "1px solid rgba(255, 255, 255, 0.18)"

    [tab]
    radius = 8
    foreground = "#C9CEDB"
    font-weight = 400

    [tab.active]
    background = "rgba(255,255,255,0.16)"
    foreground = "#FFFFFF"
    border = "1px solid rgba(255,255,255,0.18)"
    shadow = "0 1px 2px rgba(0,0,0,0.30)"
    font-weight = 500

    [tab-bar]
    height = 44

    [tab-bar.tab]
    radius = 14
    height = 32

    [tab-bar.tab.active]
    background = "#303846"
    border = "none"
    shadow = "none"

    [tab-bar.tab.hover]
    background = "#202834"

    [container]
    radius = 0
    margin = [4, 8, 12, 16]
    padding = 8
    shadow = "0 2px 8px rgba(0,0,0,0.34)"
    """.write(to: file, atomically: true, encoding: .utf8)

  let theme = try TerminalThemeStore.load(from: file)

  #expect(theme.name == "Studio Glass")
  #expect(theme.mode == .dark)
  #expect(!theme.isBuiltIn)
  #expect(theme.palette.windowBackground == HexColor("#00000000"))
  #expect(theme.palette.ansiColors.count == 16)
  #expect(theme.palette.cursorText == HexColor("#252A35"))
  #expect(theme.palette.selectionForeground == HexColor("#252A35"))
  #expect(theme.palette.selection == HexColor("#BBC9EDBF"))
  #expect(theme.palette.material == .vibrancyRegular)
  #expect(theme.style.radius == 12)
  #expect(theme.style.sidebarBackground == HexColor("#2528325C"))
  #expect(theme.style.sidebarBorderWidth == 1)
  #expect(theme.style.tab.activeBackground == HexColor("#FFFFFF29"))
  #expect(theme.style.tab.activeBorderWidth == 1)
  #expect(theme.style.tab.activeFontWeight == 500)
  #expect(theme.style.horizontalTabBarHeight == 44)
  #expect(theme.style.horizontalTab?.radius == 14)
  #expect(theme.style.horizontalTab?.height == 32)
  #expect(theme.style.horizontalTab?.foreground == HexColor("#C9CEDB"))
  #expect(theme.style.horizontalTab?.activeBackground == HexColor("#303846"))
  #expect(theme.style.horizontalTab?.hoverBackground == HexColor("#202834"))
  #expect(theme.style.tab.activeBorderColor != nil)
  #expect(theme.style.tab.activeShadow != nil)
  #expect(theme.style.horizontalTab?.activeBorderColor == nil)
  #expect(theme.style.horizontalTab?.activeBorderWidth == 0)
  #expect(theme.style.horizontalTab?.activeShadow == nil)
  #expect(theme.style.container.margin == ThemeInsets(top: 4, leading: 8, bottom: 12, trailing: 16))
  #expect(theme.style.container.padding == ThemeInsets(all: 8))
  #expect(theme.style.container.shadow?.blur == 8)
  let encoded = try #require(
    JSONSerialization.jsonObject(with: JSONEncoder().encode(theme)) as? [String: Any]
  )
  let style = try #require(encoded["style"] as? [String: Any])
  #expect((style["fontFamilies"] as? [Any])?.compactMap { $0 as? String }
    == ["JetBrains Mono", "Menlo", "monospace"])
}

@Test("Otty 主题缺少模式时按背景推断并安全处理非有限布局数值")
func terminalThemeStoreInfersModeAndNormalizesUnsafeNumbers() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let file = directory.appendingPathComponent("inferred-dark.astertheme")
  try """
    [meta]
    name = "Inferred Dark"
    [terminal]
    foreground = "#FFFFFF"
    background = "#101820"
    palette = ["#000000", "#111111", "#222222", "#333333", "#444444", "#555555", "#666666", "#777777", "#888888", "#999999", "#AAAAAA", "#BBBBBB", "#CCCCCC", "#DDDDDD", "#EEEEEE", "#FFFFFF"]
    [token]
    radius = nan
    [tab.active]
    font-weight = nan
    """.write(to: file, atomically: true, encoding: .utf8)

  let theme = try TerminalThemeStore.load(from: file)
  #expect(theme.mode == .dark)
  #expect(theme.style.radius.isFinite)
  #expect((0...128).contains(theme.style.radius))
  #expect(theme.style.tab.activeFontWeight == 600)
}

@Test("Otty 主题导入拒绝不完整色表与符号链接")
func terminalThemeStoreRejectsUnsafeOttyThemes() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let invalid = directory.appendingPathComponent("invalid.astertheme")
  try """
    [meta]
    name = "Invalid"
    mode = "light"
    [terminal]
    foreground = "#111111"
    background = "#FFFFFF"
    palette = ["#000000"]
    """.write(to: invalid, atomically: true, encoding: .utf8)
  #expect(throws: TerminalThemeStoreError.invalidPalette) {
    try TerminalThemeStore.load(from: invalid)
  }

  let unbalanced = directory.appendingPathComponent("unbalanced.astertheme")
  try """
    [meta]
    name = "Unbalanced"
    mode = "dark"
    [terminal]
    foreground = "#FFFFFF"
    background = "#000000"
    palette = ["#000000", "#111111", "#222222", "#333333", "#444444", "#555555", "#666666", "#777777", "#888888", "#999999", "#AAAAAA", "#BBBBBB", "#CCCCCC", "#DDDDDD", "#EEEEEE", "#FFFFFF"]]
    """.write(to: unbalanced, atomically: true, encoding: .utf8)
  #expect(throws: TerminalThemeStoreError.invalidFormat("主题包含未配对的数组闭括号。")) {
    try TerminalThemeStore.load(from: unbalanced)
  }

  let invalidMode = directory.appendingPathComponent("invalid-mode.astertheme")
  try """
    [meta]
    name = "Invalid Mode"
    mode = "sepia"
    [terminal]
    foreground = "#FFFFFF"
    background = "#000000"
    palette = ["#000000", "#111111", "#222222", "#333333", "#444444", "#555555", "#666666", "#777777", "#888888", "#999999", "#AAAAAA", "#BBBBBB", "#CCCCCC", "#DDDDDD", "#EEEEEE", "#FFFFFF"]
    """.write(to: invalidMode, atomically: true, encoding: .utf8)
  #expect(throws: TerminalThemeStoreError.invalidFormat("主题 meta.mode 必须是 light 或 dark。")) {
    try TerminalThemeStore.load(from: invalidMode)
  }

  let symlink = directory.appendingPathComponent("linked.astertheme")
  try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: invalid)
  #expect(throws: TerminalThemeStoreError.notRegularFile) {
    try TerminalThemeStore.load(from: symlink)
  }
}

@Test("主题校验拒绝不完整调色板和超长名称")
func terminalThemeValidationRejectsInvalidValues() throws {
  var theme = try #require(TerminalThemeCatalog.theme(named: "Ayu Light"))
  theme.palette.ansiColors.removeLast()
  #expect(throws: TerminalThemeStoreError.invalidPalette) {
    try TerminalThemeStore.validate(theme)
  }

  theme = try #require(TerminalThemeCatalog.theme(named: "Ayu Light"))
  theme.name = String(repeating: "A", count: 129)
  #expect(throws: TerminalThemeStoreError.invalidName) {
    try TerminalThemeStore.validate(theme)
  }
}

@Test("主题解析优先使用自定义主题并为丢失选择提供同模式回退")
func terminalThemeResolutionUsesCustomThemeAndSafeFallback() throws {
  var custom = try #require(TerminalThemeCatalog.theme(named: "Paper"))
  custom = custom.duplicated(name: "Studio Paper")

  #expect(
    TerminalThemeCatalog.resolve(named: "Studio Paper", customThemes: [custom], mode: .light)
      == custom)
  #expect(
    TerminalThemeCatalog.resolve(named: "Missing", customThemes: [], mode: .dark).name
      == "Ayu Dark")
}

@Test("自定义主题库为重名导入生成稳定名称并支持原位编辑")
func customThemeLibraryMaintainsUniqueEditableThemes() throws {
  let source = try #require(TerminalThemeCatalog.theme(named: "Paper"))
  var library = TerminalThemeLibrary()
  let first = library.add(source.duplicated(name: "Studio"))
  let second = library.add(source.duplicated(name: "Studio"))

  #expect(first.name == "Studio")
  #expect(second.name == "Studio 2")
  #expect(library.customThemes.count == 2)

  var edited = first
  edited.palette.accent = try #require(HexColor("#123456"))
  let didUpdate = library.update(edited)
  #expect(didUpdate)
  #expect(library.customThemes.first { $0.id == first.id }?.palette.accent == edited.palette.accent)

  var duplicateName = second
  duplicateName.name = first.name
  let didAcceptDuplicateName = library.update(duplicateName)
  #expect(!didAcceptDuplicateName)
}
