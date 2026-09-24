//! Include 展开与文件读取安全限制的测试。

use super::super::loader::{MAX_FILES, MAX_FILE_BYTES, MAX_INCLUDE_DEPTH};
use super::{aliases, home_with, ignored, list, resolve, write};

// MARK: - Include

#[test]
fn include_relative_paths_resolve_against_dot_ssh_with_sorted_globs() {
    let home = home_with("Include conf.d/*.conf\nHost root\n");
    write(
        home.path(),
        ".ssh/conf.d/20-prod.conf",
        "Host prod\n  Include nested/extra\n",
    );
    write(
        home.path(),
        ".ssh/conf.d/10-dev.conf",
        "Host dev\n  User dev-user\n",
    );
    write(home.path(), ".ssh/conf.d/.hidden.conf", "Host hidden\n");
    // 嵌套文件里的相对路径仍按 ~/.ssh/ 解析，而不是按 conf.d/
    write(home.path(), ".ssh/nested/extra", "User from-nested\n");
    write(home.path(), ".ssh/conf.d/nested/extra", "User wrong-base\n");

    let listing = list(&home);
    assert_eq!(aliases(&listing), vec!["dev", "prod", "root"]);
    assert!(listing.ignored.is_empty(), "{:?}", listing.ignored);
    assert_eq!(
        resolve(&home, "prod").unwrap().user.as_deref(),
        Some("from-nested")
    );
    assert_eq!(
        resolve(&home, "dev").unwrap().user.as_deref(),
        Some("dev-user")
    );
}

#[test]
fn include_supports_tilde_and_reports_missing_literal_files() {
    let home = home_with("Include ~/other/cfg\nInclude missing-file\nInclude empty.d/*\n");
    write(home.path(), "other/cfg", "Host tilde\n");
    let listing = list(&home);
    assert_eq!(aliases(&listing), vec!["tilde"]);
    // 字面路径不存在要报；glob 没匹配到是正常情况，不报
    assert_eq!(
        ignored(&listing),
        vec![("~/.ssh/config", 2, "Include", "notFound")]
    );
}

#[test]
fn include_inside_host_block_only_applies_when_that_host_matches() {
    let home = home_with("Host work\n  Include work.conf\nHost other\n");
    write(
        home.path(),
        ".ssh/work.conf",
        "User worker\nHost work inner\n  Port 2222\n",
    );
    let work = resolve(&home, "work").unwrap();
    assert_eq!(work.user.as_deref(), Some("worker"));
    assert_eq!(work.port, Some(2222));
    assert!(resolve(&home, "other").unwrap().user.is_none());
    // inner 只在外层 Host work 匹配时才会被看到，而 inner 本身不匹配 work，所以连不上
    assert!(resolve(&home, "inner").is_none());
    assert_eq!(aliases(&list(&home)), vec!["work", "other"]);
}

#[test]
fn include_cycle_is_detected() {
    let home = home_with("Include a\nHost root\n");
    // Include 写在 Host 之前：写在 Host 块里的话，被包含文件的 Host 会受外层条件约束
    write(home.path(), ".ssh/a", "Include b\nHost ha\n");
    write(
        home.path(),
        ".ssh/b",
        "Host hb\nInclude a\nInclude config\n",
    );
    let listing = list(&home);
    assert_eq!(aliases(&listing), vec!["hb", "ha", "root"]);
    assert_eq!(
        ignored(&listing),
        vec![
            ("~/.ssh/b", 2, "Include", "includeCycle"),
            ("~/.ssh/b", 3, "Include", "includeCycle"),
        ]
    );
}

#[test]
fn include_depth_is_limited() {
    let home = home_with("Include f1\n");
    for i in 1..=MAX_INCLUDE_DEPTH + 2 {
        write(
            home.path(),
            &format!(".ssh/f{i}"),
            &format!("Include f{}\nHost h{i}\n", i + 1),
        );
    }
    let listing = list(&home);
    assert_eq!(listing.hosts.len(), MAX_INCLUDE_DEPTH);
    let last = format!("~/.ssh/f{MAX_INCLUDE_DEPTH}");
    assert_eq!(
        ignored(&listing),
        vec![(last.as_str(), 1, "Include", "includeDepth")]
    );
}

#[test]
fn total_file_count_is_limited() {
    let home = home_with("Include many/*\n");
    for i in 0..MAX_FILES + 5 {
        write(
            home.path(),
            &format!(".ssh/many/{i:03}"),
            &format!("Host m{i}\n"),
        );
    }
    let listing = list(&home);
    assert_eq!(listing.hosts.len(), MAX_FILES - 1, "根配置占一个名额");
    assert_eq!(listing.ignored.len(), 6);
    assert!(listing
        .ignored
        .iter()
        .all(|i| i.reason == "tooManyFiles" && i.line == 1));
}

#[test]
fn oversized_files_are_rejected() {
    let big = format!("Host big\n#{}\n", "x".repeat(MAX_FILE_BYTES as usize));
    let home = home_with(&big);
    let listing = list(&home);
    assert!(listing.hosts.is_empty());
    assert_eq!(
        ignored(&listing),
        vec![("~/.ssh/config", 0, "", "tooLarge")]
    );

    let home = home_with("Include big.conf\nHost small\n");
    write(home.path(), ".ssh/big.conf", &big);
    let listing = list(&home);
    assert_eq!(aliases(&listing), vec!["small"]);
    assert_eq!(
        ignored(&listing),
        vec![("~/.ssh/config", 1, "Include", "tooLarge")]
    );
}

#[test]
fn symlinks_to_regular_files_are_followed_but_not_to_directories() {
    let home = home_with("Include linked dir-link\n");
    let real = write(home.path(), "real/cfg", "Host via-link\n");
    std::os::unix::fs::symlink(&real, home.path().join(".ssh/linked")).unwrap();
    std::os::unix::fs::symlink(home.path().join("real"), home.path().join(".ssh/dir-link"))
        .unwrap();
    let listing = list(&home);
    assert_eq!(aliases(&listing), vec!["via-link"]);
    assert_eq!(
        ignored(&listing),
        vec![("~/.ssh/config", 1, "Include", "notRegularFile")]
    );
}
