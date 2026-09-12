"""Hook directives in PTY output become server-side agent state.

Aster's lifecycle hook writes a private OSC 6974 to the agent's terminal. The
display bridge replays screen state, not raw bytes, so that OSC can never reach
a client through a surface; the service must scan PTY output itself, record
the state as the hook authority and broadcast agent.changed. This test runs a
real terminal whose command emits the same OSC the hook script does (split
across two writes to exercise chunk carry), then checks agent.explain and the
broadcast. All processes and files belong to this test.
"""
import subprocess
import sys
import tempfile
import time
import uuid
from pathlib import Path

from terminal_service import Client, TIMEOUT, eventually, success, terminal


def main(binary):
    with tempfile.TemporaryDirectory(prefix="aster-hookosc-", dir="/tmp") as parent:
        root = Path(parent)
        root.chmod(0o700)
        endpoint = root / "session/control.sock"
        clients = []
        with (root / "service.stderr").open("wb+") as diagnostics:
            server = subprocess.Popen([binary, "server", "serve", parent, "session"],
                                      stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=diagnostics)
            completed = False
            try:
                control = Client(endpoint, server)
                clients.append(control)
                session_id = "grok-" + uuid.uuid4().hex[:12]
                # The same bytes aster-agent-hook.sh writes, with the second
                # directive deliberately split across two writes and a stray
                # unterminated prefix that must be ignored without blocking.
                script = (
                    "printf 'START\\n'; "
                    "printf '\\033]6974;AgentState=processing;Provider=grokBuild;SessionID=%s\\007' \"$1\"; "
                    "sleep 0.3; printf '\\033]6974;AgentState=awaiting-in'; sleep 0.3; "
                    "printf 'put;Provider=grokBuild\\033\\\\'; "
                    "sleep 0.3; printf '\\033]6974;garbage-without-terminator'; sleep 0.3; "
                    "printf 'X\\n'; sleep 0.3; "
                    "printf '\\033]6974;AgentState=idle;Provider=grokBuild\\007'; "
                    "printf 'DONE\\n'; sleep 30")
                created = success(control.call("terminal.create", {
                    "cwd": parent, "argv": ["/bin/sh", "-c", script, "hook", session_id],
                    "geometry": {"rows": 24, "columns": 80},
                }))
                terminal_id = created["terminalID"]

                def explain():
                    return success(control.call("agent.explain", {"terminalID": terminal_id}))["agent"]

                # First directive: processing → working, source=hook, native session bound.
                def working():
                    agent = explain()
                    return agent is not None and agent["state"] == "working" and agent["source"] == "hook"
                eventually(working, "hook directive recorded as working")
                agent = explain()
                assert agent["provider"] == "grokBuild", agent
                assert agent["nativeSession"] == session_id, agent

                # Second directive split across writes: awaiting-input → blocked.
                eventually(lambda: explain()["state"] == "blocked", "split directive recorded as blocked")
                # Third: back to idle after the garbage prefix was discarded.
                eventually(lambda: explain()["state"] == "idle", "idle after unterminated garbage")

                # Every accepted directive was broadcast as agent.changed on the control channel.
                def broadcasts():
                    # 触发一次任意请求让客户端排空事件队列
                    success(control.call("health.check"))
                    states = [e["body"].get("agent", e["body"]).get("state") for e in control.events if e["event"] == "agent.changed"]
                    return states[-3:] == ["working", "blocked", "idle"]
                eventually(broadcasts, "agent.changed broadcast for each directive")
                assert terminal(control, terminal_id)["state"] == "running"

                assert success(control.call("terminal.terminate", {"terminalID": terminal_id}))
                eventually(lambda: terminal(control, terminal_id)["state"] == "exited", "terminate")
                assert success(control.call("server.stop"))["stopping"]
                server.wait(timeout=TIMEOUT)
                assert server.returncode == 0, server.returncode
                completed = True
                print("agent hook directive: OSC 6974 in PTY output is recorded server-side as hook "
                      "authority (split chunks, garbage ignored) and broadcast as agent.changed", flush=True)
            finally:
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
        raise SystemExit("usage: agent_hook_directive.py /absolute/path/to/aster-session")
    main(str(Path(sys.argv[1]).resolve()))
