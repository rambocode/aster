# Workflows 与 Agent 领域设计

## 业务背景

Aster 把 Otty 的工作区流程、CLI 与代码 Agent 能力放在同一安全边界内：用户可以恢复布局、重放 Recipe、从 Shell 控制 Pane，并在终端旁管理 Agent，但外部文件、历史记录和 lifecycle hook 均视为不可信输入。

> Ghostty 切换期间，公开嵌入接口无法观察原始 OSC 6974 和逐字节输入/输出；因此自动
> Prompt Queue 派发、精确 Agent 状态和 inline Autocomplete 暂停。手动发送、Composer、
> 历史、恢复/Fork 与安全 IPC 仍保留。下述 lifecycle 规则是恢复该能力时必须满足的契约。

## 领域概念

- `WorkflowRecipe`：可移植的 tab/window、Pane 树、内容级别和可选命令；不含 PID、FD 或运行对象。
- `WorkflowRecipeTrustStore`：按规范化内容 SHA-256 记录信任，不按路径授权。
- `WorkflowCLIAction`：已解析、有限大小的 CLI 意图；交付层再执行 IPC 和敏感会话门禁。
- `WorkflowSessionRecoveryPlanner`：根据正常退出、崩溃、更新和 crash loop 决定恢复行为。
- `AgentProvider` / `AgentSetupPlan`：八类 provider（含 Grok Build）的能力和最小增量安装步骤。
- `AgentTaskStateReducer`：按单调 lifecycle sequence 折叠 `processing / awaiting-input / idle`。
- `AgentComposerState` / `AgentPromptQueue`：Pane 级草稿、附件和由用户显式发送的临时 Prompt 列表。

## 核心规则

1. Recipe 导入拒绝符号链接、特殊文件、超限文本和越界资源；精确布局载荷受独立深度/字节预算约束，实例化时重建 Pane UUID。命令审查必须展示完整集合，逐条模式在每次写 PTY 前单独授权。
2. CLI 使用当前用户专属 `0600` token、私有目录和原子 request/response 文件；`send/run/exec` 还需用户开启 IPC，SSH/sudo Pane 需第二层授权。启动时及每次目录事件消费前都会鉴权回收崩溃遗留的 `.processing` 请求并返回确定失败；正常路径由 vnode 事件唤醒，只有监听建立失败时才回退到 100ms 轮询。
3. 工作区快照只保存描述符。主窗口和最多 16 个 UUID suite 附加窗口可恢复；用户主动关闭的附加窗口立即删除其 suite。退出先确认全部窗口，再统一写快照和终止 PTY，取消时不得部分提交。
4. Agent 安装/卸载只修改 Aster managed JSON 项、TOML marker 区块或独立 artifact；不得覆盖用户 hook。Codex hooks 默认启用；用户显式关闭时，安装操作只把 `[features].hooks` 改为 `true`。Aster 0.4.1 曾写入的非法顶层 `hooks` 布尔值会在下次安装时迁移，卸载不改 feature 设置。
5. lifecycle hook 只向所属 TTY 写有界 OSC 6974 状态，不记录 prompt、tool 参数或输出。
6. Send to Chat 可同时携带当前终端选区与可见 scrollback 尾部；面板只列出当前工作区中仍运行的 Claude Code/Codex Pane。每项先清除控制字符、遮盖常见 secret、按 UTF-8 字节限制，再包装为 `untrusted-context`；点击 Send 模拟键入目标输入框，不发送 Return。
7. 自定义 Agent 启动命令保存为 argv。恢复、Fork 和新建会话统一经 shell 参数编码器，不重新解释任意 shell 源码。
8. Prompt Queue 对活动终端 Pane 提供精简底部输入条，不依赖 Claude/Codex 的瞬时识别状态。普通 Return 或右下角上箭头只把草稿加入列表；写入 Agent 时按目标是否协商过 bracketed paste（DECSET 2004）选择编码，并在文本之后单独延时投递 Return。发送失败时保留该项，关闭输入条不会清空本次运行的列表或草稿。
9. 队列的常规发送路径是 lifecycle hook 驱动的自动派发：只有 hook 已成为该 Pane 的权威状态源（`hasAuthoritativeAgentLifecycle`）且报告 `idle` 时才写入队首。`processing` 期间只排队；`awaiting-input` 同样不派发 —— 它来自 PermissionRequest hook，屏幕上是权限确认选择器，回车等于替用户批准一次工具调用。未安装 hook 时，命令启动、用户输入和 PTY 输出只在 5 秒静默窗口内作为回退 processing 证据；输出探针推断出的 idle 只清除 UI 徽章，不参与派发，避免打断运行中的 TUI。
10. 写入 Agent 输入框的编码由目标决定，不由调用方强制：`AsterTerminalView.typePromptText` 读取 `terminal.bracketedPasteMode`，协商过就按粘贴块投递，未协商才发裸 UTF-8。Claude Code / Codex 的输入框协商 2004 后会把裸字节流按逐键解释，`/`、`@`、方向键和候选列表会吃掉内容，表现为“点了发送但输入框没变化”。Prompt Queue 的 Return 在文本之后延时 60ms 单独发送 —— 同批到达的 CR 会被算进粘贴内容变成换行，只换行不提交。
11. 自动派发严格单 in-flight：派发后必须观察到该轮从 `processing`/`awaiting-input` 回到 `idle` 才发下一条，防止多条 prompt 挤进同一轮对话。写入失败时 `restoreInFlight()` 把 prompt 放回队首并释放锁。每项左侧的发送图标是用户显式插队通道，不受 in-flight 锁与 hook 权威性限制。
12. Agent 会话标题投影：Pane 经 OSC 6974 精确绑定 provider + session ID 后，`AppModel.refreshAgentSessionTitles` 从已扫描历史匹配会话标题（清洗后仍等于文件名视为无标题），投影到标签行展示名与标题栏胶囊；用户固定标签名优先级更高。禁止目录/最近历史等松散匹配 —— 会把别的会话标题标到当前 Pane。标题是运行态，不进快照；未命中时按 5 秒节流触发一次历史重扫（transcript 在首条 prompt 后才出现）。更新走 `titleChanged` 局部通道，不进 `objectWillChange`。
13. 历史会话以标签承载（Otty 对齐）：Agent 历史浮层的 `↩`/「打开」调用 `AppModel.openAgentTranscriptTab`，经 `openResource(.view, .newTab)` 的安全校验开只读 transcript 预览标签，标签名写入清洗后的会话标题（`.name` 覆盖，随快照恢复）；同一 transcript 已有标签时只聚焦不重建。Resume / Fork 仍是显式动作，分别在浮层 footer 与 transcript 页头提供。transcript 正文由 `AgentTranscriptHTML` 在主线程外拼装、在与 Markdown 预览同源的加固 WKWebView（无 JS、CSP 锁死、无网络）中渲染：用户消息转义进卡片、assistant 消息走 swift-markdown HTMLFormatter、连续 toolCall/Reasoning/System 折叠为原生 `<details>` 摘要；单条 4,000 / 总量 400,000 字符双重上限，超限显式标注。禁止回到逐条 NSTextField 的实现——大会话会卡死主线程。
14. Shell 菜单的 Agent 子菜单只读取当前窗口、当前标签、当前聚焦 Pane 的 `activeAgentProvider` 与 `activeAgentSessionID`，并在 `menuNeedsUpdate` 时重建。不得回退到同标签其它 Pane、窗口聚合状态或最近历史。provider 已识别但 session ID 尚未关联时保留身份与历史入口，复制和 Fork 明确禁用；支持 Fork 后可选择四向分屏、新标签或新窗口。子菜单的「查看会话历史」经 `AppModel.presentAgentHistory(scopedTo:)` 打开历史浮层并**过滤到当前项目**：项目目录优先取已绑定会话在历史里的归属（provider + session ID 精确匹配），尚未关联时退回该 Pane 工作目录；匹配用 `AgentSessionMetadata.belongsToProject`（两侧经 `normalizedAbsolutePath` 归一化后等值比较，归一化失败一律不匹配）。过滤范围随每次呈现重设——命令面板等无参入口（`presentAgentHistory()`）显示全部历史；浮层内搜索也只在过滤后的集合内进行。全局 Shell 菜单的「Agent 历史」条目已移除。

## 业务流程

```mermaid
flowchart LR
  A[Recipe / CLI / Agent UI] --> B[Parser and Planner]
  B --> C{Security gate}
  C -->|Recipe hash trust| D[Idle prompt replay]
  C -->|IPC plus sensitive opt-in| E[Pane action]
  C -->|Managed ownership| F[Agent config transaction]
  F --> G[Lifecycle OSC 6974]
  G --> H[Agent state reducer]
  H --> I[Badge / notification / queue / sleep activity]
  D --> J[OSC 133 completion]
  E --> J
```

## 关键实现

领域代码位于 `Sources/AsterCore/Workflow*.swift` 与 `Agent*.swift`。`WorkflowRuntimeService` 负责 Recipe 普通文件读取和 TOML 交付；`WorkflowRecipeWorkspaceMapper` 在完整 `PaneLayout` 上转换可移植路径，并为每次实例化重建运行身份。`AsterCLIRequestService` 负责鉴权传输和中断请求恢复；`AppModel.executeWorkflowCLI` 执行已验证意图，并等待 OSC 133 返回真实退出码。`AdditionalWorkspaceWindowRegistry` 限制附加窗口恢复域，跨窗口标签转移直接移动 `TerminalTabItem`，保留 PTY 与滚动历史。

`AgentSetupService` 对所有目标先做祖先 symlink、文件类型、大小、格式和竞争变化检查，再原子写入；失败按相反顺序回滚。`Resources/agent-integration/aster-agent-hook.sh` 与生成的 plugin/extension 只上报生命周期，以及 provider 明确提供时由 ASCII 白名单和 128 字节上限约束的 `SessionID`；Codex/Claude command hook 的 stdin JSON 最多读取 256 KiB，只通过系统 `plutil` 提取顶层 `session_id`，prompt、tool 参数和输出不会进入 OSC。Grok Build 与 Claude Code 共用 `~/.claude/settings.json`：hook 根据 `GROK_HOOK_EVENT` / `GROK_SESSION_ID` 判断调用方，对不上就排空 stdin 后退出；Grok 的 session id 优先取注入的 `GROK_SESSION_ID`。`AgentHistoryDiscoveryService` 有界读取已知 provider 路径；Resume/Fork 由 `AgentSessionCommandPlanner` 保留 provider、model 和 system prompt 元数据。`FocusedAgentSessionContext` 冻结菜单动作所需的 provider、session ID 和 CWD，菜单载荷同时保留展开菜单时的工作区模型，防止菜单跟踪期间 key window 变化后把 Fork 路由到其它窗口；`AgentContinuationPlacement` 把 Fork 明确路由到当前新窗口 Pane、新标签或指定方向分屏，新 PTY 就绪后才发送 provider 原生命令。

设置页的 CLI 探测不假设 GUI 进程继承登录 shell 的 `PATH`。它先保留现有 PATH
顺序，再有界补查 `~/.local/bin`、Homebrew、nvm/fnm、asdf、mise、Volta、Bun 与
pnpm 的常见 bin 目录；不会启动登录 shell 或执行用户 rc 文件。快照下发探测到的
绝对入口路径，且 CLI 路径与 Aster managed lifecycle 集成状态分别呈现：切换 Node
版本造成 CLI 暂不可见时，已经存在的受管集成不会被误报为未安装。

内置 `AsterNerdSymbols-Regular.ttf` 以进程级 CoreText 注册，并作为终端基础字体 cascade fallback；来源和许可证见 `THIRD-PARTY-NOTICES.md`。

### Project Memory MCP

`aster-memory-mcp`（target `AsterMemoryMCP`）是独立可执行文件，通过 stdio JSON-RPC 2.0 把
Session Memory 暴露给任何支持 MCP 的 Agent，协议版本 `2025-06-18`。它以
`SQLITE_OPEN_READONLY` 打开数据库，**Aster 未运行时同样可查**；打开时用
`PRAGMA user_version` 与 `MemorySchema.currentVersion` 握手，不匹配返回结构化 `isError`
而不是崩溃。领域与存储契约见 [Session Memory 与 Context 领域](session-memory-domain.md)。

P0 工具：`search_memory`、`get_project_context`、`get_session`、`get_related_history`、
`get_task`、`get_recent_commands`。`project_path` 缺省取 MCP 进程的 `getcwd()`
（Claude Code / Codex 都在项目根目录 spawn server），传 `"*"` 表示跨全部项目。
参数经 `MCPArguments` 限长与 UUID 校验，输出经 `MCPRenderer` 清除控制字符并施加总长上限。

每次成功的 `tools/call` 由 `ContextReceiptWriter` 追加一条 `ContextReceipt`
（`trigger=agent_query`、`delivery=mcp`）。这是单写者约定的**唯一例外**：短生命周期读写
连接、只触碰 `context_receipts` 一张表、失败静默——留痕失败绝不能让 Agent 的查询失败。

`MCPInstallService` 负责注册：读-改-写项目的 `.mcp.json`，**只管理 `aster-memory` 一项并
保留用户已有的其它 server**，原子发布，拒绝符号链接与非普通文件（沿用
`AsterCLIRequestService` 的 `O_NOFOLLOW` + `fstat` 校验范式）。可执行文件优先取 app bundle
内路径，SwiftPM 调试环境回落 `.build`。Codex 侧只生成需要用户自己粘贴的配置文本，
**不自动修改 `~/.codex/config.toml`** —— 与 Agent 集成安装同样的所有权边界。

> 路径陷阱：`URL.resolvingSymlinksInPath()` 在解析符号链接之后还会去掉开头的 `/private`，
> 因此它与子进程 `getcwd()` 的结果不相等。跨进程比较路径必须用 `realpath()`。
> 生产路径本身一致（录制侧用 git toplevel、MCP 侧用 getcwd，都是物理路径），
> 只有测试构造临时目录时会踩到。

## 失败语义

- 无法验证 Recipe、CLI token、Agent 配置所有权或文件身份：拒绝操作，不做部分写入。
- CLI 目标 Pane 不存在、未空闲、输出超限或无权限：返回非零退出码和 stderr；不隐式选择其它 Pane，也不把读取失败伪装成空成功。
- Agent hook 缺失：退化为进程/提示检测，不伪造精确状态；Shell 菜单可以显示已识别的 provider，但在没有可信 session ID 时禁用复制与 Fork。
- Agent 历史损坏或超限：跳过该记录，其它 provider 仍可使用。
- Agent 历史的列表标题由 `AgentSessionTitleCleaner` 从用户消息序列推导：caveat/系统提醒等
  模板包装段整段丢弃，内容型标签只剥壳保留内文，全部为噪音时回落 transcript 文件名——
  provider 注入的 XML 风格包装串不得泄漏到历史列表。浮层 chrome（圆角/描边/layer 投影）
  与命令面板、Open Quickly 保持同一套。
- 窗口创建失败：CLI 返回失败；跨窗口标签移动会把原 Tab 放回源模型。

## 测试与验收

纯领域测试覆盖 Recipe TOML/信任、CLI 解析、恢复策略、Agent provider/状态/Composer/队列/上下文与窗口 suite 规范化；AppKit 目标测试覆盖文件传输、Agent 安装卸载、lifecycle、跨标签聊天目标、Shell 菜单随 Pane 焦点切换、Fork 落点与跨窗口路由、预填边界和 AppModel 路由。发布前运行 `swift test --no-parallel`、warnings-as-errors 构建、App 打包与签名验证。按项目要求不执行 UI 自动化，视觉清单见 `docs/developer/design-qa.md`。
