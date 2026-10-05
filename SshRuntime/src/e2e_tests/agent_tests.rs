//! identityAgent（OpenSSH IdentityAgent）：每一跳可以指定自己的 ssh-agent，盖过继承到的 `SSH_AUTH_SOCK`。

use std::sync::atomic::Ordering;

use super::*;
use crate::protocol::AuthMode;
use crate::test_support::{key_from_seed, FakeConfig, FakeSshd};

/// 只认 agent 的规格，用户名区分连接（同一 endpoint 会复用已认证的连接）。
fn agent_spec(port: u16, user: &str, identity_agent: Option<&str>) -> ResolvedSpec {
    let mut s = spec(port);
    s.auth = AuthMode::Agent;
    s.user = user.into();
    s.identity_agent = identity_agent.map(str::to_string);
    s
}

#[tokio::test]
async fn identity_agent_overrides_the_inherited_agent() {
    let inherited_key = key_from_seed(81);
    let configured_key = key_from_seed(82);
    let server = FakeSshd::start(FakeConfig {
        authorized_keys: vec![configured_key.public_key().clone()],
        ..Default::default()
    })
    .await;
    // 继承到的 agent（相当于 SSH_AUTH_SOCK）里只有服务器不认的钥匙；能登录的那把在另一个 agent 里。
    let h = Harness::with_agent(std::slice::from_ref(&inherited_key)).await;
    let alt = h.dir.path().join("alt");
    std::fs::create_dir(&alt).unwrap();
    start_agent(&alt, std::slice::from_ref(&configured_key)).await;

    // `~` 相对 broker 的主目录展开（测试里就是临时目录）。
    let by_path = agent_spec(server.port, "bypath", Some("~/alt/agent.sock"));
    let unset = agent_spec(server.port, "unset", None);
    let literal_env = agent_spec(server.port, "literal", Some("SSH_AUTH_SOCK"));
    let disabled = agent_spec(server.port, "disabled", Some("none"));
    h.sync(&[
        ("path", &by_path),
        ("unset", &unset),
        ("literal", &literal_env),
        ("none", &disabled),
    ])
    .await;

    let run = h
        .run(open_host("path", Some("exit 0"), false), vec![])
        .await;
    assert_eq!(exit_status(&run.outcome), 0);
    let offered = server.stats.offered_keys.lock().unwrap().clone();
    assert!(offered.contains(configured_key.public_key()));
    assert!(
        !offered.contains(inherited_key.public_key()),
        "the inherited agent must not be consulted once identityAgent names another socket"
    );

    // 没写与写 SSH_AUTH_SOCK 都落到继承的 agent，那里的钥匙被拒。
    for id in ["unset", "literal"] {
        let run = h.run(open_host(id, Some("exit 0"), false), vec![]).await;
        assert_eq!(failure_kind(&run.outcome), "authenticationRequired");
    }
    assert!(server
        .stats
        .offered_keys
        .lock()
        .unwrap()
        .contains(inherited_key.public_key()));

    // none：这一跳完全不碰 agent，一把钥匙都不会递出去。
    let before = server.stats.offered_keys.lock().unwrap().len();
    let run = h
        .run(open_host("none", Some("exit 0"), false), vec![])
        .await;
    assert_eq!(failure_kind(&run.outcome), "authenticationRequired");
    assert_eq!(server.stats.offered_keys.lock().unwrap().len(), before);
    assert!(server.stats.connections.load(Ordering::SeqCst) >= 4);
}

#[tokio::test]
async fn identity_agent_works_without_any_inherited_agent() {
    let key = key_from_seed(83);
    let server = FakeSshd::start(FakeConfig {
        authorized_keys: vec![key.public_key().clone()],
        ..Default::default()
    })
    .await;
    // broker 自己没有 SSH_AUTH_SOCK（从 Dock 启动的 App 常见），全靠配置里的 socket。
    let h = Harness::new().await;
    let sock = start_agent(h.dir.path(), std::slice::from_ref(&key)).await;
    let s = agent_spec(server.port, "tester", Some(&path_str(&sock)));
    h.sync(&[("h", &s)]).await;
    let run = h.run(open_host("h", Some("exit 0"), false), vec![]).await;
    assert_eq!(exit_status(&run.outcome), 0);
}
