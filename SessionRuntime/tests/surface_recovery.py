"""Focused real-service delta and slow-surface transaction deadline evidence."""
import base64
import json
import os
from pathlib import Path
import select
import socket
import subprocess
import sys
import tempfile
import time
import uuid

from terminal_service import Client, eventually, read_when_present, success, terminal
from surface_service import frame, transaction


def main(binary):
    with tempfile.TemporaryDirectory(prefix="aster-surface-recovery-", dir="/tmp") as directory:
        root = Path(directory)
        root.chmod(0o700)
        stderr = (root / "stderr").open("wb+")
        process = subprocess.Popen([binary, "server", "serve", directory, "session"],
                                   stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=stderr)
        clients = []
        watcher = None
        try:
            endpoint = root / "session/control.sock"
            owner = str(uuid.uuid4())
            def connect():
                client = Client(endpoint, process, owner)
                clients.append(client)
                return client
            control = connect()
            def create(label, geometry):
                folder = root / label
                folder.mkdir()
                program = '''import os, sys, tty
from pathlib import Path
tty.setraw(0)
Path("pid").write_text(str(os.getpid()))
print("READY", end="", flush=True)
for line in sys.stdin:
 value=line.strip()
 if value=="large":
  for row in range(256):
   sys.stdout.write("\\x1b[%d;1H" % (row+1))
   for col in range(256):
    sys.stdout.write("\\x1b[%dmX" % (31+(col%2)))
  sys.stdout.write("\\x1b[0m")
 else:
  sys.stdout.write(value)
 sys.stdout.flush()
 Path("written").write_text(value)
'''
                created = success(control.call("terminal.create", {"cwd": str(folder), "argv": [sys.executable, "-u", "-c", program], "geometry": geometry}))
                tid = created["terminalID"]
                eventually(lambda: read_when_present(folder / "pid"), "child pid")
                attachment = success(control.call("terminal.attach", {"terminalID": tid}))
                return tid, attachment, folder
            def send(tid, attachment, text):
                success(control.call("terminal.control", {"terminalID": tid, "action": "input", "data": base64.b64encode((text+"\n").encode()).decode()}, attachment["lease"]))
            geometry = {"rows": 24, "columns": 80}
            tid, attachment, folder = create("fast", geometry)
            surface = connect()
            success(surface.call("surface.subscribe", {"attachmentID": attachment["attachmentID"], "geometry": geometry}))
            sequence, data, delta = transaction(surface)
            assert not delta and b"READY" in data
            time.sleep(0.1)  # let the initial end frame drain and be acknowledged
            marker = "DELTA_" + uuid.uuid4().hex
            send(tid, attachment, marker)
            next_sequence, data, delta = transaction(surface, sequence)
            assert delta, "safe output incorrectly fell back to snapshot"
            assert marker.encode() in data and next_sequence > sequence
            print(json.dumps({"evidence": "strict_delta", "base": sequence, "sequence": next_sequence}), flush=True)

            big_geometry = {"rows": 256, "columns": 256}
            slow_tid, slow_attachment, slow_folder = create("slow", big_geometry)
            send(slow_tid, slow_attachment, "large")
            eventually(lambda: read_when_present(slow_folder / "written") == "large", "large PTY output drained")
            time.sleep(0.3)
            slow = connect()
            slow.peer.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 1024)
            success(slow.call("surface.subscribe", {"attachmentID": slow_attachment["attachmentID"], "geometry": big_geometry}))
            kind, payload = frame(slow.peer, time.monotonic() + 5)
            begin = json.loads(payload)
            assert kind == 1 and begin["type"] == "snapshot_begin", begin
            assert begin["length"] > 256 * 1024, begin
            started = time.monotonic()
            print(json.dumps({"evidence": "slow_begin", "monotonic": started, "length": begin["length"], "receive_buffer": slow.peer.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)}), flush=True)
            if hasattr(select, "kqueue"):
                watcher = select.kqueue()
                watcher.control([select.kevent(slow.peer.fileno(), filter=select.KQ_FILTER_READ, flags=select.KQ_EV_ADD)], 0, 0)
                def hungup():
                    return any(event.flags & select.KQ_EV_EOF for event in watcher.control(None, 8, 0))
            else:
                watcher = select.poll()
                watcher.register(slow.peer, select.POLLHUP | select.POLLERR)
                def hungup():
                    return any(events & (select.POLLHUP | select.POLLERR) for _, events in watcher.poll(0))
            interactions = 0
            while not hungup():
                assert time.monotonic() - started < 38, "slow transaction was not disconnected at 30 seconds"
                check = "LIVE_" + str(interactions)
                sent = time.monotonic()
                send(tid, attachment, check)
                eventually(lambda: read_when_present(folder / "written") == check, "other PTY still interactive")
                success(control.call("health.check"))
                assert time.monotonic() - sent < 5
                if interactions % 10 == 0:
                    success(control.call("terminal.control", {"terminalID": slow_tid, "action": "input", "data": ""}, slow_attachment["lease"]))
                interactions += 1
                time.sleep(1)
            observed = time.monotonic()
            assert 28 <= observed - started <= 38, observed - started
            # Drain only after the hangup event: reading before it would relieve
            # the backpressure whose fixed transaction deadline is under test.
            drained = 0
            slow.peer.settimeout(5)
            while True:
                try:
                    part = slow.peer.recv(65536)
                except ConnectionResetError:
                    break
                if not part:
                    break
                drained += len(part)
            assert drained < begin["length"], "snapshot had fully drained despite alleged backpressure"
            for child in (folder, slow_folder):
                os.kill(int((child / "pid").read_text()), 0)
            assert terminal(control, slow_tid)["state"] == "running"
            print(json.dumps({"evidence": "slow_eof", "monotonic": observed, "elapsed": observed-started, "drained": drained, "interactions": interactions}), flush=True)
            recovered = "RECOVERED_" + uuid.uuid4().hex
            send(slow_tid, slow_attachment, recovered)
            eventually(lambda: read_when_present(slow_folder / "written") == recovered, "same slow PTY remains interactive")
            replacement = connect()
            success(replacement.call("surface.subscribe", {"attachmentID": slow_attachment["attachmentID"], "geometry": big_geometry}))
            _, data, delta = transaction(replacement)
            assert not delta and recovered.encode() in data, "recovery must begin with complete fresh snapshot"
            print(json.dumps({"evidence": "resubscribe_snapshot", "marker": recovered}), flush=True)
        finally:
            for client in clients:
                client.close()
            if watcher is not None and hasattr(watcher, "close"):
                watcher.close()
            process.terminate()
            try:
                process.wait(timeout=8)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
            stderr.seek(0)
            diagnostics = stderr.read().decode(errors="replace")
            if diagnostics:
                print(diagnostics, file=sys.stderr)
            stderr.close()


if __name__ == "__main__":
    main(str(Path(sys.argv[1]).resolve()))
