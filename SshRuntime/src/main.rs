//! aster-ssh：Aster 的原生 SSH 运行时入口。
//!
//! 子命令：`broker`（常驻连接持有者）、`client`（替代 /usr/bin/ssh 的薄客户端）、
//! `config`（解析 ~/.ssh/config）。协议见 `PROTOCOL.md`。

mod auth;
mod bridge;
mod broker;
mod client;
mod connect;
mod control;
mod env;
mod forward;
mod handler;
mod known_hosts;
mod logging;
mod pool;
mod protocol;
mod ssh_config;
mod target;
mod terminal;

#[cfg(test)]
mod e2e_tests;
#[cfg(test)]
mod test_support;

use std::process::ExitCode;

/// 按第一个参数分发子命令。
fn main() -> ExitCode {
    logging::init_from_env();
    let args: Vec<String> = std::env::args().skip(1).collect();
    match args.first().map(String::as_str) {
        Some("broker") => broker::run_cli(&args[1..]),
        Some("client") => client::run_cli(&args[1..]),
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
