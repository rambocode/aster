//! 建立到一跳的传输流与 russh 客户端配置。
//!
//! 传输方式：直连 TCP、ProxyCommand（`/bin/sh -c`）、SOCKS5、HTTP CONNECT、上一跳的
//! direct-tcpip channel。结构参考 tty7 `daemon/ssh/connect.rs`@458c923（Apache-2.0），
//! 实现按本仓库需要重写：ProxyCommand 改为经 shell 执行。

use std::borrow::Cow;
use std::path::Path;
use std::pin::Pin;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

use russh::client::Msg;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf};
use tokio::net::TcpStream;
use tokio::time::Instant;

use crate::env::{expand_tokens, Env};
use crate::known_hosts;
use crate::pool::Connection;
use crate::protocol::{FailureKind, ResolvedSpec, SshFailure};

// MARK: - 传输流

/// 一跳的底层字节流。
pub enum Transport {
    Tcp(TcpStream),
    Process(ProcessStream),
    Channel(russh::ChannelStream<Msg>),
}

impl AsyncRead for Transport {
    /// 按变体转发读。
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            Transport::Tcp(s) => Pin::new(s).poll_read(cx, buf),
            Transport::Process(s) => Pin::new(s).poll_read(cx, buf),
            Transport::Channel(s) => Pin::new(s).poll_read(cx, buf),
        }
    }
}

impl AsyncWrite for Transport {
    /// 按变体转发写。
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        match self.get_mut() {
            Transport::Tcp(s) => Pin::new(s).poll_write(cx, buf),
            Transport::Process(s) => Pin::new(s).poll_write(cx, buf),
            Transport::Channel(s) => Pin::new(s).poll_write(cx, buf),
        }
    }

    /// 按变体转发 flush。
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            Transport::Tcp(s) => Pin::new(s).poll_flush(cx),
            Transport::Process(s) => Pin::new(s).poll_flush(cx),
            Transport::Channel(s) => Pin::new(s).poll_flush(cx),
        }
    }

    /// 按变体转发 shutdown。
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        match self.get_mut() {
            Transport::Tcp(s) => Pin::new(s).poll_shutdown(cx),
            Transport::Process(s) => Pin::new(s).poll_shutdown(cx),
            Transport::Channel(s) => Pin::new(s).poll_shutdown(cx),
        }
    }
}

/// ProxyCommand 子进程的 stdin/stdout 组成的双向流。流被丢弃时子进程被杀掉。
pub struct ProcessStream {
    _child: tokio::process::Child,
    stdin: tokio::process::ChildStdin,
    stdout: tokio::process::ChildStdout,
}

impl AsyncRead for ProcessStream {
    /// 读子进程 stdout。
    fn poll_read(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &mut ReadBuf<'_>,
    ) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().stdout).poll_read(cx, buf)
    }
}

impl AsyncWrite for ProcessStream {
    /// 写子进程 stdin。
    fn poll_write(
        self: Pin<&mut Self>,
        cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        Pin::new(&mut self.get_mut().stdin).poll_write(cx, buf)
    }

    /// flush 子进程 stdin。
    fn poll_flush(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().stdin).poll_flush(cx)
    }

    /// 关闭子进程 stdin。
    fn poll_shutdown(self: Pin<&mut Self>, cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Pin::new(&mut self.get_mut().stdin).poll_shutdown(cx)
    }
}

/// io 错误里连不上一类的，归为 hostUnreachable；超时归 timeout。
fn connect_failure(what: &str, e: std::io::Error) -> SshFailure {
    let kind = match e.kind() {
        std::io::ErrorKind::TimedOut => FailureKind::Timeout,
        _ => FailureKind::HostUnreachable,
    };
    SshFailure::new(kind, format!("{what}: {e}"))
}

/// TCP 连接，带超时。
async fn tcp_connect(host: &str, port: u16, limit: Duration) -> Result<TcpStream, SshFailure> {
    let what = format!("connect to {}:{port}", crate::protocol::bracket_host(host));
    match tokio::time::timeout(limit, TcpStream::connect((host, port))).await {
        Ok(Ok(s)) => {
            // Nagle 会让交互式按键多等一个 RTT；设置失败不影响正确性。
            let _ = s.set_nodelay(true);
            Ok(s)
        }
        Ok(Err(e)) => Err(connect_failure(&what, e)),
        Err(_) => Err(SshFailure::new(
            FailureKind::Timeout,
            format!("{what}: timed out"),
        )),
    }
}

/// 为一跳建立传输流。优先级：ProxyCommand > 跳板 > SOCKS5 > HTTP CONNECT > 直连。
pub async fn open_transport(
    spec: &ResolvedSpec,
    via: Option<&Arc<Connection>>,
    env: &Env,
) -> Result<Transport, SshFailure> {
    let limit = Duration::from_secs(u64::from(spec.connect_timeout.max(1)));
    if let Some(template) = spec
        .proxy_command
        .as_deref()
        .filter(|c| !c.trim().is_empty() && *c != "none")
    {
        return spawn_proxy_command(template, spec, env);
    }
    if let Some(jump) = via {
        let channel = tokio::time::timeout(limit, jump.open_direct_tcpip(&spec.host, spec.port))
            .await
            .map_err(|_| {
                SshFailure::new(
                    FailureKind::Timeout,
                    format!("jump to {} timed out", spec.host_endpoint()),
                )
            })?
            .map_err(|e| {
                SshFailure::new(
                    FailureKind::HostUnreachable,
                    format!("jump to {} failed: {e}", spec.host_endpoint()),
                )
            })?;
        return Ok(Transport::Channel(channel.into_stream()));
    }
    if let Some(proxy) = &spec.socks_proxy {
        let mut s = tcp_connect(&proxy.host, proxy.port, limit).await?;
        tokio::time::timeout(limit, socks5_handshake(&mut s, &spec.host, spec.port))
            .await
            .map_err(|_| SshFailure::new(FailureKind::Timeout, "SOCKS5 handshake timed out"))?
            .map_err(|e| {
                SshFailure::new(FailureKind::HostUnreachable, format!("SOCKS5 proxy: {e}"))
            })?;
        return Ok(Transport::Tcp(s));
    }
    if let Some(proxy) = &spec.http_proxy {
        let mut s = tcp_connect(&proxy.host, proxy.port, limit).await?;
        tokio::time::timeout(limit, http_connect_handshake(&mut s, &spec.host, spec.port))
            .await
            .map_err(|_| SshFailure::new(FailureKind::Timeout, "HTTP CONNECT timed out"))?
            .map_err(|e| {
                SshFailure::new(FailureKind::HostUnreachable, format!("HTTP proxy: {e}"))
            })?;
        return Ok(Transport::Tcp(s));
    }
    Ok(Transport::Tcp(
        tcp_connect(&spec.host, spec.port, limit).await?,
    ))
}

/// 经 `/bin/sh -c "exec …"` 启动 ProxyCommand，`%h/%p/%r` 在交给 shell 之前展开（与 OpenSSH 一致）。
fn spawn_proxy_command(
    template: &str,
    spec: &ResolvedSpec,
    env: &Env,
) -> Result<Transport, SshFailure> {
    let command = expand_tokens(
        template,
        &spec.host,
        spec.port,
        &spec.user,
        &env.local_user,
        &env.home,
    );
    let mut child = tokio::process::Command::new("/bin/sh")
        .arg("-c")
        .arg(format!("exec {command}"))
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        // stdin/stdout 是 SSH 传输流；stderr 接 broker 的 stderr（即日志）。绝不能继承 broker 的
        // stdout：那是控制通道，子进程写一个字节就会污染 JSON 行，还会让 App 读不到 EOF。
        .stderr(std::process::Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| {
            SshFailure::new(
                FailureKind::HostUnreachable,
                format!("spawn ProxyCommand: {e}"),
            )
        })?;
    let (Some(stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
        return Err(SshFailure::new(
            FailureKind::TransportFailure,
            "ProxyCommand stdio unavailable",
        ));
    };
    Ok(Transport::Process(ProcessStream {
        _child: child,
        stdin,
        stdout,
    }))
}

/// SOCKS5（无认证）CONNECT 握手，目标按域名寻址。
pub async fn socks5_handshake<S: AsyncRead + AsyncWrite + Unpin>(
    s: &mut S,
    host: &str,
    port: u16,
) -> std::io::Result<()> {
    let bad = |m: String| std::io::Error::other(m);
    s.write_all(&[0x05, 0x01, 0x00]).await?;
    let mut reply = [0u8; 2];
    s.read_exact(&mut reply).await?;
    if reply != [0x05, 0x00] {
        return Err(bad(format!("proxy refused no-auth ({reply:?})")));
    }
    let name = host.as_bytes();
    if name.len() > 255 {
        return Err(bad("target host too long".into()));
    }
    let mut req = vec![0x05, 0x01, 0x00, 0x03, name.len() as u8];
    req.extend_from_slice(name);
    req.extend_from_slice(&port.to_be_bytes());
    s.write_all(&req).await?;
    let mut head = [0u8; 4];
    s.read_exact(&mut head).await?;
    if head[1] != 0x00 {
        return Err(bad(format!("CONNECT failed (reply code {})", head[1])));
    }
    // 绑定地址长度随 ATYP 变化，必须读干净，否则剩下的字节会被当成 SSH banner。
    let addr_len = match head[3] {
        0x01 => 4,
        0x04 => 16,
        0x03 => {
            let mut l = [0u8; 1];
            s.read_exact(&mut l).await?;
            usize::from(l[0])
        }
        other => return Err(bad(format!("unexpected ATYP {other}"))),
    };
    let mut rest = vec![0u8; addr_len + 2];
    s.read_exact(&mut rest).await?;
    Ok(())
}

/// HTTP CONNECT 握手：只认状态行里的 200，读到空行为止，不多读一个字节。
pub async fn http_connect_handshake<S: AsyncRead + AsyncWrite + Unpin>(
    s: &mut S,
    host: &str,
    port: u16,
) -> std::io::Result<()> {
    let authority = format!("{}:{port}", crate::protocol::bracket_host(host));
    let req = format!("CONNECT {authority} HTTP/1.1\r\nHost: {authority}\r\n\r\n");
    s.write_all(req.as_bytes()).await?;
    let mut head = Vec::with_capacity(256);
    let mut byte = [0u8; 1];
    while !head.ends_with(b"\r\n\r\n") {
        s.read_exact(&mut byte).await?;
        head.push(byte[0]);
        if head.len() > 16 * 1024 {
            return Err(std::io::Error::other("response headers too large"));
        }
    }
    let text = String::from_utf8_lossy(&head);
    let status = text.lines().next().unwrap_or("").trim().to_string();
    let code = status.split_whitespace().nth(1).unwrap_or("");
    if code != "200" {
        return Err(std::io::Error::other(format!("CONNECT refused: {status}")));
    }
    Ok(())
}

// MARK: - russh 配置

/// 按 spec 生成 russh 客户端配置：keepalive，以及把 known_hosts 里已有的主机密钥算法排到前面。
///
/// 排序是为了不让「默认优先 ed25519」把一台只以 RSA 记录在案的主机当成未知主机
/// （OpenSSH `order_hostkeyalgs()` 的做法，参考 tty7 connect.rs@458c923）。
pub fn client_config(spec: &ResolvedSpec, known_hosts: &Path) -> Arc<russh::client::Config> {
    let mut config = russh::client::Config::default();
    if spec.keepalive_interval > 0 {
        config.keepalive_interval = Some(Duration::from_secs(u64::from(spec.keepalive_interval)));
        config.keepalive_max = spec.keepalive_count_max.max(1) as usize;
    }
    config.nodelay = true;
    let known = known_hosts::known_algorithms(known_hosts, &spec.host, spec.port);
    if !known.is_empty() {
        let same_key = |a: &russh::keys::Algorithm, b: &russh::keys::Algorithm| {
            matches!(
                (a, b),
                (
                    russh::keys::Algorithm::Rsa { .. },
                    russh::keys::Algorithm::Rsa { .. }
                )
            ) || a == b
        };
        let mut order: Vec<russh::keys::Algorithm> = config.preferred.key.iter().cloned().collect();
        order.sort_by_key(|alg| !known.iter().any(|k| same_key(k, alg)));
        config.preferred.key = Cow::Owned(order);
    }
    Arc::new(config)
}

// MARK: - 握手超时

/// 带超时地等待握手，但用户正在回答主机密钥确认时暂停计时，答完后重新给满一个超时。
pub async fn with_handshake_deadline<F: std::future::Future>(
    fut: F,
    limit: Duration,
    prompting: &AtomicBool,
) -> Option<F::Output> {
    tokio::pin!(fut);
    let mut deadline = Instant::now() + limit;
    let mut paused = false;
    loop {
        tokio::select! {
            out = &mut fut => return Some(out),
            _ = tokio::time::sleep_until(deadline) => {
                if prompting.load(Ordering::SeqCst) {
                    paused = true;
                    deadline = Instant::now() + Duration::from_millis(200);
                } else if paused {
                    paused = false;
                    deadline = Instant::now() + limit;
                } else {
                    return None;
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::io::duplex;

    /// 让假代理先写完脚本再收下全部请求字节，返回握手结果与请求内容。
    async fn scripted<F, Fut>(script: Vec<u8>, run: F) -> (std::io::Result<()>, Vec<u8>)
    where
        F: FnOnce(tokio::io::DuplexStream) -> Fut,
        Fut: std::future::Future<Output = std::io::Result<()>>,
    {
        let (client, mut proxy) = duplex(4096);
        let peer = tokio::spawn(async move {
            proxy.write_all(&script).await.unwrap();
            let mut seen = Vec::new();
            let mut buf = [0u8; 512];
            while let Ok(n) = proxy.read(&mut buf).await {
                if n == 0 {
                    break;
                }
                seen.extend_from_slice(&buf[..n]);
            }
            seen
        });
        let out = run(client).await;
        (out, peer.await.unwrap())
    }

    #[tokio::test]
    async fn socks5_connect_by_domain_name() {
        let script = [
            &[0x05u8, 0x00][..],
            &[0x05, 0x00, 0x00, 0x01, 127, 0, 0, 1, 0x1f, 0x90][..],
        ]
        .concat();
        let (out, sent) = scripted(script, |mut c| async move {
            socks5_handshake(&mut c, "example.com", 22).await
        })
        .await;
        out.unwrap();
        assert_eq!(&sent[..3], &[0x05, 0x01, 0x00]);
        assert_eq!(&sent[3..8], &[0x05, 0x01, 0x00, 0x03, 11]);
        assert_eq!(&sent[8..19], b"example.com");
        assert_eq!(&sent[19..21], &22u16.to_be_bytes());
    }

    #[tokio::test]
    async fn socks5_reports_refusal() {
        let (out, _) = scripted(
            vec![0x05, 0x00, 0x05, 0x05, 0x00, 0x01],
            |mut c| async move { socks5_handshake(&mut c, "h", 22).await },
        )
        .await;
        assert!(out.unwrap_err().to_string().contains("reply code 5"));
    }

    #[tokio::test]
    async fn http_connect_accepts_only_status_200() {
        let ok = b"HTTP/1.1 200 Connection established\r\nVia: x\r\n\r\n".to_vec();
        let (out, sent) = scripted(ok, |mut c| async move {
            http_connect_handshake(&mut c, "example.com", 22).await
        })
        .await;
        out.unwrap();
        assert!(String::from_utf8_lossy(&sent).starts_with("CONNECT example.com:22 HTTP/1.1\r\n"));
        let bad = b"HTTP/1.1 502 Bad Gateway\r\nX-Up: 200\r\n\r\n".to_vec();
        let (out, _) = scripted(bad, |mut c| async move {
            http_connect_handshake(&mut c, "h", 22).await
        })
        .await;
        assert!(out.is_err());
    }

    #[tokio::test]
    async fn handshake_deadline_pauses_while_prompting() {
        let prompting = Arc::new(AtomicBool::new(true));
        let flag = prompting.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(300)).await;
            flag.store(false, Ordering::SeqCst);
        });
        // 总耗时 400ms > 超时 150ms，但其中 300ms 在等用户，应该算成功。
        let out = with_handshake_deadline(
            tokio::time::sleep(Duration::from_millis(400)),
            Duration::from_millis(150),
            &prompting,
        )
        .await;
        assert!(out.is_some());
        let idle = AtomicBool::new(false);
        let out = with_handshake_deadline(
            tokio::time::sleep(Duration::from_secs(5)),
            Duration::from_millis(50),
            &idle,
        )
        .await;
        assert!(out.is_none());
    }
}
