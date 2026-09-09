"""Real 15-second lease inactivity expiry, independent of observer traffic."""
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from terminal_service import Client, TIMEOUT, failure, success


def wait_until(deadline):
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return
        time.sleep(min(remaining, 3.0))


def main(binary):
    with tempfile.TemporaryDirectory(prefix="aster-lease-expiry-", dir="/tmp") as parent:
        root = Path(parent)
        root.chmod(0o700)
        endpoint = root / "session/control.sock"
        peers = []
        with (root / "service.stderr").open("wb+") as diagnostics:
            process = subprocess.Popen([binary, "server", "serve", parent, "session"],
                                       stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=diagnostics)
            completed = False
            def connect():
                peer = Client(endpoint, process)
                peers.append(peer)
                return peer
            try:
                owner, observer = connect(), connect()
                created = success(owner.call("terminal.create", {
                    "cwd": parent, "argv": ["/bin/sleep", "60"],
                }))
                terminal_id = created["terminalID"]
                before_grant = time.monotonic()
                original = success(owner.call("terminal.attach", {"terminalID": terminal_id}))
                after_grant = time.monotonic()
                assert after_grant - before_grant < 0.5, "grant latency makes the expiry boundary ambiguous"
                lease = original["lease"]
                # Use fixed monotonic deadlines, not accumulating sleeps. Observer
                # reads must neither renew the writer nor mask an early expiry.
                for offset in (3, 6, 9, 12):
                    wait_until(before_grant + offset)
                    assert time.monotonic() < before_grant + offset + 0.5, "scheduler missed observe deadline"
                    observed = success(observer.call("terminal.observe", {"terminalID": terminal_id}))
                    assert observed["readOnly"] is True and "lease" not in observed
                    assert observed["currentLeaseEpoch"] == lease["leaseEpoch"]
                    print(f"lease expiry: observer active at {offset}s; writer remains idle", flush=True)

                wait_until(before_grant + 14)
                assert time.monotonic() < before_grant + 14.5, "scheduler missed pre-expiry boundary"
                failure(observer.call("terminal.attach", {"terminalID": terminal_id}), "lease_busy")
                assert time.monotonic() < before_grant + 15, "busy check completed after the expiry boundary"

                # The grant happened no later than after_grant, so this cannot
                # mistake a delayed request for the full 15 seconds of inactivity.
                wait_until(after_grant + 15.5)
                assert time.monotonic() < after_grant + 16, "scheduler missed post-expiry boundary"
                replacement = success(observer.call("terminal.attach", {"terminalID": terminal_id}))
                assert replacement["lease"]["leaseEpoch"] > lease["leaseEpoch"]
                failure(owner.call("terminal.control", {
                    "terminalID": terminal_id, "action": "input", "data": "eAo=",
                }, lease), "lease_lost")
                failure(owner.call("terminal.control", {
                    "terminalID": terminal_id, "action": "resize", "geometry": {"rows": 31, "columns": 97},
                }, lease), "lease_lost")
                # A barrier response drains all earlier events on A's connection.
                assert success(owner.call("health.check"))["alive"]
                revoked = [event for event in owner.events if event.get("event") == "lease.revoked"
                           and event["body"].get("leaseID") == lease["leaseID"]]
                assert len(revoked) == 1, revoked
                assert revoked[0]["body"] == {
                    "terminalID": terminal_id, "leaseID": lease["leaseID"],
                    "leaseEpoch": lease["leaseEpoch"], "reason": "expired",
                }, revoked

                observer.close()
                successor = connect()
                next_grant = success(successor.call("terminal.attach", {"terminalID": terminal_id}))
                assert next_grant["lease"]["leaseEpoch"] > replacement["lease"]["leaseEpoch"]
                assert time.monotonic() - before_grant < 20, "lease expiry acceptance exceeded its bounded window"
                assert success(owner.call("server.stop"))["stopping"]
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
                for peer in peers:
                    peer.close()
                if not completed:
                    diagnostics.seek(0)
                    sys.stderr.write(diagnostics.read(65536).decode(errors="replace"))
    print("lease expiry: 14s busy, 15.5s takeover, one expired event, stale input/resize rejection and disconnect release passed")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: lease_expiry.py /absolute/path/to/aster-session-runtime")
    main(str(Path(sys.argv[1]).resolve()))
