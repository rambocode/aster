# Aster 界面本地化改写规范（所有子代理必读）

## 背景
Aster 是纯 AppKit 的 macOS 终端（SwiftPM 工程，Swift 6 严格并发）。界面文案原来全是硬编码简体中文。
现在已有基础设施：
- `Sources/AsterCore/CoreLocalization.swift`：全局函数 `L(_ value: String.LocalizationValue) -> String`，
  以及 `InterfaceLanguage` 枚举（system / zh-Hans / zh-Hant / en / ja / fr / de）。
- `Sources/Aster/AppLocalization.swift`：App 启动时按设置装载 `<lang>.lproj/Localizable.strings`。
- 翻译表：`Sources/Aster/Localization/{en,ja,fr,de,zh-Hant}.lproj/Localizable.strings`（**不要直接改**，由主线程合并生成）。
- 校验脚本：`python3 scripts/check-localizations.py check`。

你的任务分两部分：**(1) 把你负责文件里面向用户的中文文案改成 `L("…")`；(2) 输出这些 key 的 5 种语言翻译 JSON。**

## 1. 改写规则
- 只改分配给你的文件。不要动测试、不要动其它文件、不要改 `.strings`。
- 用 `L("中文原文")` 包住**用户能在 App 界面上看到**的中文：菜单标题、按钮、标签、提示、占位符、tooltip、
  NSAlert 文案、通知、HUD/overlay 文案、状态栏/侧栏文本、界面上显示的错误信息（含会被展示的
  `LocalizedError.errorDescription`）、accessibility label。
- **不要**包：代码注释、日志/诊断事件名（`DiagnosticsCenter.record("xxx")` 的 event 与 attributes）、
  用作字典 key / 比较 / 持久化 / rawValue 的字符串、写进文件/配置/shell 脚本/JSON 协议的内容、
  发给 LLM/Agent 的 prompt、`Notification.Name`、正则、路径、URL、命令行参数、
  只在 aster-cli / MCP（非 App 界面）输出的文案。判断依据是"用户在 Aster.app 窗口里能不能看见"。
- `L` 定义在 AsterCore；文件若没有 `import AsterCore` 需要加上。
- **插值规则（重要）**：`L("共 \(count) 个")` 的 key 由 Foundation 按插值类型生成；只有 String 类型生成 `%@`。
  所以 `L()` 里的每个 `\(...)` 必须是 **String 类型**表达式：Int/Double/其它类型先 `String(x)` 或格式化成
  局部变量再插值。例：`L("共 \(String(count)) 个")`、`let size = formatter.string(...); L("大小 \(size)")`。
  Optional 也不行（会变成 "Optional(...)"），先解包/给默认值。
- 不要在 `L()` 里用多行 `"""` 字面量；改成单行 `\n` 拼接。
- `static let x = "中文"` 这种会在首次访问时冻结语言；面向界面的静态文案改成计算属性 `static var x: String { L("…") }`，
  或在使用点再 `L()`。枚举 `label` / `title` 这类 switch 计算属性直接在 case 里 `L()`。
- 枚举 rawValue 是中文并同时用于持久化的，rawValue 不改；显示处用 `L(String.LocalizationValue(rawValue))`
  这种动态 key 时，把每个可能的 rawValue 作为 key 写进翻译 JSON。动态 key 尽量少用。
- `String(format: "中文 %d", n)` 改成 `L("中文 \(String(n))")`。
- 字面 `%` 在 key/翻译里写 `%%`。
- 不要改变文案原文的含义和标点；不要顺手重构无关代码；每个新增/修改的函数按仓库规范保留/补一行中文注释。
- 改完运行 `swift build --product Aster 2>&1 | grep -E "error:" ` 确认你负责的文件无编译错误
  （其它代理可能同时在改别的文件，若错误不在你的文件里，等 30 秒重试一次；构建被锁时耐心等待）。
  **不要运行 swift test**（全量测试会卡死机器）。
- 改完运行 `python3 scripts/check-localizations.py check 2>&1 | grep "MISSING (你的文件路径"`，
  确认你输出的 JSON 覆盖了你文件里的所有 key（脚本会列出源码 key；MISSING 是正常的，因为 .strings 还没合并，
  你只需保证这些 key 都在你的 JSON 里）。可以用脚本推导 key：
  `python3 -c "import sys;sys.path.insert(0,'scripts');import importlib;m=importlib.import_module('check-localizations');print('\n'.join(m.extract_keys(open('FILE').read(),'FILE')[0]))"`

## 2. 翻译 JSON 输出
写到 `l10n-work/<组名>.json`，格式：
```json
{
  "语言": {"en": "Language", "ja": "言語", "fr": "Langue", "de": "Sprache", "zh-Hant": "語言"},
  "设置失败：%@": {"en": "Setup failed: %@", "ja": "設定に失敗しました：%@", "fr": "Échec de la configuration : %@", "de": "Einrichtung fehlgeschlagen: %@", "zh-Hant": "設定失敗：%@"}
}
```
- key = Swift 字面量原文（引号之间的内容，保留 `\n` `\"` 这类 Swift 转义写法），插值处写 `%@`，字面 `%` 写 `%%`。
  JSON 里反斜杠要再转义一次（建议用 Python `json.dump(ensure_ascii=False, indent=2)` 生成，别手写）。
- value 同样用 .strings 转义写法：换行 `\n`、引号 `\"`。多个插值需要调换顺序时用 `%1$@ %2$@`。
- 5 种语言都必须给全：en、ja、fr、de、zh-Hant。
- 术语表（保持一致）：工作区=Workspace/ワークスペース/Espace de travail/Arbeitsbereich/工作區；
  窗格/Pane=Pane（ja: ペイン, fr: Panneau, de: Bereich, zh-Hant: 窗格）；标签页=Tab/タブ/Onglet/Tab/標籤頁；
  分屏=Split/分割/Division/Teilung/分割；会话=Session/セッション/Session/Sitzung/工作階段；
  设置=Settings/設定/Réglages/Einstellungen/設定；记忆=Memory/メモリー/Mémoire/Erinnerungen/記憶；
  机器（远程机器）=Machine/マシン/Machine/Rechner/機器；快捷键=Shortcut/ショートカット/Raccourci/Tastenkürzel/快速鍵；
  主题=Theme/テーマ/Thème/Design/主題；侧栏=Sidebar/サイドバー/Barre latérale/Seitenleiste/側邊欄；
  详情面板=Details panel/詳細パネル/Panneau de détails/Detailbereich/詳細面板；
  Recipe、Agent、Quick Terminal、Shell、Aster、Ghostty、tmux、Claude Code、Codex 等专名不翻译。
- 繁体中文用台灣慣用語（設定、視窗、檔案、資料夾、標籤頁、貼上、複製…）。
- 英文用 macOS 风格 Title Case 标题（菜单/按钮），句子用 sentence case；德语名词大写；法语标点前留窄空格可省略但冒号前留空格。
- 翻译要自然、简洁，符合各语言 macOS 系统 App 的用语习惯。

## 3. 完成汇报
最后用不超过 15 行汇报：改了哪些文件、key 数量、刻意**没**包的类别（及理由）、编译是否通过、有无遗留问题。
