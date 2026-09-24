//! broker 的运行环境：控制通道、known_hosts 路径、主目录、agent socket、本地用户名。
//!
//! 测试把这些全部指向临时目录，绝不读写真实的 `~/.ssh`、钥匙串或 agent。

use std::path::{Path, PathBuf};
use std::sync::Arc;

use crate::control::Control;

/// 连接建立过程中各模块共享的环境。
pub struct Env {
    pub control: Arc<Control>,
    /// 缺省的用户级 known_hosts 文件路径（spec 没指定 knownHostsFiles 时使用）。
    pub known_hosts: PathBuf,
    /// 缺省的系统级 known_hosts 文件，只读。
    pub global_known_hosts: Vec<PathBuf>,
    /// 用来展开 `~` 与查找默认密钥的主目录。
    pub home: PathBuf,
    /// ssh-agent socket；None 表示不使用 agent。
    pub agent_sock: Option<PathBuf>,
    /// 缺省用户名。
    pub local_user: String,
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
