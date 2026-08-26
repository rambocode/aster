# Otty 功能对齐矩阵

## 业务背景

Aster 以 Otty 用户文档为功能规格，目标范围是 `user-interface`、`workflows`、`terminal-features` 与 `agents` 四个栏目。本文是逐页审计入口；只有页面内全部可用行为均有实现与非 UI 功能测试时，状态才能改为“完成”。“部分”表示已有能力，但不能据此推断整页完成。

> Ghostty 切换说明：本矩阵中的 SwiftTerm 精细交互完成度是迁移前基线。当前产品暂停
> Vi/Mark/Hint、键盘扩展选区、大小写/正则终端查找、inline Autocomplete、精确命令
> Outline 和 OSC 6974 Agent lifecycle；这些条目在 Ghostty 公开接口补齐前按“部分”处理。

## 状态定义

- **待审计**：尚未逐段提炼规则与失败语义。
- **部分**：已存在一个或多个子能力，仍有明确缺口。
- **完成**：逐项代码证据、功能测试和用户文档齐全。
- **上游开发中**：Otty 页面只描述方向、没有稳定行为契约；记录现状但不臆造功能。

## 需求基线

以下条目来自 2026-08-08 对四个栏目 41 个页面的逐页读取，是后续实现与测试的验收边界。

### User Interface

- **Window / Tab / Split**：OSC 0/1/2 标题与覆盖、窗口尺寸模式/置顶/PiP、标签布局/分组/排序/分隔线/自动隐藏/徽标、新标签位置、分屏创建/移动/交换/等分/聚焦、关闭确认与最近关闭、Recipe 捕获；主题详情中的 Window/Container/Sidebar/Titlebar/Tabbar/Tab 等颜色必须到达对应 AppKit 对象。
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

- **接入与状态**：以最小增量安装 Claude、Codex、OpenCode、Cursor、Kimi、Pi、omp、Grok Build hook/plugin；上报 processing/idle/awaiting，驱动 badge、通知、防睡与恢复。
- **历史与分支**：识别各 Agent 的会话文件，渲染 transcript，搜索/resume；在 split/tab/window 中使用原生命令 fork/branch，保留 provider/model/system prompt。
- **输入工作流**：Composer 多行编辑、草稿、富粘贴、pin/float；Prompt Queue 在任意终端用 Return 入队、按列表项左侧按钮显式发送；Send to Chat 把终端/文件上下文预填到现有 Agent 会话。

## 页面清单

### User Interface（9）

- 完成：[Window, Tab and Split](https://docs.otty.sh/user-interface/window-tab-split) — 多窗口与恢复、Pin、当前/跟随 PiP、OSC 独立标题、三种标签布局、分组/排序/分隔线、跨窗口标签拖动、递归分屏、缩放/移动/交换/等分/聚焦及关闭恢复均已接入；“显示 → 主题”支持搜索、方向键/悬停实时预览、确认保存与取消恢复；9 套浅色主题已由对象级测试和逐主题截图验证 Window、Container、左右 Sidebar、Titlebar、Tabbar、Tab 与终端颜色按 Otty token 呈现，左侧标签布局的中央标题条延续 Window，目录胶囊使用 Titlebar。
- 部分：[Details Panel](https://docs.otty.sh/user-interface/details-panel) — Info、Outline、Git、Files 跟随活动 Pane；Info 区分成功空结果、不可用和失败，进程树包含 shell 根并仅检查本地 listener；Outline 支持运行中/已完成 OSC 133 命令、精确绑定 Agent prompt 和带真实位置的文档结构。检查有界且不在主线程执行外部命令；真实窗口交互仍按设计 QA 手工复验，因此不宣称整页完成。
- 不适用：[Status Bar](https://docs.otty.sh/user-interface/status-bar) — 上游页面明确标记为 Planned，没有已描述的可实现功能；Aster 不再渲染自定义底部状态栏。
- 完成：[Files and Links](https://docs.otty.sh/user-interface/files-and-links) — 路径/行列/URL/OSC 8 解析、安全打开、预览、编辑、复制、Finder、默认应用、终端目录动作和 Send to Chat 使用同一文件安全边界。
- 完成：[Drag and Drop](https://docs.otty.sh/user-interface/drag-and-drop) — 文件、目录、URL、文本、标签和 Pane 均有明确落点；标签跨窗口保留运行对象，Pane 内部重排不重启 PTY。
- 完成：[Find](https://docs.otty.sh/user-interface/find) — Pane 查找支持大小写/正则/上下跳转，全局查找覆盖终端、编辑器与预览并可定位回源。
- 完成：[Open Quickly](https://docs.otty.sh/user-interface/open-quickly) — All/Opened/Recent/Folders/SSH/Agents/Current/Recipes 八类过滤与有界 fuzzy 排序已实现。
- 完成：[Command Palette](https://docs.otty.sh/user-interface/command-palette) — Pane/Window/App scope 覆盖窗口、文件、分屏、模式、工作流和 Agent 动作。
- 部分：[Outline / Jump To](https://docs.otty.sh/user-interface/outline) — Markdown、HTML、JSON、YAML、TOML、Diff 与 canonical JSONL transcript 使用纯解析器生成有界大纲；JSON 保留源顺序和真实行号，终端运行中命令也进入索引。真实窗口的 Jump/Copy 与辅助功能验收仍待完成。

### Workflows（6）

- 完成：[Recipes](https://docs.otty.sh/workflows/recipes) — `.asterrecipe` 的 scope/content/layout/commands、TOML 导入导出、路径可移植化、内容哈希信任和空闲 Prompt 串行重放均已实现。
- 部分：[Session Recovery](https://docs.otty.sh/workflows/session-recovery) — Pane/Tab/Window LIFO、正常/崩溃/更新决策、附加窗口恢复和 crash-loop 已交付；tmux、Agent session 与普通进程的安全 Planner 已实现，但 snapshot 尚不持久化对应 session ID/命令，因此不会自动重启外部进程。
- 完成：[Frequent Folders](https://docs.otty.sh/workflows/frequent-folders) — OSC 7 自动学习、粘性忽略、时间衰减、100 项容量、Open Quickly 和 CLI `jump/learn/ignore` 已闭环。
- 完成：[Using the CLI in your Shell](https://docs.otty.sh/workflows/cli-usage) — `open/view/edit/watch/jump/learn/ignore`、Pane send/run/exec/capture、`--new-window`、同步 stdout/stderr/exit code、深链和 shell wrapper 均已实现；鉴权与 IPC 授权独立。
- 上游开发中：[Data Sync](https://docs.otty.sh/workflows/data-sync) — 页面只建议备份 `~/.config/otty`，没有稳定同步契约。
- 部分 / 上游开发中：[SSH / Remote Development](https://docs.otty.sh/workflows/ssh-remote) — 基础 SSH 会话和 `ssh://` 安全预填已存在；页面声明更深远程开发仍在开发中。

### Terminal Features（17）

- 完成：[Cursor and Mouse](https://docs.otty.sh/terminal-features/cursor-and-mouse) — 支持颜色、文字色、不透明度、方块/空心方块/竖线/下划线、Default/Always 闪烁优先级和平滑移动；Default 接受 DECSCUSR，Always 固定用户选择。TUI 鼠标、Option bypass、焦点与安全输入边界均已实现。
- 完成：[Selection](https://docs.otty.sh/terminal-features/selection) — 字符/词/行/矩形、Shift 扩展、键盘扩展、复制清理和提示符内安全删除均已实现；歧义范围按文档安全降级为只复制。
- 完成：[Scroll](https://docs.otty.sh/terminal-features/scroll) — 像素平滑、手势吸附、键盘翻页、首尾停靠、alternate screen 约束与命令锚点导航均已实现。
- 完成：[Input](https://docs.otty.sh/terminal-features/input) — IME、Kitty/modifyOtherKeys、原生行词编辑、Option/Meta 与自动/手动 Secure Input 已接入；不支持的跨 Shell Redo 不发送猜测序列。
- 完成：[Copy and Paste](https://docs.otty.sh/terminal-features/copy-and-paste) — 复制清理、paste protection、全部 Paste As、OSC 52 权限及 Composer 交接均已实现。
- 完成：[Autocomplete / Inline Suggest](https://docs.otty.sh/terminal-features/autocomplete) — 输入停顿触发、inline ghost、四种接受方案及 Escape/Option-Escape/F5/自动候选面板均已接入；面板支持上下选择、Return/Tab/点击接受和 8 行上限。候选覆盖命令、子命令、选项、参数、文件、目录、Shell alias、固定命令、历史、README 与纠错。Inline ghost 会等 PTY 回显完成并更新光标位置后才显示，避免本地输入 tracker 领先 Shell 时与命令文字重叠；接受键与渲染共用同一可见性判定，ghost 未显示（等待回显、被 Escape 关闭、设置关闭，或 zsh-autosuggestions 等 Shell 端建议占据行尾导致回显校验不通过）时 Tab 原样交给 Shell，绝不接受不可见候选。Bundle 内置由 `scripts/build-fig-specs.mjs` 从 `@withfig/autocomplete` npm 包生成的 714 条完整 Fig 规格（嵌套子命令、选项、参数、静态候选与文件模板，schema v2，约 11.6 MB）；没有内置结构的命令首次输入参数时，在禁网且禁止文件写入的沙箱中按 `--help`/`-h`/`help` 生成独立本地规格。学习按目录、会话、频率、时间与固定次数排序，过滤 secret、glob 忽略、127 和错误长选项；`aster learn` 使用 0600 随机 token 鉴权。关闭本机学习会同时停止历史、README、help 探测与纠错，内置规格和文件补全仍可用。规格更新只能由设置页手动触发，从 Aster 仓库 raw 地址拉取同一份生成文件，且不覆盖本地规格；设置页状态与 Otty 对齐为 `v<上游日期> · N 条命令`。
- 完成：[Unicode and Text Styles](https://docs.otty.sh/terminal-features/unicode-and-text-styles) — Unicode/emoji/宽度/样式、Ambiguous block、连字、粗斜体/blink 策略及内置 Aster Nerd Symbols cascade fallback 均已交付。
- 完成：[BiDi / RTL Text](https://docs.otty.sh/terminal-features/bidi-rtl) — 逻辑缓冲不变，逐显示行使用 Unicode BiDi run 排列；纯 LTR 保持原位，caret、鼠标命中和普通左右键跟随视觉顺序，复制/搜索保留逻辑顺序。设置默认开启，ECMA-48 mode 8、关闭设置与 reset 均有测试。
- 完成：[Box Drawing](https://docs.otty.sh/terminal-features/box-drawing) — box/block 元素由网格几何渲染器绘制，不依赖字体 glyph 的 baseline 与 hinting。
- 完成：[Images](https://docs.otty.sh/terminal-features/images) — iTerm2 OSC 1337 支持 PNG/JPEG/GIF；Kitty 支持 direct/file/temp、分片、zlib、RGB/RGBA/PNG、placement/query/delete/placeholder；Sixel 支持 raster、RGB/HLS、RLE、透明背景与 VT340 palette。APC、分片、解压、尺寸、repeat、缓存和 RGBA 分配均有硬上限与失败清理。
- 完成：[Progress State](https://docs.otty.sh/terminal-features/progress-state) — 完整解析 OSC 9;4（含 watch/quiet 完成扩展），保留 SwiftTerm 顶部进度条；支持可配置空白前缀自动进度、`aster watch`、CLI 直接徽章、完成闪现/未读/错误/等待输入标签状态，以及可选 Dock 动画、默认错误标红和点击跳转。等待输入要求提示停留 1.5 秒且输入立即清除。
- 完成：[Privilege and Notifications](https://docs.otty.sh/terminal-features/notifications) — OSC 9/777/99 均映射系统通知；OSC 99 支持 urgency、base64、8 KiB 分片重组、替换 ID 和 capability query。成功/错误/watch、Shell Controlled、前台策略、Dock 弹跳、通知分类声音、BEL 与错误 beep 均独立可配；系统权限状态可刷新并直达设置。标题修改默认开、标题报告默认关，OSC 52 和 Secure Input 继续走各自安全边界。
- 完成：[Vi Mode](https://docs.otty.sh/terminal-features/vi-mode) — `Control+Shift+Space` 进入，支持计数、字符/词/行/屏幕/缓冲区/半页与整页移动，字符/整行/矩形选择、锚点交换、复制退出、`/ ? n N` 查找和 `f` 进入 Hint；`Escape`/`q` 退出，`Command+/` 切换按键提示。模式只修改本地 Buffer 选区和视口，不向 PTY 写入按键。
- 完成：[Hint Mode](https://docs.otty.sh/terminal-features/hint-mode) — 当前可见区的 OSC 8、URL 和文件路径按稳定顺序生成无前缀歧义标签；普通最终键经过统一安全层打开，最终键带 Shift 时复制规范化 URL 或含行列的绝对路径。输出改变立即取消旧标签并恢复进入前模式。
- 完成：[Read-only Mode](https://docs.otty.sh/terminal-features/read-only-mode) — 锁按 Pane 隔离且不持久化；终端键盘、IME、粘贴、TUI 鼠标与滚轮报告被统一拦截，协议自动回包继续发送，滚动、选择、复制、查找和输出不受影响。进入 Vi/Hint 时暂时隐藏只读 pill，但锁不会被清除；编辑器 Pane 同样停止文本改写。
- 完成：[Shell Integration](https://docs.otty.sh/terminal-features/shell-integration) — zsh/bash/fish OSC 133/7、幂等安装卸载、tmux 子 Shell、按会话禁用、命令时间线和 CLI wrapper 已接入；SSH 深度注入归入上游开发中的 Remote Development。
- 完成：[$TERM and Identification](https://docs.otty.sh/terminal-features/term-value) — TERM/terminfo 校验、环境身份、DA1/DA2/XTVERSION/DSR 与 DA3 隐私边界均已实现。

### Working with Agents（9）

- 完成：[Overview](https://docs.otty.sh/agents/agents-overview) — Agent 被建模为普通 PTY 上的 provider 会话，状态、历史、输入工作流与终端能力组合而非另建执行器。
- 完成：[Setup](https://docs.otty.sh/agents/setup) — 八类 provider（含 Grok Build）的检测、最小增量安装、卸载、重启提示和结构化自定义启动命令已实现。
- 完成：[Monitor Tasks](https://docs.otty.sh/agents/parallel-tasks) — hook 状态驱动多标签/多窗口 badge、通知、Dock、防睡与聚焦。
- 完成：[History](https://docs.otty.sh/agents/history) — 已知 provider 路径有界发现、解析、搜索和 Resume；无稳定路径的 provider 不做猜测。
- 完成：[Composer](https://docs.otty.sh/agents/composer) — 多行草稿、附件、固定、浮动、取消和 bracketed 提交已实现。
- 完成：[Prompt Queue](https://docs.otty.sh/agents/prompt-queue) — 容量/字节限制、重排/删除及 authoritative idle 后串行派发已实现。
- 完成：[Send to Chat](https://docs.otty.sh/agents/send-to-chat) — 终端选区和文件上下文经过控制字符清理、secret 遮盖、provenance 包装与总预算后进入 Composer。
- 完成：[Fork / Branch Session](https://docs.otty.sh/agents/fork-branch-session) — provider 原生 Resume/Fork 参数和能力拒绝已实现，并保留 provider/model/system prompt 元数据。
- 完成：[Supported Agents](https://docs.otty.sh/agents/supported-agents) — Claude Code、Codex、OpenCode、Cursor CLI、Kimi Code、Pi、omp、Grok Build 能力矩阵与接入方式已编码；Grok 会话历史扫描仍按上游未接线处理。

## 当前实现说明

`TerminalTitleState` 分离 OSC 1/2/0，清理控制字符并限制标题长度；每个 Pane 保存独立程序标题，只有聚焦 Pane 驱动标签和窗口。自定义 OSC handler 会同步回 SwiftTerm 内部状态；`TerminalTitleStackObserver` 跨 PTY 分片镜像 OSC/CSI，并补偿 macOS 端缺失或错误的 XTWINOPS 图标/窗口标题恢复回调。`NewTabPosition` 以纯函数决定插入位置；创建标签后会切换为手动显示顺序，避免时间排序覆盖目标位置。`RecentlyClosedTabs` 只保存可重建的标签快照，并在解码时约束历史容量。对应状态经 `WorkspaceTabSnapshot` 和独立 `UserDefaults` 键持久化，不保存进程身份。

Selection 与 Scroll 需要访问 SwiftTerm 1.15 未公开的选区锚点、矩形状态和像素滚动偏移。仓库将上游 revision `dd2fb8ac5b861e7bf617c872895e338f38165648` 固定到 `Vendor/SwiftTerm`，保留 MIT 许可证，并只在终端内核边界维护补丁；来源、核验与同步步骤见 `Vendor/SwiftTerm/UPSTREAM.md`。键盘选区跨锚点收缩或反向扩展，矩形复制按行输出；像素滚动以 `yDisp + viewportContentTranslationY` 表示，边界模式只在 normal buffer 生效。

Shell Integration 由 `ShellIntegrationLaunchPlan`、`ShellIntegrationInstaller` 与 `ShellCommandTimeline` 分层：启动计划只生成环境，安装器只维护带品牌守卫的 rc 区块，时间线只接受最长 32 字节且严格匹配 FTCS 的 payload。命令文本不会通过 OSC 133 持久化；OSC 7 路径按 UTF-8 字节 URL 转义，BEL/ESC 目录名不能注入控制序列；位置采用 `totalLinesTrimmed + bufferRow` 的单调坐标，scrollback 到达容量后仍能判断锚点是否已经裁剪。终端身份由 `TerminalIdentityPolicy` 与 `TerminalLaunchEnvironmentBuilder` 解析，`infocmp` 只以固定可执行文件和参数数组调用，非法配置不会进入 Shell。

Unicode、BiDi 与图像渲染的领域边界见 `terminal-text-and-images.md`。核心规则是逻辑文本与视觉布局分离：可配置宽度只影响新写入字符；UTF-16 shaping range 经 cell offset 映射回固定网格；BiDi 只生成视觉列映射；图片协议在位图分配和解压前完成所有上限检查。

Autocomplete 由 `PromptInputTracker`、`AutocompleteEngine`、`AutocompleteLearningDatabase`、`AutocompleteService` 与 `TerminalAutocompleteController` 分层。OSC 133 只确定 prompt/command 生命周期，命令正文只从用户输入字节重建；Up/Down 等无法重建的 Shell 历史操作会停用当前 prompt 候选。学习、Fig 更新、本地 help 规格使用独立有界文件，手动更新不会覆盖本地学习。Shell alias 通过 OSC 6973 只发送有界名称，不发送展开正文。

工作区发现由 `OpenQuicklyIndex`、`WorkspaceGlobalSearchIndex`、`WorkspaceOutlineParser` 与 `WorkspaceInspectionService` 分层；所有集合、单项文本、目录深度、外部进程输出和结果数量均有限制。`AsterAppDelegate` 为每个窗口持有独立模型，`AdditionalWorkspaceWindowRegistry` 只恢复最多 16 个 Aster UUID suite。跨窗口标签移动转移现有 `TerminalTabItem`，不重建运行态；Pin、PiP 与 CLI 新窗口都通过模型意图路由到真实 AppKit 窗口。

Workflows 与 Agent 的详细边界见 `workflows-and-agents.md`。Recipe 信任使用内容 SHA-256；CLI 使用 `0600` token 和原子普通文件传输；Agent setup 只改写有所有权标记的配置。lifecycle hook 通过 OSC 6974 上报状态，`AgentTaskStateReducer` 驱动 badge、通知、Prompt Queue 和防睡。Composer 与 Send to Chat 对附件、上下文项、UTF-8 字节和 secret 遮盖实施统一预算。

`BundledFontRegistry` 在启动时注册 `AsterNerdSymbols-Regular.ttf`，并把该字体加入用户基础终端字体的 CoreText cascade；字体同时复制进 App bundle，BMP 与补充平面 Nerd glyph 均由测试验证。来源、修改名称和许可证记录于 `THIRD-PARTY-NOTICES.md`。

文件和链接统一经过 `TargetResolver`、`TargetFileInspector` 与 `TargetSecurityPolicy`；点击单元格的 OSC 8 payload 是显式来源真值，`TerminalTargetOpenCoordinator` 取代组件默认直开路径。普通文字可选择检测全部 scheme 或标准 scheme 加自定义列表；OSC 8 始终识别，但所有非标准协议、可执行文件和 `.app` 仍需确认。可执行目标不保存路径授权，配置导入也会剥离本机 scheme 例外。

复制粘贴由 `PasteRiskAnalyzer`、`PasteProtectionPolicy` 与 `PasteTransmissionEncoder` 组成纯领域链路，AppKit 只负责系统剪贴板、确认和 PTY 写入；bracketed 结束标记会被中和，控制字符不会因可信模式跳过。`TerminalOSCStreamLimiter` 在 SwiftTerm parser 前对普通 OSC、OSC 52、通知 OSC 分别实施 16 MiB、8 MiB、约 8 KiB 的跨分片硬上限，自定义 handler 再执行解码后限长和动态权限；配置导入会降级无提示读取授权，Ask 有重入保护与冷却。`TerminalFilePasteEncoder` 拒绝符号链接，并在打开前后复验文件身份和变更时间，避免特殊文件读取与路径替换竞态。

菜单层补齐 Otty 的字号、全屏与插入链路：字号命令修改共享配置并同步所有终端，原生全屏动作定位当前工作区窗口；文件选择、交互式截屏和 AppKit Continuity Camera 都只把经过 Shell 转义的路径预填到当前前台程序输入框，Codex/Claude TUI 复用 bracketed-paste 交付且不自动提交。Continuity Camera 结果由标准 `readSelectionFromPasteboard:` responder selector 接收；手机与截屏结果经 `TerminalImportedFileStore` 约束类型、32 MiB 上限、普通文件身份以及 `0700/0600` 临时权限。Open Quickly 的历史 Prompt 在没有运行中 Agent 时同样可用，并回退写入当前终端。Carbon 安全输入真实启用时，中央工作区标题栏右侧同步显示 `SECURE INPUT` 状态胶囊。

## 测试与验收

测试除既有终端文件外，还包括 `WorkspaceDiscoveryTests.swift`、`WorkflowCLITests.swift`、`WorkflowRecipeTests.swift`、`WorkflowRecoveryTests.swift`、`AgentProviderTests.swift`、`AgentStateTests.swift`、`AgentHistoryTests.swift`、`AgentComposerTests.swift`、`AgentPromptQueueTests.swift`、`AgentChatContextTests.swift`、`AgentSetupServiceTests.swift`、`AgentIntegrationServiceTests.swift`、`AsterCLIRequestServiceTests.swift`、`WorkflowRuntimeServiceTests.swift` 与 `BundledFontRegistryTests.swift`。Shell 资源会启动真实 zsh 与 macOS Bash 3.2 验证 A/B/C/D、用户 `ZDOTDIR`、rc 回滚和控制字节路径；当前机器未安装 fish，因此 fish 只做静态资源检查，安装 fish 的环境会额外执行语法检查。界面视觉仍按 `design-qa.md` 验收；显示/编辑菜单还需在真实 Aster 窗口与 Codex TUI 中确认路径预填、控制键、字号刷新和安全输入状态胶囊。
