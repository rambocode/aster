//! russh 客户端回调：主机密钥校验（known_hosts + 控制通道确认）、远端转发与 agent 转发的
//! 入站 channel、会话结束通知。
//! 参考 tty7 `daemon/ssh/handler.rs`@458c923（Apache-2.0），确认流程改为经控制通道问 App。

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

use russh::client::{ChannelOpenHandle, Msg, Session};
use russh::keys::PublicKey;
use russh::Channel;
use tokio::sync::oneshot;

use crate::env::Env;
use crate::forward::RemoteForwards;
use crate::known_hosts::{self, HostKeyStatus};
use crate::protocol::{FailureKind, HostKeyConfirm, HostKeyStatusKind, HostPort, SshFailure};
use crate::{log_info, log_warn};

/// 一跳 SSH 连接的 russh 回调。
pub struct ClientHandler {
    pub spec_host: String,
    pub spec_port: u16,
    pub verify_host_keys: bool,
    pub interactive: bool,
    pub env: Arc<Env>,
    /// 主机密钥被拒绝时的原因，握手失败后由调用方取出，映射成 hostKeyUnknown / hostKeyChanged。
    pub verdict: Arc<Mutex<Option<SshFailure>>>,
    /// 正在等用户确认主机密钥（暂停握手计时）。
    pub prompting: Arc<AtomicBool>,
    pub remote_forwards: RemoteForwards,
    /// 是否接受服务器发来的 agent 转发 channel。
    pub agent_forward: bool,
    /// 会话结束时发出原因（None 表示正常断开）。
    pub closed: Option<oneshot::Sender<Option<String>>>,
}

impl ClientHandler {
    /// 记录拒绝原因。
    fn reject(&self, failure: SshFailure) {
        *self.verdict.lock().unwrap_or_else(|p| p.into_inner()) = Some(failure);
    }

    /// `host:port`。
    fn endpoint(&self) -> String {
        format!(
            "{}:{}",
            crate::protocol::bracket_host(&self.spec_host),
            self.spec_port
        )
    }
}

impl russh::client::Handler for ClientHandler {
    type Error = russh::Error;

    /// 按 known_hosts 校验；未知或变更时交互请求向 App 确认，非交互请求直接失败。
    async fn check_server_key(&mut self, key: &PublicKey) -> Result<bool, Self::Error> {
        let status =
            known_hosts::check_file(&self.env.known_hosts, &self.spec_host, self.spec_port, key);
        // 关闭校验只是「不在乎这台主机是谁」，被显式吊销的密钥仍然拒绝（与 tty7 一致）。
        if status == HostKeyStatus::Revoked {
            self.reject(SshFailure::new(
                FailureKind::HostKeyChanged,
                format!("host key for {} is revoked", self.endpoint()),
            ));
            return Ok(false);
        }
        if !self.verify_host_keys || status == HostKeyStatus::Known {
            return Ok(true);
        }
        let (kind, status_kind, word) = match status {
            HostKeyStatus::Changed => (
                FailureKind::HostKeyChanged,
                HostKeyStatusKind::Changed,
                "changed",
            ),
            _ => (
                FailureKind::HostKeyUnknown,
                HostKeyStatusKind::Unknown,
                "unknown",
            ),
        };
        let fingerprint = known_hosts::fingerprint(key);
        if !self.interactive {
            self.reject(SshFailure::new(
                kind,
                format!("host key for {} is {word} ({fingerprint})", self.endpoint()),
            ));
            return Ok(false);
        }
        self.prompting.store(true, Ordering::SeqCst);
        let accepted = self
            .env
            .control
            .confirm_host_key(HostKeyConfirm {
                id: String::new(),
                endpoint: self.endpoint(),
                algorithm: key.algorithm().as_str().to_string(),
                fingerprint: fingerprint.clone(),
                status: status_kind,
                interactive: true,
            })
            .await;
        self.prompting.store(false, Ordering::SeqCst);
        if !accepted {
            self.reject(SshFailure::new(
                kind,
                format!(
                    "host key for {} was not accepted ({fingerprint})",
                    self.endpoint()
                ),
            ));
            return Ok(false);
        }
        let written = match status {
            HostKeyStatus::Changed => {
                known_hosts::replace(&self.env.known_hosts, &self.spec_host, self.spec_port, key)
            }
            _ => known_hosts::append(&self.env.known_hosts, &self.spec_host, self.spec_port, key),
        };
        match written {
            Ok(()) => log_info!("recorded host key for {} in known_hosts", self.endpoint()),
            // 用户已经确认，这次连接照常进行；只是下次还会再问。
            Err(e) => log_warn!("could not record host key for {}: {e}", self.endpoint()),
        }
        Ok(true)
    }

    /// 远端转发的新连接：按绑定地址找到本地目标，连上后双向转发。
    async fn server_channel_open_forwarded_tcpip(
        &mut self,
        channel: Channel<Msg>,
        connected_address: &str,
        connected_port: u32,
        _originator_address: &str,
        _originator_port: u32,
        reply: ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        let Some(target) = self
            .remote_forwards
            .lookup(connected_address, connected_port)
        else {
            log_info!(
                "rejecting forwarded-tcpip for unregistered {connected_address}:{connected_port}"
            );
            return Ok(());
        };
        reply.accept().await;
        tokio::spawn(crate::forward::bridge_to_tcp(
            channel.into_stream(),
            HostPort {
                host: target.host,
                port: target.port,
            },
        ));
        Ok(())
    }

    /// agent 转发：只在 spec 打开了 agentForward 且本机有 agent 时接受。
    async fn server_channel_open_agent_forward(
        &mut self,
        channel: Channel<Msg>,
        reply: ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        let Some(sock) = self.env.agent_sock.clone().filter(|_| self.agent_forward) else {
            return Ok(());
        };
        reply.accept().await;
        tokio::spawn(async move {
            match tokio::net::UnixStream::connect(&sock).await {
                Ok(mut agent) => {
                    let mut stream = channel.into_stream();
                    // 任一端关闭即结束，错误只影响这一次 agent 请求。
                    let _ = tokio::io::copy_bidirectional(&mut stream, &mut agent).await;
                }
                Err(e) => log_warn!("agent forward: connect to local agent failed: {e}"),
            }
        });
        Ok(())
    }

    /// 会话结束：通知连接池。
    async fn disconnected(
        &mut self,
        reason: russh::client::DisconnectReason<Self::Error>,
    ) -> Result<(), Self::Error> {
        let (detail, result) = match reason {
            russh::client::DisconnectReason::ReceivedDisconnect(info) => (
                Some(format!("server disconnected: {}", info.message)),
                Ok(()),
            ),
            russh::client::DisconnectReason::Error(e) => (Some(e.to_string()), Err(e)),
        };
        if let Some(tx) = self.closed.take() {
            let _ = tx.send(detail);
        }
        result
    }
}
