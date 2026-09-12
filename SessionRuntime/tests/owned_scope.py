"""Real same-session process-group cleanup, with an unrelated PTY control."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

from terminal_service import Client, TIMEOUT, eventually, success, terminal


PROGRAM = r'''
import json, os, pathlib, signal, sys, time
root = pathlib.Path(sys.argv[1])
def record(name):
    value = dict(pid=os.getpid(), sid=os.getsid(0), pgid=os.getpgrp())
    temporary = root / (name + ".tmp")
    temporary.write_text(json.dumps(value))
    temporary.rename(root / (name + ".json"))
signal.signal(signal.SIGTERM, lambda *_: os._exit(0))
signal.signal(signal.SIGHUP, lambda *_: os._exit(0))
signal.signal(signal.SIGTTOU, signal.SIG_IGN)
record("root")
children = []
for name in ("foreground", "background", "same-group"):
    pid = os.fork()
    if pid == 0:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGHUP, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        if name != "same-group": os.setpgid(0, 0)
        record(name)
        while True: time.sleep(.05)
    children.append(pid)
deadline = time.monotonic() + 5
while not all((root / (name + ".json")).exists() for name in ("foreground", "background", "same-group")):
    assert time.monotonic() < deadline
    time.sleep(.01)
os.tcsetpgrp(0, children[0])
(root / "ready").write_text(str(os.tcgetpgrp(0)))
while not (root / "exit").exists(): time.sleep(.01)
os._exit(7)
'''


def process_table():
    result = subprocess.run(["ps", "-axo", "pid=,stat="], capture_output=True, text=True, timeout=TIMEOUT)
    assert result.returncode == 0, result.stderr
    return {int(parts[0]): parts[1] for line in result.stdout.splitlines() if len(parts := line.split()) >= 2}


def live_members(sid):
    members = []
    for pid, state in process_table().items():
        if state.startswith("Z"):
            continue
        try:
            if os.getsid(pid) == sid:
                members.append(pid)
        except ProcessLookupError:
            pass
    return members


def assert_clean(records):
    root = records["root"]
    assert not live_members(root["sid"]), records
    # Orphan children may briefly remain zombies under the host's init. The PTY
    # root is the runtime's direct child and must already have been reaped.
    assert root["pid"] not in process_table(), "runtime did not reap its direct PTY child"


def main(binary):
    with tempfile.TemporaryDirectory(prefix="aster-owned-scope-", dir="/tmp") as parent:
        root = Path(parent)
        root.chmod(0o700)
        endpoint = root / "session/control.sock"
        peers = []
        fixtures = []
        completed = False
        with (root / "service.stderr").open("wb+") as diagnostics:
            process = subprocess.Popen([binary, "server", "serve", parent, "session"],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=diagnostics)
            def connect():
                client = Client(endpoint, process)
                peers.append(client)
                return client
            try:
                control = connect()
                other = success(control.call("terminal.create", {
                    "cwd": parent, "argv": ["/bin/sleep", "60"],
                }))
                def isolated():
                    current = terminal(control, other["terminalID"])
                    assert current["pid"] == other["pid"] and current["state"] == "running", current

                for mode in ("terminate", "natural"):
                    folder = root / mode
                    folder.mkdir(mode=0o700)
                    fixtures.append(folder)
                    created = success(control.call("terminal.create", {
                        "cwd": parent, "argv": [sys.executable, "-u", "-c", PROGRAM, str(folder)],
                    }))
                    terminal_id = created["terminalID"]
                    eventually(lambda: (folder / "ready").exists(), "forked process-group readiness")
                    records = {name: json.loads((folder / (name + ".json")).read_text())
                               for name in ("root", "foreground", "background", "same-group")}
                    leader = records["root"]
                    assert leader["pid"] == created["pid"] == leader["sid"] == leader["pgid"]
                    assert {value["sid"] for value in records.values()} == {leader["sid"]}
                    assert records["same-group"]["pgid"] == leader["pgid"]
                    assert records["foreground"]["pgid"] == records["foreground"]["pid"]
                    assert records["background"]["pgid"] == records["background"]["pid"]
                    assert int((folder / "ready").read_text()) == records["foreground"]["pgid"]
                    assert set(live_members(leader["sid"])) == {value["pid"] for value in records.values()}
                    if mode == "terminate":
                        response = success(control.call("terminal.terminate", {"terminalID": terminal_id}))
                        assert response["state"] == "exited", response
                        # Successful terminate may not precede cleanup/EOF.
                        assert_clean(records)
                    else:
                        (folder / "exit").touch()
                        def ended():
                            current = terminal(control, terminal_id)
                            assert current["state"] in ("running", "terminating", "exited"), current
                            return current if current["state"] == "exited" else None
                        ended_record = eventually(ended, "natural root exit and owned-scope cleanup")
                        assert ended_record["exitCode"] == 7, ended_record
                        assert_clean(records)
                    isolated()
                    def exit_event():
                        success(control.call("health.check"))
                        matches = [event for event in control.events if event.get("event") == "terminal.exited"
                                   and event["body"].get("terminalID") == terminal_id]
                        assert len(matches) <= 1, matches
                        return matches
                    eventually(exit_event, "single terminal.exited notification")
                    # More reactor turns must not report a duplicate exit.
                    for _ in range(3):
                        assert len(exit_event()) == 1
                    print(f"owned scope: {mode} cleaned foreground/background/same-group; unrelated PID preserved", flush=True)

                assert success(control.call("server.stop"))["stopping"]
                process.wait(timeout=TIMEOUT)
                assert process.returncode == 0
                completed = True
            finally:
                if process.poll() is None:
                    try:
                        cleanup = connect()
                        success(cleanup.call("server.stop"))
                        process.wait(timeout=TIMEOUT)
                    except (OSError, AssertionError, subprocess.TimeoutExpired):
                        process.terminate()
                        try:
                            process.wait(timeout=TIMEOUT)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=TIMEOUT)
                # A failing cleanup implementation must not leak test children.
                # Only recorded PIDs whose original SID and PGID still match may
                # be signaled; never broaden this to a process-name/group kill.
                if not completed:
                    for folder in fixtures:
                        for path in folder.glob("*.json"):
                            record = json.loads(path.read_text())
                            try:
                                if (os.getsid(record["pid"]) == record["sid"] and
                                        os.getpgid(record["pid"]) == record["pgid"]):
                                    os.kill(record["pid"], signal.SIGKILL)
                            except ProcessLookupError:
                                pass
                for peer in peers:
                    peer.close()
                if not completed:
                    diagnostics.seek(0)
                    sys.stderr.write(diagnostics.read(65536).decode(errors="replace"))
    print("owned scope: terminate and natural exit clean all same-SID groups exactly once")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: owned_scope.py /absolute/path/to/aster-session-runtime")
    main(str(Path(sys.argv[1]).resolve()))
