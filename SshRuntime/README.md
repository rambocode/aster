# aster-ssh

Aster 的原生 SSH 运行时（Rust，基于 crates.io 上的 [russh](https://crates.io/crates/russh) 0.62）。
一个二进制三种角色：

| 子命令 | 作用 |
| --- | --- |
| `aster-ssh broker --socket <path>` | 常驻进程，每个 App 实例一个。持有全部 SSH 连接；stdin/stdout 是与 App 的 JSON Lines 控制通道 |
| `aster-ssh client …` | 替代 `/usr/bin/ssh` 的薄客户端：连到 broker socket，打开一个 channel，转发 stdio、窗口大小与退出码 |
| `aster-ssh config …` | 解析 `~/.ssh/config`（见 `src/ssh_config.rs`） |

协议契约见 [PROTOCOL.md](PROTOCOL.md)，Swift 侧对应 `Sources/AsterCore/SSHBrokerProtocol.swift`。

## 来源

设计参考 [tty7](https://github.com/l0ng-ai/tty7)（Apache-2.0）revision `458c923` 的
`crates/tty7-core/src/daemon/ssh/`：连接共享、认证顺序、known_hosts 处理、测试夹具的组织方式。
实现按本仓库的协议与风格重写，没有整段复制；借鉴了具体做法的位置在源码注释里注明
「tty7 …@458c923（Apache-2.0）」，包括：

- `known_hosts.rs`：同算法不同密钥才算「变更」，`@revoked` 优先。
- `connect.rs`：SOCKS5 / HTTP CONNECT 握手要把应答读干净；按 known_hosts 已有算法调整主机密钥协商顺序。
- `handler.rs`：关闭主机密钥校验时仍拒绝被吊销的密钥。
- `auth.rs`：关掉口令 / 键盘交互表单视为取消整个认证，关掉 passphrase 表单只跳过这把密钥。
- `pool.rs`、`test_support.rs`：共享连接与进程内测试服务器的思路。

## 模块

| 文件 | 内容 |
| --- | --- |
| `protocol.rs` | ResolvedSpec、帧协议、控制消息的 serde 形状 |
| `control.rs` | 控制通道：事件写出、`auth.request` / `hostkey.confirm` 按 id 等待回答 |
| `broker.rs` | broker 入口、控制命令分发、socket 服务、OPEN 处理 |
| `pool.rs` | 连接池：按 `user@host:port` + 代理 + 跳板链共享，拨号结果在并发 OPEN 间共享 |
| `connect.rs` | 传输流（TCP / ProxyCommand / SOCKS5 / HTTP CONNECT / 跳板 channel）、russh 配置、握手超时 |
| `handler.rs` | russh 回调：主机密钥校验、远端转发与 agent 转发入站 channel、断开通知 |
| `auth.rs` | 用户认证：agent → identityFiles → 默认密钥 → password → keyboard-interactive |
| `known_hosts.rs` | known_hosts 校验与写入（明文、`[host]:port`、hashed、通配、`@revoked`） |
| `bridge.rs` | client 与 session channel 的双向转发；client 断开时立即 EOF + CLOSE |
| `forward.rs` | 静态转发：local / remote / dynamic（SOCKS5 CONNECT） |
| `target.rs` | `--target` 文本解析与 ssh_config 合并 |
| `client.rs`、`terminal.rs` | client 命令行、raw 模式、SIGWINCH、退出码 |
| `env.rs`、`logging.rs` | 路径与环境变量、脱敏的 stderr 日志 |

## 环境变量

| 变量 | 作用 |
| --- | --- |
| `ASTER_SSH_HOME` | 代替 `HOME`，决定 `~/.ssh/config`、`~/.ssh/known_hosts` 与默认密钥的位置（测试用它指向临时目录） |
| `ASTER_SSH_KNOWN_HOSTS` | 单独指定 known_hosts 文件 |
| `SSH_AUTH_SOCK` | ssh-agent；未设置时不用 agent |
| `ASTER_SSH_DEBUG` | 非空且不为 `0` 时输出 debug 日志 |

## 行为要点

- `--target` 合并 ssh_config 时：`ConnectTimeout` 只在没有 `--connect-timeout` 时生效；`ForwardAgent`
  映射到 agentForward；`StrictHostKeyChecking accept-new` 与 `no` 都只自动记下**未知**主机，
  密钥变更照样需要确认（比 OpenSSH 的 `no` 更严）。
- client 连 broker 时，socket 不存在或拒绝连接会在 2 秒内每 75ms 重试一次（App 先公布端点再拉起 broker）。
- ProxyCommand 子进程的 stdin/stdout 是 SSH 传输流，stderr 进 broker 日志，永远不继承 broker 的
  stdout（控制通道）。
- known_hosts 按 spec 的 `knownHostsFiles` 依次查、写入第一个，`["none"]` 表示不写任何文件；
  系统级 `/etc/ssh/ssh_known_hosts{,2}`（或 ssh_config 的 GlobalKnownHostsFile）只读参与校验。
- `identitiesOnly`：agent 只为 identityFiles 里的同一把公钥签名，不逐个试 agent 里的其它密钥。
- 键盘交互的回答只看 `responses`：数组是回答（条数必须与提示一致，否则按取消处理并回报
  `accepted=false`），null 是取消。

## 安全边界

- broker 不读写钥匙串，不把口令、passphrase、私钥内容、键盘交互回答写入文件或日志。
  秘密只经控制通道进入内存（`Zeroizing<String>`），用完即清零。
- 控制消息的 `Debug` / `Display` 只输出类型名；解析失败的控制行只记录行列号，不回显原文。
- socket 权限 0600；所在目录的权限由 App 负责。
- 测试不触碰真实的 `~/.ssh`、钥匙串与 agent：known_hosts、私钥全部在临时目录，agent 关闭。

## 构建与测试

需要 Rust 工具链（本机验证版本 cargo 1.98）。

```sh
cd SshRuntime
cargo build                 # debug
cargo build --release       # 发布产物 target/release/aster-ssh
cargo test                  # 单元测试 + 端到端测试 + 进程级测试
cargo clippy --all-targets
```

测试全部跑在 127.0.0.1 的临时端口上，服务器是进程内的 russh server（`src/test_support.rs`）：

- `src/e2e_tests/`：进程内 broker + client 核心逻辑，覆盖口令重试、私钥、passphrase、键盘交互、
  known_hosts 三种状态、连接共享、exec 退出码、pty、跳板链、ProxyCommand、SOCKS5 / HTTP 代理、
  三种转发、结构化错误、日志脱敏，以及「client 断开 2 秒内远端 channel 关闭」。
- `tests/process.rs`：真的启动 broker 与 client 两个进程，验证 SIGKILL client 后 2 秒内远端 channel
  关闭、退出码与 `aster-ssh-error` 行、broker 在 stdin EOF 时退出并删除 socket。
  `ProxyCommand` 用例依赖系统自带的 `nc`。
