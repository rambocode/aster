// protocol.rs 的测试：PROTOCOL.md 样例 JSON 的 round-trip 与帧编解码。

use super::*;
use serde_json::{json, Value};

/// 解析一行 broker 事件再序列化，结果与原文语义相同。
fn round_trip_event(sample: Value) {
    let event: BrokerEvent = serde_json::from_value(sample.clone()).expect("decode sample");
    let back = serde_json::to_value(&event).expect("encode");
    assert_eq!(back, sample, "round-trip of {sample}");
}

#[test]
fn broker_event_samples_round_trip() {
    round_trip_event(json!({"type":"ready","socket":"/tmp/broker.sock","version":"0.1.0"}));
    round_trip_event(json!({
        "type":"auth.request","id":"a1","endpoint":"deploy@10.0.0.5:22","kind":"password",
        "hostID":"6F1C0A4E-8C1B-4B7E-9E55-3C4B1D2A9F10","keyFile":null,"keyDigest":null,
        "name":"","instruction":"","prompts":[{"text":"Password:","echo":false}],
        "attempt":1,"interactive":true
    }));
    round_trip_event(json!({
        "type":"auth.request","id":"a2","endpoint":"deploy@10.0.0.5:22","kind":"passphrase",
        "hostID":null,"keyFile":"/k/id_ed25519","keyDigest":"ab12",
        "name":"","instruction":"","prompts":[],"attempt":2,"interactive":false
    }));
    round_trip_event(json!({"type":"auth.result","id":"a1","accepted":true}));
    round_trip_event(json!({
        "type":"hostkey.confirm","id":"h1","endpoint":"10.0.0.5:22","algorithm":"ssh-ed25519",
        "fingerprint":"SHA256:abc","status":"unknown","interactive":true
    }));
    round_trip_event(json!({
        "type":"link.state","endpoint":"deploy@10.0.0.5:22","hostID":null,"target":"orb",
        "state":"failed","attempt":2,"errorKind":"hostUnreachable","detail":"connection refused"
    }));
    round_trip_event(json!({
        "type":"link.state","endpoint":"deploy@10.0.0.5:22","hostID":"U","target":null,
        "state":"connected"
    }));
    round_trip_event(json!({"type":"log","level":"info","message":"hello"}));
}

#[test]
fn app_command_samples_decode() {
    let sync: AppCommand = serde_json::from_value(json!({
        "type":"profiles.sync",
        "profiles":{"U":{"host":"10.0.0.5","port":22,"user":"deploy"}}
    }))
    .unwrap();
    let AppCommand::ProfilesSync { profiles } = sync else {
        panic!("profiles.sync")
    };
    let spec: ResolvedSpec = serde_json::from_value(profiles["U"].clone()).unwrap();
    assert_eq!(spec, ResolvedSpec::basic("10.0.0.5", 22, "deploy"));

    let answer: AppCommand =
        serde_json::from_str(r#"{"type":"auth.answer","id":"a1","secret":null,"responses":null}"#)
            .unwrap();
    assert!(matches!(
        answer,
        AppCommand::AuthAnswer { ref id, secret: None, responses: None } if id == "a1"
    ));
    let answer: AppCommand = serde_json::from_str(
        r#"{"type":"auth.answer","id":"a2","secret":"s3cret","responses":["x","y"]}"#,
    )
    .unwrap();
    assert!(
        !format!("{answer:?}").contains("s3cret"),
        "Debug 不能泄露秘密"
    );
    let AppCommand::AuthAnswer {
        secret, responses, ..
    } = answer
    else {
        panic!("auth.answer")
    };
    assert_eq!(secret.as_deref(), Some("s3cret"));
    assert_eq!(responses, Some(vec!["x".to_string(), "y".to_string()]));

    for (text, want) in [
        (
            r#"{"type":"hostkey.answer","id":"h1","accept":true}"#,
            "hostkey.answer",
        ),
        (
            r#"{"type":"disconnect","endpoint":"deploy@10.0.0.5:22"}"#,
            "disconnect",
        ),
        (r#"{"type":"shutdown"}"#, "shutdown"),
        (r#"{"type":"future.thing","x":1}"#, "unknown"),
    ] {
        let cmd: AppCommand = serde_json::from_str(text).unwrap();
        assert_eq!(cmd.to_string(), want);
        // 已知类型再编码后仍能解回同一个值。
        if want != "unknown" {
            let back: AppCommand =
                serde_json::from_value(serde_json::to_value(&cmd).unwrap()).unwrap();
            assert!(back == cmd);
        }
    }
}

#[test]
fn resolved_spec_sample_round_trips() {
    let sample = json!({
        "host":"10.0.0.5","port":22,"user":"deploy",
        "auth":"auto",
        "identityFiles":["/Users/me/.ssh/id_ed25519"],
        "identitiesOnly":true,
        "knownHostsFiles":["/Users/me/.orbstack/ssh/known_hosts","/Users/me/.ssh/known_hosts"],
        "agentForward":false,
        "proxyCommand":null,
        "socksProxy":null,"httpProxy":null,
        "jump":{"host":"bastion","port":2222,"user":"ops","auth":"publicKey","identityFiles":[],
                "identitiesOnly":false,"knownHostsFiles":[],
                "agentForward":false,"proxyCommand":null,"socksProxy":null,"httpProxy":null,
                "jump":null,"forwards":[],"keepaliveInterval":15,"keepaliveCountMax":3,
                "connectTimeout":10,"verifyHostKeys":true},
        "forwards":[{"kind":"local","bind":{"host":"127.0.0.1","port":8080},
                     "target":{"host":"localhost","port":80},"description":""}],
        "keepaliveInterval":15,"keepaliveCountMax":3,"connectTimeout":10,
        "verifyHostKeys":true
    });
    let spec: ResolvedSpec = serde_json::from_value(sample.clone()).unwrap();
    assert_eq!(spec.jump.as_ref().unwrap().auth, AuthMode::PublicKey);
    assert_eq!(spec.jump_depth(), 1);
    assert!(spec.identities_only);
    assert_eq!(spec.known_hosts_files.len(), 2);
    assert_eq!(serde_json::to_value(&spec).unwrap(), sample);
    assert_eq!(
        spec.connection_key(),
        "deploy@10.0.0.5:22 via ops@bastion:2222"
    );
}

#[test]
fn endpoints_bracket_ipv6_like_swift() {
    let spec = ResolvedSpec::basic("::1", 2222, "me");
    assert_eq!(spec.credential_endpoint(), "me@[::1]:2222");
    assert_eq!(spec.host_endpoint(), "[::1]:2222");
}

#[test]
fn failure_kinds_match_swift_raw_values() {
    let all = [
        (
            FailureKind::AuthenticationRequired,
            "authenticationRequired",
        ),
        (FailureKind::HostKeyUnknown, "hostKeyUnknown"),
        (FailureKind::HostKeyChanged, "hostKeyChanged"),
        (FailureKind::HostUnreachable, "hostUnreachable"),
        (FailureKind::Timeout, "timeout"),
        (FailureKind::RemoteCommandMissing, "remoteCommandMissing"),
        (FailureKind::Cancelled, "cancelled"),
        (FailureKind::TransportFailure, "transportFailure"),
    ];
    for (kind, raw) in all {
        assert_eq!(
            serde_json::to_value(kind).unwrap(),
            Value::String(raw.into())
        );
    }
    let err = SshFailure::new(
        FailureKind::AuthenticationRequired,
        "publickey,password rejected",
    );
    assert_eq!(
        serde_json::to_string(&err).unwrap(),
        r#"{"kind":"authenticationRequired","detail":"publickey,password rejected"}"#
    );
}

#[test]
fn open_request_matches_protocol_shape() {
    let sample = json!({"hostID":"U","tty":true,"cols":120,"rows":40,"term":"xterm-256color",
                        "command":"uname -a","interactive":false,"connectTimeout":5});
    let open: OpenRequest = serde_json::from_value(sample.clone()).unwrap();
    assert_eq!(open.host_id.as_deref(), Some("U"));
    assert_eq!(open.connect_timeout, Some(5));
    assert_eq!(serde_json::to_value(&open).unwrap(), sample);
    let exit: ExitReport = serde_json::from_str(r#"{"status":3}"#).unwrap();
    assert_eq!(exit.status, Some(3));
    assert_eq!(exit.signal, None);
}

#[tokio::test]
async fn frames_round_trip_and_eof_is_clean() {
    let (mut a, mut b) = tokio::io::duplex(1024);
    write_frame(&mut a, &Frame::new(frame::STDIN, b"hello".to_vec()))
        .await
        .unwrap();
    write_frame(&mut a, &Frame::new(frame::STDIN_EOF, Vec::new()))
        .await
        .unwrap();
    drop(a);
    let f = read_frame(&mut b).await.unwrap().unwrap();
    assert_eq!(
        (f.kind, f.payload.as_slice()),
        (frame::STDIN, &b"hello"[..])
    );
    let f = read_frame(&mut b).await.unwrap().unwrap();
    assert_eq!(f.kind, frame::STDIN_EOF);
    assert!(read_frame(&mut b).await.unwrap().is_none());
}

#[tokio::test]
async fn oversized_frame_is_rejected() {
    let (mut a, mut b) = tokio::io::duplex(64);
    use tokio::io::AsyncWriteExt;
    a.write_all(&[frame::STDIN, 0xff, 0xff, 0xff, 0xff])
        .await
        .unwrap();
    assert!(read_frame(&mut b).await.is_err());
}

#[test]
fn resolved_spec_identity_agent_is_optional_and_per_hop() {
    // 旧版 App 不发 identityAgent：解码成 None，编码时也不多出这个键。
    let plain: ResolvedSpec =
        serde_json::from_value(json!({"host":"h","port":22,"user":"u"})).unwrap();
    assert_eq!(plain.identity_agent, None);
    assert!(serde_json::to_value(&plain)
        .unwrap()
        .get("identityAgent")
        .is_none());
    let spec: ResolvedSpec = serde_json::from_value(json!({
        "host":"h","port":22,"user":"u","identityAgent":"~/agent.sock",
        "jump":{"host":"j","port":22,"user":"u","identityAgent":"none"}
    }))
    .unwrap();
    assert_eq!(spec.identity_agent.as_deref(), Some("~/agent.sock"));
    assert_eq!(
        spec.jump.as_ref().unwrap().identity_agent.as_deref(),
        Some("none")
    );
    let back = serde_json::to_value(&spec).unwrap();
    assert_eq!(back["identityAgent"], "~/agent.sock");
    assert_eq!(back["jump"]["identityAgent"], "none");
}
