#!/usr/bin/env python3
"""P6.1/P6.4 cold restore integration test.

Verifies that after a server cold restart:
- paneIDs remain stable
- terminalIDs change
- PIDs change
- session.restore creates new terminals for all panes
- Duplicate restore is rejected (alreadyRestored=true)
- Detach-reattach: PID does not change
"""
import json, os, signal, socket, struct, subprocess, sys, tempfile, time
from pathlib import Path

binary = str(Path(sys.argv[1]).resolve())
TIMEOUT = 20.0

def run(*arguments):
    result = subprocess.run([binary, *arguments], capture_output=True, timeout=TIMEOUT)
    assert result.stdout, (arguments, result.stderr[-400:])
    return result.returncode, json.loads(result.stdout)

def packet(value):
    data = json.dumps(value).encode()
    return struct.pack(">BI", 1, len(data)) + data

class Client:
    """Raw control connection for operations not exposed via CLI."""
    def __init__(self, endpoint):
        self.peer = socket.socket(socket.AF_UNIX)
        self.peer.connect(str(endpoint))
        self.buffer = bytearray()
        self.hello = self.next_message(TIMEOUT)
        assert self.hello["type"] == "hello", self.hello
        self.target = {key: self.hello[key] for key in ("serverID", "serverEpoch", "sessionID")}

    def next_message(self, timeout):
        deadline = time.monotonic() + timeout
        while True:
            if len(self.buffer) >= 5:
                kind, size = struct.unpack(">BI", bytes(self.buffer[:5]))
                assert kind == 1 and 0 < size <= 1024 * 1024, (kind, size)
                if len(self.buffer) >= 5 + size:
                    msg = json.loads(bytes(self.buffer[5:5 + size]))
                    del self.buffer[:5 + size]
                    return msg
            remaining = max(0.01, deadline - time.monotonic())
            self.peer.settimeout(remaining)
            try:
                part = self.peer.recv(65536)
            except socket.timeout:
                raise TimeoutError("no message within timeout")
            assert part, "connection closed"
            self.buffer.extend(part)

    def request(self, operation, params, **extra):
        import uuid
        rid = str(uuid.uuid4())
        req = {"type":"request","requestID":rid,"clientID":str(uuid.uuid4()),
               "scope":"session","operation":operation,"target":self.target,"params":params}
        req.update(extra)
        self.peer.sendall(packet(req))
        # Drain events until we get our response/error
        deadline = time.monotonic() + TIMEOUT
        while time.monotonic() < deadline:
            msg = self.next_message(max(0.1, deadline - time.monotonic()))
            if msg.get("type") in ("response", "error"):
                return msg
            # Skip events
        raise TimeoutError(f"no response for {operation}")

    def close(self):
        self.peer.close()

parent = tempfile.mkdtemp(prefix="aster-cold-restore-", dir="/tmp")
os.chmod(parent, 0o700)

try:
    # ── Phase 1: Start server, create layout with terminals ──
    print("Phase 1: Create layout...")
    code, session = run("session", "create", parent, "test")
    assert code == 0, f"session create failed: {session}"

    client1 = Client(Path(parent) / "test/control.sock")
    epoch1 = client1.hello["serverEpoch"]
    caps = client1.hello.get("capabilities", [])
    assert "session_restore" in caps, f"Missing session_restore: {caps}"

    # Create a workspace with a terminal
    ts = int(time.time() * 1000)
    resp = client1.request("workspace.create", {
        "title": "test-ws",
        "terminal": {"cwd": "/tmp", "argv": ["/bin/sh", "-c", "echo ALIVE-$$; sleep 600"]},
    }, expectedRevision=0, createdAtUnixMs=ts)
    assert resp["type"] == "response", f"workspace.create: {resp}"
    workspace = resp["result"]
    pane1_id = workspace["tabs"][0]["layout"]["pane"]["paneID"]
    terminal1_id = workspace["tabs"][0]["layout"]["pane"]["terminalID"]
    print(f"  pane={pane1_id[:8]}... terminal={terminal1_id[:8]}...")

    # Wait for terminal
    time.sleep(0.5)
    resp = client1.request("terminal.list", {})
    terminals = resp["result"]["terminals"]
    running = [t for t in terminals if t["state"] == "running"]
    assert len(running) >= 1, f"No running terminals: {terminals}"
    pid1 = running[0].get("pid")
    print(f"  PID1={pid1}")

    client1.close()

    # ── Phase 2: Stop server (cold restart) ──
    print("Phase 2: Stop server...")
    code, stop_resp = run("session", "stop", parent, "test")
    time.sleep(0.5)

    # Verify layout.json persisted
    layout_path = Path(parent) / "test/layout.json"
    assert layout_path.exists(), "layout.json missing after stop"
    saved = json.loads(layout_path.read_text())
    assert saved["version"] == 1
    print(f"  layout.json: version={saved['version']}, revision={saved['revision']}")

    # ── Phase 3: Cold restart and restore ──
    print("Phase 3: Cold restart and restore...")
    code, start_resp = run("server", "start", parent, "test")
    assert code == 0, f"server start failed: {start_resp}"
    time.sleep(0.3)

    client2 = Client(Path(parent) / "test/control.sock")
    epoch2 = client2.hello["serverEpoch"]
    assert epoch2 != epoch1, f"Epoch did not change: {epoch1} == {epoch2}"
    print(f"  epoch1={epoch1[:8]}... epoch2={epoch2[:8]}... (different: OK)")

    # Snapshot should show layout with stable paneIDs
    resp = client2.request("session.snapshot", {})
    assert resp["type"] == "response", f"snapshot: {resp}"
    snapshot = resp["result"]
    ws = snapshot["workspaces"][0]
    pane2_id = ws["tabs"][0]["layout"]["pane"]["paneID"]
    assert pane2_id == pane1_id, f"paneID changed: {pane1_id} -> {pane2_id}"
    print(f"  paneID stable: {pane2_id[:8]}... (OK)")

    # Send session.restore
    resp = client2.request("session.restore", {
        "geometry": {"rows": 24, "columns": 80},
    })
    assert resp["type"] == "response", f"session.restore: {resp}"
    result = resp["result"]
    assert result["alreadyRestored"] == False
    entries = result["entries"]
    assert len(entries) >= 1, f"No entries: {entries}"
    entry = entries[0]
    assert entry["paneID"] == pane1_id
    assert entry["oldTerminalID"] == terminal1_id
    new_terminal_id = entry["newTerminalID"]
    assert new_terminal_id != terminal1_id, "Terminal ID did not change"
    assert entry["path"] == "new_shell"
    print(f"  Restored: old_tid={terminal1_id[:8]}... new_tid={new_terminal_id[:8]}... path={entry['path']}")

    # Wait for new terminal
    time.sleep(0.5)
    resp = client2.request("terminal.list", {})
    terminals2 = resp["result"]["terminals"]
    running2 = [t for t in terminals2 if t["state"] == "running"]
    assert len(running2) >= 1, f"No running terminals after restore"
    pid2 = running2[0].get("pid")
    assert pid2 != pid1, f"PID did not change: {pid1} == {pid2}"
    print(f"  PID2={pid2} (different from PID1={pid1}: OK)")

    # ── Phase 4: Duplicate restore rejected ──
    print("Phase 4: Duplicate restore...")
    resp = client2.request("session.restore", {
        "geometry": {"rows": 24, "columns": 80},
    })
    assert resp["type"] == "response", f"dup restore: {resp}"
    assert resp["result"]["alreadyRestored"] == True
    print(f"  alreadyRestored=true (OK)")

    # ── Phase 5: Detach-reattach PID stable ──
    print("Phase 5: Detach-reattach PID stability...")
    client2.close()
    time.sleep(0.3)
    client3 = Client(Path(parent) / "test/control.sock")
    assert client3.hello["serverEpoch"] == epoch2, "Epoch should NOT change on reconnect"
    resp = client3.request("terminal.list", {})
    running3 = [t for t in resp["result"]["terminals"] if t["state"] == "running"]
    assert len(running3) >= 1
    pid3 = running3[0].get("pid")
    assert pid3 == pid2, f"PID changed on reconnect: {pid2} -> {pid3}"
    print(f"  PID3={pid3} (same as PID2: OK)")

    client3.close()
    run("session", "stop", parent, "test")

    print("\nPASS: Cold restart PID changes, detach-reattach PID stable, paneID stable, duplicate restore rejected")

finally:
    # Cleanup
    import shutil
    subprocess.run([binary, "session", "stop", parent, "test"], capture_output=True, timeout=5)
    time.sleep(0.3)
    shutil.rmtree(parent, ignore_errors=True)
