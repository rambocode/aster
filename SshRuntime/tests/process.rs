//! 进程级测试：真的启动 `aster-ssh broker` 与 `aster-ssh client` 两个进程，
//! 对着进程内的 russh 服务器（127.0.0.1 临时端口）验证退出码、结构化错误行，
//! 以及「client 进程被杀后 2 秒内远端 channel 关闭」这条硬约束。
//! HOME / ASTER_SSH_HOME 都指向临时目录，SSH_AUTH_SOCK 被清除，不触碰真实凭证。

#[path = "../src/test_support.rs"]
mod test_support;

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::{Duration, Instant};

use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};

use test_support::{FakeConfig, FakeSshd};

const BIN: &str = env!("CARGO_BIN_EXE_aster-ssh");
const HOST_ID: &str = "6F1C0A4E-8C1B-4B7E-9E55-3C4B1D2A9F10";

/// 一个运行中的 broker 进程。
struct BrokerProcess {
    child: Child,
    stdin: Option<ChildStdin>,
    socket: PathBuf,
    /// ready 之后 broker 写到 stdout 的全部行。
    lines: std::sync::Arc<std::sync::Mutex<Vec<String>>>,
    _dir: tempfile::TempDir,
}

impl BrokerProcess {
    /// 启动 broker，读到 ready 后同步一台指向 `port` 的主机。
    async fn start(port: u16) -> BrokerProcess {
        Self::start_with(json!({"host":"127.0.0.1","port":port,"user":"tester","verifyHostKeys":false,"keepaliveInterval":0})).await
    }

    /// 启动 broker，读到 ready 后以 HOST_ID 同步给定规格。
    async fn start_with(spec: Value) -> BrokerProcess {
        let dir = tempfile::tempdir().unwrap();
        let socket = dir.path().join("b.sock");
        let mut child = Command::new(BIN)
            .args(["broker", "--socket"])
            .arg(&socket)
            .env("HOME", dir.path())
            .env("ASTER_SSH_HOME", dir.path())
            .env_remove("SSH_AUTH_SOCK")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .kill_on_drop(true)
            .spawn()
            .expect("spawn broker");
        let mut lines = BufReader::new(child.stdout.take().unwrap()).lines();
        let ready: Value = serde_json::from_str(
            &tokio::time::timeout(Duration::from_secs(5), lines.next_line())
                .await
                .unwrap()
                .unwrap()
                .unwrap(),
        )
        .unwrap();
        assert_eq!(ready["type"], "ready");
        assert_eq!(ready["socket"], socket.to_string_lossy().as_ref());
        // 持续读走其余行（免得 broker 的 stdout 被写满），留给测试检查。
        let collected = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink = collected.clone();
        tokio::spawn(async move {
            while let Ok(Some(line)) = lines.next_line().await {
                sink.lock().unwrap().push(line);
            }
        });
        let mut stdin = child.stdin.take().unwrap();
        let sync = json!({"type":"profiles.sync","profiles":{HOST_ID: spec}});
        stdin
            .write_all(format!("{sync}\n").as_bytes())
            .await
            .unwrap();
        stdin.flush().await.unwrap();
        BrokerProcess {
            child,
            stdin: Some(stdin),
            socket,
            lines: collected,
            _dir: dir,
        }
    }

    /// 启动一个 client 进程。
    fn client(&self, host_id: &str, command: &str) -> Command {
        let mut cmd = Command::new(BIN);
        cmd.args(["client", "--broker"])
            .arg(&self.socket)
            .args(["--host-id", host_id, "--no-prompt", "--", command])
            .env_remove("SSH_AUTH_SOCK")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true);
        cmd
    }
}

/// 等到条件成立或超时。
async fn eventually(limit: Duration, mut check: impl FnMut() -> bool) -> bool {
    let deadline = Instant::now() + limit;
    while !check() {
        if Instant::now() > deadline {
            return false;
        }
        tokio::time::sleep(Duration::from_millis(5)).await;
    }
    true
}

#[tokio::test]
async fn killed_client_process_closes_the_remote_channel_within_two_seconds() {
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        ..Default::default()
    })
    .await;
    let broker = BrokerProcess::start(server.port).await;
    let mut client = broker.client(HOST_ID, "hang").spawn().unwrap();
    assert!(
        eventually(Duration::from_secs(10), || server
            .stats
            .execs
            .lock()
            .unwrap()
            .iter()
            .any(|c| c == "hang"))
        .await,
        "remote command started"
    );
    // 等 OPENED 到达 client 之后再杀，确保杀的是转发阶段。
    tokio::time::sleep(Duration::from_millis(100)).await;
    let killed = Instant::now();
    client.start_kill().unwrap();
    assert!(
        server.wait_closed(1, Duration::from_secs(2)).await,
        "channel closed within 2s of SIGKILL"
    );
    assert!(killed.elapsed() < Duration::from_secs(2));
    let _ = client.wait().await;
}

#[tokio::test]
async fn exit_status_and_structured_error_line_reach_the_caller() {
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        ..Default::default()
    })
    .await;
    let broker = BrokerProcess::start(server.port).await;

    let out = tokio::time::timeout(
        Duration::from_secs(10),
        broker.client(HOST_ID, "exit 7").output(),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(out.status.code(), Some(7));
    assert_eq!(out.stdout, b"bye\n");

    let out = tokio::time::timeout(
        Duration::from_secs(10),
        broker.client(HOST_ID, "signal TERM").output(),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(out.status.code(), Some(128 + 15));

    let out = tokio::time::timeout(
        Duration::from_secs(10),
        broker
            .client("00000000-0000-0000-0000-000000000000", "exit 0")
            .output(),
    )
    .await
    .unwrap()
    .unwrap();
    assert_eq!(out.status.code(), Some(255));
    let stderr = String::from_utf8_lossy(&out.stderr);
    let last = stderr.lines().last().unwrap_or_default();
    let json = last
        .strip_prefix("aster-ssh-error ")
        .unwrap_or_else(|| panic!("last stderr line: {stderr}"));
    let err: Value = serde_json::from_str(json).unwrap();
    assert_eq!(err["kind"], "transportFailure");
}

#[tokio::test]
async fn client_without_a_broker_reports_a_transport_failure() {
    let out = Command::new(BIN)
        .args([
            "client",
            "--broker",
            "/nonexistent/aster.sock",
            "--target",
            "me@127.0.0.1:1",
            "--no-prompt",
        ])
        .stdin(Stdio::null())
        .output()
        .await
        .unwrap();
    assert_eq!(out.status.code(), Some(255));
    let stderr = String::from_utf8_lossy(&out.stderr);
    assert!(
        stderr
            .lines()
            .last()
            .unwrap()
            .starts_with(r#"aster-ssh-error {"kind":"transportFailure""#),
        "{stderr}"
    );
}

#[tokio::test]
async fn broker_exits_and_removes_its_socket_on_stdin_eof() {
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        ..Default::default()
    })
    .await;
    let mut broker = BrokerProcess::start(server.port).await;
    use std::os::unix::fs::PermissionsExt as _;
    assert_eq!(
        std::fs::metadata(&broker.socket)
            .unwrap()
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
    // 先建立一条连接，退出时应一并断开。
    let out = broker.client(HOST_ID, "exit 0").output().await.unwrap();
    assert_eq!(out.status.code(), Some(0));
    drop(broker.stdin.take());
    let status = tokio::time::timeout(Duration::from_secs(5), broker.child.wait())
        .await
        .expect("broker exits")
        .unwrap();
    assert_eq!(status.code(), Some(0));
    assert!(!Path::new(&broker.socket).exists());
}

/// ProxyCommand 子进程不能继承 broker 的 stdout（控制通道）：它往 stderr 写的东西只能进日志，
/// broker 的 stdout 上只能出现 JSON 行。
#[tokio::test]
async fn proxy_command_output_never_reaches_the_control_channel() {
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        ..Default::default()
    })
    .await;
    let broker = BrokerProcess::start_with(json!({
        "host":"127.0.0.1","port":server.port,"user":"tester","verifyHostKeys":false,
        "keepaliveInterval":0,
        "proxyCommand":"sh -c 'echo proxy-noise; echo proxy-noise >&2; exec nc %h %p'"
    }))
    .await;
    let out = tokio::time::timeout(
        Duration::from_secs(10),
        broker.client(HOST_ID, "exit 3").output(),
    )
    .await
    .unwrap()
    .unwrap();
    // 第一条 echo 写进了传输流，SSH 握手会失败；关键是它不能出现在控制通道上。
    let _ = out.status;
    // 等拨号结果（connected 或 failed）的 link.state 出现，确认子进程已经跑过。
    assert!(
        eventually(Duration::from_secs(5), || broker
            .lines
            .lock()
            .unwrap()
            .iter()
            .any(|l| l.contains("\"connected\"") || l.contains("\"failed\"")))
        .await,
        "link.state result expected"
    );
    let lines = broker.lines.lock().unwrap().clone();
    for line in &lines {
        assert!(
            !line.contains("proxy-noise"),
            "control channel polluted: {line}"
        );
        serde_json::from_str::<Value>(line).unwrap_or_else(|_| panic!("not JSON: {line}"));
    }
}
