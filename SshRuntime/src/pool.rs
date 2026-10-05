//! 连接池：按 `user@host:port` + 代理 + 跳板链共享一条 russh 连接。
//!
//! 同一个键同时只有一次拨号；拨号期间到来的 OPEN 订阅同一个结果（成功或失败都共享），
//! 因此不会对同一台主机重复提问。连接断开后槽位回到空闲，下一次 OPEN 重新拨号。
//! 共享思路参考 tty7 `daemon/ssh/mod.rs` 的 SharedConnection@458c923（Apache-2.0）。

use std::collections::HashMap;
use std::future::Future;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use russh::client::{Handle, Msg};
use russh::Channel;
use tokio::sync::{oneshot, watch};

use crate::auth::{self, AuthContext};
use crate::connect;
use crate::env::Env;
use crate::forward::{ForwardSet, RemoteForwards};
use crate::handler::ClientHandler;
use crate::known_hosts::KnownHostsFiles;
use crate::protocol::{
    BrokerEvent, FailureKind, LinkState, LinkStateEvent, ResolvedSpec, SshFailure, MAX_JUMP_DEPTH,
};
use crate::{log_info, log_warn};

/// 一条已认证的 SSH 连接。
pub struct Connection {
    handle: Handle<ClientHandler>,
    key: String,
    endpoint: String,
    alive: Arc<AtomicBool>,
    env: Arc<Env>,
    remote_forwards: RemoteForwards,
    forwards: Mutex<ForwardSet>,
    /// 承载本连接的上一跳；持有它保证跳板在本连接存活期间不被释放。
    _via: Option<Arc<Connection>>,
}

impl Connection {
    /// 底层 russh 句柄。
    pub fn handle(&self) -> &Handle<ClientHandler> {
        &self.handle
    }

    /// 连接复用键。
    pub fn key(&self) -> &str {
        &self.key
    }

    /// 目标的凭证 endpoint `user@host:port`。
    pub fn endpoint(&self) -> &str {
        &self.endpoint
    }

    /// 运行环境。
    pub fn env(&self) -> &Arc<Env> {
        &self.env
    }

    /// 远端转发表。
    pub fn remote_forwards(&self) -> &RemoteForwards {
        &self.remote_forwards
    }

    /// 已建立的转发。
    pub fn forwards(&self) -> std::sync::MutexGuard<'_, ForwardSet> {
        self.forwards.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// 连接是否仍可用。
    pub fn is_alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst) && !self.handle.is_closed()
    }

    /// 标记为不可用（之后的 OPEN 会重新拨号）。
    pub fn mark_dead(&self) {
        self.alive.store(false, Ordering::SeqCst);
    }

    /// 打开 session channel。
    pub async fn open_session(&self) -> Result<Channel<Msg>, russh::Error> {
        self.handle.channel_open_session().await
    }

    /// 打开 direct-tcpip channel（跳板与本地转发用）。
    pub async fn open_direct_tcpip(
        &self,
        host: &str,
        port: u16,
    ) -> Result<Channel<Msg>, russh::Error> {
        self.handle
            .channel_open_direct_tcpip(
                host.to_string(),
                u32::from(port),
                "127.0.0.1".to_string(),
                0,
            )
            .await
    }

    /// 主动断开。
    pub async fn close(&self) {
        self.mark_dead();
        // 对端已断开时发送失败，无需处理。
        let _ = self
            .handle
            .disconnect(russh::Disconnect::ByApplication, "", "en")
            .await;
    }
}

impl Drop for Connection {
    /// 最后一个持有者离开：标记失效。随后 `Handle` 被释放，russh 会话任务读到发送端关闭而结束，
    /// 远端随之回收全部 channel。
    fn drop(&mut self) {
        self.alive.store(false, Ordering::SeqCst);
    }
}

/// 发起这次拨号的 OPEN 的上下文（写进 link.state 与 auth.request）。
#[derive(Debug, Clone, Default)]
pub struct DialRequest {
    pub interactive: bool,
    pub host_id: Option<String>,
    pub target: Option<String>,
}

/// 拨号结果，在订阅者之间共享。
type Shared = Option<Result<Arc<Connection>, SshFailure>>;

/// 一个复用键的状态。
enum Slot {
    Dialing(watch::Receiver<Shared>),
    Ready(Arc<Connection>),
}

/// 连接池。
pub struct Pool {
    env: Arc<Env>,
    slots: Mutex<HashMap<String, Slot>>,
    /// 每个键拨号过几次，用作 link.state 的 attempt，并区分 connecting / reconnecting。
    attempts: Mutex<HashMap<String, u32>>,
}

impl Pool {
    /// 新建连接池。
    pub fn new(env: Arc<Env>) -> Arc<Self> {
        Arc::new(Self {
            env,
            slots: Mutex::new(HashMap::new()),
            attempts: Mutex::new(HashMap::new()),
        })
    }

    /// 锁槽位表。
    fn slots(&self) -> std::sync::MutexGuard<'_, HashMap<String, Slot>> {
        self.slots.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// 取得（必要时拨号）spec 对应的连接。
    pub fn get<'a>(
        self: &'a Arc<Self>,
        spec: &'a ResolvedSpec,
        req: &'a DialRequest,
    ) -> Pin<Box<dyn Future<Output = Result<Arc<Connection>, SshFailure>> + Send + 'a>> {
        // 跳板递归调用 get，异步递归必须装箱。
        Box::pin(async move {
            if spec.jump_depth() > MAX_JUMP_DEPTH {
                return Err(SshFailure::new(
                    FailureKind::TransportFailure,
                    "jump chain too deep",
                ));
            }
            let key = spec.connection_key();
            let mut rx = {
                let mut slots = self.slots();
                match slots.get(&key) {
                    Some(Slot::Ready(conn)) if conn.is_alive() => return Ok(conn.clone()),
                    Some(Slot::Dialing(rx)) => rx.clone(),
                    _ => {
                        let (tx, rx) = watch::channel(None);
                        slots.insert(key.clone(), Slot::Dialing(rx.clone()));
                        let pool = self.clone();
                        let spec = spec.clone();
                        let req = req.clone();
                        // 拨号放进独立任务：发起它的 client 中途断开，也不影响正在等同一结果的其它 OPEN。
                        tokio::spawn(async move {
                            let result = pool.dial(&spec, &req).await;
                            {
                                let mut slots = pool.slots();
                                match &result {
                                    Ok(conn) => {
                                        slots.insert(
                                            spec.connection_key(),
                                            Slot::Ready(conn.clone()),
                                        );
                                    }
                                    Err(_) => {
                                        slots.remove(&spec.connection_key());
                                    }
                                }
                            }
                            let _ = tx.send(Some(result));
                        });
                        rx
                    }
                }
            };
            loop {
                if let Some(result) = rx.borrow().clone() {
                    return result;
                }
                if rx.changed().await.is_err() {
                    return Err(SshFailure::new(
                        FailureKind::TransportFailure,
                        "dial task ended unexpectedly",
                    ));
                }
            }
        })
    }

    /// 发一条 link.state。
    fn link_state(
        &self,
        spec: &ResolvedSpec,
        req: &DialRequest,
        state: LinkState,
        attempt: Option<u32>,
        failure: Option<&SshFailure>,
    ) {
        self.env
            .control
            .emit(&BrokerEvent::LinkState(LinkStateEvent {
                endpoint: spec.credential_endpoint(),
                host_id: req.host_id.clone(),
                target: req.target.clone(),
                state,
                attempt,
                error_kind: failure.map(|f| f.kind),
                detail: failure.map(|f| f.detail.clone()),
            }));
    }

    /// 拨号：上一跳 → 传输流 → 握手（主机密钥）→ 认证。
    async fn dial(
        self: &Arc<Self>,
        spec: &ResolvedSpec,
        req: &DialRequest,
    ) -> Result<Arc<Connection>, SshFailure> {
        let key = spec.connection_key();
        let attempt = {
            let mut attempts = self.attempts.lock().unwrap_or_else(|p| p.into_inner());
            let n = attempts.entry(key.clone()).or_insert(0);
            *n += 1;
            *n
        };
        let state = if attempt > 1 {
            LinkState::Reconnecting
        } else {
            LinkState::Connecting
        };
        self.link_state(spec, req, state, Some(attempt), None);
        match self.dial_once(spec, req).await {
            Ok(conn) => {
                log_info!("connected to {}", spec.credential_endpoint());
                self.link_state(spec, req, LinkState::Connected, Some(attempt), None);
                Ok(conn)
            }
            Err(failure) => {
                log_warn!(
                    "connect to {} failed: {failure}",
                    spec.credential_endpoint()
                );
                self.link_state(spec, req, LinkState::Failed, Some(attempt), Some(&failure));
                Err(failure)
            }
        }
    }

    /// 一次完整的拨号过程。
    async fn dial_once(
        self: &Arc<Self>,
        spec: &ResolvedSpec,
        req: &DialRequest,
    ) -> Result<Arc<Connection>, SshFailure> {
        let via = match spec.jump.as_deref() {
            // 跳板不是用户点名的目标：不带 hostID / target，但沿用交互与否。
            Some(jump) => {
                let jump_req = DialRequest {
                    interactive: req.interactive,
                    host_id: None,
                    target: None,
                };
                Some(self.get(jump, &jump_req).await?)
            }
            None => None,
        };
        let stream = connect::open_transport(spec, via.as_ref(), &self.env).await?;
        let verdict = Arc::new(Mutex::new(None));
        let prompting = Arc::new(AtomicBool::new(false));
        let remote_forwards = RemoteForwards::default();
        let (closed_tx, closed_rx) = oneshot::channel();
        let known_hosts = KnownHostsFiles::for_spec(spec, &self.env);
        let handler = ClientHandler {
            spec_host: spec.host.clone(),
            spec_port: spec.port,
            verify_host_keys: spec.verify_host_keys,
            accept_new_host_keys: spec.accept_new_host_keys,
            known_hosts: known_hosts.clone(),
            interactive: req.interactive,
            env: self.env.clone(),
            verdict: verdict.clone(),
            prompting: prompting.clone(),
            remote_forwards: remote_forwards.clone(),
            // 与 OpenSSH 一致：转发出去的就是这一跳认证用的那个 agent（identityAgent 优先）。
            forward_agent_sock: spec
                .agent_forward
                .then(|| self.env.agent_socket(spec))
                .flatten(),
            closed: Some(closed_tx),
        };
        let config = connect::client_config(spec, &known_hosts);
        let limit = Duration::from_secs(u64::from(spec.connect_timeout.max(1)));
        let handshake = connect::with_handshake_deadline(
            russh::client::connect_stream(config, stream, handler),
            limit,
            &prompting,
        )
        .await;
        let mut handle = match handshake {
            None => {
                return Err(SshFailure::new(
                    FailureKind::Timeout,
                    format!("SSH handshake with {} timed out", spec.host_endpoint()),
                ))
            }
            Some(Ok(h)) => h,
            Some(Err(e)) => {
                let rejected = verdict.lock().unwrap_or_else(|p| p.into_inner()).take();
                return Err(rejected.unwrap_or_else(|| {
                    SshFailure::new(
                        FailureKind::TransportFailure,
                        format!("SSH handshake with {} failed: {e}", spec.host_endpoint()),
                    )
                }));
            }
        };
        let ctx = AuthContext {
            env: &self.env,
            spec,
            interactive: req.interactive,
            host_id: req.host_id.clone(),
        };
        auth::authenticate(&mut handle, &ctx).await?;

        let alive = Arc::new(AtomicBool::new(true));
        let conn = Arc::new(Connection {
            handle,
            key: spec.connection_key(),
            endpoint: spec.credential_endpoint(),
            alive: alive.clone(),
            env: self.env.clone(),
            remote_forwards,
            forwards: Mutex::new(ForwardSet::default()),
            _via: via,
        });
        self.watch_close(spec.clone(), req.clone(), &conn, closed_rx);
        Ok(conn)
    }

    /// 会话结束时：标记失效、把槽位还回空闲、上报 closed / failed。
    fn watch_close(
        self: &Arc<Self>,
        spec: ResolvedSpec,
        req: DialRequest,
        conn: &Arc<Connection>,
        closed: oneshot::Receiver<Option<String>>,
    ) {
        let pool = Arc::downgrade(self);
        let weak = Arc::downgrade(conn);
        let alive = conn.alive.clone();
        tokio::spawn(async move {
            // 发送端随 handler 一起消失也视为关闭。
            let detail = closed.await.ok().flatten();
            alive.store(false, Ordering::SeqCst);
            let Some(pool) = pool.upgrade() else { return };
            {
                let mut slots = pool.slots();
                let ours = matches!(slots.get(&spec.connection_key()), Some(Slot::Ready(c)) if weak.upgrade().is_some_and(|w| Arc::ptr_eq(c, &w)));
                if ours {
                    slots.remove(&spec.connection_key());
                }
            }
            log_info!(
                "connection to {} closed{}",
                spec.credential_endpoint(),
                detail
                    .as_deref()
                    .map(|d| format!(": {d}"))
                    .unwrap_or_default()
            );
            let failure = detail.map(|d| SshFailure::new(FailureKind::TransportFailure, d));
            pool.link_state(&spec, &req, LinkState::Closed, None, failure.as_ref());
        });
    }

    /// 连接因 MaxSessions 拒绝新 session 时退役：从池里摘掉（已有 channel 继续用），下次 OPEN 拨新连接。
    pub fn retire(&self, conn: &Arc<Connection>) {
        let mut slots = self.slots();
        if matches!(slots.get(conn.key()), Some(Slot::Ready(c)) if Arc::ptr_eq(c, conn)) {
            slots.remove(conn.key());
        }
    }

    /// 断开目标 endpoint 为 `endpoint` 的全部连接（App 的 `disconnect` 命令）。
    pub async fn disconnect(&self, endpoint: &str) {
        let doomed: Vec<Arc<Connection>> = {
            let mut slots = self.slots();
            let keys: Vec<String> = slots
                .iter()
                .filter_map(|(k, s)| match s {
                    Slot::Ready(c) if c.endpoint() == endpoint => Some(k.clone()),
                    _ => None,
                })
                .collect();
            keys.iter()
                .filter_map(|k| match slots.remove(k) {
                    Some(Slot::Ready(c)) => Some(c),
                    _ => None,
                })
                .collect()
        };
        for conn in doomed {
            conn.close().await;
        }
    }

    /// 断开全部连接（broker 退出）。
    pub async fn close_all(&self) {
        let all: Vec<Arc<Connection>> = self
            .slots()
            .drain()
            .filter_map(|(_, s)| match s {
                Slot::Ready(c) => Some(c),
                Slot::Dialing(_) => None,
            })
            .collect();
        for conn in all {
            conn.close().await;
        }
    }

    /// 池里当前可用的连接数（测试用）。
    #[cfg(test)]
    pub fn ready_count(&self) -> usize {
        self.slots()
            .values()
            .filter(|s| matches!(s, Slot::Ready(c) if c.is_alive()))
            .count()
    }
}
