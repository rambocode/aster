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
- 部分：[Files and Links](https://docs.otty.sh/user-interface/files-and-links)
- 部分：[Drag and Drop](https://docs.otty.sh/user-interface/drag-and-drop)
- 部分：[Find](https://docs.otty.sh/user-interface/find)
- 待审计：[Open Quickly](https://docs.otty.sh/user-interface/open-quickly)
- 部分：[Command Palette](https://docs.otty.sh/user-interface/command-palette)
- 待审计：[Outline / Jump To](https://docs.otty.sh/user-interface/outline)

### Workflows（6）

- 部分：[Recipes](https://docs.otty.sh/workflows/recipes)
- 部分：[Session Recovery](https://docs.otty.sh/workflows/session-recovery)
- 待审计：[Frequent Folders](https://docs.otty.sh/workflows/frequent-folders)
- 部分：[Using the CLI in your Shell](https://docs.otty.sh/workflows/cli-usage)
- 待审计：[Data Sync](https://docs.otty.sh/workflows/data-sync)
- 部分：[SSH / Remote Development](https://docs.otty.sh/workflows/ssh-remote)

### Terminal Features（17）

- 部分：[Cursor and Mouse](https://docs.otty.sh/terminal-features/cursor-and-mouse)
- 部分：[Selection](https://docs.otty.sh/terminal-features/selection)
- 部分：[Scroll](https://docs.otty.sh/terminal-features/scroll)
- 部分：[Input](https://docs.otty.sh/terminal-features/input)
- 部分：[Copy and Paste](https://docs.otty.sh/terminal-features/copy-and-paste)
- 待审计：[Autocomplete / Inline Suggest](https://docs.otty.sh/terminal-features/autocomplete)
- 部分：[Unicode and Text Styles](https://docs.otty.sh/terminal-features/unicode-and-text-styles)
- 待审计：[BiDi / RTL Text](https://docs.otty.sh/terminal-features/bidi-rtl)
- 部分：[Box Drawing](https://docs.otty.sh/terminal-features/box-drawing)
- 待审计：[Images](https://docs.otty.sh/terminal-features/images)
- 待审计：[Progress State](https://docs.otty.sh/terminal-features/progress-state)
- 待审计：[Privilege and Notifications](https://docs.otty.sh/terminal-features/notifications)
- 待审计：[Vi Mode](https://docs.otty.sh/terminal-features/vi-mode)
- 待审计：[Hint Mode](https://docs.otty.sh/terminal-features/hint-mode)
- 待审计：[Read-only Mode](https://docs.otty.sh/terminal-features/read-only-mode)
- 部分：[Shell Integration](https://docs.otty.sh/terminal-features/shell-integration)
- 部分：[$TERM and Identification](https://docs.otty.sh/terminal-features/term-value)

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

## 测试与验收

新增测试位于 `WorkspaceNavigationPolicyTests.swift` 与 `WorkspaceBehaviorTests.swift`。每完成一页，必须在本矩阵记录代码入口、失败路径和测试名称；界面视觉验收由用户执行。
