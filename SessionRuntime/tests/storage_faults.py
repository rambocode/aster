"""Linux/root real ENOSPC, unprivileged denial and corrupt-state integration.

Only a unique directory below --mount-root is mounted. Mount denial is a hard
block, never replaced by mocked I/O. Failed runs retain evidence outside tmpfs.
"""
import argparse
import errno
import json
import os
from pathlib import Path
import pwd
import shutil
import subprocess
import sys
import tempfile
import time
import uuid

from terminal_service import Client, TIMEOUT, eventually, read_when_present, success, terminal, terminals


def run(command, **kwargs):
    return subprocess.run(command, capture_output=True, text=True, timeout=TIMEOUT, **kwargs)


def child_pids(process):
    path = Path(f"/proc/{process.pid}/task/{process.pid}/children")
    return set(path.read_text().split())


def fill(path):
    count = 0
    with path.open("wb", buffering=0) as file:
        while True:
            try:
                written = file.write(b"F" * 65536)
                assert written
                count += written
                assert count <= 16 * 1024 * 1024, "tmpfs unexpectedly exceeds its configured limit"
            except OSError as error:
                assert error.errno == errno.ENOSPC, error
                return count


def permission_denial(binary, evidence):
    account = pwd.getpwnam("nobody")
    # /root is deliberately not made traversable. The unprivileged process gets
    # its own executable copy and parent under /tmp, removed after this case.
    with tempfile.TemporaryDirectory(prefix="aster-storage-denied-", dir="/tmp") as folder:
        root = Path(folder)
        root.chmod(0o755)
        executable = root / "runtime"
        shutil.copy2(binary, executable)
        executable.chmod(0o755)
        denied = root / "denied"
        denied.mkdir(mode=0o500)
        os.chown(denied, account.pw_uid, account.pw_gid)
        credentials = dict(user=account.pw_uid, group=account.pw_gid, extra_groups=[])
        probe = run([sys.executable, "-c",
                     "import errno,os,sys\nassert os.geteuid() != 0\n"
                     "try: os.mkdir(sys.argv[1] + '/proof')\n"
                     "except OSError as e: sys.exit(0 if e.errno == errno.EACCES else 2)\n"
                     "sys.exit(3)", str(denied)], **credentials)
        assert probe.returncode == 0, (probe.stdout, probe.stderr)
        result = run([str(executable), "server", "serve", str(denied), "session"], **credentials)
        (evidence / "permission.stderr").write_text(result.stderr)
        assert result.returncode != 0 and "AccessDenied" in result.stderr, result
        assert not list(denied.iterdir()), "denied startup modified the filesystem"


def main(binary, mount_root):
    if sys.platform != "linux" or os.geteuid() != 0:
        raise SystemExit("BLOCKED: storage_faults.py requires Linux root for a private tmpfs and real nobody credentials")
    mount_root = mount_root.resolve(strict=True)
    info = mount_root.stat()
    assert info.st_uid == os.geteuid() and info.st_mode & 0o077 == 0, "mount root must be root-owned and private"
    case = mount_root / ("storage-" + uuid.uuid4().hex)
    case.mkdir(mode=0o700)
    mounted = case / "state"
    mounted.mkdir(mode=0o700)
    evidence = case / "evidence"
    evidence.mkdir(mode=0o700)
    external = case / "external"
    external.mkdir(mode=0o700)
    process = None
    peers = []
    files = []
    is_mounted = False
    completed = False
    endpoint = mounted / "session/control.sock"

    def start(label):
        diagnostics = (evidence / (label + ".stderr")).open("wb")
        files.append(diagnostics)
        child = subprocess.Popen([binary, "server", "serve", str(mounted), "session"],
                                 stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=diagnostics)
        return child

    def connect(child):
        # AF_UNIX pathname limits apply even to a private long run directory.
        # Match the production client: connect relative to the state directory
        # and restore this single-threaded test process's cwd immediately.
        previous = os.open(".", os.O_RDONLY)
        try:
            os.chdir(mounted)
            client = Client(Path("session/control.sock"), child)
        finally:
            os.fchdir(previous)
            os.close(previous)
        peers.append(client)
        return client

    def stop(child, client):
        assert success(client.call("server.stop"))["stopping"]
        child.wait(timeout=TIMEOUT)
        assert child.returncode == 0

    try:
        result = run(["mount", "-t", "tmpfs", "-o", "size=8m,mode=0700,nosuid,nodev", "aster-storage-test", str(mounted)])
        (evidence / "mount.stderr").write_text(result.stderr)
        if result.returncode != 0:
            raise RuntimeError(f"BLOCKED: private tmpfs mount rejected: {result.stderr.strip()}")
        is_mounted = True
        permission_denial(binary, evidence)
        process = start("initial")
        control = connect(process)
        identity = (mounted / "session/identity.bin").read_bytes()
        original_target = control.target.copy()
        keeper = success(control.call("terminal.create", {
            "cwd": str(external),
            "argv": ["/bin/sh", "-c", 'while :; do printf x >> heartbeat; sleep 0.05; done'],
        }))
        heartbeat = external / "heartbeat"
        eventually(lambda: heartbeat.exists() and heartbeat.stat().st_size > 0, "unrelated PTY output")
        baseline = child_pids(process)
        before = heartbeat.stat().st_size
        used = fill(mounted / "filler")
        assert os.statvfs(mounted).f_bavail == 0, "filesystem was not filled"
        (evidence / "enospc.json").write_text(json.dumps({"writtenBytes": used, "errno": errno.ENOSPC}))
        failed = control.make("terminal.create", {
            "cwd": str(external), "argv": ["/bin/sh", "-c", "echo unexpected >> forbidden; sleep 60"],
        })
        response = control.transact(failed)
        (evidence / "failed-create.json").write_text(json.dumps(response, indent=2))
        assert response.get("type") == "error", response
        assert not (external / "forbidden").exists()
        assert child_pids(process) == baseline, "ENOSPC create spawned a process"
        assert len(terminals(control)) == 1
        record = terminal(control, keeper["terminalID"])
        assert record["pid"] == keeper["pid"] and record["state"] == "running", record
        assert success(control.call("health.check"))["alive"]
        eventually(lambda: heartbeat.stat().st_size > before, "unrelated PTY continues under ENOSPC")

        (mounted / "filler").unlink()
        # Releasing disk space does not clear Log.poisoned. Query first; never
        # replay the unknown request. A distinct new request must remain blocked.
        assert len(terminals(control)) == 1
        fresh = control.call("terminal.create", {
            "cwd": str(external), "argv": ["/bin/sh", "-c", "echo unexpected >> forbidden"],
        })
        assert fresh.get("error", {}).get("code") == "outcome_unknown", fresh
        assert not (external / "forbidden").exists()
        assert child_pids(process) == baseline
        stop(process, control)
        process = start("reopened")
        control = connect(process)
        assert (mounted / "session/identity.bin").read_bytes() == identity
        assert control.target["serverID"] == original_target["serverID"]
        assert control.target["sessionID"] == original_target["sessionID"]
        assert control.target["serverEpoch"] != original_target["serverEpoch"]
        assert terminals(control) == []
        success(control.call("terminal.create", {
            "cwd": str(external), "argv": ["/bin/sh", "-c", "printf recovered > recovered"],
        }))
        eventually(lambda: read_when_present(external / "recovered") == "recovered", "writer recovered after reopen")
        assert not (external / "forbidden").exists()
        stop(process, control)

        log = mounted / "session/idempotency.log"
        valid_log = log.read_bytes()
        assert len(valid_log) > 36
        # Both a torn record and a valid-length checksum corruption must fail
        # closed without silently regenerating identity or repairing the log.
        for label, corrupt in (("torn-log", valid_log[:20]),
                               ("corrupt-log", valid_log[:-1] + bytes([valid_log[-1] ^ 1]))):
            log.write_bytes(corrupt)
            process = start(label)
            process.wait(timeout=TIMEOUT)
            assert process.returncode != 0, f"{label} startup unexpectedly succeeded"
            assert log.read_bytes() == corrupt, f"{label} was silently repaired"
            assert (mounted / "session/identity.bin").read_bytes() == identity
            log.write_bytes(valid_log)
        completed = True
    finally:
        if process is not None and process.poll() is None:
            try:
                cleanup = connect(process)
                stop(process, cleanup)
            except (OSError, AssertionError, subprocess.TimeoutExpired):
                process.terminate()
                try:
                    process.wait(timeout=TIMEOUT)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=TIMEOUT)
        for peer in peers:
            peer.close()
        for file in files:
            file.close()
        if is_mounted:
            if not completed:
                # Preserve only small state records, never the filler or socket.
                session = mounted / "session"
                for name in ("identity.bin", "idempotency.log", "idempotency.pending"):
                    source = session / name
                    if source.is_file():
                        shutil.copy2(source, evidence / name)
            result = run(["umount", str(mounted)])
            if result.returncode != 0:
                raise RuntimeError(f"test-owned mount cleanup failed at {mounted}: {result.stderr}")
        if completed:
            shutil.rmtree(case)
        else:
            print(f"Storage fault evidence retained: {evidence}", file=sys.stderr)
    print("storage faults: real ENOSPC, nobody permission denial, poison/reopen and corrupt log rejection passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=lambda value: str(Path(value).resolve(strict=True)))
    parser.add_argument("--mount-root", type=Path, default=Path("/root/.local/state/aster-test"),
                        help="existing private root; only a newly created unique child is mounted")
    arguments = parser.parse_args()
    main(arguments.binary, arguments.mount_root)
