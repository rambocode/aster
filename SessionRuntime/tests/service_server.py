"""Real foreground service lifecycle; every process and directory is test-owned."""
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid

binary = str(Path(sys.argv[1]).resolve())


def receive(peer):
    def exact(count):
        data = bytearray()
        while len(data) < count:
            part = peer.recv(count - len(data))
            if not part:
                raise AssertionError("premature connection close")
            data.extend(part)
        return bytes(data)
    kind, size = struct.unpack(">BI", exact(5))
    assert kind == 1 and 0 < size <= 1024 * 1024
    return json.loads(exact(size))


def request(peer, hello, operation="health.check", target=None):
    identity = target or {key: hello[key] for key in ("serverID", "serverEpoch", "sessionID")}
    value = dict(type="request", requestID=str(uuid.uuid4()), clientID=str(uuid.uuid4()),
                 scope="session", operation=operation, target=identity, params={})
    body = json.dumps(value).encode()
    peer.sendall(struct.pack(">BI", 1, len(body)) + body)
    response = receive(peer)
    assert response["requestID"] == value["requestID"] and response["operation"] == operation
    return response


def connect(path, process):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        assert process.poll() is None, process.stderr.read().decode() if process.poll() is not None else ""
        peer = socket.socket(socket.AF_UNIX)
        peer.settimeout(3)
        try:
            peer.connect(str(path))
            hello = receive(peer)
            assert hello["type"] == "hello" and set(hello["capabilities"]) == {"health_check", "server_lifecycle", "terminal_control", "terminal_observe", "surface_interest"}
            return peer, hello
        except (FileNotFoundError, ConnectionRefusedError):
            peer.close()
            time.sleep(0.01)
    raise AssertionError("service did not become ready")


def stop(process):
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
            raise AssertionError("service did not stop gracefully")
    assert process.returncode == 0, process.stderr.read().decode()
    process.stderr.close()


with tempfile.TemporaryDirectory(prefix="aster-server-", dir="/tmp") as parent:
    endpoint = Path(parent) / "session/control.sock"
    command = [binary, "server", "serve", parent, "session"]
    Path(parent).chmod(0o755)
    unsafe = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
    assert unsafe.returncode != 0 and b"UnsafeStateParent" in unsafe.stderr
    assert not endpoint.exists()
    Path(parent).chmod(0o700)
    first = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        peer, hello = connect(endpoint, first)
        assert request(peer, hello)["result"] == {"alive": True}
        status = subprocess.run([binary, "server", "status", parent, "session"], capture_output=True, timeout=5)
        assert status.returncode == 0, status.stderr
        status_value = json.loads(status.stdout)
        assert status_value["operation"] == "server.status"
        assert status_value["target"] == {key: hello[key] for key in ("serverID", "serverEpoch", "sessionID")}
        assert set(status_value["result"]["capabilities"]) == {"health_check", "server_lifecycle", "terminal_control", "terminal_observe", "surface_interest"}
        assert request(peer, hello, "server.status")["result"]["protocolMajor"] == 1
        old_target = {key: hello[key] for key in ("serverID", "serverEpoch", "sessionID")}
        stale = dict(old_target, serverEpoch=str(uuid.uuid4()))
        assert request(peer, hello, target=stale)["error"]["code"] == "stale_server_epoch"
        duplicate = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=5)
        assert duplicate.returncode != 0
        assert request(peer, hello)["result"]["alive"]
        bad, _ = connect(endpoint, first)
        bad.sendall(struct.pack(">BI", 2, 1) + b"x")
        assert bad.recv(1) == b""
        bad.close()
        assert request(peer, hello)["result"]["alive"]
        peer.close()
        again, same = connect(endpoint, first)
        assert all(same[key] == hello[key] for key in old_target)
        again.close()
    finally:
        stop(first)
    assert not endpoint.exists()
    second = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    try:
        peer, current = connect(endpoint, second)
        assert current["serverID"] == hello["serverID"] and current["sessionID"] == hello["sessionID"]
        assert current["serverEpoch"] != hello["serverEpoch"]
        assert request(peer, current, target=old_target)["error"]["code"] == "stale_server_epoch"
        assert request(peer, current)["result"]["alive"]
        peer.close()
    finally:
        stop(second)
    assert not endpoint.exists()
print("foreground service: health, reconnect, isolation, duplicate start, graceful stop and stable identity passed")
