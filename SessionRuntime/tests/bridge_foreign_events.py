"""A display bridge must survive broadcasts it does not own.

The control channel carries P4/P5 broadcasts (agent.changed, workspace.changed,
...) to every control connection, including an attached `terminal attach`
bridge. Before the fix the bridge treated any event kind other than
terminal.exited / lease.revoked as fatal (UnexpectedControlEvent, exit 1), so
the first agent state report killed every attached display bridge. This test
attaches a real bridge, fires agent.report from another client and proves the
bridge is still alive, still relays input and output, and still sees a later
lease.revoked / terminal.exited correctly after the foreign event advanced its
cursor. All processes and files belong to this test.
"""
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

from terminal_service import Client, TIMEOUT, eventually, success, terminal
from terminal_attach import Host


def main(binary):
    with tempfile.TemporaryDirectory(prefix="aster-foreign-", dir="/tmp") as parent:
        root = Path(parent)
        root.chmod(0o700)
        endpoint = root / "session/control.sock"
        hosts, clients = [], []
        with (root / "service.stderr").open("wb+") as diagnostics:
            server = subprocess.Popen([binary, "server", "serve", parent, "session"],
                                      stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=diagnostics)
            completed = False
            try:
                control = Client(endpoint, server)
                clients.append(control)
                marker = "FOREIGN_" + uuid.uuid4().hex
                script = ('stty -echo; printf "%s\\n" "$1"; '
                          'while IFS= read -r value; do printf "ECHO:%s\\n" "$value"; done')
                created = success(control.call("terminal.create", {
                    "cwd": parent, "argv": ["/bin/sh", "-c", script, "probe", marker],
                    "geometry": {"rows": 24, "columns": 80},
                }))
                terminal_id, pid = created["terminalID"], created["pid"]
                bridge = Host(binary, parent, terminal_id)
                hosts.append(bridge)
                bridge.until(marker.encode())

                # A foreign broadcast on the shared control channel: the bridge must
                # neither exit nor lose its sequence cursor.
                for state in ("working", "blocked", "idle"):
                    accepted = success(control.call("agent.report", {
                        "terminalID": terminal_id, "provider": "grokBuild", "state": state,
                        "source": "screen",
                    }))["accepted"]
                    assert accepted, state
                time.sleep(0.5)
                assert bridge.process.poll() is None, \
                    f"bridge exited on agent.changed broadcast: rc={bridge.process.returncode}"
                probe = "after-agent-" + uuid.uuid4().hex[:8]
                bridge.write((probe + "\n").encode())
                bridge.until(("ECHO:" + probe).encode())
                record = terminal(control, terminal_id)
                assert record["state"] == "running" and record["pid"] == pid, record

                # The cursor advanced past the foreign events: a genuine ownership
                # event afterwards is still consumed in order. Takeover by another
                # host revokes this bridge's lease and it exits cleanly.
                other = Host(binary, parent, terminal_id, takeover=True)
                hosts.append(other)
                # The revoked writer reports lease loss and exits 1, exactly as in
                # terminal_attach.py; the takeover host keeps the terminal.
                bridge.exited(1)
                other.until(marker.encode())
                assert other.process.poll() is None, "takeover host exited unexpectedly"
                other.write(b"\x02q")
                other.exited(0)

                assert success(control.call("terminal.terminate", {"terminalID": terminal_id}))
                eventually(lambda: terminal(control, terminal_id)["state"] == "exited", "terminate")
                assert success(control.call("server.stop"))["stopping"]
                server.wait(timeout=TIMEOUT)
                assert server.returncode == 0, server.returncode
                completed = True
                print("bridge foreign events: attached bridge survives agent.changed broadcasts, "
                      "keeps relaying and still honours a later lease revocation", flush=True)
            finally:
                for host in hosts:
                    host.close()
                for client in clients:
                    client.close()
                if server.poll() is None:
                    server.terminate()
                    try:
                        server.wait(timeout=TIMEOUT)
                    except subprocess.TimeoutExpired:
                        server.kill()
                        server.wait(timeout=TIMEOUT)
                if not completed:
                    diagnostics.seek(0)
                    sys.stderr.write(diagnostics.read(65536).decode(errors="replace"))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: bridge_foreign_events.py /absolute/path/to/aster-session")
    main(str(Path(sys.argv[1]).resolve()))
