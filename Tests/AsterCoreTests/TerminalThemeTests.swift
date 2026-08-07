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

/// 将 Otty 1.3.1 原始 `.ottytheme` 中的终端前景、背景与 ANSI 16 色压成稳定签名。
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
  .init(name: "One Light", mode: .light, sha256: "1a2ab206eae15f95d9c1241fbff0879e78cf8a2a17082fff8d31ae7f7020faf1"),
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

  var theme = try #require(TerminalThemeCatalog.theme(named: "Paper"))
  theme.id = UUID().uuidString
  theme.name = "My Paper"
  theme.isBuiltIn = false
  let file = directory.appendingPathComponent("my-paper.astertheme")

  try TerminalThemeStore.save(theme, to: file)
  #expect(try TerminalThemeStore.load(from: file) == theme)

  let pipe = directory.appendingPathComponent("blocked.astertheme")
  #expect(pipe.path.withCString { Darwin.mkfifo($0, 0o600) } == 0)
  #expect(throws: TerminalThemeStoreError.notRegularFile) {
    try TerminalThemeStore.load(from: pipe)
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
