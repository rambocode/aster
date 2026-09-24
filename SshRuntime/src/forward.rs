//! 静态端口转发：local（本地监听 → direct-tcpip）、remote（tcpip-forward → forwarded-tcpip）、
//! dynamic（本地 SOCKS5，只支持 CONNECT）。
//!
//! 监听任务只持有连接的 `Weak`，连接被丢弃时任务随 `ForwardSet` 一起中止，不会让连接常驻。
//! 结构参考 tty7 `daemon/ssh/forward.rs`@458c923（Apache-2.0）。

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::{Arc, Mutex, Weak};

use russh::client::Msg;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::task::JoinHandle;

use crate::pool::Connection;
use crate::protocol::{ForwardKind, ForwardRule, HostPort};
use crate::{log_info, log_warn};

/// 远端转发表：服务器上的绑定地址 → 本地目标。
#[derive(Clone, Default)]
pub struct RemoteForwards(Arc<Mutex<HashMap<(String, u32), HostPort>>>);

impl RemoteForwards {
    /// 锁住转发表。
    fn map(&self) -> std::sync::MutexGuard<'_, HashMap<(String, u32), HostPort>> {
        self.0.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// 登记一条远端转发。
    pub fn register(&self, bind_host: &str, bind_port: u32, target: HostPort) {
        self.map()
            .insert((bind_host.to_string(), bind_port), target);
    }

    /// 撤销一条远端转发。
    pub fn remove(&self, bind_host: &str, bind_port: u32) {
        self.map().remove(&(bind_host.to_string(), bind_port));
    }

    /// 查找目标。服务器回报的地址可能和请求时写法不同（如 `localhost` 与 `127.0.0.1`），
    /// 精确匹配不到时退回只按端口匹配。
    pub fn lookup(&self, address: &str, port: u32) -> Option<HostPort> {
        let map = self.map();
        if let Some(t) = map.get(&(address.to_string(), port)) {
            return Some(t.clone());
        }
        let mut by_port = map.iter().filter(|((_, p), _)| *p == port);
        match (by_port.next(), by_port.next()) {
            (Some((_, t)), None) => Some(t.clone()),
            _ => None,
        }
    }
}

/// 一条连接上已经建立的转发。丢弃时中止全部监听任务。
#[derive(Default)]
pub struct ForwardSet {
    installed: Vec<ForwardRule>,
    tasks: Vec<JoinHandle<()>>,
}

impl ForwardSet {
    /// 这条规则是否已经建立过（成功或失败都算，避免每次 OPEN 都重试并刷日志）。
    pub fn contains(&self, rule: &ForwardRule) -> bool {
        self.installed.contains(rule)
    }
}

impl Drop for ForwardSet {
    /// 连接释放时关闭全部本地监听。
    fn drop(&mut self) {
        for task in &self.tasks {
            task.abort();
        }
    }
}

/// 在连接上补齐 spec 里还没建立的转发。失败只记日志，不影响会话本身。
pub async fn ensure(conn: &Arc<Connection>, rules: &[ForwardRule]) {
    for rule in rules {
        {
            let mut set = conn.forwards();
            if set.contains(rule) {
                continue;
            }
            set.installed.push(rule.clone());
        }
        match install(conn, rule).await {
            Ok(Some(task)) => conn.forwards().tasks.push(task),
            Ok(None) => {}
            Err(e) => {
                let msg = format!(
                    "{:?} forward {}:{} failed: {e}",
                    rule.kind, rule.bind.host, rule.bind.port
                );
                log_warn!("{msg}");
                conn.env().control.log(crate::logging::Level::Warn, msg);
            }
        }
    }
}

/// 建立一条转发；本地监听类返回监听任务。
async fn install(
    conn: &Arc<Connection>,
    rule: &ForwardRule,
) -> std::io::Result<Option<JoinHandle<()>>> {
    match rule.kind {
        ForwardKind::Local | ForwardKind::Dynamic => {
            let listener = TcpListener::bind((rule.bind.host.as_str(), rule.bind.port)).await?;
            log_info!(
                "{:?} forward listening on {}",
                rule.kind,
                listener.local_addr()?
            );
            let weak = Arc::downgrade(conn);
            let rule = rule.clone();
            Ok(Some(tokio::spawn(accept_loop(listener, weak, rule))))
        }
        ForwardKind::Remote => {
            let port = u32::from(rule.bind.port);
            conn.remote_forwards()
                .register(&rule.bind.host, port, rule.target.clone());
            match conn
                .handle()
                .tcpip_forward(rule.bind.host.clone(), port)
                .await
            {
                Ok(assigned) => {
                    if port == 0 && assigned != 0 {
                        conn.remote_forwards().remove(&rule.bind.host, 0);
                        conn.remote_forwards().register(
                            &rule.bind.host,
                            assigned,
                            rule.target.clone(),
                        );
                    }
                    log_info!(
                        "remote forward {}:{} registered",
                        rule.bind.host,
                        if port == 0 { assigned } else { port }
                    );
                    Ok(None)
                }
                Err(e) => {
                    conn.remote_forwards().remove(&rule.bind.host, port);
                    Err(std::io::Error::other(e.to_string(),
                    ))
                }
            }
        }
    }
}

/// 本地监听循环：每个入站连接开一条 direct-tcpip（local 直接用规则目标，dynamic 先走 SOCKS5）。
async fn accept_loop(listener: TcpListener, conn: Weak<Connection>, rule: ForwardRule) {
    loop {
        let (socket, peer) = match listener.accept().await {
            Ok(v) => v,
            Err(e) => {
                log_warn!("forward accept failed: {e}");
                continue;
            }
        };
        let Some(conn) = conn.upgrade() else { return };
        let rule = rule.clone();
        tokio::spawn(async move {
            let result = match rule.kind {
                ForwardKind::Dynamic => serve_socks(socket, peer, &conn).await,
                _ => relay(socket, peer, &conn, &rule.target).await,
            };
            if let Err(e) = result {
                log_info!("forward connection from {peer} ended: {e}");
            }
        });
    }
}

/// 打开 direct-tcpip 并在本地 socket 与 channel 之间双向转发。
async fn relay(
    mut socket: TcpStream,
    peer: SocketAddr,
    conn: &Arc<Connection>,
    target: &HostPort,
) -> std::io::Result<()> {
    let channel = conn
        .handle()
        .channel_open_direct_tcpip(
            target.host.clone(),
            u32::from(target.port),
            peer.ip().to_string(),
            u32::from(peer.port()),
        )
        .await
        .map_err(|e| std::io::Error::other(e.to_string()))?;
    let mut stream = channel.into_stream();
    tokio::io::copy_bidirectional(&mut socket, &mut stream)
        .await
        .map(drop)
}

/// forwarded-tcpip channel 到本地目标的桥接（远端转发用）。
pub async fn bridge_to_tcp(mut stream: russh::ChannelStream<Msg>, target: HostPort) {
    match TcpStream::connect((target.host.as_str(), target.port)).await {
        Ok(mut socket) => {
            // 任一端关闭即结束；错误只影响这一条转发连接。
            let _ = tokio::io::copy_bidirectional(&mut stream, &mut socket).await;
        }
        Err(e) => log_info!(
            "remote forward: connect to {}:{} failed: {e}",
            target.host,
            target.port
        ),
    }
}

/// SOCKS5 服务端（无认证、只支持 CONNECT）：读出目标后开 direct-tcpip。
async fn serve_socks(
    mut socket: TcpStream,
    peer: SocketAddr,
    conn: &Arc<Connection>,
) -> std::io::Result<()> {
    let target = socks5_accept(&mut socket).await?;
    let opened = conn
        .handle()
        .channel_open_direct_tcpip(
            target.host.clone(),
            u32::from(target.port),
            peer.ip().to_string(),
            u32::from(peer.port()),
        )
        .await;
    let channel = match opened {
        Ok(c) => c,
        Err(e) => {
            // 0x05：连接被拒绝。
            socket
                .write_all(&[0x05, 0x05, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
                .await?;
            return Err(std::io::Error::other(e.to_string(),
            ));
        }
    };
    socket
        .write_all(&[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
        .await?;
    let mut stream = channel.into_stream();
    tokio::io::copy_bidirectional(&mut socket, &mut stream)
        .await
        .map(drop)
}

/// SOCKS5 握手的服务端部分：协商无认证，解析 CONNECT 目标。
pub async fn socks5_accept<S: AsyncRead + AsyncWrite + Unpin>(
    s: &mut S,
) -> std::io::Result<HostPort> {
    let bad = |m: &str| std::io::Error::new(std::io::ErrorKind::InvalidData, m.to_string());
    let mut head = [0u8; 2];
    s.read_exact(&mut head).await?;
    if head[0] != 0x05 {
        return Err(bad("not SOCKS5"));
    }
    let mut methods = vec![0u8; usize::from(head[1])];
    s.read_exact(&mut methods).await?;
    if !methods.contains(&0x00) {
        s.write_all(&[0x05, 0xff]).await?;
        return Err(bad("client offers no no-auth method"));
    }
    s.write_all(&[0x05, 0x00]).await?;
    let mut req = [0u8; 4];
    s.read_exact(&mut req).await?;
    if req[1] != 0x01 {
        // 0x07：命令不支持。
        s.write_all(&[0x05, 0x07, 0x00, 0x01, 0, 0, 0, 0, 0, 0])
            .await?;
        return Err(bad("only CONNECT is supported"));
    }
    let host = match req[3] {
        0x01 => {
            let mut a = [0u8; 4];
            s.read_exact(&mut a).await?;
            std::net::Ipv4Addr::from(a).to_string()
        }
        0x04 => {
            let mut a = [0u8; 16];
            s.read_exact(&mut a).await?;
            std::net::Ipv6Addr::from(a).to_string()
        }
        0x03 => {
            let mut l = [0u8; 1];
            s.read_exact(&mut l).await?;
            let mut name = vec![0u8; usize::from(l[0])];
            s.read_exact(&mut name).await?;
            String::from_utf8(name).map_err(|_| bad("bad domain name"))?
        }
        _ => return Err(bad("unknown address type")),
    };
    let mut port = [0u8; 2];
    s.read_exact(&mut port).await?;
    Ok(HostPort {
        host,
        port: u16::from_be_bytes(port),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn socks5_accept_parses_domain_and_ipv4_targets() {
        let (mut client, mut server) = tokio::io::duplex(1024);
        let srv = tokio::spawn(async move { socks5_accept(&mut server).await });
        client.write_all(&[0x05, 0x01, 0x00]).await.unwrap();
        let mut reply = [0u8; 2];
        client.read_exact(&mut reply).await.unwrap();
        assert_eq!(reply, [0x05, 0x00]);
        let mut req = vec![0x05, 0x01, 0x00, 0x03, 7];
        req.extend_from_slice(b"example");
        req.extend_from_slice(&443u16.to_be_bytes());
        client.write_all(&req).await.unwrap();
        let target = srv.await.unwrap().unwrap();
        assert_eq!(
            target,
            HostPort {
                host: "example".into(),
                port: 443
            }
        );

        let (mut client, mut server) = tokio::io::duplex(1024);
        let srv = tokio::spawn(async move { socks5_accept(&mut server).await });
        client
            .write_all(&[0x05, 0x01, 0x00, 0x05, 0x01, 0x00, 0x01, 10, 0, 0, 1, 0, 22])
            .await
            .unwrap();
        assert_eq!(
            srv.await.unwrap().unwrap(),
            HostPort {
                host: "10.0.0.1".into(),
                port: 22
            }
        );
    }

    #[test]
    fn remote_forward_lookup_falls_back_to_port() {
        let table = RemoteForwards::default();
        table.register(
            "localhost",
            9000,
            HostPort {
                host: "127.0.0.1".into(),
                port: 80,
            },
        );
        assert_eq!(table.lookup("localhost", 9000).unwrap().port, 80);
        assert_eq!(table.lookup("127.0.0.1", 9000).unwrap().port, 80);
        assert!(table.lookup("127.0.0.1", 9001).is_none());
    }
}
