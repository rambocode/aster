//! stderr 日志。
//!
//! 调用方只允许传入已脱敏的文字：口令、passphrase、私钥内容、键盘交互回答从不进入
//! 格式化参数。测试构建下每行还会记进内存，脱敏测试据此断言秘密没有出现。

use std::fmt::Arguments;
use std::io::Write as _;
use std::sync::atomic::{AtomicBool, Ordering};

/// 是否输出 debug 级别；由环境变量 `ASTER_SSH_DEBUG` 打开。
static DEBUG: AtomicBool = AtomicBool::new(false);

/// 读取环境变量，决定是否打开 debug 日志。进程启动时调用一次。
pub fn init_from_env() {
    let on = std::env::var_os("ASTER_SSH_DEBUG").is_some_and(|v| !v.is_empty() && v != "0");
    DEBUG.store(on, Ordering::Relaxed);
}

/// 日志级别。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Level {
    Debug,
    Info,
    Warn,
}

impl Level {
    /// 级别的小写名，同时用于控制通道 `log` 消息的 `level` 字段。
    pub fn as_str(self) -> &'static str {
        match self {
            Level::Debug => "debug",
            Level::Info => "info",
            Level::Warn => "warn",
        }
    }
}

/// 写一行日志到 stderr。
pub fn write(level: Level, args: Arguments<'_>) {
    // 测试构建总是记录 debug 行，让脱敏断言也覆盖 debug 日志。
    if level == Level::Debug && !DEBUG.load(Ordering::Relaxed) && !cfg!(test) {
        return;
    }
    let line = format!("aster-ssh {}: {}", level.as_str(), args);
    #[cfg(test)]
    capture::record(&line);
    let mut err = std::io::stderr().lock();
    // stderr 写失败没有更好的去处，只能放弃这一行。
    let _ = writeln!(err, "{line}");
}

/// `log_debug!(...)`：debug 级别日志。
#[macro_export]
macro_rules! log_debug {
    ($($arg:tt)*) => { $crate::logging::write($crate::logging::Level::Debug, format_args!($($arg)*)) };
}

/// `log_info!(...)`：info 级别日志。
#[macro_export]
macro_rules! log_info {
    ($($arg:tt)*) => { $crate::logging::write($crate::logging::Level::Info, format_args!($($arg)*)) };
}

/// `log_warn!(...)`：warn 级别日志。
#[macro_export]
macro_rules! log_warn {
    ($($arg:tt)*) => { $crate::logging::write($crate::logging::Level::Warn, format_args!($($arg)*)) };
}

/// 测试专用：记录全部日志行，供脱敏断言使用。
#[cfg(test)]
pub mod capture {
    use std::sync::Mutex;

    static LINES: Mutex<Vec<String>> = Mutex::new(Vec::new());

    /// 记录一行。
    pub fn record(line: &str) {
        LINES
            .lock()
            .unwrap_or_else(|p| p.into_inner())
            .push(line.to_string());
    }

    /// 至今为止的全部日志行。
    pub fn lines() -> Vec<String> {
        LINES.lock().unwrap_or_else(|p| p.into_inner()).clone()
    }
}
