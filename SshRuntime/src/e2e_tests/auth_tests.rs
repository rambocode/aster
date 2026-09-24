// 端到端：认证、主机密钥、连接共享与结构化错误。

use std::sync::atomic::Ordering;
use std::time::Duration;

use super::*;
use crate::known_hosts;
use crate::protocol::AuthMode;
use crate::test_support::{key_from_seed, FakeConfig, FakeSshd};

#[tokio::test]
async fn password_is_retried_after_a_rejection_and_results_are_reported() {
    let server = FakeSshd::start(FakeConfig {
        passwords: vec!["right-secret-7Q".into()],
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    let mut s = spec(server.port);
    s.auth = AuthMode::Password;
    h.sync(&[("host-a", &s)]).await;
    h.script.lock().unwrap().passwords.extend([
        Some("wrong-secret-9Z".to_string()),
        Some("right-secret-7Q".to_string()),
    ]);

    let run = h
        .run(open_host("HOST-A", Some("exit 3"), true), vec![])
        .await;
    assert_eq!(exit_status(&run.outcome), 3);
    assert_eq!(run.stdout, "bye\n");
    assert_eq!(server.stats.password_attempts.load(Ordering::SeqCst), 2);

    let requests = h.events_of("auth.request");
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0]["kind"], "password");
    assert_eq!(
        requests[0]["endpoint"],
        format!("tester@127.0.0.1:{}", server.port)
    );
    assert_eq!(requests[0]["hostID"], "HOST-A");
    assert_eq!(
        (
            requests[0]["attempt"].as_u64(),
            requests[1]["attempt"].as_u64()
        ),
        (Some(1), Some(2))
    );
    let results: Vec<bool> = h
        .events_of("auth.result")
        .iter()
        .map(|e| e["accepted"].as_bool().unwrap())
        .collect();
    assert_eq!(results, vec![false, true]);
    assert_logs_free_of(&["right-secret-7Q", "wrong-secret-9Z"]);
}

#[tokio::test]
async fn cancelling_the_password_prompt_cancels_the_whole_attempt() {
    let server = FakeSshd::start(FakeConfig {
        passwords: vec!["pw".into()],
        kbd_answer: Some("1".into()),
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    h.sync(&[("h", &spec(server.port))]).await;
    let run = h.run(open_host("h", Some("exit 0"), true), vec![]).await;
    assert_eq!(failure_kind(&run.outcome), "cancelled");
    // 取消口令之后不能再换键盘交互把同一个问题问一遍。
    assert!(h
        .events_of("auth.request")
        .iter()
        .all(|e| e["kind"] == "password"));
}

#[tokio::test]
async fn non_interactive_without_credentials_fails_with_authentication_required() {
    let server = FakeSshd::start(FakeConfig {
        passwords: vec!["pw".into()],
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    h.sync(&[("h", &spec(server.port))]).await;
    let run = h.run(open_host("h", Some("exit 0"), false), vec![]).await;
    assert_eq!(failure_kind(&run.outcome), "authenticationRequired");
    let requests = h.events_of("auth.request");
    assert!(!requests.is_empty());
    assert!(requests.iter().all(|e| e["interactive"] == false));
    let Outcome::Failed(f) = &run.outcome else {
        unreachable!()
    };
    let line = client::error_line(f);
    assert!(
        line.starts_with("aster-ssh-error {\"kind\":\"authenticationRequired\""),
        "{line}"
    );
    assert_eq!(client::exit_code(&run.outcome), 255);
}

#[tokio::test]
async fn public_key_file_authenticates() {
    let key = key_from_seed(21);
    let server = FakeSshd::start(FakeConfig {
        authorized_keys: vec![key.public_key().clone()],
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    let path = h.write("id_test", &openssh_key(21, None));
    let mut s = spec(server.port);
    s.auth = AuthMode::PublicKey;
    s.identity_files = vec![path_str(&path)];
    h.sync(&[("h", &s)]).await;
    let run = h.run(open_host("h", Some("exit 0"), false), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
    assert!(h.events_of("auth.request").is_empty());
}

#[tokio::test]
async fn encrypted_key_asks_for_the_passphrase_with_path_and_digest() {
    let key = key_from_seed(22);
    let server = FakeSshd::start(FakeConfig {
        authorized_keys: vec![key.public_key().clone()],
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    let text = openssh_key(22, Some("pp-secret-4K"));
    let path = h.write("id_enc", &text);
    let mut s = spec(server.port);
    s.identity_files = vec![path_str(&path)];
    h.sync(&[("h", &s)]).await;
    h.script.lock().unwrap().passphrases.extend([
        Some("nope-secret-1X".to_string()),
        Some("pp-secret-4K".to_string()),
    ]);

    let run = h.run(open_host("h", Some("exit 0"), true), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
    let requests = h.events_of("auth.request");
    assert_eq!(requests.len(), 2);
    assert_eq!(requests[0]["kind"], "passphrase");
    assert_eq!(requests[0]["keyFile"], path_str(&path));
    assert_eq!(
        requests[0]["keyDigest"],
        crate::auth::key_digest(text.as_bytes())
    );
    let results: Vec<bool> = h
        .events_of("auth.result")
        .iter()
        .map(|e| e["accepted"].as_bool().unwrap())
        .collect();
    assert_eq!(results, vec![false, true]);
    assert_logs_free_of(&["pp-secret-4K", "nope-secret-1X"]);
}

#[tokio::test]
async fn keyboard_interactive_prompts_are_forwarded() {
    let server = FakeSshd::start(FakeConfig {
        kbd_answer: Some("otp-secret-246".into()),
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    let mut s = spec(server.port);
    s.auth = AuthMode::KeyboardInteractive;
    h.sync(&[("h", &s)]).await;
    h.script
        .lock()
        .unwrap()
        .kbd
        .push_back(Some(vec!["otp-secret-246".into()]));
    let run = h.run(open_host("h", Some("exit 0"), true), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
    let requests = h.events_of("auth.request");
    assert_eq!(requests[0]["kind"], "keyboardInteractive");
    assert_eq!(requests[0]["prompts"][0]["text"], "Verification code: ");
    assert_eq!(requests[0]["instruction"], "enter the code");
    assert_logs_free_of(&["otp-secret-246"]);
}

#[tokio::test]
async fn concurrent_opens_share_one_connection_and_one_prompt() {
    let server = FakeSshd::start(FakeConfig {
        passwords: vec!["pw".into()],
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    h.sync(&[("h", &spec(server.port))]).await;
    h.script
        .lock()
        .unwrap()
        .passwords
        .push_back(Some("pw".into()));
    let (a, b, c) = tokio::join!(
        h.run(open_host("h", Some("exit 1"), true), vec![]),
        h.run(open_host("h", Some("exit 2"), true), vec![]),
        h.run(open_host("h", Some("exit 3"), true), vec![]),
    );
    assert_eq!(
        (
            exit_status(&a.outcome),
            exit_status(&b.outcome),
            exit_status(&c.outcome)
        ),
        (1, 2, 3)
    );
    assert_eq!(
        h.events_of("auth.request").len(),
        1,
        "one prompt for all three"
    );
    assert_eq!(server.stats.connections.load(Ordering::SeqCst), 1);
    let states: Vec<String> = h
        .events_of("link.state")
        .iter()
        .map(|e| e["state"].as_str().unwrap().to_string())
        .collect();
    assert_eq!(&states[..2], ["connecting", "connected"]);
}

/// 打开主机密钥校验的规格（accept_none 服务器，不涉及用户认证）。
async fn verifying(server: &FakeSshd, h: &Harness) {
    let mut s = spec(server.port);
    s.verify_host_keys = true;
    h.sync(&[("h", &s)]).await;
}

#[tokio::test]
async fn unknown_host_key_is_confirmed_then_recorded() {
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        host_key_seed: 31,
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    verifying(&server, &h).await;
    h.script.lock().unwrap().host_keys.push_back(true);
    let run = h.run(open_host("h", Some("exit 0"), true), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
    let confirms = h.events_of("hostkey.confirm");
    assert_eq!(confirms.len(), 1);
    assert_eq!(confirms[0]["status"], "unknown");
    assert_eq!(
        confirms[0]["endpoint"],
        format!("127.0.0.1:{}", server.port)
    );
    assert_eq!(
        confirms[0]["fingerprint"],
        known_hosts::fingerprint(&server.host_key)
    );
    assert_eq!(
        known_hosts::check_file(&h.known_hosts(), "127.0.0.1", server.port, &server.host_key),
        known_hosts::HostKeyStatus::Known
    );

    // 断开后重连：已记录的密钥直接匹配，不再询问。
    h.broker
        .pool()
        .disconnect(&format!("tester@127.0.0.1:{}", server.port))
        .await;
    let run = h.run(open_host("h", Some("exit 0"), false), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
    assert_eq!(h.events_of("hostkey.confirm").len(), 1);
}

#[tokio::test]
async fn unknown_host_key_fails_without_asking_when_not_interactive() {
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        host_key_seed: 32,
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    verifying(&server, &h).await;
    let run = h.run(open_host("h", Some("exit 0"), false), vec![]).await;
    assert_eq!(failure_kind(&run.outcome), "hostKeyUnknown");
    assert!(h.events_of("hostkey.confirm").is_empty());
    assert!(!h.known_hosts().exists());
}

#[tokio::test]
async fn changed_host_key_is_rejected_or_replaced() {
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        host_key_seed: 33,
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    verifying(&server, &h).await;
    let stale = key_from_seed(99).public_key().clone();
    known_hosts::append(&h.known_hosts(), "127.0.0.1", server.port, &stale).unwrap();

    // 用户拒绝：hostKeyChanged，文件不变。
    h.script.lock().unwrap().host_keys.push_back(false);
    let run = h.run(open_host("h", Some("exit 0"), true), vec![]).await;
    assert_eq!(failure_kind(&run.outcome), "hostKeyChanged");
    assert_eq!(h.events_of("hostkey.confirm")[0]["status"], "changed");

    // 非交互：直接失败。
    let run = h.run(open_host("h", Some("exit 0"), false), vec![]).await;
    assert_eq!(failure_kind(&run.outcome), "hostKeyChanged");

    // 用户接受：旧行被替换。
    h.script.lock().unwrap().host_keys.push_back(true);
    let run = h.run(open_host("h", Some("exit 0"), true), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
    let text = std::fs::read_to_string(h.known_hosts()).unwrap();
    assert_eq!(text.lines().count(), 1, "{text}");
    assert_eq!(
        known_hosts::check_file(&h.known_hosts(), "127.0.0.1", server.port, &server.host_key),
        known_hosts::HostKeyStatus::Known
    );
}

#[tokio::test]
async fn matching_host_key_connects_without_asking() {
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        host_key_seed: 34,
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    verifying(&server, &h).await;
    known_hosts::append(&h.known_hosts(), "127.0.0.1", server.port, &server.host_key).unwrap();
    let run = h.run(open_host("h", Some("exit 0"), false), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
    assert!(h.events_of("hostkey.confirm").is_empty());
}

#[tokio::test]
async fn unreachable_host_yields_a_structured_error() {
    let h = Harness::new().await;
    let mut s = spec(free_port());
    s.connect_timeout = 3;
    h.sync(&[("h", &s)]).await;
    let run = h.run(open_host("h", Some("exit 0"), false), vec![]).await;
    assert_eq!(failure_kind(&run.outcome), "hostUnreachable");
    let failed: Vec<Value> = h
        .events_of("link.state")
        .into_iter()
        .filter(|e| e["state"] == "failed")
        .collect();
    assert_eq!(failed[0]["errorKind"], "hostUnreachable");

    let run = h.run(open_host("missing", None, false), vec![]).await;
    assert_eq!(failure_kind(&run.outcome), "transportFailure");
}

#[tokio::test]
async fn disconnect_command_closes_the_link() {
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    h.sync(&[("h", &spec(server.port))]).await;
    assert_eq!(
        exit_status(
            &h.run(open_host("h", Some("exit 0"), false), vec![])
                .await
                .outcome
        ),
        0
    );
    assert_eq!(h.broker.pool().ready_count(), 1);
    let endpoint = format!("tester@127.0.0.1:{}", server.port);
    h.broker
        .handle_line(&json!({"type":"disconnect","endpoint":endpoint}).to_string())
        .await;
    assert_eq!(h.broker.pool().ready_count(), 0);
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    while !h
        .events_of("link.state")
        .iter()
        .any(|e| e["state"] == "closed")
    {
        assert!(
            std::time::Instant::now() < deadline,
            "closed state reported"
        );
        tokio::time::sleep(Duration::from_millis(10)).await;
    }
    // 断开后下一次 OPEN 重新拨号。
    assert_eq!(
        exit_status(
            &h.run(open_host("h", Some("exit 0"), false), vec![])
                .await
                .outcome
        ),
        0
    );
    assert_eq!(server.stats.connections.load(Ordering::SeqCst), 2);
    let reconnecting = h
        .events_of("link.state")
        .iter()
        .any(|e| e["state"] == "reconnecting");
    assert!(reconnecting);
}
