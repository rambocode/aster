//! `aster-ssh config` 命令行的端到端测试：用临时 HOME 跑真实二进制，检查输出和退出码。

use std::fs;
use std::process::{Command, Output};

/// 在指定 HOME 下运行 `aster-ssh config <args>`。
fn run(home: &std::path::Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_aster-ssh"))
        .arg("config")
        .args(args)
        .env("HOME", home)
        .output()
        .expect("run aster-ssh")
}

/// 造一个带 `~/.ssh/config` 的临时 HOME。
fn home_with(config: &str) -> tempfile::TempDir {
    let home = tempfile::tempdir().expect("tempdir");
    fs::create_dir_all(home.path().join(".ssh")).expect("mkdir");
    fs::write(home.path().join(".ssh/config"), config).expect("write");
    home
}

#[test]
fn list_prints_hosts_and_ignored() {
    let home = home_with("Host prod\n  HostName 10.0.0.5\nMatch all\nHost *.corp\n");
    let out = run(home.path(), &["list", "--json"]);
    assert_eq!(out.status.code(), Some(0));
    let value: serde_json::Value = serde_json::from_slice(&out.stdout).expect("json");
    assert_eq!(value["hosts"].as_array().unwrap().len(), 1);
    assert_eq!(value["hosts"][0]["alias"], "prod");
    assert_eq!(value["hosts"][0]["hostName"], "10.0.0.5");
    assert_eq!(value["ignored"][0]["option"], "Match");
    assert_eq!(value["ignored"][0]["line"], 3);
}

#[test]
fn resolve_exit_codes() {
    let home = home_with("Host prod\n  User deploy\n");
    let hit = run(home.path(), &["resolve", "prod", "--json"]);
    assert_eq!(hit.status.code(), Some(0));
    let value: serde_json::Value = serde_json::from_slice(&hit.stdout).expect("json");
    assert_eq!(value["user"], "deploy");

    let miss = run(home.path(), &["resolve", "nope", "--json"]);
    assert_eq!(miss.status.code(), Some(1));
    assert!(miss.stdout.is_empty());

    assert_eq!(
        run(home.path(), &["resolve", "--json"]).status.code(),
        Some(2)
    );
    assert_eq!(run(home.path(), &["list"]).status.code(), Some(2));
    assert_eq!(
        run(home.path(), &["bogus", "--json"]).status.code(),
        Some(2)
    );
}
