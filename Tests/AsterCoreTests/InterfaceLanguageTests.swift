import Foundation
import Testing

@testable import AsterCore

@Test("未知语言码按跟随系统处理")
func unknownLanguageSettingFallsBackToSystem() {
  #expect(InterfaceLanguage.setting("klingon") == .system)
  #expect(InterfaceLanguage.setting("") == .system)
  #expect(InterfaceLanguage.setting("zh-Hant") == .zhHant)
}

@Test("显式选择的语言不受系统偏好影响")
func explicitLanguageIgnoresSystemPreferences() {
  #expect(InterfaceLanguage.resolve(setting: "en", preferredLanguages: ["zh-Hans-CN"]) == .en)
  #expect(InterfaceLanguage.resolve(setting: "ja", preferredLanguages: ["en-US"]) == .ja)
}

@Test("跟随系统按 macOS 偏好语言匹配，区域变体也能命中")
func systemSettingMatchesPreferredLanguages() {
  #expect(InterfaceLanguage.resolve(setting: "system", preferredLanguages: ["zh-TW"]) == .zhHant)
  #expect(InterfaceLanguage.resolve(setting: "system", preferredLanguages: ["zh-Hans-CN"]) == .zhHans)
  #expect(InterfaceLanguage.resolve(setting: "system", preferredLanguages: ["fr-CA", "en"]) == .fr)
  #expect(InterfaceLanguage.resolve(setting: "system", preferredLanguages: ["de-CH"]) == .de)
}

@Test("系统语言不受支持时回退英文")
func unsupportedSystemLanguageFallsBackToEnglish() {
  #expect(InterfaceLanguage.resolve(setting: "system", preferredLanguages: ["ko-KR"]) == .en)
  #expect(InterfaceLanguage.resolve(setting: "system", preferredLanguages: []) == .en)
}

@Test("配置归一化把非法语言码写回 system")
func configurationNormalizesLanguage() {
  var configuration = AsterConfiguration()
  configuration.general.language = "not-a-language"
  #expect(configuration.normalized().general.language == "system")
  configuration.general.language = "fr"
  #expect(configuration.normalized().general.language == "fr")
}

@Test("未安装翻译钩子时 L() 按源语言原文格式化插值")
func localizationFallsBackToSourceText() {
  let previous = CoreLocalization.translator
  defer { CoreLocalization.translator = previous }
  CoreLocalization.translator = nil
  let name = "tmux"
  #expect(L("已连接到 \(name)") == "已连接到 tmux")
  #expect(L("进度 100% 完成") == "进度 100% 完成")
}

@Test("安装翻译钩子后 L() 查 .strings 表，插值 key 为 %@")
func localizationUsesInstalledTranslator() throws {
  let previous = CoreLocalization.translator
  defer { CoreLocalization.translator = previous }
  // 用临时目录造一个真实的 lproj 表，验证 Foundation 生成的插值 key 与 .strings 约定一致。
  let root = FileManager.default.temporaryDirectory
    .appendingPathComponent("aster-l10n-\(UUID().uuidString)/en.lproj", isDirectory: true)
  try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
  let table = """
    "已连接到 %@" = "Connected to %@";
    "进度 100% 完成" = "Progress 100% done";
    "缩放 %@ 的 100%% 视图" = "100%% view at %@";
    """
  try table.write(to: root.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
  let bundle = try #require(Bundle(url: root))
  CoreLocalization.translator = { value in String(localized: value, bundle: bundle) }

  let name = "tmux"
  #expect(L("已连接到 \(name)") == "Connected to tmux")
  // 无插值的文案按原文逐字查表（% 单写）；带插值的才按格式串处理（% 写作 %%）。
  #expect(L("进度 100% 完成") == "Progress 100% done")
  #expect(L("缩放 \(name) 的 100% 视图") == "100% view at tmux")
  #expect(L("没有翻译的文案") == "没有翻译的文案")
}

@Test("重复翻译不累积回调栈，避免新增和切换标签随使用时间变慢")
func localizationLookupKeepsCallbackStackBounded() throws {
  let previous = CoreLocalization.translator
  defer { CoreLocalization.translator = previous }
  CoreLocalization.translator = { _ in String(Thread.callStackReturnAddresses.count) }

  // 同一调用点重复走实际 L() 入口。计数替代耗时阈值，避免机器负载导致性能测试抖动。
  // 每次读锁内闭包若发生 reabstraction 写回，后续调用就会穿过不断增长的包装栈。
  var depths: [Int] = []
  for _ in 0..<256 {
    depths.append(try #require(Int(L("语言"))))
  }
  let first = try #require(depths.first)
  let last = try #require(depths.last)
  #expect(last <= first + 8, "翻译回调栈从 \(first) 增长到 \(last)")
}
