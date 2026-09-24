// 端到端：exec 退出码、pty、channel 生命周期、跳板链、端口转发、target 解析与控制命令。

use std::sync::atomic::Ordering;
use std::time::{Duration, Instant};

use tokio::io::{AsyncReadExt, AsyncWriteExt};

use super::*;
use crate::broker::Flow;
use crate::protocol::{frame, read_frame, write_frame, ForwardKind, ForwardRule, Frame, HostPort};
use crate::test_support::{FakeConfig, FakeSshd};

/// accept_none 服务器 + 已同步为 "h" 的规格。
async fn open_server() -> (FakeSshd, Harness) {
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    h.sync(&[("h", &spec(server.port))]).await;
    (server, h)
}

#[tokio::test]
async fn exit_status_signal_and_stderr_are_propagated() {
    let (server, h) = open_server().await;
    let run = h.run(open_host("h", Some("exit 42"), false), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 42);
    let run = h
        .run(open_host("h", Some("signal TERM"), false), vec![])
        .await;
    assert_eq!(exit_status(&run.outcome), 128 + libc::SIGTERM);
    let run = h.run(open_host("h", Some("stderr"), false), vec![]).await;
    assert_eq!(
        (
            exit_status(&run.outcome),
            run.stderr.as_str(),
            run.stdout.as_str()
        ),
        (0, "oops\n", "")
    );
    let run = h
        .run(
            open_host("h", Some("echo"), false),
            vec![b"hello ", b"world"],
        )
        .await;
    assert_eq!(
        (exit_status(&run.outcome), run.stdout.as_str()),
        (0, "hello world")
    );
    let run = h
        .run(open_host("h", Some("no-status"), false), vec![])
        .await;
    assert_eq!(failure_kind(&run.outcome), "transportFailure");
    assert_eq!(server.stats.execs.lock().unwrap()[0], "exit 42");
    assert_eq!(
        server.stats.connections.load(Ordering::SeqCst),
        1,
        "all runs share one connection"
    );
}

#[tokio::test]
async fn tty_requests_a_pty_and_forwards_resizes() {
    let (server, h) = open_server().await;
    let mut open = open_host("h", Some("tty"), false);
    open.tty = true;
    open.cols = 100;
    open.rows = 30;
    let run = h.run(open.clone(), vec![]).await;
    assert_eq!(run.stdout, "tty=xterm-256color 100x30\n");

    // 交互 shell：发一次窗口变化，然后结束 client。
    open.command = None;
    open.term = "xterm-ghostty".into();
    let stream = UnixStream::connect(&h.socket).await.unwrap();
    let (mut rd, mut wr) = stream.into_split();
    write_frame(&mut wr, &Frame::json(frame::OPEN, &open))
        .await
        .unwrap();
    assert_eq!(
        read_frame(&mut rd).await.unwrap().unwrap().kind,
        frame::OPENED
    );
    let prompt = read_frame(&mut rd).await.unwrap().unwrap();
    assert_eq!(
        (prompt.kind, prompt.payload.as_slice()),
        (frame::STDOUT, &b"$ "[..])
    );
    write_frame(
        &mut wr,
        &Frame::json(
            frame::RESIZE,
            &ResizeRequest {
                cols: 132,
                rows: 50,
            },
        ),
    )
    .await
    .unwrap();
    let deadline = Instant::now() + Duration::from_secs(3);
    while !server
        .stats
        .window_changes
        .lock()
        .unwrap()
        .contains(&(132, 50))
    {
        assert!(
            Instant::now() < deadline,
            "window change reached the server"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    assert_eq!(
        server.stats.ptys.lock().unwrap()[1],
        ("xterm-ghostty".to_string(), 100, 30)
    );
}

/// 硬约束：client 断开后，服务器必须在 2 秒内看到 channel 关闭。
#[tokio::test]
async fn client_disconnect_closes_the_channel_within_two_seconds() {
    let (server, h) = open_server().await;
    for round in 1..=2 {
        let mut open = open_host("h", Some("hang"), false);
        open.tty = round == 2;
        let stream = UnixStream::connect(&h.socket).await.unwrap();
        let (mut rd, mut wr) = stream.into_split();
        write_frame(&mut wr, &Frame::json(frame::OPEN, &open))
            .await
            .unwrap();
        assert_eq!(
            read_frame(&mut rd).await.unwrap().unwrap().kind,
            frame::OPENED
        );
        write_frame(&mut wr, &Frame::new(frame::STDIN, b"typing".to_vec()))
            .await
            .unwrap();
        let before = server.closed();
        let gone = Instant::now();
        drop((rd, wr));
        assert!(
            server.wait_closed(before + 1, Duration::from_secs(2)).await,
            "channel closed within 2s (round {round})"
        );
        assert!(gone.elapsed() < Duration::from_secs(2));
    }
    // 连接本身保留给后续 OPEN 复用。
    assert_eq!(h.broker.pool().ready_count(), 1);
}

#[tokio::test]
async fn client_that_leaves_while_waiting_for_a_prompt_does_not_break_the_dial() {
    let server = FakeSshd::start(FakeConfig {
        passwords: vec!["pw".into()],
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    h.sync(&[("h", &spec(server.port))]).await;
    // 第一个 client 在凭证请求挂起时离开；答案随后到达，第二个 client 复用结果。
    h.script
        .lock()
        .unwrap()
        .passwords
        .push_back(Some("pw".into()));
    let stream = UnixStream::connect(&h.socket).await.unwrap();
    let (_rd, mut wr) = stream.into_split();
    write_frame(
        &mut wr,
        &Frame::json(frame::OPEN, &open_host("h", Some("hang"), true)),
    )
    .await
    .unwrap();
    drop((_rd, wr));
    let run = h.run(open_host("h", Some("exit 5"), true), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 5);
    assert_eq!(h.events_of("auth.request").len(), 1);
}

#[tokio::test]
async fn jump_chain_tunnels_through_direct_tcpip() {
    let jump = FakeSshd::start(FakeConfig {
        accept_none: true,
        host_key_seed: 41,
        ..Default::default()
    })
    .await;
    let target = FakeSshd::start(FakeConfig {
        accept_none: true,
        host_key_seed: 42,
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    let mut s = spec(target.port);
    s.jump = Some(Box::new(spec(jump.port)));
    h.sync(&[("t", &s)]).await;
    let run = h.run(open_host("t", Some("exit 9"), false), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 9);
    assert_eq!(
        jump.stats.direct_tcpip.lock().unwrap()[0],
        ("127.0.0.1".to_string(), u32::from(target.port))
    );
    assert_eq!(
        jump.stats.opened.load(Ordering::SeqCst),
        0,
        "no session on the jump host itself"
    );
    assert_eq!(target.stats.opened.load(Ordering::SeqCst), 1);
    let endpoints: Vec<String> = h
        .events_of("link.state")
        .iter()
        .map(|e| e["endpoint"].as_str().unwrap().to_string())
        .collect();
    assert!(endpoints.contains(&format!("tester@127.0.0.1:{}", jump.port)));
}

#[tokio::test]
async fn proxy_command_is_run_through_the_shell() {
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    // 用 ProxyCommand 再连一次测试服务器：nc 在 macOS 上自带；%h/%p 由 broker 展开。
    let mut s = spec(server.port);
    s.host = "127.0.0.1".into();
    s.proxy_command = Some("nc %h %p".into());
    h.sync(&[("p", &s)]).await;
    let run = h.run(open_host("p", Some("exit 4"), false), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 4);
}

/// 经本地端口发一段数据并读回回显。
async fn ping_through(port: u16) -> String {
    let mut s = tokio::net::TcpStream::connect(("127.0.0.1", port))
        .await
        .unwrap();
    s.write_all(b"ping").await.unwrap();
    let mut buf = [0u8; 4];
    tokio::time::timeout(Duration::from_secs(5), s.read_exact(&mut buf))
        .await
        .unwrap()
        .unwrap();
    String::from_utf8_lossy(&buf).into_owned()
}

#[tokio::test]
async fn local_remote_and_dynamic_forwards_carry_traffic() {
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        ..Default::default()
    })
    .await;
    let echo = echo_server().await;
    let (local, remote, dynamic) = (free_port(), free_port(), free_port());
    let at = |port: u16| HostPort {
        host: "127.0.0.1".into(),
        port,
    };
    let h = Harness::new().await;
    let mut s = spec(server.port);
    s.forwards = vec![
        ForwardRule {
            kind: ForwardKind::Local,
            bind: at(local),
            target: at(echo),
            description: String::new(),
        },
        ForwardRule {
            kind: ForwardKind::Remote,
            bind: at(remote),
            target: at(echo),
            description: String::new(),
        },
        ForwardRule {
            kind: ForwardKind::Dynamic,
            bind: at(dynamic),
            target: at(0),
            description: String::new(),
        },
    ];
    h.sync(&[("h", &s)]).await;
    assert_eq!(
        exit_status(
            &h.run(open_host("h", Some("exit 0"), false), vec![])
                .await
                .outcome
        ),
        0
    );

    assert_eq!(ping_through(local).await, "ping");
    // 假服务器在本机监听远端转发端口，连它就等于从「远端」发起连接。
    assert_eq!(ping_through(remote).await, "ping");

    let mut socks = tokio::net::TcpStream::connect(("127.0.0.1", dynamic))
        .await
        .unwrap();
    crate::connect::socks5_handshake(&mut socks, "127.0.0.1", echo)
        .await
        .unwrap();
    socks.write_all(b"pong").await.unwrap();
    let mut buf = [0u8; 4];
    socks.read_exact(&mut buf).await.unwrap();
    assert_eq!(&buf, b"pong");
}

#[tokio::test]
async fn target_text_resolves_through_ssh_config_lookup() {
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        ..Default::default()
    })
    .await;
    let port = server.port;
    let lookup: crate::broker::Lookup = Arc::new(move |name: &str| {
        (name == "orb").then(|| crate::ssh_config::HostEntry {
            alias: "orb".into(),
            host_name: Some("127.0.0.1".into()),
            user: Some("root".into()),
            port: Some(port),
            ..Default::default()
        })
    });
    let h = Harness::with_lookup(lookup).await;
    // 未知主机密钥需要确认，这里接受。
    h.script.lock().unwrap().host_keys.extend([true]);
    let mut open = open_host("unused", Some("exit 6"), true);
    open.host_id = None;
    open.target = Some("orb".into());
    let run = h.run(open.clone(), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 6);
    let states = h.events_of("link.state");
    assert_eq!(states[0]["endpoint"], format!("root@127.0.0.1:{port}"));
    assert_eq!(states[0]["target"], "orb");
    assert!(states[0]["hostID"].is_null());

    open.target = Some(format!("someone@127.0.0.1:{port}"));
    let run = h.run(open, vec![]).await;
    assert_eq!(exit_status(&run.outcome), 6);
}

#[tokio::test]
async fn control_channel_ignores_unknown_and_malformed_lines() {
    let h = Harness::new().await;
    assert_eq!(
        h.broker
            .handle_line(r#"{"type":"future.feature","x":1}"#)
            .await,
        Flow::Continue
    );
    assert_eq!(
        h.broker.handle_line("not json at all").await,
        Flow::Continue
    );
    assert_eq!(
        h.broker
            .handle_line(r#"{"type":"auth.answer","id":"a999","secret":"leak-me-5T"}"#)
            .await,
        Flow::Continue
    );
    assert_eq!(
        h.broker.handle_line(r#"{"type":"shutdown"}"#).await,
        Flow::Shutdown
    );
    assert_logs_free_of(&["leak-me-5T"]);
    use std::os::unix::fs::PermissionsExt as _;
    let mode = std::fs::metadata(&h.socket).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);
}

/// 测试用代理：`socks` 为 true 时说 SOCKS5，否则说 HTTP CONNECT；返回端口与经手的目标。
async fn proxy_server(socks: bool) -> (u16, Arc<std::sync::Mutex<Vec<String>>>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let seen = Arc::new(std::sync::Mutex::new(Vec::new()));
    let log = seen.clone();
    tokio::spawn(async move {
        while let Ok((mut client, _)) = listener.accept().await {
            let log = log.clone();
            tokio::spawn(async move {
                let target = if socks {
                    let t = crate::forward::socks5_accept(&mut client).await.unwrap();
                    format!("{}:{}", t.host, t.port)
                } else {
                    let mut head = Vec::new();
                    let mut byte = [0u8; 1];
                    while !head.ends_with(b"\r\n\r\n") {
                        client.read_exact(&mut byte).await.unwrap();
                        head.push(byte[0]);
                    }
                    let text = String::from_utf8_lossy(&head).into_owned();
                    text.split_whitespace().nth(1).unwrap().to_string()
                };
                log.lock().unwrap().push(target.clone());
                let mut upstream = tokio::net::TcpStream::connect(target.as_str())
                    .await
                    .unwrap();
                let reply: &[u8] = if socks {
                    &[0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]
                } else {
                    b"HTTP/1.1 200 Connection established\r\n\r\n"
                };
                client.write_all(reply).await.unwrap();
                let _ = tokio::io::copy_bidirectional(&mut client, &mut upstream).await;
            });
        }
    });
    (port, seen)
}

#[tokio::test]
async fn socks5_and_http_connect_proxies_carry_the_ssh_transport() {
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    let (socks_port, socks_seen) = proxy_server(true).await;
    let (http_port, http_seen) = proxy_server(false).await;
    let mut via_socks = spec(server.port);
    via_socks.socks_proxy = Some(HostPort {
        host: "127.0.0.1".into(),
        port: socks_port,
    });
    let mut via_http = spec(server.port);
    via_http.http_proxy = Some(HostPort {
        host: "127.0.0.1".into(),
        port: http_port,
    });
    h.sync(&[("s", &via_socks), ("w", &via_http)]).await;
    let run = h.run(open_host("s", Some("exit 11"), false), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 11);
    let run = h.run(open_host("w", Some("exit 12"), false), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 12);
    let target = format!("127.0.0.1:{}", server.port);
    assert_eq!(*socks_seen.lock().unwrap(), vec![target.clone()]);
    assert_eq!(*http_seen.lock().unwrap(), vec![target]);
    assert_eq!(server.stats.connections.load(Ordering::SeqCst), 2);
}
