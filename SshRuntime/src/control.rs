//! App ↔ broker 控制通道（PROTOCOL §4）的 broker 侧。
//!
//! 出方向：每条事件序列化成一行 JSON，交给 stdout 写入任务。
//! 入方向：`auth.answer` / `hostkey.answer` 按 id 唤醒等待中的请求；其它命令由 broker 分发。
//! 秘密只以 `Zeroizing<String>` 存在于内存里，用完即清零，从不写日志。

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use tokio::sync::{mpsc, oneshot};
use zeroize::Zeroizing;

use crate::protocol::{AuthRequest, BrokerEvent, HostKeyConfirm};
use crate::{log_debug, log_warn};

/// 非交互请求等 App 作答的上限：App 只查钥匙串，不该超过这个时间。
const NON_INTERACTIVE_ANSWER_TIMEOUT: Duration = Duration::from_secs(30);

/// App 对凭证请求的回答。`secret` 与 `responses` 都为 None 表示取消。
pub struct AuthAnswer {
    pub secret: Option<Zeroizing<String>>,
    pub responses: Option<Vec<Zeroizing<String>>>,
}

impl AuthAnswer {
    /// 空回答（取消 / 超时 / 控制通道已关闭）。
    pub fn cancelled() -> Self {
        Self {
            secret: None,
            responses: None,
        }
    }

    /// 是否为取消（测试用）。
    #[cfg(test)]
    pub fn is_cancelled(&self) -> bool {
        self.secret.is_none() && self.responses.is_none()
    }
}

/// 等待中的一个请求的唤醒端。
enum Waiter {
    Auth(oneshot::Sender<AuthAnswer>),
    HostKey(oneshot::Sender<bool>),
}

/// 控制通道。broker 全局一个，所有连接共享。
pub struct Control {
    /// 出方向；`close_output` 之后为 None，写入任务读完剩余行后结束。
    out: Mutex<Option<mpsc::UnboundedSender<String>>>,
    pending: Mutex<HashMap<String, Waiter>>,
    next_id: AtomicU64,
}

impl Control {
    /// 新建控制通道，返回写出行的接收端（由 stdout 写入任务或测试消费）。
    pub fn new() -> (Self, mpsc::UnboundedReceiver<String>) {
        let (out, rx) = mpsc::unbounded_channel();
        (
            Self {
                out: Mutex::new(Some(out)),
                pending: Mutex::new(HashMap::new()),
                next_id: AtomicU64::new(1),
            },
            rx,
        )
    }

    /// 发一条事件。接收端已关闭（App 退出）时静默丢弃。
    pub fn emit(&self, event: &BrokerEvent) {
        match serde_json::to_string(event) {
            Ok(line) => {
                let out = self.out.lock().unwrap_or_else(|p| p.into_inner());
                if let Some(out) = out.as_ref() {
                    // 发送失败说明 stdout 写入任务已结束，broker 正在退出，没有可补救的动作。
                    let _ = out.send(line);
                }
            }
            Err(e) => log_warn!("encode control event failed: {e}"),
        }
    }

    /// 生成请求 id，形如 `a1` / `h2`。
    fn next_id(&self, prefix: &str) -> String {
        format!("{prefix}{}", self.next_id.fetch_add(1, Ordering::Relaxed))
    }

    /// 锁 pending 表；锁被毒化时照样取回数据（表里只有唤醒端，不存在不一致状态）。
    fn pending(&self) -> std::sync::MutexGuard<'_, HashMap<String, Waiter>> {
        self.pending.lock().unwrap_or_else(|p| p.into_inner())
    }

    /// 发 `auth.request` 并等待回答。`request.id` 由这里填写，返回 (id, 回答)。
    ///
    /// 非交互请求最多等 30 秒；交互请求等用户操作，不设上限（连接关闭时由调用方取消）。
    pub async fn ask_auth(&self, mut request: AuthRequest) -> (String, AuthAnswer) {
        let id = self.next_id("a");
        request.id = id.clone();
        let (tx, rx) = oneshot::channel();
        self.pending().insert(id.clone(), Waiter::Auth(tx));
        let interactive = request.interactive;
        self.emit(&BrokerEvent::AuthRequest(request));
        let answer = self.wait(&id, rx, interactive).await;
        (id, answer.unwrap_or_else(AuthAnswer::cancelled))
    }

    /// 发 `auth.result`。
    pub fn auth_result(&self, id: &str, accepted: bool) {
        self.emit(&BrokerEvent::AuthResult {
            id: id.to_string(),
            accepted,
        });
    }

    /// 发 `hostkey.confirm` 并等待用户决定。没有回答按拒绝处理。
    pub async fn confirm_host_key(&self, mut request: HostKeyConfirm) -> bool {
        let id = self.next_id("h");
        request.id = id.clone();
        let (tx, rx) = oneshot::channel();
        self.pending().insert(id.clone(), Waiter::HostKey(tx));
        let interactive = request.interactive;
        self.emit(&BrokerEvent::HostKeyConfirm(request));
        self.wait(&id, rx, interactive).await.unwrap_or(false)
    }

    /// 等一个 oneshot；超时或发送端被丢弃时返回 None，并清掉 pending 项。
    async fn wait<T>(&self, id: &str, rx: oneshot::Receiver<T>, interactive: bool) -> Option<T> {
        let result = if interactive {
            rx.await.ok()
        } else {
            match tokio::time::timeout(NON_INTERACTIVE_ANSWER_TIMEOUT, rx).await {
                Ok(r) => r.ok(),
                Err(_) => {
                    log_warn!("control request {id} timed out without an answer");
                    None
                }
            }
        };
        self.pending().remove(id);
        result
    }

    /// 投递 `auth.answer`。id 不存在（已超时、重复回答）时忽略。
    pub fn deliver_auth(&self, id: &str, answer: AuthAnswer) {
        match self.pending().remove(id) {
            Some(Waiter::Auth(tx)) => {
                // 等待方已放弃（超时）时发送失败，回答随 Zeroizing 被清零丢弃。
                let _ = tx.send(answer);
            }
            Some(other) => {
                log_warn!("auth.answer {id} does not match an auth request");
                self.pending().insert(id.to_string(), other);
            }
            None => log_debug!("auth.answer for unknown id {id}"),
        }
    }

    /// 投递 `hostkey.answer`。
    pub fn deliver_host_key(&self, id: &str, accept: bool) {
        match self.pending().remove(id) {
            Some(Waiter::HostKey(tx)) => {
                let _ = tx.send(accept);
            }
            Some(other) => {
                log_warn!("hostkey.answer {id} does not match a host key request");
                self.pending().insert(id.to_string(), other);
            }
            None => log_debug!("hostkey.answer for unknown id {id}"),
        }
    }

    /// App 断开：唤醒全部等待者，一律按取消处理。
    pub fn cancel_all(&self) {
        let drained: Vec<Waiter> = self.pending().drain().map(|(_, w)| w).collect();
        for waiter in drained {
            match waiter {
                Waiter::Auth(tx) => {
                    let _ = tx.send(AuthAnswer::cancelled());
                }
                Waiter::HostKey(tx) => {
                    let _ = tx.send(false);
                }
            }
        }
    }

    /// 关闭出方向：之后的事件被丢弃，写入任务写完已排队的行后退出。
    pub fn close_output(&self) {
        self.out.lock().unwrap_or_else(|p| p.into_inner()).take();
    }

    /// 发一条 `log` 事件（内容必须已脱敏）。
    pub fn log(&self, level: crate::logging::Level, message: impl Into<String>) {
        self.emit(&BrokerEvent::Log {
            level: level.as_str().to_string(),
            message: message.into(),
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::protocol::{AuthRequestKind, HostKeyStatusKind};

    /// 空白的口令请求。
    fn password_request(interactive: bool) -> AuthRequest {
        AuthRequest {
            id: String::new(),
            endpoint: "u@h:22".into(),
            kind: AuthRequestKind::Password,
            host_id: None,
            key_file: None,
            key_digest: None,
            name: String::new(),
            instruction: String::new(),
            prompts: vec![],
            attempt: 1,
            interactive,
        }
    }

    #[tokio::test]
    async fn an_answer_wakes_the_request_with_the_matching_id() {
        let (control, mut rx) = Control::new();
        let control = std::sync::Arc::new(control);
        let asker = {
            let control = control.clone();
            tokio::spawn(async move { control.ask_auth(password_request(true)).await })
        };
        let line = rx.recv().await.unwrap();
        let v: serde_json::Value = serde_json::from_str(&line).unwrap();
        assert_eq!(v["type"], "auth.request");
        let id = v["id"].as_str().unwrap().to_string();
        control.deliver_auth(
            &id,
            AuthAnswer {
                secret: Some(Zeroizing::new("pw".into())),
                responses: None,
            },
        );
        let (got_id, answer) = asker.await.unwrap();
        assert_eq!(got_id, id);
        assert_eq!(answer.secret.as_deref().map(String::as_str), Some("pw"));
    }

    #[tokio::test]
    async fn cancel_all_rejects_host_keys_and_cancels_auth() {
        let (control, _rx) = Control::new();
        let control = std::sync::Arc::new(control);
        let hk = {
            let control = control.clone();
            tokio::spawn(async move {
                control
                    .confirm_host_key(HostKeyConfirm {
                        id: String::new(),
                        endpoint: "h:22".into(),
                        algorithm: "ssh-ed25519".into(),
                        fingerprint: "SHA256:x".into(),
                        status: HostKeyStatusKind::Unknown,
                        interactive: true,
                    })
                    .await
            })
        };
        let auth = {
            let control = control.clone();
            tokio::spawn(async move { control.ask_auth(password_request(true)).await })
        };
        // 两个请求都登记后再取消。
        while control.pending().len() < 2 {
            tokio::task::yield_now().await;
        }
        control.cancel_all();
        assert!(!hk.await.unwrap());
        assert!(auth.await.unwrap().1.is_cancelled());
    }
}
