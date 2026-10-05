# aster-ssh 协议

`aster-ssh` 是 Aster 的原生 SSH 运行时（Rust，基于 russh），移植自 tty7（Apache-2.0）。
本文是 Swift 侧（`Sources/AsterCore/SSHBrokerProtocol.swift`）与 Rust 侧共同遵守的契约：
任何一侧改字段都要同步改另一侧和本文。

## 1. 进程与角色

| 角色 | 命令 | 谁启动 | 说明 |
| --- | --- | --- | --- |
| broker | `aster-ssh broker --socket <path>` | App（`SSHBrokerSupervisor`），每个 App 实例一个 | 持有全部 russh 连接；stdin/stdout 是与 App 的控制通道；stdin EOF 即退出并断开全部连接 |
| client | `aster-ssh client …` | 替代原来 exec `/usr/bin/ssh` 的所有位置，包括 Ghostty Pane 子进程 | 连到 broker socket，打开一个 channel，转发 stdio、窗口大小与退出码 |
| config | `aster-ssh config list --json` / `aster-ssh config resolve <alias> --json` | App 按需调用 | 解析 `~/.ssh/config`，不依赖 broker |

broker 不读写钥匙串，不把任何秘密写入文件或日志。秘密只经控制通道（App 与 broker 之间的私有管道）传入内存。

## 2. client 命令行

```
aster-ssh client --broker <socket>
                 (--host-id <uuid> | --target <text>)
                 [--tty] [--no-prompt] [--connect-timeout <sec>]
                 [-- <remote command>]
```

- `--host-id`：已保存的主机，规格来自最近一次 `profiles.sync`。
- `--target`：alias、`user@host`、`user@host:port`、`ssh://user@host:port`、`[v6]:port`。
  broker 先按 `~/.ssh/config` 解析 alias（第一个匹配生效），再补默认端口 22 与当前用户名。
- `--tty`：请求远端 pty（大小取本地 tty；本地 stdin 是 tty 时进入 raw 模式，并转发 SIGWINCH）。
  对应 OpenSSH 的 `-tt`。
- `--no-prompt`：后台调用。缺少凭证或主机密钥需要确认时，broker 不向 App 发**交互**请求
  （`interactive:false`），App 只能用钥匙串里已有的凭证作答，否则按失败处理。对应 OpenSSH 的 `BatchMode=yes`。
- `<remote command>`：**单个字符串**，原样作为 SSH exec 请求发送（和 OpenSSH 一样由远端登录 Shell 解释），
  调用方负责 POSIX 转义（`RemoteSSHInvocation.shellQuoted`）。省略时请求交互 Shell（原生 SSH Pane）。

退出码：
- 远端命令正常结束：远端退出码；远端被信号结束：`128 + 信号值`。
- 传输层失败：`255`，并在 stderr **最后一行**输出一行结构化错误：

```
aster-ssh-error {"kind":"authenticationRequired","detail":"publickey,password rejected"}
```

`kind` 取值与 Swift `RemoteSSHFailureKind` 的 rawValue 完全一致：
`authenticationRequired`、`hostKeyUnknown`、`hostKeyChanged`、`hostUnreachable`、`timeout`、
`remoteCommandMissing`、`cancelled`、`transportFailure`。`detail` 已脱敏（不含口令、密钥内容、提示原文）。

**channel 生命周期（硬约束）**：client 进程退出或 socket 断开时，broker 必须立即对该 channel 发送 EOF
与 close。远端 pty 因此收到 SIGHUP，`aster-session terminal attach` 在 2 秒内退出并释放写租约。
禁止让 channel 挂在共享连接上等待超时（这是原来 ControlMaster 方案滞留 62 秒的问题）。

## 3. client ↔ broker 帧协议（Rust 内部）

unix socket，每帧 `type:u8 | len:u32 BE | payload`。

| type | 名称 | 方向 | payload |
| --- | --- | --- | --- |
| 1 | OPEN | c→b | JSON `{"hostID"?, "target"?, "tty":bool, "cols","rows", "term", "command"?, "interactive":bool, "connectTimeout"?}` |
| 2 | OPENED | b→c | JSON `{}` |
| 3 | STDIN | c→b | 原始字节 |
| 4 | STDOUT | b→c | 原始字节 |
| 5 | STDERR | b→c | 原始字节 |
| 6 | STDIN_EOF | c→b | 空 |
| 7 | RESIZE | c→b | JSON `{"cols","rows"}` |
| 8 | EXIT | b→c | JSON `{"status":int?, "signal":string?}` |
| 9 | ERROR | b→c | JSON `{"kind","detail"}` |

## 4. App ↔ broker 控制协议

broker 的 stdin（App→broker）与 stdout（broker→App），每行一个 JSON 对象（JSON Lines），UTF-8。
broker 的 stderr 只写脱敏日志。未知 `type` 必须忽略（向前兼容）。

### 4.1 broker → App

```jsonc
{"type":"ready","socket":"/…/broker.sock","version":"0.1.0"}

// 需要凭证。kind: password | passphrase | keyboardInteractive
{"type":"auth.request","id":"a1","endpoint":"deploy@10.0.0.5:22","kind":"password",
 "hostID":"UUID"|null,"keyFile":null,"keyDigest":null,
 "name":"","instruction":"","prompts":[{"text":"Password:","echo":false}],
 "attempt":1,"interactive":true}
// passphrase 时 keyFile 为展开后的私钥路径，keyDigest 为私钥文件内容 SHA-512 的小写 hex。

// 上一次 auth.answer 提供的秘密是否被服务器接受。App 只在 accepted=true 后才写钥匙串；
// accepted=false 且秘密来自钥匙串时，App 删除该条目。
{"type":"auth.result","id":"a1","accepted":true}

// 主机密钥需要确认。status: unknown | changed
{"type":"hostkey.confirm","id":"h1","endpoint":"10.0.0.5:22","algorithm":"ssh-ed25519",
 "fingerprint":"SHA256:…","status":"unknown","interactive":true}

// 连接状态。state: connecting | connected | reconnecting | failed | closed
{"type":"link.state","endpoint":"deploy@10.0.0.5:22","hostID":"UUID"|null,"target":"orb"|null,
 "state":"failed","attempt":2,"errorKind":"hostUnreachable","detail":"connection refused"}

{"type":"log","level":"info","message":"…"}   // 已脱敏
```

### 4.2 App → broker

```jsonc
// 全量替换已保存主机的解析后规格（已合并「默认」项、已展开跳板链）。
{"type":"profiles.sync","profiles":{"UUID":{ /* ResolvedSpec */ }}}

// password / passphrase：secret 为 null 表示取消。
// keyboardInteractive：secret 恒为 null，按 responses 判断——数组（可为空）是回答，null 是取消。
{"type":"auth.answer","id":"a1","secret":"…"|null,"responses":["…"]|null}

// accept=true：unknown 追加到 ~/.ssh/known_hosts；changed 替换旧行。
{"type":"hostkey.answer","id":"h1","accept":true}

{"type":"disconnect","endpoint":"deploy@10.0.0.5:22"}
{"type":"shutdown"}
```

`interactive:false` 的请求，App 只能从钥匙串作答，不得弹窗；取不到就回 `secret:null`。

### 4.3 ResolvedSpec

```jsonc
{
  "host":"10.0.0.5","port":22,"user":"deploy",
  "auth":"auto",                       // auto | password | publicKey | agent | keyboardInteractive
  "identityFiles":["/Users/me/.ssh/id_ed25519"],   // 已展开 ~ 与 %h/%r
  "identitiesOnly":false,              // 可省略，缺省 false。true：只用 identityFiles，见下
  "knownHostsFiles":[],                // 可省略，已展开的路径；见下
  "identityAgent":"~/agent.sock",      // 可省略，IdentityAgent 原文，由 broker 展开；见下
  "agentForward":false,
  "proxyCommand":null,                 // 字符串，经 /bin/sh -c 执行，%h/%p/%r 由 broker 展开
  "socksProxy":null,"httpProxy":null,  // {"host","port"}
  "jump":null,                         // 另一个 ResolvedSpec（递归，最深 8 层）
  "forwards":[{"kind":"local","bind":{"host":"127.0.0.1","port":8080},
               "target":{"host":"localhost","port":80},"description":""}],
  "keepaliveInterval":15,"keepaliveCountMax":3,"connectTimeout":10,
  "verifyHostKeys":true
}
```

`knownHostsFiles`（对应 OpenSSH `UserKnownHostsFile`）：
- 空数组或缺省：用 `$HOME/.ssh/known_hosts`。
- 多个文件：依次查。优先级：`@revoked` > 任一文件有同一把密钥（匹配）> 任一文件有同算法不同密钥（changed）> unknown。
  用户接受新密钥时只写**第一个**文件（changed 时替换其中的旧行，没有旧行则追加）。
- `["none"]`：没有用户级文件（`UserKnownHostsFile none`）。与 OpenSSH 一致：主机仍按 unknown 处理，
  交互确认后**本次连接**照常进行但不写任何文件（下次新连接还会再问），非交互直接失败。
- 系统级文件 `/etc/ssh/ssh_known_hosts`、`/etc/ssh/ssh_known_hosts2` 始终只读参与校验；`--target`
  经 ssh_config 解析时改用其中的 `GlobalKnownHostsFile`。

`identitiesOnly`（对应 OpenSSH `IdentitiesOnly`）：agent 里只用与 identityFiles 同一把公钥的身份签名
（公钥取自旁边的 `.pub`，没有时从未加密私钥推出），不逐个尝试 agent 里的其它密钥。
与 OpenSSH 一样，identityFiles 为空时仍回落到默认密钥（`~/.ssh/id_ed25519` 等）。

`identityAgent`（对应 OpenSSH `IdentityAgent`）：这一跳认证与 agent 转发用的 ssh-agent。App 原文照传，
broker 在连接时解析；`jump` 里的每一跳各带各的，不互相继承。
- 缺省或 null：用 broker 继承到的 `SSH_AUTH_SOCK`。
- `"none"`：不用 agent。`"SSH_AUTH_SOCK"`：同缺省。两者区分大小写。
- `"$VAR"`：socket 路径取自 broker 进程的环境变量 VAR；没设或为空就不用 agent。
- 其它：socket 路径，broker 展开 `%h/%p/%r/%u/%d/%%`、`${VAR}`（没设就不用 agent）与开头的 `~`。

endpoint 身份（凭证共享、连接复用的键）：`user@host:port`；有跳板时连接复用键再拼上跳板链，
但凭证键仍是目标自身的 `user@host:port`。

## 5. config 子命令输出

```jsonc
// aster-ssh config list --json
{"hosts":[{"alias":"orb","hostName":"127.0.0.1","user":"root","port":32222,
           "identityFiles":["…"],"proxyJump":null,"proxyCommand":null,
           "forwards":[…],"keepaliveInterval":null,"keepaliveCountMax":null,
           "forwardAgent":null,"connectTimeout":null,"strictHostKeyChecking":null,
           "userKnownHostsFiles":["~/.orbstack/ssh/known_hosts"],"globalKnownHostsFiles":[],
           "identitiesOnly":true,"identityAgent":"~/.1password/agent.sock"}],
 "ignored":[{"file":"~/.ssh/config","line":12,"option":"Match","reason":"unsupported"}]}

// aster-ssh config resolve <alias> --json   → 单个上面的 host 对象；无匹配退出码 1
```

`ignored` 就是导入时展示给用户的 ImportReport。

字段都是 ssh_config 的原文（第一个出现的指令生效），`~` 与 `%` token 由使用方展开：
- `forwardAgent`、`identitiesOnly`：布尔，没写为 null。
- `connectTimeout`：秒，没写或 `none` 为 null。
- `strictHostKeyChecking`：归一化为 `yes | no | ask | accept-new`，没写为 null。
- `identityAgent`：`IdentityAgent` 原文（路径、`$VAR`、`SSH_AUTH_SOCK` 或 `none`），没写为 null。
  `$VAR` 名字不合法或 `${` 没闭合时记进 `ignored`（`invalidValue`）。
- `userKnownHostsFiles`、`globalKnownHostsFiles`：路径数组，可多个；`none` 写成 `["none"]`；没写为空数组。

新增字段一律可省略，旧版 JSON 仍能解码。
