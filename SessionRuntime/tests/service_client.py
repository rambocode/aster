"""Status CLI failures against controlled same-user Unix listeners."""
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import uuid

binary = str(Path(sys.argv[1]).resolve())


def packet(value):
    body = json.dumps(value).encode()
    return struct.pack(">BI", 1, len(body)) + body


def request(peer):
    def exact(n):
        data = b""
        while len(data) < n:
            part = peer.recv(n - len(data))
            if not part:
                raise EOFError()
            data += part
        return data
    kind, count = struct.unpack(">BI", exact(5))
    assert kind == 1 and count < 1024 * 1024
    return json.loads(exact(count))


def exercise(mode, code):
    with tempfile.TemporaryDirectory(prefix="aster-client-", dir="/tmp") as parent:
        state = Path(parent) / "session"
        state.mkdir(mode=0o700)
        path = state / "control.sock"
        listener = socket.socket(socket.AF_UNIX)
        listener.bind(str(path))
        path.chmod(0o600)
        listener.listen(1)
        listener.settimeout(5)
        finished = threading.Event()
        failures = []
        hello = dict(type="hello", protocolMajor=1, protocolMinor=0,
                     serverID=str(uuid.uuid4()), serverEpoch=str(uuid.uuid4()), sessionID=str(uuid.uuid4()),
                     platform="linux-x86_64", capabilities=["health_check"])

        if mode in ("reordered_capabilities", "duplicate_capabilities"):
            hello["capabilities"] = ["health_check", "optional_one"]
        if mode == "future_fields":
            hello["future"] = {"value": True}

        def serve():
            try:
                with listener.accept()[0] as peer:
                    peer.settimeout(5)
                    if mode == "silent":
                        finished.wait(4)
                        return
                    if mode == "oversized":
                        peer.sendall(struct.pack(">BI", 1, 1024 * 1024 + 1))
                        return
                    if mode == "incompatible":
                        hello["protocolMajor"] = 2
                        peer.sendall(packet(hello))
                        return
                    if mode == "missing_capability":
                        hello["capabilities"] = []
                        peer.sendall(packet(hello))
                        return
                    if mode == "delayed_reply":
                        finished.wait(1.8)
                    peer.sendall(packet(hello))
                    value = request(peer)
                    if mode == "delayed_reply" and finished.wait(1.8):
                        return
                    response = dict(type="response", requestID=value["requestID"], operation="server.status", scope="session",
                                    target=value["target"], revision=0,
                                    result=dict(version="test", protocolMajor=1, protocolMinor=0, capabilities=["health_check"]))
                    if mode == "request":
                        response["requestID"] = str(uuid.uuid4())
                    elif mode == "target":
                        response["target"]["serverEpoch"] = str(uuid.uuid4())
                    elif mode == "capabilities":
                        response["result"]["capabilities"] = ["terminal_control"]
                    elif mode == "reordered_capabilities":
                        response["result"]["capabilities"] = ["optional_one", "health_check"]
                    elif mode == "duplicate_capabilities":
                        response["result"]["capabilities"] = ["health_check", "health_check"]
                    elif mode == "future_fields":
                        response["result"]["future"] = True
                    elif mode == "mixed":
                        response["error"] = {"code": "internal_error", "message": "bad", "retry": "never"}
                    elif mode == "missing_fields":
                        response["result"] = {}
                    elif mode == "failure":
                        response = dict(type="error", requestID=value["requestID"], operation="server.status", scope="session",
                                        error=dict(code="resource_limit", message="busy", retry="backoff"))
                    peer.sendall(packet(response))
            except BaseException as error:
                failures.append(error)

        worker = threading.Thread(target=serve)
        worker.start()
        try:
            result = subprocess.run([binary, "server", "status", parent, "session"], capture_output=True, timeout=5)
            value = json.loads(result.stdout)
            if code is None:
                assert result.returncode == 0 and value["type"] == "response", value
            elif mode == "failure":
                assert result.returncode != 0
                assert value["type"] == "error" and value["error"]["code"] == code, value
            else:
                assert result.returncode != 0
                assert value == {"type": "client_error", "code": code}, value
        finally:
            finished.set()
            worker.join(timeout=6)
            listener.close()
        assert not worker.is_alive() and not failures, failures


for mode, code in [("silent", "ServiceTimedOut"), ("delayed_reply", "ServiceTimedOut"), ("oversized", "InvalidServiceFrame"),
                   ("incompatible", "IncompatibleMajor"), ("missing_capability", "MissingCapabilities"),
                   ("request", "RequestMismatch"), ("target", "TargetMismatch"),
                   ("capabilities", "InvalidServiceStatus"), ("duplicate_capabilities", "InvalidServiceStatus"),
                   ("reordered_capabilities", None), ("future_fields", None), ("mixed", "InvalidServiceStatus"),
                   ("missing_fields", "MissingField"), ("failure", "resource_limit")]:
    exercise(mode, code)

with tempfile.TemporaryDirectory(prefix="aster-client-", dir="/tmp") as parent:
    result = subprocess.run([binary, "server", "status", parent, "absent"], capture_output=True, timeout=5)
    assert result.returncode != 0 and json.loads(result.stdout)["type"] == "client_error"
    assert not (Path(parent) / "absent").exists(), "status must not create a service directory"
print("status client: deadline, handshake, reply correlation, errors and read-only lookup passed")
