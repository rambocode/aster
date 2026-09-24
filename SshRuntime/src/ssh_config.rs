//! ~/.ssh/config 解析（移植自 tty7 `src/core/ssh_config.rs`，Apache-2.0）。P0 占位：
//! 接口已定，rust-config 包补全实现；rust-core 包只调用 `resolve`，不改本文件。

use std::process::ExitCode;

use serde::{Deserialize, Serialize};

/// 主机与端口。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct HostPort {
    pub host: String,
    pub port: u16,
}

/// 端口转发规则，JSON 形状与 PROTOCOL.md §4.3 的 forwards 一致。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ForwardRule {
    /// local | remote | dynamic
    pub kind: String,
    pub bind: HostPort,
    pub target: HostPort,
    #[serde(default)]
    pub description: String,
}

/// 解析后的一个 Host 条目，JSON 形状与 PROTOCOL.md §5 一致（camelCase）。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct HostEntry {
    pub alias: String,
    pub host_name: Option<String>,
    pub user: Option<String>,
    pub port: Option<u16>,
    pub identity_files: Vec<String>,
    /// 原文，可能是逗号分隔的跳板链，每一跳是 alias 或 `user@host:port`。
    pub proxy_jump: Option<String>,
    pub proxy_command: Option<String>,
    pub forwards: Vec<ForwardRule>,
    pub keepalive_interval: Option<u32>,
    pub keepalive_count_max: Option<u32>,
}

/// 按 OpenSSH 语义（第一个匹配生效、支持 Include）解析 `$HOME/.ssh/config` 里的 alias。
/// 没有任何 Host 匹配时返回 None。
pub fn resolve(_alias: &str) -> Option<HostEntry> {
    None
}

/// `aster-ssh config (list|resolve <alias>) --json` 入口。
pub fn run_cli(_args: &[String]) -> ExitCode {
    eprintln!("aster-ssh config: not implemented");
    ExitCode::from(2)
}
