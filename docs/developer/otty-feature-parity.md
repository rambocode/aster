# Otty 功能对齐矩阵

## 业务背景

Aster 以 Otty 用户文档为功能规格，目标范围是 `user-interface`、`workflows`、`terminal-features` 与 `agents` 四个栏目。本文是逐页审计入口；只有页面内全部可用行为均有实现与非 UI 功能测试时，状态才能改为“完成”。“部分”表示已有能力，但不能据此推断整页完成。

## 状态定义

- **待审计**：尚未逐段提炼规则与失败语义。
- **部分**：已存在一个或多个子能力，仍有明确缺口。
- **完成**：逐项代码证据、功能测试和用户文档齐全。

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
