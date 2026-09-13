import Foundation
import os

/// 界面语言设置的取值集合。`system` 跟随 macOS 偏好语言；其余为 Aster 自带翻译的语言，
/// rawValue 同时是配置文件里持久化的值与资源 bundle 中 `<code>.lproj` 的目录名。
public enum InterfaceLanguage: String, CaseIterable, Codable, Equatable, Sendable {
  case system
  case zhHans = "zh-Hans"
  case zhHant = "zh-Hant"
  case en
  case ja
  case fr
  case de

  /// 源语言：代码里的文案原文是简体中文，没有翻译时直接展示原文。
  public static let source: InterfaceLanguage = .zhHans

  /// 有翻译资源的语言（不含 `system`）。
  public static var translatable: [InterfaceLanguage] { allCases.filter { $0 != .system } }

  /// 下拉菜单里的显示名：各语言用自己的写法，用户切错语言时也能认出来。
  public var nativeName: String {
    switch self {
    case .system: L("跟随系统")
    case .zhHans: "简体中文"
    case .zhHant: "繁體中文"
    case .en: "English"
    case .ja: "日本語"
    case .fr: "Français"
    case .de: "Deutsch"
    }
  }

  /// 把配置值解析成实际语言；未知值按 `system` 处理，避免手改配置写错后界面失效。
  public static func setting(_ rawValue: String) -> InterfaceLanguage {
    InterfaceLanguage(rawValue: rawValue) ?? .system
  }

  /// 把设置值 + 系统偏好语言列表解析为一个具体语言（永不返回 `system`）。
  /// 跟随系统时走 Foundation 的语言匹配（`zh-TW` → zh-Hant、`en-GB` → en 等），
  /// 系统语言完全不在支持列表时回退英文：对不认识中文的用户，英文比源语言更可读。
  public static func resolve(setting: String, preferredLanguages: [String]) -> InterfaceLanguage {
    let chosen = InterfaceLanguage.setting(setting)
    guard chosen == .system else { return chosen }
    let candidates = translatable.map(\.rawValue)
    let matched = Bundle.preferredLocalizations(from: candidates, forPreferences: preferredLanguages)
    return matched.first.flatMap(InterfaceLanguage.init(rawValue:)) ?? .en
  }
}

/// 全局文案翻译钩子。AsterCore 自身不持有资源 bundle：App 启动时把 `translator` 指向
/// 自己的 `.lproj` 表；aster-cli / MCP 等不装钩子的进程直接得到源语言（简体中文）原文。
/// 单元测试也不装钩子，所以断言中文文案的既有测试不受系统语言影响。
public enum CoreLocalization {
  public typealias Translator = @Sendable (String.LocalizationValue) -> String

  private static let storage = OSAllocatedUnfairLock<Translator?>(initialState: nil)

  /// 当前翻译函数；nil 表示源语言直出。启动时设置一次，之后只读。
  public static var translator: Translator? {
    get { storage.withLock { $0 } }
    set { storage.withLock { $0 = newValue } }
  }

  /// 无翻译时的兜底：走 `Bundle.main` 的查表语义，缺 key 就把原文按插值格式化后返回。
  public static func string(_ value: String.LocalizationValue) -> String {
    if let translator { return translator(value) }
    return String(localized: value, bundle: .main)
  }
}

/// 界面文案入口：`L("语言")`、`L("设置失败：\(reason)")`。
/// key 是简体中文原文，插值处在 `.strings` 表里写作 `%@`；插值表达式必须是 String 类型，
/// 否则 Foundation 会生成 `%lld` 一类的 key 而查不到翻译。
public func L(_ value: String.LocalizationValue) -> String {
  CoreLocalization.string(value)
}
