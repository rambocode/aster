#!/usr/bin/env python3
"""Verify real PNG input survives service framing and a disconnect/reattach."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import time
from probe import connect, send, frame


def snapshot(client):
    expected = None
    digest = None
    data = bytearray()
    index = 0
    while True:
        kind, payload = frame(client)
        if kind == 1:
            event = json.loads(payload)
            if event['type'] == 'snapshot_begin':
                assert expected is None
                expected, digest = event['length'], event['sha256']
            elif event['type'] == 'snapshot_end':
                assert expected == len(data)
                assert hashlib.sha256(data).hexdigest() == digest
                return bytes(data)
        else:
            assert expected is not None
            assert struct.unpack('!I', payload[:4])[0] == index
            index += 1
            data.extend(payload[4:])


def verify_pixels(data):
    transfer = bytearray()
    found = False
    for match in re.finditer(rb'\x1b_G([^\x1b;]*)(?:;([^\x1b]*))?\x1b\\', data):
        parameters = dict(part.split(b'=', 1) for part in match[1].split(b','))
        if parameters.get(b'a') == b't' and parameters.get(b'i') == b'17':
            assert parameters[b'f'] == b'32'
            assert parameters[b's'] == b'2' and parameters[b'v'] == b'1'
            transfer.clear()
            found = True
        if found and match[2]:
            transfer.extend(match[2])
            if parameters.get(b'm', b'0') == b'0':
                assert base64.b64decode(transfer) == bytes([255, 0, 0, 255, 0, 255, 0, 128])
                return
    raise AssertionError('PNG pixels missing from committed snapshot')


def main():
    binary = str(Path(sys.argv[1]).resolve())
    fixture = Path(sys.argv[2]).resolve() if len(sys.argv) > 2 else Path(__file__).resolve().parent.parent / 'src/testdata/rgba.png'
    png = base64.b64encode(fixture.read_bytes()).decode()
    with tempfile.TemporaryDirectory(prefix='aster-img-', dir='/tmp') as folder:
        path = Path(folder) / 'session.sock'
        pid_path = Path(folder) / 'child.pid'
        program = """import os, sys
sys.stdout.write('\\x1b_Ga=T,f=100,i=17,p=3,c=2,r=1,C=1,q=2;'+sys.argv[1]+'\\x1b\\\\READY')
sys.stdout.flush()
with open('child.pid.tmp','w') as f: f.write(str(os.getpid()))
os.rename('child.pid.tmp','child.pid')
for line in sys.stdin: print('ECHO:'+line.strip(), flush=True)
"""
        server = subprocess.Popen([binary, 'probe-serve', str(path), folder, sys.executable, '-c', program, png],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 5
            while not path.exists() or not pid_path.exists():
                assert server.poll() is None, server.stderr.read().decode()
                assert time.monotonic() < deadline
                time.sleep(0.01)
            child_pid = int(pid_path.read_text())
            time.sleep(0.1)
            with connect(path) as client:
                # Hello must flush even while a snapshot is awaiting geometry.
                client.settimeout(0.1)
                try:
                    early = client.recv(1)
                except socket.timeout:
                    early = None
                assert early is None, 'image snapshot sent without pixel geometry'
                client.settimeout(3)
                send(client, op='resize', rows=24, cols=80, pixelWidth=800, pixelHeight=480)
                first = snapshot(client)
                verify_pixels(first)
                assert b'READY' in first
                send(client, op='release')
            time.sleep(0.1)
            os.kill(child_pid, 0)
            with connect(path) as client:
                restored = snapshot(client)
                verify_pixels(restored)
                assert b'READY' in restored
                send(client, op='terminate')
            assert server.wait(timeout=3) == 0, server.stderr.read().decode()
            print('PASS: early PNG cached, hello flushed, committed pixels verified, reconnect kept child/image')
        finally:
            if server.poll() is None:
                os.killpg(server.pid, signal.SIGTERM)
                server.wait(timeout=3)
            server.stderr.close()


if __name__ == '__main__':
    main()
