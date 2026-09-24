//! 用户认证。
//!
//! auto 的顺序：agent → identityFiles → 默认密钥 → password → keyboard-interactive。
//! 缺秘密时经控制通道发 `auth.request` 向 App 要；每次把秘密交给服务器（或用 passphrase 解密）
//! 之后发 `auth.result`，App 据此决定是否写入或删除钥匙串。
//! 流程参考 tty7 `daemon/ssh/auth.rs`@458c923（Apache-2.0）：用户关掉口令 / 键盘交互的表单
//! 视为取消整个认证，关掉 passphrase 表单只跳过这把密钥。

use std::path::{Path, PathBuf};
use std::sync::Arc;

use russh::client::{AuthResult, Handle, KeyboardInteractiveAuthResponse};
use russh::keys::agent::client::AgentClient;
use russh::keys::agent::AgentIdentity;
use russh::keys::{HashAlg, PrivateKey, PrivateKeyWithHashAlg};
use russh::{MethodKind, MethodSet};
use sha2::{Digest, Sha512};
use zeroize::Zeroizing;

use crate::env::{expand_tilde, expand_tokens, Env};
use crate::handler::ClientHandler;
use crate::protocol::{
    AuthMode, AuthPrompt, AuthRequest, AuthRequestKind, FailureKind, ResolvedSpec, SshFailure,
};
use crate::{log_debug, log_info};

/// 每种需要秘密的方式最多问几次（与 OpenSSH NumberOfPasswordPrompts 缺省值一致）。
const MAX_PROMPTS: u32 = 3;
/// 一次键盘交互最多往返几轮，防止服务器无限追问。
const MAX_KI_ROUNDS: u32 = 16;
/// 没有配置 identityFiles 时尝试的默认密钥（相对主目录）。
const DEFAULT_KEYS: [&str; 3] = [".ssh/id_ed25519", ".ssh/id_ecdsa", ".ssh/id_rsa"];

/// 一次认证需要的上下文。
pub struct AuthContext<'a> {
    pub env: &'a Env,
    pub spec: &'a ResolvedSpec,
    pub interactive: bool,
    /// 只有目标主机本身带 hostID；跳板为 None。
    pub host_id: Option<String>,
}

/// 一步认证的结果。
enum Outcome {
    Authenticated,
    /// 用户关掉了口令 / 键盘交互表单：整个认证结束，不再换方式追问。
    Cancelled,
    /// 试过但被拒绝；带上服务器给出的剩余方式。
    Rejected(Option<MethodSet>),
    /// 没有可试的东西（没有 agent、密钥文件不存在、非交互且钥匙串里没有）。
    Skipped,
}

/// 认证步骤。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Step {
    Agent,
    IdentityFiles,
    DefaultKeys,
    Password,
    KeyboardInteractive,
}

impl Step {
    /// 这一步属于哪种 SSH 认证方式。
    fn method(self) -> MethodKind {
        match self {
            Step::Agent | Step::IdentityFiles | Step::DefaultKeys => MethodKind::PublicKey,
            Step::Password => MethodKind::Password,
            Step::KeyboardInteractive => MethodKind::KeyboardInteractive,
        }
    }

    /// 写进失败说明里的方式名。
    fn label(self) -> &'static str {
        match self.method() {
            MethodKind::Password => "password",
            MethodKind::KeyboardInteractive => "keyboard-interactive",
            _ => "publickey",
        }
    }
}

/// 按认证方式列出步骤。
fn steps(mode: AuthMode) -> &'static [Step] {
    match mode {
        AuthMode::Auto => &[
            Step::Agent,
            Step::IdentityFiles,
            Step::DefaultKeys,
            Step::Password,
            Step::KeyboardInteractive,
        ],
        AuthMode::PublicKey => &[Step::IdentityFiles, Step::DefaultKeys],
        AuthMode::Agent => &[Step::Agent],
        AuthMode::Password => &[Step::Password],
        AuthMode::KeyboardInteractive => &[Step::KeyboardInteractive],
    }
}

/// russh 通信错误统一归为 transportFailure。
fn transport(e: russh::Error) -> SshFailure {
    SshFailure::new(
        FailureKind::TransportFailure,
        format!("authentication: {e}"),
    )
}

/// 私钥文件内容 SHA-512 的小写 hex，是 passphrase 的钥匙串账户名。
pub fn key_digest(contents: &[u8]) -> String {
    hex::encode(Sha512::digest(contents))
}

/// 对一跳做用户认证。
pub async fn authenticate(
    handle: &mut Handle<ClientHandler>,
    ctx: &AuthContext<'_>,
) -> Result<(), SshFailure> {
    let user = ctx.spec.user.clone();
    let mut remaining = match handle.authenticate_none(user).await.map_err(transport)? {
        AuthResult::Success => return Ok(()),
        AuthResult::Failure {
            remaining_methods, ..
        } => remaining_methods,
    };
    let mut rejected: Vec<&'static str> = Vec::new();
    for &step in steps(ctx.spec.auth) {
        // 服务器没列出剩余方式时照样尝试（空集合 = 服务器没说）。
        if !remaining.is_empty() && !remaining.contains(&step.method()) {
            continue;
        }
        if step == Step::DefaultKeys && !ctx.spec.identity_files.is_empty() {
            continue;
        }
        let outcome = match step {
            Step::Agent => try_agent(handle, ctx).await?,
            Step::IdentityFiles => {
                let files: Vec<PathBuf> = ctx
                    .spec
                    .identity_files
                    .iter()
                    .map(|f| expand_identity(f, ctx))
                    .collect();
                try_key_files(handle, ctx, &files, true).await?
            }
            Step::DefaultKeys => {
                let files: Vec<PathBuf> =
                    DEFAULT_KEYS.iter().map(|f| ctx.env.home.join(f)).collect();
                try_key_files(handle, ctx, &files, false).await?
            }
            Step::Password => try_password(handle, ctx).await?,
            Step::KeyboardInteractive => try_keyboard_interactive(handle, ctx).await?,
        };
        match outcome {
            Outcome::Authenticated => return Ok(()),
            Outcome::Cancelled => {
                return Err(SshFailure::new(
                    FailureKind::Cancelled,
                    "authentication cancelled by user",
                ))
            }
            Outcome::Rejected(methods) => {
                if !rejected.contains(&step.label()) {
                    rejected.push(step.label());
                }
                if let Some(m) = methods.filter(|m| !m.is_empty()) {
                    remaining = m;
                }
            }
            Outcome::Skipped => {}
        }
    }
    let detail = if rejected.is_empty() {
        let offered: Vec<&str> = remaining.iter().map(<&str>::from).collect();
        format!(
            "no usable credentials (server offers {})",
            offered.join(",")
        )
    } else {
        format!("{} rejected", rejected.join(","))
    };
    Err(SshFailure::new(FailureKind::AuthenticationRequired, detail))
}

/// 展开 identityFiles 里的 `~` 与 `%h/%r/%p/%u`。
fn expand_identity(raw: &str, ctx: &AuthContext<'_>) -> PathBuf {
    let s = ctx.spec;
    let text = expand_tokens(
        raw,
        &s.host,
        s.port,
        &s.user,
        &ctx.env.local_user,
        &ctx.env.home,
    );
    expand_tilde(&text, &ctx.env.home)
}

/// 发一条凭证请求。
async fn ask(
    ctx: &AuthContext<'_>,
    kind: AuthRequestKind,
    attempt: u32,
    fill: impl FnOnce(&mut AuthRequest),
) -> (String, crate::control::AuthAnswer) {
    let mut request = AuthRequest {
        id: String::new(),
        endpoint: ctx.spec.credential_endpoint(),
        kind,
        host_id: ctx.host_id.clone(),
        key_file: None,
        key_digest: None,
        name: String::new(),
        instruction: String::new(),
        prompts: Vec::new(),
        attempt,
        interactive: ctx.interactive,
    };
    fill(&mut request);
    ctx.env.control.ask_auth(request).await
}

/// RSA 签名用的哈希：优先服务器声明支持的，缺省 SHA-256。
async fn rsa_hash(handle: &Handle<ClientHandler>, key_is_rsa: bool) -> Option<HashAlg> {
    if !key_is_rsa {
        return None;
    }
    match handle.best_supported_rsa_hash().await {
        Ok(Some(best)) => best,
        _ => Some(HashAlg::Sha256),
    }
}

/// agent 里的每个身份依次尝试。
async fn try_agent(
    handle: &mut Handle<ClientHandler>,
    ctx: &AuthContext<'_>,
) -> Result<Outcome, SshFailure> {
    let Some(sock) = ctx.env.agent_sock.as_ref() else {
        return Ok(Outcome::Skipped);
    };
    let mut agent = match AgentClient::connect_uds(sock).await {
        Ok(a) => a,
        Err(e) => {
            log_debug!("ssh-agent unavailable: {e}");
            return Ok(Outcome::Skipped);
        }
    };
    let identities = match agent.request_identities().await {
        Ok(ids) => ids,
        Err(e) => {
            log_debug!("ssh-agent identities unavailable: {e}");
            return Ok(Outcome::Skipped);
        }
    };
    let mut outcome = Outcome::Skipped;
    for identity in identities {
        let AgentIdentity::PublicKey { key, .. } = identity else {
            continue;
        };
        let hash = rsa_hash(handle, key.algorithm().is_rsa()).await;
        match handle
            .authenticate_publickey_with(ctx.spec.user.clone(), key, hash, &mut agent)
            .await
        {
            Ok(AuthResult::Success) => return Ok(Outcome::Authenticated),
            Ok(AuthResult::Failure {
                remaining_methods, ..
            }) => outcome = Outcome::Rejected(Some(remaining_methods)),
            Err(e) => log_debug!("agent signing failed: {e}"),
        }
    }
    Ok(outcome)
}

/// 依次尝试一组私钥文件。
async fn try_key_files(
    handle: &mut Handle<ClientHandler>,
    ctx: &AuthContext<'_>,
    files: &[PathBuf],
    explicit: bool,
) -> Result<Outcome, SshFailure> {
    let mut outcome = Outcome::Skipped;
    for path in files {
        match try_key_file(handle, ctx, path, explicit).await? {
            Outcome::Authenticated => return Ok(Outcome::Authenticated),
            r @ Outcome::Rejected(_) => outcome = r,
            Outcome::Cancelled | Outcome::Skipped => {}
        }
    }
    Ok(outcome)
}

/// 读取并（必要时向 App 要 passphrase 后）解密一把私钥，再用它认证。
async fn try_key_file(
    handle: &mut Handle<ClientHandler>,
    ctx: &AuthContext<'_>,
    path: &Path,
    explicit: bool,
) -> Result<Outcome, SshFailure> {
    let contents = match std::fs::read(path) {
        Ok(c) => Zeroizing::new(c),
        Err(e) => {
            if explicit {
                log_info!("identity file {} unreadable: {e}", path.display());
            }
            return Ok(Outcome::Skipped);
        }
    };
    let text = Zeroizing::new(String::from_utf8_lossy(&contents).into_owned());
    let key = match russh::keys::decode_secret_key(&text, None) {
        Ok(k) => k,
        Err(russh::keys::Error::KeyIsEncrypted) => {
            match unlock_key(ctx, path, &contents, &text).await {
                Some(k) => k,
                None => return Ok(Outcome::Skipped),
            }
        }
        Err(e) => {
            log_info!(
                "identity file {} is not a usable private key: {e}",
                path.display()
            );
            return Ok(Outcome::Skipped);
        }
    };
    let hash = rsa_hash(handle, key.algorithm().is_rsa()).await;
    let key = PrivateKeyWithHashAlg::new(Arc::new(key), hash);
    match handle
        .authenticate_publickey(ctx.spec.user.clone(), key)
        .await
        .map_err(transport)?
    {
        AuthResult::Success => Ok(Outcome::Authenticated),
        AuthResult::Failure {
            remaining_methods, ..
        } => {
            log_debug!("server rejected key {}", path.display());
            Ok(Outcome::Rejected(Some(remaining_methods)))
        }
    }
}

/// 向 App 要 passphrase 并解密，最多 3 次。解密成功即算 accepted（passphrase 本身是对的）。
async fn unlock_key(
    ctx: &AuthContext<'_>,
    path: &Path,
    contents: &[u8],
    text: &str,
) -> Option<PrivateKey> {
    let digest = key_digest(contents);
    let key_file = path.to_string_lossy().into_owned();
    for attempt in 1..=MAX_PROMPTS {
        let (id, answer) = ask(ctx, AuthRequestKind::Passphrase, attempt, |r| {
            r.key_file = Some(key_file.clone());
            r.key_digest = Some(digest.clone());
            r.prompts = vec![AuthPrompt {
                text: format!("Enter passphrase for key '{key_file}':"),
                echo: false,
            }];
        })
        .await;
        // 关掉 passphrase 表单只放弃这把密钥，后面的方式问的是另一件事。
        let secret = answer.secret?;
        match russh::keys::decode_secret_key(text, Some(&secret)) {
            Ok(key) => {
                ctx.env.control.auth_result(&id, true);
                return Some(key);
            }
            Err(_) => {
                ctx.env.control.auth_result(&id, false);
                log_info!(
                    "passphrase for {} did not decrypt the key (attempt {attempt})",
                    path.display()
                );
            }
        }
    }
    None
}

/// 口令认证：向 App 要口令，被拒后重试，最多 3 次。
async fn try_password(
    handle: &mut Handle<ClientHandler>,
    ctx: &AuthContext<'_>,
) -> Result<Outcome, SshFailure> {
    let mut outcome = Outcome::Skipped;
    for attempt in 1..=MAX_PROMPTS {
        let (id, answer) = ask(ctx, AuthRequestKind::Password, attempt, |r| {
            r.prompts = vec![AuthPrompt {
                text: format!("{}'s password:", ctx.spec.credential_endpoint()),
                echo: false,
            }];
        })
        .await;
        let Some(secret) = answer.secret else {
            return Ok(if ctx.interactive {
                Outcome::Cancelled
            } else {
                outcome
            });
        };
        let result = handle
            .authenticate_password(ctx.spec.user.clone(), String::clone(&secret))
            .await
            .map_err(transport)?;
        drop(secret);
        match result {
            AuthResult::Success => {
                ctx.env.control.auth_result(&id, true);
                return Ok(Outcome::Authenticated);
            }
            AuthResult::Failure {
                remaining_methods, ..
            } => {
                ctx.env.control.auth_result(&id, false);
                log_info!(
                    "password rejected for {} (attempt {attempt})",
                    ctx.spec.credential_endpoint()
                );
                let again = remaining_methods.is_empty()
                    || remaining_methods.contains(&MethodKind::Password);
                outcome = Outcome::Rejected(Some(remaining_methods));
                if !again {
                    break;
                }
            }
        }
    }
    Ok(outcome)
}

/// 键盘交互认证：每一轮提示都转成一条 `auth.request`，失败后重新开始，最多 3 次。
///
/// 中间轮次的回答是否正确要等整轮结束才知道，所以 `auth.result` 在成功或失败时对本次
/// 请求里的全部 id 一起发出。
async fn try_keyboard_interactive(
    handle: &mut Handle<ClientHandler>,
    ctx: &AuthContext<'_>,
) -> Result<Outcome, SshFailure> {
    let mut outcome = Outcome::Skipped;
    for attempt in 1..=MAX_PROMPTS {
        let mut ids: Vec<String> = Vec::new();
        let mut resp = handle
            .authenticate_keyboard_interactive_start(ctx.spec.user.clone(), None)
            .await
            .map_err(transport)?;
        let mut rounds = 0;
        loop {
            rounds += 1;
            if rounds > MAX_KI_ROUNDS {
                for id in &ids {
                    ctx.env.control.auth_result(id, false);
                }
                return Ok(Outcome::Rejected(None));
            }
            match resp {
                KeyboardInteractiveAuthResponse::Success => {
                    for id in &ids {
                        ctx.env.control.auth_result(id, true);
                    }
                    return Ok(Outcome::Authenticated);
                }
                KeyboardInteractiveAuthResponse::Failure {
                    remaining_methods, ..
                } => {
                    for id in &ids {
                        ctx.env.control.auth_result(id, false);
                    }
                    // 一个问题都没问就被拒，说明服务器不给这种方式，重来也没用。
                    if ids.is_empty() {
                        return Ok(Outcome::Rejected(Some(remaining_methods)));
                    }
                    let again = remaining_methods.is_empty()
                        || remaining_methods.contains(&MethodKind::KeyboardInteractive);
                    outcome = Outcome::Rejected(Some(remaining_methods));
                    if !again {
                        return Ok(outcome);
                    }
                    break;
                }
                KeyboardInteractiveAuthResponse::InfoRequest {
                    name,
                    instructions,
                    prompts,
                } => {
                    if prompts.is_empty() {
                        resp = handle
                            .authenticate_keyboard_interactive_respond(Vec::new())
                            .await
                            .map_err(transport)?;
                        continue;
                    }
                    let wire: Vec<AuthPrompt> = prompts
                        .iter()
                        .map(|p| AuthPrompt {
                            text: p.prompt.clone(),
                            echo: p.echo,
                        })
                        .collect();
                    let (id, answer) =
                        ask(ctx, AuthRequestKind::KeyboardInteractive, attempt, |r| {
                            r.name = name.clone();
                            r.instruction = instructions.clone();
                            r.prompts = wire;
                        })
                        .await;
                    // 键盘交互只看 responses：数组是回答，null 是取消；secret 恒为 null（PROTOCOL §4.2）。
                    let responses: Option<Vec<String>> = match answer.responses {
                        Some(v) if v.len() == prompts.len() => {
                            Some(v.iter().map(|s| String::clone(s)).collect())
                        }
                        Some(v) => {
                            // 回答条数和提示对不上是 App 侧的错误；按取消处理，并告诉 App 这次没被接受。
                            log_info!(
                                "keyboard-interactive answer has {} responses for {} prompts",
                                v.len(),
                                prompts.len()
                            );
                            ctx.env.control.auth_result(&id, false);
                            None
                        }
                        None => None,
                    };
                    let Some(responses) = responses else {
                        return Ok(if ctx.interactive {
                            Outcome::Cancelled
                        } else {
                            outcome
                        });
                    };
                    ids.push(id);
                    resp = handle
                        .authenticate_keyboard_interactive_respond(responses)
                        .await
                        .map_err(transport)?;
                }
            }
        }
    }
    Ok(outcome)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn auto_order_is_agent_files_defaults_password_ki() {
        assert_eq!(
            steps(AuthMode::Auto),
            &[
                Step::Agent,
                Step::IdentityFiles,
                Step::DefaultKeys,
                Step::Password,
                Step::KeyboardInteractive
            ]
        );
        assert_eq!(steps(AuthMode::Agent), &[Step::Agent]);
        assert_eq!(steps(AuthMode::Password), &[Step::Password]);
    }

    #[test]
    fn key_digest_is_lowercase_sha512_hex() {
        let d = key_digest(b"abc");
        assert_eq!(d.len(), 128);
        assert!(d.starts_with("ddaf35a193617aba"));
        assert_eq!(d, d.to_lowercase());
    }
}
