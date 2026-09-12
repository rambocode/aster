"""An acknowledged stop is not complete until the original instance is gone."""
import fcntl
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
    data = json.dumps(value).encode()
    return struct.pack(">BI", 1, len(data)) + data


def receive(peer):
    def exact(n):
        data = b""
        while len(data) < n:
            part = peer.recv(n - len(data))
            if not part:
                raise EOFError()
            data += part
        return data
    kind, size = struct.unpack(">BI", exact(5))
    assert kind == 1 and size < 1024 * 1024
    return json.loads(exact(size))


for replacement, invalid_ack in [(False, False), (True, False), (False, True)]:
    with tempfile.TemporaryDirectory(prefix="aster-stop-", dir="/tmp") as parent:
        state = Path(parent) / "session"
        state.mkdir(mode=0o700)
        with (state / "server.lock").open("wb") as lock:
            Path(lock.name).chmod(0o600)
            fcntl.flock(lock, fcntl.LOCK_EX)
            listener = socket.socket(socket.AF_UNIX)
            listener.bind(str(state / "control.sock"))
            (state / "control.sock").chmod(0o600)
            listener.listen(8)
            listener.settimeout(0.1)
            done = threading.Event()
            failures, operations = [], []
            hello = dict(type="hello", protocolMajor=1, protocolMinor=0, serverID=str(uuid.uuid4()),
                         serverEpoch=str(uuid.uuid4()), sessionID=str(uuid.uuid4()), platform="linux-x86_64",
                         capabilities=["health_check", "server_lifecycle"])
            original = {key: hello[key] for key in ("serverID", "serverEpoch", "sessionID")}

            def serve():
                while not done.is_set():
                    try:
                        peer, _ = listener.accept()
                    except socket.timeout:
                        continue
                    try:
                        with peer:
                            peer.settimeout(3)
                            peer.sendall(packet(hello))
                            request = receive(peer)
                            operations.append(request["operation"])
                            if request["operation"] == "server.stop":
                                result = {"stopping": not invalid_ack}
                            else:
                                assert request["operation"] == "server.status"
                                result = dict(version="test", protocolMajor=1, protocolMinor=0, capabilities=hello["capabilities"])
                            peer.sendall(packet(dict(type="response", requestID=request["requestID"],
                                operation=request["operation"], scope="session", target=request["target"], revision=0, result=result)))
                            if replacement and request["operation"] == "server.stop":
                                hello["serverEpoch"] = str(uuid.uuid4())
                    except (ConnectionResetError, BrokenPipeError, EOFError):
                        # The shared stop deadline can cancel a status query
                        # after connect but before its response is consumed.
                        continue
                    except BaseException as error:
                        failures.append(error)
                        return

            worker = threading.Thread(target=serve)
            worker.start()
            try:
                result = subprocess.run([binary, "server", "stop", parent, "session"], capture_output=True, timeout=8)
                value = json.loads(result.stdout)
                if invalid_ack:
                    assert result.returncode != 0 and value["code"] == "InvalidServiceStop", value
                elif replacement:
                    assert result.returncode == 0 and value["target"] == original, value
                    assert value["state"] == "stopped"
                else:
                    assert result.returncode != 0 and value["code"] == "ServiceTimedOut", value
                assert operations.count("server.stop") == 1, operations
                if not invalid_ack:
                    assert "server.status" in operations
            finally:
                done.set()
                worker.join(timeout=4)
                listener.close()
            assert not worker.is_alive() and not failures, failures
print("stop confirmation: false acknowledgement rejected; replacement preserved; no mutation retry")

with tempfile.TemporaryDirectory(prefix="aster-stop-slow-", dir="/tmp") as parent:
    launched = subprocess.run([binary, "server", "start", parent, "session"], capture_output=True, timeout=8)
    assert launched.returncode == 0, launched.stdout
    started = json.loads(launched.stdout)
    target = started["status"]["target"]
    slow = socket.socket(socket.AF_UNIX)
    slow.settimeout(3)
    slow.connect(str(Path(parent) / "session/control.sock"))
    receive(slow)
    try:
        def message(operation, params, selected=target):
            return dict(type="request", requestID=str(uuid.uuid4()), clientID=str(uuid.uuid4()),
                        scope="session", operation=operation, target=selected, params=params)
        stale = dict(target, serverEpoch=str(uuid.uuid4()))
        slow.sendall(packet(message("server.stop", {}, stale)))
        assert receive(slow)["error"]["code"] == "stale_server_epoch"
        slow.sendall(packet(message("server.stop", {"unexpected": True})))
        assert receive(slow)["error"]["code"] == "invalid_request"
        slow.sendall(b"".join(packet(message("server.status", {})) for _ in range(500)))
        stopped = subprocess.run([binary, "server", "stop", parent, "session"], capture_output=True, timeout=8)
        assert stopped.returncode == 0, stopped.stdout
        value = json.loads(stopped.stdout)
        assert value["state"] == "stopped" and value["target"] == target
        assert not (Path(parent) / "session/control.sock").exists()
    finally:
        slow.close()
        if (Path(parent) / "session/control.sock").exists():
            # Cleanup is test-owned and is not used to pass the stop assertion.
            import os, signal
            os.kill(started["pid"], signal.SIGTERM)
print("stop drain: stale/invalid requests preserved service; slow connection did not block shutdown")
