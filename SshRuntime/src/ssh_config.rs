//! ~/.ssh/config 解析。移植自 tty7 `src/core/ssh_config.rs`（HEAD 458c923，Apache-2.0），
//! 按 OpenSSH readconf.c 的语义修正了全局指令顺序、Include 相对路径与条件、ProxyJump/ProxyCommand 互斥等细节。
//!
//! 模块划分：`lexer` 分词与模式匹配，`values` 指令值解析，`loader` 安全读文件与 Include 展开；
//! 本文件负责对外类型、按 alias 求值和 `aster-ssh config` 命令行。

mod lexer;
mod loader;
mod values;

#[cfg(test)]
mod tests;

use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

use serde::{Deserialize, Serialize};

use lexer::host_patterns_match;
use loader::{Block, Loaded};
use values::Setting;

/// 主机与端口。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct HostPort {
    pub host: String,
    pub port: u16,
}

/// 端口转发规则，JSON 形状与 PROTOCOL.md §4.3 的 forwards 一致。
///
/// 只写端口的绑定端点落到 `127.0.0.1`，`*` 或空地址落到 `0.0.0.0`；dynamic 的 target 为空（host ""、port 0）。
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
///
/// 各字段都是 ssh_config 里写了什么就给什么：`hostName`/`user`/`port` 没写时为 null
/// （连接时分别回落到 alias、本机用户、22）；`identityFiles`、`proxyCommand` 保留原文，
/// `~` 与 `%` token 由使用方按 PROTOCOL §4.3 展开。只有 `hostName` 在这里展开 `%h`、`%%`。
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
    /// ForwardAgent；没写为 null。
    #[serde(default)]
    pub forward_agent: Option<bool>,
    /// ConnectTimeout，单位秒；没写或写 `none` 为 null。
    #[serde(default)]
    pub connect_timeout: Option<u32>,
    /// StrictHostKeyChecking，归一化为 yes | no | ask | accept-new；没写为 null。
    #[serde(default)]
    pub strict_host_key_checking: Option<String>,
}

/// 没有被采用的一行配置，即导入时展示给用户的 ImportReport 条目（PROTOCOL.md §5）。
///
/// `reason` 是原因码：unsupported | invalidValue | notFound | unreadable | notRegularFile |
/// tooLarge | tooManyFiles | includeDepth | includeCycle。Include 相关的原因记在 Include 那一行；
/// 根配置本身读失败时 `line` 为 0、`option` 为空。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct IgnoredDirective {
    /// 家目录下的路径写成 `~/…`。
    pub file: String,
    /// 从 1 开始的行号。
    pub line: usize,
    /// 关键字，保留文件里的原始大小写。
    pub option: String,
    pub reason: String,
}

/// `aster-ssh config list --json` 的输出。
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Default)]
pub struct ConfigListing {
    pub hosts: Vec<HostEntry>,
    pub ignored: Vec<IgnoredDirective>,
}

/// 按 OpenSSH 语义（第一个匹配生效、支持 Include）解析 `$HOME/.ssh/config` 里的 alias。
/// 没有任何 Host 匹配时返回 None；HOME 未设置时同样返回 None。
#[allow(dead_code)] // rust-core 包接入 broker 前，main 只走 run_cli
pub fn resolve(alias: &str) -> Option<HostEntry> {
    let home = home_dir()?;
    resolve_in(&home.join(".ssh/config"), &home, alias)
}

/// 解析指定配置文件里的 alias。`home` 用于展开 Include 里的 `~` 和相对路径（相对 `home/.ssh/`）。
///
/// 只有显式的 Host 块（含 `Host *`）匹配才算命中；只命中第一个 Host 之前的全局指令不算。
pub fn resolve_in(config_path: &Path, home: &Path, alias: &str) -> Option<HostEntry> {
    resolve_loaded(&loader::load(config_path, home), alias)
}

/// 列出配置里所有具体 alias（不含通配符和取反模式，按首次出现顺序），每个都完整求值，并附带 ignored。
pub fn list_in(config_path: &Path, home: &Path) -> ConfigListing {
    let loaded = loader::load(config_path, home);
    let hosts = loaded
        .aliases
        .iter()
        // 嵌在不匹配的 Host 里的 Include、或被同一行 `!` 排除的 alias 实际连不上，这里一并滤掉
        .filter_map(|alias| resolve_loaded(&loaded, alias))
        .collect();
    ConfigListing {
        hosts,
        ignored: loaded.ignored,
    }
}

/// 在已加载的配置上对一个 alias 求值。
fn resolve_loaded(loaded: &Loaded, alias: &str) -> Option<HostEntry> {
    let matched: Vec<&Block> = loaded
        .blocks
        .iter()
        .filter(|block| block_matches(block, alias))
        .collect();
    if !matched.iter().any(|block| !block.conditions.is_empty()) {
        return None;
    }
    let mut acc = Accumulator::default();
    for block in matched {
        for setting in &block.settings {
            acc.apply(setting);
        }
    }
    Some(acc.finish(alias))
}

/// 块的条件链是否全部匹配（空链无条件生效）。
fn block_matches(block: &Block, alias: &str) -> bool {
    block
        .conditions
        .iter()
        .all(|patterns| host_patterns_match(patterns, alias))
}

/// 按出现顺序累积指令：单值字段第一个生效，IdentityFile 与转发累加并去重（与 OpenSSH 相同）。
#[derive(Default)]
struct Accumulator {
    entry: HostEntry,
    /// ProxyJump 与 ProxyCommand 互斥：谁先出现谁生效，后出现的另一个被忽略（readconf.c 的行为）。
    proxy_decided: bool,
    /// `ConnectTimeout none` 也占住第一个值，所以单独记。
    connect_timeout_decided: bool,
}

impl Accumulator {
    /// 应用一条指令。
    fn apply(&mut self, setting: &Setting) {
        let entry = &mut self.entry;
        match setting {
            Setting::HostName(v) => {
                entry.host_name.get_or_insert_with(|| v.clone());
            }
            Setting::User(v) => {
                entry.user.get_or_insert_with(|| v.clone());
            }
            Setting::Port(p) => {
                entry.port.get_or_insert(*p);
            }
            Setting::IdentityFile(f) => {
                if !entry.identity_files.contains(f) {
                    entry.identity_files.push(f.clone());
                }
            }
            Setting::ProxyJump(v) if !self.proxy_decided => {
                self.proxy_decided = true;
                entry.proxy_jump = v.clone();
            }
            Setting::ProxyCommand(v) if !self.proxy_decided => {
                self.proxy_decided = true;
                entry.proxy_command = v.clone();
            }
            Setting::ProxyJump(_) | Setting::ProxyCommand(_) => {}
            Setting::Forward(rule) => {
                if !entry.forwards.contains(rule) {
                    entry.forwards.push(rule.clone());
                }
            }
            Setting::ServerAliveInterval(n) => {
                entry.keepalive_interval.get_or_insert(*n);
            }
            Setting::ServerAliveCountMax(n) => {
                entry.keepalive_count_max.get_or_insert(*n);
            }
            Setting::ForwardAgent(b) => {
                entry.forward_agent.get_or_insert(*b);
            }
            Setting::ConnectTimeout(v) if !self.connect_timeout_decided => {
                self.connect_timeout_decided = true;
                entry.connect_timeout = *v;
            }
            Setting::ConnectTimeout(_) => {}
            Setting::StrictHostKeyChecking(v) => {
                entry
                    .strict_host_key_checking
                    .get_or_insert_with(|| v.clone());
            }
        }
    }

    /// 填入 alias，并展开 HostName 里的 token。
    fn finish(mut self, alias: &str) -> HostEntry {
        self.entry.alias = alias.to_string();
        self.entry.host_name = self
            .entry
            .host_name
            .map(|h| expand_hostname_tokens(&h, alias));
        self.entry
    }
}

/// 展开 HostName 的 token。OpenSSH 的 HostName 只接受 `%h`（原始 alias）和 `%%`；未知 token 原样保留。
fn expand_hostname_tokens(hostname: &str, alias: &str) -> String {
    let mut out = String::with_capacity(hostname.len());
    let mut chars = hostname.chars();
    while let Some(ch) = chars.next() {
        if ch != '%' {
            out.push(ch);
            continue;
        }
        match chars.next() {
            Some('h') => out.push_str(alias),
            Some('%') => out.push('%'),
            Some(other) => {
                out.push('%');
                out.push(other);
            }
            None => out.push('%'),
        }
    }
    out
}

/// 当前用户的家目录：`ASTER_SSH_HOME` 优先于 `$HOME`（空值视为未设置），与 broker
/// 找 known_hosts、默认密钥用同一个目录，测试把它指到临时目录时两边不会分叉。
fn home_dir() -> Option<PathBuf> {
    ["ASTER_SSH_HOME", "HOME"]
        .iter()
        .filter_map(std::env::var_os)
        .find(|value| !value.is_empty())
        .map(PathBuf::from)
}

/// `aster-ssh config` 的子命令。
#[derive(Debug, PartialEq, Eq)]
enum CliCommand {
    List,
    Resolve(String),
}

const USAGE: &str = "usage: aster-ssh config (list --json | resolve <alias> --json)";

/// 解析 `config` 之后的参数；目前只有 JSON 输出，所以 `--json` 必须写，留出以后加文本格式的余地。
fn parse_cli(args: &[String]) -> Result<CliCommand, String> {
    let mut json = false;
    let mut positional = Vec::new();
    for arg in args {
        if arg == "--json" {
            json = true;
        } else if arg.starts_with('-') {
            return Err(format!("unknown option: {arg}"));
        } else {
            positional.push(arg.as_str());
        }
    }
    let command = match positional.as_slice() {
        ["list"] => CliCommand::List,
        ["resolve", alias] => CliCommand::Resolve(alias.to_string()),
        _ => return Err("expected `list` or `resolve <alias>`".to_string()),
    };
    if !json {
        return Err("--json is required".to_string());
    }
    Ok(command)
}

/// `aster-ssh config (list|resolve <alias>) --json` 入口。
///
/// 退出码：0 成功；1 resolve 没有匹配、HOME 未设置或写 stdout 失败；2 参数错误。
pub fn run_cli(args: &[String]) -> ExitCode {
    let command = match parse_cli(args) {
        Ok(command) => command,
        Err(message) => {
            eprintln!("aster-ssh config: {message}\n{USAGE}");
            return ExitCode::from(2);
        }
    };
    let Some(home) = home_dir() else {
        eprintln!("aster-ssh config: HOME is not set");
        return ExitCode::from(1);
    };
    let config = home.join(".ssh/config");
    let json = match command {
        CliCommand::List => serde_json::to_string(&list_in(&config, &home)),
        CliCommand::Resolve(alias) => match resolve_in(&config, &home, &alias) {
            Some(entry) => serde_json::to_string(&entry),
            None => {
                eprintln!("aster-ssh config: no Host matches {alias:?}");
                return ExitCode::from(1);
            }
        },
    };
    let written = json.map_err(|e| e.to_string()).and_then(|text| {
        let mut out = std::io::stdout().lock();
        writeln!(out, "{text}")
            .and_then(|_| out.flush())
            .map_err(|e| e.to_string())
    });
    match written {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            eprintln!("aster-ssh config: {message}");
            ExitCode::from(1)
        }
    }
}
