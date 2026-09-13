import AsterCore
import Foundation

/// App 端的界面语言装配：按设置解析出语言，从 SwiftPM 资源 bundle 里找到对应的
/// `<code>.lproj` 子 bundle，并把 `L()` 的翻译钩子指向它。启动时调用一次；
/// 之后改设置只写配置，界面重启后才切换（菜单、已开窗口不会就地重绘）。
enum AppLocalization {
  /// 当前生效的语言；未 `apply` 前是源语言。
  nonisolated(unsafe) private(set) static var current: InterfaceLanguage = .source

  /// 解析并安装翻译表。`preferredLanguages` 可注入以便测试「跟随系统」的解析。
  static func apply(setting: String, preferredLanguages: [String] = Locale.preferredLanguages) {
    let language = InterfaceLanguage.resolve(setting: setting, preferredLanguages: preferredLanguages)
    install(language)
  }

  /// 直接切到某个具体语言。源语言不需要 bundle；其它语言找不到 `.lproj` 时退回原文，
  /// 只记录诊断而不阻塞启动——文案退化不该让终端打不开。
  static func install(_ language: InterfaceLanguage) {
    current = language
    guard language != .source, let bundle = localizationBundle(for: language) else {
      CoreLocalization.translator = nil
      if language != .source {
        DiagnosticsCenter.shared.record(
          "localization.bundle_missing", level: .warning, category: .integration,
          attributes: ["language": language.rawValue])
      }
      return
    }
    CoreLocalization.translator = { value in String(localized: value, bundle: bundle) }
  }

  /// `AsterTerminal_Aster.bundle/<code>.lproj` 作为独立 Bundle 打开，查表就不受进程
  /// `AppleLanguages` 影响，用户在 Aster 里选的语言才是唯一真值。
  /// SwiftPM 会把 `zh-Hant.lproj` 落成小写目录名，所以原名找不到时再按小写找一次。
  static func localizationBundle(for language: InterfaceLanguage) -> Bundle? {
    guard let resources = PackagedResourceBundle.locate(named: "AsterTerminal_Aster.bundle") else {
      return nil
    }
    let candidates = [language.rawValue, language.rawValue.lowercased()]
    for name in candidates {
      if let path = resources.path(forResource: name, ofType: "lproj"), let bundle = Bundle(path: path) {
        return bundle
      }
    }
    return nil
  }
}
