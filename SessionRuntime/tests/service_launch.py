"""Daemon start uses private readiness and survives its launching CLI."""
import concurrent.futures
import fcntl
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import tempfile
import time

binary = str(Path(sys.argv[1]).resolve())


def invoke(parent, name="session", action="start", **kwargs):
    result = subprocess.run([binary, "server", action, parent, name], capture_output=True, timeout=8, **kwargs)
    return result, json.loads(result.stdout)


def stop_owned(parent, started):
    # Only test-created PIDs are signalled. Confirm the endpoint still represents
    # the exact epoch returned by this launch before cleanup.
    status, value = invoke(parent, action="status")
    assert status.returncode == 0 and value["target"] == started["status"]["target"]
    result, stopped = invoke(parent, action="stop")
    if result.returncode != 0:
        # Test-only cleanup of the already verified, test-owned process; failure
        # remains a failed test and is never counted as a successful RPC stop.
        os.kill(started["pid"], signal.SIGTERM)
    assert result.returncode == 0 and stopped["type"] == "server_stop", stopped
    assert stopped["state"] == "stopped" and stopped["target"] == started["status"]["target"]
    assert not (Path(parent) / "session/control.sock").exists()



with tempfile.TemporaryDirectory(prefix="aster-launch-", dir="/tmp") as parent:
    read_fd, original_write = os.pipe()
    write_fd = fcntl.fcntl(original_write, fcntl.F_DUPFD, 80)
    os.close(original_write)
    try:
        result, started = invoke(parent, pass_fds=(write_fd,))
        assert result.returncode == 0 and started["state"] == "started", (result.stderr, started)
        os.close(write_fd)
        write_fd = None
        try:
            assert os.getsid(started["pid"]) == started["pid"]
            assert select.select([read_fd], [], [], 1)[0], "daemon retained an unrelated inherited FD"
            assert os.read(read_fd, 1) == b""
            again, existing = invoke(parent, preexec_fn=lambda: signal.signal(signal.SIGCHLD, signal.SIG_IGN))
            assert again.returncode == 0 and existing["state"] == "already_running"
            assert existing["pid"] is None and existing["status"]["target"] == started["status"]["target"]
        finally:
            stop_owned(parent, started)
        result, restarted = invoke(parent)
        assert result.returncode == 0 and restarted["state"] == "started"
        try:
            old, new = started["status"]["target"], restarted["status"]["target"]
            assert old["serverID"] == new["serverID"] and old["sessionID"] == new["sessionID"]
            assert old["serverEpoch"] != new["serverEpoch"]
        finally:
            stop_owned(parent, restarted)
    finally:
        os.close(read_fd)
        if write_fd is not None:
            os.close(write_fd)

with tempfile.TemporaryDirectory(prefix="aster-launch-race-", dir="/tmp") as parent:
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
        results = list(workers.map(lambda _: invoke(parent), range(4)))
    launches = [value for result, value in results if value.get("state") == "started"]
    assert len(launches) == 1, results
    try:
        assert all(result.returncode == 0 for result, _ in results), results
        assert all(value["status"]["target"] == launches[0]["status"]["target"] for _, value in results)
    finally:
        stop_owned(parent, launches[0])

with tempfile.TemporaryDirectory(prefix="aster-launch-failure-", dir="/tmp") as parent:
    state = Path(parent) / "broken"
    state.mkdir(mode=0o700)
    identity = state / "identity.bin"
    identity.write_bytes(b"corrupt")
    identity.chmod(0o600)
    result, value = invoke(parent, "broken")
    assert result.returncode != 0 and value["code"] == "ServiceInitializationFailed", value
    assert identity.read_bytes() == b"corrupt" and not (state / "control.sock").exists()
    waiting = Path(parent) / "waiting"
    waiting.mkdir(mode=0o700)
    with (waiting / "server.lock").open("wb") as lock:
        os.chmod(lock.name, 0o600)
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        result, value = invoke(parent, "waiting")
        assert result.returncode != 0 and value["code"] == "StartupOutcomeUnknown", value
        assert not (waiting / "control.sock").exists()
print("daemon start: detached I/O, readiness verification, reuse, concurrent start and failures passed")
