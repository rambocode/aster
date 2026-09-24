//! 一个 client 与一条 SSH session channel 之间的双向转发。
//!
//! 硬约束（PROTOCOL §2）：client 进程退出或 socket 断开时，立即对 channel 发 EOF 与 CLOSE，
//! 让远端 pty 收到 SIGHUP。为此把「读 client socket」放在不会被远端流控卡住的循环里：
//! 发往远端的数据交给单独的写入任务（它可能因窗口耗尽而等待），读循环只负责转交，
//! 一旦读到 EOF 就直接用 `ChannelWriteHalf` 发 EOF/CLOSE 并中止写入任务。

use std::sync::Arc;

use russh::client::Msg;
use russh::{Channel, ChannelMsg, Sig};
use tokio::io::{AsyncRead, AsyncWrite, AsyncWriteExt};
use tokio::sync::mpsc;

use crate::log_debug;
use crate::pool::Connection;
use crate::protocol::{
    frame, read_frame, write_frame, ExitReport, FailureKind, Frame, ResizeRequest, SshFailure,
};

/// 待写往远端的 stdin 队列深度（每项最多 32 KiB）。足够大，读循环几乎不会因远端流控停下。
const STDIN_QUEUE: usize = 256;

/// 发往写入任务的一项。
enum Upstream {
    Data(Vec<u8>),
    Eof,
}

/// 转发结束的原因。
#[derive(Debug, PartialEq, Eq)]
pub enum Ended {
    /// client 断开（进程退出、socket 关闭或读写出错）。
    ClientGone,
    /// 远端关闭了 channel，EXIT 已发给 client。
    RemoteClosed,
}

/// 信号名（不含 `SIG`）。
pub fn signal_name(sig: &Sig) -> String {
    match sig {
        Sig::ABRT => "ABRT".into(),
        Sig::ALRM => "ALRM".into(),
        Sig::FPE => "FPE".into(),
        Sig::HUP => "HUP".into(),
        Sig::ILL => "ILL".into(),
        Sig::INT => "INT".into(),
        Sig::KILL => "KILL".into(),
        Sig::PIPE => "PIPE".into(),
        Sig::QUIT => "QUIT".into(),
        Sig::SEGV => "SEGV".into(),
        Sig::TERM => "TERM".into(),
        Sig::USR1 => "USR1".into(),
        Sig::Custom(name) => name.trim_start_matches("SIG").to_string(),
    }
}

/// 运行转发直到任一方结束。`early` 是等待 exec/shell 确认期间已经收到的 channel 消息。
pub async fn run<R, W>(
    conn: Arc<Connection>,
    channel: Channel<Msg>,
    early: Vec<ChannelMsg>,
    mut client_rd: R,
    mut client_wr: W,
) -> Ended
where
    R: AsyncRead + Unpin,
    W: AsyncWrite + Unpin,
{
    let (mut read_half, write_half) = channel.split();
    let mut remote_writer = write_half.make_writer();
    let (up_tx, mut up_rx) = mpsc::channel::<Upstream>(STDIN_QUEUE);
    let writer = tokio::spawn(async move {
        while let Some(item) = up_rx.recv().await {
            let ok = match item {
                Upstream::Data(bytes) => remote_writer.write_all(&bytes).await.is_ok(),
                // shutdown 在已写数据之后发 CHANNEL_EOF，顺序由这个任务保证。
                Upstream::Eof => remote_writer.shutdown().await.is_ok(),
            };
            if !ok {
                break;
            }
        }
    });

    // client → 远端。
    let from_client = async {
        loop {
            let frame = match read_frame(&mut client_rd).await {
                Ok(Some(f)) => f,
                Ok(None) | Err(_) => return,
            };
            match frame.kind {
                frame::STDIN => {
                    if up_tx.send(Upstream::Data(frame.payload)).await.is_err() {
                        // 写入任务已结束（远端不再收数据），继续读以便察觉 client 断开。
                        continue;
                    }
                }
                frame::STDIN_EOF => {
                    let _ = up_tx.send(Upstream::Eof).await;
                }
                frame::RESIZE => {
                    if let Ok(size) = frame.parse::<ResizeRequest>() {
                        let _ = write_half.window_change(size.cols, size.rows, 0, 0).await;
                    }
                }
                other => log_debug!("ignoring client frame type {other}"),
            }
        }
    };

    // 远端 → client。
    let to_client = async {
        let mut exit = ExitReport::default();
        let mut pending = early.into_iter();
        loop {
            let msg = match pending.next() {
                Some(m) => Some(m),
                None => read_half.wait().await,
            };
            let out = match msg {
                Some(ChannelMsg::Data { data }) => Frame::new(frame::STDOUT, data.to_vec()),
                Some(ChannelMsg::ExtendedData { data, ext: 1 }) => {
                    Frame::new(frame::STDERR, data.to_vec())
                }
                Some(ChannelMsg::ExitStatus { exit_status }) => {
                    exit.status = Some(exit_status as i32);
                    continue;
                }
                Some(ChannelMsg::ExitSignal {
                    signal_name: sig, ..
                }) => {
                    exit.signal = Some(signal_name(&sig));
                    continue;
                }
                Some(ChannelMsg::Close) | None => {
                    let frame = if exit.status.is_none() && exit.signal.is_none() {
                        Frame::json(
                            frame::ERROR,
                            &SshFailure::new(
                                FailureKind::TransportFailure,
                                "channel closed without exit status",
                            ),
                        )
                    } else {
                        Frame::json(frame::EXIT, &exit)
                    };
                    return match write_frame(&mut client_wr, &frame).await {
                        Ok(()) => Ended::RemoteClosed,
                        Err(_) => Ended::ClientGone,
                    };
                }
                Some(_) => continue,
            };
            if write_frame(&mut client_wr, &out).await.is_err() {
                return Ended::ClientGone;
            }
        }
    };

    let ended = tokio::select! {
        _ = from_client => Ended::ClientGone,
        ended = to_client => ended,
    };
    writer.abort();
    // 两种结局都关 channel：client 走了必须立刻让远端收到 EOF/CLOSE；远端先关时这两条不再上线。
    let _ = write_half.eof().await;
    let _ = write_half.close().await;
    log_debug!("channel on {} ended: {ended:?}", conn.endpoint());
    drop(conn);
    ended
}
