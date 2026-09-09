#!/usr/bin/env python3
"""P4 验收用的可控 TCP 中继：让真实 SSH 连接可以被真实切断再恢复。

A14 要求「中断真实测试连接至少 60 秒后恢复」。直接停 OrbStack 会影响用户自己的
容器，按进程名杀 ssh 又违反证据规则（只能限定本次 runID）。所以这里起一个本轮
专用的本地中继端口：机器配置连中继，中继再转发到真实后端。要制造断连就停中继
（已建立的连接会真实收到 FIN/RST，新的连接会被拒绝），恢复就重新启动中继。
中继只监听 127.0.0.1，且只服务本次 runID 的 PID 文件，不触碰其它进程。

用法：
    remote-work-p4-relay.py serve  --listen-port N --target-host H --target-port P \
                                   --state-file /path/to/relay.json
    remote-work-p4-relay.py pause  --state-file /path/to/relay.json
    remote-work-p4-relay.py resume --state-file /path/to/relay.json
    remote-work-p4-relay.py stop   --state-file /path/to/relay.json
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import socket
import socketserver
import sys
import threading
import time


class _RelayHandler(socketserver.BaseRequestHandler):
    """把一条入站连接双向搬运到后端；任一侧关闭就整体收束。"""

    def handle(self) -> None:
        backend = socket.create_connection(
            (self.server.target_host, self.server.target_port), timeout=10
        )
        try:
            self._pump_both(self.request, backend)
        finally:
            for sock in (backend, self.request):
                try:
                    sock.close()
                except OSError:
                    pass

    @staticmethod
    def _pump_both(left: socket.socket, right: socket.socket) -> None:
        def pump(src: socket.socket, dst: socket.socket) -> None:
            try:
                while True:
                    chunk = src.recv(65536)
                    if not chunk:
                        break
                    dst.sendall(chunk)
            except OSError:
                pass
            finally:
                try:
                    dst.shutdown(socket.SHUT_WR)
                except OSError:
                    pass

        first = threading.Thread(target=pump, args=(left, right), daemon=True)
        first.start()
        pump(right, left)
        first.join(timeout=5)


class _RelayServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    allow_reuse_address = True


def _serve(args: argparse.Namespace) -> int:
    server = _RelayServer(("127.0.0.1", args.listen_port), _RelayHandler)
    server.target_host = args.target_host
    server.target_port = args.target_port
    listen_port = server.server_address[1]
    state = {
        "pid": os.getpid(),
        "listenPort": listen_port,
        "targetHost": args.target_host,
        "targetPort": args.target_port,
        "startedAt": time.time(),
    }
    # 先写状态文件再进入 accept 循环，调用方可以只靠该文件判断中继已就绪。
    with open(args.state_file, "w", encoding="utf-8") as handle:
        json.dump(state, handle)
    print(json.dumps(state), flush=True)

    stopping = threading.Event()

    def _handle_stop(_signum: int, _frame: object) -> None:
        stopping.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _handle_stop)
    signal.signal(signal.SIGINT, _handle_stop)
    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()
    return 0


def _load_state(path: str) -> dict:
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def _signal_relay(args: argparse.Namespace, sig: int) -> int:
    """只向状态文件里记录的那一个 PID 发信号，绝不按进程名匹配。"""
    state = _load_state(args.state_file)
    pid = int(state["pid"])
    try:
        os.kill(pid, sig)
    except ProcessLookupError:
        print(json.dumps({"result": "gone", "pid": pid}), flush=True)
        return 1
    print(json.dumps({"result": "signalled", "pid": pid, "signal": sig}), flush=True)
    return 0


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["serve", "pause", "resume", "stop"])
    parser.add_argument("--listen-port", type=int, default=0)
    parser.add_argument("--target-host", default="127.0.0.1")
    parser.add_argument("--target-port", type=int, default=32222)
    parser.add_argument("--state-file", required=True)
    args = parser.parse_args(argv)
    if args.action == "serve":
        return _serve(args)
    if args.action == "pause":
        return _signal_relay(args, signal.SIGSTOP)
    if args.action == "resume":
        return _signal_relay(args, signal.SIGCONT)
    return _signal_relay(args, signal.SIGTERM)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
