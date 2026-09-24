//! ssh_config 解析测试。每个用例都在临时目录里造一个假的 HOME，不读真实 `~/.ssh/config`。
//! Include 与文件安全相关的用例在 `tests/include.rs`，JSON 与命令行在 `tests/json.rs`。

mod include;
mod json;

use std::fs;
use std::path::{Path, PathBuf};

use tempfile::TempDir;

use super::lexer::{pattern_match, split_words};
use super::*;

/// 造一个临时 HOME，写入 `~/.ssh/config`。
pub(super) fn home_with(config: &str) -> TempDir {
    let home = tempfile::tempdir().expect("tempdir");
    fs::create_dir_all(home.path().join(".ssh")).expect("mkdir .ssh");
    write(home.path(), ".ssh/config", config);
    home
}

/// 在 HOME 下写一个文件（自动建父目录），返回完整路径。
pub(super) fn write(home: &Path, relative: &str, text: &str) -> PathBuf {
    let path = home.join(relative);
    fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
    fs::write(&path, text).expect("write");
    path
}

/// 在临时 HOME 上解析 alias。
pub(super) fn resolve(home: &TempDir, alias: &str) -> Option<HostEntry> {
    resolve_in(&home.path().join(".ssh/config"), home.path(), alias)
}

/// 在临时 HOME 上列出所有 host。
pub(super) fn list(home: &TempDir) -> ConfigListing {
    list_in(&home.path().join(".ssh/config"), home.path())
}

/// list 结果里的 alias 列表。
pub(super) fn aliases(listing: &ConfigListing) -> Vec<&str> {
    listing.hosts.iter().map(|h| h.alias.as_str()).collect()
}

/// ignored 条目压成 (文件, 行, 关键字, 原因) 方便断言。
pub(super) fn ignored(listing: &ConfigListing) -> Vec<(&str, usize, &str, &str)> {
    listing
        .ignored
        .iter()
        .map(|i| {
            (
                i.file.as_str(),
                i.line,
                i.option.as_str(),
                i.reason.as_str(),
            )
        })
        .collect()
}

/// 构造一个 HostPort。
pub(super) fn hp(host: &str, port: u16) -> HostPort {
    HostPort {
        host: host.to_string(),
        port,
    }
}

// MARK: - 匹配与求值顺序

#[test]
fn first_match_wins_across_blocks() {
    let home = home_with(concat!(
        "Host prod\n",
        "  HostName 10.0.0.5\n",
        "  User deploy\n",
        "  User ignored-second\n",
        "Host *\n",
        "  User fallback\n",
        "  Port 2200\n",
        "  HostName should-not-win\n",
    ));
    let prod = resolve(&home, "prod").expect("prod");
    assert_eq!(prod.host_name.as_deref(), Some("10.0.0.5"));
    assert_eq!(prod.user.as_deref(), Some("deploy"));
    assert_eq!(prod.port, Some(2200));

    let other = resolve(&home, "other.example").expect("Host * 也算命中");
    assert_eq!(other.user.as_deref(), Some("fallback"));
    assert_eq!(other.host_name.as_deref(), Some("should-not-win"));
}

#[test]
fn global_lines_before_first_host_take_precedence() {
    // OpenSSH 里第一个 Host 之前的行对所有主机生效，并且因为出现得早，优先于后面的 Host 块
    let home = home_with("User early\nHost prod\n  User late\n");
    assert_eq!(
        resolve(&home, "prod").unwrap().user.as_deref(),
        Some("early")
    );
    // 只命中全局行、没有任何 Host 块匹配：返回 None
    assert!(resolve(&home, "nobody").is_none());
}

#[test]
fn wildcards_and_negation() {
    let home = home_with(concat!(
        "Host *.corp !secret.corp\n",
        "  User corp\n",
        "Host web?\n",
        "  User web\n",
        "Host !only-negated\n",
        "  User never\n",
    ));
    assert_eq!(
        resolve(&home, "a.corp").unwrap().user.as_deref(),
        Some("corp")
    );
    assert!(resolve(&home, "secret.corp").is_none());
    assert_eq!(resolve(&home, "web1").unwrap().user.as_deref(), Some("web"));
    assert!(resolve(&home, "web12").is_none());
    // 只有取反模式的 Host 行不匹配任何主机
    assert!(resolve(&home, "anything").is_none());
    // 大小写不敏感
    assert_eq!(
        resolve(&home, "A.CORP").unwrap().user.as_deref(),
        Some("corp")
    );
}

#[test]
fn pattern_match_handles_pathological_patterns_quickly() {
    assert!(pattern_match("*.conf", "dev.conf"));
    assert!(!pattern_match("host?", "host12"));
    let text = "a".repeat(200);
    assert!(!pattern_match("*a*a*a*a*a*a*a*a*a*a*b", &text));
}

#[test]
fn unknown_alias_and_missing_config_return_none() {
    let home = home_with("Host prod\n  HostName 10.0.0.5\n");
    assert!(resolve(&home, "dev").is_none());
    let empty = tempfile::tempdir().unwrap();
    assert!(resolve_in(&empty.path().join(".ssh/config"), empty.path(), "prod").is_none());
    assert_eq!(
        list_in(&empty.path().join(".ssh/config"), empty.path()),
        ConfigListing::default()
    );
}

#[test]
fn hostname_tokens_expand() {
    let home = home_with("Host web1 lit\n  HostName %h.internal\nHost lit\n  HostName 100%%\n");
    assert_eq!(
        resolve(&home, "web1").unwrap().host_name.as_deref(),
        Some("web1.internal")
    );
    assert_eq!(expand_hostname_tokens("100%%-%q", "a"), "100%-%q");
}

#[test]
fn keyword_equals_syntax_quotes_and_comments() {
    let home = home_with(concat!(
        "# 注释\n",
        "Host = \"quoted host\" plain\n",
        "  Port=2222\n",
        "  User  me # 行尾注释\n",
        "  IdentityFile \"~/.ssh/my key\"\n",
        "  ProxyCommand connect -H proxy#1 %h %p\n",
    ));
    let entry = resolve(&home, "quoted host").expect("quoted");
    assert_eq!(entry.port, Some(2222));
    assert_eq!(entry.user.as_deref(), Some("me"));
    assert_eq!(entry.identity_files, vec!["~/.ssh/my key"]);
    assert_eq!(
        entry.proxy_command.as_deref(),
        Some("connect -H proxy#1 %h %p")
    );
    assert_eq!(aliases(&list(&home)), vec!["quoted host", "plain"]);
}

#[test]
fn split_words_follows_openssh_escapes() {
    assert_eq!(
        split_words(r#"a\ b "c d" 'e"f'"#).unwrap(),
        vec!["a b", "c d", "e\"f"]
    );
    assert_eq!(split_words(r"C:\keys\id").unwrap(), vec![r"C:\keys\id"]);
    assert!(split_words("\"unterminated").is_none());
}

#[test]
fn multiple_identity_files_accumulate_in_order_without_duplicates() {
    let home = home_with(concat!(
        "Host prod\n",
        "  IdentityFile ~/.ssh/id_prod\n",
        "  IdentityFile ~/.ssh/id_backup\n",
        "Host *\n",
        "  IdentityFile ~/.ssh/id_common\n",
        "  IdentityFile ~/.ssh/id_prod\n",
    ));
    assert_eq!(
        resolve(&home, "prod").unwrap().identity_files,
        vec!["~/.ssh/id_prod", "~/.ssh/id_backup", "~/.ssh/id_common"]
    );
}

#[test]
fn proxy_jump_chain_is_kept_verbatim_and_excludes_proxy_command() {
    let home = home_with(concat!(
        "Host prod\n",
        "  ProxyJump me@bastion:2200,[fe80::1]:22,second\n",
        "  ProxyCommand nc %h %p\n",
        "Host direct\n",
        "  ProxyCommand none\n",
        "Host *\n",
        "  ProxyJump default-jump\n",
    ));
    let prod = resolve(&home, "prod").unwrap();
    assert_eq!(
        prod.proxy_jump.as_deref(),
        Some("me@bastion:2200,[fe80::1]:22,second")
    );
    assert_eq!(
        prod.proxy_command, None,
        "ProxyJump 先出现，ProxyCommand 被忽略"
    );
    let direct = resolve(&home, "direct").unwrap();
    assert_eq!(direct.proxy_jump, None, "ProxyCommand none 占住了代理设置");
    assert_eq!(direct.proxy_command, None);
}

#[test]
fn keepalive_and_extra_fields() {
    let home = home_with(concat!(
        "Host prod\n",
        "  ServerAliveInterval 15\n",
        "  ServerAliveCountMax 3\n",
        "  ForwardAgent yes\n",
        "  ConnectTimeout 1m30s\n",
        "  StrictHostKeyChecking off\n",
        "Host bad\n",
        "  ServerAliveInterval soon\n",
        "  Port 70000\n",
    ));
    let prod = resolve(&home, "prod").unwrap();
    assert_eq!(prod.keepalive_interval, Some(15));
    assert_eq!(prod.keepalive_count_max, Some(3));
    assert_eq!(prod.forward_agent, Some(true));
    assert_eq!(prod.connect_timeout, Some(90));
    assert_eq!(prod.strict_host_key_checking.as_deref(), Some("no"));
    assert_eq!(
        ignored(&list(&home)),
        vec![
            ("~/.ssh/config", 8, "ServerAliveInterval", "invalidValue"),
            ("~/.ssh/config", 9, "Port", "invalidValue"),
        ]
    );
}

#[test]
fn known_hosts_files_and_identities_only() {
    let home = home_with(concat!(
        "Host orb\n",
        "  UserKnownHostsFile ~/.orbstack/ssh/known_hosts \"~/with space/kh\"\n",
        "  UserKnownHostsFile ~/ignored_second_directive\n",
        "  GlobalKnownHostsFile /etc/custom_known_hosts\n",
        "  IdentitiesOnly yes\n",
        "Host blind\n",
        "  UserKnownHostsFile none\n",
        "  IdentitiesOnly no\n",
        "Host bad\n",
        "  UserKnownHostsFile none ~/x\n",
        "  IdentitiesOnly maybe\n",
    ));
    let orb = resolve(&home, "orb").unwrap();
    assert_eq!(
        orb.user_known_hosts_files,
        vec!["~/.orbstack/ssh/known_hosts", "~/with space/kh"],
        "原文保留，第一个指令生效"
    );
    assert_eq!(
        orb.global_known_hosts_files,
        vec!["/etc/custom_known_hosts"]
    );
    assert_eq!(orb.identities_only, Some(true));
    let blind = resolve(&home, "blind").unwrap();
    assert_eq!(blind.user_known_hosts_files, vec!["none"]);
    assert_eq!(blind.identities_only, Some(false));
    assert_eq!(
        resolve(&home, "bad").unwrap().user_known_hosts_files,
        Vec::<String>::new()
    );
    assert_eq!(
        ignored(&list(&home)),
        vec![
            ("~/.ssh/config", 10, "UserKnownHostsFile", "invalidValue"),
            ("~/.ssh/config", 11, "IdentitiesOnly", "invalidValue"),
        ],
        "这两项不再记为 unsupported"
    );
    let json = serde_json::to_value(&orb).unwrap();
    assert_eq!(
        json["userKnownHostsFiles"][0],
        "~/.orbstack/ssh/known_hosts"
    );
    assert_eq!(json["identitiesOnly"], true);
    let old: HostEntry = serde_json::from_str(r#"{"alias":"x","hostName":null,"user":null,"port":null,"identityFiles":[],"proxyJump":null,"proxyCommand":null,"forwards":[],"keepaliveInterval":null,"keepaliveCountMax":null}"#).unwrap();
    assert!(old.user_known_hosts_files.is_empty() && old.identities_only.is_none());
}

// MARK: - 端口转发

#[test]
fn forward_syntaxes() {
    let home = home_with(concat!(
        "Host fw\n",
        "  LocalForward 8080 localhost:80\n",
        "  LocalForward [::1]:8081 [::1]:81\n",
        "  LocalForward *:8082 db.internal:5432\n",
        "  LocalForward 0.0.0.0/8083 ::1/83\n",
        "  RemoteForward 9000 127.0.0.1:3000\n",
        "  RemoteForward [::1]:0 localhost:22\n",
        "  DynamicForward 1080\n",
        "  DynamicForward [::1]:1081\n",
        "  DynamicForward localhost:1082\n",
        "  LocalForward 8080 localhost:80\n",
    ));
    let rules: Vec<(String, HostPort, HostPort)> = resolve(&home, "fw")
        .unwrap()
        .forwards
        .into_iter()
        .map(|r| (r.kind, r.bind, r.target))
        .collect();
    let expected = vec![
        ("local", hp("127.0.0.1", 8080), hp("localhost", 80)),
        ("local", hp("::1", 8081), hp("::1", 81)),
        ("local", hp("0.0.0.0", 8082), hp("db.internal", 5432)),
        ("local", hp("0.0.0.0", 8083), hp("::1", 83)),
        ("remote", hp("127.0.0.1", 9000), hp("127.0.0.1", 3000)),
        ("remote", hp("::1", 0), hp("localhost", 22)),
        ("dynamic", hp("127.0.0.1", 1080), HostPort::default()),
        ("dynamic", hp("::1", 1081), HostPort::default()),
        ("dynamic", hp("localhost", 1082), HostPort::default()),
    ];
    let expected: Vec<(String, HostPort, HostPort)> = expected
        .into_iter()
        .map(|(k, b, t)| (k.to_string(), b, t))
        .collect();
    assert_eq!(rules, expected, "最后一条重复的 LocalForward 被去重");
}

#[test]
fn invalid_and_unsupported_forwards_are_reported() {
    let home = home_with(concat!(
        "Host fw\n",
        "  LocalForward 8080\n",
        "  LocalForward ::1:8080 localhost:80\n",
        "  LocalForward 8080 localhost:0\n",
        "  LocalForward /tmp/sock localhost:80\n",
        "  RemoteForward 1080\n",
        "  DynamicForward 1080 extra\n",
    ));
    assert!(resolve(&home, "fw").unwrap().forwards.is_empty());
    let listing = list(&home);
    let reasons: Vec<(usize, &str)> = listing
        .ignored
        .iter()
        .map(|i| (i.line, i.reason.as_str()))
        .collect();
    assert_eq!(
        reasons,
        vec![
            (2, "invalidValue"),
            (3, "invalidValue"),
            (4, "invalidValue"),
            (5, "unsupported"),
            (6, "unsupported"),
            (7, "invalidValue"),
        ]
    );
}

// MARK: - 不支持的指令

#[test]
fn match_blocks_are_skipped_and_reported() {
    let home = home_with(concat!(
        "Host secure\n",
        "  HostName real.example.com\n",
        "Match host secure exec \"true\"\n",
        "  User should-be-ignored\n",
        "  Include never-read\n",
        "Host secure\n",
        "  User after-match\n",
    ));
    let entry = resolve(&home, "secure").unwrap();
    assert_eq!(entry.user.as_deref(), Some("after-match"));
    assert_eq!(
        ignored(&list(&home)),
        vec![("~/.ssh/config", 3, "Match", "unsupported")]
    );
}

#[test]
fn unsupported_directives_are_listed_with_file_and_line() {
    let home = home_with(concat!(
        "CanonicalizeHostname yes\n",
        "Host prod\n",
        "  GSSAPIAuthentication yes\n",
        "  HostName 10.0.0.5\n",
        "  UseKeychain yes\n",
    ));
    assert_eq!(
        ignored(&list(&home)),
        vec![
            ("~/.ssh/config", 1, "CanonicalizeHostname", "unsupported"),
            ("~/.ssh/config", 3, "GSSAPIAuthentication", "unsupported"),
            ("~/.ssh/config", 5, "UseKeychain", "unsupported"),
        ]
    );
}
