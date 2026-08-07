# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## 项目概览

Aster 是一个**纯 AppKit** 的原生 macOS 终端工作区（SwiftPM 包，非 Xcode 项目）。当前版本 0.4.1 (6)，要求 macOS 14+、Swift 6.2 工具链。唯一外部依赖是 SwiftTerm（提供 VT100/xterm 网格与本地进程）。

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

三个 target 的边界是本项目最重要的约束：

- **`AsterPTY`**（C）：`forkpty` 等 POSIX PTY 原语，供 `PTYShellProcess` 使用。
- **`AsterCore`**（无 AppKit 依赖，纯值语义）：领域模型与持久化格式 —— `PaneLayout` 递归分屏树、`PaneDescriptor`、`WorkspaceSnapshot`/`WorkspaceRecipe`、`AsterConfiguration`（九个设置域）、`TerminalTheme`/`OttyBuiltInThemes`/`TerminalThemeStore`、`DocumentBuffer`、`CommandPalette`。所有类型 `Codable + Equatable + Sendable`。测试真值都放在这里。
- **`Aster`**（可执行，全部 AppKit）：`AsterApp.swift` 自定义 `@main` → `AsterAppDelegate` 管理窗口与菜单；`AppModel` 持有标签与快照；`WorkspaceViewController`（1400 行，主窗口组合根）；`SettingsViewController`（九类设置）；`TerminalSession` 是 SwiftTerm 的唯一适配边界；`DesignSystem.swift` 提供 `ThemeRuntime` + 动态 `NSColor` + `ThemeVisualEffectView`。

### 描述符与运行态必须分离

`PaneDescriptor`（可序列化，进快照）与 `WorkspacePaneRuntime`（持有 PTY、编辑缓冲区，不可序列化）严格分开。会话恢复只重建可重建状态 —— **禁止序列化 PID、文件描述符或敏感环境变量**。`TerminalTabItem` 把 Session 状态变化转发给标签视图，并把 OSC 7 当前目录写回分屏树。

### AppKit 硬性规则

1. `Sources/Aster` **不得导入 SwiftUI**，不得创建 `NSHostingView`/`NSHostingController`。`AppKitMigrationTests` 会静态扫描视图树里是否出现 `NSHosting*` 类名并使测试失败。
2. `TerminalSession` 强持有唯一 `LocalProcessTerminalView`；AppKit 布局重建/标签切换**不得重启 PTY**。Session 生命周期内有稳定的终端容器视图，刷新只重新安放外层容器。
3. 递归 Pane 树用 `PersistedSplitView`（原生 `NSSplitView`）渲染，只在用户拖动分隔线时把 `0.05...0.95` 的比例写回快照。
4. 主题色只能经由 `ThemeRuntime` 的动态 `NSColor` 和 `ThemeVisualEffectView` 进入视图，**不要在视图里散落固定色值**。
5. Pane 容器需要显式尺寸约束；`NSStackView` 的固有宽度推断会把 SwiftTerm 网格压成 0 宽。设置页滚动内容用 `FlippedStackView` 从 `NSClipView` 顶部锚定。

### 进程关闭语义

`TerminalRetirementCoordinator`（进程级单例，位于 `TerminalSession.swift`）在 Pane/Session 释放后继续强持有 retiring view：先 `SIGHUP` 进程组，750ms 后未退出升级 `SIGKILL`，并轮询到 SwiftTerm monitor 完成 `waitpid`。只在 `process.running` 为真且 `shellPid` 未变时发信号 —— 对已保留的旧 PID 发信号会在 PID 复用后误杀无关进程。应用整体退出走 `immediately: true`。

### 主题系统

24 套内置主题是 Otty 1.3.1 `.ottytheme` 的只读真值表。`TerminalThemeTests` 把每套主题的终端前景/背景 + ANSI 16 色压成 SHA-256 签名比对，**改动 `OttyBuiltInThemes` 的任何颜色都会让测试失败**（这是有意的：能发现漏主题、改名、错色、ANSI 顺序颠倒）。内置主题不可原位修改，编辑前先创建副本。Otty 的 `background = "none"` 保留为透明 RGBA，但因为 SwiftTerm 内部颜色无 alpha，实际栅格用主题 `surface` 预合成。

### 外部输入的安全边界

导入路径已有既定上限，改动时保持：`.astertheme` ≤ 256 KiB；`.asterrecipe` ≤ 2 MiB 且在创建任何运行态**之前**校验标签数/Pane 数/树深度/UUID 唯一性/split ratio；编辑器单文件 ≤ 10 MiB，单个 Recipe 引用的资源累计 ≤ 32 MiB；FIFO 与设备文件一律拒绝读取。Recipe 保留 command 字段用于向前兼容，但**不执行外部 Recipe 中的任何命令**。

### 持久化

全部走 `UserDefaults`，键带版本后缀：`aster.configuration.v2`、`aster.theme-library.v1`、`aster.workspace.snapshot.v1`、`aster.sidebar.tab-{grouping,order}.v1`、`aster.migration.compact-sidebar.v1`。配置以单个 JSON blob 原子写入；终端相关配置改动后立即同步到已存在的终端视图（`TerminalSession.apply`）。加迁移时沿用「只迁移旧默认值、不动用户显式设置」的做法（见 compact-sidebar 迁移）。

## 测试约定

使用 swift-testing（`import Testing`、`@Test("中文描述")`、`#expect`），不是 XCTest。涉及 `AppPreferences`/`AppModel` 的测试必须用独立 `UserDefaults` suite（见 `AppKitMigrationTests` 的 `isolatedDefaults()`），不要污染 `.standard`。`AsterTests` 需要 `@MainActor`。

## 文档同步要求

用户可见的交互变化必须同步更新 `docs/developer/*.md` 与 `docs/user/help.md`；这三份开发文档采用固定结构（业务背景 / 领域概念 / 核心规则 / 业务流程 mermaid / 关键实现 / 失败语义 / 测试与验收），沿用该结构。设计验收结论记录在 `design-qa.md`。
