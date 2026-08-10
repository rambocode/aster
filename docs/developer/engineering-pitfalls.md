# 工程陷阱与诊断方法论

跨域的工程纪律清单。收录只在真实时序下爆发、单元测试几乎无法复现、且症状与根因相距极远的一类问题;每条都出自真实事故,配有回归测试或常驻哨兵。改动相关路径前先读本清单。

## 业务背景

2026-08-10「恢复后第一个 pane 永远无法输入 / 分屏出现双分割线」一案:根因是 `makeTerminalView` 中途的 terminfo 探测用 `Process.waitUntilExit()` 泵了主线程 runloop,把排队中的工作区刷新拉进终端创建半途同步执行,同一 `TerminalSession` 启动了两个 PTY、视图绑定错乱。三个干净环境探针全绿、真机必现,最终靠现场结构化埋点三级收窄(失败原因枚举 → 上下文属性 → 重入调用栈)才定位。本文沉淀该案的全部教训。

## 核心规则

### 1. 主线程禁止泵 runloop 的等待

`Process.waitUntilExit()`、`NSAlert.runModal()` 等会在调用线程泵 default 模式 runloop 并排空主队列——任何排队中的 `DispatchQueue.main.async` 任务(如 `scheduleRefresh`)会被拉进**当前调用的半途**同步执行,造成重入。

- 视图/会话创建等非重入安全路径中,子进程等待一律用 `terminationHandler` + `DispatchSemaphore`(阻塞但不泵),见 `SystemTerminfoChecker.entryExists`。
- 回归测试模式:default 模式 Timer 在等待期间不得触发(`TerminalLaunchEnvironmentTests`「terminfo 探测不得在主线程泵 runloop」)。

### 2. 昂贵的一次性创建入口必须防重入

资源(如 `TerminalSession.terminalView`)创建后**立即登记**,再做后续接线;任何重入方命中缓存分支拿到同一实例,而不是重复创建(双 PTY)。同时保留 fault 级重入哨兵日志(`terminal.view_creation_reentered`,含逐帧调用栈),重入一旦复发即可定位。

### 3. 交互路径必须有自愈能力

不能只依赖「状态变化才有动作」:点击「已经是活动态」的 pane 不产生 `activePaneChanged` 事件,但键盘焦点可能早已丢失,必须显式重新交接(`WorkspaceViewController.routePaneClick`)。任何依赖单次初始化成功的交互,都要评估失败后用户是否还有恢复手段。

### 4. 高频事件禁止触发整树重建

OSC 标题(每秒多次)、命令开始/结束(`hasRunningCommand`)、Agent provider 变化等高频字段不得进入 `objectWillChange` → `refresh()` 链;只允许真正改变 Pane 结构形态的进程生命周期字段(lifecycleState / isRunning / exitCode / startupError)触发重建,其余走专用局部通道。回归:`TerminalOutputStormTests`。

### 5. 输出跟随语义

新输出只在视口已位于底部时跟随;用户上滚期间不得拉回。退出 Vi/Mark 显式回底(tmux copy-mode 语义)。回归:`TerminalOutputStormTests`、`TerminalScrollTests`。

## 诊断方法论(harness 绿、真机红时)

1. 每个可复现症状先写「红回路」测试(断言打在用户的确切症状上),修复后转绿留作回归。
2. harness 无法复现时**立即停止静态猜测**,转现场埋点,按信息量逐级升级:失败原因枚举(如 `no_view` / `view_detached` / `responder_refused`)→ 上下文属性(pane / session / lifecycle / generation / 调用计数)→ 重入哨兵 + `Thread.callStackSymbols` 逐帧属性(`swift demangle` 解码)。
3. **先验证诊断通道本身**:测试进程与应用曾共用 `~/Library/Logs/Aster`,测试噪声被误读为应用行为,导致两轮错误结论。现约束:测试环境不落盘 JSONL、每条记录带 `process` 属性;取证前清空/隔离旧日志。
4. 本机可自助闭环:`open dist/Aster.app` → 等待 → 读 JSONL → `osascript -e 'quit app "Aster"'`,不必每轮等待人工复现。
5. 警惕「同因多症」:一个根因(重入、高频重建)可同时表现为输入失效、闪动、IME 中断、卡顿、视觉残留;先找共同机制,再逐个验证表象。

## 失败语义

- 重入哨兵触发(`terminal.view_creation_reentered`,fault 级)视为缺陷,必须定位调用栈来源,不允许静默容忍。
- 焦点交接失败记录 `workspace.focus_pane_failed`(含 reason / pane / session / lifecycle),持续出现同一 reason 即为回归信号。

## 测试与验收

`TerminalLaunchEnvironmentTests`(runloop 泵探针)、`TerminalOutputStormTests`(重建风暴与滚动语义)、`RestoredWorkspaceInputProbeTests`(恢复输入 + 点击自愈 + 退出恢复)、`InteractiveSplitGeometryProbeTests`(分屏几何与褪色)、`SplitPaneTests`(焦点褪色局部翻转)。已知:全量 `--no-parallel` 会在 AppKitMigrationTests 中途静默 exit(0)(仅执行约 259/561),验证需并行全量 + 对 PTY 敏感套件定向串行补跑,并核对总结行。
