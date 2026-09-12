#!/usr/bin/env python3
"""Verify delta sequence gaps resync and rejected deltas never reach stdout."""
import base64
import hashlib
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
from handshake_gate import packet
from probe import frame


def control(value):
    return packet(1, json.dumps(value).encode())


def transaction(data, sequence, base=None):
    delta = base is not None
    return (control(dict(type='delta_begin' if delta else 'snapshot_begin', length=len(data),
                         sha256=hashlib.sha256(data).hexdigest(), sequence=sequence, baseSequence=base))
            + packet(2, struct.pack('!I', 0) + data)
            + control(dict(type='delta_end' if delta else 'snapshot_end')))


def main():
    binary = str(Path(sys.argv[1]).resolve())
    hello = control(dict(type='hello', protocolMajor=1, protocolMinor=0,
                         serverID='12345678-1234-1234-1234-123456789abc',
                         serverEpoch='12345678-1234-1234-1234-123456789abd',
                         sessionID='12345678-1234-1234-1234-123456789abe',
                         platform='linux-x86_64', capabilities=['p0_active_screen', 'snapshot_transaction_v1', 'terminal_delta_v1']))
    with tempfile.TemporaryDirectory(prefix='aster-dgate-', dir='/tmp') as folder:
        for scenario in ('gap', 'unsafe', 'before-snapshot', 'oversized'):
            path = Path(folder) / (scenario + '.sock')
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(str(path)); listener.listen(1); listener.settimeout(3)
                bridge = subprocess.Popen([binary, 'probe-bridge', str(path)], stdin=subprocess.PIPE,
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, bufsize=0)
                try:
                    with listener.accept()[0] as peer:
                        peer.settimeout(3)
                        peer.sendall(hello)
                        if scenario != 'before-snapshot':
                            peer.sendall(transaction(b'BASE', 1))
                            assert bridge.stdout.read(4) == b'BASE'
                        if scenario == 'gap':
                            bridge.stdin.write(b'\x02')
                            peer.settimeout(0.1)
                            try:
                                early = peer.recv(1)
                            except socket.timeout:
                                early = None
                            assert early is None
                            peer.settimeout(3)
                            peer.sendall(transaction(b'MUST_NOT_APPLY', 100, 99))
                            kind, request = frame(peer)
                            assert kind == 1 and json.loads(request)['op'] == 'snapshot'
                            bridge.stdin.write(b'DROP_WHILE_STALE\n')
                            peer.settimeout(0.1)
                            try:
                                leaked = peer.recv(1)
                            except socket.timeout:
                                leaked = None
                            assert leaked is None
                            peer.sendall(transaction(b'RESTORED', 101) + transaction(b'+DELTA', 102, 101))
                            assert bridge.stdout.read(8) == b'RESTORED'
                            assert bridge.stdout.read(6) == b'+DELTA'
                            bridge.stdin.write(b'q')
                            peer.settimeout(3)
                            kind, request = frame(peer)
                            typed = json.loads(request)
                            assert kind == 1 and typed['op'] == 'input' and base64.b64decode(typed['data']) == b'q'
                            peer.shutdown(socket.SHUT_WR)
                            assert bridge.wait(timeout=3) == 0, bridge.stderr.read().decode()
                            assert bridge.stdout.read() == b''
                            peer.settimeout(1)
                            assert peer.recv(8192) == b'', 'stale input was replayed after resync'
                        else:
                            payload = b'\x1b]52;c;c2VjcmV0\x07' if scenario == 'unsafe' else b'EARLY'
                            if scenario == 'oversized':
                                peer.sendall(control(dict(type='delta_begin', length=65537, sha256='0'*64, sequence=2, baseSequence=1)))
                            else:
                                peer.sendall(transaction(payload, 2, 1))
                            assert bridge.wait(timeout=3) != 0
                            reason = {'unsafe':'UnsafeDelta','before-snapshot':'DeltaBeforeSnapshot','oversized':'DeltaTooLarge'}[scenario]
                            assert 'error: ' + reason in bridge.stderr.read().decode()
                            assert bridge.stdout.read() == b''
                finally:
                    if bridge.poll() is None:
                        bridge.terminate(); bridge.wait(timeout=3)
                    bridge.stdin.close(); bridge.stdout.close(); bridge.stderr.close()
            path.unlink()
    print('PASS: gap requests full resync, stale input dropped, unsafe/early deltas rejected')


if __name__ == '__main__':
    main()
