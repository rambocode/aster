"""Real terminal RPC integration. Run with the service binary on the same machine.

Every process and filesystem artifact belongs to this test. No surface protocol is
needed: the test shell records PID, literal input and actual PTY geometry in files.
"""
import base64
import copy
import json
import os
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
import time
import uuid


TIMEOUT = 5.0


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


class Client:
    def __init__(self, endpoint, process, client_id=None):
        self.client_id = client_id or str(uuid.uuid4())
        self.sequence = 0
        self.event_sequence = 0
        self.events = []
        deadline = time.monotonic() + TIMEOUT
        while True:
            assert process.poll() is None, "test-owned service exited before connection"
            self.peer = socket.socket(socket.AF_UNIX)
            self.peer.settimeout(max(0.001, deadline - time.monotonic()))
            try:
                self.peer.connect(str(endpoint))
                break
            except (FileNotFoundError, ConnectionRefusedError):
                self.peer.close()
                assert time.monotonic() < deadline, "service did not become ready"
                time.sleep(0.01)
        self.hello = receive(self.peer, deadline)
        assert self.hello["type"] == "hello"
        assert {"terminal_control", "terminal_observe"} <= set(self.hello["capabilities"]), self.hello
        self.target = {key: self.hello[key] for key in ("serverID", "serverEpoch", "sessionID")}

    def close(self):
        self.peer.close()

    def make(self, operation, params=None, lease=None):
        request = dict(type="request", requestID=str(uuid.uuid4()), clientID=self.client_id,
                       scope="session", operation=operation, target=self.target, params=params or {})
        if operation in {"terminal.create", "terminal.terminate"}:
            request["createdAtUnixMs"] = time.time_ns() // 1_000_000
        if lease is not None:
            self.sequence += 1
            request.update(lease=lease, controlSequence=self.sequence)
        return request

    def send(self, request):
        body = json.dumps(request, separators=(",", ":")).encode()
        self.peer.settimeout(TIMEOUT)
        self.peer.sendall(struct.pack(">BI", 1, len(body)) + body)

    def reply(self, request):
        deadline = time.monotonic() + TIMEOUT
        while True:
            response = receive(self.peer, deadline)
            if response.get("type") == "event":
                assert response["target"] == self.target, response
                assert response["sequence"] == self.event_sequence + 1, response
                self.event_sequence = response["sequence"]
                assert len(self.events) < 10000, "unbounded lifecycle events"
                self.events.append(response)
                continue
            assert response.get("requestID") == request["requestID"], response
            assert response.get("operation") == request["operation"], response
            if response.get("type") == "response":
                assert response.get("target") == request["target"], response
            else:
                assert response.get("type") == "error" and response.get("scope") == request["scope"], response
            assert ("result" in response) != ("error" in response), response
            return response

    def call(self, operation, params=None, lease=None):
        request = self.make(operation, params, lease)
        return self.transact(request)

    def transact(self, request):
        self.send(request)
        return self.reply(request)


def success(response):
    assert "error" not in response, response
    return response["result"]


def failure(response, code):
    assert response.get("error", {}).get("code") == code, response


def eventually(probe, label):
    deadline = time.monotonic() + TIMEOUT
    while time.monotonic() < deadline:
        value = probe()
        if value:
            return value
        time.sleep(0.01)
    raise AssertionError(f"deadline waiting for {label}")


def read_when_present(path):
    try:
        return path.read_text()
    except FileNotFoundError:
        return None


def terminals(client):
    return success(client.call("terminal.list"))["terminals"]


def terminal(client, terminal_id):
    matches = [entry for entry in terminals(client) if entry["terminalID"] == terminal_id]
    assert len(matches) == 1, matches
    return matches[0]


def exited(client, terminal_id):
    record = terminal(client, terminal_id)
    return record if record["state"] == "exited" else None


def main(binary):
    with tempfile.TemporaryDirectory(prefix="aster-terminal-", dir="/tmp") as parent:
        root = Path(parent)
        root.chmod(0o700)
        endpoint = root / "session/control.sock"
        # Keep diagnostics in a file so an unexpected noisy child cannot fill a pipe.
        with (root / "service.stderr").open("wb+") as diagnostics:
            process = subprocess.Popen([binary, "server", "serve", parent, "session"],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                       stderr=diagnostics)
            clients = []
            completed = False
            try:
                first = Client(endpoint, process)
                clients.append(first)
                half = Client(endpoint, process)
                clients.append(half)
                pending = half.make("terminal.create", {"cwd": parent, "argv": ["/bin/sh", "-c", "exit 3"]})
                half.send(pending)
                half.peer.shutdown(socket.SHUT_WR)
                half_created = success(half.reply(pending))
                assert half_created["terminalID"]
                noisy = success(first.call("terminal.create", {"cwd": parent, "argv": ["/bin/sh", "-c", "while :; do printf 'NOISY-OUTPUT-0123456789\\n'; done"]}))
                # CLI preserves literal argv through the wire and remote exec.
                literal = "space ; $(touch MUST_NOT_EXIST)"
                cli = subprocess.run([binary, "terminal", "create", parent, "session", parent,
                                      "/bin/sh", "-c", 'printf "%s" "$1" > cli-argument; read line', "probe", literal],
                                     capture_output=True, text=True, timeout=TIMEOUT)
                assert cli.returncode == 0, cli.stdout + cli.stderr
                cli_record = success(json.loads(cli.stdout))
                eventually(lambda: read_when_present(root / "cli-argument") == literal, "CLI literal argument")
                assert (root / "cli-argument").read_text() == literal
                assert not (root / "MUST_NOT_EXIST").exists()
                listing = subprocess.run([binary, "terminal", "list", parent, "session"], capture_output=True, text=True, timeout=TIMEOUT)
                assert listing.returncode == 0, listing.stdout + listing.stderr
                assert any(t["terminalID"] == cli_record["terminalID"] for t in success(json.loads(listing.stdout))["terminals"])
                stopped = subprocess.run([binary, "terminal", "terminate", parent, "session", cli_record["terminalID"]], capture_output=True, text=True, timeout=TIMEOUT)
                assert stopped.returncode == 0, stopped.stdout + stopped.stderr
                assert success(json.loads(stopped.stdout))["state"] == "exited"
                noise_stopped = success(first.call("terminal.terminate", {"terminalID": noisy["terminalID"]}))
                assert noise_stopped["state"] == "exited"
                baseline_count = len(terminals(first))
                script = ('printf "%s\\n" "$$" >> launches; '
                          'IFS= read -r value; printf "%s" "$value" > input; '
                          'stty size > size; IFS= read -r finish; exit 7')
                create = first.make("terminal.create", {
                    "cwd": parent, "argv": ["/bin/sh", "-c", script],
                    "geometry": {"rows": 24, "columns": 80},
                })
                original = success(first.transact(create))
                terminal_id = original["terminalID"]
                assert original["state"] == "running" and original["pid"] > 0, original
                os.kill(original["pid"], 0)  # Existence check only; never signal a terminal PID.
                launched = eventually(lambda: read_when_present(root / "launches"), "real shell PID")
                assert launched.splitlines() == [str(original["pid"])], launched
                first.close()
                resumed = Client(endpoint, process, create["clientID"])
                clients.append(resumed)
                assert resumed.target == first.target
                for _ in range(20):
                    resumed.close()
                    resumed = Client(endpoint, process, create["clientID"])
                    clients.append(resumed)
                    current = terminal(resumed, terminal_id)
                    assert current["pid"] == original["pid"] and current["state"] == "running", current
                    attachment = success(resumed.call("terminal.attach", {"terminalID": terminal_id}))
                    assert success(resumed.call("terminal.release", {"attachmentID": attachment["attachmentID"]}))["released"]
                listed = terminal(resumed, terminal_id)
                assert listed["pid"] == original["pid"] and listed["state"] == "running", listed
                replay = success(resumed.transact(create))
                assert replay == original, (original, replay)
                queried = success(resumed.call("request.status", {"queriedRequestID": create["requestID"]}))
                assert queried["operation"] == "terminal.create" and queried["state"] == "committed", queried
                assert queried["resourceIDs"] == [terminal_id] and not queried["resourcesInvalidated"], queried
                assert len(terminals(resumed)) == baseline_count + 1
                assert (root / "launches").read_text().splitlines() == [str(original["pid"])]
                conflict = copy.deepcopy(create)
                conflict["params"]["argv"] = ["/bin/sh", "-c", "exit 91"]
                failure(resumed.transact(conflict), "invalid_request")

                second = Client(endpoint, process)
                clients.append(second)
                unrelated_query = success(second.call("request.status", {"queriedRequestID": create["requestID"]}))
                assert unrelated_query["state"] == "unknown" and unrelated_query["resourceIDs"] == [], unrelated_query
                grant = success(resumed.call("terminal.attach", {"terminalID": terminal_id}))
                assert grant["readOnly"] is False
                observed = success(second.call("terminal.observe", {"terminalID": terminal_id}))
                assert observed["readOnly"] is True and "lease" not in observed, observed
                assert observed["currentLeaseEpoch"] == grant["lease"]["leaseEpoch"], observed
                # Possession of another client's token must not make an observer writable.
                bad_input = {"terminalID": terminal_id, "action": "input", "data": "eAo="}
                failure(second.call("terminal.control", bad_input, grant["lease"]), "lease_lost")
                failure(second.call("terminal.attach", {"terminalID": terminal_id}), "lease_busy")

                # Both connections submit CAS against the same observed epoch before
                # either waits for a response; the scheduler may choose either winner.
                params = {"terminalID": terminal_id, "takeover": True,
                          "expectedLeaseEpoch": observed["currentLeaseEpoch"]}
                left = resumed.make("terminal.attach", params)
                right = second.make("terminal.attach", params)
                resumed.send(left)
                second.send(right)
                responses = [(resumed, resumed.reply(left)), (second, second.reply(right))]
                winners = [(client, reply) for client, reply in responses if "result" in reply]
                losers = [reply for _, reply in responses if "error" in reply]
                assert len(winners) == len(losers) == 1, responses
                failure(losers[0], "lease_lost")
                writer, winning_reply = winners[0]
                lease = success(winning_reply)["lease"]
                assert lease["leaseEpoch"] > grant["lease"]["leaseEpoch"]
                failure(resumed.call("terminal.control", bad_input, grant["lease"]), "lease_lost")
                resize = {"terminalID": terminal_id, "action": "resize",
                          "geometry": {"rows": 31, "columns": 97}}
                assert success(writer.call("terminal.control", resize, lease))["accepted"]
                literal = "literal $(echo forbidden); spaces & symbols"
                write = {"terminalID": terminal_id, "action": "input",
                         "data": base64.b64encode((literal + "\n").encode()).decode()}
                assert success(writer.call("terminal.control", write, lease))["accepted"]
                assert eventually(lambda: read_when_present(root / "input"), "literal PTY input") == literal
                actual_size = eventually(lambda: read_when_present(root / "size"), "actual PTY geometry")
                assert actual_size.split() == ["31", "97"], actual_size
                assert success(writer.call("terminal.control", {
                    "terminalID": terminal_id, "action": "input", "data": "ZmluaXNoCg==",
                }, lease))["accepted"]
                ended = eventually(lambda: exited(resumed, terminal_id), "exit code 7")
                assert ended["exitCode"] == 7, ended

                victim = success(resumed.call("terminal.create", {
                    "cwd": parent, "argv": ["/bin/sh", "-c", "exec /bin/sleep 60"],
                }))
                terminate = resumed.make("terminal.terminate", {"terminalID": victim["terminalID"]})
                terminated = success(resumed.transact(terminate))
                assert success(resumed.transact(terminate)) == terminated
                eventually(lambda: exited(resumed, victim["terminalID"]), "terminated process")
                assert len(terminals(resumed)) == baseline_count + 2, "duplicate create/terminate changed terminal inventory"
                # A06.3 retry-window boundary at the real service level: requests older
                # than 24 hours, requests from the future and durable operations without
                # createdAtUnixMs must all be rejected without creating any task. Only the
                # public socket protocol is used; the idempotency log unit tests are not a substitute.
                stale_argv = ["/bin/sh", "-c", "exec /bin/sleep 60"]
                stale = resumed.make("terminal.create", {"cwd": parent, "argv": stale_argv})
                stale["createdAtUnixMs"] = time.time_ns() // 1_000_000 - 24 * 60 * 60 * 1000 - 1
                failure(resumed.transact(stale), "request_expired")
                # Retrying the same expired request stays rejected; a retry never executes it.
                failure(resumed.transact(stale), "request_expired")
                future = resumed.make("terminal.create", {"cwd": parent, "argv": stale_argv})
                future["createdAtUnixMs"] = time.time_ns() // 1_000_000 + 60 * 60 * 1000
                failure(resumed.transact(future), "invalid_request")
                # A missing createdAtUnixMs is an envelope violation: the service closes the
                # connection exactly like a malformed frame, returns no business error and must
                # leave no intent or process behind.
                missing = resumed.make("terminal.create", {"cwd": parent, "argv": stale_argv})
                del missing["createdAtUnixMs"]
                resumed.send(missing)
                try:
                    resumed.reply(missing)
                except AssertionError as closed:
                    assert "premature connection close" in str(closed), closed
                else:
                    raise AssertionError("missing createdAtUnixMs was answered instead of rejected")
                # Rejected requests never reach the intent log or the pool: after reconnecting
                # the inventory is unchanged and request.status reports them as unknown.
                verifier = Client(endpoint, process, resumed.client_id)
                clients.append(verifier)
                assert len(terminals(verifier)) == baseline_count + 2, "rejected stale/future/missing-time requests changed terminal inventory"
                for rejected in (stale, future, missing):
                    unknown = success(verifier.call("request.status", {"queriedRequestID": rejected["requestID"]}))
                    assert unknown["state"] == "unknown", unknown
                assert success(verifier.call("server.stop"))["stopping"]
                process.wait(timeout=TIMEOUT)
                assert process.returncode == 0, process.returncode
                process = subprocess.Popen([binary, "server", "serve", parent, "session"], stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=diagnostics)
                restored = Client(endpoint, process, create["clientID"])
                clients.append(restored)
                old = success(restored.call("request.status", {"queriedRequestID": create["requestID"]}))
                assert old["state"] == "committed" and old["operation"] == "terminal.create", old
                assert old["resourcesInvalidated"] and old["resourceIDs"] == [terminal_id], old
                assert terminals(restored) == [], "request.status restarted old tasks"
                success(restored.call("server.stop"))
                process.wait(timeout=TIMEOUT)
                assert process.returncode == 0
                completed = True
            finally:
                if process.poll() is None:
                    # Normal stop first. The fallback only addresses our Popen child.
                    try:
                        cleanup = Client(endpoint, process)
                        clients.append(cleanup)
                        success(cleanup.call("server.stop"))
                        process.wait(timeout=TIMEOUT)
                    except (OSError, AssertionError, subprocess.TimeoutExpired):
                        process.terminate()
                        try:
                            process.wait(timeout=TIMEOUT)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=TIMEOUT)
                for client in clients:
                    client.close()
                if not completed:
                    diagnostics.seek(0)
                    sys.stderr.write(diagnostics.read(65536).decode(errors="replace"))
    print("terminal service: real PID/exit, reconnect, durable replay/conflict, stale/future/missing-time rejection, lease CAS, literal input and PTY resize passed")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: terminal_service.py /absolute/path/to/aster-session-runtime")
    main(str(Path(sys.argv[1]).resolve()))
