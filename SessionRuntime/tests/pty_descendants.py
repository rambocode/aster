#!/usr/bin/env python3
"""Read-only PTY ownership experiment; never invokes or alters Aster runtime.

Each case owns a fresh PTY session and one identified descendant. Cleanup signals
only those reported PIDs after rechecking their SID. Linux adopts its own orphan
via PR_SET_CHILD_SUBREAPER so the diagnostic itself does not leave zombies.
"""
import ctypes
import errno
import json
import os
import pty
import select
import signal
import subprocess
import sys
import time


def describe(pid):
    try:
        result = {"pid": pid, "sid": os.getsid(pid), "pgid": os.getpgid(pid)}
    except ProcessLookupError:
        return {"pid": pid, "gone": True}
    ps = subprocess.run(["ps", "-p", str(pid), "-o", "pid=,ppid=,pgid=,stat=,tty="], capture_output=True, text=True)
    result["ps"] = ps.stdout.strip()
    if sys.platform.startswith("linux"):
        result["fds"] = {}
        for fd in (0, 1, 2):
            try:
                result["fds"][str(fd)] = os.readlink(f"/proc/{pid}/fd/{fd}")
            except OSError:
                pass
    else:
        result["fds"] = subprocess.run(["/usr/sbin/lsof", "-a", "-p", str(pid), "-d", "0,1,2", "-Ffnt"], capture_output=True, text=True).stdout.strip()
    return result


def eof_within(master, seconds):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if not select.select([master], [], [], max(0, end - time.monotonic()))[0]:
            return False
        try:
            if not os.read(master, 4096):
                return True
        except OSError as error:
            if error.errno == errno.EIO:
                return True
            raise
    return False


def run_case(mode):
    report_read, report_write = os.pipe()
    root, master = pty.fork()
    if root == 0:
        os.close(report_read)
        ready_read, ready_write = os.pipe()
        job = os.fork()
        if job == 0:
            os.close(ready_read)
            if mode != "ignore_hup_same_group":
                os.setpgid(0, 0)
            else:
                signal.signal(signal.SIGHUP, signal.SIG_IGN)
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
            os.write(ready_write, b"ready")
            os.close(ready_write)
            os.close(report_write)
            while True:
                signal.pause()
        os.close(ready_write)
        os.read(ready_read, 5)
        os.close(ready_read)
        if mode == "foreground":
            os.tcsetpgrp(0, job)
        os.write(report_write, json.dumps({"root": os.getpid(), "job": job, "tty": os.ttyname(0), "foreground_pgid": os.tcgetpgrp(0)}).encode() + b"\n")
        os.close(report_write)
        while True:
            signal.pause()
    os.close(report_write)
    job = None
    try:
        if not select.select([report_read], [], [], 5)[0]:
            raise RuntimeError("test child setup timed out")
        report = json.loads(os.read(report_read, 4096))
        job = report["job"]
        before = {"root": describe(root), "job": describe(job)}
        assert before["root"]["sid"] == root == before["job"]["sid"]
        assert before["root"]["pgid"] == root
        # Exactly the runtime's initial termination target: the root process group.
        os.killpg(root, signal.SIGTERM)
        deadline = time.monotonic() + 3
        root_status = None
        while time.monotonic() < deadline:
            result, status = os.waitpid(root, os.WNOHANG)
            if result:
                root_status = status
                break
            time.sleep(0.01)
        assert root_status is not None, "root did not exit after SIGTERM"
        eof = eof_within(master, 0.5)
        after_root = describe(job)
        os.close(master)
        master = -1
        time.sleep(0.1)
        after_close = describe(job)
        print(json.dumps({"platform": sys.platform, "case": mode, "setup": report, "before": before, "root_wait_status": root_status, "root_exit": os.waitstatus_to_exitcode(root_status), "master_eof_after_root": eof, "job_after_root": after_root, "job_after_master_close": after_close}, sort_keys=True), flush=True)
    finally:
        os.close(report_read)
        if master >= 0:
            os.close(master)
        for pid in (job, root):
            if pid is None:
                continue
            try:
                if os.getsid(pid) == root:
                    os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        for pid in (job, root):
            if pid is not None:
                try:
                    os.waitpid(pid, 0)
                except ChildProcessError:
                    pass


if __name__ == "__main__":
    if sys.platform.startswith("linux"):
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.prctl(36, 1, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "cannot own diagnostic orphan cleanup")
    for case in ("foreground", "background", "ignore_hup_same_group"):
        run_case(case)
