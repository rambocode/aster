#!/usr/bin/env python3
"""Reject invalid peers before forwarding preloaded input or rendering bytes."""
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile


def packet(kind, payload):
    return struct.pack('!BI', kind, len(payload)) + payload


def main():
    binary = str(Path(sys.argv[1]).resolve())
    hello = dict(type='hello', protocolMajor=1, protocolMinor=0,
                 serverID='12345678-1234-1234-1234-123456789abc',
                 serverEpoch='12345678-1234-1234-1234-123456789abd',
                 sessionID='12345678-1234-1234-1234-123456789abe',
                 platform='linux-x86_64', capabilities=['p0_active_screen', 'snapshot_transaction_v1', 'terminal_delta_v1'])
    cases = [
        ('wrong-major', packet(1, json.dumps(hello | dict(protocolMajor=2)).encode())),
        ('missing-capability', packet(1, json.dumps(hello | dict(capabilities=[])).encode())),
        ('snapshot-only-peer', packet(1, json.dumps(hello | dict(capabilities=['p0_active_screen', 'snapshot_transaction_v1'])).encode())),
        ('legacy-probe', packet(1, json.dumps(hello | dict(capabilities=['p0_active_screen'])).encode())),
        ('surface-first', packet(2, b'MUST_NOT_RENDER')),
        ('invalid-identity', packet(1, json.dumps(hello | dict(serverID='invalid')).encode())),
    ]
    with tempfile.TemporaryDirectory(prefix='aster-gate-', dir='/tmp') as folder:
        for name, payload in cases:
            path = Path(folder) / (name + '.sock')
            with socket.socket(socket.AF_UNIX) as listener:
                listener.bind(str(path))
                listener.listen(1)
                listener.settimeout(3)
                bridge = subprocess.Popen([binary, 'probe-bridge', str(path)], stdin=subprocess.PIPE,
                                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                try:
                    bridge.stdin.write(b'MUST_NOT_SEND\n')
                    bridge.stdin.flush()
                    with listener.accept()[0] as peer:
                        peer.settimeout(0.1)
                        try:
                            early = peer.recv(8192)
                        except socket.timeout:
                            early = None
                        assert early is None, (name, 'forwarded input before hello', early)
                        peer.sendall(payload)
                        assert bridge.wait(timeout=3) != 0, name
                        expected_error = {'wrong-major': 'IncompatibleMajor', 'missing-capability': 'MissingCapabilities',
                                          'legacy-probe': 'MissingCapabilities', 'snapshot-only-peer': 'MissingCapabilities', 'surface-first': 'HandshakeRequired',
                                          'invalid-identity': 'InvalidHandshake'}[name]
                        diagnostic = bridge.stderr.read().decode()
                        assert 'error: ' + expected_error in diagnostic, (name, diagnostic)
                        peer.settimeout(1)
                        assert peer.recv(8192) == b'', (name, 'forwarded input after rejecting hello')
                        assert bridge.stdout.read() == b'', (name, 'rendered untrusted frame')
                finally:
                    if bridge.poll() is None:
                        bridge.terminate()
                        bridge.wait(timeout=3)
                    bridge.stdin.close()
                    bridge.stdout.close()
                    bridge.stderr.close()
            path.unlink()
    print('PASS: 6 handshake rejection cases never forwarded queued input or rendered frames')


if __name__ == '__main__':
    main()
