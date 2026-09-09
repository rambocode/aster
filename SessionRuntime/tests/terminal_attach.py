"""Real CLI host PTY checks; all processes and artifacts belong to this test."""
import errno
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import uuid

from terminal_service import Client, TIMEOUT, eventually, read_when_present, success, terminal


class Host:
    def __init__(self, binary, parent, terminal_id, observer=False, takeover=False):
        self.master, self.slave = pty.openpty()
        self.resize(24, 80)
        self.original = termios.tcgetattr(self.slave)
        self.process = subprocess.Popen(
            [binary, "terminal", "observe" if observer else "attach", parent, "session", terminal_id] + (["--takeover"] if takeover else []),
            stdin=self.slave, stdout=self.slave, stderr=self.slave, start_new_session=True)

    def resize(self, rows, columns):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, columns, 0, 0))

    def write(self, data):
        assert self.process.poll() is None, "CLI exited before input"
        assert os.write(self.master, data) == len(data)

    def until(self, marker):
        deadline = time.monotonic() + TIMEOUT
        output = bytearray()
        while marker not in output:
            remaining = deadline - time.monotonic()
            assert remaining > 0, f"CLI output missing {marker!r}: {bytes(output[-2048:])!r}"
            ready, _, _ = select.select([self.master], [], [], remaining)
            assert ready, f"CLI output timed out: {bytes(output[-2048:])!r}"
            try:
                part = os.read(self.master, 65536)
            except OSError as error:
                if error.errno != errno.EIO:
                    raise
                part = b""
            assert part, f"CLI output closed: {bytes(output[-2048:])!r}"
            output.extend(part)
            assert len(output) <= 4 * 1024 * 1024, "unexpected unbounded CLI output"

    def exited(self, expected=None):
        result = self.process.wait(timeout=TIMEOUT)
        if expected is not None:
            assert result == expected, result
        restored = termios.tcgetattr(self.slave)
        expected = self.original.copy()
        if sys.platform == "darwin":
            # Darwin sets this kernel-owned retype flag even for a plain
            # Python setraw -> tcsetattr(original) roundtrip.
            restored[3] &= ~termios.PENDIN
            expected[3] &= ~termios.PENDIN
        assert restored == expected, ("host termios was not restored", expected, restored)

    def close(self):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=TIMEOUT)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=TIMEOUT)
        os.close(self.master)
        os.close(self.slave)


def tail_drain(control, binary, parent, hosts):
    for mode in ("input", "heartbeat"):
        folder = Path(parent) / mode
        folder.mkdir()
        marker = "SCOPE_TAIL_" + uuid.uuid4().hex
        program = r'''
import os, pathlib, signal, sys, time
folder = pathlib.Path(sys.argv[1])
if os.fork() == 0:
    ending = [False]
    def finish(*_): ending[0] = True
    signal.signal(signal.SIGHUP, finish)
    signal.signal(signal.SIGTERM, finish)
    (folder / "child-ready").touch()
    while not ending[0]: time.sleep(.005)
    time.sleep(.7)
    os._exit(0)
while not (folder / "child-ready").exists(): time.sleep(.005)
print("SCOPE_READY", flush=True)
while not (folder / "finish").exists(): time.sleep(.005)
os.write(1, ("\r\n" + sys.argv[2] + "\r\n").encode())
os._exit(7)
'''
        created = success(control.call("terminal.create", {
            "cwd": parent, "argv": [sys.executable, "-u", "-c", program, str(folder), marker],
        }))
        writer = Host(binary, parent, created["terminalID"])
        hosts.append(writer)
        writer.until(b"SCOPE_READY")
        if mode == "heartbeat":
            # CLI heartbeats every five seconds; put the root exit just before
            # that boundary, while its same-SID child still holds the PTY open.
            time.sleep(4.7)
        (folder / "finish").touch()
        def terminating():
            current = terminal(control, created["terminalID"])
            assert current["state"] != "exited", "missed the incomplete cleanup window"
            return current["state"] == "terminating"
        eventually(terminating, "root exited while descendant retains tail output")
        assert not any(event["event"] == "terminal.exited" and
                       event["body"]["terminalID"] == created["terminalID"] for event in control.events)
        if mode == "input":
            writer.write(b"input-after-root-exit")
        # Darwin revokes slave writes after its session leader exits. The root
        # queues the final marker first; the delayed child keeps cleanup open.
        writer.until(marker.encode())
        writer.exited(0)
        assert terminal(control, created["terminalID"])["exitCode"] == 7
        print(f"terminal attach tail drain: {mode} rejection preserves delayed same-SID output", flush=True)


def main(binary, tail_only=False):
    with tempfile.TemporaryDirectory(prefix="aster-attach-", dir="/tmp") as parent:
        root = Path(parent)
        root.chmod(0o700)
        endpoint = root / "session/control.sock"
        hosts = []
        clients = []
        with (root / "service.stderr").open("wb+") as diagnostics:
            server = subprocess.Popen([binary, "server", "serve", parent, "session"],
                                      stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=diagnostics)
            completed = False
            try:
                control = Client(endpoint, server)
                clients.append(control)
                if tail_only:
                    tail_drain(control, binary, parent, hosts)
                    assert success(control.call("server.stop"))["stopping"]
                    server.wait(timeout=TIMEOUT)
                    assert server.returncode == 0
                    completed = True
                    return
                marker = "ATTACH_" + uuid.uuid4().hex
                script = ('stty -echo; printf "%s\\n" "$1"; '
                          'while IFS= read -r value; do '
                          'if [ "$value" = size ]; then stty size > size; '
                          'else printf "%s" "$value" > input; fi; '
                          'printf "%s\\n" "$1"; done')
                created = success(control.call("terminal.create", {
                    "cwd": parent, "argv": ["/bin/sh", "-c", script, "probe", marker],
                    "geometry": {"rows": 24, "columns": 80},
                }))
                terminal_id = created["terminalID"]
                pid = created["pid"]

                def alive():
                    record = terminal(control, terminal_id)
                    assert record["state"] == "running" and record["pid"] == pid, record

                def host(observer=False, takeover=False):
                    instance = Host(binary, parent, terminal_id, observer, takeover)
                    hosts.append(instance)
                    instance.until(marker.encode())
                    return instance

                writer = host()
                literal = b"literal $(echo forbidden); spaces & symbols"
                writer.write(literal + b"\n")
                eventually(lambda: (root / "input").exists() and (root / "input").read_bytes() == literal,
                           "literal writer input")
                # The prefix crosses writes, exercising parser state rather than
                # relying on both Ctrl+B bytes arriving in a single read.
                writer.write(b"\x02")
                writer.write(b"\x02literal-prefix\n")
                eventually(lambda: (root / "input").read_bytes() == b"\x02literal-prefix", "literal Ctrl+B")
                assert writer.process.poll() is None

                writer.resize(31, 97)
                writer.process.send_signal(signal.SIGWINCH)
                # A retry is needed because stdin and the signal pipe can become
                # readable together; the shell records the actual PTY size.
                def resized():
                    writer.write(b"size\n")
                    value = read_when_present(root / "size")
                    return value is not None and value.split() == ["31", "97"]
                eventually(resized, "SIGWINCH resized source PTY")
                writer.write(b"\x02q")
                writer.exited(0)
                alive()

                observer = host(observer=True)
                # A concurrent attachment proves observe has not acquired the
                # write lease. Its input remains local even while a writer exists.
                grant = success(control.call("terminal.attach", {"terminalID": terminal_id}))
                before = (root / "input").read_bytes()
                observer.write(b"OBSERVER_MUST_NOT_WRITE\n")
                observer.resize(40, 120)
                observer.process.send_signal(signal.SIGWINCH)
                time.sleep(0.1)
                assert (root / "input").read_bytes() == before
                (root / "size").unlink()
                assert success(control.call("terminal.control", {
                    "terminalID": terminal_id, "action": "input", "data": "c2l6ZQo=",
                }, grant["lease"]))["accepted"]
                assert eventually(lambda: read_when_present(root / "size"), "observer retained source size").split() == ["31", "97"]
                observer.write(b"\x02q")
                observer.exited(0)
                assert success(control.call("terminal.release", {"attachmentID": grant["attachmentID"]}))["released"]
                alive()

                previous = host()
                replacement = host(takeover=True)
                previous.exited(1)
                replacement.write(b"TAKEOVER_WRITER\n")
                eventually(lambda: (root / "input").read_bytes() == b"TAKEOVER_WRITER", "explicit takeover writes")
                replacement.write(b"\x02q")
                replacement.exited(0)
                alive()

                interrupted = host()
                interrupted.process.terminate()
                interrupted.exited()
                alive()
                # Natural exit must follow the final verified surface bytes,
                # even when the exit event arrives on the separate control pipe.
                final_marker = "FINAL_EXIT_" + uuid.uuid4().hex
                finite_script = "import sys; print('FINITE_READY',flush=True); input(); sys.stdout.write('TAIL' * 5000 + '\\r\\n' + sys.argv[1]); sys.stdout.flush(); raise SystemExit(7)"
                finite = success(control.call("terminal.create", {"cwd": parent, "argv": [sys.executable, "-u", "-c", finite_script, final_marker]}))
                finite_writer = Host(binary, parent, finite["terminalID"])
                hosts.append(finite_writer)
                finite_writer.until(b"FINITE_READY")
                finite_observer = Host(binary, parent, finite["terminalID"], observer=True)
                hosts.append(finite_observer)
                finite_observer.until(b"FINITE_READY")
                finite_writer.write(b"finish\n")
                finite_writer.until(final_marker.encode())
                finite_observer.until(final_marker.encode())
                finite_writer.exited(0)
                finite_observer.exited(0)
                assert terminal(control, finite["terminalID"])["exitCode"] == 7
                success(control.call("health.check"))
                success(control.call("health.check"))
                exits = [event for event in control.events if event["event"] == "terminal.exited" and event["body"]["terminalID"] == finite["terminalID"]]
                assert len(exits) == 1 and exits[0]["body"]["exitCode"] == 7, exits
                assert success(control.call("server.stop"))["stopping"]
                server.wait(timeout=TIMEOUT)
                assert server.returncode == 0
                completed = True
            finally:
                for instance in hosts:
                    instance.close()
                if server.poll() is None:
                    try:
                        cleanup = Client(endpoint, server)
                        clients.append(cleanup)
                        success(cleanup.call("server.stop"))
                        server.wait(timeout=TIMEOUT)
                    except (OSError, AssertionError, subprocess.TimeoutExpired):
                        server.terminate()
                        try:
                            server.wait(timeout=TIMEOUT)
                        except subprocess.TimeoutExpired:
                            server.kill()
                            server.wait(timeout=TIMEOUT)
                for client in clients:
                    client.close()
                if not completed:
                    diagnostics.seek(0)
                    sys.stderr.write(diagnostics.read(65536).decode(errors="replace"))
    print("terminal attach: writer, observer, literal prefix, resize, detach and signal termios restoration passed")


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3) or (len(sys.argv) == 3 and sys.argv[2] != "--tail-drain-only"):
        raise SystemExit("usage: terminal_attach.py /absolute/path/to/aster-session-runtime [--tail-drain-only]")
    main(str(Path(sys.argv[1]).resolve()), len(sys.argv) == 3)
