"""P1 CLI recovery through a frame-aware proxy to a real private service."""
import base64
import hashlib
import json
import os
from pathlib import Path
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time
import uuid

from terminal_attach import Host
from terminal_service import Client, TIMEOUT, eventually, success


def read_frame(peer):
    def exact(size):
        result = bytearray()
        while len(result) < size:
            data = peer.recv(size - len(result))
            if not data:
                raise EOFError()
            result.extend(data)
        return bytes(result)
    header = exact(5)
    kind, size = struct.unpack(">BI", header)
    assert kind in (1, 2) and 0 < size <= 1024 * 1024
    return kind, exact(size)


def wire(kind, payload):
    if isinstance(payload, dict):
        payload = json.dumps(payload).encode()
    return struct.pack(">BI", kind, len(payload)) + payload


class Proxy:
    def __init__(self, endpoint, upstream):
        self.upstream = upstream
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(str(endpoint))
        endpoint.chmod(0o600)
        self.listener.listen()
        self.listener.settimeout(.1)
        self.stopped = threading.Event()
        self.release = threading.Event()
        self.snapshot_requested = threading.Event()
        self.control_injected = threading.Event()
        self.restored_sent = threading.Event()
        self.surface_gap = False
        self.control_gap = False
        self.requests = []
        self.errors = []
        self.sockets = []
        self.threads = []
        self.spawn(self.accept)

    def spawn(self, target, *arguments):
        thread = threading.Thread(target=target, args=arguments, daemon=True)
        self.threads.append(thread)
        thread.start()

    def accept(self):
        while not self.stopped.is_set():
            try:
                peer, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            upstream = socket.socket(socket.AF_UNIX)
            upstream.connect(str(self.upstream))
            self.sockets.extend((peer, upstream))
            state = {"surface": False, "initial": True, "sequence": 0}
            self.spawn(self.copy, peer, upstream, state, False)
            self.spawn(self.copy, upstream, peer, state, True)

    def copy(self, source, destination, state, responses):
        try:
            while not self.stopped.is_set():
                kind, payload = read_frame(source)
                value = json.loads(payload) if kind == 1 else None
                if not responses and value and value.get("type") == "request":
                    self.requests.append((time.monotonic(), value))
                    if value["operation"] == "surface.subscribe":
                        state["surface"] = True
                    if value["operation"] == "surface.snapshot":
                        self.snapshot_requested.set()
                if responses and value:
                    if state["surface"] and value["type"] == "snapshot_begin":
                        state["sequence"] = value["sequence"]
                        if (not state["initial"] and self.snapshot_requested.is_set()) or self.control_injected.is_set() or self.restored_sent.is_set():
                            assert self.release.wait(12), "test did not release recovery snapshot"
                            # Preserve the actual snapshot but prepend harmless
                            # SGR resets so its verified body cannot fit in the
                            # host PTY output queue until the test drains stdout.
                            parts = []
                            while True:
                                next_kind, body = read_frame(source)
                                if next_kind == 1:
                                    assert json.loads(body)["type"] == "snapshot_end"
                                    break
                                parts.append(body)
                            data = b"\x1b[0m" * 65536 + b"".join(parts) + b"\r\nRECOVERY_OUTPUT_APPLIED\r\n"
                            value["length"] = len(data)
                            value["sha256"] = hashlib.sha256(data).hexdigest()
                            destination.sendall(wire(1, value))
                            for offset in range(0, len(data), 65536):
                                destination.sendall(wire(2, data[offset:offset+65536]))
                            destination.sendall(wire(1, dict(type="snapshot_end")))
                            self.restored_sent.set()
                            continue
                    if (not state["surface"] and value["type"] == "event" and self.control_gap):
                        self.control_gap = False
                        value["sequence"] += 1
                        payload = json.dumps(value).encode()
                        self.control_injected.set()
                destination.sendall(wire(kind, payload))
                if responses and value and state["surface"] and value["type"] == "snapshot_end":
                    first = state["initial"]
                    state["initial"] = False
                    if first and self.surface_gap:
                        self.surface_gap = False
                        data = b"MUST_NOT_APPLY"
                        destination.sendall(wire(1, dict(type="delta_begin", length=len(data),
                            sha256=hashlib.sha256(data).hexdigest(), sequence=state["sequence"]+2,
                            baseSequence=state["sequence"]+1)) + wire(2, data) + wire(1, dict(type="delta_end")))
        except (EOFError, BrokenPipeError, ConnectionResetError, OSError):
            pass
        except Exception as error:
            self.errors.append(repr(error))
        finally:
            try:
                destination.shutdown(socket.SHUT_WR)
            except OSError:
                pass

    def close(self):
        self.stopped.set()
        self.release.set()
        self.listener.close()
        for peer in self.sockets:
            try:
                peer.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
            peer.close()
        for thread in self.threads:
            thread.join(timeout=1)


def main(binary):
    with tempfile.TemporaryDirectory(prefix="aster-resync-", dir="/tmp") as parent:
        root = Path(parent)
        root.chmod(0o700)
        actual, proxied = root / "actual", root / "proxy"
        actual.mkdir(mode=0o700)
        (proxied / "session").mkdir(parents=True, mode=0o700)
        proxied.chmod(0o700)
        hosts = []
        proxy = None
        control = None
        with (root / "stderr").open("wb+") as diagnostics:
            server = subprocess.Popen([binary, "server", "serve", str(actual), "session"],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=diagnostics)
            try:
                endpoint = actual / "session/control.sock"
                control = Client(endpoint, server)
                program = "import pathlib,sys; print('RESYNC_READY',flush=True); pathlib.Path('ready').touch()\nfor line in sys.stdin: pathlib.Path('input').write_text(line.strip()); print('ACK:'+line.strip(),flush=True)"
                created = success(control.call("terminal.create", {"cwd": parent,
                    "argv": [sys.executable, "-u", "-c", program]}))
                eventually(lambda: (root / "ready").exists(), "terminal ready before snapshot")
                proxy = Proxy(proxied / "session/control.sock", endpoint)
                proxy.surface_gap = True
                writer = Host(binary, str(proxied), created["terminalID"])
                hosts.append(writer)
                writer.until(b"RESYNC_READY")
                assert proxy.snapshot_requested.wait(TIMEOUT)
                freeze = time.monotonic()
                writer.write(b"DROP_DURING_GAP\n")
                writer.resize(31, 97)
                writer.process.send_signal(signal.SIGWINCH)
                # Hold past the five-second heartbeat, proving the empty input
                # is allowed while user input and resize remain gated.
                time.sleep(5.3)
                requests = [request for at, request in proxy.requests if at >= freeze]
                controls = [request for request in requests if request["operation"] == "terminal.control"]
                assert any(request["params"].get("action") == "input" and request["params"].get("data") == "" for request in controls), controls
                assert all(request["params"].get("action") == "input" and request["params"].get("data") == "" for request in controls), controls
                assert sum(request["operation"] == "surface.snapshot" for _, request in proxy.requests) == 1
                assert not (root / "input").exists()
                proxy.release.set()
                assert proxy.restored_sent.wait(TIMEOUT)
                time.sleep(.2)
                after_validation = time.monotonic()
                writer.write(b"DROP_BEFORE_STDOUT_APPLIED\n")
                time.sleep(.2)
                assert not (root / "input").exists()
                assert not any(at >= after_validation and request["operation"] == "terminal.control" and
                    request["params"].get("data") for at, request in proxy.requests)
                writer.until(b"RECOVERY_OUTPUT_APPLIED")
                eventually(lambda: sum(request["operation"] == "surface.subscribe" for _, request in proxy.requests) == 2, "deferred resize rebuilds surface")
                writer.until(b"RECOVERY_OUTPUT_APPLIED")
                resizes = [request for at, request in proxy.requests if at >= freeze and request["operation"] == "terminal.control" and request["params"].get("action") == "resize"]
                assert len(resizes) == 1 and resizes[0]["params"]["geometry"]["rows"] == 31 and resizes[0]["params"]["geometry"]["columns"] == 97
                writer.write(b"ACCEPT_AFTER_GAP\n")
                eventually(lambda: (root / "input").exists() and (root / "input").read_text() == "ACCEPT_AFTER_GAP", "input resumed after applied snapshot")
                print("PASS surface gap: one snapshot request; stale keys/resize blocked; heartbeat preserved; verified snapshot resumes input", flush=True)

                old_attach = [request for _, request in proxy.requests if request["operation"] == "terminal.attach"][-1]
                proxy.control_gap = True
                # A real unrelated terminal exit supplies an authenticated event;
                # only its sequence is altered in the proxy.
                success(control.call("terminal.create", {"cwd": parent, "argv": ["/bin/sh", "-c", "exit 0"]}))
                assert proxy.control_injected.wait(TIMEOUT)
                eventually(lambda: len([request for _, request in proxy.requests if request["operation"] == "terminal.attach"]) == 2, "fresh ownership after control event gap")
                attaches = [request for _, request in proxy.requests if request["operation"] == "terminal.attach"]
                assert attaches[-1]["clientID"] != old_attach["clientID"]
                assert attaches[-1]["params"]["terminalID"] == created["terminalID"]
                writer.until(b"RECOVERY_OUTPUT_APPLIED")
                writer.write(b"ACCEPT_AFTER_CONTROL_GAP\n")
                eventually(lambda: (root / "input").read_text() == "ACCEPT_AFTER_CONTROL_GAP", "input with reconstructed lease")
                new_controls = [request for _, request in proxy.requests if request["operation"] == "terminal.control" and request["clientID"] == attaches[-1]["clientID"]]
                old_controls = [request for _, request in proxy.requests if request["operation"] == "terminal.control" and request["clientID"] == old_attach["clientID"]]
                assert new_controls[-1]["lease"] != old_controls[-1]["lease"]
                proxy.control_injected.clear()
                proxy.control_gap = True
                success(control.call("terminal.create", {"cwd": parent, "argv": ["/bin/sh", "-c", "exit 0"]}))
                assert proxy.control_injected.wait(TIMEOUT)
                writer.exited(1)
                assert len([request for _, request in proxy.requests if request["operation"] == "terminal.attach"]) == 2
                assert not proxy.errors, proxy.errors
                print("PASS control event gap: old connections released; one fresh attach/snapshot; new lease and input restored", flush=True)
            finally:
                for host in hosts:
                    host.close()
                if proxy:
                    proxy.close()
                if server.poll() is None:
                    try:
                        cleanup = Client(actual / "session/control.sock", server)
                        success(cleanup.call("server.stop"))
                        cleanup.close()
                        server.wait(timeout=TIMEOUT)
                    except (OSError, AssertionError, subprocess.TimeoutExpired):
                        server.terminate()
                        try:
                            server.wait(timeout=TIMEOUT)
                        except subprocess.TimeoutExpired:
                            server.kill()
                            server.wait(timeout=TIMEOUT)
                if control:
                    control.close()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: attach_resync.py /absolute/path/to/aster-session")
    main(str(Path(sys.argv[1]).resolve()))
