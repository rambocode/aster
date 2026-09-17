# Aster session runtime

状态：P0 原型与基线验收已通过，尚未完成远程工作模式。规范见 `docs/developer/remote-work.md`，阶段及验收证据见 `docs/developer/remote-work-stages.md` 和 `remote-work-evidence/p0.md`。原型不是正式 server API，也不意味着 P1–P8 已完成。

## 构建与验证

使用 Zig 0.15.2。所有命令在本目录执行：

```sh
scripts/build-vt.sh native
zig build -Dvt-prefix=.build/vt-host
scripts/test-runtime.sh
scripts/test-window.sh
```

`test-runtime.sh` 运行协议、VT、真实 PTY、socket、桥接、故障注入和 PNG 服务测试。`test-window.sh` 显式启用真实 AppKit/Ghostty 窗口测试，验证输入、图像、surface 重建和后台进程保活；GPU PNG 输出到仓库 `.build/remote-bridge-image.png`。这些测试不安装系统服务。

Linux 构建：

```sh
scripts/build-vt.sh x86_64-linux-musl
zig build -Dtarget=x86_64-linux-musl -Dvt-prefix=.build/vt-linux --prefix .build/linux
zig build test-binaries -Dtarget=x86_64-linux-musl -Dvt-prefix=.build/vt-linux --prefix .build/linux
```

`test-binaries` 只生成目标测试可执行文件；必须在目标系统实际运行才能计入验收。普通 install 不打包测试文件。构建产物、下载源码和临时测试数据保持忽略。

## 当前实现

- `protocol.zig`、Swift `SessionWireFrame` 共享有界分帧样例；握手通过版本、身份和能力校验后才接收画面或发送输入。
- `session.zig` 持有独立 PTY 与 VT，客户端断开不销毁进程；输入、查询回复、读取工作量和快照均有界。
- `probe-serve` 使用同用户私有 Unix socket；`probe-bridge` 负责终端输入/显示、实际像素尺寸、SIGWINCH 和异常退出后的 raw-mode 恢复。
- 快照使用 begin/chunk/end、顺序及 SHA-256 校验，首份完整快照之前不放行输入；要求 `snapshot_transaction_v1` 能力，旧 raw-frame probe 会被拒绝。
- `terminal_snapshot.zig` 组合双屏幕历史、图像缓存、placement、保存模式和光标。图形等待实际像素几何，缓存不因此丢弃，hello 仍正常发送。
- 图形支持有界内联 RGB/RGBA 和真实 PNG，关闭文件、临时文件、共享内存加载；缓存包括未显示图像，placement 支持可见、离屏及虚拟占位符。
- 原生 GPU 测试证明 PNG 能显示且在 surface 重建后恢复；此项不替代完整用户级 UI 验收。

开发入口：

```text
aster-session server start <existing-private-state-parent> <name>
aster-session server serve <existing-private-state-parent> <name>
aster-session server status <existing-private-state-parent> <name>
aster-session server stop <existing-private-state-parent> <name>
aster-session probe-serve <private-socket> <cwd> <executable> [args...]
aster-session probe-bridge <private-socket>
```

`server serve` 是当前 P1 的前台健康服务入口：父目录必须属于当前用户且不向组/其他用户开放，
服务持有私有锁、持久身份和当前 epoch，支持握手、health.check、server.status 和 server.stop。它不派生后台进程，
尚无终端创建能力，不替代后台入口，支持通过独立 stop 入口结束服务。SIGTERM/SIGINT/SIGHUP 会按序关闭连接、
socket 和锁；`tests/service_server.py` 验证实际启动、重连、坏连接隔离、重复启动拒绝和重启身份。

`server start` 在独立 session 中后台运行服务，关闭调用方标准流和其它继承 FD，等待私有 ready
并按本次启动 epoch 查询确认。stdout 返回 server_start JSON：started 或 already_running、诊断 PID
（已有服务时为 null）和已验证 status。PID 不是资源身份。超时或结果未知不会杀进程、重启或替换服务。
后台当前不保留 stderr；诊断初始化失败时使用前台 server serve 入口获取具体错误。

`server status` 只读查询现有实例，使用同一个 3 秒期限完成连接、握手和状态回复。成功输出已校验的
RPC response JSON；服务端 error 原样校验后输出并退出 1，连接/校验失败输出 client_error JSON 并退出 1。
它不会创建状态目录、修复文件或隐式启动服务。

`server stop` 使用 server_lifecycle 能力与完整实例身份发送一次停止请求，不发送 PID 信号。
服务停止接入新操作并有界排空回复；CLI 收到确认后还需观察连接关闭和锁释放，或验证已出现不同 epoch。
只有原实例已停止才输出 server_stop JSON；替代实例保留，失败/超时不会重发停止请求。

原型 probe 身份仅在进程内稳定，尚无生产持久会话注册表或写租约。生产操作 schema 和跨语言编解码契约已定义，运行时 handler 按 P1–P8 实现。当前支持经过分类及校验的增量帧，复杂或不完整 VT 序列回到完整快照；序号失配会重新同步。不要将原型能力标记成正式产品功能。

## P1 终端操作开发入口

构建带 VT 的运行时后，在已启动的私有服务实例上执行：

```sh
aster-session terminal create <state-parent> <name> <absolute-cwd> <program> [args...]
aster-session terminal list <state-parent> <name>
aster-session terminal terminate <state-parent> <name> <terminal-id>
aster-session terminal attach <state-parent> <name> <terminal-id> [--takeover]
aster-session terminal observe <state-parent> <name> <terminal-id>
```

create 在执行机器合并环境并解析 PATH，argv 按字面传递；运行后客户端断开不结束终端。list 返回实际运行状态、PID 和退出结果。terminate 等待托管进程退出。命令输出结构化响应，失败退出 1；结果未知时先查询实际资源，不自动重复创建。私有父目录必须已存在且仅当前用户可访问。

同一 Unix socket 的协议入口已实现 terminal.attach/observe/release/control；observe 返回只读 currentLeaseEpoch，接管提交该预期代数，不能读取或复用别人的写 token。写租约 15 秒无活性失效；input/resize/scroll 必须通过租约与控制序号验证。关闭输入侧释放写权，仍接收已接受创建的回复；完全断开丢弃投递权并继续完成持久操作。

attach/observe 使用独立控制和画面连接，完整校验快照/增量后显示。Ctrl+B q 分离，Ctrl+B Ctrl+B 发送字面 Ctrl+B；分离后后台任务继续。attach --takeover 先观察当前租约代数再进行显式CAS，竞争失败不会覆盖新写者。observe 不取得写权、不发送输入、不调整源PTY尺寸。

surface.subscribe/snapshot/unsubscribe 已接入持久服务，文本历史视口可投影。不同源/目标尺寸的独立投影及历史中部分可见图像尚未实现，对不支持的投影明确失败；不能据此宣告完整画面支持。P1 整体验收与 App 接入仍未完成。

## P4 命名会话注册表与共享工作区

注册表就是私有 state parent 目录本身：每个命名会话是一个子目录，持有自己的锁、`identity.bin`、
幂等日志和 `layout.json`。没有额外索引文件，因此崩溃的写入方不可能让注册表与实际状态不一致。
稳定 sessionID 来自该会话已提交的 `identity.bin`；没有提交身份的目录不算会话，会被列表忽略。

```sh
aster-session session list <state-parent>
aster-session session create <state-parent> <name>
aster-session session attach <state-parent> <name-or-id>
aster-session session stop <state-parent> <name-or-id>
aster-session session delete <state-parent> <name-or-id>
aster-session session snapshot <state-parent> <name>
aster-session workspace list <state-parent> <name>
aster-session workspace create <state-parent> <name> --expected-revision <n> --title <t> --cwd <abs> -- <argv...>
aster-session workspace update <state-parent> <name> --workspace <id> --expected-revision <n> --title <t>
aster-session workspace close <state-parent> <name> --workspace <id> --expected-revision <n>
aster-session tab create <state-parent> <name> --workspace <id> --expected-revision <n> --title <t> --cwd <abs> -- <argv...>
aster-session tab update <state-parent> <name> --tab <id> --expected-revision <n> --title <t>
aster-session tab close <state-parent> <name> --tab <id> --expected-revision <n>
aster-session pane split <state-parent> <name> --pane <id> --direction <left|right|up|down> --expected-revision <n> --cwd <abs> -- <argv...>
aster-session pane update <state-parent> <name> --pane <id> --expected-revision <n> --title <t>
aster-session pane close <state-parent> <name> --pane <id> --expected-revision <n>
```

`session create` 启动独立后台服务实例并返回稳定 sessionID、serverID、serverEpoch 和实际状态；
running 状态必须由该会话自己的 socket 应答核对 sessionID 后才成立，仅目录存在不算运行。
`session stop` 只对该会话发送 `server.stop`，不发 PID 信号，并保留 `layout.json`；
`session delete` 要求已停止，运行中返回 `session_running`，删除只影响该会话目录。
注册表操作同时通过控制 socket 提供（registry scope 请求不带 target），由请求到达的那个会话
按自己所在的 state parent 服务；正在服务请求的会话用自身身份回答自己的状态，并拒绝通过注册表
停止自己（改用 session 范围的 `server.stop`）。运行中的服务不会 fork 自己来创建兄弟会话，而是
运行已安装二进制自身的 `server start` 入口，新守护进程与提出请求的会话不共享任何状态。

`workspace_store.zig` 持有工作区→标签→递归分屏树与单调递增的会话 revision；结构变更和终端退出
共用这一个计数器。上限为 1024 工作区、128 标签、64 pane、16 层深度。布局以 `layout.json`（0600）
原子提交：临时文件 → fsync → rename → 目录 fsync。文件损坏时保留原文件并明确报错，服务拒绝启动，
不会静默当成空布局。

`workspace_service.zig` 实现 `session.snapshot`、`workspace.list/create/update/close`、
`tab.create/update/close`、`pane.split/update/close`。全部结构变更携带 `expectedRevision`；
校验与 revision 自增在**准入时**一起完成，因此两个客户端用同一 revision 并发提交时恰好一个被接受，
另一个返回 `revision_conflict`，失败信封额外携带 `currentRevision` 让失败方无需再查即可重试。
带 `terminalSpec` 的创建操作真实创建受管终端，cwd 由服务端校验（不存在返回 `cwd_unavailable`），
只有进程真正存在且布局落盘后才提交结构节点，失败不留下半个节点。close 先落盘再结束受管终端，
关闭最后一个 pane 会关闭标签，关闭最后一个标签会关闭工作区。durable 操作接入既有幂等日志。

结构变更后向所有控制连接广播 `workspace.changed` / `tab.changed` / `pane.changed` /
`terminal.created`，序号按连接连续递增、revision 不回退；关闭事件用受影响的父对象表达，
被关闭的工作区表示为 `tabs: []`。服务握手新增 `session_snapshot` 与 `workspace_mutation`。

`tests/session_registry.py` 与 `tests/workspace_transaction.py` 使用真实进程验证上述行为，
包括两个客户端进程用同一 expectedRevision 并发提交、冲突方重新取快照后重试成功。

## 依赖与扩展边界

VT 使用 Ghostty revision `4dcb09ada0c0909717d92547623b26eafa50ca8a`。构建脚本核对固定源码及完整补丁集，拒绝覆盖额外源码修改。Headless 可执行文件不依赖 AppKit、Metal 或 Sparkle。

- `patches/0001-formatter-cursor-order.patch`：恢复顺序、原点坐标、逐字符保护和键盘模式环形栈。
- `patches/0002-screen-export.patch`：只读屏幕/历史/图形/保存状态扩展；不修改应用侧 XCFramework ABI。
- `patches/0003-history-budget.patch`：计量历史所占真实页面并裁剪最旧历史；不删除 active 行，不把页面池预热内存算作保留历史。
- `patches/0004-history-pages.patch`：历史页稳定身份与FIFO观察接口。
- `patches/0005-history-page-release.patch`：lib侧释放已淘汰页面，避免每终端保留历史page arena峰值；reset保留active缓冲。
- `patches/0006-graphics-metadata-budget.patch`：headless库每屏限制4096张图像和8192个placement；数量满后拒绝新增、允许替换，替换和逐出时释放tracked pin。像素配额与元数据数量分别限制。
- `patches/0007-cursor-shape-replay.patch`：headless VT 按屏记录程序最后一次 DECSCUSR 请求，光标回放末尾原样补发；从未请求过的屏不发，客户端沿用自己的默认光标样式。修复恢复的 Pane 光标退回方块、要到下一次提示符才变回竖线。
- PNG 使用同 revision 的 `src/stb/stb_image.h`，仅编译内存 PNG 解码。输入与解码像素各限 16 MiB，活跃工作分配含头部限 64 MiB。
- 分发运行时二进制时携带 `THIRD_PARTY_NOTICES.md`。

后续按阶段推进持久化、多机器、Agent、恢复、TUI 和升级交接。实际完成状态只以阶段记录和测试证据为准。

## 操作契约测试

`protocol/contract.md` 说明生产操作边界；`scripts/build-protocol.py` 生成操作、事件和画面 schema 及 Swift/Zig 元数据。不要手改生成文件。

```sh
scripts/setup-protocol-tests.sh
scripts/test-protocol.sh
```

schema 测试依赖只安装在 `.build/schema-env`。契约存在不代表 handler 已实现；每个方法的实施阶段记录在 `protocol/operations.md`。

## P1 清理与查询

`request.status` 查询既有请求状态，返回原操作、资源ID及 `resourcesInvalidated`；未知/过期结果不触发重试执行。`terminal.list` 的 `terminating` 表示仍在结束和清理，不能当作已退出。结束成功必须等原POSIX会话清理与PTY输出结束。

当前进程清理需要Linux subreaper或Mac audit-token信号。后者在macOS15起提供；macOS14兼容性尚待确定，缺接口时明确拒绝受管服务启动。此限制不代表项目整体最低系统版本已变更。
