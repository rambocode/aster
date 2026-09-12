"""Real named-session registry integration.

Two named sessions are actually created as independent background services in a
private state parent. Every assertion is about observed reality: real distinct
identities, a real stop that leaves the sibling running, a delete refused while
the session is alive, and the layout snapshot still on disk after a stop.
"""
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid

binary = str(Path(sys.argv[1]).resolve())
TIMEOUT = 20.0


def run(*arguments):
    result = subprocess.run([binary, *arguments], capture_output=True, timeout=TIMEOUT)
    assert result.stdout, (arguments, result.stderr[-400:])
    return result.returncode, json.loads(result.stdout)


def packet(value):
    data = json.dumps(value).encode()
    return struct.pack(">BI", 1, len(data)) + data


def receive(peer, deadline):
    def exact(count):
        data = bytearray()
        while len(data) < count:
            remaining = deadline - time.monotonic()
            assert remaining > 0, "frame deadline exceeded"
            peer.settimeout(remaining)
            part = peer.recv(count - len(data))
            assert part, "premature connection close"
            data.extend(part)
        return bytes(data)
    kind, size = struct.unpack(">BI", exact(5))
    assert kind == 1 and 0 < size <= 1024 * 1024, (kind, size)
    return json.loads(exact(size))


def result(response):
    assert "error" not in response, response
    return response["result"]


def failure(code, response):
    assert response.get("error", {}).get("code") == code, response


parent = tempfile.mkdtemp(prefix="aster-registry-", dir="/tmp")
os.chmod(parent, 0o700)
started = []
try:
    code, alpha = run("session", "create", parent, "alpha")
    assert code == 0, alpha
    alpha = result(alpha)
    started.append("alpha")
    code, beta = run("session", "create", parent, "beta")
    assert code == 0, beta
    beta = result(beta)
    started.append("beta")

    # Independent services: distinct persistent identities and distinct
    # incarnations. A shared identity would mean one process served both names.
    assert alpha["sessionID"] != beta["sessionID"], (alpha, beta)
    assert alpha["serverID"] != beta["serverID"], (alpha, beta)
    assert alpha["serverEpoch"] != beta["serverEpoch"], (alpha, beta)
    assert alpha["state"] == beta["state"] == "running"

    code, listing = run("session", "list", parent)
    assert code == 0
    sessions = {item["name"]: item for item in result(listing)["sessions"]}
    assert set(sessions) == {"alpha", "beta"}, sessions
    assert all(item["state"] == "running" for item in sessions.values()), sessions
    assert sessions["alpha"]["sessionID"] == alpha["sessionID"]

    code, attached = run("session", "attach", parent, beta["sessionID"])
    assert code == 0 and result(attached)["serverEpoch"] == beta["serverEpoch"], attached

    # Give each session a real layout so "stop keeps the snapshot" is observable.
    for name in ("alpha", "beta"):
        code, created = run("workspace", "create", parent, name, "--expected-revision", "0",
                            "--title", name, "--cwd", "/tmp", "--", "/bin/sh", "-c", "sleep 300")
        assert code == 0, created
        assert (Path(parent) / name / "layout.json").exists()

    # Deleting a live session must be refused, and must not disturb it.
    code, refused = run("session", "delete", parent, alpha["sessionID"])
    assert code == 1
    failure("session_running", refused)
    code, still = run("session", "attach", parent, alpha["sessionID"])
    assert result(still)["serverEpoch"] == alpha["serverEpoch"], still

    # Registry scope over a session's own control socket: the same registry, and
    # a request with no target, served by whichever session answered.
    endpoint = Path(parent) / "beta/control.sock"
    peer = socket.socket(socket.AF_UNIX)
    try:
        peer.connect(str(endpoint))
        deadline = time.monotonic() + TIMEOUT
        hello = receive(peer, deadline)
        assert hello["type"] == "hello"
        assert {"session_snapshot", "workspace_mutation"} <= set(hello["capabilities"]), hello
        request = dict(type="request", requestID=str(uuid.uuid4()), clientID=str(uuid.uuid4()),
                       scope="registry", operation="session.list", params={})
        peer.sendall(packet(request))
        response = receive(peer, deadline)
        assert response["requestID"] == request["requestID"], response
        assert "target" not in response and "revision" not in response, response
        over_socket = {item["name"] for item in response["result"]["sessions"]}
        assert over_socket == {"alpha", "beta"}, response

        def registry_call(operation, params):
            message = dict(type="request", requestID=str(uuid.uuid4()), clientID=str(uuid.uuid4()),
                           scope="registry", operation=operation, params=params)
            if operation in {"session.create", "session.stop", "session.delete"}:
                message["createdAtUnixMs"] = time.time_ns() // 1_000_000
            peer.sendall(packet(message))
            reply = receive(peer, time.monotonic() + TIMEOUT)
            assert reply["requestID"] == message["requestID"], reply
            return reply

        # A live service can create, stop and delete a sibling session without
        # forking itself; the new service must be a genuinely separate instance.
        spawned = result(registry_call("session.create", {"name": "gamma"}))
        started.append("gamma")
        assert spawned["state"] == "running" and spawned["serverID"] != beta["serverID"], spawned
        assert result(registry_call("session.stop", {"sessionID": spawned["sessionID"]}))["state"] == "stopped"
        started.remove("gamma")
        assert result(registry_call("session.delete", {"sessionID": spawned["sessionID"]}))["deleted"] is True
        assert not (Path(parent) / "gamma").exists()
        # A session cannot stop itself through the registry: that handshake is
        # the session-scope server.stop, not a registry action.
        failure("invalid_request", registry_call("session.stop", {"sessionID": beta["sessionID"]}))
        # Beta served all of that and is untouched.
        assert result(registry_call("session.attach", {"sessionID": beta["sessionID"]}))["serverEpoch"] == beta["serverEpoch"]
    finally:
        peer.close()

    code, stopped = run("session", "stop", parent, alpha["sessionID"])
    assert code == 0, stopped
    assert result(stopped)["state"] == "stopped", stopped
    started.remove("alpha")

    # Stop is scoped to one session: the sibling keeps the same incarnation and
    # the stopped session keeps its layout snapshot on disk.
    code, sibling = run("session", "attach", parent, beta["sessionID"])
    assert result(sibling)["state"] == "running", sibling
    assert result(sibling)["serverEpoch"] == beta["serverEpoch"], sibling
    assert (Path(parent) / "alpha/layout.json").exists(), "stop must preserve the layout snapshot"
    assert not (Path(parent) / "alpha/control.sock").exists()

    code, deleted = run("session", "delete", parent, alpha["sessionID"])
    assert code == 0 and result(deleted)["deleted"] is True, deleted
    assert not (Path(parent) / "alpha").exists()

    code, remaining = run("session", "list", parent)
    names = {item["name"] for item in result(remaining)["sessions"]}
    assert names == {"beta"}, remaining
    code, unknown = run("session", "attach", parent, alpha["sessionID"])
    assert code == 1
    failure("session_not_found", unknown)

    for name in ("", ".", "..", "a/b"):
        code, rejected = run("session", "create", parent, name)
        assert code == 1, rejected
        assert rejected.get("error", {}).get("code") in {"invalid_request"} or rejected.get("code"), rejected
finally:
    for name in started:
        try:
            subprocess.run([binary, "session", "stop", parent, name], capture_output=True, timeout=TIMEOUT)
        except Exception:
            pass
    shutil.rmtree(parent, ignore_errors=True)

print("session registry: independent services; stop kept layout and sibling; running delete refused")
