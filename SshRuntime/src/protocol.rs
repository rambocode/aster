//! PROTOCOL.md 的 Rust 形状：ResolvedSpec、client↔broker 帧协议、App↔broker 控制消息。
//!
//! 字段名与 Swift 侧 `SSHBrokerProtocol.swift` / `SSHHostProfile.swift` 一一对应，
//! 改这里必须同步改 PROTOCOL.md 与 Swift。

use std::collections::BTreeMap;
use std::fmt;

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

/// 跳板链最大深度，与 Swift `SSHHostResolver.maximumJumpDepth` 一致。
pub const MAX_JUMP_DEPTH: usize = 8;

// MARK: - 失败分类

/// 传输层失败的分类；rawValue 与 Swift `RemoteSSHFailureKind` 完全一致。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum FailureKind {
    AuthenticationRequired,
    HostKeyUnknown,
    HostKeyChanged,
    HostUnreachable,
    Timeout,
    RemoteCommandMissing,
    Cancelled,
    TransportFailure,
}

/// 一次失败：分类 + 已脱敏的说明。broker 与 client 之间、日志里都只传这个。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct SshFailure {
    pub kind: FailureKind,
    pub detail: String,
}

impl SshFailure {
    /// 构造一个失败；detail 只能放不含秘密的文字。
    pub fn new(kind: FailureKind, detail: impl Into<String>) -> Self {
        Self {
            kind,
            detail: detail.into(),
        }
    }
}

impl fmt::Display for SshFailure {
    /// 形如 `hostUnreachable: connection refused`，用于日志。
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let kind = serde_json::to_value(self.kind)
            .ok()
            .and_then(|v| v.as_str().map(str::to_string))
            .unwrap_or_default();
        write!(f, "{kind}: {}", self.detail)
    }
}

impl std::error::Error for SshFailure {}

// MARK: - ResolvedSpec（§4.3）

/// 主机与端口。
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct HostPort {
    pub host: String,
    pub port: u16,
}

/// 认证方式。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AuthMode {
    #[default]
    Auto,
    Password,
    PublicKey,
    Agent,
    KeyboardInteractive,
}

/// 转发类型：本地（-L）、远端（-R）、动态 SOCKS（-D）。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ForwardKind {
    Local,
    Remote,
    Dynamic,
}

/// 一条静态端口转发规则。动态转发忽略 `target`。
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct ForwardRule {
    pub kind: ForwardKind,
    pub bind: HostPort,
    pub target: HostPort,
    #[serde(default)]
    pub description: String,
}

/// broker 可直接使用的连接规格（App 已合并默认项、展开跳板链）。
///
/// Swift 默认省略值为 nil 的可选字段，所以这里所有可选/带默认值的字段都要 `serde(default)`。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedSpec {
    pub host: String,
    pub port: u16,
    pub user: String,
    #[serde(default)]
    pub auth: AuthMode,
    #[serde(default)]
    pub identity_files: Vec<String>,
    #[serde(default)]
    pub agent_forward: bool,
    #[serde(default)]
    pub proxy_command: Option<String>,
    #[serde(default)]
    pub socks_proxy: Option<HostPort>,
    #[serde(default)]
    pub http_proxy: Option<HostPort>,
    #[serde(default)]
    pub jump: Option<Box<ResolvedSpec>>,
    #[serde(default)]
    pub forwards: Vec<ForwardRule>,
    #[serde(default = "default_keepalive_interval")]
    pub keepalive_interval: u32,
    #[serde(default = "default_keepalive_count_max")]
    pub keepalive_count_max: u32,
    #[serde(default = "default_connect_timeout")]
    pub connect_timeout: u32,
    #[serde(default = "default_true")]
    pub verify_host_keys: bool,
}

/// keepalive 间隔缺省值（秒）。
pub fn default_keepalive_interval() -> u32 {
    15
}

/// keepalive 最大未应答次数缺省值。
pub fn default_keepalive_count_max() -> u32 {
    3
}

/// 连接超时缺省值（秒）。
pub fn default_connect_timeout() -> u32 {
    10
}

/// serde 缺省为 true 的布尔字段。
fn default_true() -> bool {
    true
}

/// IPv6 字面量加方括号，其它原样返回。
pub fn bracket_host(host: &str) -> String {
    if host.contains(':') {
        format!("[{host}]")
    } else {
        host.to_string()
    }
}

impl ResolvedSpec {
    /// 只有主机、端口、用户的最小规格，其它取缺省值。
    pub fn basic(host: impl Into<String>, port: u16, user: impl Into<String>) -> Self {
        Self {
            host: host.into(),
            port,
            user: user.into(),
            auth: AuthMode::Auto,
            identity_files: Vec::new(),
            agent_forward: false,
            proxy_command: None,
            socks_proxy: None,
            http_proxy: None,
            jump: None,
            forwards: Vec::new(),
            keepalive_interval: default_keepalive_interval(),
            keepalive_count_max: default_keepalive_count_max(),
            connect_timeout: default_connect_timeout(),
            verify_host_keys: true,
        }
    }

    /// 凭证键 `user@host:port`，与 Swift `credentialEndpoint` 相同（IPv6 加方括号）。
    pub fn credential_endpoint(&self) -> String {
        format!("{}@{}:{}", self.user, bracket_host(&self.host), self.port)
    }

    /// 主机密钥确认用的 `host:port`。
    pub fn host_endpoint(&self) -> String {
        format!("{}:{}", bracket_host(&self.host), self.port)
    }

    /// 连接复用键：目标 endpoint + 代理方式 + 跳板链。
    ///
    /// 代理也拼进去，是因为同一 endpoint 走不同代理得到的是两条不同的传输，不能互相顶替。
    pub fn connection_key(&self) -> String {
        let mut key = self.credential_endpoint();
        if let Some(cmd) = &self.proxy_command {
            key.push_str(&format!(" proxy-command={cmd}"));
        } else if let Some(p) = &self.socks_proxy {
            key.push_str(&format!(" socks={}:{}", bracket_host(&p.host), p.port));
        } else if let Some(p) = &self.http_proxy {
            key.push_str(&format!(" http={}:{}", bracket_host(&p.host), p.port));
        }
        if let Some(jump) = &self.jump {
            key.push_str(" via ");
            key.push_str(&jump.connection_key());
        }
        key
    }

    /// 跳板链深度（不含自身）。
    pub fn jump_depth(&self) -> usize {
        let mut depth = 0;
        let mut cur = self.jump.as_deref();
        while let Some(j) = cur {
            depth += 1;
            cur = j.jump.as_deref();
        }
        depth
    }
}

// MARK: - client ↔ broker 帧（§3）

/// 帧类型常量。
pub mod frame {
    pub const OPEN: u8 = 1;
    pub const OPENED: u8 = 2;
    pub const STDIN: u8 = 3;
    pub const STDOUT: u8 = 4;
    pub const STDERR: u8 = 5;
    pub const STDIN_EOF: u8 = 6;
    pub const RESIZE: u8 = 7;
    pub const EXIT: u8 = 8;
    pub const ERROR: u8 = 9;
}

/// 单帧 payload 上限。client 每次最多发 32 KiB，留足余量防止坏帧耗尽内存。
pub const MAX_FRAME_LEN: usize = 4 * 1024 * 1024;

/// 一帧：类型 + payload。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Frame {
    pub kind: u8,
    pub payload: Vec<u8>,
}

impl Frame {
    /// 构造一帧。
    pub fn new(kind: u8, payload: impl Into<Vec<u8>>) -> Self {
        Self {
            kind,
            payload: payload.into(),
        }
    }

    /// payload 为 JSON 的帧。
    pub fn json<T: Serialize>(kind: u8, value: &T) -> Self {
        Self::new(kind, serde_json::to_vec(value).unwrap_or_default())
    }

    /// 把 payload 当 JSON 解析。
    pub fn parse<T: for<'de> Deserialize<'de>>(&self) -> Result<T, serde_json::Error> {
        serde_json::from_slice(&self.payload)
    }
}

/// 读一帧。对端正常关闭（帧边界处 EOF）返回 `Ok(None)`。
pub async fn read_frame<R: AsyncRead + Unpin>(r: &mut R) -> std::io::Result<Option<Frame>> {
    let mut head = [0u8; 5];
    // 第一个字节单独读，才能区分「帧边界处的干净 EOF」和「帧读到一半断开」。
    match r.read(&mut head[..1]).await? {
        0 => return Ok(None),
        _ => r.read_exact(&mut head[1..]).await?,
    };
    let len = u32::from_be_bytes([head[1], head[2], head[3], head[4]]) as usize;
    if len > MAX_FRAME_LEN {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidData,
            format!("frame too large: {len} bytes"),
        ));
    }
    let mut payload = vec![0u8; len];
    r.read_exact(&mut payload).await?;
    Ok(Some(Frame {
        kind: head[0],
        payload,
    }))
}

/// 写一帧并 flush。
pub async fn write_frame<W: AsyncWrite + Unpin>(w: &mut W, frame: &Frame) -> std::io::Result<()> {
    let mut buf = Vec::with_capacity(5 + frame.payload.len());
    buf.push(frame.kind);
    buf.extend_from_slice(&(frame.payload.len() as u32).to_be_bytes());
    buf.extend_from_slice(&frame.payload);
    w.write_all(&buf).await?;
    w.flush().await
}

/// OPEN 帧的 payload。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenRequest {
    #[serde(rename = "hostID", default, skip_serializing_if = "Option::is_none")]
    pub host_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub target: Option<String>,
    #[serde(default)]
    pub tty: bool,
    #[serde(default = "default_cols")]
    pub cols: u32,
    #[serde(default = "default_rows")]
    pub rows: u32,
    #[serde(default = "default_term")]
    pub term: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub command: Option<String>,
    #[serde(default = "default_true")]
    pub interactive: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub connect_timeout: Option<u32>,
}

/// 缺省列数。
fn default_cols() -> u32 {
    80
}

/// 缺省行数。
fn default_rows() -> u32 {
    24
}

/// 缺省 TERM。
pub fn default_term() -> String {
    "xterm-256color".to_string()
}

/// RESIZE 帧的 payload。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct ResizeRequest {
    pub cols: u32,
    pub rows: u32,
}

/// EXIT 帧的 payload：正常结束带 status，被信号结束带 signal（不含 `SIG` 前缀）。
#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct ExitReport {
    #[serde(default)]
    pub status: Option<i32>,
    #[serde(default)]
    pub signal: Option<String>,
}

// MARK: - App ↔ broker 控制消息（§4）

/// 键盘交互的一条提示。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthPrompt {
    pub text: String,
    pub echo: bool,
}

/// 凭证请求类型。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum AuthRequestKind {
    Password,
    Passphrase,
    KeyboardInteractive,
}

/// `auth.request` 的字段。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AuthRequest {
    pub id: String,
    pub endpoint: String,
    pub kind: AuthRequestKind,
    #[serde(rename = "hostID", default)]
    pub host_id: Option<String>,
    #[serde(default)]
    pub key_file: Option<String>,
    #[serde(default)]
    pub key_digest: Option<String>,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub instruction: String,
    #[serde(default)]
    pub prompts: Vec<AuthPrompt>,
    pub attempt: u32,
    pub interactive: bool,
}

/// 主机密钥确认状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HostKeyStatusKind {
    Unknown,
    Changed,
}

/// `hostkey.confirm` 的字段。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostKeyConfirm {
    pub id: String,
    pub endpoint: String,
    pub algorithm: String,
    pub fingerprint: String,
    pub status: HostKeyStatusKind,
    pub interactive: bool,
}

/// 连接状态。
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum LinkState {
    Connecting,
    Connected,
    Reconnecting,
    Failed,
    Closed,
}

/// `link.state` 的字段。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LinkStateEvent {
    pub endpoint: String,
    #[serde(rename = "hostID", default)]
    pub host_id: Option<String>,
    #[serde(default)]
    pub target: Option<String>,
    pub state: LinkState,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attempt: Option<u32>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error_kind: Option<FailureKind>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub detail: Option<String>,
}

/// broker → App 的一行。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum BrokerEvent {
    #[serde(rename = "ready")]
    Ready { socket: String, version: String },
    #[serde(rename = "auth.request")]
    AuthRequest(AuthRequest),
    #[serde(rename = "auth.result")]
    AuthResult { id: String, accepted: bool },
    #[serde(rename = "hostkey.confirm")]
    HostKeyConfirm(HostKeyConfirm),
    #[serde(rename = "link.state")]
    LinkState(LinkStateEvent),
    #[serde(rename = "log")]
    Log { level: String, message: String },
}

/// App → broker 的一行。未知 `type` 解析成 `Unknown`，调用方忽略。
///
/// 不 derive `Debug`：`auth.answer` 带秘密，Debug 手写成只输出类型名。
#[derive(Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type")]
pub enum AppCommand {
    /// profiles 逐条保留原始 JSON，单条坏数据不影响其它主机。
    #[serde(rename = "profiles.sync")]
    ProfilesSync {
        profiles: BTreeMap<String, serde_json::Value>,
    },
    #[serde(rename = "auth.answer")]
    AuthAnswer {
        id: String,
        #[serde(default)]
        secret: Option<String>,
        #[serde(default)]
        responses: Option<Vec<String>>,
    },
    #[serde(rename = "hostkey.answer")]
    HostKeyAnswer { id: String, accept: bool },
    #[serde(rename = "disconnect")]
    Disconnect { endpoint: String },
    #[serde(rename = "shutdown")]
    Shutdown,
    #[serde(other)]
    Unknown,
}

impl fmt::Display for AppCommand {
    /// 只输出消息类型，保证日志里不会出现口令等内容。
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        let name = match self {
            AppCommand::ProfilesSync { .. } => "profiles.sync",
            AppCommand::AuthAnswer { .. } => "auth.answer",
            AppCommand::HostKeyAnswer { .. } => "hostkey.answer",
            AppCommand::Disconnect { .. } => "disconnect",
            AppCommand::Shutdown => "shutdown",
            AppCommand::Unknown => "unknown",
        };
        f.write_str(name)
    }
}

impl fmt::Debug for AppCommand {
    /// 与 Display 相同，只输出类型名，避免 `{:?}` 泄露秘密。
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        fmt::Display::fmt(self, f)
    }
}

#[cfg(test)]
#[path = "protocol_tests.rs"]
mod tests;
