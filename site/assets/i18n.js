/* Aster 官网 —— 多语言（zh / en / ja / de / fr）
   中文是页面里的原文与词典键；切换语言时按文本节点原样替换，切回中文即还原。
   词典条目必须每行一条、键用双引号：scripts/site-i18n-keys.py 按 `"中文": "译文",` 提取键核对覆盖率。 */
(function () {
  "use strict";

  var LANGS = [
    { code: "zh", label: "中文", html: "zh-CN" },
    { code: "en", label: "English", html: "en" },
    { code: "ja", label: "日本語", html: "ja" },
    { code: "de", label: "Deutsch", html: "de" },
    { code: "fr", label: "Français", html: "fr" },
  ];

  /* ---------- 词典：中文原文 → 各语言 ----------
     文本键：页面文本节点 trim 后的整段；属性键：aria-label / alt / title 的值；
     末尾一组是 site.js 通过 window.asterT 查询的动态文案。
     被 <em> / <a> 切开的半句（如「少一点切换，」「用过 Aster？」）译文要能与相邻节点连读，
     需要的空格写在译文里。「补全」同时用于快捷键提示与对比表行名，译文须两处都通顺。 */
  var I18N = {
    en: {
      "跳到正文": "Skip to content",
      "体验一下": "Try it",
      "工作区": "Workspace",
      "功能": "Features",
      "用户评价": "Voices",
      "文档": "Docs",
      "下载 Aster": "Download Aster",
      "原生 macOS 14+ · AppKit · Ghostty 内核": "Native on macOS 14+ · AppKit · Ghostty core",
      "Aster 是开源的原生 macOS 终端工作区。终端、文件预览、AI Agent 会话与本机补全放在同一个窗口里，让思路一路向前。": "Aster is an open-source, native macOS terminal workspace. Terminals, file previews, AI agent sessions and on-device completion share one window, so your train of thought keeps moving.",
      "下载 Mac 版": "Download for Mac",
      "macOS 14+ · Apple 芯片": "macOS 14+ · Apple silicon",
      "免费 · MIT 开源": "Free · MIT licensed",
      "已签名并公证": "Signed & notarized",
      "少一点切换，": "Less switching, ",
      "多一点 flow.": "more flow.",
      "接住你的下一步": "Catches your next step",
      "交互演示": "Interactive demo",
      "本机补全 · 714 份命令规格": "On-device completion · 714 command specs",
      "选择": "Select",
      "补全": "Autocomplete",
      "Git 命令": "Git commands",
      "项目脚本": "Project scripts",
      "暂停": "Pause",
      "输入": "Type",
      "自动补全": "Autocomplete",
      "接着向前": "Keep going",
      "交互示例，不执行真实命令。也可以点击候选项试试。": "Interactive example; no real commands are run. Try clicking a suggestion, too.",
      "命令在跑，文档在旁边。每一块上下文，都有恰好的位置。": "Commands run, docs sit alongside. Every piece of context has its place.",
      "并排工作": "Side by side",
      "专注终端": "Terminal focus",
      "Aster 实际窗口截图": "Actual Aster window",
      "放大查看": "Enlarge",
      "终端与 Markdown 文档，在同一个原生窗口里。": "Terminal and Markdown docs in one native window.",
      "熟悉的 Mac 手感。": "Feels like a Mac app.",
      "原生 AppKit": "Native AppKit",
      "Ghostty 内核": "Ghostty core",
      "Sparkle 自动更新": "Sparkle auto-updates",
      "不收集使用数据": "No usage data collected",
      "顺手，藏在每个细节里。": "Ease, hidden in every detail.",
      "探索全部功能": "Explore all features",
      "少敲几下，": "Fewer keystrokes,",
      "思路不用停下来。": "no break in your train of thought.",
      "714 份 Fig 命令规格、文件与别名候选、隐私感知学习。补全全部发生在本机，不经过任何服务器。": "714 Fig command specs, file and alias candidates, privacy-aware learning. Completion happens entirely on your Mac, never through a server.",
      "试试自动补全": "Try autocomplete",
      "谁在忙，": "Who's busy?",
      "一眼就知道。": "You'll know at a glance.",
      "Claude Code、Codex 会话自动获得标题与运行状态，标签栏一眼看到谁在思考；transcript 直接在 File Pane 里回看。": "Claude Code and Codex sessions get titles and run states automatically, so the tab bar shows who's thinking; transcripts replay right in the File Pane.",
      "整理项目文档": "Tidying project docs",
      "运行中": "Running",
      "检查界面改动": "Reviewing UI changes",
      "已完成": "Done",
      "状态示意": "Illustrative status",
      "打开文件，": "Open files",
      "不打断手上的事。": "without breaking your stride.",
      "源码、Markdown、图片、PDF、diff、hex，一个 File Pane 全收；任意方向递归分屏，终端与预览混排。": "Source, Markdown, images, PDF, diff and hex all open in one File Pane; split recursively in any direction and mix terminals with previews.",
      "从这里，继续。": "Pick up from here.",
      "24 套主题，": "24 themes,",
      "选中即生效。": "applied the moment you pick.",
      "实时终端预览，无需重启；明暗外观可分开指定。": "Live terminal preview, no restart; light and dark appearances are set separately.",
      "远端机器，": "Remote machines",
      "当本机用。": "that feel local.",
      "Linux 服务器或 OrbStack 虚拟机的终端与布局跑在远端后台服务里，关掉 Aster 也不中断。SSH 登录后右侧面板切成服务器文件与监控，复用已认证连接。": "Terminals and layouts on Linux servers or OrbStack VMs run in a background service on the remote host and keep going after you quit Aster. After an SSH login, the right panel switches to server files and monitoring, reusing the authenticated connection.",
      "Linux · 常驻": "Linux · always on",
      "安静地更新，": "Quiet updates,",
      "不收集使用数据。": "no usage data collected.",
      "Sparkle 2 后台检查，更新必须同时通过 EdDSA 签名与公证校验；不收集使用数据，崩溃上报等联网功能默认关闭。": "Sparkle 2 checks in the background, and every update must pass both EdDSA signature and notarization checks. No usage data is collected, and networked features such as crash reporting are off by default.",
      "Developer ID 签名 + 公证": "Developer ID signed + notarized",
      "六种界面语言，跟随系统或手动指定": "Six interface languages, following the system or set by hand",
      ".asterrecipe 导出整个工作区，启动即恢复": ".asterrecipe exports the whole workspace, restored on launch",
      "和传统终端，差在整个工作区。": "Versus traditional terminals, the difference is the whole workspace.",
      "差异不在快慢，在于哪些事不用再离开这个窗口。": "It isn't about speed. It's about what you no longer have to leave this window for.",
      "传统终端": "Traditional terminal",
      "看文件": "View files",
      "cat / less，或切去编辑器和 Finder": "cat / less, or switch to an editor and Finder",
      "File Pane 同窗预览源码、Markdown、图片、PDF、diff、hex": "File Pane previews source, Markdown, images, PDF, diff and hex in the same window",
      "跑 Agent": "Run agents",
      "输出滚过就没了，哪个会话在干活全靠盯": "Output scrolls away; you have to keep watching to know which session is working",
      "Claude Code、Codex 会话自动命名，标签栏显示运行状态，transcript 可回看": "Claude Code and Codex sessions are named automatically, run state shows in the tab bar, transcripts can be replayed",
      "自己攒 fzf、zsh-autosuggestions 一套插件": "Assemble your own fzf and zsh-autosuggestions plugin stack",
      "开箱内置 714 份命令规格 + 文件/别名候选，本机隐私学习": "714 command specs plus file/alias candidates built in, private on-device learning",
      "恢复现场": "Restore state",
      "布局与会话多数关窗即失，或靠手写脚本": "Layouts and sessions mostly vanish with the window, or depend on hand-written scripts",
      ".asterrecipe 一个文件导出整个工作区，启动即恢复": ".asterrecipe exports the whole workspace to one file, restored on launch",
      "远程": "Remote",
      "ssh 进去只有一个 Shell，文件和监控另开工具": "ssh gives you a single shell; files and monitoring need other tools",
      "远端终端与布局常驻后台服务，右侧面板直接看服务器文件与负载": "Remote terminals and layouts live in a background service; the right panel shows server files and load directly",
      "技术底子": "Foundations",
      "Electron / 跨平台框架的不在少数": "Quite a few are built on Electron or cross-platform frameworks",
      "纯 AppKit 原生 + Ghostty 终端内核，不收集使用数据": "Pure native AppKit plus the Ghostty terminal core; no usage data collected",
      "那些让工作顺一点的改变，也值得被分享。": "The changes that make work a little smoother are worth sharing too.",
      "终端和 README 并排之后，我终于不用在几个窗口里，来回寻找上下文了。": "With the terminal and the README side by side, I finally stopped hunting for context across windows.",
      "林": "林",
      "林序": "Lin Xu",
      "最喜欢的是，它仍然像一个 Mac 应用。工具多了，终端却没有变复杂。": "What I like most is that it still feels like a Mac app. More tools, yet the terminal didn't get any more complicated.",
      "小满 Nora": "Nora",
      "用过 Aster？": "Used Aster? ",
      "到 GitHub 说说你的体验": "Tell us how it went on GitHub",
      "，我们会把真实反馈放到这里。": ", and we'll put real feedback here.",
      "还有一点，": "One more thing",
      "你可能想知道。": "you might want to know.",
      "我的 Mac 能用 Aster 吗？": "Will Aster run on my Mac?",
      "Aster 需要 macOS 14 Sonoma 或更高版本。当前发布的安装包只包含 Apple 芯片（arm64）版本，Intel 芯片的 Mac 无法运行。": "Aster requires macOS 14 Sonoma or later. Current releases ship only the Apple silicon (arm64) build, so Intel Macs can't run it.",
      "Aster 免费吗？": "Is Aster free?",
      "免费。Aster 以 MIT 许可证开源，已签名并公证的 DMG 安装包和全部源码都可以在 GitHub 上免费获取，无需注册账号。": "Yes. Aster is open source under the MIT license; the signed, notarized DMG and all of the source code are free on GitHub, with no account required.",
      "Aster 和 iTerm2、Warp 等终端有什么不同？": "How is Aster different from terminals like iTerm2 or Warp?",
      "Aster 是一个以 AppKit 构建的原生工作区：基于 Ghostty 内核的终端可以和文件浏览器、编辑器、预览以递归分屏放在同一个窗口里。它还内置 Claude Code、Codex 等 Agent 会话的标题与状态显示、714 份命令规格的本机补全，以及可导出为 .asterrecipe 并在启动时恢复的工作区。": "Aster is a native workspace built with AppKit: a terminal on the Ghostty core shares one window with file browsers, editors and previews in recursive splits. It also shows titles and status for agent sessions such as Claude Code and Codex, offers on-device completion with 714 command specs, and keeps workspaces you can export as .asterrecipe and restore at launch.",
      "Aster 支持远程服务器和 SSH 吗？": "Does Aster support remote servers and SSH?",
      "支持。你可以在“设置 ▸ 主机”保存 SSH 主机并直接打开原生 SSH 标签，口令只存在 macOS 钥匙串；也可以把 Linux 服务器等添加为远程机器，终端运行在远端的后台会话服务里，关掉 Aster 或断网后进程和布局仍然保留。": "Yes. Save SSH hosts under “Settings ▸ Host” and open native SSH tabs directly; passwords live only in the macOS Keychain. You can also add Linux servers and similar machines as remote machines: terminals run in a background session service on the remote host, so processes and layouts survive quitting Aster or losing the network.",
      "Aster 会上传我的数据吗？": "Does Aster upload my data?",
      "Aster 不收集使用数据：补全、学习和常用目录排名都只在本机进行，更新检查也不发送使用数据或系统信息。崩溃报告、用 CLI Agent 提炼项目记忆这类会联网发送内容的功能默认关闭，只有你在设置里手动开启后才会工作。": "Aster does not collect usage data. Completion, learning and frequent-directory ranking all happen on your Mac, and update checks send no usage data or system information. Features that send content over the network, such as crash reports or distilling project memory with a CLI agent, are off by default and only work after you turn them on in Settings.",
      "Aster 怎么更新？": "How does Aster update?",
      "Aster 内置 Sparkle 2，默认每天在后台检查一次官方更新源，也可以用菜单“Aster ▸ 检查更新…”手动检查；安装包必须同时通过 EdDSA 签名校验和 macOS 公证校验才会安装。0.4.1 及更早的版本没有更新组件，需要手动下载一次新版 DMG。": "Aster has Sparkle 2 built in. By default it checks the official update feed once a day in the background, and you can check manually with “Aster ▸ Check for Updates…”. A package is installed only after it passes both EdDSA signature and macOS notarization checks. Version 0.4.1 and earlier have no updater, so download the new DMG manually once.",
      "v0.6.15 · macOS 14+ · Apple 芯片 · 免费开源": "v0.6.15 · macOS 14+ · Apple silicon · Free & open source",
      "原生 macOS 终端工作区。不收集使用数据，联网功能默认关闭。": "A native macOS terminal workspace. No usage data collected; networked features are off by default.",
      "产品": "Product",
      "下载": "Download",
      "更新日志": "Changelog",
      "主题库": "Theme gallery",
      "用户指南": "User guide",
      "开发者文档": "Developer docs",
      "常见问题": "FAQ",
      "项目": "Project",
      "MIT 许可证": "MIT License",
      "第三方声明": "Third-party notices",
      "本地开发版实际采集 · 公开演示内容": "Captured from a local dev build · public demo content",
      "暂停动效": "Pause motion",
      "主导航": "Main navigation",
      "打开导航": "Open navigation",
      "移动导航": "Mobile navigation",
      "演示工作区": "Demo workspace",
      "命令自动补全演示": "Command autocomplete demo",
      "命令补全候选": "Completion suggestions",
      "演示场景": "Demo scenarios",
      "重播命令演示": "Replay command demo",
      "终端、文件、Agent、SSH 与主题可以组成你的工作区": "Terminals, files, agents, SSH and themes make up your workspace",
      "实际截图": "Actual screenshots",
      "放大真实产品截图": "Enlarge the actual product screenshot",
      "Aster 实际窗口：左侧标签栏、中间终端、右侧 Markdown 预览": "Actual Aster window: tab bar on the left, terminal in the middle, Markdown preview on the right",
      "Agent 状态示意": "Illustrative agent status",
      "主题预览": "Theme preview",
      "关闭截图": "Close screenshot",
      "完整 Aster 产品截图": "Full Aster product screenshot",
      "关闭导航": "Close navigation",
      "播放动效": "Play motion",
      "播放": "Play",
      "打包并签名 Aster.app": "Package and sign Aster.app",
      "生成并校验 DMG": "Build and verify the DMG",
      "构建原生 SSH 运行时": "Build the native SSH runtime",
      "专注终端时，侧栏与文件面板都能收起。": "When you focus on the terminal, the sidebar and file panel can both be collapsed.",
      "Aster 实际终端窗口，显示公开演示目录和配置文件": "Actual Aster terminal window showing a public demo directory and config file",
      "截图暂时无法载入，请重新选择。": "The screenshot couldn't be loaded. Please select it again.",
      "已补全为 ": "Completed to ",
      "。这是演示，没有执行命令。": ". This is a demo; no command was run.",
      "已重播": "Replayed",
    },

    ja: {
      "跳到正文": "本文へスキップ",
      "体验一下": "試してみる",
      "工作区": "ワークスペース",
      "功能": "機能",
      "用户评价": "ユーザーの声",
      "文档": "ドキュメント",
      "下载 Aster": "Aster をダウンロード",
      "原生 macOS 14+ · AppKit · Ghostty 内核": "ネイティブ macOS 14+ · AppKit · Ghostty コア",
      "Aster 是开源的原生 macOS 终端工作区。终端、文件预览、AI Agent 会话与本机补全放在同一个窗口里，让思路一路向前。": "Aster はオープンソースのネイティブ macOS ターミナルワークスペースです。ターミナル、ファイルプレビュー、AI エージェントのセッション、ローカル補完を一つのウィンドウにまとめ、考えを止めずに前へ進めます。",
      "下载 Mac 版": "Mac 版をダウンロード",
      "macOS 14+ · Apple 芯片": "macOS 14+ · Apple シリコン",
      "免费 · MIT 开源": "無料 · MIT オープンソース",
      "已签名并公证": "署名・公証済み",
      "少一点切换，": "切り替えは少なく、",
      "多一点 flow.": "もっと flow を.",
      "接住你的下一步": "次の一手を受け止める",
      "交互演示": "インタラクティブデモ",
      "本机补全 · 714 份命令规格": "ローカル補完 · 714 のコマンド仕様",
      "选择": "選択",
      "补全": "補完",
      "Git 命令": "Git コマンド",
      "项目脚本": "プロジェクトスクリプト",
      "暂停": "一時停止",
      "输入": "入力",
      "自动补全": "自動補完",
      "接着向前": "その先へ",
      "交互示例，不执行真实命令。也可以点击候选项试试。": "操作できるデモです。実際のコマンドは実行されません。候補をクリックして試すこともできます。",
      "命令在跑，文档在旁边。每一块上下文，都有恰好的位置。": "コマンドが走り、ドキュメントはすぐ隣に。どのコンテキストにも、ちょうどいい居場所があります。",
      "并排工作": "並べて作業",
      "专注终端": "ターミナルに集中",
      "Aster 实际窗口截图": "Aster の実際のウィンドウ",
      "放大查看": "拡大して見る",
      "终端与 Markdown 文档，在同一个原生窗口里。": "ターミナルと Markdown ドキュメントを、一つのネイティブウィンドウで。",
      "熟悉的 Mac 手感。": "いつもの Mac の手ざわり。",
      "原生 AppKit": "ネイティブ AppKit",
      "Ghostty 内核": "Ghostty コア",
      "Sparkle 自动更新": "Sparkle 自動アップデート",
      "不收集使用数据": "利用データを収集しない",
      "顺手，藏在每个细节里。": "使いやすさは、細部に宿る。",
      "探索全部功能": "すべての機能を見る",
      "少敲几下，": "打つのは少なく、",
      "思路不用停下来。": "考えは止めずに。",
      "714 份 Fig 命令规格、文件与别名候选、隐私感知学习。补全全部发生在本机，不经过任何服务器。": "714 の Fig コマンド仕様、ファイルとエイリアスの候補、プライバシーに配慮した学習。補完はすべてローカルで完結し、サーバーを経由しません。",
      "试试自动补全": "自動補完を試す",
      "谁在忙，": "誰が作業中か、",
      "一眼就知道。": "ひと目でわかる。",
      "Claude Code、Codex 会话自动获得标题与运行状态，标签栏一眼看到谁在思考；transcript 直接在 File Pane 里回看。": "Claude Code や Codex のセッションには自動でタイトルと実行状態が付き、どれが考え中かはタブバーでひと目でわかります。transcript は File Pane でそのまま見返せます。",
      "整理项目文档": "プロジェクト文書を整理中",
      "运行中": "実行中",
      "检查界面改动": "UI の変更を確認",
      "已完成": "完了",
      "状态示意": "状態のイメージ",
      "打开文件，": "ファイルを開いても、",
      "不打断手上的事。": "手は止まらない。",
      "源码、Markdown、图片、PDF、diff、hex，一个 File Pane 全收；任意方向递归分屏，终端与预览混排。": "ソース、Markdown、画像、PDF、diff、hex を一つの File Pane で。どの方向にも再帰的に分割でき、ターミナルとプレビューを並べられます。",
      "从这里，继续。": "ここから、続きを。",
      "24 套主题，": "24 のテーマ、",
      "选中即生效。": "選べばすぐ反映。",
      "实时终端预览，无需重启；明暗外观可分开指定。": "ターミナルのライブプレビュー付きで、再起動は不要。ライトとダークは別々に指定できます。",
      "远端机器，": "リモートマシンを、",
      "当本机用。": "手元のように。",
      "Linux 服务器或 OrbStack 虚拟机的终端与布局跑在远端后台服务里，关掉 Aster 也不中断。SSH 登录后右侧面板切成服务器文件与监控，复用已认证连接。": "Linux サーバーや OrbStack の仮想マシンのターミナルとレイアウトはリモートのバックグラウンドサービスで動き、Aster を閉じても途切れません。SSH でログインすると右側のパネルがサーバーのファイルとモニタリングに切り替わり、認証済みの接続を再利用します。",
      "Linux · 常驻": "Linux · 常駐",
      "安静地更新，": "静かにアップデート、",
      "不收集使用数据。": "利用データは収集しない。",
      "Sparkle 2 后台检查，更新必须同时通过 EdDSA 签名与公证校验；不收集使用数据，崩溃上报等联网功能默认关闭。": "Sparkle 2 がバックグラウンドで確認し、更新は EdDSA 署名と公証の両方の検証を通過する必要があります。利用データは収集せず、クラッシュレポートなどのネットワーク機能はデフォルトでオフです。",
      "Developer ID 签名 + 公证": "Developer ID 署名 + 公証",
      "六种界面语言，跟随系统或手动指定": "6 つの表示言語、システムに合わせるか手動で指定",
      ".asterrecipe 导出整个工作区，启动即恢复": ".asterrecipe でワークスペース全体を書き出し、起動時に復元",
      "和传统终端，差在整个工作区。": "従来のターミナルとの差は、ワークスペース全体。",
      "差异不在快慢，在于哪些事不用再离开这个窗口。": "違いは速さではありません。どんな作業のために、このウィンドウを離れずに済むかです。",
      "传统终端": "従来のターミナル",
      "看文件": "ファイルを見る",
      "cat / less，或切去编辑器和 Finder": "cat / less、またはエディタや Finder に切り替え",
      "File Pane 同窗预览源码、Markdown、图片、PDF、diff、hex": "File Pane が同じウィンドウでソース・Markdown・画像・PDF・diff・hex をプレビュー",
      "跑 Agent": "エージェントを動かす",
      "输出滚过就没了，哪个会话在干活全靠盯": "出力は流れて消え、どのセッションが作業中かは見張るしかない",
      "Claude Code、Codex 会话自动命名，标签栏显示运行状态，transcript 可回看": "Claude Code・Codex のセッションに自動で名前が付き、タブバーに実行状態、transcript も見返せる",
      "自己攒 fzf、zsh-autosuggestions 一套插件": "fzf や zsh-autosuggestions などのプラグインを自分で揃える",
      "开箱内置 714 份命令规格 + 文件/别名候选，本机隐私学习": "714 のコマンド仕様とファイル／エイリアス候補を標準搭載、学習もローカルで",
      "恢复现场": "作業状態の復元",
      "布局与会话多数关窗即失，或靠手写脚本": "レイアウトとセッションはウィンドウを閉じると大抵消えるか、手書きのスクリプト頼み",
      ".asterrecipe 一个文件导出整个工作区，启动即恢复": ".asterrecipe 一つでワークスペース全体を書き出し、起動時に復元",
      "远程": "リモート",
      "ssh 进去只有一个 Shell，文件和监控另开工具": "ssh で入ってもシェルが一つだけ。ファイルやモニタリングは別のツールで",
      "远端终端与布局常驻后台服务，右侧面板直接看服务器文件与负载": "リモートのターミナルとレイアウトはバックグラウンドサービスに常駐し、右側のパネルでサーバーのファイルと負荷を直接確認",
      "技术底子": "技術的な土台",
      "Electron / 跨平台框架的不在少数": "Electron やクロスプラットフォームのフレームワーク製も少なくない",
      "纯 AppKit 原生 + Ghostty 终端内核，不收集使用数据": "純粋な AppKit ネイティブ + Ghostty ターミナルコア、利用データは収集しない",
      "那些让工作顺一点的改变，也值得被分享。": "仕事を少し心地よくしてくれた変化も、分かち合う価値があります。",
      "终端和 README 并排之后，我终于不用在几个窗口里，来回寻找上下文了。": "ターミナルと README を並べてからは、いくつものウィンドウを行き来してコンテキストを探さずに済むようになりました。",
      "林": "林",
      "林序": "林序",
      "最喜欢的是，它仍然像一个 Mac 应用。工具多了，终端却没有变复杂。": "何より気に入っているのは、ちゃんと Mac アプリらしいところ。ツールが増えても、ターミナルは複雑になっていません。",
      "小满 Nora": "小満 Nora",
      "用过 Aster？": "Aster を使ってみましたか？",
      "到 GitHub 说说你的体验": "GitHub で感想を聞かせてください",
      "，我们会把真实反馈放到这里。": "。実際のフィードバックをここに掲載します。",
      "还有一点，": "始める前に、",
      "你可能想知道。": "知っておきたいこと。",
      "我的 Mac 能用 Aster 吗？": "手元の Mac で Aster を使えますか？",
      "Aster 需要 macOS 14 Sonoma 或更高版本。当前发布的安装包只包含 Apple 芯片（arm64）版本，Intel 芯片的 Mac 无法运行。": "Aster には macOS 14 Sonoma 以降が必要です。現在配布しているインストーラは Apple シリコン（arm64）版のみで、Intel プロセッサ搭載の Mac では動作しません。",
      "Aster 免费吗？": "Aster は無料ですか？",
      "免费。Aster 以 MIT 许可证开源，已签名并公证的 DMG 安装包和全部源码都可以在 GitHub 上免费获取，无需注册账号。": "無料です。Aster は MIT ライセンスのオープンソースで、署名・公証済みの DMG インストーラとすべてのソースコードを GitHub から無料で入手できます。アカウント登録は不要です。",
      "Aster 和 iTerm2、Warp 等终端有什么不同？": "Aster は iTerm2 や Warp などのターミナルと何が違いますか？",
      "Aster 是一个以 AppKit 构建的原生工作区：基于 Ghostty 内核的终端可以和文件浏览器、编辑器、预览以递归分屏放在同一个窗口里。它还内置 Claude Code、Codex 等 Agent 会话的标题与状态显示、714 份命令规格的本机补全，以及可导出为 .asterrecipe 并在启动时恢复的工作区。": "Aster は AppKit で作られたネイティブのワークスペースです。Ghostty コアのターミナルを、ファイルブラウザ、エディタ、プレビューと再帰分割で同じウィンドウに並べられます。さらに Claude Code や Codex などのエージェントセッションのタイトルと状態表示、714 のコマンド仕様によるローカル補完、.asterrecipe として書き出せて起動時に復元できるワークスペースを備えています。",
      "Aster 支持远程服务器和 SSH 吗？": "Aster はリモートサーバーや SSH に対応していますか？",
      "支持。你可以在“设置 ▸ 主机”保存 SSH 主机并直接打开原生 SSH 标签，口令只存在 macOS 钥匙串；也可以把 Linux 服务器等添加为远程机器，终端运行在远端的后台会话服务里，关掉 Aster 或断网后进程和布局仍然保留。": "対応しています。「設定 ▸ ホスト」に SSH ホストを保存すれば、ネイティブの SSH タブを直接開けます。パスワードは macOS のキーチェーンにだけ保存されます。Linux サーバーなどをリモートマシンとして追加することもでき、ターミナルはリモートのバックグラウンドセッションサービスで動くため、Aster を閉じてもネットワークが切れても、プロセスとレイアウトはそのまま残ります。",
      "Aster 会上传我的数据吗？": "Aster はデータを送信しますか？",
      "Aster 不收集使用数据：补全、学习和常用目录排名都只在本机进行，更新检查也不发送使用数据或系统信息。崩溃报告、用 CLI Agent 提炼项目记忆这类会联网发送内容的功能默认关闭，只有你在设置里手动开启后才会工作。": "Aster は利用データを収集しません。補完、学習、よく使うディレクトリのランキングはすべてローカルで行われ、アップデートの確認でも利用データやシステム情報は送信しません。クラッシュレポートや、CLI エージェントでプロジェクトメモリを要約する機能など、ネットワーク経由で内容を送る機能はデフォルトでオフで、設定で手動でオンにしたときだけ動作します。",
      "Aster 怎么更新？": "Aster はどうやってアップデートしますか？",
      "Aster 内置 Sparkle 2，默认每天在后台检查一次官方更新源，也可以用菜单“Aster ▸ 检查更新…”手动检查；安装包必须同时通过 EdDSA 签名校验和 macOS 公证校验才会安装。0.4.1 及更早的版本没有更新组件，需要手动下载一次新版 DMG。": "Aster には Sparkle 2 が組み込まれており、デフォルトで 1 日 1 回バックグラウンドで公式の配信元を確認します。メニューの「Aster ▸ アップデートを確認…」から手動でも確認できます。インストーラは EdDSA 署名と macOS の公証の両方の検証を通過したときだけインストールされます。0.4.1 以前のバージョンにはアップデート機能がないため、新しい DMG を一度だけ手動でダウンロードしてください。",
      "v0.6.15 · macOS 14+ · Apple 芯片 · 免费开源": "v0.6.15 · macOS 14+ · Apple シリコン · 無料・オープンソース",
      "原生 macOS 终端工作区。不收集使用数据，联网功能默认关闭。": "ネイティブ macOS ターミナルワークスペース。利用データは収集せず、ネットワーク機能はデフォルトでオフです。",
      "产品": "プロダクト",
      "下载": "ダウンロード",
      "更新日志": "更新履歴",
      "主题库": "テーマギャラリー",
      "用户指南": "ユーザーガイド",
      "开发者文档": "開発者ドキュメント",
      "常见问题": "よくある質問",
      "项目": "プロジェクト",
      "MIT 许可证": "MIT ライセンス",
      "第三方声明": "サードパーティ表記",
      "本地开发版实际采集 · 公开演示内容": "ローカルの開発版で撮影 · 公開用のデモ内容",
      "暂停动效": "アニメーションを停止",
      "主导航": "メインナビゲーション",
      "打开导航": "ナビゲーションを開く",
      "移动导航": "モバイルナビゲーション",
      "演示工作区": "デモのワークスペース",
      "命令自动补全演示": "コマンド自動補完のデモ",
      "命令补全候选": "コマンド補完の候補",
      "演示场景": "デモのシナリオ",
      "重播命令演示": "コマンドのデモをもう一度再生",
      "终端、文件、Agent、SSH 与主题可以组成你的工作区": "ターミナル、ファイル、エージェント、SSH、テーマでワークスペースを組み立てられます",
      "实际截图": "実際のスクリーンショット",
      "放大真实产品截图": "実際の製品スクリーンショットを拡大",
      "Aster 实际窗口：左侧标签栏、中间终端、右侧 Markdown 预览": "Aster の実際のウィンドウ：左にタブバー、中央にターミナル、右に Markdown プレビュー",
      "Agent 状态示意": "エージェント状態のイメージ",
      "主题预览": "テーマのプレビュー",
      "关闭截图": "スクリーンショットを閉じる",
      "完整 Aster 产品截图": "Aster 製品スクリーンショットの全体",
      "关闭导航": "ナビゲーションを閉じる",
      "播放动效": "アニメーションを再生",
      "播放": "再生",
      "打包并签名 Aster.app": "Aster.app をパッケージして署名",
      "生成并校验 DMG": "DMG を作成して検証",
      "构建原生 SSH 运行时": "ネイティブ SSH ランタイムをビルド",
      "专注终端时，侧栏与文件面板都能收起。": "ターミナルに集中したいときは、サイドバーもファイルパネルも畳めます。",
      "Aster 实际终端窗口，显示公开演示目录和配置文件": "Aster の実際のターミナルウィンドウ。公開用デモのディレクトリと設定ファイルを表示",
      "截图暂时无法载入，请重新选择。": "スクリーンショットを読み込めませんでした。もう一度選んでください。",
      "已补全为 ": "補完しました：",
      "。这是演示，没有执行命令。": "。デモのため、コマンドは実行していません。",
      "已重播": "もう一度再生しました",
    },

    de: {
      "跳到正文": "Zum Inhalt springen",
      "体验一下": "Ausprobieren",
      "工作区": "Arbeitsbereich",
      "功能": "Funktionen",
      "用户评价": "Stimmen",
      "文档": "Doku",
      "下载 Aster": "Aster laden",
      "原生 macOS 14+ · AppKit · Ghostty 内核": "Nativ für macOS 14+ · AppKit · Ghostty-Kern",
      "Aster 是开源的原生 macOS 终端工作区。终端、文件预览、AI Agent 会话与本机补全放在同一个窗口里，让思路一路向前。": "Aster ist ein quelloffener, nativer Terminal-Arbeitsbereich für macOS. Terminal, Dateivorschau, KI-Agent-Sitzungen und lokale Vervollständigung teilen sich ein Fenster, damit deine Gedanken in Bewegung bleiben.",
      "下载 Mac 版": "Für Mac laden",
      "macOS 14+ · Apple 芯片": "macOS 14+ · Apple Silicon",
      "免费 · MIT 开源": "Kostenlos · MIT-Lizenz",
      "已签名并公证": "Signiert & notarisiert",
      "少一点切换，": "Weniger wechseln, ",
      "多一点 flow.": "mehr Flow.",
      "接住你的下一步": "Fängt deinen nächsten Schritt auf",
      "交互演示": "Interaktive Demo",
      "本机补全 · 714 份命令规格": "Lokale Vervollständigung · 714 Befehls-Specs",
      "选择": "Wählen",
      "补全": "Vervollständigen",
      "Git 命令": "Git-Befehle",
      "项目脚本": "Projektskripte",
      "暂停": "Pause",
      "输入": "Tippen",
      "自动补全": "Autovervollständigung",
      "接着向前": "Weitermachen",
      "交互示例，不执行真实命令。也可以点击候选项试试。": "Interaktives Beispiel, es werden keine echten Befehle ausgeführt. Du kannst auch einen Vorschlag anklicken.",
      "命令在跑，文档在旁边。每一块上下文，都有恰好的位置。": "Befehle laufen, die Doku liegt daneben. Jeder Kontext hat genau seinen Platz.",
      "并排工作": "Nebeneinander",
      "专注终端": "Terminal im Fokus",
      "Aster 实际窗口截图": "Echtes Aster-Fenster",
      "放大查看": "Vergrößern",
      "终端与 Markdown 文档，在同一个原生窗口里。": "Terminal und Markdown-Doku im selben nativen Fenster.",
      "熟悉的 Mac 手感。": "Fühlt sich an wie ein Mac.",
      "原生 AppKit": "Natives AppKit",
      "Ghostty 内核": "Ghostty-Kern",
      "Sparkle 自动更新": "Auto-Updates per Sparkle",
      "不收集使用数据": "Keine Nutzungsdaten",
      "顺手，藏在每个细节里。": "Komfort steckt in jedem Detail.",
      "探索全部功能": "Alle Funktionen ansehen",
      "少敲几下，": "Weniger tippen,",
      "思路不用停下来。": "ohne den Faden zu verlieren.",
      "714 份 Fig 命令规格、文件与别名候选、隐私感知学习。补全全部发生在本机，不经过任何服务器。": "714 Fig-Befehlsspezifikationen, Datei- und Alias-Kandidaten, datenschutzbewusstes Lernen. Die Vervollständigung läuft komplett lokal und nie über einen Server.",
      "试试自动补全": "Autovervollständigung testen",
      "谁在忙，": "Wer gerade arbeitet,",
      "一眼就知道。": "siehst du sofort.",
      "Claude Code、Codex 会话自动获得标题与运行状态，标签栏一眼看到谁在思考；transcript 直接在 File Pane 里回看。": "Claude-Code- und Codex-Sitzungen erhalten automatisch Titel und Laufstatus, die Tab-Leiste zeigt auf einen Blick, wer gerade denkt; Transcripts liest du direkt im File Pane nach.",
      "整理项目文档": "Räumt die Projektdoku auf",
      "运行中": "Läuft",
      "检查界面改动": "Prüft UI-Änderungen",
      "已完成": "Fertig",
      "状态示意": "Beispielhafter Status",
      "打开文件，": "Dateien öffnen,",
      "不打断手上的事。": "ohne aus dem Takt zu kommen.",
      "源码、Markdown、图片、PDF、diff、hex，一个 File Pane 全收；任意方向递归分屏，终端与预览混排。": "Quellcode, Markdown, Bilder, PDF, Diff und Hex in einem File Pane; rekursive Splits in jede Richtung, Terminal und Vorschau gemischt.",
      "从这里，继续。": "Von hier aus weiter.",
      "24 套主题，": "24 Themes,",
      "选中即生效。": "sofort aktiv.",
      "实时终端预览，无需重启；明暗外观可分开指定。": "Live-Vorschau im Terminal, kein Neustart nötig; Hell und Dunkel lassen sich getrennt festlegen.",
      "远端机器，": "Entfernte Rechner,",
      "当本机用。": "wie lokal nutzen.",
      "Linux 服务器或 OrbStack 虚拟机的终端与布局跑在远端后台服务里，关掉 Aster 也不中断。SSH 登录后右侧面板切成服务器文件与监控，复用已认证连接。": "Terminals und Layouts auf Linux-Servern oder OrbStack-VMs laufen in einem Hintergrunddienst auf dem entfernten Rechner und laufen weiter, auch wenn du Aster schließt. Nach dem SSH-Login zeigt das rechte Panel Serverdateien und Monitoring und nutzt die bereits authentifizierte Verbindung.",
      "Linux · 常驻": "Linux · dauerhaft aktiv",
      "安静地更新，": "Leise Updates,",
      "不收集使用数据。": "keine Nutzungsdaten.",
      "Sparkle 2 后台检查，更新必须同时通过 EdDSA 签名与公证校验；不收集使用数据，崩溃上报等联网功能默认关闭。": "Sparkle 2 prüft im Hintergrund, und jedes Update muss die EdDSA-Signatur- und die Notarisierungsprüfung bestehen. Es werden keine Nutzungsdaten erhoben; Netzwerkfunktionen wie Absturzberichte sind standardmäßig aus.",
      "Developer ID 签名 + 公证": "Developer-ID-signiert + notarisiert",
      "六种界面语言，跟随系统或手动指定": "Sechs Oberflächensprachen, nach System oder manuell gewählt",
      ".asterrecipe 导出整个工作区，启动即恢复": ".asterrecipe exportiert den ganzen Arbeitsbereich, beim Start wiederhergestellt",
      "和传统终端，差在整个工作区。": "Gegenüber klassischen Terminals: Der Unterschied ist der ganze Arbeitsbereich.",
      "差异不在快慢，在于哪些事不用再离开这个窗口。": "Es geht nicht um Tempo, sondern darum, wofür du dieses Fenster nicht mehr verlassen musst.",
      "传统终端": "Klassisches Terminal",
      "看文件": "Dateien ansehen",
      "cat / less，或切去编辑器和 Finder": "cat / less, oder Wechsel zu Editor und Finder",
      "File Pane 同窗预览源码、Markdown、图片、PDF、diff、hex": "File Pane zeigt Quellcode, Markdown, Bilder, PDF, Diff und Hex im selben Fenster",
      "跑 Agent": "Agents ausführen",
      "输出滚过就没了，哪个会话在干活全靠盯": "Ausgabe scrollt davon; welche Sitzung arbeitet, sieht man nur durch ständiges Hinsehen",
      "Claude Code、Codex 会话自动命名，标签栏显示运行状态，transcript 可回看": "Claude-Code- und Codex-Sitzungen automatisch benannt, Laufstatus in der Tab-Leiste, Transcripts nachlesbar",
      "自己攒 fzf、zsh-autosuggestions 一套插件": "fzf, zsh-autosuggestions und weitere Plugins selbst zusammenstellen",
      "开箱内置 714 份命令规格 + 文件/别名候选，本机隐私学习": "714 Befehls-Specs plus Datei-/Alias-Kandidaten ab Werk, privates lokales Lernen",
      "恢复现场": "Zustand wiederherstellen",
      "布局与会话多数关窗即失，或靠手写脚本": "Layouts und Sitzungen verschwinden meist mit dem Fenster oder hängen an selbst geschriebenen Skripten",
      ".asterrecipe 一个文件导出整个工作区，启动即恢复": ".asterrecipe exportiert den ganzen Arbeitsbereich in eine Datei, beim Start wiederhergestellt",
      "远程": "Remote",
      "ssh 进去只有一个 Shell，文件和监控另开工具": "Per ssh gibt es nur eine Shell; Dateien und Monitoring brauchen eigene Tools",
      "远端终端与布局常驻后台服务，右侧面板直接看服务器文件与负载": "Entfernte Terminals und Layouts bleiben im Hintergrunddienst aktiv; das rechte Panel zeigt Serverdateien und Last direkt",
      "技术底子": "Fundament",
      "Electron / 跨平台框架的不在少数": "Nicht wenige basieren auf Electron oder Cross-Platform-Frameworks",
      "纯 AppKit 原生 + Ghostty 终端内核，不收集使用数据": "Pures natives AppKit plus Ghostty-Terminalkern, keine Nutzungsdaten",
      "那些让工作顺一点的改变，也值得被分享。": "Was die Arbeit ein wenig leichter macht, ist es wert, geteilt zu werden.",
      "终端和 README 并排之后，我终于不用在几个窗口里，来回寻找上下文了。": "Seit Terminal und README nebeneinander liegen, suche ich den Kontext nicht mehr über mehrere Fenster zusammen.",
      "林": "林",
      "林序": "Lin Xu",
      "最喜欢的是，它仍然像一个 Mac 应用。工具多了，终端却没有变复杂。": "Am liebsten mag ich, dass es sich immer noch wie eine Mac-App anfühlt. Mehr Werkzeuge, und trotzdem ist das Terminal nicht komplizierter geworden.",
      "小满 Nora": "Nora",
      "用过 Aster？": "Schon mit Aster gearbeitet? ",
      "到 GitHub 说说你的体验": "Erzähl uns auf GitHub davon",
      "，我们会把真实反馈放到这里。": ", echtes Feedback zeigen wir dann hier.",
      "还有一点，": "Bevor du loslegst,",
      "你可能想知道。": "ein paar Antworten.",
      "我的 Mac 能用 Aster 吗？": "Läuft Aster auf meinem Mac?",
      "Aster 需要 macOS 14 Sonoma 或更高版本。当前发布的安装包只包含 Apple 芯片（arm64）版本，Intel 芯片的 Mac 无法运行。": "Aster benötigt macOS 14 Sonoma oder neuer. Die aktuellen Installationspakete enthalten nur die Version für Apple Silicon (arm64); Macs mit Intel-Prozessor können Aster nicht ausführen.",
      "Aster 免费吗？": "Ist Aster kostenlos?",
      "免费。Aster 以 MIT 许可证开源，已签名并公证的 DMG 安装包和全部源码都可以在 GitHub 上免费获取，无需注册账号。": "Ja. Aster ist quelloffen unter der MIT-Lizenz; das signierte und notarisierte DMG sowie der gesamte Quellcode sind kostenlos auf GitHub erhältlich, ganz ohne Konto.",
      "Aster 和 iTerm2、Warp 等终端有什么不同？": "Was unterscheidet Aster von Terminals wie iTerm2 oder Warp?",
      "Aster 是一个以 AppKit 构建的原生工作区：基于 Ghostty 内核的终端可以和文件浏览器、编辑器、预览以递归分屏放在同一个窗口里。它还内置 Claude Code、Codex 等 Agent 会话的标题与状态显示、714 份命令规格的本机补全，以及可导出为 .asterrecipe 并在启动时恢复的工作区。": "Aster ist ein nativer, mit AppKit gebauter Arbeitsbereich: Das Terminal mit Ghostty-Kern teilt sich per rekursiver Splits ein Fenster mit Dateibrowsern, Editoren und Vorschau. Dazu kommen Titel und Status für Agent-Sitzungen wie Claude Code und Codex, lokale Vervollständigung mit 714 Befehls-Specs und Arbeitsbereiche, die sich als .asterrecipe exportieren und beim Start wiederherstellen lassen.",
      "Aster 支持远程服务器和 SSH 吗？": "Unterstützt Aster Remote-Server und SSH?",
      "支持。你可以在“设置 ▸ 主机”保存 SSH 主机并直接打开原生 SSH 标签，口令只存在 macOS 钥匙串；也可以把 Linux 服务器等添加为远程机器，终端运行在远端的后台会话服务里，关掉 Aster 或断网后进程和布局仍然保留。": "Ja. Unter „Einstellungen ▸ Host“ speicherst du SSH-Hosts und öffnest direkt native SSH-Tabs; Passwörter liegen nur im macOS-Schlüsselbund. Außerdem kannst du Linux-Server und Ähnliches als entfernte Rechner hinzufügen: Die Terminals laufen dort in einem Hintergrund-Sitzungsdienst, sodass Prozesse und Layouts erhalten bleiben, auch wenn du Aster schließt oder die Verbindung abreißt.",
      "Aster 会上传我的数据吗？": "Lädt Aster meine Daten hoch?",
      "Aster 不收集使用数据：补全、学习和常用目录排名都只在本机进行，更新检查也不发送使用数据或系统信息。崩溃报告、用 CLI Agent 提炼项目记忆这类会联网发送内容的功能默认关闭，只有你在设置里手动开启后才会工作。": "Aster erhebt keine Nutzungsdaten: Vervollständigung, Lernen und das Ranking häufig genutzter Verzeichnisse laufen nur lokal, und auch die Update-Prüfung sendet weder Nutzungsdaten noch Systeminformationen. Funktionen, die Inhalte übers Netz senden, etwa Absturzberichte oder das Verdichten des Projektgedächtnisses mit einem CLI-Agent, sind standardmäßig aus und arbeiten erst, wenn du sie in den Einstellungen einschaltest.",
      "Aster 怎么更新？": "Wie aktualisiert sich Aster?",
      "Aster 内置 Sparkle 2，默认每天在后台检查一次官方更新源，也可以用菜单“Aster ▸ 检查更新…”手动检查；安装包必须同时通过 EdDSA 签名校验和 macOS 公证校验才会安装。0.4.1 及更早的版本没有更新组件，需要手动下载一次新版 DMG。": "Aster bringt Sparkle 2 mit und prüft standardmäßig einmal täglich im Hintergrund die offizielle Update-Quelle; manuell geht es über „Aster ▸ Nach Updates suchen…“. Installiert wird ein Paket nur, wenn es sowohl die EdDSA-Signaturprüfung als auch die macOS-Notarisierung besteht. Versionen bis einschließlich 0.4.1 haben keine Update-Komponente; dort einmal das neue DMG manuell laden.",
      "v0.6.15 · macOS 14+ · Apple 芯片 · 免费开源": "v0.6.15 · macOS 14+ · Apple Silicon · kostenlos & quelloffen",
      "原生 macOS 终端工作区。不收集使用数据，联网功能默认关闭。": "Nativer Terminal-Arbeitsbereich für macOS. Keine Nutzungsdaten, Netzwerkfunktionen standardmäßig aus.",
      "产品": "Produkt",
      "下载": "Download",
      "更新日志": "Changelog",
      "主题库": "Theme-Galerie",
      "用户指南": "Benutzerhandbuch",
      "开发者文档": "Entwickler-Doku",
      "常见问题": "FAQ",
      "项目": "Projekt",
      "MIT 许可证": "MIT-Lizenz",
      "第三方声明": "Hinweise zu Drittanbietern",
      "本地开发版实际采集 · 公开演示内容": "Aufgenommen mit einem lokalen Dev-Build · öffentliche Demo-Inhalte",
      "暂停动效": "Animationen pausieren",
      "主导航": "Hauptnavigation",
      "打开导航": "Navigation öffnen",
      "移动导航": "Mobile Navigation",
      "演示工作区": "Demo-Arbeitsbereich",
      "命令自动补全演示": "Demo der Befehls-Autovervollständigung",
      "命令补全候选": "Vervollständigungsvorschläge",
      "演示场景": "Demo-Szenarien",
      "重播命令演示": "Befehlsdemo erneut abspielen",
      "终端、文件、Agent、SSH 与主题可以组成你的工作区": "Terminal, Dateien, Agents, SSH und Themes bilden deinen Arbeitsbereich",
      "实际截图": "Echte Screenshots",
      "放大真实产品截图": "Echten Produkt-Screenshot vergrößern",
      "Aster 实际窗口：左侧标签栏、中间终端、右侧 Markdown 预览": "Echtes Aster-Fenster: links die Tab-Leiste, in der Mitte das Terminal, rechts die Markdown-Vorschau",
      "Agent 状态示意": "Beispielhafter Agent-Status",
      "主题预览": "Theme-Vorschau",
      "关闭截图": "Screenshot schließen",
      "完整 Aster 产品截图": "Vollständiger Aster-Produkt-Screenshot",
      "关闭导航": "Navigation schließen",
      "播放动效": "Animationen abspielen",
      "播放": "Abspielen",
      "打包并签名 Aster.app": "Aster.app paketieren und signieren",
      "生成并校验 DMG": "DMG erstellen und prüfen",
      "构建原生 SSH 运行时": "Native SSH-Laufzeit bauen",
      "专注终端时，侧栏与文件面板都能收起。": "Im Terminal-Fokus lassen sich Seitenleiste und Dateipanel einklappen.",
      "Aster 实际终端窗口，显示公开演示目录和配置文件": "Echtes Aster-Terminalfenster mit einem öffentlichen Demo-Verzeichnis und einer Konfigurationsdatei",
      "截图暂时无法载入，请重新选择。": "Der Screenshot konnte gerade nicht geladen werden. Bitte erneut auswählen.",
      "已补全为 ": "Vervollständigt zu ",
      "。这是演示，没有执行命令。": ". Das ist eine Demo, es wurde kein Befehl ausgeführt.",
      "已重播": "Erneut abgespielt",
    },

    fr: {
      "跳到正文": "Aller au contenu",
      "体验一下": "Essayer",
      "工作区": "Espace de travail",
      "功能": "Fonctionnalités",
      "用户评价": "Témoignages",
      "文档": "Docs",
      "下载 Aster": "Télécharger Aster",
      "原生 macOS 14+ · AppKit · Ghostty 内核": "Natif macOS 14+ · AppKit · moteur Ghostty",
      "Aster 是开源的原生 macOS 终端工作区。终端、文件预览、AI Agent 会话与本机补全放在同一个窗口里，让思路一路向前。": "Aster est un espace de travail terminal natif et open source pour macOS. Terminal, aperçu de fichiers, sessions d'agents IA et complétion locale partagent une seule fenêtre, pour que vos idées continuent d'avancer.",
      "下载 Mac 版": "Télécharger pour Mac",
      "macOS 14+ · Apple 芯片": "macOS 14+ · puce Apple",
      "免费 · MIT 开源": "Gratuit · open source MIT",
      "已签名并公证": "Signé et notarié",
      "少一点切换，": "Moins d'allers-retours, ",
      "多一点 flow.": "plus de flow.",
      "接住你的下一步": "Prêt pour votre prochaine étape",
      "交互演示": "Démo interactive",
      "本机补全 · 714 份命令规格": "Complétion locale · 714 spécifications de commandes",
      "选择": "Choisir",
      "补全": "Compléter",
      "Git 命令": "Commandes Git",
      "项目脚本": "Scripts du projet",
      "暂停": "Pause",
      "输入": "Saisir",
      "自动补全": "Autocomplétion",
      "接着向前": "Continuer",
      "交互示例，不执行真实命令。也可以点击候选项试试。": "Exemple interactif : aucune vraie commande n'est exécutée. Vous pouvez aussi cliquer sur une suggestion.",
      "命令在跑，文档在旁边。每一块上下文，都有恰好的位置。": "Les commandes tournent, la doc reste à côté. Chaque élément de contexte trouve sa juste place.",
      "并排工作": "Côte à côte",
      "专注终端": "Terminal seul",
      "Aster 实际窗口截图": "Fenêtre Aster réelle",
      "放大查看": "Agrandir",
      "终端与 Markdown 文档，在同一个原生窗口里。": "Le terminal et la doc Markdown dans la même fenêtre native.",
      "熟悉的 Mac 手感。": "Le toucher Mac que vous connaissez.",
      "原生 AppKit": "AppKit natif",
      "Ghostty 内核": "Moteur Ghostty",
      "Sparkle 自动更新": "Mises à jour Sparkle",
      "不收集使用数据": "Aucune donnée d'usage collectée",
      "顺手，藏在每个细节里。": "Le confort se cache dans chaque détail.",
      "探索全部功能": "Voir toutes les fonctionnalités",
      "少敲几下，": "Moins de frappe,",
      "思路不用停下来。": "sans perdre le fil.",
      "714 份 Fig 命令规格、文件与别名候选、隐私感知学习。补全全部发生在本机，不经过任何服务器。": "714 spécifications de commandes Fig, candidats fichiers et alias, apprentissage respectueux de la vie privée. La complétion se fait entièrement en local, sans passer par un serveur.",
      "试试自动补全": "Essayer l'autocomplétion",
      "谁在忙，": "Qui travaille,",
      "一眼就知道。": "vous le voyez d'un coup d'œil.",
      "Claude Code、Codex 会话自动获得标题与运行状态，标签栏一眼看到谁在思考；transcript 直接在 File Pane 里回看。": "Les sessions Claude Code et Codex reçoivent automatiquement un titre et un état d'exécution : la barre d'onglets montre qui réfléchit, et les transcripts se relisent directement dans le File Pane.",
      "整理项目文档": "Range la doc du projet",
      "运行中": "En cours",
      "检查界面改动": "Vérifie les changements d'UI",
      "已完成": "Terminé",
      "状态示意": "État illustratif",
      "打开文件，": "Ouvrir un fichier,",
      "不打断手上的事。": "sans lâcher ce que vous faites.",
      "源码、Markdown、图片、PDF、diff、hex，一个 File Pane 全收；任意方向递归分屏，终端与预览混排。": "Source, Markdown, images, PDF, diff et hex : tout s'ouvre dans un seul File Pane. Splits récursifs dans tous les sens, terminaux et aperçus mêlés.",
      "从这里，继续。": "On reprend d'ici.",
      "24 套主题，": "24 thèmes,",
      "选中即生效。": "appliqués dès la sélection.",
      "实时终端预览，无需重启；明暗外观可分开指定。": "Aperçu en direct dans le terminal, sans redémarrage ; clair et sombre se règlent séparément.",
      "远端机器，": "Des machines distantes",
      "当本机用。": "comme si elles étaient là.",
      "Linux 服务器或 OrbStack 虚拟机的终端与布局跑在远端后台服务里，关掉 Aster 也不中断。SSH 登录后右侧面板切成服务器文件与监控，复用已认证连接。": "Les terminaux et dispositions des serveurs Linux ou des VM OrbStack tournent dans un service d'arrière-plan sur la machine distante et continuent même si vous quittez Aster. Après une connexion SSH, le panneau de droite affiche les fichiers et la supervision du serveur en réutilisant la connexion déjà authentifiée.",
      "Linux · 常驻": "Linux · toujours actif",
      "安静地更新，": "Des mises à jour discrètes,",
      "不收集使用数据。": "aucune donnée d'usage collectée.",
      "Sparkle 2 后台检查，更新必须同时通过 EdDSA 签名与公证校验；不收集使用数据，崩溃上报等联网功能默认关闭。": "Sparkle 2 vérifie en arrière-plan, et chaque mise à jour doit passer à la fois la signature EdDSA et la notarisation. Aucune donnée d'usage n'est collectée, et les fonctions réseau comme les rapports de plantage sont désactivées par défaut.",
      "Developer ID 签名 + 公证": "Signature Developer ID + notarisation",
      "六种界面语言，跟随系统或手动指定": "Six langues d'interface, selon le système ou au choix",
      ".asterrecipe 导出整个工作区，启动即恢复": ".asterrecipe exporte tout l'espace de travail, restauré au lancement",
      "和传统终端，差在整个工作区。": "Face aux terminaux classiques, la différence, c'est tout l'espace de travail.",
      "差异不在快慢，在于哪些事不用再离开这个窗口。": "La différence n'est pas la vitesse, mais tout ce pour quoi vous n'avez plus à quitter cette fenêtre.",
      "传统终端": "Terminal classique",
      "看文件": "Voir des fichiers",
      "cat / less，或切去编辑器和 Finder": "cat / less, ou basculer vers un éditeur et le Finder",
      "File Pane 同窗预览源码、Markdown、图片、PDF、diff、hex": "Le File Pane affiche source, Markdown, images, PDF, diff et hex dans la même fenêtre",
      "跑 Agent": "Lancer des agents",
      "输出滚过就没了，哪个会话在干活全靠盯": "La sortie défile et disparaît ; savoir quelle session travaille oblige à surveiller",
      "Claude Code、Codex 会话自动命名，标签栏显示运行状态，transcript 可回看": "Sessions Claude Code et Codex nommées automatiquement, état dans la barre d'onglets, transcripts consultables",
      "自己攒 fzf、zsh-autosuggestions 一套插件": "Assembler soi-même fzf, zsh-autosuggestions et d'autres plugins",
      "开箱内置 714 份命令规格 + 文件/别名候选，本机隐私学习": "714 spécifications de commandes et candidats fichiers/alias intégrés, apprentissage local et privé",
      "恢复现场": "Restaurer l'état",
      "布局与会话多数关窗即失，或靠手写脚本": "Dispositions et sessions disparaissent souvent avec la fenêtre, ou reposent sur des scripts maison",
      ".asterrecipe 一个文件导出整个工作区，启动即恢复": ".asterrecipe exporte tout l'espace de travail dans un fichier, restauré au lancement",
      "远程": "À distance",
      "ssh 进去只有一个 Shell，文件和监控另开工具": "ssh ne donne qu'un shell ; fichiers et supervision demandent d'autres outils",
      "远端终端与布局常驻后台服务，右侧面板直接看服务器文件与负载": "Terminaux et dispositions distants restent actifs dans un service d'arrière-plan ; le panneau de droite montre directement fichiers et charge du serveur",
      "技术底子": "Fondations",
      "Electron / 跨平台框架的不在少数": "Beaucoup reposent sur Electron ou des frameworks multiplateformes",
      "纯 AppKit 原生 + Ghostty 终端内核，不收集使用数据": "AppKit natif pur + moteur de terminal Ghostty, aucune donnée d'usage collectée",
      "那些让工作顺一点的改变，也值得被分享。": "Ce qui rend le travail un peu plus fluide mérite aussi d'être partagé.",
      "终端和 README 并排之后，我终于不用在几个窗口里，来回寻找上下文了。": "Depuis que le terminal et le README sont côte à côte, je ne cherche plus le contexte d'une fenêtre à l'autre.",
      "林": "林",
      "林序": "Lin Xu",
      "最喜欢的是，它仍然像一个 Mac 应用。工具多了，终端却没有变复杂。": "Ce que je préfère, c'est que ça reste une vraie app Mac. Plus d'outils, et pourtant le terminal n'est pas devenu plus compliqué.",
      "小满 Nora": "Nora",
      "用过 Aster？": "Vous utilisez Aster ? ",
      "到 GitHub 说说你的体验": "Racontez-nous votre expérience sur GitHub",
      "，我们会把真实反馈放到这里。": " : nous publierons ici de vrais retours.",
      "还有一点，": "Avant de commencer,",
      "你可能想知道。": "quelques réponses.",
      "我的 Mac 能用 Aster 吗？": "Aster fonctionne-t-il sur mon Mac ?",
      "Aster 需要 macOS 14 Sonoma 或更高版本。当前发布的安装包只包含 Apple 芯片（arm64）版本，Intel 芯片的 Mac 无法运行。": "Aster nécessite macOS 14 Sonoma ou plus récent. Les paquets actuellement publiés ne contiennent que la version pour puce Apple (arm64) : les Mac à processeur Intel ne peuvent pas l'exécuter.",
      "Aster 免费吗？": "Aster est-il gratuit ?",
      "免费。Aster 以 MIT 许可证开源，已签名并公证的 DMG 安装包和全部源码都可以在 GitHub 上免费获取，无需注册账号。": "Oui. Aster est open source sous licence MIT ; le DMG signé et notarié ainsi que tout le code source sont disponibles gratuitement sur GitHub, sans création de compte.",
      "Aster 和 iTerm2、Warp 等终端有什么不同？": "En quoi Aster diffère-t-il de terminaux comme iTerm2 ou Warp ?",
      "Aster 是一个以 AppKit 构建的原生工作区：基于 Ghostty 内核的终端可以和文件浏览器、编辑器、预览以递归分屏放在同一个窗口里。它还内置 Claude Code、Codex 等 Agent 会话的标题与状态显示、714 份命令规格的本机补全，以及可导出为 .asterrecipe 并在启动时恢复的工作区。": "Aster est un espace de travail natif construit avec AppKit : le terminal, propulsé par le moteur Ghostty, partage la même fenêtre que navigateurs de fichiers, éditeurs et aperçus, organisés en splits récursifs. Il affiche aussi le titre et l'état des sessions d'agents comme Claude Code et Codex, propose une complétion locale avec 714 spécifications de commandes, et des espaces de travail exportables en .asterrecipe et restaurés au lancement.",
      "Aster 支持远程服务器和 SSH 吗？": "Aster prend-il en charge les serveurs distants et SSH ?",
      "支持。你可以在“设置 ▸ 主机”保存 SSH 主机并直接打开原生 SSH 标签，口令只存在 macOS 钥匙串；也可以把 Linux 服务器等添加为远程机器，终端运行在远端的后台会话服务里，关掉 Aster 或断网后进程和布局仍然保留。": "Oui. Vous pouvez enregistrer des hôtes SSH dans « Réglages ▸ Hôte » et ouvrir directement des onglets SSH natifs ; les mots de passe ne sont stockés que dans le trousseau macOS. Vous pouvez aussi ajouter des serveurs Linux comme machines distantes : les terminaux tournent dans un service de sessions en arrière-plan sur la machine distante, si bien que processus et dispositions survivent à la fermeture d'Aster ou à une coupure réseau.",
      "Aster 会上传我的数据吗？": "Aster envoie-t-il mes données ?",
      "Aster 不收集使用数据：补全、学习和常用目录排名都只在本机进行，更新检查也不发送使用数据或系统信息。崩溃报告、用 CLI Agent 提炼项目记忆这类会联网发送内容的功能默认关闭，只有你在设置里手动开启后才会工作。": "Aster ne collecte aucune donnée d'usage : la complétion, l'apprentissage et le classement des dossiers fréquents se font uniquement en local, et la vérification des mises à jour n'envoie ni données d'usage ni informations système. Les fonctions qui envoient du contenu sur le réseau, comme les rapports de plantage ou la synthèse de la mémoire de projet par un agent CLI, sont désactivées par défaut et ne fonctionnent qu'une fois activées manuellement dans les réglages.",
      "Aster 怎么更新？": "Comment Aster se met-il à jour ?",
      "Aster 内置 Sparkle 2，默认每天在后台检查一次官方更新源，也可以用菜单“Aster ▸ 检查更新…”手动检查；安装包必须同时通过 EdDSA 签名校验和 macOS 公证校验才会安装。0.4.1 及更早的版本没有更新组件，需要手动下载一次新版 DMG。": "Aster intègre Sparkle 2 : par défaut, il vérifie la source de mises à jour officielle une fois par jour en arrière-plan, et vous pouvez aussi lancer la vérification via « Aster ▸ Rechercher des mises à jour… ». Un paquet n'est installé qu'après avoir passé à la fois la vérification de signature EdDSA et la notarisation macOS. Les versions 0.4.1 et antérieures n'ont pas de module de mise à jour : téléchargez une fois le nouveau DMG manuellement.",
      "v0.6.15 · macOS 14+ · Apple 芯片 · 免费开源": "v0.6.15 · macOS 14+ · puce Apple · gratuit et open source",
      "原生 macOS 终端工作区。不收集使用数据，联网功能默认关闭。": "Espace de travail terminal natif pour macOS. Aucune donnée d'usage collectée, fonctions réseau désactivées par défaut.",
      "产品": "Produit",
      "下载": "Télécharger",
      "更新日志": "Notes de version",
      "主题库": "Galerie de thèmes",
      "用户指南": "Guide utilisateur",
      "开发者文档": "Docs développeur",
      "常见问题": "FAQ",
      "项目": "Projet",
      "MIT 许可证": "Licence MIT",
      "第三方声明": "Mentions tierces",
      "本地开发版实际采集 · 公开演示内容": "Capturé sur une build de développement locale · contenu de démo public",
      "暂停动效": "Mettre les animations en pause",
      "主导航": "Navigation principale",
      "打开导航": "Ouvrir la navigation",
      "移动导航": "Navigation mobile",
      "演示工作区": "Espace de travail de démo",
      "命令自动补全演示": "Démo d'autocomplétion de commandes",
      "命令补全候选": "Suggestions de complétion",
      "演示场景": "Scénarios de démo",
      "重播命令演示": "Rejouer la démo de commande",
      "终端、文件、Agent、SSH 与主题可以组成你的工作区": "Terminaux, fichiers, agents, SSH et thèmes composent votre espace de travail",
      "实际截图": "Captures réelles",
      "放大真实产品截图": "Agrandir la capture réelle du produit",
      "Aster 实际窗口：左侧标签栏、中间终端、右侧 Markdown 预览": "Fenêtre Aster réelle : barre d'onglets à gauche, terminal au centre, aperçu Markdown à droite",
      "Agent 状态示意": "État d'agent illustratif",
      "主题预览": "Aperçu du thème",
      "关闭截图": "Fermer la capture",
      "完整 Aster 产品截图": "Capture complète du produit Aster",
      "关闭导航": "Fermer la navigation",
      "播放动效": "Reprendre les animations",
      "播放": "Lecture",
      "打包并签名 Aster.app": "Empaqueter et signer Aster.app",
      "生成并校验 DMG": "Générer et vérifier le DMG",
      "构建原生 SSH 运行时": "Compiler le runtime SSH natif",
      "专注终端时，侧栏与文件面板都能收起。": "En mode terminal seul, la barre latérale et le panneau de fichiers se replient.",
      "Aster 实际终端窗口，显示公开演示目录和配置文件": "Fenêtre de terminal Aster réelle, avec un dossier de démo public et un fichier de configuration",
      "截图暂时无法载入，请重新选择。": "Impossible de charger la capture pour l'instant. Veuillez la sélectionner à nouveau.",
      "已补全为 ": "Complété en ",
      "。这是演示，没有执行命令。": ". Ceci est une démo : aucune commande n'a été exécutée.",
      "已重播": "Rejoué",
    },
  };

  /* ---------- 含内联标记的标题：按选择器整体替换 innerHTML ----------
     中文版不写在这里：首次切换前从页面原样缓存，避免与 HTML 两处维护。 */
  var HERO_UNDERLINE = '<svg class="hero-underline" viewBox="0 0 300 18" aria-hidden="true"><path d="M3 11Q125-4 293 6"/><path d="M32 17Q174 5 263 13"/></svg>';
  var TYPE_CARET = '<span class="type-caret" aria-hidden="true">_</span>';
  var CLOSING_CARET = '<b aria-hidden="true">_</b>';

  /* 拼首屏标题：保留下划线 SVG 与打字光标结构，只换文字；after 是重点词之后的尾字（日文助词） */
  function heroTitle(before, word, after) {
    return before + '<span class="hero-word">' + word + HERO_UNDERLINE + "</span>" + (after || "") + TYPE_CARET;
  }

  var RICH = [
    {
      sel: "#hero-title",
      html: {
        en: heroTitle("Turn ideas<br>into the ", "next step"),
        ja: heroTitle("アイデアを、<br>", "次の一手", "へ"),
        de: heroTitle("Aus Ideen wird<br>der ", "nächste Schritt"),
        fr: heroTitle("De l'idée<br>à la ", "prochaine étape"),
      },
    },
    {
      sel: "#workspace-title",
      html: {
        en: 'Your work,<br><span class="soft">no longer scattered.</span>',
        ja: '仕事を、<br><span class="soft">散らかさない。</span>',
        de: 'Deine Arbeit,<br><span class="soft">nicht mehr verstreut.</span>',
        fr: 'Votre travail,<br><span class="soft">enfin rassemblé.</span>',
      },
    },
    {
      sel: "#voices-title",
      html: {
        en: 'You fall for a tool<br>because of <span class="serif-accent">one moment.</span>',
        ja: '道具を好きになるのは、<br>たいてい<span class="serif-accent">ある一瞬。</span>',
        de: 'Ein Werkzeug liebt man<br>oft wegen <span class="serif-accent">eines Moments.</span>',
        fr: 'On s\'attache à un outil<br>souvent pour <span class="serif-accent">un seul instant.</span>',
      },
    },
    {
      sel: "#closing-title",
      html: {
        en: "Your next idea<br><span>starts here.</span>" + CLOSING_CARET,
        ja: "次にやりたいことは、<br><span>ここから始まる。</span>" + CLOSING_CARET,
        de: "Dein nächstes Vorhaben<br><span>beginnt hier.</span>" + CLOSING_CARET,
        fr: "Votre prochaine idée<br><span>commence ici.</span>" + CLOSING_CARET,
      },
    },
  ];

  /* 标题与描述；中文同样取页面原值。描述须含系统要求、技术栈、许可证与隐私事实，措辞只写「不收集使用数据」 */
  var META = {
    title: {
      en: "Aster — Native macOS terminal workspace",
      ja: "Aster — ネイティブ macOS ターミナルワークスペース",
      de: "Aster — Nativer Terminal-Arbeitsbereich für macOS",
      fr: "Aster — Espace de travail terminal natif pour macOS",
    },
    desc: {
      en: "Aster is an open-source, native macOS terminal workspace: the Ghostty terminal core, recursive splits, file previews, AI agent sessions and on-device completion in one AppKit window. macOS 14+ (Apple silicon), MIT licensed, no usage data collected.",
      ja: "Aster はオープンソースのネイティブ macOS ターミナルワークスペース。Ghostty ターミナルコア、再帰分割、ファイルプレビュー、AI エージェントのセッション、ローカル補完を一つの AppKit ウィンドウに。macOS 14+（Apple シリコン）、MIT ライセンス、利用データは収集しません。",
      de: "Aster ist ein quelloffener, nativer Terminal-Arbeitsbereich für macOS: Ghostty-Terminalkern, rekursive Splits, Dateivorschau, KI-Agent-Sitzungen und lokale Vervollständigung in einem AppKit-Fenster. macOS 14+ (Apple Silicon), MIT-Lizenz, keine Erhebung von Nutzungsdaten.",
      fr: "Aster est un espace de travail terminal natif et open source pour macOS : moteur de terminal Ghostty, splits récursifs, aperçu de fichiers, sessions d'agents IA et complétion locale dans une seule fenêtre AppKit. macOS 14+ (puce Apple), licence MIT, aucune donnée d'usage collectée.",
    },
  };

  // MARK: - 翻译引擎

  var ATTRS = ["aria-label", "alt", "title"];
  var current = "zh";
  var cache = null;      /* 文本节点缓存：[{node, raw, zh}] */
  var richZh = null;     /* RICH 元素的中文原始 innerHTML，下标与 RICH 对应 */
  var metaZh = null;     /* 中文 title / description 原值 */
  var attrMemo = typeof WeakMap === "function" ? new WeakMap() : null; /* 元素 → {属性名: {zh, written}} */
  var keySet = new Set();
  var reverse = Object.create(null); /* 任一语言译文 → 中文键 */
  Object.keys(I18N).forEach(function (code) {
    var dict = I18N[code];
    Object.keys(dict).forEach(function (zh) {
      keySet.add(zh);
      if (!(dict[zh] in reverse)) reverse[dict[zh]] = zh;
    });
  });

  /* 查当前语言译文；缺词条时回退中文原文 */
  function lookup(code, zh) {
    if (code === "zh") return zh;
    return (I18N[code] && I18N[code][zh]) || zh;
  }

  /* 首次切换前缓存中文原貌：文本节点、RICH 标题、META。之后文本节点按缓存原地替换 */
  function buildCache() {
    cache = [];
    var richEls = RICH.map(function (r) { return document.querySelector(r.sel); });
    richZh = richEls.map(function (el) { return el ? el.innerHTML : ""; });
    var desc = document.querySelector('meta[name="description"]');
    metaZh = { title: document.title, desc: desc ? desc.getAttribute("content") : "" };
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

  /* 翻译 aria-label / alt / title。每次切换都重新扫描，覆盖 site.js 之后改写或新增的属性。
     判定中文键的顺序：上次本脚本写入的值 → 值本身就是中文键 → site.js 已按当前语言写入的译文（反查）。
     不认识的值（如 "GitHub stars"）原样保留。 */
  function translateAttrs(code) {
    var selector = ATTRS.map(function (a) { return "[" + a + "]"; }).join(",");
    document.body.querySelectorAll(selector).forEach(function (el) {
      var memo = attrMemo ? attrMemo.get(el) : el.__asterAttrs;
      if (!memo) {
        memo = {};
        if (attrMemo) attrMemo.set(el, memo); else el.__asterAttrs = memo;
      }
      ATTRS.forEach(function (name) {
        if (!el.hasAttribute(name)) return;
        var value = el.getAttribute(name);
        var prev = memo[name];
        var zh;
        if (prev && value === prev.written) zh = prev.zh;
        else if (keySet.has(value)) zh = value;
        else if (value in reverse) zh = reverse[value];
        else return;
        var tr = lookup(code, zh);
        memo[name] = { zh: zh, written: tr };
        if (value !== tr) el.setAttribute(name, tr);
      });
    });
  }

  /* 切换语言：文本节点、属性、RICH 标题、META 与切换器状态，最后广播 aster:lang */
  function setLang(code) {
    if (!I18N[code] && code !== "zh") code = "en";
    current = code;
    var langDef = LANGS.find(function (l) { return l.code === code; });
    document.documentElement.lang = langDef ? langDef.html : "zh-CN";

    if (!cache) buildCache();
    cache.forEach(function (item) {
      item.node.nodeValue = item.raw.replace(item.zh, lookup(code, item.zh));
    });
    translateAttrs(code);
    RICH.forEach(function (r, i) {
      var el = document.querySelector(r.sel);
      if (el) el.innerHTML = code === "zh" ? richZh[i] : (r.html[code] || richZh[i]);
    });
    document.title = code === "zh" ? metaZh.title : (META.title[code] || metaZh.title);
    var desc = document.querySelector('meta[name="description"]');
    if (desc) desc.setAttribute("content", code === "zh" ? metaZh.desc : (META.desc[code] || metaZh.desc));

    var label = document.querySelector("#lang-menu .lang-label");
    if (label && langDef) label.textContent = langDef.label;
    document.querySelectorAll("#lang-menu .lang-list button").forEach(function (b) {
      b.classList.toggle("on", b.dataset.lang === code);
    });
    try { localStorage.setItem("aster-lang", code); } catch (e) { /* 私密模式等场景忽略 */ }

    // 通知 site.js 重绘动态文案（补全候选、截图说明、播放按钮等）
    try {
      window.dispatchEvent(new CustomEvent("aster:lang", { detail: { code: code } }));
    } catch (e) { /* 不支持 CustomEvent 构造的旧浏览器：site.js 仍可靠 html[lang] 变化兜底 */ }
  }

  /* 供 site.js 的动态内容取当前语言文案；词典没有的键原样返回中文 */
  window.asterT = function (zh) {
    return lookup(current, zh);
  };

  // MARK: - 切换器 UI

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

  // MARK: - 初始语言：记忆 > 浏览器语言 > 中文

  /* 按浏览器语言列表挑第一个支持的语言；都不支持时用英文（非中文读者的通用回退） */
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
  setLang(initial); /* 中文也走一遍，以同步下拉选中态与 html lang */
})();
