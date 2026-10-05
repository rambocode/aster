# 原生 SSH 引擎与已保存主机

远程机器、原生 SSH 标签和详情面板的受管旁路，默认都走 Aster 自带的 `aster-ssh`（Rust + russh），不再 exec `/usr/bin/ssh`。口令和私钥 passphrase 可以存进 macOS 钥匙串。设计参考 tty7（<https://github.com/l0ng-ai/tty7>，Apache-2.0，revision 458c923）：守护进程持有连接、主机配置对象、钥匙串按 endpoint 保存、认证弹窗排队。

契约全文见 [`SshRuntime/PROTOCOL.md`](../../SshRuntime/PROTOCOL.md)。本页讲结构、真值归属和失败语义。

## 组件

| 组件 | 位置 | 职责 |
| --- | --- | --- |
| `aster-ssh broker` | `SshRuntime/`，打包进 `Contents/MacOS/aster-ssh` | 每个 App 实例一个。持有全部 russh 连接（按 `user@host:port` 加跳板链共享），负责 keepalive、跳板、ProxyCommand、SOCKS/HTTP 代理、静态端口转发和 known_hosts 校验 |
| `aster-ssh client` | 同一个二进制 | 替代原来 exec `/usr/bin/ssh` 的所有位置，包括 Ghostty Pane 子进程。连到 broker socket，开一个 channel，转发 stdio、窗口大小和退出码 |
| `aster-ssh config` | 同一个二进制 | 解析 `~/.ssh/config`（Include、第一个匹配生效）；设置页导入和 Open Quickly 别名都用它 |
| `SSHBrokerSupervisor` | `Sources/Aster/SSH/` | 拉起和重启 broker，读写 JSON Lines 控制通道，推送 `profiles.sync`，把 `link.state` 转给机器连接状态 |
| `SSHAuthCoordinator` | `Sources/Aster/SSH/` | 回答认证和主机密钥请求：先查钥匙串，再弹窗；按请求排队，同时只显示一个表单 |
| `SSHCredentialStore` | `Sources/Aster/SSH/` | 钥匙串读写 |
| `SSHHostProfile` / `SSHHostStore` / `SSHHostResolver` | `Sources/AsterCore/` | 主机模型、`hosts.json` 持久化、合并默认项并展开跳板链 |
| `SSHHostDirectory` | `Sources/Aster/SSH/` | App 侧主机列表的唯一权威，监听外部修改 |

## 真值归属

| 数据 | 权威位置 | 规则 |
| --- | --- | --- |
| 已保存主机 | `~/Library/Application Support/Aster/hosts.json` | 带版本号的 JSON，目录 0700、文件 0600，整份校验通过才替换；**类型上就没有秘密字段** |
| 「默认」项 | 同一文件，固定 ID `…d0d0` | 其它主机的空字段继承它；它自己的空字段用内置默认值（端口 22、auto 认证、keepalive 15s×3、超时 10s、校验主机密钥） |
| 口令 | 登录钥匙串，service `io.aster.ssh`，account `user@host:port` | 只在 broker 报告认证成功后写入；来自钥匙串的口令被拒时删除；共用同一 endpoint 的主机共用同一条口令 |
| 私钥 passphrase | 登录钥匙串，service `io.aster.ssh-key`，account 为私钥文件内容 SHA-512 hex | 同上 |
| 机器与主机的绑定 | `machines.json` 的可选键 `hostID` | 只在绑定时写出，未使用新功能的配置仍能被旧版本读取 |
| 主机使用频率 | UserDefaults `aster.hosts.usage.v1` | 只用于排序，不写进 `hosts.json`，避免每次连接都触发文件监听 |

用的是基于文件的登录钥匙串，不是 data protection 钥匙串：后者需要 `keychain-access-groups` entitlement，Aster 没有。broker 本身不访问钥匙串，秘密只经 App 与 broker 之间的私有管道进入内存，用完即丢，不写文件，也不写日志。

## 引擎选择与回退

- 优先级：环境变量 `ASTER_SSH_ENGINE`（`native` / `openssh`，不区分大小写）→ 设置「高级 → SSH → SSH 引擎」（`shell.sshEngine`，默认 native）。
- **引擎只在 App 启动时决定**，改设置后要重启 Aster 才生效。运行中切换会让已经连着 broker 的受管终端和 Pane 桥失效。
- 选了 native 但找不到二进制，或者拉不起 broker 时，回退到 openssh，并记诊断 `ssh.engine.fallback`。
- openssh 路径与改造前逐字节一致：私有临时配置、ControlMaster、`BatchMode=yes`。
- 用户在 Shell 里手敲的 `ssh` 永远是 OpenSSH，不受引擎影响。详情面板借用它的 ControlMaster（场景 A）也不受影响。

二进制定位顺序：`ASTER_SSH_BINARY` → `Contents/MacOS/aster-ssh` → 主程序同目录 → 开发构建的 `SshRuntime/target/{release,debug}/aster-ssh`。开发时运行 `scripts/build-ssh-runtime.sh .build/debug` 就能让 `swift build` 出来的 App 找到它。

## broker 生命周期

- socket 位于 `/tmp/aster-sshb-<10 位>/b.sock`，目录 0700。路径在一个 App 进程内固定，broker 重启后不变，所以已经写进 Pane 命令行的桥仍然有效。
- ready 超时 5 秒。重启退避依次为 0.5/1/2/4/8/15/30 秒；连续运行满 30 秒后退避从头开始计。
- App 退出时发 `shutdown`，然后删除目录。broker 读到 stdin EOF（App 崩溃）时也会断开全部连接并退出。
- **channel 生命周期是硬约束**：client 进程一死，broker 立即对它的 channel 发 EOF 和 close，远端 pty 收到 SIGHUP，`aster-session terminal attach` 在 2 秒内退出并释放写租约。原来 ControlMaster 方案有滞留 62 秒的问题，共享连接不能再引入它。

## 调用形状

| 场景 | OpenSSH | 原生 |
| --- | --- | --- |
| 后台结构化命令、事件订阅、安装 | `ssh -o BatchMode=yes … -- target 'cmd'` | `aster-ssh client --broker S (--host-id ID \| --target T) --no-prompt -- 'cmd'` |
| 显示桥（受管 Pane） | `ssh -tt …` | `… --tty`，不带 `--no-prompt`，允许交互认证 |
| 原生 SSH 标签 | 不适用（回退为在本地 Shell 里敲 `ssh target`） | `aster-ssh client … --tty`，不带命令，得到交互 Shell |

- 绑定了主机的机器用 `--host-id`，超时以主机配置为准。
- 按 target 连接的，沿用连接策略的超时。
- 失败分类：先读 stderr 最后一行 `aster-ssh-error {"kind":…}`（退出码 255），没有再回退到 OpenSSH 文本分类。

## 认证与主机密钥

1. broker 需要凭证时发 `auth.request`。App 先查钥匙串（只在第一次尝试时查）。后台请求（`interactive:false`）只能用钥匙串作答，查不到就取消。
2. 交互请求弹出表单：口令或 passphrase 用安全输入框，「记住到钥匙串」默认勾选；键盘交互按提示逐项输入，回答不存钥匙串。
3. broker 每次尝试后发 `auth.result`。App 只在 `accepted=true` 且用户勾选了记住时写钥匙串；来自钥匙串的秘密被拒时删掉那条。挂起的秘密最多在内存里留 60 秒。
4. 主机密钥按 `~/.ssh/known_hosts` 校验（支持 hashed 条目和 `[host]:port`）：
   - 未知：显示算法和指纹，默认按钮是「取消」。
   - 变更：显示中间人攻击警告，必须手动输入 `yes` 才能继续；接受后替换旧行。
   - 后台连接遇到这两种情况，一律失败并进入 attention，不自动接受。
5. `link.state` 的 `authenticationRequired`、`hostKeyUnknown`、`hostKeyChanged` 立即让机器进入 attention。链路回到 connected 时，处在重连、attention 或断开状态的机器立即重连。

### ssh-agent 的选择（IdentityAgent）

每一跳（目标与每个跳板）各自决定用哪个 agent，规则只有一份，在 broker 的 `Env::agent_socket`（`SshRuntime/src/env.rs`）：

1. 优先级：主机的 `identityAgent` > 「默认」项的 `identityAgent` > broker 继承到的 `SSH_AUTH_SOCK`。`--target` 走 ssh_config 时按「第一个匹配生效」取 `IdentityAgent`。
2. 取值与 OpenSSH 一致（`none` 与 `SSH_AUTH_SOCK` 区分大小写）：
   - `none`：这一跳不用 agent。
   - `SSH_AUTH_SOCK`：用继承到的环境变量，同没写。
   - `$VAR`：路径取自环境变量；变量没设或为空就不用 agent，不回落到 `SSH_AUTH_SOCK`。
   - 其它：当作路径，展开 `%h`、`%p`、`%r`、`%u`、`%d`、`%%`、`${VAR}` 和开头的 `~`。
3. Swift 侧只做继承与去空白，把原文放进 `ResolvedSpec.identityAgent`。环境变量属于 broker 进程，所以展开留给 broker。
4. agent 转发用同一个 socket：`agentForward` 打开且这一跳解析得到 socket 时才请求转发。
5. 与 OpenSSH 的差异：`${VAR}` 没设时 OpenSSH 直接报错退出，这里记一条 debug 日志并跳过 agent；`%C`、`%i`、`%k`、`%L`、`%l`、`%n`、`%j` 不展开，原样保留。
6. 从 Dock 启动的 App 拿到的是 launchd 的 `SSH_AUTH_SOCK`（系统 agent），不是用户 Shell 里导出的值。用第三方 agent 的用户应当写 `IdentityAgent`。

## ~/.ssh/config 解析

Rust 实现，参考 tty7 的 `ssh_config.rs`：

- 支持：Include（相对路径按 `~/.ssh/` 解析，最多 16 层，检测循环）、Host 模式（`*`、`?`、`!`）、第一个匹配生效，以及 HostName、User、Port、IdentityFile、ProxyJump、ProxyCommand、三类 Forward、ServerAlive*、ConnectTimeout、ForwardAgent、StrictHostKeyChecking、UserKnownHostsFile、GlobalKnownHostsFile、IdentitiesOnly、IdentityAgent。
- 不支持：Match 块（整块跳过）、UseKeychain、GSSAPI*、Canonicalize* 等。这些指令按行列进 `ignored`，导入时展示给用户。
- 安全上限：单个文件 1MB，最多 64 个文件。
- 与 OpenSSH 的差异：Host 匹配不区分大小写。

## 验证

- Rust：`cd SshRuntime && cargo test`。用进程内的 russh 服务端覆盖认证、known_hosts、exec 退出码、pty、channel 关闭时限、跳板链、结构化错误行和协议样例。
- Swift：`./scripts/test.sh --no-parallel --filter 'nativeTransport|sshBrokerSupervisor|machineHostBinding|sshAuthCoordinator|sshCredentialStore|sshHostProfile|sshHostStore|sshBrokerProtocol|settingsHosts|sshConfigImport'`。
- 打包：`./scripts/build-app.sh` 会构建 aster-ssh、复制进 `Contents/MacOS/`、签名并运行 `--version` 自检。
