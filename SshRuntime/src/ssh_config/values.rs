//! 指令值解析：把 `关键字 值` 转成类型化的 Setting，失败时给出原因。
//! 端口转发语法移植自 tty7 `src/core/ssh_config.rs`（HEAD 458c923，Apache-2.0），补了 `addr/port` 与校验。

use super::lexer::split_words;
use super::{ForwardRule, HostPort};

/// 支持的一条指令解析后的值。只有这里列出的关键字会进入 HostEntry，其余都记进 ignored。
#[derive(Debug, Clone, PartialEq, Eq)]
pub(super) enum Setting {
    HostName(String),
    User(String),
    Port(u16),
    IdentityFile(String),
    /// None 表示显式写了 `none`：它同样占住「第一个值」，后面的 ProxyJump/ProxyCommand 不再生效。
    ProxyJump(Option<String>),
    ProxyCommand(Option<String>),
    Forward(ForwardRule),
    ServerAliveInterval(u32),
    ServerAliveCountMax(u32),
    ForwardAgent(bool),
    /// None 表示 `ConnectTimeout none`。
    ConnectTimeout(Option<u32>),
    /// 归一化成 yes | no | ask | accept-new。
    StrictHostKeyChecking(String),
}

/// 指令没有被采用的原因。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(super) enum Rejected {
    /// 关键字或这种写法 Aster 不支持。
    Unsupported,
    /// 关键字支持，但值不合法。
    Invalid,
}

impl Rejected {
    /// ignored 条目里 `reason` 字段的原因码。
    pub(super) fn code(self) -> &'static str {
        match self {
            Rejected::Unsupported => "unsupported",
            Rejected::Invalid => "invalidValue",
        }
    }
}

/// 解析一条指令。`key` 必须已经转成小写；`rest` 是关键字之后的原文。
pub(super) fn parse_setting(key: &str, rest: &str) -> Result<Setting, Rejected> {
    match key {
        "hostname" => single(rest).map(Setting::HostName),
        "user" => single(rest).map(Setting::User),
        "port" => single(rest)
            .and_then(|v| parse_port(&v, false))
            .map(Setting::Port),
        "identityfile" => single(rest).map(Setting::IdentityFile),
        "proxyjump" => single(rest).map(|v| Setting::ProxyJump(none_or(v))),
        // ProxyCommand 取行尾原文：命令里的 `#`、引号都属于命令本身，OpenSSH 同样不对它分词。
        "proxycommand" if rest.is_empty() => Err(Rejected::Invalid),
        "proxycommand" => Ok(Setting::ProxyCommand(none_or(rest.to_string()))),
        "localforward" => words(rest).and_then(|w| parse_forward("local", &w)),
        "remoteforward" => words(rest).and_then(|w| parse_forward("remote", &w)),
        "dynamicforward" => words(rest).and_then(|w| parse_forward("dynamic", &w)),
        "serveraliveinterval" => single(rest)
            .and_then(|v| v.parse().map_err(|_| Rejected::Invalid))
            .map(Setting::ServerAliveInterval),
        "serveralivecountmax" => single(rest)
            .and_then(|v| v.parse().map_err(|_| Rejected::Invalid))
            .map(Setting::ServerAliveCountMax),
        "forwardagent" => single(rest).map(|v| Setting::ForwardAgent(forward_agent_enabled(&v))),
        "connecttimeout" => single(rest).and_then(|v| match v.eq_ignore_ascii_case("none") {
            true => Ok(Setting::ConnectTimeout(None)),
            false => parse_time(&v).map(|s| Setting::ConnectTimeout(Some(s))),
        }),
        "stricthostkeychecking" => single(rest)
            .and_then(|v| strict_host_key_checking(&v))
            .map(Setting::StrictHostKeyChecking),
        _ => Err(Rejected::Unsupported),
    }
}

/// 分词；引号不配对时视为值不合法。
fn words(rest: &str) -> Result<Vec<String>, Rejected> {
    split_words(rest).ok_or(Rejected::Invalid)
}

/// 取唯一的一个参数；缺参数或多出参数都算不合法（OpenSSH 对这些关键字同样报错）。
fn single(rest: &str) -> Result<String, Rejected> {
    let mut list = words(rest)?;
    match list.len() {
        1 => Ok(list.remove(0)),
        _ => Err(Rejected::Invalid),
    }
}

/// `none`（大小写不敏感）表示显式关闭。
fn none_or(value: String) -> Option<String> {
    (!value.eq_ignore_ascii_case("none")).then_some(value)
}

/// ForwardAgent 取值：yes/true 开启、no/false 关闭；
/// 其它值（套接字路径或 `$ENV`）在 OpenSSH 里表示「用指定的 agent 转发」，同样视为开启。
fn forward_agent_enabled(value: &str) -> bool {
    !matches!(value.to_ascii_lowercase().as_str(), "no" | "false")
}

/// StrictHostKeyChecking 归一化：off/false 同 no，true 同 yes。
fn strict_host_key_checking(value: &str) -> Result<String, Rejected> {
    let normalized = match value.to_ascii_lowercase().as_str() {
        "yes" | "true" => "yes",
        "no" | "off" | "false" => "no",
        "ask" => "ask",
        "accept-new" => "accept-new",
        _ => return Err(Rejected::Invalid),
    };
    Ok(normalized.to_string())
}

/// OpenSSH `convtime`：`30`、`30s`、`1m30s`、`2h` 这类时间写法，换算成秒。
fn parse_time(value: &str) -> Result<u32, Rejected> {
    let mut total: u64 = 0;
    let mut segments = 0;
    let mut digits = String::new();
    // 在末尾补一个 's'，让最后一段没写单位的数字也按秒结算
    for c in value.chars().chain(std::iter::once('s')) {
        if c.is_ascii_digit() {
            digits.push(c);
            continue;
        }
        if digits.is_empty() {
            // 末尾补的 's' 前面没有数字是正常收尾；其它位置出现孤立单位就是写错了
            if segments > 0 && c == 's' {
                break;
            }
            return Err(Rejected::Invalid);
        }
        let unit: u64 = match c.to_ascii_lowercase() {
            's' => 1,
            'm' => 60,
            'h' => 3600,
            'd' => 86_400,
            'w' => 604_800,
            _ => return Err(Rejected::Invalid),
        };
        let n: u64 = digits.parse().map_err(|_| Rejected::Invalid)?;
        total = n
            .checked_mul(unit)
            .and_then(|s| total.checked_add(s))
            .ok_or(Rejected::Invalid)?;
        digits.clear();
        segments += 1;
    }
    u32::try_from(total).map_err(|_| Rejected::Invalid)
}

/// 端口号；`allow_zero` 只给 RemoteForward 的绑定端口用（0 表示让服务端分配）。
fn parse_port(value: &str, allow_zero: bool) -> Result<u16, Rejected> {
    match value.parse::<u16>() {
        Ok(0) if !allow_zero => Err(Rejected::Invalid),
        Ok(port) => Ok(port),
        Err(_) => Err(Rejected::Invalid),
    }
}

/// 解析三种转发。Local/Remote 需要 `绑定 目标` 两个参数，Dynamic 只要一个绑定端点。
fn parse_forward(kind: &str, args: &[String]) -> Result<Setting, Rejected> {
    let (bind, target) = match (kind, args) {
        ("dynamic", [bind]) => (parse_bind(bind, false)?, HostPort::default()),
        ("local", [bind, target]) => (parse_bind(bind, false)?, parse_target(target)?),
        ("remote", [bind, target]) => (parse_bind(bind, true)?, parse_target(target)?),
        // RemoteForward 只写一个参数是远端 SOCKS（反向动态转发），暂不支持
        ("remote", [_]) => return Err(Rejected::Unsupported),
        _ => return Err(Rejected::Invalid),
    };
    Ok(Setting::Forward(ForwardRule {
        kind: kind.to_string(),
        bind,
        target,
        description: String::new(),
    }))
}

/// 绑定端点。只写端口时绑回环 `127.0.0.1`（OpenSSH 默认 GatewayPorts no 的效果）；
/// 显式写空地址或 `*` 表示所有网卡，统一成 `0.0.0.0`，让下游拿到可以直接 bind 的地址。
fn parse_bind(token: &str, allow_zero: bool) -> Result<HostPort, Rejected> {
    let (host, port) = split_endpoint(token)?;
    let host = match host.as_deref() {
        None => "127.0.0.1".to_string(),
        Some("") | Some("*") => "0.0.0.0".to_string(),
        Some(h) => h.to_string(),
    };
    Ok(HostPort {
        host,
        port: parse_port(port, allow_zero)?,
    })
}

/// 转发目标端点，必须带主机名。
fn parse_target(token: &str) -> Result<HostPort, Rejected> {
    match split_endpoint(token)? {
        (Some(host), port) if !host.is_empty() => Ok(HostPort {
            host,
            port: parse_port(port, false)?,
        }),
        _ => Err(Rejected::Invalid),
    }
}

/// 拆出 `(主机, 端口原文)`，支持 `[addr]:port`、`addr:port`、`addr/port` 和只写 `port`。
///
/// 以 `/` 开头的是 Unix 域套接字转发，暂不支持。不带方括号的 IPv6（`::1:8080`）有歧义，
/// OpenSSH 也不接受，按不合法处理；IPv6 要写 `[::1]:8080` 或 `::1/8080`。
fn split_endpoint(token: &str) -> Result<(Option<String>, &str), Rejected> {
    if token.starts_with('/') {
        return Err(Rejected::Unsupported);
    }
    if let Some(rest) = token.strip_prefix('[') {
        let close = rest.find(']').ok_or(Rejected::Invalid)?;
        let port = rest[close + 1..]
            .strip_prefix([':', '/'])
            .ok_or(Rejected::Invalid)?;
        return Ok((Some(rest[..close].to_string()), port));
    }
    // `addr/port` 允许地址里带冒号（IPv6），`addr:port` 不允许
    if let Some(ix) = token.rfind('/') {
        return Ok((Some(token[..ix].to_string()), &token[ix + 1..]));
    }
    match token.split_once(':') {
        Some((_, port)) if port.contains(':') => Err(Rejected::Invalid),
        Some((host, port)) => Ok((Some(host.to_string()), port)),
        None => Ok((None, token)),
    }
}
