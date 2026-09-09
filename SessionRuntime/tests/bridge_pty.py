#!/usr/bin/env python3
"""Validate resize propagation and terminal restoration using a real host PTY."""
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
from probe import connect, send


def until(master, marker):
    output = bytearray()
    deadline = time.monotonic() + 4
    while marker not in output:
        if time.monotonic() > deadline:
            raise AssertionError(f'missing {marker!r}; output={bytes(output)!r}')
        if select.select([master], [], [], 0.1)[0]:
            output.extend(os.read(master, 8192))


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix='aster-tty-', dir='/tmp') as folder:
        path = Path(folder) / 'session.sock'
        pid_file = Path(folder) / 'child.pid'
        command = """import os, sys, fcntl, termios, struct
with open('child.pid.tmp', 'w') as f: f.write(str(os.getpid()))
os.rename('child.pid.tmp', 'child.pid')
print('READY', flush=True)
for line in sys.stdin:
    rows, cols, px, py = struct.unpack('HHHH', fcntl.ioctl(0, termios.TIOCGWINSZ, b'\\0' * 8))
    print('SIZE:%s:%d %d PIXELS:%d %d' % (line.strip(), rows, cols, px, py), flush=True)
"""
        server = subprocess.Popen([binary, 'probe-serve', str(path), folder, sys.executable, '-c', command],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
        master, slave = pty.openpty()
        bridge = None
        try:
            deadline = time.monotonic() + 5
            while not path.exists() or not pid_file.exists():
                assert server.poll() is None, server.stderr.read().decode()
                assert time.monotonic() < deadline
                time.sleep(0.01)
            child_pid = int(pid_file.read_text())
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 33, 101, 808, 528))
            original = termios.tcgetattr(slave)
            bridge = subprocess.Popen([binary, 'probe-bridge', str(path)], stdin=slave, stdout=slave,
                                      stderr=subprocess.PIPE)
            until(master, b'READY')
            assert termios.tcgetattr(slave)[3] & termios.ICANON == 0
            os.write(master, b'first\n')
            until(master, b'SIZE:first:33 101 PIXELS:808 528')
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 41, 123, 1230, 820))
            os.kill(bridge.pid, signal.SIGWINCH)
            os.write(master, b'second\n')
            until(master, b'SIZE:second:41 123 PIXELS:1230 820')
            bridge.terminate()
            assert bridge.wait(timeout=3) != 0
            restored = termios.tcgetattr(slave)
            # Darwin sets PENDIN when returning queued input to canonical mode.
            # It is kernel input-processing state, not an un-restored raw flag.
            pending = getattr(termios, 'PENDIN', 0)
            restored[3] &= ~pending
            original[3] &= ~pending
            assert restored == original, (original, restored, bridge.returncode, bridge.stderr.read().decode())
            os.kill(child_pid, 0)
            time.sleep(0.1)
            with connect(path) as client:
                send(client, op='terminate')
            assert server.wait(timeout=3) == 0
            print('PASS: initial size, SIGWINCH resize, SIGTERM raw-mode restoration and child survival')
        finally:
            if bridge:
                if bridge.poll() is None:
                    bridge.terminate()
                    bridge.wait(timeout=3)
                bridge.stderr.close()
            if server.poll() is None:
                os.killpg(server.pid, signal.SIGTERM)
                server.wait(timeout=3)
            server.stderr.close()
            os.close(master)
            os.close(slave)


if __name__ == '__main__':
    main()
