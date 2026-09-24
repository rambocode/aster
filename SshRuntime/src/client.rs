//! `aster-ssh client …`：替代 `/usr/bin/ssh` 的薄客户端。
//!
//! 连到 broker socket，发 OPEN，收到 OPENED 后转发 stdin/stdout/stderr、窗口大小，
//! 最后按 EXIT / ERROR 决定退出码。退出码规则见 PROTOCOL §2：
//! 远端正常结束 → 远端状态；被信号结束 → 128+信号值；传输失败 → 255，并在 stderr
//! 最后一行写 `aster-ssh-error {json}`。

use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::process::ExitCode;
use std::time::Duration;

use tokio::io::{AsyncWrite, AsyncWriteExt};
use tokio::net::UnixStream;
use tokio::sync::mpsc;

use crate::protocol::{
    frame, read_frame, write_frame, ExitReport, FailureKind, Frame, OpenRequest, ResizeRequest,
    SshFailure,
};
use crate::terminal::{enter_raw_mode, is_tty, restore_terminal, window_size};

/// 结构化错误行前缀，与 Swift `NativeSSHErrorLine.prefix` 相同。
pub const ERROR_PREFIX: &str = "aster-ssh-error ";
/// broker 还没 bind 完时，client 最多等这么久（App 先公布端点再拉起 broker）。
const BROKER_CONNECT_GRACE: Duration = Duration::from_secs(2);
/// 重试间隔。
const BROKER_CONNECT_RETRY: Duration = Duration::from_millis(75);

/// 每个 STDIN 帧最多携带的字节数。
const STDIN_CHUNK: usize = 32 * 1024;

/// 解析后的命令行。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClientArgs {
    pub broker: PathBuf,
    pub host_id: Option<String>,
    pub target: Option<String>,
    pub tty: bool,
    pub no_prompt: bool,
    pub connect_timeout: Option<u32>,
    pub command: Option<String>,
}

/// 解析 `client` 之后的参数。
pub fn parse_args(args: &[String]) -> Result<ClientArgs, String> {
    let mut out = ClientArgs {
        broker: PathBuf::new(),
        host_id: None,
        target: None,
        tty: false,
        no_prompt: false,
        connect_timeout: None,
        command: None,
    };
    let mut broker = None;
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        let mut value = |name: &str| {
            it.next()
                .cloned()
                .ok_or_else(|| format!("{name} needs a value"))
        };
        match arg.as_str() {
            "--broker" => broker = Some(PathBuf::from(value("--broker")?)),
            "--host-id" => out.host_id = Some(value("--host-id")?),
            "--target" => out.target = Some(value("--target")?),
            "--tty" => out.tty = true,
            "--no-prompt" => out.no_prompt = true,
            "--connect-timeout" => {
                let v = value("--connect-timeout")?;
                out.connect_timeout = Some(
                    v.parse()
                        .map_err(|_| format!("bad --connect-timeout {v}"))?,
                );
            }
            "--" => {
                // 远端命令本应是单个字符串；多于一个时按 OpenSSH 的做法用空格拼接。
                let rest: Vec<String> = it.by_ref().cloned().collect();
                if !rest.is_empty() {
                    out.command = Some(rest.join(" "));
                }
            }
            other => return Err(format!("unknown argument {other}")),
        }
    }
    out.broker = broker.ok_or("--broker is required")?;
    match (&out.host_id, &out.target) {
        (Some(_), None) | (None, Some(_)) => Ok(out),
        _ => Err("exactly one of --host-id or --target is required".to_string()),
    }
}

/// 连接 broker socket。socket 还不存在（ENOENT）或没人监听（ECONNREFUSED）时，
/// 在 `grace` 内每隔 75ms 重试；其它错误和超时直接返回最后一次的错误。
pub async fn connect_broker(path: &Path, grace: Duration) -> std::io::Result<UnixStream> {
    let deadline = tokio::time::Instant::now() + grace;
    loop {
        match UnixStream::connect(path).await {
            Ok(s) => return Ok(s),
            Err(e) => {
                let retryable = matches!(
                    e.kind(),
                    std::io::ErrorKind::NotFound | std::io::ErrorKind::ConnectionRefused
                );
                if !retryable || tokio::time::Instant::now() + BROKER_CONNECT_RETRY > deadline {
                    return Err(e);
                }
                tokio::time::sleep(BROKER_CONNECT_RETRY).await;
            }
        }
    }
}

/// 一次会话的结局。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    Exit(ExitReport),
    Failed(SshFailure),
}

/// 信号名 → 信号值。
fn signal_number(name: &str) -> Option<i32> {
    let n = match name.trim_start_matches("SIG") {
        "HUP" => libc::SIGHUP,
        "INT" => libc::SIGINT,
        "QUIT" => libc::SIGQUIT,
        "ILL" => libc::SIGILL,
        "ABRT" => libc::SIGABRT,
        "FPE" => libc::SIGFPE,
        "KILL" => libc::SIGKILL,
        "SEGV" => libc::SIGSEGV,
        "PIPE" => libc::SIGPIPE,
        "ALRM" => libc::SIGALRM,
        "TERM" => libc::SIGTERM,
        "USR1" => libc::SIGUSR1,
        "USR2" => libc::SIGUSR2,
        _ => return None,
    };
    Some(n)
}

/// 结局 → 进程退出码。
pub fn exit_code(outcome: &Outcome) -> i32 {
    match outcome {
        Outcome::Exit(ExitReport {
            status: Some(s), ..
        }) => s & 0xff,
        Outcome::Exit(ExitReport {
            signal: Some(sig), ..
        }) => signal_number(sig).map_or(255, |n| 128 + n),
        _ => 255,
    }
}

/// 失败时写在 stderr 最后一行的结构化错误。
pub fn error_line(failure: &SshFailure) -> String {
    format!(
        "{ERROR_PREFIX}{}",
        serde_json::to_string(failure).unwrap_or_default()
    )
}

/// 会话的本地端：stdin 块（None 表示 EOF）、窗口变化、输出流，以及 OPENED 时的回调（进入 raw 模式）。
pub struct ClientIo<O, E> {
    pub stdin: mpsc::Receiver<Option<Vec<u8>>>,
    pub resize: mpsc::UnboundedReceiver<ResizeRequest>,
    pub stdout: O,
    pub stderr: E,
    pub on_opened: Box<dyn FnOnce() + Send>,
}

/// 从 broker 读来的帧；读取放在独立任务里，因为 `read_frame` 不能在 select 里被中途取消。
fn spawn_frame_reader(mut rd: tokio::net::unix::OwnedReadHalf) -> mpsc::Receiver<Option<Frame>> {
    let (tx, rx) = mpsc::channel(64);
    tokio::spawn(async move {
        loop {
            match read_frame(&mut rd).await {
                Ok(Some(f)) => {
                    if tx.send(Some(f)).await.is_err() {
                        return;
                    }
                }
                _ => {
                    let _ = tx.send(None).await;
                    return;
                }
            }
        }
    });
    rx
}

/// ERROR 帧 → 失败；payload 坏了也要给出一个失败。
fn error_from(frame: &Frame) -> SshFailure {
    frame.parse::<SshFailure>().unwrap_or_else(|_| {
        SshFailure::new(FailureKind::TransportFailure, "malformed error from broker")
    })
}

/// 跑完一次会话：OPEN → OPENED → 转发 → EXIT / ERROR。
pub async fn drive<O, E>(stream: UnixStream, open: &OpenRequest, mut io: ClientIo<O, E>) -> Outcome
where
    O: AsyncWrite + Unpin,
    E: AsyncWrite + Unpin,
{
    let lost = || {
        Outcome::Failed(SshFailure::new(
            FailureKind::TransportFailure,
            "connection to aster-ssh broker lost",
        ))
    };
    let (rd, mut wr) = stream.into_split();
    if write_frame(&mut wr, &Frame::json(frame::OPEN, open))
        .await
        .is_err()
    {
        return lost();
    }
    let mut frames = spawn_frame_reader(rd);
    loop {
        match frames.recv().await.flatten() {
            Some(f) if f.kind == frame::OPENED => break,
            Some(f) if f.kind == frame::ERROR => return Outcome::Failed(error_from(&f)),
            Some(_) => continue,
            None => return lost(),
        }
    }
    (io.on_opened)();

    // 写 broker 失败（它可能刚发完 EXIT 就关了 socket）不能直接判定失败：
    // 停止发送，继续读完已经到达的帧，由 EXIT / ERROR / EOF 决定结局。
    let mut stdin_open = true;
    let mut resize_open = true;
    loop {
        let to_send = tokio::select! {
            f = frames.recv() => {
                let Some(f) = f.flatten() else { return lost() };
                match f.kind {
                    frame::STDOUT => {
                        // 本地 stdout 关了（如管道读端退出）：不再输出，但会话照常等远端结束。
                        let _ = io.stdout.write_all(&f.payload).await;
                        let _ = io.stdout.flush().await;
                    }
                    frame::STDERR => {
                        let _ = io.stderr.write_all(&f.payload).await;
                        let _ = io.stderr.flush().await;
                    }
                    frame::EXIT => return Outcome::Exit(f.parse().unwrap_or_default()),
                    frame::ERROR => return Outcome::Failed(error_from(&f)),
                    _ => {}
                }
                None
            }
            chunk = io.stdin.recv(), if stdin_open => Some(match chunk.flatten() {
                Some(bytes) => Frame::new(frame::STDIN, bytes),
                None => {
                    stdin_open = false;
                    Frame::new(frame::STDIN_EOF, Vec::new())
                }
            }),
            size = io.resize.recv(), if resize_open => match size {
                Some(size) => Some(Frame::json(frame::RESIZE, &size)),
                None => {
                    resize_open = false;
                    None
                }
            },
        };
        if let Some(frame) = to_send {
            if write_frame(&mut wr, &frame).await.is_err() {
                stdin_open = false;
                resize_open = false;
            }
        }
    }
}

/// 恢复终端、写出错误行后退出进程。
fn finish(outcome: &Outcome) -> ! {
    restore_terminal();
    if let Outcome::Failed(failure) = outcome {
        let mut err = std::io::stderr().lock();
        // stderr 已不可写时无处可报，只能保留退出码。
        let _ = writeln!(err, "aster-ssh: {}", failure.detail);
        let _ = writeln!(err, "{}", error_line(failure));
    }
    // stdin 读线程还阻塞在 read 上，runtime 无法正常回收；直接退出。
    std::process::exit(exit_code(outcome));
}

/// 在独立线程里阻塞读 fd 0，按块送进 channel；EOF 或出错送 None。
fn spawn_stdin_reader() -> mpsc::Receiver<Option<Vec<u8>>> {
    let (tx, rx) = mpsc::channel(16);
    std::thread::spawn(move || {
        let mut buf = vec![0u8; STDIN_CHUNK];
        loop {
            // SAFETY: buf 在整个调用期间有效且长度正确。
            let n = unsafe { libc::read(0, buf.as_mut_ptr().cast(), buf.len()) };
            if n < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            let item = (n > 0).then(|| buf[..n as usize].to_vec());
            let eof = item.is_none();
            if tx.blocking_send(item).is_err() || eof {
                return;
            }
        }
    });
    rx
}

/// 被 SIGHUP/SIGTERM/SIGINT/SIGQUIT 结束时先恢复终端再退出（128+信号值）。
fn spawn_signal_exit() -> std::io::Result<()> {
    use tokio::signal::unix::{signal, SignalKind};
    for (kind, num) in [
        (SignalKind::hangup(), libc::SIGHUP),
        (SignalKind::terminate(), libc::SIGTERM),
        (SignalKind::interrupt(), libc::SIGINT),
        (SignalKind::quit(), libc::SIGQUIT),
    ] {
        let mut stream = signal(kind)?;
        tokio::spawn(async move {
            if stream.recv().await.is_some() {
                restore_terminal();
                std::process::exit(128 + num);
            }
        });
    }
    Ok(())
}

/// `aster-ssh client …` 入口。
pub fn run_cli(args: &[String]) -> ExitCode {
    let args = match parse_args(args) {
        Ok(a) => a,
        Err(e) => finish(&Outcome::Failed(SshFailure::new(
            FailureKind::TransportFailure,
            format!("invalid arguments: {e}"),
        ))),
    };
    let runtime = match tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
    {
        Ok(rt) => rt,
        Err(e) => finish(&Outcome::Failed(SshFailure::new(
            FailureKind::TransportFailure,
            format!("runtime: {e}"),
        ))),
    };
    let outcome = runtime.block_on(async move {
        if let Err(e) = spawn_signal_exit() {
            return Outcome::Failed(SshFailure::new(
                FailureKind::TransportFailure,
                format!("signal setup: {e}"),
            ));
        }
        let stream = match connect_broker(&args.broker, BROKER_CONNECT_GRACE).await {
            Ok(s) => s,
            Err(e) => {
                return Outcome::Failed(SshFailure::new(
                    FailureKind::TransportFailure,
                    format!("aster-ssh broker unavailable: {e}"),
                ))
            }
        };
        let raw = args.tty && is_tty(0);
        let size = if args.tty {
            window_size()
        } else {
            ResizeRequest { cols: 80, rows: 24 }
        };
        let term = std::env::var("TERM")
            .ok()
            .filter(|t| !t.is_empty())
            .unwrap_or_else(crate::protocol::default_term);
        let open = OpenRequest {
            host_id: args.host_id.clone(),
            target: args.target.clone(),
            tty: args.tty,
            cols: size.cols,
            rows: size.rows,
            term,
            command: args.command.clone(),
            interactive: !args.no_prompt,
            connect_timeout: args.connect_timeout,
        };
        let (resize_tx, resize_rx) = mpsc::unbounded_channel();
        if raw {
            match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::window_change()) {
                Ok(mut winch) => {
                    tokio::spawn(async move {
                        while winch.recv().await.is_some() {
                            if resize_tx.send(window_size()).is_err() {
                                return;
                            }
                        }
                    });
                }
                Err(e) => crate::log_warn!("SIGWINCH unavailable: {e}"),
            }
        } else {
            drop(resize_tx);
        }
        let io = ClientIo {
            stdin: spawn_stdin_reader(),
            resize: resize_rx,
            stdout: tokio::io::stdout(),
            stderr: tokio::io::stderr(),
            on_opened: Box::new(move || {
                if raw {
                    enter_raw_mode();
                }
            }),
        };
        drive(stream, &open, io).await
    });
    finish(&outcome)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// 字符串切片转参数表。
    fn argv(list: &[&str]) -> Vec<String> {
        list.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn parses_the_protocol_command_line() {
        let a = parse_args(&argv(&[
            "--broker",
            "/s",
            "--host-id",
            "U",
            "--tty",
            "--no-prompt",
            "--connect-timeout",
            "5",
            "--",
            "aster-session terminal attach 'x y'",
        ]))
        .unwrap();
        assert_eq!(a.broker, PathBuf::from("/s"));
        assert_eq!(a.host_id.as_deref(), Some("U"));
        assert!(a.tty && a.no_prompt);
        assert_eq!(a.connect_timeout, Some(5));
        assert_eq!(
            a.command.as_deref(),
            Some("aster-session terminal attach 'x y'")
        );
        let b = parse_args(&argv(&["--broker", "/s", "--target", "me@h:22"])).unwrap();
        assert_eq!(b.command, None);
        assert!(parse_args(&argv(&["--broker", "/s"])).is_err());
        assert!(parse_args(&argv(&[
            "--broker",
            "/s",
            "--host-id",
            "U",
            "--target",
            "t"
        ]))
        .is_err());
        assert!(parse_args(&argv(&["--target", "t"])).is_err());
        assert!(parse_args(&argv(&["--broker", "/s", "--target", "t", "--bogus"])).is_err());
    }

    #[test]
    fn exit_codes_follow_the_protocol() {
        let exit = |status: Option<i32>, signal: Option<&str>| {
            exit_code(&Outcome::Exit(ExitReport {
                status,
                signal: signal.map(String::from),
            }))
        };
        assert_eq!(exit(Some(0), None), 0);
        assert_eq!(exit(Some(3), None), 3);
        assert_eq!(exit(Some(127), None), 127);
        assert_eq!(exit(None, Some("TERM")), 128 + libc::SIGTERM);
        assert_eq!(exit(None, Some("HUP")), 129);
        assert_eq!(exit(None, Some("WEIRD")), 255);
        assert_eq!(
            exit_code(&Outcome::Failed(SshFailure::new(FailureKind::Timeout, "t"))),
            255
        );
    }

    #[test]
    fn error_line_is_prefix_plus_json() {
        let line = error_line(&SshFailure::new(
            FailureKind::AuthenticationRequired,
            "publickey,password rejected",
        ));
        assert_eq!(
            line,
            r#"aster-ssh-error {"kind":"authenticationRequired","detail":"publickey,password rejected"}"#
        );
    }

    #[tokio::test]
    async fn connect_waits_briefly_for_a_broker_that_is_still_starting() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("late.sock");
        let bind_at = path.clone();
        let listener = tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(300)).await;
            let l = tokio::net::UnixListener::bind(&bind_at).unwrap();
            let _ = l.accept().await;
        });
        let started = std::time::Instant::now();
        connect_broker(&path, Duration::from_secs(2)).await.unwrap();
        assert!(started.elapsed() >= Duration::from_millis(250));
        listener.abort();

        let started = std::time::Instant::now();
        let err = connect_broker(&dir.path().join("never.sock"), Duration::from_millis(400))
            .await
            .unwrap_err();
        assert_eq!(err.kind(), std::io::ErrorKind::NotFound);
        assert!(started.elapsed() >= Duration::from_millis(300));
        assert!(started.elapsed() < Duration::from_secs(1));
    }
}
