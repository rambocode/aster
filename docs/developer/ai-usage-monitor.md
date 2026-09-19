# AI 用量监控

## 背景与范围

在系统状态栏常驻一个图标，点开是一个浮动窗，显示三件事：订阅配额、本机 token 用量、
正在跑的 Agent 会话。功能思路来自 [jettoai/tally](https://github.com/jettoai/tally)（MIT）；
token 统计内核从它移植，其余按 Aster 已有能力重做。

这是**非核心功能**。它不改终端输入、渲染与 PTY 路径，默认关闭
（`agents.usageMenuBarEnabled = false`）。

不做的部分：tally 的多账号选号启动、触顶自动换号、supervisor、PATH shim、statusLine 注入。
Aster 本身就是承载 Agent 的终端，这些编排不属于「监控」。

## 规则

1. **关着就是零**。开关关闭时 `UsageMonitorCoordinator` 与 `UsageSessionBoardAdapter`
   都不存在，没有订阅、轮询和状态栏图标。
2. **浮动窗关着只剩配额轮询**：每 300 秒一次，Claude 是一个 HTTP 请求，Codex 是一次
   `codex app-server` 子进程往返（几十毫秒 CPU）。token 扫描与进程采样完全不跑。
   状态栏红点由已有的 Agent 状态事件驱动，不加 timer。
3. **页面不可见零开销**。每页实现 `UsageSectionController`：`suspend()` 之后不得留下任何
   任务、订阅或定时器。不用常驻 `Timer`，一律「单次延迟 Task 自续 + cancel」，
   迟到结果用 generation 校验丢弃。
4. **配额只有一条请求时间线**。浮动窗不另起配额服务，只给 `ClaudeAccountQuotaService.shared`
   加被动引用。有 Claude Pane 时仍是 90 秒一档；只有被动引用时 300 秒一档；换档不多发请求
   （`refresh` 在任何 `await` 之前先写 `lastFetchAt`，后到的请求必被 90 秒最小间隔挡掉）。
5. **不另建会话状态**。看板读 `AsterControlBridge` 的现有投影，状态仍以
   `AgentControlStatusMapper` 为准。
6. **不进 `TerminalTabItem.objectWillChange`**。状态栏与各页只在值变化时重绘。
7. **只读、不读正文**。token 数据源只取数字、时间戳与工作目录，全部只读本机文件，不联网。
   对外只有配额这一条路：Claude 官方 `/api/oauth/usage`、`codex app-server`、Cursor 的
   `api2.cursor.sh`、以及 Antigravity 在 `127.0.0.1` 上的本地服务；除此之外不发任何网络请求，
   也不写任何 Agent 的配置。各家的凭据只在内存里存活到用完，不落盘、不进日志、不进诊断字段。

## 数据来源

### 配额

| 账号 | 来源 | 刷新 |
|---|---|---|
| Claude | `ClaudeAccountQuotaService`：官方 `/api/oauth/usage`，凭据取自 Claude Code 的钥匙串项 | 被动 300 秒；有 Claude Pane 时 90 秒 |
| Codex | `CodexAppServerQuotaClient`：起 `codex app-server`，JSON-RPC over stdio 问 `account/rateLimits/read` | 被动 300 秒；打开配额页时按 60 秒节流补一次 |
| Codex（兜底） | `CodexAccountQuotaReader`：`~/.codex/sessions/YYYY/MM/DD` 按目录名倒序找最新 `rollout-*.jsonl`，读尾部 64 KiB，复用 `CodexRolloutUsageParser` | 仅在 app-server 不可用时 |
| Cursor | `CursorAccountQuotaClient`：从 Cursor IDE 的 `state.vscdb` 读 `cursorAuth/accessToken`，POST `api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage` | 被动 300 秒 |
| Antigravity | `AntigravityQuotaClient`：找它自己的 `language_server` 进程拿 CSRF token 与监听端口，POST 本地 `RetrieveUserQuotaSummary` | 被动 300 秒；服务没跑就没有卡片 |

**Codex 必须以 app-server 为准**。rollout 只记录本机某个会话最后一次响应时的值：别的设备、别的会话、
之后的消耗它都看不到。2026-09-19 实测同一时刻 rollout 显示每周 84%、app-server 显示 100%。
rollout 只在 `codex` 可执行文件找不到、版本太旧不认识 `app-server`、或调用失败时兜底。

窗口种类按 `windowDurationMins` 判定（≥1440 分钟为每周），不按 `primary` / `secondary` 的位置——
不同套餐的两个位置含义不同。只保留账号级窗口，丢掉 `session`（那是某个会话的上下文占比）。
兜底路径下已过重置时刻的窗口按 0 显示并注明「等 Codex 下次运行后更新」：本机没跑 Codex 就没有
新消耗，0 是准确值；直接丢弃会让整行消失，看起来像功能坏了。

**订阅档位**（`UsageAccountSnapshot.plan`）跟着配额一起取，各家叫法不同，原样展示：
Claude 读钥匙串凭据里的 `rateLimitTier`（`default_claude_max_20x` → `Max 20x`），退到
`subscriptionType`；Codex 读 `rateLimits.planType`（`pro` → `Pro`）。拿不到就不显示徽标。

**Cursor 与 Antigravity 走的是私有接口，随时会变**，所以失败一律静默降级成「没有卡片」，
不弹窗、不抛错、不重试：
- Cursor 的凭据库有 1 GB 且 Cursor 开着时是 WAL 模式。用 plain `SQLITE_OPEN_READONLY`
  （复用 `ReadOnlySQLiteDatabase`），**不要加 `immutable=1`**——实测它会跳过 `-wal` 读到过期
  快照，连表都看不见。只取需要的两个 key，不遍历全表。`billingCycleEnd` 是**毫秒**，而且实测
  返回的是 JSON **字符串**不是数字，两种都要接。窗口用 `.billingCycle`——它是按月结算周期，
  套 `.weekly` 会让「多久后重置」差出几周。档位取 `cursorAuth/stripeMembershipType`。
  注意 `totalPercentUsed` 的分母不是 `planUsage.limit`（实测 5.00% 对应 $24.76/$495，而 `limit`
  是 $20 的套餐内额度），所以卡片上的补充说明只讲已花金额，不讲比例，免得读成超额扣费。
- Antigravity 的配额没有任何离线缓存，只能实时问它自己起的本地服务，所以
  **Antigravity.app 或 `agy` 没在跑时就读不到**。CSRF token 在那个进程的命令行参数里；端口靠
  `lsof` 列它的监听 socket，不扫端口。自签证书只对 `127.0.0.1` 放行。已知 agy ≥ 1.2.2 起该端点
  要求 CSRF 且不再暴露 token，社区工具普遍受影响——这也是静默降级的一种。
  响应给的是 `remainingFraction`（剩余比例），要反算成已用百分比；一个账号可能有很多模型桶，
  按已用降序只留 4 条，面板放不下更多。
  **只有 Antigravity.app 这条能指望**：`agy` CLI 从 1.2.2 起强制校验 CSRF 且不再把 token 放进
  命令行（本机是 1.2.7），所以 CLI 起的那个服务读不到；App 仍会在 argv 里带 `--csrf_token`。
  IDE 版的 `RetrieveUserQuotaSummary` 会 404，靠两个回退端点兜。
  **不做** `cloudcode-pa.googleapis.com` 的 OAuth 直连兜底，两个理由，第二个是实测的：
  一是它要用 Antigravity 自己的 OAuth client id/secret（社区做法是从二进制里逆向扒出来再
  硬编码），把另一家的客户端密钥放进签名公证的发布产物，性质已经不是「只读用户已有凭据」；
  二是 2026-09-19 用本机钥匙串里的 Antigravity token（`service=gemini` / `account=antigravity`，
  值带 `go-keyring-base64:` 前缀）实测 `v1internal:retrieveUserQuotaSummary`，返回
  `403 PERMISSION_DENIED` / `SUBSCRIPTION_REQUIRED`（"You do not have a valid license of this
  product"，domain `cloudaicompanion.googleapis.com`）。该账号 agy 日常可用，说明个人版的
  配额压根不由这个企业向端点提供。**这条路已经验证过走不通，不要再试。**
  **端点刻意不缓存**：定位是一次 `ps`（找不到进程就此结束）加最多一次 `lsof`，实测约 32 毫秒，
  摊到 300 秒一轮可以忽略；而缓存住「没找到」会让用户刚打开 Antigravity 后迟迟看不到卡片，
  缓存住旧端口则会在它重启后一直打错地方。

两家的失败都不区分原因（未授权、超时、网络错误一律当作取不到）。用户没登录 Cursor 时
`credentials()` 直接返回 nil，压根不会发请求；只有 token 存在但已失效这一种窄情况会每
300 秒白打一次，代价可以忽略，不值得为它引入一套带状态的失败枚举。

其余 Agent 没有把订阅配额落到本地，只能联网调各家私有接口，不做。

### Token 统计

`TokenUsageSource` 协议（`Sources/AsterCore/TokenStats/TokenUsageSource.swift`）抹平各家格式。
四列统一口径：`input` 不含缓存命中，`output` 含 reasoning。下表的口径结论都在本机真实数据上
用各家自带的 total 字段闭合验证过。

| Agent | 位置 | 记录 | `input` 含 cache | 备注 |
|---|---|---|---|---|
| Claude Code | `~/.claude/projects/**/*.jsonl` | `message.usage.*` | 否 | 同一 `message.id` 多行重复 usage，按列取历史最大值增量计 |
| Codex | `~/.codex/{sessions,archived_sessions}/**/rollout-*.jsonl` | `token_count` 的 `total_token_usage` | 是，要减 | 会话累计值，取相邻差分；任一列变小视为计数器重置 |
| Pi | `~/.pi/agent/sessions/<slug>/*.jsonl` | `message.usage.*` | 否 | 每轮增量；`cwd` 在首行 `session` 记录；按记录 `id` 去重 |
| Grok | `~/.grok/sessions/<urlenc-cwd>/<id>/updates.jsonl` | `turn_completed` 的 `usage` | 是，要减 | `task-completed-*` 回合**保留**：它与主回合的模型调用不重叠，二者之和等于事件日志里的循环数 |
| Gemini CLI | `~/.gemini/tmp/<项目>/chats/session-*.{jsonl,json}` | `tokens.*` | 是，要减 | `thoughts` 并入 output，`tool` 并入 input；项目路径读同级 `.project_root` |
| droid | `~/.factory/sessions/<id>.settings.json` | `tokenUsage.*` | 否 | 会话累计、无 `cwd`：按文件 mtime 归日，项目记「其他」 |
| OpenCode | `~/.local/share/opencode/opencode.db` | `message.data` 的 `$.tokens.*`，只算 assistant | 否 | 只读打开；不读 `part` 表（与 message 重复）；db 与 `-wal` 合成一个缓存身份 |
| Hermes | `~/.hermes/state.db` | `sessions` 表 | 按列名 | 表空、无表、无 db 都静默返回空 |

Cursor、Antigravity 的 transcript 没有 token 字段或是 protobuf；Copilot、Qwen、Kiro、Qoder、
omp 等本地没有用量数据。不做。各家只统计 token，不换算金额（只有部分 Agent 有 cost 字段，
口径不齐）。

**性能**。`JSONScan` 是手写浅层字节扫描器：一行 transcript 带着整个回合的正文，要的只有几个
整数，不用 `JSONDecoder`。`TokenLineReader` 用 `mmap` + `memchr` 切行 + `memmem` 预筛。
`TokenStatsEngine` 按 `(size, mtime)` 跳过没变的文件；缓存带版本号与时区，任何一个变了就整体
作废（bucket 的 `day` 是本地日）。解析或归因规则每次变化都要把
`TokenStatsCache.currentVersion` 加一。

**项目归属**（`TokenProjectResolver`）：从 `cwd` 向上找 `.git`；是目录就是项目根；是文件
（git worktree）就折回主仓库；找不到就用 `cwd`。没有移植 tally 的 `TokenProjectMap`，
它依赖作者本人的 `~/workspace` 目录惯例。

**扫描时机**（`TokenStatsService`，actor）：只在 Token 页可见时触发，从不定时。首次冷扫要读
几 GB 语料，跑在 `utility` 优先级，逐文件检查取消；取消时把半成品缓存落盘，下次接着扫。
缓存在 `~/Library/Caches/<bundle id>/token-stats.v1.json`。

### 会话看板

`UsageSessionBoardAdapter` 订阅 `AsterControlEventHub` 的 `pane.*` 事件，把一批事件合并成一次
评估，列表真的变了才通知（`pane.updated` 会随终端标题频繁到达）。控制 socket 没起来的第二
实例没有桥，看板为空，配额与 Token 页照常可用。

进程占用：`ProcessFootprintSampler` 用 `proc_listallpids` + `proc_pidinfo` + `proc_pid_rusage`
读全机进程（约 600 个进程一次 2 毫秒），不 shell out。`ProcessFootprintCalculator` 以 Pane 的
登录 shell 为根做 BFS；CPU 只统计两次采样都在的进程。只在「会话」页可见且有卡片时每 3 秒采
一次。两个容易踩的坑：`proc_listallpids` 第二次调用返回的是 **pid 个数**不是字节数；CPU 时间是
mach 绝对时间单位，Apple Silicon 上换算系数不是 1。

卡片**座位冻结**：页面打开期间，已有卡片不因状态变化换位，否则正要点的卡会从手底下跑掉；
只在页面重新打开时按 blocked → working → done → idle → unknown 重排。

## 实现与边界

| 层 | 位置 | 职责 |
|---|---|---|
| Core | `Sources/AsterCore/TokenStats/` | 扫描器、六个 JSONL / JSON 数据源、引擎、汇总、热力图 |
| Core | `Sources/AsterCore/Usage/` | 账号快照、状态栏摘要、进程占用算术、看板排序 |
| 应用 | `Sources/Aster/Usage/` | 协调器、状态栏条目、浮动窗、三页、配额发布点、采样器、看板适配器 |
| 应用 | `Sources/Aster/Usage/Sources/` | 两个 SQLite 数据源（Core 不引 SQLite） |

`UsageQuotaStore` 把 Codex / Cursor / Antigravity 统一成 `PolledSource`：各自持有取数体、
在途标志、上次成功时刻、世代号与自续的轮询任务，行为完全一致（在途则跳过而非排队、
节流、世代校验丢弃迟到结果、取不到就只让自己那张卡片消失）。Claude 不在此列——它由
共享的 `ClaudeAccountQuotaService` 推送。**测试必须注入这三个取数体**，否则会走生产实现
去读真实的 Cursor 凭据库并发起网络请求。

接线只在 `AsterAppDelegate.synchronizeUsageMonitor()`：启动时与每次偏好变化时按开关建立或
拆除。协调器不在 `deinit` 里清理（不在主线程隔离上），释放前必须先 `setEnabled(false)`。
菜单「显示 → 显示 AI 用量」和命令面板 `show-ai-usage` 会顺手打开开关。

浮动窗是 `.nonactivatingPanel` + `.floating` 的 `NSPanel`，可加入所有 Space；首次贴在状态栏
图标下方，之后记住位置（`aster.usage.panel-frame.v1`），屏幕布局变了就夹回可见区域。

## 验证

```sh
./scripts/test.sh --filter 'TokenStats|TokenSource|ProcessFootprint|UsageMonitor|UsageQuota|usageQuota|usageQuotaSources|UsageStatusSummary|UsagePlanName|claudeQuota|CodexAppServer|CursorQuota|AntigravityQuota|UsageTokenPage|TokenStatsService|UsageSessionBoard|AgentUsage'
```

`--filter` 是大小写敏感的正则，匹配测试 ID（套件名或函数名），**不匹配中文显示名**，
所以小写开头的测试函数要按源码名写。

几个真机冒烟默认跳过，要用环境变量打开，它们会真的发请求 / 起进程：

```sh
ASTER_CODEX_SMOKE=1  ./scripts/test.sh --filter 'codexAppServerLiveSmoke'
ASTER_CURSOR_SMOKE=1 ./scripts/test.sh --filter 'CursorQuotaClientTests/liveSmoke'
ASTER_AGY_SMOKE=1    ./scripts/test.sh --filter 'AntigravityQuotaSmoke'   # 需先打开 Antigravity
```

真机验收要看：数值与 Claude `/usage` 一致；Token 页第二次打开接近瞬时；冷扫期间终端打字不卡；
Agent 等输入时状态栏亮红点且点卡片能跳回 Pane；浮动窗关闭后空闲唤醒数与功能关闭时持平。
