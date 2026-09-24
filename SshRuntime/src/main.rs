//! aster-ssh：Aster 的原生 SSH 运行时入口。
//!
//! 子命令：`broker`（常驻连接持有者）、`client`（替代 /usr/bin/ssh 的薄客户端）、
//! `config`（解析 ~/.ssh/config）。协议见 `PROTOCOL.md`。

mod ssh_config;

use std::process::ExitCode;

/// 按第一个参数分发子命令。
fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("config") => ssh_config::run_cli(&args[1..]),
        Some("--version") => {
            println!("aster-ssh {}", env!("CARGO_PKG_VERSION"));
            ExitCode::SUCCESS
        }
        _ => {
            eprintln!("usage: aster-ssh (broker|client|config) ...");
            ExitCode::from(2)
        }
    }
}
