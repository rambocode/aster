//! broker 的运行环境：控制通道、known_hosts 路径、主目录、agent socket、本地用户名。
//!
//! 测试把这些全部指向临时目录，绝不读写真实的 `~/.ssh`、钥匙串或 agent。

use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::control::Control;
use crate::log_debug;
use crate::protocol::ResolvedSpec;

/// 连接建立过程中各模块共享的环境。
pub struct Env {
    pub control: Arc<Control>,
    /// 缺省的用户级 known_hosts 文件路径（spec 没指定 knownHostsFiles 时使用）。
    pub known_hosts: PathBuf,
    /// 缺省的系统级 known_hosts 文件，只读。
    pub global_known_hosts: Vec<PathBuf>,
    /// 用来展开 `~` 与查找默认密钥的主目录。
    pub home: PathBuf,
    /// 继承到的 ssh-agent socket（`SSH_AUTH_SOCK`）；None 表示没有。某一跳实际用哪个 agent 要问
    /// `agent_socket`，spec 的 identityAgent 可以改掉它。
    pub agent_sock: Option<PathBuf>,
    /// 缺省用户名。
    pub local_user: String,
}

impl Env {
    /// 这一跳认证与 agent 转发用的 agent socket：spec 的 identityAgent 优先，没写才用继承到的
    /// `SSH_AUTH_SOCK`。None 表示这一跳不用 agent。
    pub fn agent_socket(&self, spec: &ResolvedSpec) -> Option<PathBuf> {
        let tokens = AgentTokens {
            host: &spec.host,
            port: spec.port,
            remote_user: &spec.user,
            local_user: &self.local_user,
            home: &self.home,
        };
        let raw = spec.identity_agent.as_deref();
        let sock = resolve_identity_agent(raw, self.agent_sock.as_deref(), &tokens, &non_empty_env);
        if sock.is_none() && raw.is_some_and(|r| r != "none") {
            log_debug!(
                "IdentityAgent for {} names no socket; not using an agent",
                spec.host_endpoint()
            );
        }
        sock
    }
}

/// 展开 IdentityAgent 路径里 `%` 记号需要的值。
pub struct AgentTokens<'a> {
    pub host: &'a str,
    pub port: u16,
    pub remote_user: &'a str,
    pub local_user: &'a str,
    pub home: &'a Path,
}

/// 按 OpenSSH 的 IdentityAgent 语义算出 agent socket（ssh.c 的处理顺序）：
/// - 没写：用继承到的 `SSH_AUTH_SOCK`（`inherited`）。
/// - `none`：不用 agent。`SSH_AUTH_SOCK`：同没写。两者与 OpenSSH 一样区分大小写。
/// - `$VAR`：socket 路径取自环境变量 VAR；变量没设就不用 agent（不回落到 `SSH_AUTH_SOCK`）。
/// - 其它：当路径，展开 `%h/%p/%r/%u/%d/%%`、`${VAR}` 与开头的 `~`；`${VAR}` 没设同样不用 agent。
///
/// `getenv` 注入是为了测试不碰真实进程环境。
pub fn resolve_identity_agent(
    raw: Option<&str>,
    inherited: Option<&Path>,
    tokens: &AgentTokens<'_>,
    getenv: &dyn Fn(&str) -> Option<String>,
) -> Option<PathBuf> {
    let raw = match raw {
        None | Some("SSH_AUTH_SOCK") => return inherited.map(Path::to_path_buf),
        Some("none") | Some("") => return None,
        Some(raw) => raw,
    };
    if let Some(name) = raw.strip_prefix('$').filter(|n| !n.starts_with('{')) {
        return getenv(name).filter(|v| !v.is_empty()).map(PathBuf::from);
    }
    let text = expand_tokens(
        raw,
        tokens.host,
        tokens.port,
        tokens.remote_user,
        tokens.local_user,
        tokens.home,
    );
    let text = expand_env_braces(&text, getenv)?;
    Some(expand_tilde(&text, tokens.home)).filter(|p| !p.as_os_str().is_empty())
}

/// 环境变量名是否合法：非空，只含字母、数字、下划线（OpenSSH `valid_env_name`）。
pub fn valid_env_name(name: &str) -> bool {
    !name.is_empty() && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '_')
}

/// 展开 `${VAR}`。`${` 没有闭合、名字为空或变量没设时返回 None（OpenSSH 在这些情况下直接报错退出）。
pub fn expand_env_braces(text: &str, getenv: &dyn Fn(&str) -> Option<String>) -> Option<String> {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start) = rest.find("${") {
        out.push_str(&rest[..start]);
        let after = &rest[start + 2..];
        let end = after.find('}')?;
        let name = &after[..end];
        if name.is_empty() {
            return None;
        }
        out.push_str(&getenv(name)?);
        rest = &after[end + 1..];
    }
    out.push_str(rest);
    Some(out)
}

/// 从进程环境得到的路径设置。
#[derive(Debug, Clone)]
pub struct Paths {
    pub home: PathBuf,
    pub known_hosts: PathBuf,
    pub global_known_hosts: Vec<PathBuf>,
    pub agent_sock: Option<PathBuf>,
    pub local_user: String,
}

impl Paths {
    /// 读取环境变量：`ASTER_SSH_HOME` 优先于 `HOME`（测试用它把 `~/.ssh` 指到临时目录），
    /// `ASTER_SSH_KNOWN_HOSTS` 可单独覆盖 known_hosts，`SSH_AUTH_SOCK` 指定 agent。
    pub fn from_process() -> Self {
        let home = non_empty_env("ASTER_SSH_HOME")
            .or_else(|| non_empty_env("HOME"))
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from("/"));
        let known_hosts = non_empty_env("ASTER_SSH_KNOWN_HOSTS")
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".ssh").join("known_hosts"));
        Self {
            known_hosts,
            // OpenSSH 的 GlobalKnownHostsFile 缺省值；只读，文件不存在时视为空。
            global_known_hosts: vec![
                PathBuf::from("/etc/ssh/ssh_known_hosts"),
                PathBuf::from("/etc/ssh/ssh_known_hosts2"),
            ],
            agent_sock: non_empty_env("SSH_AUTH_SOCK").map(PathBuf::from),
            local_user: current_user(),
            home,
        }
    }
}

/// 读一个非空环境变量。
fn non_empty_env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|v| !v.is_empty())
}

/// 当前用户名：`USER` 环境变量，取不到时查 passwd。
pub fn current_user() -> String {
    if let Some(user) = non_empty_env("USER") {
        return user;
    }
    // SAFETY: getpwuid 返回指向静态缓冲区的指针或 NULL；这里只在同一线程内立即拷出 pw_name。
    unsafe {
        let pw = libc::getpwuid(libc::getuid());
        if !pw.is_null() && !(*pw).pw_name.is_null() {
            if let Ok(name) = std::ffi::CStr::from_ptr((*pw).pw_name).to_str() {
                return name.to_string();
            }
        }
    }
    "root".to_string()
}

/// 展开开头的 `~` / `~/`。
pub fn expand_tilde(path: &str, home: &Path) -> PathBuf {
    if path == "~" {
        home.to_path_buf()
    } else if let Some(rest) = path.strip_prefix("~/") {
        home.join(rest)
    } else {
        PathBuf::from(path)
    }
}

/// 展开 OpenSSH 的 `%h`、`%p`、`%r`、`%u`、`%d`、`%%`；未知记号原样保留。
pub fn expand_tokens(
    text: &str,
    host: &str,
    port: u16,
    remote_user: &str,
    local_user: &str,
    home: &Path,
) -> String {
    let mut out = String::with_capacity(text.len());
    let mut chars = text.chars();
    while let Some(c) = chars.next() {
        if c != '%' {
            out.push(c);
            continue;
        }
        match chars.next() {
            Some('h') => out.push_str(host),
            Some('p') => out.push_str(&port.to_string()),
            Some('r') => out.push_str(remote_user),
            Some('u') => out.push_str(local_user),
            Some('d') => out.push_str(&home.to_string_lossy()),
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

#[cfg(test)]
mod tests {
    use super::*;

    /// 固定的测试环境变量。
    fn fake_env(name: &str) -> Option<String> {
        match name {
            "MY_AGENT" => Some("/run/my-agent.sock".to_string()),
            "RUNTIME" => Some("/run/user".to_string()),
            "EMPTY" => Some(String::new()),
            _ => None,
        }
    }

    /// 用固定记号解析一次 IdentityAgent。
    fn agent(raw: Option<&str>, inherited: Option<&str>) -> Option<PathBuf> {
        let tokens = AgentTokens {
            host: "h.example",
            port: 2222,
            remote_user: "deploy",
            local_user: "me",
            home: Path::new("/home/me"),
        };
        resolve_identity_agent(raw, inherited.map(Path::new), &tokens, &fake_env)
    }

    #[test]
    fn identity_agent_follows_openssh_precedence() {
        let inherited = Some("/tmp/inherited.sock");
        let path = |p: &str| Some(PathBuf::from(p));
        // 没写与 SSH_AUTH_SOCK 用继承到的 socket；none 关掉 agent。
        assert_eq!(agent(None, inherited), path("/tmp/inherited.sock"));
        assert_eq!(
            agent(Some("SSH_AUTH_SOCK"), inherited),
            path("/tmp/inherited.sock")
        );
        assert_eq!(agent(Some("SSH_AUTH_SOCK"), None), None);
        assert_eq!(agent(Some("none"), inherited), None);
        // 显式路径盖过继承值，并展开 ~、% 记号与 ${VAR}。
        assert_eq!(
            agent(Some("/tmp/fixture-agent.sock"), inherited),
            path("/tmp/fixture-agent.sock")
        );
        assert_eq!(
            agent(Some("~/Library/Group Containers/x/agent.sock"), None),
            path("/home/me/Library/Group Containers/x/agent.sock")
        );
        assert_eq!(
            agent(Some("%d/.agents/%r@%h-%p-%u.sock"), None),
            path("/home/me/.agents/deploy@h.example-2222-me.sock")
        );
        assert_eq!(
            agent(Some("${RUNTIME}/agent.sock"), None),
            path("/run/user/agent.sock")
        );
        // $VAR 取环境变量；没设或为空就不用 agent，不回落到继承值。
        assert_eq!(
            agent(Some("$MY_AGENT"), inherited),
            path("/run/my-agent.sock")
        );
        assert_eq!(agent(Some("$UNSET"), inherited), None);
        assert_eq!(agent(Some("$EMPTY"), inherited), None);
        assert_eq!(agent(Some("${UNSET}/agent.sock"), inherited), None);
    }

    #[test]
    fn env_brace_expansion_rejects_malformed_references() {
        assert_eq!(
            expand_env_braces("a${RUNTIME}b${MY_AGENT}", &fake_env).as_deref(),
            Some("a/run/userb/run/my-agent.sock")
        );
        assert_eq!(
            expand_env_braces("plain $x", &fake_env).as_deref(),
            Some("plain $x")
        );
        assert_eq!(expand_env_braces("${RUNTIME", &fake_env), None);
        assert_eq!(expand_env_braces("${}", &fake_env), None);
        assert!(valid_env_name("SSH_AUTH_SOCK_2") && !valid_env_name("") && !valid_env_name("A-B"));
    }

    #[test]
    fn tilde_and_tokens_expand() {
        let home = Path::new("/home/me");
        assert_eq!(
            expand_tilde("~/.ssh/id", home),
            PathBuf::from("/home/me/.ssh/id")
        );
        assert_eq!(expand_tilde("/abs", home), PathBuf::from("/abs"));
        assert_eq!(
            expand_tokens("nc %h %p %r %u 100%% %x", "h", 2222, "r", "l", home),
            "nc h 2222 r l 100% %x"
        );
    }
}
