"""Real session surface protocol, ownership and slow-reader integration checks."""
import base64
import hashlib
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid

from terminal_service import Client, TIMEOUT, eventually, read_when_present, success, terminal


def frame(peer, deadline):
    def exact(length):
        data = bytearray()
        while len(data) < length:
            remaining = deadline - time.monotonic()
            assert remaining > 0, "surface frame deadline exceeded"
            peer.settimeout(remaining)
            part = peer.recv(length - len(data))
            if not part:
                raise EOFError("surface disconnected")
            data.extend(part)
        return bytes(data)
    kind, length = struct.unpack(">BI", exact(5))
    assert kind in (1, 2), kind
    assert 0 < length <= (1024 * 1024 if kind == 1 else 256 * 1024), length
    return kind, exact(length)


def transaction(client, previous=None):
    deadline = time.monotonic() + TIMEOUT
    kind, payload = frame(client.peer, deadline)
    assert kind == 1
    begin = json.loads(payload)
    assert begin["type"] in ("snapshot_begin", "delta_begin"), begin
    delta = begin["type"] == "delta_begin"
    assert 0 < begin["length"] <= 32 * 1024 * 1024, begin
    assert len(begin["sha256"]) == 64 and all(c in "0123456789abcdef" for c in begin["sha256"])
    assert isinstance(begin["sequence"], int) and begin["sequence"] >= 0
    if previous is not None:
        assert begin["sequence"] >= previous, begin
    if delta:
        assert previous is not None and begin["baseSequence"] == previous, begin
        assert begin["sequence"] > previous, begin
    else:
        assert begin.get("baseSequence") is None, begin
    data = bytearray()
    while True:
        kind, payload = frame(client.peer, deadline)
        if kind == 1:
            assert json.loads(payload) == {"type": "delta_end" if delta else "snapshot_end"}
            assert len(data) == begin["length"], begin
            assert hashlib.sha256(data).hexdigest() == begin["sha256"], begin
            return begin["sequence"], bytes(data), delta
        data.extend(payload)
        assert len(data) <= begin["length"], "transaction exceeded declared length"


def rejected(response):
    assert response.get("type") == "error" and response.get("error", {}).get("code"), response


def disconnected(client):
    deadline = time.monotonic() + TIMEOUT
    try:
        while True:
            frame(client.peer, deadline)
    except (EOFError, ConnectionResetError):
        return


def main(binary):
    with tempfile.TemporaryDirectory(prefix="aster-surface-", dir="/tmp") as parent:
        root = Path(parent)
        root.chmod(0o700)
        endpoint = root / "session/control.sock"
        with (root / "service.stderr").open("wb+") as diagnostics:
            process = subprocess.Popen([binary, "server", "serve", parent, "session"],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=diagnostics)
            clients = []
            completed = False
            def connect(client_id=None):
                client = Client(endpoint, process, client_id)
                clients.append(client)
                assert "surface_interest" in client.hello["capabilities"], client.hello
                return client
            try:
                owner_id = str(uuid.uuid4())
                early_surface = connect(owner_id)
                control = connect(owner_id)
                marker = "SURFACE_" + uuid.uuid4().hex
                program = '''import os, sys, tty
from pathlib import Path
tty.setraw(0)
sys.stdout.write("READY"); sys.stdout.flush()
Path("ready").write_text("ready")
for line in sys.stdin:
    value = line.strip()
    if value == "size":
        size = os.get_terminal_size(0)
        Path("size").write_text(f"{size.lines} {size.columns}")
    elif value == "history":
        for i in range(100):
            sys.stdout.write(f"HISTORY{i:04d}\\r\\n")
        sys.stdout.flush()
        Path("history-done").write_text("done")
    elif value == "noise":
        for i in range(20000):
            sys.stdout.write(f"{i:08d}:" + "0123456789" * 20 + "\\r\\n")
        sys.stdout.flush()
        Path("noise-done").write_text("done")
    else:
        sys.stdout.write(value); sys.stdout.flush()
        Path("written").write_text(value)
'''
                geometry = {"rows": 24, "columns": 80}
                created = success(control.call("terminal.create", {
                    "cwd": parent, "argv": [sys.executable, "-u", "-c", program], "geometry": geometry,
                }))
                terminal_id = created["terminalID"]
                eventually(lambda: read_when_present(root / "ready"), "PTY ready")
                attachment = success(control.call("terminal.attach", {"terminalID": terminal_id}))
                params = {"attachmentID": attachment["attachmentID"], "geometry": geometry}
                def input_text(value):
                    assert success(control.call("terminal.control", {
                        "terminalID": terminal_id, "action": "input",
                        "data": base64.b64encode((value + "\n").encode()).decode(),
                    }, attachment["lease"]))["accepted"]

                rejected(control.call("surface.subscribe", params))
                stranger = connect()
                rejected(stranger.call("surface.subscribe", params))
                wrong_size = connect(control.client_id)
                rejected(wrong_size.call("surface.subscribe", {
                    **params, "geometry": {"rows": 31, "columns": 97},
                }))
                input_text("size")
                assert eventually(lambda: read_when_present(root / "size"), "actual PTY geometry").split() == ["24", "80"]

                surface = early_surface
                stream = success(surface.call("surface.subscribe", params))
                assert stream["terminalID"] == terminal_id and stream["streamID"]
                sequence, data, delta = transaction(surface)
                assert not delta and b"READY" in data
                input_text(marker)
                eventually(lambda: read_when_present(root / "written") == marker, "real PTY output")
                deadline = time.monotonic() + TIMEOUT
                while True:
                    sequence, data, _ = transaction(surface, sequence)
                    if marker.encode() in data:
                        break
                    assert time.monotonic() < deadline, "PTY marker missing from surface"
                input_text("history")
                eventually(lambda: read_when_present(root / "history-done"), "history output")
                while True:
                    sequence, data, _ = transaction(surface, sequence)
                    if b"HISTORY0099" in data:
                        break
                assert success(control.call("terminal.control", {"terminalID": terminal_id, "action": "scroll", "rows": -20}, attachment["lease"]))["accepted"]
                sequence, data, delta = transaction(surface, sequence)
                assert not delta and b"HISTORY0060" in data and b"HISTORY0099" not in data, data[-1000:]
                assert success(control.call("terminal.control", {"terminalID": terminal_id, "action": "scroll", "rows": 2147483647}, attachment["lease"]))["accepted"]
                sequence, data, delta = transaction(surface, sequence)
                assert not delta and b"HISTORY0099" in data
                rejected(stranger.call("surface.snapshot", {"streamID": stream["streamID"]}))
                assert success(control.call("surface.snapshot", {"streamID": stream["streamID"]}))["scheduled"]
                sequence, data, delta = transaction(surface, sequence)
                assert not delta and b"HISTORY0099" in data
                assert success(control.call("surface.unsubscribe", {"streamID": stream["streamID"]}))["unsubscribed"]
                disconnected(surface)
                assert success(control.call("health.check"))["alive"]

                surface = connect(control.client_id)
                same_stream = success(surface.call("surface.subscribe", params))
                transaction(surface)
                assert success(surface.call("surface.unsubscribe", {"streamID": same_stream["streamID"]}))["unsubscribed"]
                disconnected(surface)
                surface = connect(control.client_id)
                success(surface.call("surface.subscribe", params))
                transaction(surface)
                assert success(control.call("terminal.release", {"attachmentID": attachment["attachmentID"]}))["released"]
                disconnected(surface)
                assert terminal(control, terminal_id)["state"] == "running"

                # A tiny receive buffer plus unread output creates a slow dedicated
                # peer; control traffic must remain responsive throughout the burst.
                attachment = success(control.call("terminal.attach", {"terminalID": terminal_id}))
                slow = connect(control.client_id)
                slow.peer.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
                success(slow.call("surface.subscribe", {"attachmentID": attachment["attachmentID"], "geometry": geometry}))
                input_text("noise")
                for _ in range(20):
                    success(control.call("health.check"))
                    assert terminal(control, terminal_id)["state"] == "running"
                eventually(lambda: read_when_present(root / "noise-done"), "PTY drained despite slow surface")
                assert success(control.call("server.stop"))["stopping"]
                process.wait(timeout=TIMEOUT)
                assert process.returncode == 0
                completed = True
            finally:
                if process.poll() is None:
                    try:
                        cleanup = Client(endpoint, process)
                        clients.append(cleanup)
                        success(cleanup.call("server.stop"))
                        process.wait(timeout=TIMEOUT)
                    except (OSError, AssertionError, subprocess.TimeoutExpired):
                        process.terminate()
                        try:
                            process.wait(timeout=TIMEOUT)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=TIMEOUT)
                for client in clients:
                    client.close()
                if not completed:
                    diagnostics.seek(0)
                    sys.stderr.write(diagnostics.read(65536).decode(errors="replace"))
    print("surface service: transactions, PTY output, ownership, geometry and slow-reader isolation passed")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: surface_service.py /absolute/path/to/aster-session-runtime")
    main(str(Path(sys.argv[1]).resolve()))
