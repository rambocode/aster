/* Aster 官网 —— 多语言（zh / en / ja / de / fr）
   中文是页面里的原文与词典键；切换语言时按文本节点原样替换，切回中文即还原。 */
(function () {
  "use strict";

  var LANGS = [
    { code: "zh", label: "中文", html: "zh-CN" },
    { code: "en", label: "English", html: "en" },
    { code: "ja", label: "日本語", html: "ja" },
    { code: "de", label: "Deutsch", html: "de" },
    { code: "fr", label: "Français", html: "fr" },
  ];

  /* ---------- 词典：中文原文 → 各语言 ---------- */
  var I18N = {
    en: {
      "功能": "Features",
      "对比": "Compare",
      "文档": "Docs",
      "更新日志": "Changelog",
      "下载 DMG": "Download DMG",
      "下载 Aster": "Download Aster",
      "在 GitHub 上查看": "View on GitHub",
      "Aster Terminal · 原生 AppKit · macOS 14+": "Aster Terminal · Native AppKit · macOS 14+",
      "传统终端给你一个 Shell 窗口；Aster 在同一个原生 macOS 窗口里装下标签、任意分屏、文件预览、Agent 会话与本机补全——完全以 AppKit 构建，轻快克制。":
        "A traditional terminal gives you a shell window. Aster fits tabs, arbitrary splits, file previews, agent sessions and on-device completion into one native macOS window — built entirely with AppKit, light and restrained.",
      "已签名并公证": "Signed & notarized",
      "内置自动更新": "Auto-updates built in",
      "MIT 开源": "MIT open source",
      "Aster 是一个完全使用 AppKit 构建的原生 macOS 终端工作区，采用轻量标签导航、纸张色画布和克制的苔绿色状态反馈。":
        "Aster is a native macOS terminal workspace built entirely with AppKit — lightweight tab navigation, a paper-toned canvas, and restrained moss-green status accents.",
      "完整 VT100/xterm 与全屏 TUI": "Full VT100/xterm & fullscreen TUIs",
      "递归分屏，混排文件与预览": "Recursive splits mixing files & previews",
      ".asterrecipe 工作区导入导出": ".asterrecipe workspace import/export",
      "内置主题，实时终端预览": "built-in themes with live preview",
      "条本机命令补全规格": "on-device command completion specs",
      "使用数据上传": "usage data uploaded",
      "开源许可证": "open-source license",
      "一次拖拽，从此自动更新": "Drag once, auto-update forever",
      "从发布页获取已签名并公证的镜像，macOS 直接验证来源。": "Grab the signed, notarized image from the releases page; macOS verifies its origin directly.",
      "拖进 Applications": "Drag into Applications",
      "打开镜像，把 Aster.app 拖进应用程序文件夹，双击启动。": "Open the image, drag Aster.app into your Applications folder, double-click to launch.",
      "此后交给它自己": "Then let it take care of itself",
      "每天后台检查一次更新，EdDSA 签名与公证双重校验后才安装。": "It checks once a day in the background and installs only after both EdDSA signature and notarization checks pass.",
      "亲眼看看两件小事": "See two small things for yourself",
      "本机智能补全": "On-device smart completion",
      "24 套主题即时切换": "24 themes, switched instantly",
      "选中即生效，无需重启；明暗外观可分开指定。": "Takes effect on selection, no restart; light and dark set separately.",
      "一个窗口里的全部工作": "All your work in one window",
      "完整终端，Ghostty 内核": "A full terminal on the Ghostty core",
      "VT100/xterm、ANSI 真彩色、鼠标与超链接，vim、top、fzf 等全屏 TUI 原生流畅；TERM=auto 安全回退。":
        "VT100/xterm, ANSI true color, mouse and hyperlinks; vim, top and fzf run natively smooth; TERM=auto with a safe fallback.",
      "递归分屏的工作区": "A workspace of recursive splits",
      "任意方向拆分，终端、文件浏览器、编辑器与预览混排在同一窗口；源码、Markdown、图片、PDF、diff、hex 一个 File Pane 全收。":
        "Split in any direction and mix terminals, file browsers, editors and previews in one window; source, Markdown, images, PDF, diff and hex all land in one File Pane.",
      "与 Agent 一起工作": "Working with agents",
      "Claude Code、Codex 会话自动获得标题与运行状态，标签栏一眼看到谁在思考；transcript 直接在 File Pane 里回看。":
        "Claude Code and Codex sessions get titles and run states automatically — the tab bar shows who's thinking at a glance; transcripts replay right in the File Pane.",
      "本机自动补全": "On-device autocomplete",
      "714 份 Fig 命令规格、文件与别名候选、隐私感知学习——补全全部发生在本机，不经过任何服务器。":
        "714 Fig command specs, file and alias candidates, privacy-aware learning — completion happens entirely on this machine, never through a server.",
      "主题与 Recipes": "Themes & Recipes",
      "24 套内置主题带实时终端预览，明暗可分开指定；.asterrecipe 把整个工作区导出成文件，启动即恢复会话。":
        "24 built-in themes with live terminal preview, light and dark set separately; .asterrecipe exports the whole workspace to a file, and sessions restore on launch.",
      "安静地更新": "Updates, quietly",
      "Sparkle 2 后台检查，可选静默安装与预览通道；更新只来自官方源，且必须同时通过签名与公证校验。":
        "Sparkle 2 checks in the background, with optional silent install and a preview channel; updates come only from the official feed and must pass both signature and notarization checks.",
      "和传统终端，差在整个工作区": "Versus traditional terminals: the difference is the workspace",
      "传统终端专注于把 Shell 窗口本身做好；Aster 的范围是围绕终端的整套工作。差异不在快慢，在于哪些事不用再离开这个窗口。":
        "Traditional terminals focus on making the shell window itself good; Aster's scope is the whole job around the terminal. The difference isn't speed — it's what no longer requires leaving the window.",
      "传统终端": "Traditional terminal",
      "看文件": "Viewing files",
      "cat / less，或切去编辑器和 Finder": "cat / less, or switching away to an editor and Finder",
      "File Pane 同窗预览源码、Markdown、图片、PDF、diff、hex": "File Pane previews source, Markdown, images, PDF, diff and hex in the same window",
      "跑 Agent": "Running agents",
      "输出滚过就没了，哪个会话在干活全靠盯": "Output scrolls away; knowing which session is busy means staring at it",
      "Claude Code、Codex 会话自动命名，标签栏显示运行状态，transcript 可回看": "Claude Code and Codex sessions auto-named, run state in the tab bar, transcripts replayable",
      "补全": "Completion",
      "自己攒 fzf、zsh-autosuggestions 一套插件": "Assembling your own stack of fzf and zsh-autosuggestions plugins",
      "开箱内置 714 份命令规格 + 文件/别名候选，本机隐私学习": "714 command specs plus file/alias candidates out of the box, private on-device learning",
      "恢复现场": "Restoring state",
      "布局与会话多数关窗即失，或靠手写脚本": "Layouts and sessions mostly die with the window, or live in hand-written scripts",
      ".asterrecipe 一个文件导出整个工作区，启动即恢复": ".asterrecipe exports the whole workspace to one file, restored on launch",
      "主题": "Themes",
      "找配色文件、改配置、重启生效": "Hunting for color files, editing configs, restarting to apply",
      "24 套内置主题实时预览，明暗分开指定，工作区即时切换": "24 built-in themes with live preview, light/dark set separately, the workspace switches instantly",
      "技术底子": "Foundations",
      "Electron / 跨平台框架的不在少数": "Quite a few are Electron or cross-platform frameworks",
      "纯 AppKit 原生 + Ghostty 终端内核，不上传任何使用数据": "Pure native AppKit plus the Ghostty terminal core; no usage data ever uploaded",
      "给终端一个完整的工作区。": "Give your terminal a whole workspace.",
      "macOS 14 或更高版本，下载即用；也欢迎来 GitHub 参与构建。": "macOS 14 or later, ready right after download; contributions on GitHub are welcome too.",
      "原生 macOS 终端工作区。不含遥测，不上传数据。": "A native macOS terminal workspace. No telemetry, no data uploads.",
      "产品": "Product",
      "下载": "Download",
      "主题库": "Theme gallery",
      "用户指南": "User guide",
      "开发者文档": "Developer docs",
      "常见问题": "FAQ",
      "项目": "Project",
      "MIT 许可证": "MIT License",
      "第三方声明": "Third-party notices",
      "↑↓ 选择": "↑↓ select",
      "Tab 补全": "Tab complete",
      "Esc 关闭": "Esc dismiss",
      "当前仓库分支": "branch in this repo",
    },

    ja: {
      "功能": "機能",
      "对比": "比較",
      "文档": "ドキュメント",
      "更新日志": "更新履歴",
      "下载 DMG": "DMG をダウンロード",
      "下载 Aster": "Aster をダウンロード",
      "在 GitHub 上查看": "GitHub で見る",
      "Aster Terminal · 原生 AppKit · macOS 14+": "Aster Terminal · ネイティブ AppKit · macOS 14+",
      "传统终端给你一个 Shell 窗口；Aster 在同一个原生 macOS 窗口里装下标签、任意分屏、文件预览、Agent 会话与本机补全——完全以 AppKit 构建，轻快克制。":
        "従来のターミナルはシェルのウィンドウを一つくれるだけ。Aster はタブ、自在な分割、ファイルプレビュー、エージェントセッション、ローカル補完を一つのネイティブ macOS ウィンドウに収めます——すべて AppKit 製、軽快で控えめに。",
      "已签名并公证": "署名・公証済み",
      "内置自动更新": "自動アップデート内蔵",
      "MIT 开源": "MIT オープンソース",
      "Aster 是一个完全使用 AppKit 构建的原生 macOS 终端工作区，采用轻量标签导航、纸张色画布和克制的苔绿色状态反馈。":
        "Aster は AppKit だけで作られたネイティブ macOS ターミナルワークスペース。軽量なタブ、紙色のキャンバス、控えめな苔色のステータス表示。",
      "完整 VT100/xterm 与全屏 TUI": "完全な VT100/xterm と全画面 TUI",
      "递归分屏，混排文件与预览": "再帰分割でファイルとプレビューを混在",
      ".asterrecipe 工作区导入导出": ".asterrecipe でワークスペースを入出力",
      "内置主题，实时终端预览": "内蔵テーマ、ライブプレビュー付き",
      "条本机命令补全规格": "ローカル補完のコマンド仕様",
      "使用数据上传": "送信される利用データ",
      "开源许可证": "オープンソースライセンス",
      "一次拖拽，从此自动更新": "一度ドラッグすれば、あとは自動更新",
      "从发布页获取已签名并公证的镜像，macOS 直接验证来源。": "リリースページから署名・公証済みイメージを取得。出所は macOS が直接検証します。",
      "拖进 Applications": "Applications へドラッグ",
      "打开镜像，把 Aster.app 拖进应用程序文件夹，双击启动。": "イメージを開き、Aster.app をアプリケーションフォルダへ。ダブルクリックで起動。",
      "此后交给它自己": "あとは本人に任せる",
      "每天后台检查一次更新，EdDSA 签名与公证双重校验后才安装。": "1日1回バックグラウンドで更新を確認。EdDSA 署名と公証の二重検証を通ってからインストールします。",
      "亲眼看看两件小事": "小さな二つのこと、実際にどうぞ",
      "本机智能补全": "ローカル・スマート補完",
      "24 套主题即时切换": "24 テーマを即時切り替え",
      "选中即生效，无需重启；明暗外观可分开指定。": "選んだ瞬間に反映、再起動不要。ライト／ダークは別々に指定できます。",
      "一个窗口里的全部工作": "仕事のすべてを、一つのウィンドウに",
      "完整终端，Ghostty 内核": "Ghostty コアの完全なターミナル",
      "VT100/xterm、ANSI 真彩色、鼠标与超链接，vim、top、fzf 等全屏 TUI 原生流畅；TERM=auto 安全回退。":
        "VT100/xterm、ANSI トゥルーカラー、マウスとハイパーリンク。vim・top・fzf などの全画面 TUI もネイティブに滑らか。TERM=auto の安全なフォールバック付き。",
      "递归分屏的工作区": "再帰分割のワークスペース",
      "任意方向拆分，终端、文件浏览器、编辑器与预览混排在同一窗口；源码、Markdown、图片、PDF、diff、hex 一个 File Pane 全收。":
        "任意の方向に分割し、ターミナル・ファイルブラウザ・エディタ・プレビューを同じウィンドウに。ソース、Markdown、画像、PDF、diff、hex は一つの File Pane に収まります。",
      "与 Agent 一起工作": "エージェントと一緒に働く",
      "Claude Code、Codex 会话自动获得标题与运行状态，标签栏一眼看到谁在思考；transcript 直接在 File Pane 里回看。":
        "Claude Code や Codex のセッションに自動でタイトルと実行状態が付き、どのタブが考え中かは一目瞭然。transcript は File Pane でそのまま見返せます。",
      "本机自动补全": "ローカル自動補完",
      "714 份 Fig 命令规格、文件与别名候选、隐私感知学习——补全全部发生在本机，不经过任何服务器。":
        "714 の Fig コマンド仕様、ファイル・エイリアス候補、プライバシーに配慮した学習。補完はすべてローカルで完結し、サーバーを経由しません。",
      "主题与 Recipes": "テーマと Recipes",
      "24 套内置主题带实时终端预览，明暗可分开指定；.asterrecipe 把整个工作区导出成文件，启动即恢复会话。":
        "24 の内蔵テーマにライブプレビュー。ライト／ダークは別指定。.asterrecipe でワークスペースを丸ごとファイルに書き出し、起動時にセッションを復元します。",
      "安静地更新": "静かにアップデート",
      "Sparkle 2 后台检查，可选静默安装与预览通道；更新只来自官方源，且必须同时通过签名与公证校验。":
        "Sparkle 2 がバックグラウンドで確認。サイレントインストールとプレビューチャンネルは任意。更新は公式フィードのみ、署名と公証の両方を通過したものだけです。",
      "和传统终端，差在整个工作区": "従来のターミナルとの差は、ワークスペースまるごと",
      "传统终端专注于把 Shell 窗口本身做好；Aster 的范围是围绕终端的整套工作。差异不在快慢，在于哪些事不用再离开这个窗口。":
        "従来のターミナルはシェルウィンドウそのものを磨きます。Aster の守備範囲はターミナルを取り巻く仕事全体。差は速さではなく、何のためにウィンドウを離れなくて済むかです。",
      "传统终端": "従来のターミナル",
      "看文件": "ファイル閲覧",
      "cat / less，或切去编辑器和 Finder": "cat / less、あるいはエディタや Finder へ切り替え",
      "File Pane 同窗预览源码、Markdown、图片、PDF、diff、hex": "File Pane が同じウィンドウでソース・Markdown・画像・PDF・diff・hex をプレビュー",
      "跑 Agent": "エージェント",
      "输出滚过就没了，哪个会话在干活全靠盯": "出力は流れて消え、どのセッションが動いているかは目視頼み",
      "Claude Code、Codex 会话自动命名，标签栏显示运行状态，transcript 可回看": "Claude Code・Codex セッションに自動命名、タブに実行状態、transcript も見返せる",
      "补全": "補完",
      "自己攒 fzf、zsh-autosuggestions 一套插件": "fzf や zsh-autosuggestions を自分で寄せ集める",
      "开箱内置 714 份命令规格 + 文件/别名候选，本机隐私学习": "714 のコマンド仕様とファイル／エイリアス候補を標準搭載、学習もローカルで",
      "恢复现场": "状態の復元",
      "布局与会话多数关窗即失，或靠手写脚本": "レイアウトとセッションは大抵ウィンドウと共に消える。さもなければ手書きスクリプト",
      ".asterrecipe 一个文件导出整个工作区，启动即恢复": ".asterrecipe 一つでワークスペースを書き出し、起動時に復元",
      "主题": "テーマ",
      "找配色文件、改配置、重启生效": "配色ファイルを探し、設定をいじり、再起動して反映",
      "24 套内置主题实时预览，明暗分开指定，工作区即时切换": "24 の内蔵テーマをライブプレビュー、ライト／ダーク別指定、即時切り替え",
      "技术底子": "技術的土台",
      "Electron / 跨平台框架的不在少数": "Electron やクロスプラットフォーム製も少なくない",
      "纯 AppKit 原生 + Ghostty 终端内核，不上传任何使用数据": "純粋な AppKit ネイティブ + Ghostty コア。利用データは一切送信しません",
      "给终端一个完整的工作区。": "ターミナルに、まるごとのワークスペースを。",
      "macOS 14 或更高版本，下载即用；也欢迎来 GitHub 参与构建。": "macOS 14 以降、ダウンロードしてすぐ使えます。GitHub での参加も歓迎です。",
      "原生 macOS 终端工作区。不含遥测，不上传数据。": "ネイティブ macOS ターミナルワークスペース。テレメトリなし、データ送信なし。",
      "产品": "プロダクト",
      "下载": "ダウンロード",
      "主题库": "テーマギャラリー",
      "用户指南": "ユーザーガイド",
      "开发者文档": "開発者ドキュメント",
      "常见问题": "よくある質問",
      "项目": "プロジェクト",
      "MIT 许可证": "MIT ライセンス",
      "第三方声明": "サードパーティ表記",
      "↑↓ 选择": "↑↓ 選択",
      "Tab 补全": "Tab 補完",
      "Esc 关闭": "Esc 閉じる",
      "当前仓库分支": "このリポジトリのブランチ",
    },

    de: {
      "功能": "Funktionen",
      "对比": "Vergleich",
      "文档": "Doku",
      "更新日志": "Changelog",
      "下载 DMG": "DMG laden",
      "下载 Aster": "Aster laden",
      "在 GitHub 上查看": "Auf GitHub ansehen",
      "Aster Terminal · 原生 AppKit · macOS 14+": "Aster Terminal · Natives AppKit · macOS 14+",
      "传统终端给你一个 Shell 窗口；Aster 在同一个原生 macOS 窗口里装下标签、任意分屏、文件预览、Agent 会话与本机补全——完全以 AppKit 构建，轻快克制。":
        "Ein klassisches Terminal gibt dir ein Shell-Fenster. Aster bringt Tabs, beliebige Splits, Dateivorschau, Agent-Sitzungen und lokale Vervollständigung in einem nativen macOS-Fenster unter — komplett in AppKit gebaut, leicht und zurückhaltend.",
      "已签名并公证": "Signiert & notarisiert",
      "内置自动更新": "Auto-Updates integriert",
      "MIT 开源": "MIT Open Source",
      "Aster 是一个完全使用 AppKit 构建的原生 macOS 终端工作区，采用轻量标签导航、纸张色画布和克制的苔绿色状态反馈。":
        "Aster ist ein nativer macOS-Terminal-Arbeitsbereich, komplett in AppKit gebaut — leichte Tab-Navigation, papierfarbene Fläche, dezente moosgrüne Statusakzente.",
      "完整 VT100/xterm 与全屏 TUI": "Volles VT100/xterm & Vollbild-TUIs",
      "递归分屏，混排文件与预览": "Rekursive Splits, Dateien & Vorschau gemischt",
      ".asterrecipe 工作区导入导出": ".asterrecipe-Import/-Export",
      "内置主题，实时终端预览": "integrierte Themes mit Live-Vorschau",
      "条本机命令补全规格": "lokale Befehls-Spezifikationen",
      "使用数据上传": "hochgeladene Nutzungsdaten",
      "开源许可证": "Open-Source-Lizenz",
      "一次拖拽，从此自动更新": "Einmal ziehen, ab dann automatische Updates",
      "从发布页获取已签名并公证的镜像，macOS 直接验证来源。": "Hol dir das signierte, notarisierte Image von der Releases-Seite; macOS prüft die Herkunft direkt.",
      "拖进 Applications": "In „Programme“ ziehen",
      "打开镜像，把 Aster.app 拖进应用程序文件夹，双击启动。": "Image öffnen, Aster.app in den Programme-Ordner ziehen, per Doppelklick starten.",
      "此后交给它自己": "Ab hier macht es das selbst",
      "每天后台检查一次更新，EdDSA 签名与公证双重校验后才安装。": "Einmal täglich Hintergrund-Check; installiert wird erst nach EdDSA-Signatur- und Notarisierungsprüfung.",
      "亲眼看看两件小事": "Zwei Kleinigkeiten, live",
      "本机智能补全": "Lokale intelligente Vervollständigung",
      "24 套主题即时切换": "24 Themes, sofort umgeschaltet",
      "选中即生效，无需重启；明暗外观可分开指定。": "Wirkt sofort bei Auswahl, ohne Neustart; Hell und Dunkel getrennt wählbar.",
      "一个窗口里的全部工作": "Die ganze Arbeit in einem Fenster",
      "完整终端，Ghostty 内核": "Volles Terminal mit Ghostty-Kern",
      "VT100/xterm、ANSI 真彩色、鼠标与超链接，vim、top、fzf 等全屏 TUI 原生流畅；TERM=auto 安全回退。":
        "VT100/xterm, ANSI-True-Color, Maus und Hyperlinks; vim, top und fzf laufen nativ flüssig; TERM=auto mit sicherem Fallback.",
      "递归分屏的工作区": "Arbeitsbereich mit rekursiven Splits",
      "任意方向拆分，终端、文件浏览器、编辑器与预览混排在同一窗口；源码、Markdown、图片、PDF、diff、hex 一个 File Pane 全收。":
        "In jede Richtung teilen; Terminals, Dateibrowser, Editoren und Vorschau in einem Fenster; Quellcode, Markdown, Bilder, PDF, Diff und Hex in einem File Pane.",
      "与 Agent 一起工作": "Mit Agents arbeiten",
      "Claude Code、Codex 会话自动获得标题与运行状态，标签栏一眼看到谁在思考；transcript 直接在 File Pane 里回看。":
        "Claude-Code- und Codex-Sitzungen bekommen automatisch Titel und Laufstatus — die Tab-Leiste zeigt auf einen Blick, wer gerade denkt; Transcripts direkt im File Pane.",
      "本机自动补全": "Lokales Autocomplete",
      "714 份 Fig 命令规格、文件与别名候选、隐私感知学习——补全全部发生在本机，不经过任何服务器。":
        "714 Fig-Spezifikationen, Datei- und Alias-Kandidaten, datenschutzbewusstes Lernen — Vervollständigung passiert komplett lokal, nie über einen Server.",
      "主题与 Recipes": "Themes & Recipes",
      "24 套内置主题带实时终端预览，明暗可分开指定；.asterrecipe 把整个工作区导出成文件，启动即恢复会话。":
        "24 integrierte Themes mit Live-Vorschau, Hell/Dunkel getrennt; .asterrecipe exportiert den ganzen Arbeitsbereich als Datei, Sitzungen kommen beim Start zurück.",
      "安静地更新": "Updates, leise",
      "Sparkle 2 后台检查，可选静默安装与预览通道；更新只来自官方源，且必须同时通过签名与公证校验。":
        "Sparkle 2 prüft im Hintergrund, optional stille Installation und Preview-Kanal; Updates kommen nur aus der offiziellen Quelle und müssen Signatur- und Notarisierungsprüfung bestehen.",
      "和传统终端，差在整个工作区": "Gegenüber klassischen Terminals: der Unterschied ist der Arbeitsbereich",
      "传统终端专注于把 Shell 窗口本身做好；Aster 的范围是围绕终端的整套工作。差异不在快慢，在于哪些事不用再离开这个窗口。":
        "Klassische Terminals machen das Shell-Fenster selbst gut; Asters Anspruch ist die ganze Arbeit rund ums Terminal. Der Unterschied ist nicht Tempo, sondern wofür man das Fenster nicht mehr verlassen muss.",
      "传统终端": "Klassisches Terminal",
      "看文件": "Dateien ansehen",
      "cat / less，或切去编辑器和 Finder": "cat / less, oder Wechsel zu Editor und Finder",
      "File Pane 同窗预览源码、Markdown、图片、PDF、diff、hex": "File Pane zeigt Quellcode, Markdown, Bilder, PDF, Diff und Hex im selben Fenster",
      "跑 Agent": "Agents ausführen",
      "输出滚过就没了，哪个会话在干活全靠盯": "Ausgabe scrollt davon; wer gerade arbeitet, sieht man nur durch Hinschauen",
      "Claude Code、Codex 会话自动命名，标签栏显示运行状态，transcript 可回看": "Claude-Code- und Codex-Sitzungen automatisch benannt, Laufstatus in der Tab-Leiste, Transcripts nachlesbar",
      "补全": "Vervollständigung",
      "自己攒 fzf、zsh-autosuggestions 一套插件": "fzf und zsh-autosuggestions selbst zusammenstecken",
      "开箱内置 714 份命令规格 + 文件/别名候选，本机隐私学习": "714 Spezifikationen plus Datei-/Alias-Kandidaten ab Werk, privates lokales Lernen",
      "恢复现场": "Zustand wiederherstellen",
      "布局与会话多数关窗即失，或靠手写脚本": "Layouts und Sitzungen enden meist mit dem Fenster — oder leben in Skripten",
      ".asterrecipe 一个文件导出整个工作区，启动即恢复": ".asterrecipe exportiert alles in eine Datei; beim Start wiederhergestellt",
      "主题": "Themes",
      "找配色文件、改配置、重启生效": "Farbdateien suchen, Konfiguration editieren, Neustart",
      "24 套内置主题实时预览，明暗分开指定，工作区即时切换": "24 Themes mit Live-Vorschau, Hell/Dunkel getrennt, sofortiger Wechsel",
      "技术底子": "Fundament",
      "Electron / 跨平台框架的不在少数": "Nicht wenige sind Electron oder Cross-Platform-Frameworks",
      "纯 AppKit 原生 + Ghostty 终端内核，不上传任何使用数据": "Pures natives AppKit plus Ghostty-Kern; keine Nutzungsdaten",
      "给终端一个完整的工作区。": "Gib deinem Terminal einen ganzen Arbeitsbereich.",
      "macOS 14 或更高版本，下载即用；也欢迎来 GitHub 参与构建。": "macOS 14 oder neuer, sofort einsatzbereit; Mitbauen auf GitHub ist willkommen.",
      "原生 macOS 终端工作区。不含遥测，不上传数据。": "Nativer macOS-Terminal-Arbeitsbereich. Keine Telemetrie, keine Daten-Uploads.",
      "产品": "Produkt",
      "下载": "Download",
      "主题库": "Theme-Galerie",
      "用户指南": "Benutzerhandbuch",
      "开发者文档": "Entwickler-Doku",
      "常见问题": "FAQ",
      "项目": "Projekt",
      "MIT 许可证": "MIT-Lizenz",
      "第三方声明": "Drittanbieter-Hinweise",
      "↑↓ 选择": "↑↓ wählen",
      "Tab 补全": "Tab vervollständigen",
      "Esc 关闭": "Esc schließen",
      "当前仓库分支": "Branch in diesem Repo",
    },

    fr: {
      "功能": "Fonctionnalités",
      "对比": "Comparatif",
      "文档": "Docs",
      "更新日志": "Changelog",
      "下载 DMG": "Télécharger le DMG",
      "下载 Aster": "Télécharger Aster",
      "在 GitHub 上查看": "Voir sur GitHub",
      "Aster Terminal · 原生 AppKit · macOS 14+": "Aster Terminal · AppKit natif · macOS 14+",
      "传统终端给你一个 Shell 窗口；Aster 在同一个原生 macOS 窗口里装下标签、任意分屏、文件预览、Agent 会话与本机补全——完全以 AppKit 构建，轻快克制。":
        "Un terminal classique vous donne une fenêtre shell. Aster réunit onglets, splits libres, aperçu de fichiers, sessions d'agents et complétion locale dans une seule fenêtre macOS native — entièrement construit avec AppKit, léger et sobre.",
      "已签名并公证": "Signé et notarié",
      "内置自动更新": "Mises à jour automatiques",
      "MIT 开源": "Open source MIT",
      "Aster 是一个完全使用 AppKit 构建的原生 macOS 终端工作区，采用轻量标签导航、纸张色画布和克制的苔绿色状态反馈。":
        "Aster est un espace de travail terminal natif pour macOS, entièrement construit avec AppKit — onglets légers, toile couleur papier, accents vert mousse discrets.",
      "完整 VT100/xterm 与全屏 TUI": "VT100/xterm complet et TUI plein écran",
      "递归分屏，混排文件与预览": "Splits récursifs, fichiers et aperçus mêlés",
      ".asterrecipe 工作区导入导出": "Import/export .asterrecipe",
      "内置主题，实时终端预览": "thèmes intégrés avec aperçu en direct",
      "条本机命令补全规格": "spécifications de commandes locales",
      "使用数据上传": "donnée d'usage envoyée",
      "开源许可证": "licence open source",
      "一次拖拽，从此自动更新": "Un seul glisser, des mises à jour automatiques ensuite",
      "从发布页获取已签名并公证的镜像，macOS 直接验证来源。": "Récupérez l'image signée et notariée depuis la page des releases ; macOS en vérifie l'origine directement.",
      "拖进 Applications": "Glissez dans Applications",
      "打开镜像，把 Aster.app 拖进应用程序文件夹，双击启动。": "Ouvrez l'image, glissez Aster.app dans le dossier Applications, double-cliquez pour lancer.",
      "此后交给它自己": "Ensuite, il s'occupe de lui-même",
      "每天后台检查一次更新，EdDSA 签名与公证双重校验后才安装。": "Vérification quotidienne en arrière-plan ; installation uniquement après double contrôle signature EdDSA et notarisation.",
      "亲眼看看两件小事": "Deux petites choses, en direct",
      "本机智能补全": "Complétion intelligente locale",
      "24 套主题即时切换": "24 thèmes, changement instantané",
      "选中即生效，无需重启；明暗外观可分开指定。": "Effet immédiat à la sélection, sans redémarrage ; clair et sombre configurables séparément.",
      "一个窗口里的全部工作": "Tout votre travail dans une seule fenêtre",
      "完整终端，Ghostty 内核": "Un terminal complet, moteur Ghostty",
      "VT100/xterm、ANSI 真彩色、鼠标与超链接，vim、top、fzf 等全屏 TUI 原生流畅；TERM=auto 安全回退。":
        "VT100/xterm, vraies couleurs ANSI, souris et hyperliens ; vim, top et fzf fluides en natif ; TERM=auto avec repli sûr.",
      "递归分屏的工作区": "Un espace de travail en splits récursifs",
      "任意方向拆分，终端、文件浏览器、编辑器与预览混排在同一窗口；源码、Markdown、图片、PDF、diff、hex 一个 File Pane 全收。":
        "Divisez dans tous les sens et mélangez terminaux, navigateur de fichiers, éditeurs et aperçus ; source, Markdown, images, PDF, diff et hex dans un seul File Pane.",
      "与 Agent 一起工作": "Travailler avec des agents",
      "Claude Code、Codex 会话自动获得标题与运行状态，标签栏一眼看到谁在思考；transcript 直接在 File Pane 里回看。":
        "Les sessions Claude Code et Codex reçoivent titre et état d'exécution automatiquement — la barre d'onglets montre d'un coup d'œil qui réfléchit ; les transcriptions se relisent dans le File Pane.",
      "本机自动补全": "Autocomplétion locale",
      "714 份 Fig 命令规格、文件与别名候选、隐私感知学习——补全全部发生在本机，不经过任何服务器。":
        "714 spécifications Fig, candidats fichiers et alias, apprentissage respectueux de la vie privée — la complétion se fait entièrement en local, jamais via un serveur.",
      "主题与 Recipes": "Thèmes et Recipes",
      "24 套内置主题带实时终端预览，明暗可分开指定；.asterrecipe 把整个工作区导出成文件，启动即恢复会话。":
        "24 thèmes intégrés avec aperçu en direct, clair et sombre séparés ; .asterrecipe exporte tout l'espace de travail dans un fichier, sessions restaurées au lancement.",
      "安静地更新": "Des mises à jour discrètes",
      "Sparkle 2 后台检查，可选静默安装与预览通道；更新只来自官方源，且必须同时通过签名与公证校验。":
        "Sparkle 2 vérifie en arrière-plan, installation silencieuse et canal preview en option ; les mises à jour ne viennent que de la source officielle et doivent passer signature et notarisation.",
      "和传统终端，差在整个工作区": "Face aux terminaux classiques : la différence, c'est l'espace de travail",
      "传统终端专注于把 Shell 窗口本身做好；Aster 的范围是围绕终端的整套工作。差异不在快慢，在于哪些事不用再离开这个窗口。":
        "Les terminaux classiques soignent la fenêtre shell elle-même ; Aster couvre tout le travail autour du terminal. La différence n'est pas la vitesse, mais ce qui ne demande plus de quitter la fenêtre.",
      "传统终端": "Terminal classique",
      "看文件": "Voir des fichiers",
      "cat / less，或切去编辑器和 Finder": "cat / less, ou basculer vers un éditeur et le Finder",
      "File Pane 同窗预览源码、Markdown、图片、PDF、diff、hex": "Le File Pane affiche source, Markdown, images, PDF, diff et hex dans la même fenêtre",
      "跑 Agent": "Lancer des agents",
      "输出滚过就没了，哪个会话在干活全靠盯": "La sortie défile et disparaît ; savoir quelle session travaille, c'est surveiller",
      "Claude Code、Codex 会话自动命名，标签栏显示运行状态，transcript 可回看": "Sessions Claude Code et Codex nommées automatiquement, état dans la barre d'onglets, transcriptions relisibles",
      "补全": "Complétion",
      "自己攒 fzf、zsh-autosuggestions 一套插件": "Bricoler sa pile de plugins fzf + zsh-autosuggestions",
      "开箱内置 714 份命令规格 + 文件/别名候选，本机隐私学习": "714 spécifications + candidats fichiers/alias d'origine, apprentissage local privé",
      "恢复现场": "Restaurer l'état",
      "布局与会话多数关窗即失，或靠手写脚本": "Dispositions et sessions meurent le plus souvent avec la fenêtre, ou vivent dans des scripts maison",
      ".asterrecipe 一个文件导出整个工作区，启动即恢复": ".asterrecipe exporte tout dans un fichier, restauré au lancement",
      "主题": "Thèmes",
      "找配色文件、改配置、重启生效": "Chercher des fichiers de couleurs, éditer la config, redémarrer",
      "24 套内置主题实时预览，明暗分开指定，工作区即时切换": "24 thèmes en aperçu direct, clair/sombre séparés, bascule instantanée",
      "技术底子": "Fondations",
      "Electron / 跨平台框架的不在少数": "Beaucoup reposent sur Electron ou des frameworks multiplateformes",
      "纯 AppKit 原生 + Ghostty 终端内核，不上传任何使用数据": "AppKit natif pur + moteur Ghostty ; aucune donnée d'usage envoyée",
      "给终端一个完整的工作区。": "Donnez à votre terminal un espace de travail complet.",
      "macOS 14 或更高版本，下载即用；也欢迎来 GitHub 参与构建。": "macOS 14 ou plus récent, prêt dès le téléchargement ; les contributions sur GitHub sont bienvenues.",
      "原生 macOS 终端工作区。不含遥测，不上传数据。": "Espace de travail terminal natif pour macOS. Sans télémétrie, sans envoi de données.",
      "产品": "Produit",
      "下载": "Télécharger",
      "主题库": "Galerie de thèmes",
      "用户指南": "Guide utilisateur",
      "开发者文档": "Docs développeur",
      "常见问题": "FAQ",
      "项目": "Projet",
      "MIT 许可证": "Licence MIT",
      "第三方声明": "Mentions tierces",
      "↑↓ 选择": "↑↓ choisir",
      "Tab 补全": "Tab compléter",
      "Esc 关闭": "Esc fermer",
      "当前仓库分支": "branche du dépôt",
    },
  };

  /* 含内联标记的富文本节点：按选择器整体替换 innerHTML */
  var RICH = [
    {
      sel: ".hero h1",
      html: {
        zh: "不止是终端，<br>是一整个<em>工作区</em>。",
        en: "More than a terminal —<br>a whole <em>workspace</em>.",
        ja: "ターミナルを超えて、<br>まるごと<em>ワークスペース</em>。",
        de: "Mehr als ein Terminal —<br>ein ganzer <em>Arbeitsbereich</em>.",
        fr: "Plus qu'un terminal —<br>un <em>espace de travail</em> complet.",
      },
    },
    {
      sel: "#ac-desc",
      html: {
        zh: '714 份命令规格，<kbd class="key">Tab</kbd> 一下就位——不联网，不出这台机器。',
        en: '714 command specs, one <kbd class="key">Tab</kbd> away — no network, nothing leaves this machine.',
        ja: '714 のコマンド仕様が <kbd class="key">Tab</kbd> 一つで。ネット接続なし、このマシンから出ません。',
        de: '714 Befehls-Spezifikationen, ein <kbd class="key">Tab</kbd> entfernt — ohne Netz, nichts verlässt diesen Rechner.',
        fr: "714 spécifications de commandes, à un <kbd class=\"key\">Tab</kbd> près — sans réseau, rien ne quitte cette machine.",
      },
    },
  ];

  var META = {
    title: {
      zh: "Aster — 原生 macOS 终端工作区",
      en: "Aster — Native macOS terminal workspace",
      ja: "Aster — ネイティブ macOS ターミナルワークスペース",
      de: "Aster — Nativer macOS-Terminal-Arbeitsbereich",
      fr: "Aster — Espace de travail terminal natif pour macOS",
    },
    desc: {
      zh: "Aster 是完全以 AppKit 构建的原生 macOS 终端工作区：轻量标签、递归分屏、文件预览与 Agent 会话，落在纸张色画布与克制的苔绿反馈之上。",
      en: "Aster is a native macOS terminal workspace built entirely with AppKit: tabs, recursive splits, file previews and agent sessions on a paper-toned canvas.",
      ja: "Aster は AppKit だけで作られたネイティブ macOS ターミナルワークスペース。タブ、再帰分割、ファイルプレビュー、エージェントセッション。",
      de: "Aster ist ein nativer macOS-Terminal-Arbeitsbereich, komplett in AppKit gebaut: Tabs, rekursive Splits, Dateivorschau und Agent-Sitzungen.",
      fr: "Aster est un espace de travail terminal natif pour macOS, entièrement construit avec AppKit : onglets, splits récursifs, aperçu de fichiers et sessions d'agents.",
    },
  };

  var current = "zh";
  var cache = null; /* [{node, raw, zh}] */
  var keySet = new Set(Object.keys(I18N.en));

  function buildCache() {
    cache = [];
    var richEls = RICH.map(function (r) { return document.querySelector(r.sel); });
    var walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT, {
      acceptNode: function (node) {
        var p = node.parentNode;
        if (!p) return NodeFilter.FILTER_REJECT;
        var tag = p.nodeName;
        if (tag === "SCRIPT" || tag === "STYLE" || tag === "NOSCRIPT") return NodeFilter.FILTER_REJECT;
        for (var i = 0; i < richEls.length; i++) {
          if (richEls[i] && richEls[i].contains(node)) return NodeFilter.FILTER_REJECT;
        }
        return NodeFilter.FILTER_ACCEPT;
      },
    });
    var n;
    while ((n = walker.nextNode())) {
      var t = n.nodeValue.trim();
      if (t && keySet.has(t)) cache.push({ node: n, raw: n.nodeValue, zh: t });
    }
  }

  function setLang(code) {
    if (!I18N[code] && code !== "zh") code = "en";
    current = code;
    var langDef = LANGS.find(function (l) { return l.code === code; });
    document.documentElement.lang = langDef ? langDef.html : "zh-CN";

    if (!cache) buildCache();
    cache.forEach(function (item) {
      var tr = code === "zh" ? item.zh : (I18N[code][item.zh] || item.zh);
      item.node.nodeValue = item.raw.replace(item.zh, tr);
    });
    RICH.forEach(function (r) {
      var el = document.querySelector(r.sel);
      if (el) el.innerHTML = r.html[code] || r.html.zh;
    });
    document.title = META.title[code] || META.title.zh;
    var desc = document.querySelector('meta[name="description"]');
    if (desc) desc.setAttribute("content", META.desc[code] || META.desc.zh);

    var label = document.querySelector("#lang-menu .lang-label");
    if (label && langDef) label.textContent = langDef.label;
    document.querySelectorAll("#lang-menu .lang-list button").forEach(function (b) {
      b.classList.toggle("on", b.dataset.lang === code);
    });
    try { localStorage.setItem("aster-lang", code); } catch (e) { /* 私密模式等场景忽略 */ }
  }

  /* 供 site.js 的动态内容（补全提示条等）取当前语言文案 */
  window.asterT = function (zh) {
    if (current === "zh") return zh;
    return (I18N[current] && I18N[current][zh]) || zh;
  };

  /* ---------- 切换器 UI ---------- */
  var menu = document.getElementById("lang-menu");
  if (menu) {
    var GLOBE =
      '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"><circle cx="12" cy="12" r="9"></circle><path d="M3 12h18"></path><path d="M12 3c2.8 2.6 4.2 5.6 4.2 9S14.8 18.4 12 21c-2.8-2.6-4.2-5.6-4.2-9S9.2 5.6 12 3Z"></path></svg>';
    var btn = document.createElement("button");
    btn.type = "button";
    btn.className = "lang-btn";
    btn.setAttribute("aria-haspopup", "listbox");
    btn.innerHTML = GLOBE + '<span class="lang-label">中文</span><svg width="11" height="11" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M6 9l6 6 6-6"></path></svg>';
    var list = document.createElement("div");
    list.className = "lang-list";
    LANGS.forEach(function (l) {
      var item = document.createElement("button");
      item.type = "button";
      item.dataset.lang = l.code;
      item.textContent = l.label;
      item.addEventListener("click", function () {
        setLang(l.code);
        menu.classList.remove("open");
      });
      list.appendChild(item);
    });
    menu.appendChild(btn);
    menu.appendChild(list);
    btn.addEventListener("click", function (e) {
      e.stopPropagation();
      menu.classList.toggle("open");
    });
    document.addEventListener("click", function () { menu.classList.remove("open"); });
  }

  /* ---------- 初始语言：记忆 > 浏览器语言 > 中文 ---------- */
  function detect() {
    var langs = navigator.languages || [navigator.language || "zh"];
    for (var i = 0; i < langs.length; i++) {
      var l = String(langs[i]).toLowerCase();
      if (l.indexOf("zh") === 0) return "zh";
      if (l.indexOf("ja") === 0) return "ja";
      if (l.indexOf("de") === 0) return "de";
      if (l.indexOf("fr") === 0) return "fr";
      if (l.indexOf("en") === 0) return "en";
    }
    return "en";
  }

  var initial = null;
  try { initial = localStorage.getItem("aster-lang"); } catch (e) { /* ignore */ }
  if (!initial || !LANGS.some(function (l) { return l.code === initial; })) initial = detect();
  if (initial !== "zh") {
    setLang(initial);
  } else {
    setLang("zh"); /* 同步下拉选中态与 html lang */
  }
})();
