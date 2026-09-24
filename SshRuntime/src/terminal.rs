//! 本地终端：raw 模式的进入与恢复、窗口大小。原设置存在进程级静态变量里，
//! 正常退出和被信号结束两条路径都据此恢复。

use std::sync::Mutex;

use crate::protocol::ResizeRequest;

/// 进入 raw 模式前的终端设置，退出（含被信号结束）时据此恢复。
static SAVED_TERMIOS: Mutex<Option<libc::termios>> = Mutex::new(None);

/// fd 是否是终端。
pub fn is_tty(fd: i32) -> bool {
    // SAFETY: isatty 只读取 fd 状态。
    unsafe { libc::isatty(fd) == 1 }
}

/// 本地终端大小；取不到时 80x24。
pub fn window_size() -> ResizeRequest {
    for fd in [0, 1, 2] {
        // SAFETY: winsize 是纯数据结构，TIOCGWINSZ 只写入它。
        let mut ws: libc::winsize = unsafe { std::mem::zeroed() };
        if unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut ws) } == 0
            && ws.ws_col > 0
            && ws.ws_row > 0
        {
            return ResizeRequest {
                cols: u32::from(ws.ws_col),
                rows: u32::from(ws.ws_row),
            };
        }
    }
    ResizeRequest { cols: 80, rows: 24 }
}

/// 把 stdin 切到 raw 模式并记下原设置。
pub fn enter_raw_mode() {
    // SAFETY: termios 是纯数据结构；tcgetattr/tcsetattr 只作用于 fd 0。
    unsafe {
        let mut original: libc::termios = std::mem::zeroed();
        if libc::tcgetattr(0, &mut original) != 0 {
            return;
        }
        let mut raw = original;
        libc::cfmakeraw(&mut raw);
        if libc::tcsetattr(0, libc::TCSADRAIN, &raw) == 0 {
            *SAVED_TERMIOS.lock().unwrap_or_else(|p| p.into_inner()) = Some(original);
        }
    }
}

/// 恢复进入 raw 模式前的终端设置（可重复调用）。
pub fn restore_terminal() {
    let saved = SAVED_TERMIOS
        .lock()
        .unwrap_or_else(|p| p.into_inner())
        .take();
    if let Some(original) = saved {
        // SAFETY: 写回之前由 tcgetattr 取得的设置。
        unsafe {
            libc::tcsetattr(0, libc::TCSADRAIN, &original);
        }
    }
}
