"""A04: 20 real SSH detach/reconnect cycles, each with 30 seconds unattended.

Uses P1 terminal.observe over SSH solely as acceptance-test transport. It does
not implement or claim the product's P3 SSH connection management.
"""
import argparse
import json
from pathlib import Path
import re
import select
import shlex
import subprocess
import sys
import tempfile
import time
import uuid


TIMEOUT = 15
CYCLES = 20
DETACH_SECONDS = 30


class Remote:
    def __init__(self, host, binary, parent):
        self.host, self.binary, self.parent = host, binary, parent
        self.ssh = ["ssh", "-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                    "-o", "ControlMaster=no", "-o", "ControlPath=none"]

    def command(self, arguments):
        result = subprocess.run(self.ssh + [self.host, shlex.join(arguments)],
                                stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=TIMEOUT)
        assert result.returncode == 0, (arguments, result.returncode, result.stderr, result.stdout)
        return result.stdout

    def rpc(self, family, action, *arguments):
        reply = json.loads(self.command([self.binary, family, action, self.parent, "session", *arguments]))
        if family == "server" and action == "stop":
            assert reply.get("type") == "server_stop" and reply.get("state") == "stopped", reply
            return reply
        assert "error" not in reply and "result" in reply, reply
        return reply

    def state(self, terminal_id):
        reply = self.rpc("terminal", "list")
        records = reply["result"]["terminals"]
        assert len(records) == 1 and records[0]["terminalID"] == terminal_id, records
        record = records[0]
        assert record["state"] == "running", record
        # Inspect while no observer is connected; kill(pid, 0) never sends a signal.
        status = json.loads(self.command(["python3", "-c",
            "import json,os,pathlib,sys; os.kill(int(sys.argv[2]),0); "
            "p=pathlib.Path(sys.argv[1]); lines=p.read_text().splitlines(); "
            "print(json.dumps(dict(bytes=p.stat().st_size,last=lines[-1],lines=len(lines))))",
            self.parent + "/counter", str(record["pid"])]))
        return {"target": reply["target"], "terminalID": record["terminalID"], "pid": record["pid"], **status}


class Viewer:
    def __init__(self, remote, terminal_id):
        self.remote = remote
        self.terminal_id = terminal_id
        self.pid_file = remote.parent + "/viewer-" + uuid.uuid4().hex + ".pid"
        script = ("stty rows 24 cols 80; printf '%s' \"$$\" > " + shlex.quote(self.pid_file) +
                  "; exec " + shlex.join([remote.binary, "terminal", "observe", remote.parent, "session", terminal_id]))
        self.process = subprocess.Popen(remote.ssh + ["-tt", remote.host, script],
                                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)

    def latest(self, marker, minimum):
        deadline = time.monotonic() + TIMEOUT
        output = bytearray()
        pattern = re.compile(re.escape(marker.encode()) + rb"(\d{12})")
        while True:
            remaining = deadline - time.monotonic()
            assert remaining > 0, f"reconnected viewer did not show counter >= {minimum}: {bytes(output[-2048:])!r}"
            ready, _, _ = select.select([self.process.stdout], [], [], remaining)
            assert ready, "viewer output deadline exceeded"
            chunk = self.process.stdout.read1(65536)
            assert chunk, f"viewer exited: {self.process.poll()}, {bytes(output[-2048:])!r}"
            output.extend(chunk)
            assert len(output) <= 4 * 1024 * 1024, "unbounded viewer output"
            values = [int(match) for match in pattern.findall(output)]
            if values and max(values) >= minimum:
                return max(values)

    def detach(self, method):
        if method == "cli-terminate":
            # The wrapper wrote its PID immediately before exec. Verify the live
            # argv still names this exact test observer before terminating it.
            self.remote.command(["python3", "-c",
                "import os,pathlib,signal,sys; pid=int(pathlib.Path(sys.argv[1]).read_text()); "
                "args=pathlib.Path('/proc/%d/cmdline'%pid).read_bytes().split(bytes([0])); "
                "args=[a for a in args if a]; expected=[sys.argv[2].encode(),b'terminal',b'observe',str(pathlib.Path(sys.argv[1]).parent).encode(),b'session',sys.argv[3].encode()]; "
                "assert os.readlink('/proc/%d/exe'%pid)==str(pathlib.Path(sys.argv[2]).resolve()); "
                "assert args==expected or args==[expected[0]]+expected, (pid,args); "
                "os.kill(pid,signal.SIGTERM)",
                self.pid_file, self.remote.binary, self.terminal_id])
        elif method == "ssh-interrupt":
            self.process.kill()  # Only this test-owned SSH transport process.
        else:
            self.process.stdin.write(b"\x02q")
            self.process.stdin.flush()
        # SSH can still be draining its channel into this PIPE after the CLI
        # exits. Waiting without reading deadlocks once snapshot history grows.
        deadline = time.monotonic() + TIMEOUT
        drained = 0
        while self.process.poll() is None:
            remaining = deadline - time.monotonic()
            assert remaining > 0, f"viewer failed to detach; drained {drained} bytes"
            ready, _, _ = select.select([self.process.stdout], [], [], min(remaining, 0.25))
            if ready:
                chunk = self.process.stdout.read1(65536)
                drained += len(chunk)
                assert drained <= 4 * 1024 * 1024, "unexpected detach output volume"
        result = self.process.returncode
        if method == "normal":
            assert result == 0, result
        self.close()

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=TIMEOUT)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=TIMEOUT)
        self.process.stdin.close()
        self.process.stdout.close()


def main(arguments):
    run_id = "a04-" + uuid.uuid4().hex
    parent = str(Path(arguments.remote_root) / run_id)
    remote = Remote(arguments.host, arguments.binary, parent)
    evidence = Path(arguments.evidence) if arguments.evidence else Path(tempfile.mkdtemp(prefix="aster-a04-"))
    evidence.mkdir(parents=True, exist_ok=True)
    events = (evidence / "events.jsonl").open("a", buffering=1)
    viewer = None
    started = False
    completed = False
    marker = "COUNT:" + run_id[-12:] + ":"
    def record(value):
        events.write(json.dumps({"time": time.time(), **value}) + "\n")
        print(json.dumps(value), flush=True)
    try:
        remote.command(["mkdir", "-m", "700", parent])
        start = json.loads(remote.command([remote.binary, "server", "start", parent, "session"]))
        assert start.get("type") == "server_start" and start.get("state") == "started", start
        started = True
        record({"event": "started", "remoteDirectory": parent, "evidence": str(evidence), "response": start})
        script = ('n=0; while :; do n=$((n+1)); '
                  'printf "%s%012d\\n" "$1" "$n" >> counter; '
                  'printf "%s%012d\\n" "$1" "$n"; sleep 0.2; done')
        created = remote.rpc("terminal", "create", parent, "/bin/sh", "-c", script, "counter", marker)
        terminal_id = created["result"]["terminalID"]
        # SSH command latency normally suffices, but readiness has an explicit bound.
        remote.command(["python3", "-c",
            "import pathlib,sys,time; p=pathlib.Path(sys.argv[1]); end=time.monotonic()+10\n"
            "while not p.exists() or not p.stat().st_size:\n"
            " assert time.monotonic()<end; time.sleep(.01)", parent + "/counter"])
        baseline = remote.state(terminal_id)
        record({"event": "baseline", **baseline})
        viewer = Viewer(remote, terminal_id)
        viewer.latest(marker, int(baseline["last"].split(":")[-1]))
        for cycle in range(1, CYCLES + 1):
            method = "cli-terminate" if cycle == 1 else "ssh-interrupt" if cycle == 2 else "normal"
            before = remote.state(terminal_id)
            viewer.detach(method)
            viewer = None
            detached_at = time.monotonic()
            record({"event": "detached", "cycle": cycle, "method": method, "waitSeconds": DETACH_SECONDS})
            time.sleep(DETACH_SECONDS)
            elapsed = time.monotonic() - detached_at
            assert elapsed >= DETACH_SECONDS
            after = remote.state(terminal_id)
            assert after["target"] == baseline["target"], after
            assert after["terminalID"] == baseline["terminalID"] and after["pid"] == baseline["pid"], after
            assert after["bytes"] > before["bytes"] and after["lines"] > before["lines"], (before, after)
            minimum = int(after["last"].split(":")[-1])
            viewer = Viewer(remote, terminal_id)
            shown = viewer.latest(marker, minimum)
            record({"event": "reconnected", "cycle": cycle, "detachedSeconds": elapsed,
                    "displayedCounter": shown, **after})
        viewer.detach("normal")
        viewer = None
        completed = True
        record({"event": "passed", "cycles": CYCLES, "minimumDetachedSeconds": CYCLES * DETACH_SECONDS})
    finally:
        if viewer is not None:
            viewer.close()
        if started:
            try:
                remote.rpc("server", "stop")
                record({"event": "server-stopped"})
            except Exception as error:
                record({"event": "cleanup-failed", "error": str(error), "remoteDirectory": parent})
                raise
        events.close()
        if completed:
            # This exact randomly-created run directory is the only removal target.
            remote.command(["python3", "-c", "import shutil,sys; shutil.rmtree(sys.argv[1])", parent])
        else:
            print(f"Failure evidence: {evidence}; remote state retained: {parent}", file=sys.stderr)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--host", default="root@ubuntu@orb")
    parser.add_argument("--binary", default="/root/.local/state/aster-test/p1-attach-cli-1a5aea663615/aster-session")
    parser.add_argument("--remote-root", default="/root/.local/state/aster-test")
    parser.add_argument("--evidence", help="local output directory for per-cycle JSON evidence")
    main(parser.parse_args())
