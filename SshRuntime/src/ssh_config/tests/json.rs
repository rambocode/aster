//! JSON 形状（PROTOCOL.md §5）与命令行参数的测试。

use super::super::{parse_cli, CliCommand, ConfigListing};
use super::{home_with, hp, list};

// MARK: - JSON 与命令行

/// PROTOCOL.md §5 的样例（把省略号换成了具体值）。
const PROTOCOL_SAMPLE: &str = r#"{"hosts":[{"alias":"orb","hostName":"127.0.0.1","user":"root","port":32222,
    "identityFiles":["~/.ssh/id_ed25519"],"proxyJump":null,"proxyCommand":null,
    "forwards":[{"kind":"local","bind":{"host":"127.0.0.1","port":8080},
                 "target":{"host":"localhost","port":80},"description":""}],
    "keepaliveInterval":null,"keepaliveCountMax":null}],
 "ignored":[{"file":"~/.ssh/config","line":12,"option":"Match","reason":"unsupported"}]}"#;

#[test]
fn protocol_sample_deserializes() {
    let listing: ConfigListing = serde_json::from_str(PROTOCOL_SAMPLE).expect("sample");
    assert_eq!(listing.hosts[0].alias, "orb");
    assert_eq!(listing.hosts[0].port, Some(32222));
    assert_eq!(listing.hosts[0].forwards[0].target, hp("localhost", 80));
    assert_eq!(
        listing.hosts[0].forward_agent, None,
        "新增字段缺省可反序列化"
    );
    assert_eq!(listing.ignored[0].line, 12);
}

#[test]
fn list_json_matches_protocol_shape_and_round_trips() {
    let home = home_with(concat!(
        "Host orb\n",
        "  HostName 127.0.0.1\n",
        "  User root\n",
        "  Port 32222\n",
        "  IdentityFile ~/.ssh/id_ed25519\n",
        "  LocalForward 8080 localhost:80\n",
        "Match all\n",
    ));
    let listing = list(&home);
    let text = serde_json::to_string(&listing).unwrap();
    let value: serde_json::Value = serde_json::from_str(&text).unwrap();
    let sample: serde_json::Value = serde_json::from_str(PROTOCOL_SAMPLE).unwrap();

    // 样例里出现的每个键都要有，值也要一致（新增字段只多不少）
    let host = value["hosts"][0].as_object().unwrap();
    for (key, expected) in sample["hosts"][0].as_object().unwrap() {
        assert_eq!(host.get(key), Some(expected), "hosts[0].{key}");
    }
    let mut keys: Vec<&String> = value["ignored"][0].as_object().unwrap().keys().collect();
    keys.sort();
    assert_eq!(keys, vec!["file", "line", "option", "reason"]);
    assert_eq!(value["ignored"][0]["line"], 7);

    let back: ConfigListing = serde_json::from_str(&text).unwrap();
    assert_eq!(back, listing);
}

#[test]
fn cli_arguments() {
    let args = |list: &[&str]| list.iter().map(|s| s.to_string()).collect::<Vec<_>>();
    assert_eq!(parse_cli(&args(&["list", "--json"])), Ok(CliCommand::List));
    assert_eq!(
        parse_cli(&args(&["resolve", "prod", "--json"])),
        Ok(CliCommand::Resolve("prod".to_string()))
    );
    assert!(parse_cli(&args(&["list"])).is_err(), "缺 --json");
    assert!(
        parse_cli(&args(&["resolve", "--json"])).is_err(),
        "缺 alias"
    );
    assert!(parse_cli(&args(&["resolve", "a", "b", "--json"])).is_err());
    assert!(parse_cli(&args(&["list", "--yaml"])).is_err());
    assert!(parse_cli(&args(&[])).is_err());
}
