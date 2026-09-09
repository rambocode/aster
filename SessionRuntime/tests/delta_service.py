#!/usr/bin/env python3
"""Verify full->delta->full->delta on a real service, including safe fallback."""
import hashlib
import json
import os
from pathlib import Path
import signal
import struct
import subprocess
import sys
import tempfile
import time
from probe import connect, send, frame


def transaction(client, previous):
    kind, payload = frame(client)
    assert kind == 1
    header = json.loads(payload)
    assert header['type'] in ('snapshot_begin', 'delta_begin'), header
    delta = header['type'] == 'delta_begin'
    if delta:
        assert header['baseSequence'] == previous and header['sequence'] > previous
    data = bytearray()
    index = 0
    while True:
        kind, payload = frame(client)
        if kind == 1:
            assert json.loads(payload)['type'] == ('delta_end' if delta else 'snapshot_end')
            assert len(data) == header['length']
            assert hashlib.sha256(data).hexdigest() == header['sha256']
            return delta, bytes(data), header['sequence']
        assert struct.unpack('!I', payload[:4])[0] == index
        index += 1
        data.extend(payload[4:])


def main():
    binary = str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix='aster-delta-', dir='/tmp') as folder:
        path = Path(folder) / 'session.sock'
        program = """import os, sys, tty
tty.setraw(0)
print('READY', end='', flush=True)
with open('ready.tmp', 'w') as f: f.write('ready')
os.rename('ready.tmp', 'ready')
for line in sys.stdin:
    if line.strip() == 'unsafe':
        sys.stdout.write('\\x1b]52;c;c2VjcmV0\\x07STATE')
    else: sys.stdout.write('TEXT:'+line.strip())
    sys.stdout.flush()
"""
        server = subprocess.Popen([binary, 'probe-serve', str(path), folder, sys.executable, '-c', program],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while not path.exists() or not (Path(folder) / 'ready').exists():
                assert server.poll() is None
                assert time.monotonic() < deadline
                time.sleep(0.01)
            with connect(path) as client:
                delta, data, sequence = transaction(client, None)
                assert not delta and b'READY' in data
                send(client, op='input', text='one\n')
                delta, data, sequence = transaction(client, sequence)
                assert delta and data == b'TEXT:one', (delta, data)
                send(client, op='input', text='unsafe\n')
                delta, data, sequence = transaction(client, sequence)
                assert not delta and b'STATE' in data and b']52;' not in data
                send(client, op='input', text='two\n')
                delta, data, sequence = transaction(client, sequence)
                assert delta and data == b'TEXT:two', (delta, data)
                send(client, op='terminate')
            assert server.wait(timeout=3) == 0, server.stderr.read().decode()
            print('PASS: complete snapshot -> text delta -> unsafe-control snapshot -> text delta')
        finally:
            if server.poll() is None:
                os.killpg(server.pid, signal.SIGTERM)
                server.wait(timeout=3)
            server.stderr.close()


if __name__ == '__main__':
    main()
