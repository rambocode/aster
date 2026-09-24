//! 测试夹具：进程内的 russh SSH 服务器，只监听 127.0.0.1 的临时端口。
//!
//! 只依赖 russh / tokio / std，既作为单元测试模块，也被 `tests/` 下的进程级测试
//! 以 `#[path]` 引入。exec 命令约定：
//! `exit N`、`signal NAME`、`echo`（回显 stdin，EOF 后退出 0）、`stderr`、`tty`（报告 pty 参数）、
//! `hang`（永不结束）、`no-status`（不带退出状态直接关闭）。
//! 思路参考 tty7 `daemon/ssh/test_support.rs`@458c923（Apache-2.0）。

#![allow(dead_code)]

use std::collections::{HashMap, HashSet};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use russh::keys::ssh_key::private::Ed25519Keypair;
use russh::keys::{PrivateKey, PublicKey};
use russh::server::{self, Auth, ChannelOpenHandle, Msg, Session};
use russh::{Channel, ChannelId, MethodKind, MethodSet, Sig};

/// 服务器行为配置。
#[derive(Clone, Default)]
pub struct FakeConfig {
    /// 接受的口令。
    pub passwords: Vec<String>,
    /// 接受的公钥。
    pub authorized_keys: Vec<PublicKey>,
    /// 键盘交互只有一个提示，回答等于它才通过。
    pub kbd_answer: Option<String>,
    /// none 认证直接通过。
    pub accept_none: bool,
    /// 主机密钥种子。
    pub host_key_seed: u8,
}

/// 服务器观察到的事件计数。
#[derive(Default)]
pub struct Stats {
    pub connections: AtomicUsize,
    pub opened: AtomicUsize,
    pub closed: AtomicUsize,
    pub eofs: AtomicUsize,
    pub password_attempts: AtomicUsize,
    pub kbd_attempts: AtomicUsize,
    pub execs: Mutex<Vec<String>>,
    pub ptys: Mutex<Vec<(String, u32, u32)>>,
    pub window_changes: Mutex<Vec<(u32, u32)>>,
    pub close_times: Mutex<Vec<Instant>>,
    pub direct_tcpip: Mutex<Vec<(String, u32)>>,
}

/// 一台正在运行的假 SSH 服务器。
pub struct FakeSshd {
    pub port: u16,
    pub host_key: PublicKey,
    pub stats: Arc<Stats>,
}

/// 由种子生成确定的 ed25519 私钥（只在测试里存在）。
pub fn key_from_seed(seed: u8) -> PrivateKey {
    PrivateKey::from(Ed25519Keypair::from_seed(&[seed; 32]))
}

impl FakeSshd {
    /// 启动服务器，接受任意多个连接。
    pub async fn start(config: FakeConfig) -> FakeSshd {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
            .await
            .expect("bind loopback");
        let port = listener.local_addr().expect("local addr").port();
        let host = key_from_seed(if config.host_key_seed == 0 {
            7
        } else {
            config.host_key_seed
        });
        let host_key = host.public_key().clone();
        let server_config = server::Config {
            inactivity_timeout: None,
            auth_rejection_time: Duration::from_millis(0),
            auth_rejection_time_initial: Some(Duration::from_millis(0)),
            keys: vec![host],
            methods: MethodSet::from(
                &[
                    MethodKind::PublicKey,
                    MethodKind::Password,
                    MethodKind::KeyboardInteractive,
                ][..],
            ),
            ..Default::default()
        };
        let server_config = Arc::new(server_config);
        let stats = Arc::new(Stats::default());
        let config = Arc::new(config);
        let st = stats.clone();
        tokio::spawn(async move {
            while let Ok((socket, _)) = listener.accept().await {
                st.connections.fetch_add(1, Ordering::SeqCst);
                let handler = Sshd {
                    config: config.clone(),
                    stats: st.clone(),
                    channels: HashMap::new(),
                    echo: HashSet::new(),
                };
                let server_config = server_config.clone();
                tokio::spawn(async move {
                    if let Ok(running) = server::run_stream(server_config, socket, handler).await {
                        let _ = running.await;
                    }
                });
            }
        });
        FakeSshd {
            port,
            host_key,
            stats,
        }
    }

    /// 服务器收到的 CHANNEL_CLOSE 次数。
    pub fn closed(&self) -> usize {
        self.stats.closed.load(Ordering::SeqCst)
    }

    /// 在 `limit` 内等到至少 `n` 次 CHANNEL_CLOSE；返回是否等到。
    pub async fn wait_closed(&self, n: usize, limit: Duration) -> bool {
        let deadline = Instant::now() + limit;
        while self.closed() < n {
            if Instant::now() > deadline {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        true
    }

    /// 在 `limit` 内等到至少 `n` 个已打开的 session。
    pub async fn wait_opened(&self, n: usize, limit: Duration) -> bool {
        let deadline = Instant::now() + limit;
        while self.stats.opened.load(Ordering::SeqCst) < n {
            if Instant::now() > deadline {
                return false;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        true
    }
}

/// 每个连接一份的服务器回调。
struct Sshd {
    config: Arc<FakeConfig>,
    stats: Arc<Stats>,
    /// channel → 请求过的 pty（term, cols, rows）。
    channels: HashMap<ChannelId, (String, u32, u32)>,
    /// 处于回显模式的 channel。
    echo: HashSet<ChannelId>,
}

impl Sshd {
    /// 拒绝并告知剩余方式。
    fn reject() -> Auth {
        Auth::Reject {
            proceed_with_methods: Some(MethodSet::from(
                &[
                    MethodKind::PublicKey,
                    MethodKind::Password,
                    MethodKind::KeyboardInteractive,
                ][..],
            )),
            partial_success: false,
        }
    }

    /// 发退出状态并关闭 channel。
    fn finish(session: &mut Session, channel: ChannelId, status: u32) -> Result<(), russh::Error> {
        session.exit_status_request(channel, status)?;
        session.eof(channel)?;
        session.close(channel)
    }
}

/// 在 SSH channel 与 TCP 连接之间双向转发（跳板与远端转发用）。
async fn bridge(channel: Channel<Msg>, mut tcp: tokio::net::TcpStream) {
    let mut stream = channel.into_stream();
    let _ = tokio::io::copy_bidirectional(&mut stream, &mut tcp).await;
}

impl server::Handler for Sshd {
    type Error = russh::Error;

    async fn auth_none(&mut self, _user: &str) -> Result<Auth, Self::Error> {
        Ok(if self.config.accept_none {
            Auth::Accept
        } else {
            Self::reject()
        })
    }

    async fn auth_password(&mut self, _user: &str, password: &str) -> Result<Auth, Self::Error> {
        self.stats.password_attempts.fetch_add(1, Ordering::SeqCst);
        Ok(if self.config.passwords.iter().any(|p| p == password) {
            Auth::Accept
        } else {
            Self::reject()
        })
    }

    async fn auth_publickey_offered(
        &mut self,
        _user: &str,
        key: &PublicKey,
    ) -> Result<Auth, Self::Error> {
        Ok(if self.config.authorized_keys.contains(key) {
            Auth::Accept
        } else {
            Self::reject()
        })
    }

    async fn auth_publickey(&mut self, _user: &str, key: &PublicKey) -> Result<Auth, Self::Error> {
        Ok(if self.config.authorized_keys.contains(key) {
            Auth::Accept
        } else {
            Self::reject()
        })
    }

    async fn auth_keyboard_interactive<'a>(
        &'a mut self,
        _user: &str,
        _submethods: &str,
        response: Option<server::Response<'a>>,
    ) -> Result<Auth, Self::Error> {
        let Some(expected) = self.config.kbd_answer.clone() else {
            return Ok(Self::reject());
        };
        match response {
            None => Ok(Auth::Partial {
                name: "2FA".into(),
                instructions: "enter the code".into(),
                prompts: vec![("Verification code: ".into(), false)].into(),
            }),
            Some(mut answers) => {
                self.stats.kbd_attempts.fetch_add(1, Ordering::SeqCst);
                let got = answers
                    .next()
                    .map(|b| String::from_utf8_lossy(&b).into_owned());
                Ok(if got.as_deref() == Some(expected.as_str()) {
                    Auth::Accept
                } else {
                    Self::reject()
                })
            }
        }
    }

    async fn channel_open_session(
        &mut self,
        _channel: Channel<Msg>,
        reply: ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.stats.opened.fetch_add(1, Ordering::SeqCst);
        reply.accept().await;
        Ok(())
    }

    async fn channel_open_direct_tcpip(
        &mut self,
        channel: Channel<Msg>,
        host: &str,
        port: u32,
        _originator_address: &str,
        _originator_port: u32,
        reply: ChannelOpenHandle,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.stats
            .direct_tcpip
            .lock()
            .unwrap()
            .push((host.to_string(), port));
        match tokio::net::TcpStream::connect((host, port as u16)).await {
            Ok(tcp) => {
                reply.accept().await;
                tokio::spawn(bridge(channel, tcp));
            }
            Err(_) => reply.reject(russh::ChannelOpenFailure::ConnectFailed).await,
        }
        Ok(())
    }

    async fn tcpip_forward(
        &mut self,
        address: &str,
        port: &mut u32,
        session: &mut Session,
    ) -> Result<bool, Self::Error> {
        let Ok(listener) = tokio::net::TcpListener::bind((address, *port as u16)).await else {
            return Ok(false);
        };
        let bound = listener.local_addr().map(|a| a.port()).unwrap_or(0);
        if *port == 0 {
            *port = u32::from(bound);
        }
        let handle = session.handle();
        let address = address.to_string();
        let reported = *port;
        tokio::spawn(async move {
            while let Ok((tcp, peer)) = listener.accept().await {
                let handle = handle.clone();
                let address = address.clone();
                tokio::spawn(async move {
                    if let Ok(ch) = handle
                        .channel_open_forwarded_tcpip(
                            address,
                            reported,
                            peer.ip().to_string(),
                            u32::from(peer.port()),
                        )
                        .await
                    {
                        bridge(ch, tcp).await;
                    }
                });
            }
        });
        Ok(true)
    }

    async fn pty_request(
        &mut self,
        channel: ChannelId,
        term: &str,
        cols: u32,
        rows: u32,
        _pw: u32,
        _ph: u32,
        _modes: &[(russh::Pty, u32)],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.stats
            .ptys
            .lock()
            .unwrap()
            .push((term.to_string(), cols, rows));
        self.channels
            .insert(channel, (term.to_string(), cols, rows));
        session.channel_success(channel)
    }

    async fn window_change_request(
        &mut self,
        _channel: ChannelId,
        cols: u32,
        rows: u32,
        _pw: u32,
        _ph: u32,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.stats.window_changes.lock().unwrap().push((cols, rows));
        Ok(())
    }

    async fn shell_request(
        &mut self,
        channel: ChannelId,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        session.channel_success(channel)?;
        session.data(channel, &b"$ "[..])
    }

    async fn exec_request(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        let command = String::from_utf8_lossy(data).into_owned();
        self.stats.execs.lock().unwrap().push(command.clone());
        session.channel_success(channel)?;
        let mut words = command.split_whitespace();
        match (words.next(), words.next()) {
            (Some("exit"), Some(n)) => {
                session.data(channel, &b"bye\n"[..])?;
                Self::finish(session, channel, n.parse().unwrap_or(1))
            }
            (Some("signal"), Some(name)) => {
                let sig = match name {
                    "TERM" => Sig::TERM,
                    "KILL" => Sig::KILL,
                    "HUP" => Sig::HUP,
                    other => Sig::Custom(other.to_string()),
                };
                session.exit_signal_request(channel, sig, false, "", "")?;
                session.eof(channel)?;
                session.close(channel)
            }
            (Some("echo"), _) => {
                self.echo.insert(channel);
                Ok(())
            }
            (Some("stderr"), _) => {
                session.extended_data(channel, 1, &b"oops\n"[..])?;
                Self::finish(session, channel, 0)
            }
            (Some("tty"), _) => {
                let line = match self.channels.get(&channel) {
                    Some((term, cols, rows)) => format!("tty={term} {cols}x{rows}\n"),
                    None => "notty\n".to_string(),
                };
                session.data(channel, line.into_bytes())?;
                Self::finish(session, channel, 0)
            }
            (Some("hang"), _) => Ok(()),
            (Some("no-status"), _) => {
                session.eof(channel)?;
                session.close(channel)
            }
            _ => Self::finish(session, channel, 0),
        }
    }

    async fn data(
        &mut self,
        channel: ChannelId,
        data: &[u8],
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        if self.echo.contains(&channel) {
            session.data(channel, data.to_vec())?;
        }
        Ok(())
    }

    async fn channel_eof(
        &mut self,
        channel: ChannelId,
        session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.stats.eofs.fetch_add(1, Ordering::SeqCst);
        if self.echo.remove(&channel) {
            Self::finish(session, channel, 0)?;
        }
        Ok(())
    }

    async fn channel_close(
        &mut self,
        channel: ChannelId,
        _session: &mut Session,
    ) -> Result<(), Self::Error> {
        self.echo.remove(&channel);
        self.stats.closed.fetch_add(1, Ordering::SeqCst);
        self.stats.close_times.lock().unwrap().push(Instant::now());
        Ok(())
    }
}
