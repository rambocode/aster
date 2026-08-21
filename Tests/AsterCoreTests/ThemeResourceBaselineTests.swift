import Foundation
import Testing

@testable import AsterCore

/// 仓库内主题基线目录（`Resources/themes`）。Aster 是独立应用，24 套主题以文件形式
/// 存在项目里，不依赖开发机上是否装了 Otty；这里由测试文件位置推导仓库根。
private var baselineThemesDirectory: URL {
  URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()  // AsterCoreTests
    .deletingLastPathComponent()  // Tests
    .deletingLastPathComponent()  // 仓库根
    .appendingPathComponent("Resources/themes", isDirectory: true)
}

private func baselineThemeFiles() throws -> [URL] {
  try FileManager.default.contentsOfDirectory(
    at: baselineThemesDirectory,
    includingPropertiesForKeys: nil,
    options: [.skipsHiddenFiles]
  )
  .filter { $0.pathExtension.lowercased() == "astertheme" }
  .sorted { $0.lastPathComponent < $1.lastPathComponent }
}

@Test("仓库基线主题文件与内置主题表一一对应")
func baselineThemeFilesCoverBuiltIns() throws {
  let files = try baselineThemeFiles()
  let fileIDs = Set(files.map { $0.deletingPathExtension().lastPathComponent })
  let builtInIDs = Set(TerminalThemeCatalog.builtIns.map(\.id))
  #expect(fileIDs == builtInIDs)
}

/// 防漂移闸门：`BuiltInThemeTable` 是手工抄录的 Swift 表，改动时很容易与磁盘基线
/// 脱节。只比对终端色表——界面令牌（radius、sidebar 配色等）是内置表在文件未声明
/// 时手工补齐的默认级联，两侧本就不必逐字段相等，比进来只会得到假失败。
@Test("基线主题文件解析结果与内置表一致")
func baselineThemeFilesMatchBuiltInTable() throws {
  for file in try baselineThemeFiles() {
    let id = file.deletingPathExtension().lastPathComponent
    guard let builtin = TerminalThemeCatalog.builtIns.first(where: { $0.id == id }) else {
      Issue.record("内置表缺少主题 \(id)")
      continue
    }
    let parsed = try TerminalThemeStore.load(from: file)
    #expect(parsed.name == builtin.name, "\(id) 名称不一致")
    #expect(parsed.mode == builtin.mode, "\(id) 模式不一致")
    #expect(parsed.palette.foreground == builtin.palette.foreground, "\(id) 前景色不一致")
    #expect(
      parsed.palette.windowBackground == builtin.palette.windowBackground, "\(id) 背景色不一致")
    #expect(parsed.palette.ansiColors == builtin.palette.ansiColors, "\(id) ANSI 调色板不一致")
  }
}

/// 主题文件按内容而非后缀选解析器：基线文件是 TOML 文本，即使后缀是 `.astertheme`
/// 也必须走 TOML 分支，否则升级后用户目录里的主题会整批读不出来。
@Test("TOML 内容配 .astertheme 后缀仍可解析")
func tomlContentWithAsterThemeExtensionParses() throws {
  let directory = FileManager.default.temporaryDirectory
    .appendingPathComponent(UUID().uuidString, isDirectory: true)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: directory) }

  let source = try #require(try baselineThemeFiles().first)
  let target = directory.appendingPathComponent("copied.astertheme")
  try FileManager.default.copyItem(at: source, to: target)

  let parsed = try TerminalThemeStore.load(from: target)
  #expect(parsed.palette.ansiColors.count == 16)
}
