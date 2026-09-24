//! `--target` 文本 → ResolvedSpec。
//!
//! `ssh://…`、`user@host[:port]`、`host:port`、`[v6]:port` 按 quick-connect 语义解析
//! （最后一个 `@` 之前是用户名）；其它文本当作 alias。两种写法都会按 OpenSSH 的习惯
//! 再用 `~/.ssh/config` 里匹配主机名的条目补全（HostName、User、Port、IdentityFile、
//! ProxyJump、ProxyCommand、转发、keepalive），文本里显式写出的用户与端口优先。

use std::path::Path;

use crate::env::{expand_tilde, expand_tokens};
use crate::protocol::{
    default_connect_timeout, default_keepalive_count_max, default_keepalive_interval, AuthMode,
    FailureKind, ForwardKind, ForwardRule, HostPort, ResolvedSpec, SshFailure, MAX_JUMP_DEPTH,
};
use crate::ssh_config::HostEntry;

/// quick-connect 文本拆出的三段。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QuickTarget {
    pub user: Option<String>,
    pub host: String,
    pub port: Option<u16>,
}

/// 解析 quick-connect 写法；不是这种写法（即 alias）返回 None，格式错误返回 Err。
pub fn parse_quick(text: &str) -> Result<Option<QuickTarget>, SshFailure> {
    let bad = || {
        SshFailure::new(
            FailureKind::TransportFailure,
            format!("invalid target '{text}'"),
        )
    };
    let text = text.trim();
    let (body, is_url) = match text.strip_prefix("ssh://") {
        Some(rest) => (rest.trim_end_matches('/'), true),
        None => (text, false),
    };
    let (user, hostport) = match body.rfind('@') {
        Some(i) => (
            Some(body[..i].to_string()).filter(|u| !u.is_empty()),
            &body[i + 1..],
        ),
        None => (None, body),
    };
    let (host, port) = if let Some(rest) = hostport.strip_prefix('[') {
        let close = rest.find(']').ok_or_else(bad)?;
        let host = &rest[..close];
        let port = match &rest[close + 1..] {
            "" => None,
            p => Some(
                p.strip_prefix(':')
                    .ok_or_else(bad)?
                    .parse::<u16>()
                    .map_err(|_| bad())?,
            ),
        };
        (host.to_string(), port)
    } else {
        match hostport.rsplit_once(':') {
            // 恰好一个冒号才是 host:port；多个冒号是没加方括号的 IPv6 字面量。
            Some((h, p)) if !h.contains(':') => {
                (h.to_string(), Some(p.parse::<u16>().map_err(|_| bad())?))
            }
            _ => (hostport.to_string(), None),
        }
    };
    if host.is_empty() {
        return Err(bad());
    }
    let quick = is_url || user.is_some() || port.is_some() || hostport.starts_with('[');
    Ok(quick.then_some(QuickTarget { user, host, port }))
}

/// 解析时需要的外部信息。
pub struct Resolver<'a> {
    pub home: &'a Path,
    pub local_user: &'a str,
    /// ssh_config 查询；生产环境是 `ssh_config::resolve`，测试注入假数据。
    pub lookup: &'a dyn Fn(&str) -> Option<HostEntry>,
    pub connect_timeout: Option<u32>,
}

impl Resolver<'_> {
    /// 把 target 文本解析成完整规格。
    pub fn resolve(&self, text: &str) -> Result<ResolvedSpec, SshFailure> {
        self.resolve_at(text, 0)
    }

    /// 带递归深度的解析（ProxyJump 的每一跳也走这里）。
    fn resolve_at(&self, text: &str, depth: usize) -> Result<ResolvedSpec, SshFailure> {
        if depth > MAX_JUMP_DEPTH {
            return Err(SshFailure::new(
                FailureKind::TransportFailure,
                "ProxyJump chain too deep",
            ));
        }
        let (name, user, port) = match parse_quick(text)? {
            Some(q) => (q.host, q.user, q.port),
            None => (text.trim().to_string(), None, None),
        };
        let entry = (self.lookup)(&name);
        let entry = entry.as_ref();
        let host = entry
            .and_then(|e| e.host_name.clone())
            .filter(|h| !h.is_empty())
            .unwrap_or_else(|| name.clone());
        let user = user
            .or_else(|| entry.and_then(|e| e.user.clone()))
            .unwrap_or_else(|| self.local_user.to_string());
        let port = port.or_else(|| entry.and_then(|e| e.port)).unwrap_or(22);

        let mut spec = ResolvedSpec::basic(host, port, user);
        spec.auth = AuthMode::Auto;
        // 超时优先级：client 的 --connect-timeout > ssh_config 的 ConnectTimeout > 缺省。
        spec.connect_timeout = self
            .connect_timeout
            .or_else(|| entry.and_then(|e| e.connect_timeout))
            .unwrap_or_else(default_connect_timeout);
        if let Some(e) = entry {
            spec.agent_forward = e.forward_agent.unwrap_or(false);
            // `no` 也只按 accept-new 处理：自动记下新主机，但密钥变更照样要确认，
            // 不跟随 OpenSSH 在 `no` 时放行变更密钥的做法。
            spec.accept_new_host_keys = matches!(
                e.strict_host_key_checking.as_deref(),
                Some("accept-new") | Some("no")
            );
            spec.identity_files = e
                .identity_files
                .iter()
                .map(|f| {
                    let expanded = expand_tokens(
                        f,
                        &spec.host,
                        spec.port,
                        &spec.user,
                        self.local_user,
                        self.home,
                    );
                    expand_tilde(&expanded, self.home)
                        .to_string_lossy()
                        .into_owned()
                })
                .collect();
            spec.proxy_command = e
                .proxy_command
                .clone()
                .filter(|c| !c.trim().is_empty() && c.trim() != "none");
            spec.forwards = e.forwards.iter().filter_map(convert_forward).collect();
            spec.keepalive_interval = e
                .keepalive_interval
                .unwrap_or_else(default_keepalive_interval);
            spec.keepalive_count_max = e
                .keepalive_count_max
                .unwrap_or_else(default_keepalive_count_max);
            if let Some(chain) = e
                .proxy_jump
                .as_deref()
                .map(str::trim)
                .filter(|c| !c.is_empty() && *c != "none")
            {
                spec.jump = Some(Box::new(self.resolve_chain(chain, depth)?));
            }
        }
        Ok(spec)
    }

    /// `a,b,c` 形式的跳板链：连接顺序是 a → b → c → 目标，所以 c 的上一跳是 b，b 的是 a。
    fn resolve_chain(&self, chain: &str, depth: usize) -> Result<ResolvedSpec, SshFailure> {
        let hops: Vec<&str> = chain
            .split(',')
            .map(str::trim)
            .filter(|h| !h.is_empty())
            .collect();
        if depth + hops.len() > MAX_JUMP_DEPTH {
            return Err(SshFailure::new(
                FailureKind::TransportFailure,
                "ProxyJump chain too deep",
            ));
        }
        let mut previous: Option<ResolvedSpec> = None;
        for hop in hops {
            let mut spec = self.resolve_at(hop, depth + 1)?;
            // 链里显式写出的上一跳优先于该跳自己配置的 ProxyJump；链首保留自己的配置。
            if let Some(prev) = previous.take() {
                spec.jump = Some(Box::new(prev));
            }
            // 跳板只负责中转，不带自己的转发规则（与 OpenSSH -J 一致）。
            spec.forwards.clear();
            previous = Some(spec);
        }
        previous.ok_or_else(|| SshFailure::new(FailureKind::TransportFailure, "empty ProxyJump"))
    }
}

/// ssh_config 的转发规则转成协议里的形状；未知类型丢弃。
fn convert_forward(rule: &crate::ssh_config::ForwardRule) -> Option<ForwardRule> {
    let kind = match rule.kind.as_str() {
        "local" => ForwardKind::Local,
        "remote" => ForwardKind::Remote,
        "dynamic" => ForwardKind::Dynamic,
        _ => return None,
    };
    Some(ForwardRule {
        kind,
        bind: HostPort {
            host: rule.bind.host.clone(),
            port: rule.bind.port,
        },
        target: HostPort {
            host: rule.target.host.clone(),
            port: rule.target.port,
        },
        description: rule.description.clone(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 解析 quick-connect，期望是 quick 写法。
    fn quick(text: &str) -> QuickTarget {
        parse_quick(text).unwrap().expect("quick target")
    }

    #[test]
    fn quick_connect_forms() {
        assert_eq!(
            quick("deploy@10.0.0.5"),
            QuickTarget {
                user: Some("deploy".into()),
                host: "10.0.0.5".into(),
                port: None
            }
        );
        assert_eq!(quick("deploy@host:2222").port, Some(2222));
        assert_eq!(
            quick("ssh://me@h:2200/"),
            QuickTarget {
                user: Some("me".into()),
                host: "h".into(),
                port: Some(2200)
            }
        );
        assert_eq!(
            quick("[::1]:2222"),
            QuickTarget {
                user: None,
                host: "::1".into(),
                port: Some(2222)
            }
        );
        assert_eq!(quick("u@[fe80::1]").host, "fe80::1");
        assert_eq!(quick("host:22").port, Some(22));
        // 最后一个 @ 之前全是用户名。
        assert_eq!(quick("a@b.com@host").user.as_deref(), Some("a@b.com"));
        assert!(parse_quick("orb").unwrap().is_none());
        assert!(parse_quick("u@host:notaport").is_err());
        assert!(parse_quick("[::1").is_err());
    }

    /// 测试用的 ssh_config 查询。
    fn fake_lookup(name: &str) -> Option<HostEntry> {
        match name {
            "orb" => Some(HostEntry {
                alias: "orb".into(),
                host_name: Some("127.0.0.1".into()),
                user: Some("root".into()),
                port: Some(32222),
                identity_files: vec!["~/.ssh/id_%h".into()],
                proxy_jump: Some("bastion,j2".into()),
                proxy_command: None,
                forwards: vec![crate::ssh_config::ForwardRule {
                    kind: "local".into(),
                    bind: crate::ssh_config::HostPort {
                        host: "127.0.0.1".into(),
                        port: 8080,
                    },
                    target: crate::ssh_config::HostPort {
                        host: "localhost".into(),
                        port: 80,
                    },
                    description: String::new(),
                }],
                keepalive_interval: Some(30),
                forward_agent: Some(true),
                strict_host_key_checking: Some("accept-new".into()),
                ..Default::default()
            }),
            "slow" => Some(HostEntry {
                alias: "slow".into(),
                connect_timeout: Some(42),
                strict_host_key_checking: Some("yes".into()),
                ..Default::default()
            }),
            "bastion" => Some(HostEntry {
                alias: "bastion".into(),
                host_name: Some("b.example".into()),
                user: Some("ops".into()),
                ..Default::default()
            }),
            "loop" => Some(HostEntry {
                alias: "loop".into(),
                proxy_jump: Some("loop".into()),
                ..Default::default()
            }),
            _ => None,
        }
    }

    /// 固定环境的解析器。
    fn resolver(lookup: &dyn Fn(&str) -> Option<HostEntry>) -> Resolver<'_> {
        Resolver {
            home: Path::new("/home/me"),
            local_user: "me",
            lookup,
            connect_timeout: Some(7),
        }
    }

    #[test]
    fn alias_merges_ssh_config_and_builds_the_jump_chain() {
        let spec = resolver(&fake_lookup).resolve("orb").unwrap();
        assert_eq!(
            (spec.host.as_str(), spec.port, spec.user.as_str()),
            ("127.0.0.1", 32222, "root")
        );
        assert_eq!(
            spec.identity_files,
            vec!["/home/me/.ssh/id_127.0.0.1".to_string()]
        );
        assert_eq!(spec.keepalive_interval, 30);
        assert_eq!(spec.keepalive_count_max, 3);
        assert_eq!(spec.connect_timeout, 7);
        assert!(spec.agent_forward);
        assert!(spec.accept_new_host_keys);
        assert_eq!(spec.forwards.len(), 1);
        let j2 = spec.jump.as_deref().unwrap();
        assert_eq!((j2.host.as_str(), j2.user.as_str()), ("j2", "me"));
        let b = j2.jump.as_deref().unwrap();
        assert_eq!(
            (b.host.as_str(), b.user.as_str(), b.port),
            ("b.example", "ops", 22)
        );
        assert!(b.jump.is_none());
    }

    #[test]
    fn quick_target_text_overrides_config_and_defaults_apply() {
        let spec = resolver(&fake_lookup).resolve("admin@orb:2200").unwrap();
        assert_eq!(
            (spec.host.as_str(), spec.port, spec.user.as_str()),
            ("127.0.0.1", 2200, "admin")
        );
        let plain = resolver(&fake_lookup).resolve("unknown-host").unwrap();
        assert_eq!(
            (plain.host.as_str(), plain.port, plain.user.as_str()),
            ("unknown-host", 22, "me")
        );
        assert!(plain.jump.is_none());
    }

    #[test]
    fn self_referencing_jump_is_cut_off() {
        let err = resolver(&fake_lookup).resolve("loop").unwrap_err();
        assert!(err.detail.contains("too deep"));
    }

    #[test]
    fn connect_timeout_prefers_the_command_line_then_ssh_config() {
        let spec = resolver(&fake_lookup).resolve("slow").unwrap();
        assert_eq!(spec.connect_timeout, 7, "--connect-timeout wins");
        let no_flag = Resolver {
            connect_timeout: None,
            ..resolver(&fake_lookup)
        };
        let spec = no_flag.resolve("slow").unwrap();
        assert_eq!(spec.connect_timeout, 42);
        assert!(!spec.accept_new_host_keys, "yes keeps asking");
        assert!(!spec.agent_forward);
        assert_eq!(no_flag.resolve("unknown").unwrap().connect_timeout, 10);
    }
}
