"""Real event subscription against a live background session.

Nothing here is simulated. A real named session runs in the background, real
structural transactions launch real PTY processes, and the events are read from
a separate `aster-session event subscribe` process over a pipe — the same argv
the app forwards over SSH. The test proves the stream is ordered and contiguous,
that a second subscription restarts its own sequence at 1, and that killing a
subscriber leaves the service and its running terminals untouched.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time

binary = str(Path(sys.argv[1]).resolve())
TIMEOUT = 20.0
HOLD = ["/bin/sh", "-c", "while :; do sleep 1; done"]


def run(*arguments):
    result = subprocess.run([binary, *arguments], capture_output=True, timeout=TIMEOUT)
    assert result.stdout, (arguments, result.stderr[-400:])
    return result.returncode, json.loads(result.stdout)


def result(response):
    assert "error" not in response, response
    return response["result"]


def alive(pid):
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False


class Subscriber:
    """One real `event subscribe` child process, read as JSON Lines."""

    def __init__(self, parent, name):
        self.process = subprocess.Popen(
            [binary, "event", "subscribe", parent, name],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.events = []
        self.buffer = bytearray()
        self.sequence = 0
        self.revision = 0
        os.set_blocking(self.process.stdout.fileno(), False)
        self.hello = self.line(TIMEOUT)
        assert self.hello is not None, self.stderr()
        assert self.hello["type"] == "subscribed", self.hello
        for key in ("serverID", "serverEpoch", "sessionID", "revision"):
            assert key in self.hello, self.hello
        self.revision = self.hello["revision"]
        self.target = {key: self.hello[key] for key in ("serverID", "serverEpoch", "sessionID")}

    def line(self, timeout):
        """Pops one complete JSON Lines record, or None once the deadline passes.

        Reads are non-blocking and the leftover bytes stay in this buffer: one
        read can carry several records, and a record can arrive in pieces."""
        deadline = time.monotonic() + timeout
        while True:
            index = self.buffer.find(b"\n")
            if index >= 0:
                text = bytes(self.buffer[:index])
                del self.buffer[:index + 1]
                return json.loads(text)
            if time.monotonic() >= deadline:
                return None
            chunk = self.process.stdout.read(65536)
            if chunk:
                self.buffer.extend(chunk)
                continue
            if chunk == b"" and self.process.poll() is not None:
                return None
            time.sleep(0.01)

    def event(self, timeout=TIMEOUT):
        message = self.line(timeout)
        assert message is not None, ("subscriber produced no event", self.stderr())
        assert message["type"] == "event", message
        assert message["target"] == self.target, message
        # Sequence belongs to this connection, is contiguous, and revision never rewinds.
        assert message["sequence"] == self.sequence + 1, (message, self.sequence)
        assert message["revision"] >= self.revision, (message, self.revision)
        for key in ("eventID", "event", "body"):
            assert key in message, message
        self.sequence = message["sequence"]
        self.revision = message["revision"]
        self.events.append(message)
        return message

    def collect(self, count):
        return [self.event() for _ in range(count)]

    def quiet(self, seconds=0.5):
        assert self.line(seconds) is None, "unexpected extra event"

    def stderr(self):
        try:
            return self.process.stderr.read(4000)
        except Exception:  # pragma: no cover - diagnostics only
            return b""

    def stop(self, sig=signal.SIGTERM):
        if self.process.poll() is None:
            self.process.send_signal(sig)
        code = self.process.wait(timeout=TIMEOUT)
        self.process.stdout.close()
        self.process.stderr.close()
        return code


parent = tempfile.mkdtemp(prefix="aster-events-", dir="/tmp")
os.chmod(parent, 0o700)
running = True
first = None
second = None
try:
    code, session = run("session", "create", parent, "work")
    assert code == 0, session
    assert result(session)["state"] == "running", session

    first = Subscriber(parent, "work")
    code, snapshot = run("session", "snapshot", parent, "work")
    assert first.target == snapshot["target"], (first.target, snapshot["target"])
    assert first.hello["revision"] == snapshot["revision"], (first.hello, snapshot)

    # A real transaction from a completely separate client process.
    code, created = run("workspace", "create", parent, "work", "--expected-revision", "0",
                        "--title", "main", "--cwd", "/tmp", "--", *HOLD)
    assert code == 0, created
    workspace = result(created)
    revision = created["revision"]
    root_pane = workspace["tabs"][0]["layout"]["pane"]

    names = [event["event"] for event in first.collect(2)]
    assert names == ["terminal.created", "workspace.changed"], names
    assert first.events[-1]["body"]["workspaceID"] == workspace["workspaceID"], first.events[-1]
    assert first.revision == revision, (first.revision, revision)

    code, split = run("pane", "split", parent, "work", "--pane", root_pane["paneID"],
                      "--direction", "right", "--expected-revision", str(revision),
                      "--cwd", "/tmp", "--", *HOLD)
    assert code == 0, split
    revision = split["revision"]
    names = [event["event"] for event in first.collect(2)]
    assert names == ["terminal.created", "tab.changed"], names
    assert first.sequence == 4, first.sequence

    code, tab = run("tab", "create", parent, "work", "--workspace", workspace["workspaceID"],
                    "--expected-revision", str(revision), "--title", "second",
                    "--cwd", "/tmp", "--", *HOLD)
    assert code == 0, tab
    revision = tab["revision"]
    names = [event["event"] for event in first.collect(2)]
    assert names == ["terminal.created", "tab.changed"], names
    assert first.sequence == 6, first.sequence
    first.quiet()

    # A second, later connection starts its own sequence at 1 and never inherits
    # the first connection's cursor.
    second = Subscriber(parent, "work")
    assert second.hello["revision"] == revision, (second.hello, revision)
    assert second.target == first.target
    code, renamed = run("tab", "update", parent, "work", "--tab", result(tab)["tabID"],
                        "--expected-revision", str(revision), "--title", "renamed")
    assert code == 0, renamed
    revision = renamed["revision"]
    fresh = second.event()
    assert fresh["sequence"] == 1, fresh
    assert fresh["event"] == "tab.changed", fresh
    assert fresh["body"]["title"] == "renamed", fresh
    later = first.event()
    assert later["sequence"] == 7, later
    assert later["eventID"] == fresh["eventID"], (later, fresh)

    # Terminals that the subscription never touched must keep running.
    code, live = run("session", "snapshot", parent, "work")
    pids = [item["pid"] for item in result(live)["terminals"] if item.get("pid")]
    assert len(pids) == 3, pids
    assert all(alive(pid) for pid in pids), pids

    # A subscriber that goes away is invisible to the service and to the PTYs.
    assert first.stop() == 0, "SIGTERM must be a clean exit"
    first = None
    time.sleep(0.3)
    assert all(alive(pid) for pid in pids), pids
    code, after = run("session", "snapshot", parent, "work")
    assert code == 0, after
    assert after["revision"] == revision, (after, revision)

    # The surviving subscription keeps working after its peer disappeared.
    code, closed = run("tab", "close", parent, "work", "--tab", result(tab)["tabID"],
                       "--expected-revision", str(revision))
    assert code == 0, closed
    revision = closed["revision"]
    tail = [second.event()["event"] for _ in range(1)]
    assert tail == ["workspace.changed"], tail
    assert second.sequence == 2, second.sequence
    assert second.events[-1]["revision"] == revision, (second.events[-1], revision)

    # The closed tab's terminal is reaped next. That is terminal lifecycle, not a
    # layout edit, so the event keeps this connection's sequence contiguous and
    # quotes the *same* layout revision tab.close returned: the revision the
    # client already holds stays usable for its next transaction.
    exited = second.event()
    assert exited["event"] == "terminal.exited", exited
    assert exited["sequence"] == 3, exited
    assert exited["revision"] == revision, (exited, revision)
    code, after_exit = run("session", "snapshot", parent, "work")
    assert after_exit["revision"] == revision, (after_exit, revision)

    assert second.stop(signal.SIGINT) == 0, "SIGINT must be a clean exit"
    second = None

    # A subscription against a session that does not exist fails loudly.
    missing = subprocess.run([binary, "event", "subscribe", parent, "absent"],
                             capture_output=True, timeout=TIMEOUT)
    assert missing.returncode != 0, missing
    assert not missing.stdout, missing.stdout
    assert missing.stderr.strip(), missing

    code, stopped = run("session", "stop", parent, "work")
    assert code == 0, stopped
    running = False
    print("event stream ok")
finally:
    for subscriber in (first, second):
        if subscriber is not None:
            try:
                subscriber.stop(signal.SIGKILL)
            except Exception:
                pass
    if running:
        subprocess.run([binary, "session", "stop", parent, "work"], capture_output=True, timeout=TIMEOUT)
    shutil.rmtree(parent, ignore_errors=True)
