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

### 6. 系统 UI 字体对私用区(PUA)码位跳过自定义 cascade

2026-08-11「光标偏离文本约一格 / 提示符箭头消失」一案:内置 `AsterNerdSymbols` 通过 `kCTFontCascadeListAttribute` 挂在基础等宽字体后面,但当基字体解析为**隐藏系统字体**(`.AppleSystemUIFontMonospaced`,即用户未装 JetBrains Mono 时的默认落点)时,macOS 对 PUA 码位(U+E000-U+F8FF 等)**跳过自定义 cascade 直落 LastResort**——Powerline 分隔符、Nerd 图标渲染成空白,却仍占据一格,后续文本整体右移,视觉上表现为「光标错位」。非 PUA 字符(如 ❯ U+276F)的 cascade 正常,极具迷惑性;Menlo 等公开字体做基字体时 PUA cascade 也正常,因此测试环境常常不红。

- 字体构建层无解(`CTFontDescriptor` / `CTFontCreateCopyWithAttributes` 变体均被跳过),必须在**逐字符选字体**的 seam 修:`buildAttributedString` 对 PUA 字符手动沿 cascade 列表解析并显式指定字体(vendored 补丁,见 `UPSTREAM.md`),CG 与 Metal 两条渲染路径经同一分段构建器同时受益。
- 症状与根因相距极远:用户报「光标没对齐」,根因是字形缺失。渲染类错位先问「是不是有看不见的字符占位」,再查光标数学。
- 回归:`PrivateUseGlyphFallbackTests`(系统等宽字体 + Nerd cascade 下 E0B0 不得整形到 LastResort)。

### 7. 用户操作的控件不能被自己的副作用重建

设置页曾经每次配置变化都全量重建视图树:点一次开关要重造侧栏九个按钮、搜索框、字体枚举(上千个 `NSFont`)与 24 张主题卡,点击反馈被同一轮主线程布局工作压住,表现为「点哪儿都要顿一下」。规则:**正在被操作的控件必须活过它自己触发的更新**。

- 视图树分层:常驻骨架(导航、搜索、容器)只建一次,只有真正换页时才替换内容区。
- 本页发起的配置广播要能被识别并跳过刷新(`isApplyingLocalControlAction`),且**每一条**订阅都要遵守——漏掉一条(如 Panel 宽度绑定)就等于没做,滑杆照样在拖动中被销毁。
- 就地能表达的状态就地更新:选中态翻转、滑杆/步进器的数值标签,都不值得一次重建。
- 会改变同页其它行可见性/选中态的控件(下拉、主题卡、布局卡)才请求一次合并刷新。
- 昂贵且几乎不变的系统查询(字体枚举)按进程缓存,用系统通知作废,而不是每次刷新重算。
- 回归:`SettingsResponsivenessTests`。

### 8. 动态 `NSColor` 的 `.cgColor` 按 `NSAppearance.current` 解析，不看视图自己的外观

`layer.backgroundColor = SomeDynamicColor.cgColor` 会在赋值那一刻用**当前线程**的 `NSAppearance.current` 求值。设置 `view.appearance = darkAqua` 并不改变它——深色模式下照样拿到浅色值,而且颜色一旦落进 layer 就不再跟随外观变化。凡是往 layer 写动态色的地方都要 `effectiveAppearance.performAsCurrentDrawingAppearance { ... }`(或改在 `updateLayer()` 里写,AppKit 会先把 effectiveAppearance 设为 current),并在外观变化时重算。每次重建的视图容易掩盖这个问题;视图一旦常驻,浅色底就会留在深色页面上。回归:`SettingsResponsivenessTests`「明暗切换后常驻侧栏底色跟随外观」。

### 9. `contentViewController` 赋值会抹掉先写好的窗口尺寸

`NSWindow(contentRect:)` 里给的尺寸在 `window.contentViewController = vc` 之后会被收缩回控制器视图自己的默认尺寸。恢复记忆尺寸必须写在赋值**之后**(`setContentSize`),否则测试里表现为「值存对了、读对了,窗口却还是默认高度」。

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

`TerminalLaunchEnvironmentTests`(runloop 泵探针)、`TerminalOutputStormTests`(重建风暴与滚动语义)、`RestoredWorkspaceInputProbeTests`(恢复输入 + 点击自愈 + 退出恢复)、`InteractiveSplitGeometryProbeTests`(分屏几何与褪色)、`NestedSplitGeometryProbeTests`(嵌套分屏收敛定位)、`SplitPaneFocusProbeTests`(拆分后键盘焦点跟随)、`SplitPaneTests`(焦点褪色局部翻转)、`PrivateUseGlyphFallbackTests`(PUA 字形 cascade 解析)、`CursorAlignmentProbeTests`(光标网格对齐)、`MetalCaretInvariantProbeTests`(Metal 激活时 AppKit caret 隐藏)。已知:全量 `--no-parallel` 会在 AppKitMigrationTests 中途静默 exit(0)(仅执行约 259/561),验证需并行全量 + 对 PTY 敏感套件定向串行补跑,并核对总结行。
