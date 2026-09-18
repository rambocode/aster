# 开发约定

改代码前先看这一页：架构边界、代码组织、版本号、提交信息、文档同步与验证要求。
本文沿用 Glimmer 开发约定的组织方式，按 Aster 的 SwiftPM / AppKit 技术栈适配；具体领域设计以 [developer/](developer/) 中的对应文档为准。

## 架构约束（不要违反）

- **领域模型与 AppKit 解耦。** `Sources/AsterCore` 放工作区、会话、配置及协议等可复用模型和规则，不依赖 AppKit、GhosttyKit、Sparkle 或应用 UI。现有 PTY 与 Markdown 依赖遵循 `Package.swift` 的 target 边界，不把 Core 当成任意基础设施的入口。
- **应用层负责协调与呈现。** `Sources/Aster` 使用 AppKit，不引入 SwiftUI。窗口、视图和控制器负责事件转换、校验、编排与渲染；可复用业务规则下沉到 Core，存储与外部系统调用通过明确接口隔离。
- **终端引擎桥接集中管理。** Ghostty 桥接保留在 `Sources/Aster/Ghostty`；PTY 原语在 `Sources/AsterPTY`。产品终端使用 Ghostty，SwiftTerm 仅作为迁移期回归适配器，不重新挂入产品工作区。生命周期与 ABI 约束见 [Ghostty 终端引擎](developer/ghostty-terminal-engine.md)。
- **存储、查询与控制分开。** `AsterMemory` 负责 SQLite 编解码与文件布局，领域模型留在 Core；`AsterMemoryMCP` 保持只读查询；`AsterCLI` 通过既有协议控制应用，不依赖 AppKit。细节见 [会话记忆](developer/session-memory-domain.md) 与 [工作流和代理](developer/workflows-and-agents.md)。
- **输入与渲染不能被辅助功能阻塞。** 网络、数据库与耗时计算不能占用主线程；异步结果按发起时的会话或 Pane 身份回写，处理取消、超时、关闭和过期响应，避免切换焦点后写入错误会话。
- **状态只有一个权威来源。** 设置、会话与更新状态遵循现有归属，不为 UI 方便建立第二份可写副本。Sparkle 只通过更新服务边界接入，不在视图中直接调用 SDK；规则见 [软件更新](developer/software-update.md)。

## 代码组织

- **一个主要类型一个文件。** `struct`、`enum`、`class`、`actor`、`protocol` 按主要职责拆分；只服务于该类型的小型辅助类型可同文件或嵌套定义，不为机械满足数量而增加文件。
- **按领域组织目录。** 新增或重构同一概念的一组文件时收进对应功能目录，相关实现与专用类型放在一起；遵循现有 target 边界，不因本次功能批量移动存量文件。测试在 `Tests/` 下对应 target 中按功能组织。
- **大类型按职责拆分。** 优先提取独立协作者；确需拆分同一类型时使用 `extension`。跨文件扩展不能访问原文件的 `private` / `fileprivate` 成员，不得为拆文件无依据扩大到 `public`；需要共享的实现保持最小可见性，并说明边界。
- **控制文件长度。** 新增文件目标 500 行以内，原则上不超过 800 行；接近上限时按职责拆分。存量超长文件在相关改动中渐进治理，不做无关拆分。测试独立放在 `*Tests.swift`，超过 200 行时优先按行为主题拆分。
- **遵循 Swift 导入与访问控制。** 使用明确的 `import Module`，测试需要内部 API 时使用 `@testable import`；不通过隐式导出扩大依赖。默认 `internal`，优先 `private` / `fileprivate`，仅跨模块必需的 API 使用 `public`。
- **不修改生成产物。** Ghostty XCFramework、生成资源与构建产物由脚本生成；第三方源码改动必须同步来源版本、补丁说明及对应测试。

## 命名与注释

- 两空格缩进；类型用 `UpperCamelCase`，成员、变量与函数用 `lowerCamelCase`。Swift 文件按主要类型或领域命名，延续仓库现有惯例；测试文件使用 `*Tests.swift`。
- 标识符用英文，注释和开发文档用中文。UI 文案进入既有本地化机制，简体中文为源语言，不在业务代码中散落不可翻译的字符串；见 [界面本地化](developer/interface-localization.md)。
- 新文件用简短 `//` 文件头说明职责；公共 API 用 `///` 说明输入、输出、失败语义及必要的并发约束。字段含义或单位不明显时补充说明，不为显然含义重复注释。
- 使用有语义的 `// MARK: -` 分组，不添加 `// ====` 等装饰性分隔线。不要求属性之间机械空行，按相关性分组并遵循周围格式。

## 依赖、并发与配置

- SwiftPM 依赖在 `Package.swift` 声明，解析结果由 `Package.resolved` 锁定；版本策略沿用现有依赖约定。增加依赖前确认标准库、系统框架及现有模块不能满足需求。
- 遵循 Swift 6.2 的隔离与 `Sendable` 检查。AppKit 状态在 `@MainActor` 上操作；跨隔离边界传递安全值，不用 `@unchecked Sendable`、`nonisolated(unsafe)` 或降低语言模式掩盖并发问题。必要的底层桥接例外必须有同步机制、解释与测试。
- 失败通过明确的 `Error` 类型与 `throws` 或现有结果模型表达，不用 `try?`、空 `catch` 或强制解包掩盖可恢复错误。任务、观察者、定时器、文件描述符与 C 回调的释放必须和所有权、生命周期对应。
- 配置与快捷键接入既有配置、校验和命令路由，不在视图中另建真值或散落键码。日志沿用所在模块的机制，不输出密钥、令牌及不必要的用户终端内容。

## 版本号

- 应用版本以 `Resources/Info.plist` 为准：`CFBundleShortVersionString` 表达语义版本，`CFBundleVersion` 使用跨 stable / preview 通道共享的全局单调整数。
- 每次发布的 `CFBundleVersion` 必须大于所有已发布版本，不得复用或按通道单独计数；Sparkle 依赖它判断更新。
- 标签使用 `v<版本>`；预览版按 `0.5.0-preview.1` 形式表达并通过发布脚本的 `--preview` 指定。不要将预览后缀写进 `CFBundleVersion`，也不要套用其他项目的 `-dev` 或平台前缀标签规则。
- 普通开发修改不自动升版本；发布通过 `scripts/release.sh` 统一处理，细节见 [软件更新](developer/software-update.md)。

## 提交信息

- 使用 Conventional Commits：`<类型>(<范围>): <说明>`。类型与范围英文小写，人工编写的说明用中文，例如 `fix(workspace): 修复切换 Pane 后的选择状态`、`docs(contributing): 补充 Swift 开发约定`。保留发布脚本生成的既有格式。
- 类型：`feat` 新功能、`fix` 缺陷、`docs` 文档、`refactor` 不改行为的整理、`perf` 性能、`test` 测试、`build` 构建、`ci` 持续集成、`chore` 维护、`style` 格式、`revert` 还原。
- 范围按实际领域选择，如 `core`、`workspace`、`terminal`、`ghostty`、`memory`、`mcp`、`cli`、`settings`、`ui`、`packaging`、`release`；跨领域可省略。不兼容改动使用 `!` 并说明迁移方式。
- 一个提交只做一件事；正文解释原因与取舍，不加 AI 署名，不重写历史提交。提交、推送与发版需有对应任务授权。

## 文档同步

- 领域背景、概念、核心规则、流程与关键实现写在 `docs/developer/` 对应页面；复杂的新功能补用户帮助，不把细节堆进 README。
- 用户可感知的按键、菜单、设置、文件布局或行为变化，同一提交更新 [用户帮助](user/help.md) 与对应开发文档；本地化变化同步翻译表。
- 协议、持久化、第三方补丁或发布方式改变时，同步兼容性、迁移与验证说明。文档与实现有分歧时，核实预期后使两者一致，不把规划写成已实现能力。
- 发布前准备 `docs/release-notes/<版本>.md`；不套用来源项目的目录、CHANGELOG 或贡献限制。

## 提交前检查

- 先检查 `git worktree list` 与 `git status --short`，确认当前任务归属并保留其他改动；提交前核对暂存差异、忽略规则和敏感信息边界。
- 开发环境要求 macOS 14+、Swift 6.2、Zig 0.15.2 与 Xcode Metal Toolchain。Ghostty 依赖通过 `./scripts/setup-ghostty.sh` 准备，使用 `swift build` 验证构建。
- 测试使用 Swift Testing（`import Testing`、`@Test`、`#expect`），不新增 XCTest 用例。AppKit 测试通常标记 `@MainActor`；偏好设置测试使用独立 `UserDefaults` suite。
- 代码改动先运行 `./scripts/test.sh --filter <name>` 定向验证，提交前运行 `./scripts/test.sh --no-parallel` 全量检查。必须使用封装脚本，以提供 Sparkle 动态库路径与 AppKit 测试宿主；检查最终测试汇总，不能只看退出码。详见 [测试执行与完整性审计](developer/testing.md)。
- 纯文档改动检查链接、命令与 `git diff --check`，不为文案新增测试或运行无关应用构建。其他改动按影响执行静态检查、资源检查与实际环境验收；跳过或未运行的检查必须说明。
- 打包相关改动运行 `./scripts/build-app.sh`，必要时运行 `./scripts/build-dmg.sh`。图标栅格化依赖 `rsvg-convert`（`brew install librsvg`），不使用会引入不透明背景的替代输出。
- UI 变更提供适用的截图或录屏；单元测试通过、应用已安装与真实交互验收是不同状态，分别报告。

## CI 与发版

- 当前仓库没有 `.github/workflows/`，不假定存在自动 CI、提交钩子或标签触发发布；本地检查仍需实际执行。新增自动化时再将对应入口与门禁写入本文。
- 发布入口为 `./scripts/release.sh --short <version> --bundle <int>`，预览版追加 `--preview`。脚本要求干净的 `master`、与 `origin/master` 同步、标签未存在、发行说明齐全且构建号递增。
- 发布脚本会修改版本、提交并推送、构建签名公证包、创建 GitHub Release 和更新 appcast；只有获得发布授权后才能执行。
- 必须先上传 DMG，再发布指向它的 appcast；每次 appcast 生成使用仅含当次 DMG 的 staging 目录，避免改坏历史下载链接。
- 签名身份与公证配置通过 `ASTER_SIGN_IDENTITY`、`ASTER_NOTARY_PROFILE` 等既有环境变量提供；Sparkle EdDSA 私钥留在登录钥匙串，不导出进仓库。`.build/`、`dist/`、生成的 Ghostty 资源及 XCFramework 保持未跟踪。
- 发版验收覆盖签名、公证、安装包、Release 资产和 appcast；本地构建成功不能代替远端发布成功。完整流程与失败恢复以 [软件更新](developer/software-update.md) 和发布脚本为准。

## 外部 PR

- 从 `master` 开分支，一个 PR 聚焦一个问题；进入 feature worktree 后，同一任务的实现、测试和提交持续在该 worktree 完成。
- PR 说明行为与架构影响、关联问题和实际验证命令；UI 变化附截图或录屏，签名、第三方代码、持久化及兼容性变化需明确指出。
- 保留贡献者署名；合并方式遵循维护者要求，不引入其他项目的平台拆分或暂不接受某类功能的限制。
