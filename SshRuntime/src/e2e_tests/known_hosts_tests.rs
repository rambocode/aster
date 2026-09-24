// 端到端：多个 known_hosts 文件（UserKnownHostsFile）与 IdentitiesOnly。

use std::sync::atomic::Ordering;

use super::*;
use crate::known_hosts::{self, HostKeyStatus};
use crate::protocol::AuthMode;
use crate::test_support::{key_from_seed, FakeConfig, FakeSshd};

/// 打开主机密钥校验、使用给定 known_hosts 列表的规格。
fn verifying(port: u16, files: &[&Path]) -> ResolvedSpec {
    let mut s = spec(port);
    s.verify_host_keys = true;
    s.known_hosts_files = files.iter().map(|p| path_str(p)).collect();
    s
}

#[tokio::test]
async fn a_match_in_the_second_known_hosts_file_is_enough() {
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        host_key_seed: 61,
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    let first = h.dir.path().join("kh-first");
    let second = h.dir.path().join("orb").join("known_hosts");
    // 第一个文件里是别的主机，第二个文件里才有它。
    known_hosts::append(&first, "other.example", 22, key_from_seed(1).public_key()).unwrap();
    known_hosts::append(&second, "127.0.0.1", server.port, &server.host_key).unwrap();
    h.sync(&[("h", &verifying(server.port, &[&first, &second]))])
        .await;
    let run = h.run(open_host("h", Some("exit 0"), false), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
    assert!(h.events_of("hostkey.confirm").is_empty());
    // 默认的 ~/.ssh/known_hosts 不参与，也不会被创建。
    assert!(!h.known_hosts().exists());
}

#[tokio::test]
async fn a_stale_default_file_is_not_consulted_when_files_are_listed() {
    // 真机上的问题：~/.ssh/known_hosts 里有一条过期记录，而配置指向另一个文件。
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        host_key_seed: 62,
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    known_hosts::append(
        &h.known_hosts(),
        "127.0.0.1",
        server.port,
        key_from_seed(97).public_key(),
    )
    .unwrap();
    let own = h.dir.path().join("own_known_hosts");
    known_hosts::append(&own, "127.0.0.1", server.port, &server.host_key).unwrap();
    h.sync(&[("h", &verifying(server.port, &[&own]))]).await;
    let run = h.run(open_host("h", Some("exit 0"), false), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
}

#[tokio::test]
async fn an_accepted_key_is_written_to_the_first_file_only() {
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        host_key_seed: 63,
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    let first = h.dir.path().join("a").join("known_hosts");
    let second = h.dir.path().join("b_known_hosts");
    std::fs::write(&second, "").unwrap();
    h.sync(&[("h", &verifying(server.port, &[&first, &second]))])
        .await;
    h.script.lock().unwrap().host_keys.push_back(true);
    let run = h.run(open_host("h", Some("exit 0"), true), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
    assert_eq!(h.events_of("hostkey.confirm").len(), 1);
    assert_eq!(
        known_hosts::check_file(&first, "127.0.0.1", server.port, &server.host_key),
        HostKeyStatus::Known
    );
    assert_eq!(std::fs::read_to_string(&second).unwrap(), "");
}

#[tokio::test]
async fn known_hosts_none_accepts_for_the_connection_without_writing() {
    let server = FakeSshd::start(FakeConfig {
        accept_none: true,
        host_key_seed: 64,
        ..Default::default()
    })
    .await;
    let h = Harness::new().await;
    let mut s = spec(server.port);
    s.verify_host_keys = true;
    s.known_hosts_files = vec!["none".into()];
    h.sync(&[("h", &s)]).await;
    // 非交互：没有记录就是未知主机。
    let run = h.run(open_host("h", Some("exit 0"), false), vec![]).await;
    assert_eq!(failure_kind(&run.outcome), "hostKeyUnknown");
    // 交互接受：本次连接可用，但哪里都不写；下次新连接还会再问。
    h.script.lock().unwrap().host_keys.extend([true, true]);
    let run = h.run(open_host("h", Some("exit 0"), true), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
    assert!(!h.known_hosts().exists());
    h.broker
        .pool()
        .disconnect(&format!("tester@127.0.0.1:{}", server.port))
        .await;
    let run = h.run(open_host("h", Some("exit 0"), true), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
    assert_eq!(h.events_of("hostkey.confirm").len(), 2);
}

#[tokio::test]
async fn identities_only_never_offers_other_agent_keys() {
    let other = key_from_seed(71);
    let named = key_from_seed(72);
    let server = FakeSshd::start(FakeConfig {
        authorized_keys: vec![other.public_key().clone()],
        ..Default::default()
    })
    .await;
    let h = Harness::with_agent(&[other.clone(), named.clone()]).await;
    let path = h.write("id_named", &openssh_key(72, None));
    let mut s = spec(server.port);
    s.identity_files = vec![path_str(&path)];
    s.identities_only = true;
    h.sync(&[("only", &s)]).await;
    let run = h
        .run(open_host("only", Some("exit 0"), false), vec![])
        .await;
    assert_eq!(failure_kind(&run.outcome), "authenticationRequired");
    let offered = server.stats.offered_keys.lock().unwrap().clone();
    assert!(
        !offered.contains(other.public_key()),
        "agent's other key must not be offered"
    );
    assert!(offered.contains(named.public_key()));

    // 对照：不开 IdentitiesOnly 时 agent 里的另一把钥匙能登录。
    let mut loose = s.clone();
    loose.identities_only = false;
    loose.user = "loose".into();
    h.sync(&[("loose", &loose)]).await;
    let run = h
        .run(open_host("loose", Some("exit 0"), false), vec![])
        .await;
    assert_eq!(exit_status(&run.outcome), 0);
}

#[tokio::test]
async fn identities_only_still_lets_the_agent_sign_for_the_named_key() {
    let named = key_from_seed(73);
    let server = FakeSshd::start(FakeConfig {
        authorized_keys: vec![named.public_key().clone()],
        ..Default::default()
    })
    .await;
    let h = Harness::with_agent(&[key_from_seed(74), named.clone()]).await;
    // 私钥加密且没给 passphrase：只有 agent 能签，靠旁边的 .pub 认出是同一把。
    let path = h.write("id_locked", &openssh_key(73, Some("unused-pass")));
    h.write("id_locked.pub", &named.public_key().to_openssh().unwrap());
    let mut s = spec(server.port);
    s.auth = AuthMode::Auto;
    s.identity_files = vec![path_str(&path)];
    s.identities_only = true;
    h.sync(&[("h", &s)]).await;
    let run = h.run(open_host("h", Some("exit 0"), false), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
    assert!(
        h.events_of("auth.request").is_empty(),
        "no passphrase needed"
    );
    let offered = server.stats.offered_keys.lock().unwrap().clone();
    assert!(!offered.contains(key_from_seed(74).public_key()));
    assert_eq!(server.stats.connections.load(Ordering::SeqCst), 1);
}
