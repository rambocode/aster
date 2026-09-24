//! ~/.ssh/config 解析（移植自 tty7 `src/core/ssh_config.rs`，Apache-2.0）。P0 占位。

use std::process::ExitCode;

/// `aster-ssh config (list|resolve <alias>) --json` 入口。
pub fn run_cli(_args: &[String]) -> ExitCode {
    eprintln!("aster-ssh config: not implemented");
    ExitCode::from(2)
}
