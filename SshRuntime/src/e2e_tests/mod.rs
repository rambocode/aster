//! 端到端测试：进程内 broker + 进程内 russh 服务器 + client 核心逻辑，全部走 127.0.0.1 与临时目录。
//!
//! 夹具 `Harness` 模拟 App：消费控制通道的每一行，并按脚本自动回答凭证与主机密钥请求。

mod auth_tests;
mod session_tests;

use std::collections::VecDeque;
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::task::{Context, Poll};
use std::time::Duration;

use serde_json::{json, Value};
use tokio::io::AsyncWrite;
use tokio::net::UnixStream;
use tokio::sync::mpsc;

use crate::broker::{Broker, Lookup};
use crate::client::{self, ClientIo, Outcome};
use crate::env::Paths;
use crate::protocol::{OpenRequest, ResizeRequest, ResolvedSpec};

/// 模拟 App 的作答脚本；队列空了就回答取消 / 拒绝。
#[derive(Default)]
pub struct Script {
    pub passwords: VecDeque<Option<String>>,
    pub passphrases: VecDeque<Option<String>>,
    pub kbd: VecDeque<Option<Vec<String>>>,
    pub host_keys: VecDeque<bool>,
}

/// 一套测试环境。
pub struct Harness {
    pub dir: tempfile::TempDir,
    pub broker: Arc<Broker>,
    pub socket: PathBuf,
    pub events: Arc<Mutex<Vec<Value>>>,
    pub script: Arc<Mutex<Script>>,
}

impl Harness {
    /// 不读 ssh_config 的环境。
    pub async fn new() -> Harness {
        Self::with_lookup(Arc::new(|_: &str| None)).await
    }

    /// 自定义 ssh_config 查询的环境。
    pub async fn with_lookup(lookup: Lookup) -> Harness {
        let dir = tempfile::tempdir().expect("tempdir");
        let paths = Paths {
            home: dir.path().to_path_buf(),
            known_hosts: dir.path().join(".ssh").join("known_hosts"),
            agent_sock: None,
            local_user: "tester".into(),
        };
        let (broker, mut rx) = Broker::new(paths, lookup);
        let socket = dir.path().join("broker.sock");
        let listener = crate::broker::bind_socket(&socket).expect("bind broker socket");
        tokio::spawn(broker.clone().serve(listener));
        let events = Arc::new(Mutex::new(Vec::new()));
        let script = Arc::new(Mutex::new(Script::default()));
        {
            let (broker, events, script) = (broker.clone(), events.clone(), script.clone());
            tokio::spawn(async move {
                while let Some(line) = rx.recv().await {
                    let event: Value = serde_json::from_str(&line).expect("control line is JSON");
                    events.lock().unwrap().push(event.clone());
                    if let Some(answer) = answer_for(&event, &script) {
                        broker.handle_line(&answer.to_string()).await;
                    }
                }
            });
        }
        Harness {
            dir,
            broker,
            socket,
            events,
            script,
        }
    }

    /// 以 hostID 同步一组规格。
    pub async fn sync(&self, profiles: &[(&str, &ResolvedSpec)]) {
        let map: serde_json::Map<String, Value> = profiles
            .iter()
            .map(|(id, s)| (id.to_string(), serde_json::to_value(s).unwrap()))
            .collect();
        self.broker
            .handle_line(&json!({"type":"profiles.sync","profiles":map}).to_string())
            .await;
    }

    /// 某类型的全部控制事件。
    pub fn events_of(&self, kind: &str) -> Vec<Value> {
        self.events
            .lock()
            .unwrap()
            .iter()
            .filter(|e| e["type"] == kind)
            .cloned()
            .collect()
    }

    /// known_hosts 路径。
    pub fn known_hosts(&self) -> PathBuf {
        self.dir.path().join(".ssh").join("known_hosts")
    }

    /// 在临时目录写一个文件。
    pub fn write(&self, name: &str, contents: &str) -> PathBuf {
        let path = self.dir.path().join(name);
        std::fs::write(&path, contents).unwrap();
        use std::os::unix::fs::PermissionsExt as _;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
        path
    }

    /// 跑一次 client：stdin 依次送入 `input` 后 EOF，返回结局与输出。
    pub async fn run(&self, open: OpenRequest, input: Vec<&[u8]>) -> Run {
        self.run_with(open, input, true, Vec::new()).await
    }

    /// 同 `run`，可选择不关 stdin、并在 OPENED 后发送窗口变化。
    pub async fn run_with(
        &self,
        open: OpenRequest,
        input: Vec<&[u8]>,
        close_stdin: bool,
        resizes: Vec<ResizeRequest>,
    ) -> Run {
        let stream = UnixStream::connect(&self.socket)
            .await
            .expect("connect broker");
        let (stdin_tx, stdin_rx) = mpsc::channel(16);
        for chunk in input {
            stdin_tx.send(Some(chunk.to_vec())).await.unwrap();
        }
        if close_stdin {
            stdin_tx.send(None).await.unwrap();
        }
        let (resize_tx, resize_rx) = mpsc::unbounded_channel();
        for r in resizes {
            resize_tx.send(r).unwrap();
        }
        let stdout = SharedBuf::default();
        let stderr = SharedBuf::default();
        let io = ClientIo {
            stdin: stdin_rx,
            resize: resize_rx,
            stdout: stdout.clone(),
            stderr: stderr.clone(),
            on_opened: Box::new(|| {}),
        };
        let outcome =
            tokio::time::timeout(Duration::from_secs(20), client::drive(stream, &open, io))
                .await
                .expect("client finished in time");
        drop((stdin_tx, resize_tx));
        Run {
            outcome,
            stdout: stdout.text(),
            stderr: stderr.text(),
        }
    }
}

/// 按脚本给出回答行。
fn answer_for(event: &Value, script: &Mutex<Script>) -> Option<Value> {
    let id = event["id"].clone();
    let mut script = script.lock().unwrap();
    match event["type"].as_str()? {
        "auth.request" => match event["kind"].as_str()? {
            "password" => Some(
                json!({"type":"auth.answer","id":id,"secret":script.passwords.pop_front().flatten(),"responses":null}),
            ),
            "passphrase" => Some(
                json!({"type":"auth.answer","id":id,"secret":script.passphrases.pop_front().flatten(),"responses":null}),
            ),
            _ => Some(
                json!({"type":"auth.answer","id":id,"secret":null,"responses":script.kbd.pop_front().flatten()}),
            ),
        },
        "hostkey.confirm" => Some(
            json!({"type":"hostkey.answer","id":id,"accept":script.host_keys.pop_front().unwrap_or(false)}),
        ),
        _ => None,
    }
}

/// 一次 client 运行的结果。
pub struct Run {
    pub outcome: Outcome,
    pub stdout: String,
    pub stderr: String,
}

/// 可共享的输出缓冲。
#[derive(Clone, Default)]
pub struct SharedBuf(Arc<Mutex<Vec<u8>>>);

impl SharedBuf {
    /// 内容转成文本。
    pub fn text(&self) -> String {
        String::from_utf8_lossy(&self.0.lock().unwrap()).into_owned()
    }
}

impl AsyncWrite for SharedBuf {
    /// 追加到缓冲。
    fn poll_write(
        self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Poll::Ready(Ok(buf.len()))
    }

    /// 无需 flush。
    fn poll_flush(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    /// 无需关闭。
    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

/// 指向测试服务器、不校验主机密钥的规格。
pub fn spec(port: u16) -> ResolvedSpec {
    let mut s = ResolvedSpec::basic("127.0.0.1", port, "tester");
    s.verify_host_keys = false;
    s.keepalive_interval = 0;
    s
}

/// 以 hostID 打开、执行 `command` 的 OPEN。
pub fn open_host(id: &str, command: Option<&str>, interactive: bool) -> OpenRequest {
    OpenRequest {
        host_id: Some(id.into()),
        target: None,
        tty: false,
        cols: 80,
        rows: 24,
        term: "xterm-256color".into(),
        command: command.map(String::from),
        interactive,
        connect_timeout: None,
    }
}

/// 结局应是正常退出，返回退出码。
pub fn exit_status(outcome: &Outcome) -> i32 {
    match outcome {
        Outcome::Exit(_) => client::exit_code(outcome),
        Outcome::Failed(f) => panic!("expected exit, got failure {f}"),
    }
}

/// 结局应是失败，返回失败分类（camelCase 字符串）。
pub fn failure_kind(outcome: &Outcome) -> String {
    match outcome {
        Outcome::Failed(f) => serde_json::to_value(f.kind)
            .unwrap()
            .as_str()
            .unwrap()
            .to_string(),
        Outcome::Exit(e) => panic!("expected failure, got exit {e:?}"),
    }
}

/// 一对 OpenSSH 格式的测试私钥文本（明文 / 用 `passphrase` 加密）。
pub fn openssh_key(seed: u8, passphrase: Option<&str>) -> String {
    use russh::keys::ssh_key::{Cipher, Kdf, LineEnding};
    let key = crate::test_support::key_from_seed(seed);
    let key = match passphrase {
        // bcrypt 轮数调低只为测试速度。
        Some(p) => key
            .encrypt_with(
                Cipher::Aes256Ctr,
                Kdf::Bcrypt {
                    salt: vec![9u8; 16],
                    rounds: 4,
                },
                0,
                p,
            )
            .unwrap(),
        None => key,
    };
    key.to_openssh(LineEnding::LF).unwrap().to_string()
}

/// 找一个当前空闲的本地端口（绑定后立即释放）。
pub fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

/// 本地 TCP 回显服务器，返回端口。
pub async fn echo_server() -> u16 {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    tokio::spawn(async move {
        while let Ok((mut s, _)) = listener.accept().await {
            tokio::spawn(async move {
                let (mut r, mut w) = s.split();
                let _ = tokio::io::copy(&mut r, &mut w).await;
            });
        }
    });
    port
}

/// 断言日志里没有出现任何一个秘密。
pub fn assert_logs_free_of(secrets: &[&str]) {
    for line in crate::logging::capture::lines() {
        for secret in secrets {
            assert!(
                !line.contains(secret),
                "secret leaked into log line: {line}"
            );
        }
    }
}

/// 把路径转成字符串。
pub fn path_str(p: &Path) -> String {
    p.to_string_lossy().into_owned()
}
