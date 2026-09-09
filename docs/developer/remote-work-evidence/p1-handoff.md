# P1 交接记录

工作区：`/Users/mike/source/project/aster/.worktrees/codex-remote-work`

分支：`codex/remote-work`；基线：`9e33e7b`。改动尚未提交、推送、安装或部署。保留全部既有改动，不将目录内其他功能的改动归为本次P1。

## 当前状态

本任务范围截至P1。P2–P8由其他agent继续，本任务不启动后续阶段。P1.1–P1.7实施任务均完成，双真实PTY的非零全局配额补验已在Mac/Linux通过。A06与P4.2的阶段冲突已按"布局revision并发归入P4.2/A15、要求不降级"处理；A06.3过期/未来/缺时间戳请求补齐了真实服务级Mac/Linux证据。P1整体验收已标记通过，阶段状态表与验收规格状态行同步更新。

## 已交付

- 后台服务及私有同用户Unix socket、持久身份、启动互斥和ready确认。
- PTY生命周期与原SID进程清理；分离不结束任务；终止/退出事件等待清理及尾输出完成。
- terminal创建、查询、附加、观察、释放、终止及最小CLI。
- 单写租约、CAS接管、15秒过期、旧代输入和resize拒绝。
- 持久幂等意图/结果与request.status；磁盘满、权限、半写、未知结果和冷重启资源失效。
- 独立surface通道、完整快照/安全增量、SHA事务、源缓冲/发送队列上限、30秒慢事务断开及重新订阅。
- CLI surface/control缺口恢复、恢复期间输入门禁、延后尺寸变化、stdout实际应用后恢复输入。
- 单终端16MiB历史、会话256MiB历史FIFO；headless图形每屏4096图像/8192 placements，替换与逐出释放tracked pin。
- 同geometry历史文字、颜色与图像前缀投影；不改变源VT或PTY尺寸。

## 已知支持边界

1. 原生验证环境为当前本机macOS与OrbStack Linux x86_64。macOS服务缺少原子身份信号API时拒绝启动，未声称支持macOS14。App最低系统版本未调整。
2. 不支持的异geometry订阅明确拒绝。完整TUI/窄屏继续按P7，四平台矩阵继续按P8。
3. 图像历史前缀依赖接收Ghostty VT保留与视口相交的历史anchor。小scrollback接收端已复现锚点移位，不属于保真支持；未进行真实渲染截图逐像素比较。
4. 原SID清理不追杀主动setsid逃逸到其他会话的进程。

## 接续执行

- 在同一worktree读取[阶段规格](../remote-work-stages.md)、[验收规格](../remote-work-acceptance.md)和[P1证据](p1.md)，保留每项已运行检查的准确范围。
- P2按规格以"P1通过"为前置，可以启动。P4.2/A15验收时必须用真实布局事务并发提交同revision修改，不以协议字段或通用revision单测代替；这是从A06移入的原要求。
- 继续任务前核对git worktree归属；不要切回master进行本任务修改，不覆盖其他agent文件。
- 运行改动影响面的定向测试；不要重复全量套件。子代理使用low，明确文件所有权。
- 发布、提交、推送须按用户相应授权执行；本交接不包含这些动作。

## 关键证据

| 链路 | 证据位置 |
| --- | --- |
| 20次SSH断开，每次至少30秒 | `.build/remote-work-evidence/p1-detach-survival-drained/events.jsonl` |
| 原SID清理、结果查询、租约过期 | `.build/remote-work-evidence/p1-owned-scope-linux.log`、`p1-request-status-linux.log`、`p1-lease-expiry-linux.log` |
| 真实磁盘满与权限故障 | `.build/remote-work-evidence/p1-storage-linux.log` |
| 强制delta、慢连接期限和重新订阅 | `SessionRuntime/.build/p1-surface-recovery-native.log`、`.build/remote-work-evidence/p1-surface-recovery-linux.log` |
| CLI缺口、输入门禁和控制重建 | `SessionRuntime/.build/attach-resync-native.log`、`.build/remote-work-evidence/p1-attach-resync-linux.log` |
| 图像历史与小容量限制 | `SessionRuntime/.build/p1-viewport-graphics-prefix-native.log`、`p1-viewport-graphics-prefix-linux.log`、`p1-viewport-small-history-native.log` |
| 双真实PTY非零全局历史配额 | `SessionRuntime/.build/p1-real-pty-history-native.log`、`.build/remote-work-evidence/p1-real-pty-history-linux.log` |
| 图形元数据和满额快照 | `SessionRuntime/.build/graphics-metadata-tests.log`、`.build/remote-work-evidence/p1-metadata-snapshot-native.log` |
| 过期/未来/缺时间戳请求拒绝（A06.3） | `.build/remote-work-evidence/p1-request-window-native.log`、`p1-request-window-linux.log` |

表中相对路径均以该worktree为根。构建输出和证据日志可能被清理，保留[P1证据](p1.md)中的执行说明与未完成边界；需要复验时只重跑相应检查。
