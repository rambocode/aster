# Otty 功能对齐矩阵

## 业务背景

Aster 以 Otty 用户文档为功能规格，目标范围是 `user-interface`、`workflows`、`terminal-features` 与 `agents` 四个栏目。本文是逐页审计入口；只有页面内全部可用行为均有实现与非 UI 功能测试时，状态才能改为“完成”。“部分”表示已有能力，但不能据此推断整页完成。

## 状态定义

- **待审计**：尚未逐段提炼规则与失败语义。
- **部分**：已存在一个或多个子能力，仍有明确缺口。
- **完成**：逐项代码证据、功能测试和用户文档齐全。
- **上游开发中**：Otty 页面只描述方向、没有稳定行为契约；记录现状但不臆造功能。

## 需求基线

以下条目来自 2026-08-08 对四个栏目 41 个页面的逐页读取，是后续实现与测试的验收边界。

### User Interface

- **Window / Tab / Split**：OSC 0/1/2 标题与覆盖、窗口尺寸模式/置顶/PiP、标签布局/分组/排序/分隔线/自动隐藏/徽标、新标签位置、分屏创建/移动/交换/等分/聚焦、关闭确认与最近关闭、Recipe 捕获。
- **Details / Outline**：详情跟随聚焦 Pane；Info 显示目录、进程、监听端口和打开动作；Outline 索引命令/Agent Prompt/文件结构；Git 显示仓库与变更；Files 显示以 CWD 为根的树。
- **Files / Links / Drag**：识别绝对、tilde、相对、行列路径、URL 与 OSC 8；安全打开、预览、复制、Finder、`cd`；支持文件/目录/URL/文本、标签和 Pane 的拖放落点语义。
- **Find / Open Quickly / Command Palette**：Pane 内实时查找、大小写/正则/范围与全局结果；Open Quickly 的 All/Opened/Recent/Folders/SSH/Agents/Current/Recipes 过滤器；命令面板覆盖全部带 Pane/Window/App scope 的动作。
- **Status Bar**：上游仅标记 Planned，不据此新增行为。

### Workflows

- **Recipes**：tab/window/commands scope，layout/commands/scrollback 内容级别，可移植路径，内部保存和 TOML 导入导出，来源区分、SHA-256 信任与命令 replay 策略。
- **Recovery**：pane/tab/window 最近关闭 LIFO；正常退出、崩溃、更新三类启动恢复；可选 tmux/Agent/进程恢复与命令白名单。
- **Frequent Folders / CLI**：目录自动学习、忽略、frecency 衰减和排名；`open/view/edit/watch/jump/learn/ignore`、Pane send/run/exec/capture、深链与 shell wrapper/alias。
- **Data Sync / SSH Remote**：Data Sync 与深度 SSH 开发均标记 In Development；只验收页面明确声称已存在的配置目录备份建议和基础 SSH 会话，不实现未定义方向。

### Terminal Features

- **交互**：cursor shape/blink policy、鼠标捕获和 bypass；字符/行/矩形选择；首尾 overscroll 与 smooth scroll；原生编辑键、IME、Kitty/modifyOtherKeys、Secure Input；复制清理、paste protection、paste-as 与 OSC 52 权限。
- **文本与媒体**：离线 autocomplete 与隐私过滤；完整 Unicode/emoji/样式、BiDi 逻辑顺序、box drawing；iTerm2/Kitty/Sixel 图片协议。
- **状态与模式**：OSC 9;4 进度、badge/Dock；OSC 9/99/777 通知、BEL 与权限；Vi、Hint、Read-only 三种 Pane 模式及其交互边界。
- **Shell / Identification**：zsh/bash/fish OSC 133/7 集成及安全安装卸载；`TERM`/`COLORTERM`/`TERM_PROGRAM`/`OTTY_PANE_ID`、DA1/DA2/XTVERSION/DSR 与 terminfo。

### Working with Agents

- **接入与状态**：以最小增量安装 Claude、Codex、OpenCode、Cursor、Kimi、Pi、omp hook/plugin；上报 processing/idle/awaiting，驱动 badge、通知、防睡与恢复。
- **历史与分支**：识别各 Agent 的会话文件，渲染 transcript，搜索/resume；在 split/tab/window 中使用原生命令 fork/branch，保留 provider/model/system prompt。
- **输入工作流**：Composer 多行编辑、草稿、富粘贴、pin/float；Prompt Queue 在空闲 Prompt 串行派发；Send to Chat 把终端/文件上下文送入现有或新 Agent 会话。

## 页面清单

### User Interface（9）

- 部分：[Window, Tab and Split](https://docs.otty.sh/user-interface/window-tab-split) — 已有递归分屏、导航、重排、三种标签布局、分组/排序/分隔线；本轮补充 OSC 独立标题、名称/前缀、新标签位置和最近关闭恢复。窗口多实例、Pin、PiP 等仍待实现。
- 部分：[Details Panel](https://docs.otty.sh/user-interface/details-panel)
- 不适用：[Status Bar](https://docs.otty.sh/user-interface/status-bar) — 上游页面明确标记为 Planned，没有已描述的可实现功能；Aster 现有状态栏属于自身能力。
- 部分：[Files and Links](https://docs.otty.sh/user-interface/files-and-links) — 已实现绝对/tilde/相对/行列路径规范化、任意或自定义 scheme、OSC 8 精确来源、非标准 scheme 首次确认、可执行文件与 `.app` 每次确认、scheme 例外持久化，以及 FIFO/socket/设备拒绝；上下文动作矩阵、内置预览和编辑器行列跳转仍待实现。
- 部分：[Drag and Drop](https://docs.otty.sh/user-interface/drag-and-drop)
- 部分：[Find](https://docs.otty.sh/user-interface/find)
- 待审计：[Open Quickly](https://docs.otty.sh/user-interface/open-quickly)
- 部分：[Command Palette](https://docs.otty.sh/user-interface/command-palette)
- 待审计：[Outline / Jump To](https://docs.otty.sh/user-interface/outline)

### Workflows（6）

- 部分：[Recipes](https://docs.otty.sh/workflows/recipes)
- 部分：[Session Recovery](https://docs.otty.sh/workflows/session-recovery)
- 部分：[Frequent Folders](https://docs.otty.sh/workflows/frequent-folders) — 已实现 OSC 7 自动学习、粘性忽略、精确/前缀/包含匹配、文档规定的时间衰减、100 项容量和本机持久化；管理 UI、Open Quickly Folders 与 CLI `jump/learn/ignore` 尚待接入。
- 部分：[Using the CLI in your Shell](https://docs.otty.sh/workflows/cli-usage)
- 上游开发中：[Data Sync](https://docs.otty.sh/workflows/data-sync) — 页面只建议备份 `~/.config/otty`，没有稳定同步契约。
- 部分 / 上游开发中：[SSH / Remote Development](https://docs.otty.sh/workflows/ssh-remote) — 基础 SSH 会话和 `ssh://` 安全预填已存在；页面声明更深远程开发仍在开发中。

### Terminal Features（17）

- 部分：[Cursor and Mouse](https://docs.otty.sh/terminal-features/cursor-and-mouse)
- 部分：[Selection](https://docs.otty.sh/terminal-features/selection) — 已实现拖动、双击单词、三击整行、`Option` 矩形拖选、`Shift` 点击扩展，以及线性/矩形 `Shift+Arrow` 键盘扩展；`Option` 在鼠标报告期间强制原生选择，`Shift` 是否被终端捕获遵循协议模式。选中即复制、输入时清选区和复制后清选区均可配置。Shell Integration 提供当前提示符边界后，Backspace 与 Cut 可删除同一输入行内能精确映射的 ASCII 选区；跨行、矩形和 Unicode 歧义范围安全降级为只复制，完整输入缓冲映射仍待后续增强。
- 部分：[Scroll](https://docs.otty.sh/terminal-features/scroll) — 已实现 `Shift+Page Up/Down`、`Shift+Home/End`、新输出/输入回到底部、像素级平滑滚动与手势结束行吸附，并提供滚过首尾的全部停靠模式；alternate screen 禁用越界空白。OSC 133 命令锚点已接入，`Command+Page Up/Down` 可跳到上一/下一条未被 scrollback 裁剪的命令。
- 部分：[Input](https://docs.otty.sh/terminal-features/input) — SwiftTerm 已承载 IME、Kitty Keyboard Protocol、modifyOtherKeys 与应用键盘模式；Aster 新增普通 Shell 下的原生 macOS 行/词移动、行/词删除与撤销 readline 映射，并在全屏 TUI 或增强键盘协议启用时保留组件原编码。Option as Meta 新安装默认关闭。自动安全输入在终端 I/O 前后读取 PTY ECHO/ICANON，手动开关位于“编辑 → 安全键盘输入”且应用失活时暂停。Shift+Arrow 选择和可配置选择清理已经接入；Redo、Composer 与 Prompt Queue 仍按各自批次推进。
- 部分：[Copy and Paste](https://docs.otty.sh/terminal-features/copy-and-paste) — 已实现快捷键/菜单/右键复制粘贴、选中即复制、逐行去尾空白、复制后清选区、四类危险粘贴识别、备用屏与可信 bracketed 跳过、Paste As（选区/文件 Base64/Shell 转义/强制 bracketed）及 OSC 52 独立读写权限；“粘贴并在 Composer 中继续”已保留安全接缝，待 Composer 批次接通。
- 完成：[Autocomplete / Inline Suggest](https://docs.otty.sh/terminal-features/autocomplete) — 输入停顿触发、inline ghost、四种接受方案及 Escape/Option-Escape/F5/自动候选面板均已接入；面板支持上下选择、Return/Tab/点击接受和 8 行上限。候选覆盖命令、子命令、选项、参数、文件、目录、Shell alias、固定命令、历史、README 与纠错。Bundle 固定 Fig revision 的 715 个直接命令名称；没有内置结构的命令首次输入参数时，在禁网且禁止文件写入的沙箱中按 `--help`/`-h`/`help` 生成独立本地规格。学习按目录、会话、频率、时间与固定次数排序，过滤 secret、glob 忽略、127 和错误长选项；`aster learn` 使用 0600 随机 token 鉴权。关闭本机学习会同时停止历史、README、help 探测与纠错，内置规格和文件补全仍可用。Fig 更新只能由设置页手动触发，且不覆盖本地规格。
- 部分：[Unicode and Text Styles](https://docs.otty.sh/terminal-features/unicode-and-text-styles) — 完整 Unicode、emoji/variation selector、宽字符、24-bit/256 色及五类下划线沿用 SwiftTerm；本轮增加可配置 Ambiguous block、三档连字、粗斜体策略、稳定/动画 blink、SGR 6、Invisible，并修正连字与 UTF-16/网格映射。内置 Nerd Font fallback 尚未随包交付，因此本页仍为部分。
- 完成：[BiDi / RTL Text](https://docs.otty.sh/terminal-features/bidi-rtl) — 逻辑缓冲不变，逐显示行使用 Unicode BiDi run 排列；纯 LTR 保持原位，caret、鼠标命中和普通左右键跟随视觉顺序，复制/搜索保留逻辑顺序。设置默认开启，ECMA-48 mode 8、关闭设置与 reset 均有测试。
- 部分：[Box Drawing](https://docs.otty.sh/terminal-features/box-drawing)
- 完成：[Images](https://docs.otty.sh/terminal-features/images) — iTerm2 OSC 1337 支持 PNG/JPEG/GIF；Kitty 支持 direct/file/temp、分片、zlib、RGB/RGBA/PNG、placement/query/delete/placeholder；Sixel 支持 raster、RGB/HLS、RLE、透明背景与 VT340 palette。APC、分片、解压、尺寸、repeat、缓存和 RGBA 分配均有硬上限与失败清理。
- 完成：[Progress State](https://docs.otty.sh/terminal-features/progress-state) — 完整解析 OSC 9;4（含 watch/quiet 完成扩展），保留 SwiftTerm 顶部进度条；支持可配置空白前缀自动进度、`aster watch`、CLI 直接徽章、完成闪现/未读/错误/等待输入标签状态，以及可选 Dock 动画、默认错误标红和点击跳转。等待输入要求提示停留 1.5 秒且输入立即清除。
- 完成：[Privilege and Notifications](https://docs.otty.sh/terminal-features/notifications) — OSC 9/777/99 均映射系统通知；OSC 99 支持 urgency、base64、8 KiB 分片重组、替换 ID 和 capability query。成功/错误/watch、Shell Controlled、前台策略、Dock 弹跳、通知分类声音、BEL 与错误 beep 均独立可配；系统权限状态可刷新并直达设置。标题修改默认开、标题报告默认关，OSC 52 和 Secure Input 继续走各自安全边界。
- 完成：[Vi Mode](https://docs.otty.sh/terminal-features/vi-mode) — `Control+Shift+Space` 进入，支持计数、字符/词/行/屏幕/缓冲区/半页与整页移动，字符/整行/矩形选择、锚点交换、复制退出、`/ ? n N` 查找和 `f` 进入 Hint；`Escape`/`q` 退出，`Command+/` 切换按键提示。模式只修改本地 Buffer 选区和视口，不向 PTY 写入按键。
- 完成：[Hint Mode](https://docs.otty.sh/terminal-features/hint-mode) — 当前可见区的 OSC 8、URL 和文件路径按稳定顺序生成无前缀歧义标签；普通最终键经过统一安全层打开，最终键带 Shift 时复制规范化 URL 或含行列的绝对路径。输出改变立即取消旧标签并恢复进入前模式。
- 完成：[Read-only Mode](https://docs.otty.sh/terminal-features/read-only-mode) — 锁按 Pane 隔离且不持久化；终端键盘、IME、粘贴、TUI 鼠标与滚轮报告被统一拦截，协议自动回包继续发送，滚动、选择、复制、查找和输出不受影响。进入 Vi/Hint 时暂时隐藏只读 pill，但锁不会被清除；编辑器 Pane 同样停止文本改写。
- 部分：[Shell Integration](https://docs.otty.sh/terminal-features/shell-integration) — 已提供签名 Bundle 内可读的 zsh/bash/fish 脚本，发送 OSC 133 A/B/C/D 与 OSC 7；zsh/fish 使用会话环境注入，Bash 与 tmux 子 Shell 使用幂等、可卸载且保留符号链接/用户内容的受管 rc 区块。关闭设置会确认并移除区块，`ASTER_DISABLE_INTEGRATION=1` 可按 Shell 禁用。命令时间线驱动运行状态、退出码徽标、`Command+Page Up/Down` 和安全提示符删除；SSH wrapper、`--no-integration` CLI 与进程恢复仍待对应工作流批次。
- 部分：[$TERM and Identification](https://docs.otty.sh/terminal-features/term-value) — `auto` 默认解析为 `xterm-256color`，自定义名称经语法与真实 terminfo 校验；缺失时告警回退。Pane 注入 `TERM`、`COLORTERM`、`TERM_PROGRAM=aster`、版本、`CW_TERM=aster` 与稳定 `ASTER_PANE_ID`（保留旧 `ASTER_SESSION_ID` 别名），并优先搜索签名 Bundle terminfo。DA1/DA2、XTVERSION、DSR 5/6 与不响应 DA3 均已按品牌安全合同实现；远端 SSH 首次传输 terminfo 待 SSH 工作流。

### Working with Agents（9）

- 待审计：[Overview](https://docs.otty.sh/agents/agents-overview)
- 部分：[Setup](https://docs.otty.sh/agents/setup)
- 待审计：[Monitor Tasks](https://docs.otty.sh/agents/parallel-tasks)
- 待审计：[History](https://docs.otty.sh/agents/history)
- 待审计：[Composer](https://docs.otty.sh/agents/composer)
- 待审计：[Prompt Queue](https://docs.otty.sh/agents/prompt-queue)
- 待审计：[Send to Chat](https://docs.otty.sh/agents/send-to-chat)
- 待审计：[Fork / Branch Session](https://docs.otty.sh/agents/fork-branch-session)
- 待审计：[Supported Agents](https://docs.otty.sh/agents/supported-agents)

## 当前实现说明

`TerminalTitleState` 分离 OSC 1/2/0，清理控制字符并限制标题长度；每个 Pane 保存独立程序标题，只有聚焦 Pane 驱动标签和窗口。自定义 OSC handler 会同步回 SwiftTerm 内部状态；`TerminalTitleStackObserver` 跨 PTY 分片镜像 OSC/CSI，并补偿 macOS 端缺失或错误的 XTWINOPS 图标/窗口标题恢复回调。`NewTabPosition` 以纯函数决定插入位置；创建标签后会切换为手动显示顺序，避免时间排序覆盖目标位置。`RecentlyClosedTabs` 只保存可重建的标签快照，并在解码时约束历史容量。对应状态经 `WorkspaceTabSnapshot` 和独立 `UserDefaults` 键持久化，不保存进程身份。

Selection 与 Scroll 需要访问 SwiftTerm 1.15 未公开的选区锚点、矩形状态和像素滚动偏移。仓库将上游 revision `dd2fb8ac5b861e7bf617c872895e338f38165648` 固定到 `Vendor/SwiftTerm`，保留 MIT 许可证，并只在终端内核边界维护补丁；来源、核验与同步步骤见 `Vendor/SwiftTerm/UPSTREAM.md`。键盘选区跨锚点收缩或反向扩展，矩形复制按行输出；像素滚动以 `yDisp + viewportContentTranslationY` 表示，边界模式只在 normal buffer 生效。

Shell Integration 由 `ShellIntegrationLaunchPlan`、`ShellIntegrationInstaller` 与 `ShellCommandTimeline` 分层：启动计划只生成环境，安装器只维护带品牌守卫的 rc 区块，时间线只接受最长 32 字节且严格匹配 FTCS 的 payload。命令文本不会通过 OSC 133 持久化；OSC 7 路径按 UTF-8 字节 URL 转义，BEL/ESC 目录名不能注入控制序列；位置采用 `totalLinesTrimmed + bufferRow` 的单调坐标，scrollback 到达容量后仍能判断锚点是否已经裁剪。终端身份由 `TerminalIdentityPolicy` 与 `TerminalLaunchEnvironmentBuilder` 解析，`infocmp` 只以固定可执行文件和参数数组调用，非法配置不会进入 Shell。

Unicode、BiDi 与图像渲染的领域边界见 `terminal-text-and-images.md`。核心规则是逻辑文本与视觉布局分离：可配置宽度只影响新写入字符；UTF-16 shaping range 经 cell offset 映射回固定网格；BiDi 只生成视觉列映射；图片协议在位图分配和解压前完成所有上限检查。

Autocomplete 由 `PromptInputTracker`、`AutocompleteEngine`、`AutocompleteLearningDatabase`、`AutocompleteService` 与 `TerminalAutocompleteController` 分层。OSC 133 只确定 prompt/command 生命周期，命令正文只从用户输入字节重建；Up/Down 等无法重建的 Shell 历史操作会停用当前 prompt 候选。学习、Fig 更新、本地 help 规格使用独立有界文件，手动更新不会覆盖本地学习。Shell alias 通过 OSC 6973 只发送有界名称，不发送展开正文。

文件和链接统一经过 `TargetResolver`、`TargetFileInspector` 与 `TargetSecurityPolicy`；点击单元格的 OSC 8 payload 是显式来源真值，`TerminalTargetOpenCoordinator` 取代组件默认直开路径。普通文字可选择检测全部 scheme 或标准 scheme 加自定义列表；OSC 8 始终识别，但所有非标准协议、可执行文件和 `.app` 仍需确认。可执行目标不保存路径授权，配置导入也会剥离本机 scheme 例外。

复制粘贴由 `PasteRiskAnalyzer`、`PasteProtectionPolicy` 与 `PasteTransmissionEncoder` 组成纯领域链路，AppKit 只负责系统剪贴板、确认和 PTY 写入；bracketed 结束标记会被中和，控制字符不会因可信模式跳过。`TerminalOSCStreamLimiter` 在 SwiftTerm parser 前对普通 OSC、OSC 52、通知 OSC 分别实施 16 MiB、8 MiB、约 8 KiB 的跨分片硬上限，自定义 handler 再执行解码后限长和动态权限；配置导入会降级无提示读取授权，Ask 有重入保护与冷却。`TerminalFilePasteEncoder` 拒绝符号链接，并在打开前后复验文件身份和变更时间，避免特殊文件读取与路径替换竞态。

## 测试与验收

新增测试位于 `WorkspaceNavigationPolicyTests.swift`、`WorkspaceBehaviorTests.swift`、`DetectedTargetTests.swift`、`TerminalClipboardTests.swift`、`TerminalClipboardCoordinatorTests.swift`、`TerminalSelectionTests.swift`、`TerminalScrollTests.swift`、`TerminalUnicodeRenderingTests.swift`、`TerminalBidirectionalTests.swift`、`TerminalGraphicsTests.swift`、`ShellIntegrationTests.swift`、`ShellIntegrationInstallerTests.swift`、`TerminalIdentificationTests.swift`、`TerminalLaunchEnvironmentTests.swift`、`TerminalShellIntegrationTests.swift`、`AsterConfigurationTests.swift` 与 `AppKitMigrationTests.swift`。Shell 资源会启动真实 zsh 与 macOS Bash 3.2 验证 A/B/C/D、用户 `ZDOTDIR`、rc 回滚和控制字节路径；当前机器未安装 fish，因此 fish 只做静态资源检查，安装 fish 的环境会额外执行语法检查。每完成一页，必须在本矩阵记录代码入口、失败路径和测试名称；界面视觉验收由用户执行。
