//! known_hosts 校验与写入。
//!
//! 支持 OpenSSH 格式的明文、`[host]:port`、逗号分隔多主机、通配符 / 取反模式、
//! hashed 条目（`|1|salt|hmac`）以及 `@revoked` / `@cert-authority` 标记。
//! 行为参考 tty7 `crates/tty7-core/src/daemon/ssh/known_hosts.rs`@458c923（Apache-2.0）：
//! 同算法不同密钥才算「变更」，只有别的算法的条目时按「未知」处理。

use std::io::Write as _;
use std::path::Path;

use data_encoding::BASE64;
use hmac::{Hmac, KeyInit, Mac};
use russh::keys::{HashAlg, PublicKey};
use sha1::Sha1;

/// 校验结果。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HostKeyStatus {
    /// 有一条同密钥条目。
    Known,
    /// 没有这台主机、或只有其它算法的条目。
    Unknown,
    /// 有同算法但不同密钥的条目。
    Changed,
    /// 密钥被 `@revoked` 标记，任何情况下都拒绝。
    Revoked,
}

/// known_hosts 里用来匹配的主机名：22 端口直接用主机名，其它端口用 `[host]:port`。
pub fn host_token(host: &str, port: u16) -> String {
    if port == 22 {
        host.to_string()
    } else {
        format!("[{host}]:{port}")
    }
}

/// `SHA256:…` 形式的指纹，与 `ssh-keygen -l` 一致。
pub fn fingerprint(key: &PublicKey) -> String {
    key.fingerprint(HashAlg::Sha256).to_string()
}

/// 行标记。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Marker {
    Revoked,
    CertAuthority,
}

/// 解析后的一行。
struct Entry<'a> {
    marker: Option<Marker>,
    hosts: &'a str,
    key: Option<PublicKey>,
}

impl<'a> Entry<'a> {
    /// 解析一行；注释、空行和格式不对的行返回 None。
    fn parse(line: &'a str) -> Option<Self> {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            return None;
        }
        let mut fields = line.split_whitespace();
        let mut first = fields.next()?;
        let marker = match first {
            "@revoked" => Some(Marker::Revoked),
            "@cert-authority" => Some(Marker::CertAuthority),
            other if other.starts_with('@') => return None,
            _ => None,
        };
        if marker.is_some() {
            first = fields.next()?;
        }
        let _algorithm = fields.next()?;
        let b64 = fields.next()?;
        Some(Self {
            marker,
            hosts: first,
            key: russh::keys::parse_public_key_base64(b64).ok(),
        })
    }

    /// 主机字段是否匹配 token。取反模式命中时整行不匹配（OpenSSH 语义）。
    fn matches(&self, token: &str) -> bool {
        let mut matched = false;
        for pattern in self.hosts.split(',') {
            if let Some(negated) = pattern.strip_prefix('!') {
                if glob_match(negated, token) {
                    return false;
                }
            } else if pattern.starts_with("|1|") {
                matched |= hashed_matches(pattern, token);
            } else {
                matched |= glob_match(pattern, token);
            }
        }
        matched
    }

    /// 主机字段是否只有一个模式（可以原地替换整行）。
    fn is_single_host(&self) -> bool {
        !self.hosts.contains(',')
    }
}

/// `*` / `?` 通配匹配，大小写不敏感（主机名本身不区分大小写）。
fn glob_match(pattern: &str, text: &str) -> bool {
    /// 字节级回溯匹配。
    fn inner(p: &[u8], t: &[u8]) -> bool {
        match (p.first(), t.first()) {
            (None, None) => true,
            (Some(b'*'), _) => inner(&p[1..], t) || (!t.is_empty() && inner(p, &t[1..])),
            (Some(b'?'), Some(_)) => inner(&p[1..], &t[1..]),
            (Some(a), Some(b)) if a.eq_ignore_ascii_case(b) => inner(&p[1..], &t[1..]),
            _ => false,
        }
    }
    inner(pattern.as_bytes(), text.as_bytes())
}

/// hashed 条目：`|1|base64(salt)|base64(HMAC-SHA1(salt, token))`。
fn hashed_matches(pattern: &str, token: &str) -> bool {
    let mut parts = pattern.trim_start_matches("|1|").split('|');
    let (Some(salt), Some(hash)) = (parts.next(), parts.next()) else {
        return false;
    };
    let (Ok(salt), Ok(hash)) = (
        BASE64.decode(salt.as_bytes()),
        BASE64.decode(hash.as_bytes()),
    ) else {
        return false;
    };
    let Ok(mac) = <Hmac<Sha1> as KeyInit>::new_from_slice(&salt) else {
        return false;
    };
    mac.chain_update(token.as_bytes())
        .verify_slice(&hash)
        .is_ok()
}

/// 在 known_hosts 文本里校验一把主机密钥。
pub fn check_str(contents: &str, host: &str, port: u16, key: &PublicKey) -> HostKeyStatus {
    let token = host_token(host, port);
    let mut changed = false;
    let mut known = false;
    for line in contents.lines() {
        let Some(entry) = Entry::parse(line) else {
            continue;
        };
        if !entry.matches(&token) {
            continue;
        }
        let Some(stored) = entry.key.as_ref() else {
            continue;
        };
        match entry.marker {
            // 吊销优先于一切，包括前面已经出现过的信任条目。
            Some(Marker::Revoked) if stored == key => return HostKeyStatus::Revoked,
            Some(_) => {}
            None if stored == key => known = true,
            None if stored.algorithm() == key.algorithm() => changed = true,
            None => {}
        }
    }
    match (known, changed) {
        (true, _) => HostKeyStatus::Known,
        (false, true) => HostKeyStatus::Changed,
        (false, false) => HostKeyStatus::Unknown,
    }
}

/// 读文件校验；文件不存在按空文件处理。
pub fn check_file(path: &Path, host: &str, port: u16, key: &PublicKey) -> HostKeyStatus {
    match std::fs::read_to_string(path) {
        Ok(contents) => check_str(&contents, host, port, key),
        Err(_) => HostKeyStatus::Unknown,
    }
}

/// known_hosts 里已有的、这台主机的算法（按文件顺序去重），用于把它们排到协商列表前面。
pub fn known_algorithms(path: &Path, host: &str, port: u16) -> Vec<russh::keys::Algorithm> {
    let Ok(contents) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    let token = host_token(host, port);
    let mut out = Vec::new();
    for line in contents.lines() {
        let Some(entry) = Entry::parse(line) else {
            continue;
        };
        if entry.marker.is_some() || !entry.matches(&token) {
            continue;
        }
        if let Some(alg) = entry.key.map(|k| k.algorithm()) {
            if !out.contains(&alg) {
                out.push(alg);
            }
        }
    }
    out
}

/// 一行 `token algorithm base64`。
fn entry_line(host: &str, port: u16, key: &PublicKey) -> std::io::Result<String> {
    let openssh = key
        .to_openssh()
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e.to_string()))?;
    let mut parts = openssh.split_whitespace();
    let algorithm = parts.next().unwrap_or_default();
    let b64 = parts.next().unwrap_or_default();
    Ok(format!("{} {algorithm} {b64}", host_token(host, port)))
}

/// 确保父目录存在（0700）。
fn ensure_parent(path: &Path) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        if !dir.exists() {
            std::fs::create_dir_all(dir)?;
            use std::os::unix::fs::PermissionsExt as _;
            std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
        }
    }
    Ok(())
}

/// 追加一条信任记录（unknown 被接受时）。
pub fn append(path: &Path, host: &str, port: u16, key: &PublicKey) -> std::io::Result<()> {
    ensure_parent(path)?;
    let line = entry_line(host, port, key)?;
    let needs_newline = match std::fs::read(path) {
        Ok(bytes) => !bytes.is_empty() && bytes.last() != Some(&b'\n'),
        Err(_) => false,
    };
    use std::os::unix::fs::OpenOptionsExt as _;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .mode(0o600)
        .open(path)?;
    if needs_newline {
        file.write_all(b"\n")?;
    }
    file.write_all(line.as_bytes())?;
    file.write_all(b"\n")
}

/// 替换变更的记录（changed 被接受时）。
///
/// 同算法、不同密钥、只列这一台主机的行原地换成新行；列了多台主机的行只去掉命中的模式，
/// 保留其它主机，新记录追加到末尾。没有可替换的行时退化为追加。
/// 写入走「临时文件 + rename」，中途失败不会留下半个文件。
pub fn replace(path: &Path, host: &str, port: u16, key: &PublicKey) -> std::io::Result<()> {
    let contents = match std::fs::read_to_string(path) {
        Ok(c) => c,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => String::new(),
        Err(e) => return Err(e),
    };
    let token = host_token(host, port);
    let new_line = entry_line(host, port, key)?;
    let mut replaced = false;
    let mut out: Vec<String> = Vec::new();
    for line in contents.lines() {
        let stale = Entry::parse(line).filter(|e| {
            e.marker.is_none()
                && e.matches(&token)
                && e.key
                    .as_ref()
                    .is_some_and(|k| k.algorithm() == key.algorithm() && k != key)
        });
        match stale {
            Some(entry) if entry.is_single_host() => {
                if !replaced {
                    out.push(new_line.clone());
                    replaced = true;
                }
            }
            Some(entry) => {
                let hosts: Vec<&str> = entry
                    .hosts
                    .split(',')
                    .filter(|p| {
                        !(glob_match(p, &token)
                            || (p.starts_with("|1|") && hashed_matches(p, &token)))
                    })
                    .collect();
                let rest = line
                    .trim_start()
                    .split_once(char::is_whitespace)
                    .map_or("", |(_, rest)| rest);
                out.push(format!("{} {}", hosts.join(","), rest.trim_start()));
            }
            None => out.push(line.to_string()),
        }
    }
    if !replaced {
        out.push(new_line);
    }
    ensure_parent(path)?;
    let tmp = path.with_extension("aster-tmp");
    {
        use std::os::unix::fs::OpenOptionsExt as _;
        let mut file = std::fs::OpenOptions::new()
            .create(true)
            .write(true)
            .truncate(true)
            .mode(0o600)
            .open(&tmp)?;
        file.write_all(out.join("\n").as_bytes())?;
        file.write_all(b"\n")?;
        file.sync_all()?;
    }
    std::fs::rename(&tmp, path)
}

#[cfg(test)]
mod tests {
    use super::*;
    use russh::keys::ssh_key::private::Ed25519Keypair;
    use russh::keys::PrivateKey;

    /// 由种子生成确定的 ed25519 公钥。
    fn key(seed: u8) -> PublicKey {
        PrivateKey::from(Ed25519Keypair::from_seed(&[seed; 32]))
            .public_key()
            .clone()
    }

    /// 某把公钥的 `algorithm base64` 部分。
    fn key_text(k: &PublicKey) -> String {
        k.to_openssh().unwrap()
    }

    #[test]
    fn plain_entries_known_unknown_changed() {
        let text = format!("example.com {}\n", key_text(&key(1)));
        assert_eq!(
            check_str(&text, "example.com", 22, &key(1)),
            HostKeyStatus::Known
        );
        assert_eq!(
            check_str(&text, "example.com", 22, &key(2)),
            HostKeyStatus::Changed
        );
        assert_eq!(
            check_str(&text, "other.com", 22, &key(1)),
            HostKeyStatus::Unknown
        );
        // 非 22 端口只认 `[host]:port`。
        assert_eq!(
            check_str(&text, "example.com", 2222, &key(1)),
            HostKeyStatus::Unknown
        );
    }

    #[test]
    fn bracketed_port_and_multi_host_and_wildcards() {
        let text = format!(
            "# comment\n\n[example.com]:2222,10.0.0.5 {}\n*.corp,!bad.corp {}\n",
            key_text(&key(1)),
            key_text(&key(3))
        );
        assert_eq!(
            check_str(&text, "example.com", 2222, &key(1)),
            HostKeyStatus::Known
        );
        assert_eq!(
            check_str(&text, "10.0.0.5", 22, &key(1)),
            HostKeyStatus::Known
        );
        assert_eq!(
            check_str(&text, "a.corp", 22, &key(3)),
            HostKeyStatus::Known
        );
        assert_eq!(
            check_str(&text, "bad.corp", 22, &key(3)),
            HostKeyStatus::Unknown
        );
    }

    #[test]
    fn hashed_entries_match_by_hmac() {
        let salt = [5u8; 20];
        let mac = <Hmac<Sha1> as KeyInit>::new_from_slice(&salt)
            .unwrap()
            .chain_update(b"[h.example]:2200")
            .finalize()
            .into_bytes();
        let pattern = format!("|1|{}|{}", BASE64.encode(&salt), BASE64.encode(&mac));
        let text = format!("{pattern} {}\n", key_text(&key(4)));
        assert_eq!(
            check_str(&text, "h.example", 2200, &key(4)),
            HostKeyStatus::Known
        );
        assert_eq!(
            check_str(&text, "h.example", 2200, &key(5)),
            HostKeyStatus::Changed
        );
        assert_eq!(
            check_str(&text, "h.example", 22, &key(4)),
            HostKeyStatus::Unknown
        );
    }

    #[test]
    fn revoked_wins_and_cert_authority_is_ignored() {
        let text = format!(
            "h {k}\n@revoked h {k}\n@cert-authority h {o}\n",
            k = key_text(&key(1)),
            o = key_text(&key(2))
        );
        assert_eq!(check_str(&text, "h", 22, &key(1)), HostKeyStatus::Revoked);
        assert_eq!(check_str(&text, "h", 22, &key(2)), HostKeyStatus::Changed);
    }

    #[test]
    fn append_then_replace_rewrites_only_the_stale_line() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(".ssh").join("known_hosts");
        append(&path, "keep.example", 22, &key(9)).unwrap();
        append(&path, "127.0.0.1", 2201, &key(1)).unwrap();
        assert_eq!(
            check_file(&path, "127.0.0.1", 2201, &key(1)),
            HostKeyStatus::Known
        );

        replace(&path, "127.0.0.1", 2201, &key(2)).unwrap();
        assert_eq!(
            check_file(&path, "127.0.0.1", 2201, &key(2)),
            HostKeyStatus::Known
        );
        assert_eq!(
            check_file(&path, "127.0.0.1", 2201, &key(1)),
            HostKeyStatus::Changed
        );
        assert_eq!(
            check_file(&path, "keep.example", 22, &key(9)),
            HostKeyStatus::Known
        );
        let text = std::fs::read_to_string(&path).unwrap();
        assert_eq!(text.lines().count(), 2, "{text}");

        use std::os::unix::fs::PermissionsExt as _;
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
    }

    #[test]
    fn replace_keeps_other_hosts_on_a_shared_line() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        std::fs::write(
            &path,
            format!("a.example,b.example {}\n", key_text(&key(1))),
        )
        .unwrap();
        replace(&path, "a.example", 22, &key(2)).unwrap();
        assert_eq!(
            check_file(&path, "a.example", 22, &key(2)),
            HostKeyStatus::Known
        );
        assert_eq!(
            check_file(&path, "b.example", 22, &key(1)),
            HostKeyStatus::Known
        );
    }

    #[test]
    fn known_algorithms_lists_each_once() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("known_hosts");
        std::fs::write(
            &path,
            format!("h {}\nh {}\n", key_text(&key(1)), key_text(&key(2))),
        )
        .unwrap();
        assert_eq!(known_algorithms(&path, "h", 22).len(), 1);
        assert!(known_algorithms(&path, "x", 22).is_empty());
    }
}
