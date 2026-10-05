//! `aster-ssh broker --socket <path>`：常驻进程，持有全部 SSH 连接。
//!
//! stdin/stdout 是与 App 的控制通道（JSON Lines），unix socket 接受 `aster-ssh client`。
//! stdin EOF 或 `shutdown`：断开全部连接、删除 socket、退出。

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use russh::client::Msg;
use russh::{Channel, ChannelMsg};
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::net::{UnixListener, UnixStream};
use tokio::sync::mpsc;
use zeroize::Zeroizing;

use crate::control::{AuthAnswer, Control};
use crate::env::{Env, Paths};
use crate::pool::{Connection, DialRequest, Pool};
use crate::protocol::{
    frame, read_frame, write_frame, AppCommand, BrokerEvent, FailureKind, Frame, OpenRequest,
    ResolvedSpec, SshFailure,
};
use crate::ssh_config::HostEntry;
use crate::target::Resolver;
use crate::{bridge, forward, log_info, log_warn};

/// ssh_config 查询函数。
pub type Lookup = Arc<dyn Fn(&str) -> Option<HostEntry> + Send + Sync>;

/// 处理一行控制命令之后该做什么。
#[derive(Debug, PartialEq, Eq)]
pub enum Flow {
    Continue,
    Shutdown,
}

/// broker 本体。
pub struct Broker {
    env: Arc<Env>,
    pool: Arc<Pool>,
    /// hostID（大写）→ 规格，由 `profiles.sync` 全量替换。
    profiles: Mutex<HashMap<String, ResolvedSpec>>,
    lookup: Lookup,
}

impl Broker {
    /// 新建 broker，返回控制通道出方向的接收端。
    pub fn new(paths: Paths, lookup: Lookup) -> (Arc<Self>, mpsc::UnboundedReceiver<String>) {
        let (control, rx) = Control::new();
        let env = Arc::new(Env {
            control: Arc::new(control),
            known_hosts: paths.known_hosts,
            global_known_hosts: paths.global_known_hosts,
            home: paths.home,
            agent_sock: paths.agent_sock,
            local_user: paths.local_user,
        });
        let broker = Arc::new(Self {
            pool: Pool::new(env.clone()),
            env,
            profiles: Mutex::new(HashMap::new()),
            lookup,
        });
        (broker, rx)
    }

    /// 控制通道。
    pub fn control(&self) -> &Arc<Control> {
        &self.env.control
    }

    /// 连接池（测试用）。
    #[cfg(test)]
    pub fn pool(&self) -> &Arc<Pool> {
        &self.pool
    }

    /// 处理 App 发来的一行。坏行记日志后忽略，未知类型直接忽略。
    pub async fn handle_line(&self, line: &str) -> Flow {
        let line = line.trim();
        if line.is_empty() {
            return Flow::Continue;
        }
        let command: AppCommand = match serde_json::from_str(line) {
            Ok(c) => c,
            // 只报解析错误的位置，不回显原文：原文可能是带口令的 auth.answer。
            Err(e) => {
                log_warn!(
                    "ignoring malformed control line (line {}, column {})",
                    e.line(),
                    e.column()
                );
                return Flow::Continue;
            }
        };
        match command {
            AppCommand::ProfilesSync { profiles } => {
                let mut parsed = HashMap::new();
                for (id, value) in profiles {
                    match serde_json::from_value::<ResolvedSpec>(value) {
                        Ok(spec) => {
                            parsed.insert(id.to_uppercase(), spec);
                        }
                        Err(e) => log_warn!("profiles.sync: host {id} ignored: {e}"),
                    }
                }
                log_info!("profiles.sync: {} host(s)", parsed.len());
                *self.profiles.lock().unwrap_or_else(|p| p.into_inner()) = parsed;
            }
            AppCommand::AuthAnswer {
                id,
                secret,
                responses,
            } => {
                let answer = AuthAnswer {
                    secret: secret.map(Zeroizing::new),
                    responses: responses.map(|v| v.into_iter().map(Zeroizing::new).collect()),
                };
                self.env.control.deliver_auth(&id, answer);
            }
            AppCommand::HostKeyAnswer { id, accept } => {
                self.env.control.deliver_host_key(&id, accept)
            }
            AppCommand::Disconnect { endpoint } => self.pool.disconnect(&endpoint).await,
            AppCommand::Shutdown => return Flow::Shutdown,
            AppCommand::Unknown => {}
        }
        Flow::Continue
    }

    /// 接受 client 连接，直到 listener 出错。
    pub async fn serve(self: Arc<Self>, listener: UnixListener) {
        loop {
            match listener.accept().await {
                Ok((stream, _)) => {
                    let broker = self.clone();
                    tokio::spawn(async move { broker.serve_client(stream).await });
                }
                Err(e) => {
                    log_warn!("accept failed: {e}");
                    tokio::time::sleep(Duration::from_millis(100)).await;
                }
            }
        }
    }

    /// 断开全部连接，唤醒全部等待中的请求。
    pub async fn shutdown(&self) {
        self.env.control.cancel_all();
        // 对端不响应时不能卡住退出。
        let _ = tokio::time::timeout(Duration::from_secs(2), self.pool.close_all()).await;
    }

    /// OPEN 对应的规格。
    fn spec_for(&self, open: &OpenRequest) -> Result<ResolvedSpec, SshFailure> {
        if let Some(id) = &open.host_id {
            let profiles = self.profiles.lock().unwrap_or_else(|p| p.into_inner());
            let mut spec = profiles.get(&id.to_uppercase()).cloned().ok_or_else(|| {
                SshFailure::new(
                    FailureKind::TransportFailure,
                    format!("unknown host id {id}"),
                )
            })?;
            if let Some(t) = open.connect_timeout {
                spec.connect_timeout = t;
            }
            return Ok(spec);
        }
        let Some(text) = open.target.as_deref().filter(|t| !t.trim().is_empty()) else {
            return Err(SshFailure::new(
                FailureKind::TransportFailure,
                "OPEN without hostID or target",
            ));
        };
        let lookup = self.lookup.clone();
        let lookup_fn = move |name: &str| lookup(name);
        let resolver = Resolver {
            home: &self.env.home,
            local_user: &self.env.local_user,
            lookup: &lookup_fn,
            connect_timeout: open.connect_timeout,
        };
        resolver.resolve(text)
    }

    /// 服务一个 client：OPEN → 连接 → 开 channel → OPENED → 转发。
    async fn serve_client(self: Arc<Self>, stream: UnixStream) {
        let (mut rd, mut wr) = stream.into_split();
        let open = match read_frame(&mut rd).await {
            Ok(Some(f)) if f.kind == frame::OPEN => match f.parse::<OpenRequest>() {
                Ok(open) => open,
                Err(e) => {
                    let _ = send_error(
                        &mut wr,
                        &SshFailure::new(FailureKind::TransportFailure, format!("bad OPEN: {e}")),
                    )
                    .await;
                    return;
                }
            },
            _ => return,
        };
        let spec = match self.spec_for(&open) {
            Ok(s) => s,
            Err(f) => {
                let _ = send_error(&mut wr, &f).await;
                return;
            }
        };
        let req = DialRequest {
            interactive: open.interactive,
            host_id: open.host_id.clone(),
            target: open.target.clone(),
        };

        let mut stash = Vec::new();
        let (conn, channel, early) = match self
            .open_channel(&spec, &req, &open, &mut rd, &mut stash)
            .await
        {
            Ok(Some(v)) => v,
            // client 在等连接期间走了。
            Ok(None) => return,
            Err(f) => {
                let _ = send_error(&mut wr, &f).await;
                return;
            }
        };
        if write_frame(&mut wr, &Frame::new(frame::OPENED, b"{}".to_vec()))
            .await
            .is_err()
        {
            // client 已经走了；丢弃 channel 前照样发 EOF/CLOSE。
            let _ = channel.eof().await;
            let _ = channel.close().await;
            return;
        }
        let rd = std::io::Cursor::new(stash).chain(rd);
        bridge::run(conn, channel, early, rd, wr).await;
    }

    /// 取连接并打开、配置 session channel；等到 exec/shell 请求被确认才返回。
    ///
    /// 等连接（可能在等用户回答认证表单）期间盯住 client：它先走了就返回 None，不再等；
    /// 拨号任务本身继续，结果留给其它 OPEN。client 在 OPENED 之前本不该发帧，万一发了也存进
    /// `stash`，转发开始时按原顺序补上。只盯拨号这一段：channel 一旦打开就必须由转发循环
    /// 负责关闭，不能在这里被取消丢掉。
    async fn open_channel<R: AsyncRead + Unpin>(
        &self,
        spec: &ResolvedSpec,
        req: &DialRequest,
        open: &OpenRequest,
        rd: &mut R,
        stash: &mut Vec<u8>,
    ) -> Result<Option<(Arc<Connection>, Channel<Msg>, Vec<ChannelMsg>)>, SshFailure> {
        let mut last: Option<SshFailure> = None;
        for _ in 0..3 {
            let conn = tokio::select! {
                r = self.pool.get(spec, req) => r?,
                _ = wait_for_eof(rd, stash) => return Ok(None),
            };
            forward::ensure(&conn, &spec.forwards).await;
            let mut channel = match conn.open_session().await {
                Ok(c) => c,
                // sshd 的 MaxSessions 用满了：这条连接不再接受新 session，换一条新的。
                Err(russh::Error::ChannelOpenFailure(russh::ChannelOpenFailure::ConnectFailed)) => {
                    self.pool.retire(&conn);
                    last = Some(SshFailure::new(
                        FailureKind::TransportFailure,
                        "server refused a new session",
                    ));
                    continue;
                }
                Err(e) => {
                    conn.mark_dead();
                    last = Some(SshFailure::new(
                        FailureKind::TransportFailure,
                        format!("open session: {e}"),
                    ));
                    continue;
                }
            };
            return match self.start_session(&conn, &mut channel, spec, open).await {
                Ok(early) => Ok(Some((conn, channel, early))),
                Err(f) => {
                    let _ = channel.close().await;
                    Err(f)
                }
            };
        }
        Err(last.unwrap_or_else(|| {
            SshFailure::new(FailureKind::TransportFailure, "open session failed")
        }))
    }

    /// 发 agent 转发 / pty / exec 或 shell 请求，等服务器确认。确认前收到的消息原样返回。
    async fn start_session(
        &self,
        conn: &Connection,
        channel: &mut Channel<Msg>,
        spec: &ResolvedSpec,
        open: &OpenRequest,
    ) -> Result<Vec<ChannelMsg>, SshFailure> {
        let fail = |what: &str, e: russh::Error| {
            SshFailure::new(FailureKind::TransportFailure, format!("{what}: {e}"))
        };
        if spec.agent_forward && conn.env().agent_socket(spec).is_some() {
            channel
                .agent_forward(false)
                .await
                .map_err(|e| fail("agent forward", e))?;
        }
        if open.tty {
            let term = if open.term.is_empty() {
                crate::protocol::default_term()
            } else {
                open.term.clone()
            };
            channel
                .request_pty(false, &term, open.cols, open.rows, 0, 0, &[])
                .await
                .map_err(|e| fail("pty request", e))?;
        }
        match open.command.as_deref() {
            Some(cmd) => channel
                .exec(true, cmd.as_bytes())
                .await
                .map_err(|e| fail("exec request", e))?,
            None => channel
                .request_shell(true)
                .await
                .map_err(|e| fail("shell request", e))?,
        }
        let limit = Duration::from_secs(u64::from(spec.connect_timeout.max(1)).max(10));
        let mut early = Vec::new();
        let confirmed = tokio::time::timeout(limit, async {
            loop {
                match channel.wait().await {
                    Some(ChannelMsg::Success) => return Ok(()),
                    Some(ChannelMsg::Failure) => {
                        return Err(SshFailure::new(
                            FailureKind::TransportFailure,
                            "server refused the exec/shell request",
                        ))
                    }
                    Some(ChannelMsg::Close) | None => {
                        return Err(SshFailure::new(
                            FailureKind::TransportFailure,
                            "channel closed before the session started",
                        ))
                    }
                    Some(other) => early.push(other),
                }
            }
        })
        .await;
        match confirmed {
            Ok(Ok(())) => Ok(early),
            Ok(Err(f)) => Err(f),
            Err(_) => Err(SshFailure::new(
                FailureKind::Timeout,
                "server did not answer the exec/shell request",
            )),
        }
    }
}

/// 读 client socket 直到 EOF；期间读到的字节存进 `stash`。
async fn wait_for_eof<R: AsyncRead + Unpin>(rd: &mut R, stash: &mut Vec<u8>) {
    loop {
        match rd.read_buf(stash).await {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
    }
}

/// 发 ERROR 帧。
async fn send_error<W: tokio::io::AsyncWrite + Unpin>(
    wr: &mut W,
    failure: &SshFailure,
) -> std::io::Result<()> {
    write_frame(wr, &Frame::json(frame::ERROR, failure)).await
}

/// 删除残留的 socket 文件（只删 socket，不碰同名的普通文件）。
fn remove_stale_socket(path: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::FileTypeExt as _;
    match std::fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_socket() => std::fs::remove_file(path),
        Ok(_) => Err(std::io::Error::new(
            std::io::ErrorKind::AlreadyExists,
            format!("{} exists and is not a socket", path.display()),
        )),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(e) => Err(e),
    }
}

/// 绑定 socket 并设为 0600。
pub fn bind_socket(path: &Path) -> std::io::Result<UnixListener> {
    remove_stale_socket(path)?;
    let listener = UnixListener::bind(path)?;
    use std::os::unix::fs::PermissionsExt as _;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

/// `aster-ssh broker --socket <path>` 入口。
pub fn run_cli(args: &[String]) -> ExitCode {
    let mut socket: Option<PathBuf> = None;
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            "--socket" => socket = it.next().map(PathBuf::from),
            other => {
                eprintln!("aster-ssh broker: unknown argument {other}");
                return ExitCode::from(2);
            }
        }
    }
    let Some(socket) = socket else {
        eprintln!("usage: aster-ssh broker --socket <path>");
        return ExitCode::from(2);
    };
    let runtime = match tokio::runtime::Builder::new_multi_thread()
        .worker_threads(2)
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => {
            eprintln!("aster-ssh broker: runtime: {e}");
            return ExitCode::from(1);
        }
    };
    let code = runtime.block_on(run(socket));
    // stdin 读取占着一个阻塞线程，等 runtime 回收会卡住；清理已经做完，直接退出。
    std::process::exit(code);
}

/// broker 主循环。
async fn run(socket: PathBuf) -> i32 {
    let listener = match bind_socket(&socket) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("aster-ssh broker: bind {}: {e}", socket.display());
            return 1;
        }
    };
    // ssh_config 与 known_hosts 用同一个主目录（尊重 ASTER_SSH_HOME），测试与生产看到的配置位置一致。
    let paths = Paths::from_process();
    let config_home = paths.home.clone();
    let lookup: Lookup = Arc::new(move |alias: &str| {
        crate::ssh_config::resolve_in(
            &config_home.join(".ssh").join("config"),
            &config_home,
            alias,
        )
    });
    let (broker, mut out_rx) = Broker::new(paths, lookup);
    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(line) = out_rx.recv().await {
            if stdout.write_all(line.as_bytes()).await.is_err()
                || stdout.write_all(b"\n").await.is_err()
                || stdout.flush().await.is_err()
            {
                break;
            }
        }
    });
    broker.control().emit(&BrokerEvent::Ready {
        socket: socket.to_string_lossy().into_owned(),
        version: env!("CARGO_PKG_VERSION").to_string(),
    });
    log_info!("broker listening on {}", socket.display());
    let server = tokio::spawn(broker.clone().serve(listener));

    let mut lines = tokio::io::BufReader::new(tokio::io::stdin()).lines();
    loop {
        match lines.next_line().await {
            Ok(Some(line)) => {
                if broker.handle_line(&line).await == Flow::Shutdown {
                    break;
                }
            }
            Ok(None) => break,
            Err(e) => {
                log_warn!("control channel read failed: {e}");
                break;
            }
        }
    }
    log_info!("broker shutting down");
    server.abort();
    broker.shutdown().await;
    if let Err(e) = std::fs::remove_file(&socket) {
        log_warn!("remove socket {}: {e}", socket.display());
    }
    broker.control().close_output();
    let _ = tokio::time::timeout(Duration::from_secs(1), writer).await;
    0
}
