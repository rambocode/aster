#!/usr/bin/env python3
"""Exercise the P0 private socket against a real independently owned shell."""
import json
import os
from pathlib import Path
import signal
import select
import socket
import struct
import subprocess
import sys
import tempfile
import time


def send(client, **request):
    data = json.dumps(request).encode()
    client.sendall(struct.pack('!BI', 1, len(data)) + data)


def exact(client, size):
    result = bytearray()
    while len(result) < size:
        chunk = client.recv(size - len(result))
        if not chunk:
            raise AssertionError('unexpected protocol EOF')
        result.extend(chunk)
    return bytes(result)


def frame(client):
    kind, size = struct.unpack('!BI', exact(client, 5))
    assert 0 < size <= 1024 * 1024
    return kind, exact(client, size)


def connect(path):
    client = socket.socket(socket.AF_UNIX)
    client.settimeout(3)
    client.connect(str(path))
    kind, payload = frame(client)
    assert kind == 1 and set(json.loads(payload)['capabilities']) >= {'p0_active_screen', 'snapshot_transaction_v1', 'terminal_delta_v1'}
    return client


def await_text(client, text):
    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        send(client, op='snapshot')
        kind, payload = frame(client)
        if kind == 2 and text in payload:
            return payload
    raise AssertionError(f'screen missing expected marker {text!r}')


def main():
    binary = str(Path(sys.argv[1]).resolve())
    # A short private path fits both Darwin and Linux sockaddr_un limits.
    with tempfile.TemporaryDirectory(prefix='aster-p0-', dir='/tmp') as folder:
        path = Path(folder) / 'session.sock'
        pid_file = Path(folder) / 'child.pid'
        command = 'echo $$ > child.pid.tmp; mv child.pid.tmp child.pid; while IFS= read -r line; do printf "REPLY:%s PID:%s\\n" "$line" "$$"; done'
        process = subprocess.Popen([binary, 'probe-serve', str(path), folder, '/bin/sh', '-c', command],
                                   stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while not path.exists() or not pid_file.exists():
                if process.poll() is not None:
                    raise AssertionError(process.stderr.read().decode())
                if time.monotonic() > deadline:
                    raise AssertionError('service did not become ready')
                time.sleep(0.01)
            child_pid = int(pid_file.read_text())
            assert path.stat().st_mode & 0o777 == 0o600
            for index in range(3):
                with connect(path) as client:
                    send(client, op='input', text=f'round{index}\n')
                    await_text(client, f'REPLY:round{index} PID:{child_pid}'.encode())
                    send(client, op='release')
                time.sleep(0.1)
                os.kill(child_pid, 0)
                assert int(pid_file.read_text()) == child_pid
            bridge = subprocess.Popen([binary, 'probe-bridge', str(path)], stdin=subprocess.PIPE,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
            try:
                for byte in '桥接\n'.encode():
                    bridge.stdin.write(bytes([byte]))
                    bridge.stdin.flush()
                    time.sleep(0.01)
                output = bytearray()
                deadline = time.monotonic() + 3
                while f'REPLY:桥接 PID:{child_pid}'.encode() not in output:
                    assert time.monotonic() < deadline, 'bridge did not render child response'
                    ready, _, _ = select.select([bridge.stdout], [], [], 0.1)
                    if ready:
                        part = os.read(bridge.stdout.fileno(), 8192)
                        assert part, bridge.stderr.read().decode()
                        output.extend(part)
                bridge.stdin.write(b'\x02q')
                bridge.stdin.flush()
                assert bridge.wait(timeout=3) == 0, bridge.stderr.read().decode()
                os.kill(child_pid, 0)
            finally:
                if bridge.poll() is None:
                    bridge.terminate()
                    bridge.wait(timeout=3)
                bridge.stdin.close()
                bridge.stdout.close()
                bridge.stderr.close()
            time.sleep(0.1)
            with connect(path) as client:
                await_text(client, f'REPLY:桥接 PID:{child_pid}'.encode())
                send(client, op='terminate')
            assert process.wait(timeout=3) == 0, process.stderr.read().decode()
            try:
                os.kill(child_pid, 0)
            except ProcessLookupError:
                pass
            else:
                raise AssertionError('explicit termination did not reap child')
            assert not path.exists()
            print('PASS: detach/reattach, byte-split UTF-8 bridge, prefix detach, explicit termination')
        finally:
            if process.poll() is None:
                os.killpg(process.pid, signal.SIGTERM)
                process.wait(timeout=3)
            process.stderr.close()


if __name__ == '__main__':
    main()
