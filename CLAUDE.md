# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

Aster 是一个**纯 AppKit** 的原生 macOS 终端工作区（SwiftPM 包，非 Xcode 项目）。当前版本 0.4.1 (6)，要求 macOS 14+、Swift 6.2 工具链。`Package.swift` 的 `dependencies` 为空 —— SwiftTerm 以固定上游 revision **vendored 在 `Vendor/SwiftTerm/`** 并作为本地 target 编译（见下方「Vendored SwiftTerm」）。

## 常用命令

```bash
swift build                      # 调试构建
swift test                       # 全部测试（swift-testing，非 XCTest）
swift test --no-parallel         # 发布前必须；PTY 生命周期测试对并发敏感
swift test --filter <名称片段>    # 跑单个测试；匹配 @Test 的函数名，例如 --filter workspaceUsesOnlyNativeAppKitViews
./scripts/build-app.sh           # release 构建 + 组装 dist/Aster.app（含图标与签名）
./scripts/build-dmg.sh           # 组装并校验 dist/Aster-<版本>.dmg
open dist/Aster.app
```

发布前完整流程（见 `docs/developer/terminal-domain.md`）：
`swift test --no-parallel` → `swift build -c release` → `./scripts/build-app.sh` → `codesign --verify --deep --strict dist/Aster.app` → 实机启动验证。

`build-app.sh` 默认使用 ad-hoc 签名；正式分发通过 `ASTER_SIGN_IDENTITY="Developer ID Application: ..."` 覆盖。该脚本还会用 `qlmanage` 把 `Resources/AsterIcon.svg` 渲染成 iconset，并把 SwiftTerm 的 Metal shader bundle 复制到 `Contents/Resources`（放在 .app 根目录会破坏签名）。

## 架构分层

四个 target 的边界是本项目最重要的约束：

- **`AsterPTY`**（C）：`forkpty` 等 POSIX PTY 原语，供 `PTYShellProcess` 使用。
- **`SwiftTerm`**（vendored，Swift 5 语言模式）：VT100/xterm 网格与渲染。
- **`AsterCore`**（无 AppKit 依赖，纯值语义）：领域模型与持久化格式。除工作区本体（`WorkspaceLayout`/`WorkspaceState`/`WorkspacePersistence`/`AsterConfiguration`/`TerminalTheme`+`OttyBuiltInThemes`）外，还承载 Agent 域（`AgentState`/`AgentProvider`/`AgentComposer`/`AgentPromptQueue`/`AgentHistory`/`AgentChatContext`）、Workflow 域（`WorkflowRecipe`/`WorkflowRecipeSecurity`/`WorkflowCLI`/`WorkflowDeepLink`/`WorkflowRecovery`）、终端语义域（`TerminalInput`/`TerminalClipboard`/`TerminalActivity`/`TerminalPaneMode`/`TerminalIdentification`/`ShellIntegration`/`Autocomplete`/`DetectedTarget`）。所有类型 `Codable + Equatable + Sendable`。**测试真值都放在这里**：能写成纯函数的逻辑不要留在 AppKit 层。
- **`Aster`**（可执行，全部 AppKit）：`AsterApp.swift`（自定义 `@main` → `AsterAppDelegate`，管理多窗口与菜单）、`AppModel`（每窗口一个，持有标签与快照）、`WorkspaceViewController`（`WorkspaceView.swift`，主窗口组合根）、`SettingsViewController`（九类设置）、`TerminalSession`（SwiftTerm 的**唯一**适配边界）、`DesignSystem.swift`（`ThemeRuntime` + 动态 `NSColor` + `ThemeVisualEffectView`）。其余是无状态或单一职责的服务层：`AsterCLIRequestService`、`WorkflowRuntimeService`、`AgentIntegrationService`/`AgentSetupService`、`AutocompleteService`、`ShellIntegrationInstaller`、`WorkspaceInspectionService`、`SecureInputCoordinator`、`TerminalNotificationService`、`DockActivityCoordinator`、`TerminalTargetOpenCoordinator`、`PanePictureInPictureController`。新增能力优先加服务文件，不要继续膨胀 `WorkspaceView.swift`（已 4000+ 行）。

### 描述符与运行态必须分离

`PaneDescriptor`（可序列化，进快照）与 `WorkspacePaneRuntime`（持有 PTY、编辑缓冲区，不可序列化）严格分开。会话恢复只重建可重建状态 —— **禁止序列化 PID、文件描述符或敏感环境变量**。`TerminalTabItem` 把 Session 状态变化转发给标签视图，并把 OSC 7 当前目录写回分屏树。拖放重排/移动 Pane 只改描述符位置，**Pane UUID 必须保持不变**（ID 变了等于重建运行态，PTY 会重启）。

### AppKit 硬性规则

1. `Sources/Aster` **不得导入 SwiftUI**，不得创建 `NSHostingView`/`NSHostingController`。`AppKitMigrationTests` 会静态扫描视图树里是否出现 `NSHosting*` 类名并使测试失败。
2. `TerminalSession` 强持有唯一 `LocalProcessTerminalView`；AppKit 布局重建/标签切换**不得重启 PTY**。Session 生命周期内有稳定的终端容器视图，刷新只重新安放外层容器。
3. 递归 Pane 树用 `PersistedSplitView`（原生 `NSSplitView`）渲染，只在用户拖动分隔线时把 `0.05...0.95` 的比例写回快照。
4. 主题色只能经由 `ThemeRuntime` 的动态 `NSColor` 和 `ThemeVisualEffectView` 进入视图，**不要在视图里散落固定色值**。
5. Pane 容器在**宽和高两个方向**都需要必需尺寸约束。`NSStackView` 的固有尺寸推断会把 SwiftTerm 网格压成 0：`NSSplitView` 给每个子面板加了 `PreferredSize/FallbackSize`（`== 0 @250`）回退约束，缺高度约束时上下分屏会把整个内容区塌成一条分隔条。约束链是「内容区绑定外层 stack 宽高 → wrapper 钉 stack 底边 → 状态栏钉 inner 底边 → Pane 区填充剩余」。设置页滚动文档用 `FlippedDocumentView`（左上原点）从 `NSClipView` 顶部锚定，内部放标准 `NSStackView`——不要直接翻转 StackView，AppKit 会同时反转 arrangedSubviews 的垂直排布。
6. 切换聚焦 Pane 只做局部更新（焦点指示线 + first responder），**不触发整树重建**；Outline/Shell Integration 时间线变化也走专用事件局部刷新。

### Vendored SwiftTerm

`Vendor/SwiftTerm` 锁定 1.15.0 / revision `dd2fb8a`，补丁面（键盘与矩形选区、精确滚动与动量、非消费式 OSC 观察者、绝对缓冲坐标、只读模式的输入预检 seam、Vi Mode 的滚动不变行范围、DA1/DA2/XTVERSION 身份）逐条记录在 `Vendor/SwiftTerm/UPSTREAM.md`。**改动 vendored 源码必须**：窄范围修改 + 注释说明为什么不能在宿主层实现、补测试、同步更新 `UPSTREAM.md` 的补丁面清单。宁可扩大上游的 `open`/可见性 seam，也不要把 Aster 业务逻辑写进 SwiftTerm。

### 进程关闭语义

`TerminalRetirementCoordinator`（进程级单例，位于 `TerminalSession.swift`）在 Pane/Session 释放后继续强持有 retiring view：先 `SIGHUP` 进程组，750ms 后未退出升级 `SIGKILL`，并轮询到 SwiftTerm monitor 完成 `waitpid`。只在 `process.running` 为真且 `shellPid` 未变时发信号 —— 对已保留的旧 PID 发信号会在 PID 复用后误杀无关进程。应用整体退出走 `immediately: true`。

### 多窗口

每个工作区窗口有独立的 `AppModel` 和独立的 `UserDefaults` suite；**设置与主题库全局共享**。附加窗口 suite 只接受 `AdditionalWorkspaceWindowRegistry.prefix + UUID` 命名，最多恢复 16 个，用户主动关闭窗口时立即 `removePersistentDomain`。跨窗口拖动标签必须转移**同一个** `TerminalTabItem` 实例，不得从 snapshot 重建（会丢 PTY、滚动历史与 Agent 状态）。退出流程先确认全部窗口，再统一写快照并终止 PTY，任一取消则不得部分提交。

### 主题系统

24 套内置主题是 Otty 1.3.1 `.ottytheme` 的只读真值表。`TerminalThemeTests` 把每套主题的终端前景/背景 + ANSI 16 色压成 SHA-256 签名比对，**改动 `OttyBuiltInThemes` 的任何颜色都会让测试失败**（这是有意的：能发现漏主题、改名、错色、ANSI 顺序颠倒）。内置主题不可原位修改，编辑前先创建副本。Otty 的 `background = "none"` 保留为透明 RGBA，但因为 SwiftTerm 内部颜色无 alpha，实际栅格用主题 `surface` 预合成。


### 交互设计
所有的交互设计都需要给到用户反馈.
如:
- 鼠标放到文件列表上,文件背景色有变化;
- 鼠标放到icon 上,光标的变化;
- 鼠标点击前和点击后,对象的变化

### 外部输入的安全边界

改动导入/打开/IPC 路径时保持既有上限与授权语义：

- **文件与导入**：`.astertheme` ≤ 256 KiB；`.asterrecipe` ≤ 2 MiB，且在创建任何运行态**之前**校验标签数/Pane 数/树深度/UUID 唯一性/split ratio；编辑器单文件 ≤ 10 MiB；单个 Recipe 引用资源累计 ≤ 32 MiB。FIFO、socket、设备文件与符号链接一律拒绝。Recipe 保留 command 字段用于向前兼容，**外部 Recipe 的命令默认不执行**；确认界面必须展示完整命令集合，逐条模式在每次写 PTY 前单独授权。
- **CLI / IPC**（`AsterCLIRequestService` + `WorkflowCLI`）：私有状态目录 + `0600` token + 原子 request/response 文件；`send/run/exec` 额外要求用户开启 IPC，SSH/sudo Pane 需第二层授权。启动与轮询会回收崩溃遗留的 `.processing` 请求并返回确定失败，不得静默丢弃。
- **链接与目标打开**（`DetectedTarget` + `TerminalTargetOpenCoordinator`）：原始目标 ≤ 4096 UTF-8 字节且无控制字符；相对路径只以该 Pane 最近一次可靠 OSC 7 CWD 为基准；OSC 8 不受自动检测白名单限制但仍需授权；可执行文件与 `.app` 每次都确认；**配置导入会剥离本机安全授权**。
- **Agent 集成**：安装/卸载只改 Aster managed JSON 项、TOML marker 区块或独立 artifact，绝不覆盖用户 hook；lifecycle hook 只向所属 TTY 写有界 OSC 6974 状态，不记录 prompt、工具参数或输出；Send to Chat 先清控制字符、遮盖 secret、按 UTF-8 字节截断并包装为 `untrusted-context`，最终仍由用户确认。自定义启动命令保存为 **argv**，恢复/Fork 统一经参数编码器，不重新解释 shell 源码。
- **Shell Integration / Autocomplete**：受管 rc 区块必须幂等、可卸载、保留区块外内容与权限/符号链接，多目标先预检后写入、失败回滚。Autocomplete 只在 OSC 133 确认的可靠 prompt 中工作，接受候选只发送未输入的后缀且不自动回车；关闭本机学习时不得读历史/README 或运行 help 探测。

### 持久化

全部走 `UserDefaults`，键带版本后缀：`aster.configuration.v2`、`aster.theme-library.v1`、`aster.workspace.snapshot.v1`、`aster.workspace.{additional-window-suites,recently-closed,closed-items}.v1`、`aster.sidebar.tab-{grouping,order}.v1`、`aster.inspector.{presented,section}.v1`、`aster.frequent-folders.v1`、`aster.workflow-recipe-trust.v1`、`aster.session.{running,end-reason,crash-count}.v1`、`aster.migration.compact-sidebar.v1`。配置以单个 JSON blob 原子写入；终端相关配置改动后立即同步到已存在的终端视图（`TerminalSession.apply`）。加迁移时沿用「只迁移旧默认值、不动用户显式设置」的做法（见 compact-sidebar 迁移）。

## 测试约定

使用 swift-testing（`import Testing`、`@Test("中文描述")`、`#expect`），不是 XCTest。涉及 `AppPreferences`/`AppModel` 的测试必须用独立 `UserDefaults` suite（见 `AppKitMigrationTests` 的 `isolatedDefaults()`），不要污染 `.standard`。`AsterTests` 需要 `@MainActor`。`AppKitMigrationTests` 除 SwiftUI 扫描外还锁定了侧栏结构、设置页布局与九个分类的可交互性 —— 改这些界面时预期它会失败，应更新断言而不是绕过。

## 文档同步要求

用户可见的交互变化必须同步更新 `docs/developer/` 下对应领域文档与 `docs/user/help.md`。开发文档采用固定结构（业务背景 / 领域概念 / 核心规则 / 业务流程 mermaid / 关键实现 / 失败语义 / 测试与验收），按域拆分：`terminal-domain.md`（工作区与终端主线）、`appkit-interface.md`、`theme-system.md`、`files-and-links-domain.md`、`workflows-and-agents.md`、`terminal-activity-and-notifications.md`、`terminal-text-and-images.md`、`otty-feature-parity.md`。设计验收结论写入 **`docs/developer/design-qa.md`**（仓库根目录还有一份停留在 0.4.0 的旧 `design-qa.md`，不是真值，别往那里写）。提交信息使用 Conventional Commit 风格（`feat(workspace): ...`）；`AGENTS.md` 记录了同一套约定的英文摘要，改动规则时两边保持一致。
