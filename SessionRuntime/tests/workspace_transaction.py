"""Real workspace/tab/pane transactions against a live background session.

Nothing here is simulated: the structural operations launch real PTY processes
whose PIDs this test signals directly, every structural verb is driven through the
real CLI binary, the optimistic-concurrency check is proven by two separate client
processes submitting the same expectedRevision at the same time, and the event
stream is read from a separate, independent control connection.
"""
import json
import os
from pathlib import Path
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid

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


def eventually(probe, label):
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        if probe():
            return
        time.sleep(0.02)
    raise AssertionError(label)


def packet(value):
    data = json.dumps(value).encode()
    return struct.pack(">BI", 1, len(data)) + data


class Observer:
    """Independent control connection used only to read the event stream, so the
    events are observed from outside every process that issues the commands."""

    def __init__(self, endpoint):
        self.peer = socket.socket(socket.AF_UNIX)
        self.peer.connect(str(endpoint))
        self.buffer = bytearray()
        self.events = []
        self.sequence = 0
        self.revision = 0
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
                    body = bytes(self.buffer[5:5 + size])
                    del self.buffer[:5 + size]
                    return json.loads(body)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                return None
            self.peer.settimeout(remaining)
            try:
                part = self.peer.recv(65536)
            except socket.timeout:
                return None
            assert part, "observer connection closed"
            self.buffer.extend(part)

    def drain(self, timeout=0.4):
        while True:
            message = self.next_message(timeout)
            if message is None:
                return
            self.record(message)

    def record(self, message):
        assert message["type"] == "event", message
        # Sequence is contiguous on this connection and revision never rewinds.
        assert message["sequence"] == self.sequence + 1, (message, self.sequence)
        assert message["revision"] >= self.revision, (message, self.revision)
        self.sequence = message["sequence"]
        self.revision = message["revision"]
        self.events.append(message)

    def close(self):
        self.peer.close()


parent = tempfile.mkdtemp(prefix="aster-workspace-", dir="/tmp")
os.chmod(parent, 0o700)
running = True
observer = None
try:
    code, session = run("session", "create", parent, "work")
    assert code == 0, session
    assert result(session)["state"] == "running", session
    observer = Observer(Path(parent) / "work/control.sock")
    code, initial = run("session", "snapshot", parent, "work")
    assert code == 0, initial
    target = initial["target"]

    code, created = run("workspace", "create", parent, "work", "--expected-revision", "0",
                        "--title", "main", "--cwd", "/tmp", "--", *HOLD)
    assert code == 0, created
    workspace = result(created)
    revision = created["revision"]
    # A structural transaction that also launches a terminal advances the layout
    # revision exactly once: the structure changed once, and the terminal it
    # created is not a second layout edit.
    assert revision == 1, created
    root_pane = workspace["tabs"][0]["layout"]["pane"]
    code, snapshot = run("session", "snapshot", parent, "work")
    terminals = {item["terminalID"]: item for item in result(snapshot)["terminals"]}
    first_pid = terminals[root_pane["terminalID"]]["pid"]
    assert alive(first_pid), "workspace.create must launch a real process"
    assert snapshot["revision"] == revision, snapshot

    code, split = run("pane", "split", parent, "work", "--pane", root_pane["paneID"],
                      "--direction", "right", "--expected-revision", str(revision),
                      "--cwd", "/tmp", "--", *HOLD)
    assert code == 0, split
    second = result(split)
    # Same rule for pane.split: one structural change, one revision, even though
    # a real PTY was launched alongside it.
    assert split["revision"] == revision + 1, (split, revision)
    revision = split["revision"]
    second_pid = second["terminal"]["pid"]
    assert second_pid != first_pid and alive(second_pid), split

    # Two independent client processes submit the same expectedRevision at the
    # same moment. Exactly one must be admitted; the other must lose.
    contenders = [
        subprocess.Popen([binary, "pane", "split", parent, "work", "--pane", root_pane["paneID"],
                          "--direction", "down", "--expected-revision", str(revision),
                          "--cwd", "/tmp", "--", *HOLD], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        for _ in range(2)
    ]
    outcomes = []
    for process in contenders:
        out, _ = process.communicate(timeout=TIMEOUT)
        outcomes.append((process.returncode, json.loads(out)))
    winners = [value for code, value in outcomes if code == 0]
    losers = [value for code, value in outcomes if code != 0]
    assert len(winners) == 1 and len(losers) == 1, outcomes
    assert losers[0]["error"]["code"] == "revision_conflict", losers[0]
    # The failure envelope carries the authoritative revision so the loser can
    # retry without guessing, and it must not be the revision it submitted.
    assert losers[0]["currentRevision"] > revision, losers[0]
    assert losers[0]["target"] == target and "result" not in losers[0], losers[0]
    revision = winners[0]["revision"]
    third_pid = winners[0]["result"]["terminal"]["pid"]
    assert alive(third_pid)

    code, resynced = run("session", "snapshot", parent, "work")
    assert code == 0
    fresh_revision = resynced["revision"]
    assert fresh_revision >= losers[0]["currentRevision"], (resynced, losers[0])
    code, retried = run("pane", "split", parent, "work", "--pane", root_pane["paneID"],
                        "--direction", "down", "--expected-revision", str(fresh_revision),
                        "--cwd", "/tmp", "--", *HOLD)
    assert code == 0, retried
    retried_pid = result(retried)["terminal"]["pid"]
    assert alive(retried_pid), retried
    revision = retried["revision"]

    code, snapshot = run("session", "snapshot", parent, "work")
    assert len(result(snapshot)["terminals"]) == 4, snapshot

    observer.drain()
    kinds = [event["event"] for event in observer.events]
    assert kinds.count("terminal.created") == 4, kinds
    assert "workspace.changed" in kinds and "tab.changed" in kinds, kinds
    for event in observer.events:
        assert event["target"] == target, event

    # Closing a pane ends its real process and leaves the siblings running.
    code, closed = run("pane", "close", parent, "work", "--pane", second["pane"]["paneID"],
                       "--expected-revision", str(revision))
    assert code == 0 and result(closed)["closed"] is True, closed
    eventually(lambda: not alive(second_pid), "pane.close must end the real process")
    assert alive(first_pid) and alive(third_pid), "closing one pane must not touch siblings"

    observer.drain()
    assert observer.events[-1]["event"] in {"tab.changed", "workspace.changed", "terminal.exited"}, observer.events[-1]

    # Every remaining structural verb is exercised through the real CLI: rename
    # a workspace/tab/pane, then close a tab and the workspace and prove the
    # managed processes below them actually exit.
    code, snapshot = run("session", "snapshot", parent, "work")
    assert code == 0, snapshot
    revision = snapshot["revision"]
    live_workspace = result(snapshot)["workspaces"][0]
    workspace_id = live_workspace["workspaceID"]
    tab_id = live_workspace["tabs"][0]["tabID"]

    code, renamed = run("workspace", "update", parent, "work", "--workspace", workspace_id,
                        "--expected-revision", str(revision), "--title", "renamed")
    assert code == 0, renamed
    assert result(renamed)["title"] == "renamed", renamed
    assert renamed["revision"] > revision, renamed
    revision = renamed["revision"]

    code, retitled = run("tab", "update", parent, "work", "--tab", tab_id,
                         "--expected-revision", str(revision), "--title", "first-tab")
    assert code == 0, retitled
    assert result(retitled)["title"] == "first-tab", retitled
    assert retitled["revision"] > revision, retitled
    revision = retitled["revision"]

    code, labelled = run("pane", "update", parent, "work", "--pane", root_pane["paneID"],
                         "--expected-revision", str(revision), "--title", "shell")
    assert code == 0, labelled
    assert result(labelled)["title"] == "shell", labelled
    assert labelled["revision"] > revision, labelled
    revision = labelled["revision"]

    # A stale revision must still lose after the updates above bumped it.
    code, stale = run("pane", "update", parent, "work", "--pane", root_pane["paneID"],
                      "--expected-revision", "0", "--title", "stale")
    assert code == 1 and stale["error"]["code"] == "revision_conflict", stale

    # `--expected-revision` is mandatory: a missing flag is a client-side error.
    code, missing = run("tab", "close", parent, "work", "--tab", tab_id)
    assert code == 1 and missing["type"] == "client_error", missing
    assert missing["code"] == "MissingExpectedRevision", missing

    code, extra = run("tab", "create", parent, "work", "--workspace", workspace_id,
                      "--expected-revision", str(revision), "--title", "second",
                      "--cwd", "/tmp", "--", *HOLD)
    assert code == 0, extra
    extra_tab = result(extra)["tabID"]
    revision = extra["revision"]
    code, snapshot = run("session", "snapshot", parent, "work")
    terminals = {item["terminalID"]: item for item in result(snapshot)["terminals"]}
    extra_pid = terminals[result(extra)["layout"]["pane"]["terminalID"]]["pid"]
    assert alive(extra_pid), extra

    code, tab_closed = run("tab", "close", parent, "work", "--tab", extra_tab,
                           "--expected-revision", str(revision))
    assert code == 0 and result(tab_closed)["closed"] is True, tab_closed
    assert tab_closed["revision"] > revision, tab_closed
    revision = tab_closed["revision"]
    eventually(lambda: not alive(extra_pid), "tab.close must end the real process")
    assert alive(first_pid) and alive(third_pid), "closing one tab must not touch the others"
    code, snapshot = run("session", "snapshot", parent, "work")
    tabs = result(snapshot)["workspaces"][0]["tabs"]
    assert [item["tabID"] for item in tabs] == [tab_id], snapshot
    # Reaping the closed tab's terminal must NOT advance the layout revision:
    # the only layout edit here was tab.close itself. If the reap bumped it, the
    # revision the client just received would already be stale and its next
    # legal transaction would lose to a phantom conflict.
    assert snapshot["revision"] == revision, (snapshot, revision)

    # A terminal that exits on its own is not a layout edit either. Create one
    # through a structural verb (one bump), let it die, and prove the layout
    # revision is frozen across the whole reap while terminal.exited is still
    # broadcast with the current revision on a contiguous sequence.
    code, dying = run("tab", "create", parent, "work", "--workspace", workspace_id,
                      "--expected-revision", str(revision), "--title", "short-lived",
                      "--cwd", "/tmp", "--", "/bin/sh", "-c", "exit 3")
    assert code == 0, dying
    assert dying["revision"] == revision + 1, (dying, revision)
    revision = dying["revision"]
    dying_tab = result(dying)["tabID"]
    dying_terminal = result(dying)["layout"]["pane"]["terminalID"]

    def reaped():
        _, current = run("session", "snapshot", parent, "work")
        for item in result(current)["terminals"]:
            if item["terminalID"] == dying_terminal:
                return item["state"] == "exited"
        return False

    eventually(reaped, "the short-lived terminal must be reaped")
    code, after_exit = run("session", "snapshot", parent, "work")
    assert code == 0, after_exit
    assert after_exit["revision"] == revision, (after_exit, revision)

    observer.drain()
    exits = [event for event in observer.events if event["event"] == "terminal.exited"
             and event["body"]["terminalID"] == dying_terminal]
    assert len(exits) == 1, [event["event"] for event in observer.events]
    assert exits[0]["revision"] == revision, (exits[0], revision)
    assert exits[0]["body"]["exitCode"] == 3, exits[0]

    code, dying_closed = run("tab", "close", parent, "work", "--tab", dying_tab,
                             "--expected-revision", str(revision))
    assert code == 0 and result(dying_closed)["closed"] is True, dying_closed
    assert dying_closed["revision"] == revision + 1, (dying_closed, revision)
    revision = dying_closed["revision"]
    code, snapshot = run("session", "snapshot", parent, "work")
    assert snapshot["revision"] == revision, (snapshot, revision)

    code, workspace_closed = run("workspace", "close", parent, "work", "--workspace", workspace_id,
                                 "--expected-revision", str(revision))
    assert code == 0 and result(workspace_closed)["closed"] is True, workspace_closed
    assert workspace_closed["revision"] > revision, workspace_closed
    code, listing = run("workspace", "list", parent, "work")
    assert code == 0 and result(listing)["workspaces"] == [], listing
    for pid in (first_pid, third_pid, retried_pid):
        eventually(lambda pid=pid: not alive(pid), "workspace.close must end every terminal below it")

    observer.drain()
    assert any(event["event"] == "workspace.changed" and event["body"]["tabs"] == []
               for event in observer.events), [event["event"] for event in observer.events]

    code, snapshot = run("session", "snapshot", parent, "work")
    remaining = {item["terminalID"] for item in result(snapshot)["terminals"] if item["state"] == "running"}
    assert second["terminal"]["terminalID"] not in remaining, snapshot
finally:
    if observer is not None:
        observer.close()
    if running:
        subprocess.run([binary, "session", "stop", parent, "work"], capture_output=True, timeout=TIMEOUT)
    shutil.rmtree(parent, ignore_errors=True)

print("workspace transactions: real PTYs, exactly one concurrent winner, contiguous events, real close")
