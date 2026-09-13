import AppKit
import Testing

@testable import Aster
@testable import AsterCore

/// 用随包分发的真实翻译表验证：切到英文后，`L()`、主菜单标题与设置页注入脚本都换语言；
/// 切回源语言后恢复中文。覆盖 issue #1「选择 English 无效」的整条链路。
@Test("切换到英文后主菜单与文案使用随包翻译表")
@MainActor
func switchingToEnglishLocalizesMenusAndStrings() throws {
  _ = NSApplication.shared
  defer { AppLocalization.install(.source) }

  for language in InterfaceLanguage.translatable where language != .source {
    #expect(AppLocalization.localizationBundle(for: language) != nil, "\(language.rawValue).lproj 缺失")
  }

  AppLocalization.install(.en)
  #expect(AppLocalization.current == .en)
  #expect(L("语言") == "Language")
  #expect(InterfaceLanguage.system.nativeName == "System Default")
  let name = "tmux"
  #expect(L("已导入主题“\(name)”") == "Theme \"tmux\" has been imported")

  let suite = "AsterTests.l10n.\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suite)!
  defaults.removePersistentDomain(forName: suite)
  defer { defaults.removePersistentDomain(forName: suite) }
  let delegate = AsterAppDelegate(
    model: AppModel(defaults: defaults), preferences: AppPreferences(defaults: defaults))
  // 顶层 NSMenuItem 的 title 是占位，真正的菜单名在各自 submenu 上。
  let titles = delegate.makeMainMenu().items.compactMap { $0.submenu?.title }
  #expect(titles.contains("File"))
  #expect(titles.contains("Edit"))
  #expect(titles.contains("Window"))
  #expect(!titles.contains("文件"))

  AppLocalization.install(.source)
  #expect(L("语言") == "语言")
  let sourceTitles = delegate.makeMainMenu().items.compactMap { $0.submenu?.title }
  #expect(sourceTitles.contains("文件"))
}

@Test("繁体、日、法、德翻译表都能命中同一 key")
func everyLanguageTranslatesTheSameKey() {
  defer { AppLocalization.install(.source) }
  var seen: Set<String> = []
  for language in [InterfaceLanguage.zhHant, .ja, .fr, .de, .en] {
    AppLocalization.install(language)
    let text = L("跟随系统")
    #expect(text != "跟随系统", "\(language.rawValue) 没有翻译「跟随系统」")
    seen.insert(text)
  }
  #expect(seen.count == 5)
}
