#!/usr/bin/env python3
"""An incomplete first snapshot must neither render nor unlock pending input."""
import hashlib
import json
from pathlib import Path
import socket
import struct
import subprocess
import sys
import tempfile
from handshake_gate import packet


def control(value):
    return packet(1, json.dumps(value).encode())


def main():
    binary = str(Path(sys.argv[1]).resolve())
    hello = control(dict(type='hello', protocolMajor=1, protocolMinor=0,
                         serverID='12345678-1234-1234-1234-123456789abc',
                         serverEpoch='12345678-1234-1234-1234-123456789abd',
                         sessionID='12345678-1234-1234-1234-123456789abe',
                         platform='linux-x86_64', capabilities=['p0_active_screen', 'snapshot_transaction_v1', 'terminal_delta_v1']))
    begin = dict(type='snapshot_begin', sequence=1, length=6, sha256=hashlib.sha256(b'abcdef').hexdigest())
    end = control(dict(type='snapshot_end'))
    cases = [
        ('incomplete', control(begin) + packet(2, struct.pack('!I', 0) + b'abc')),
        ('wrong-order', control(begin) + packet(2, struct.pack('!I', 1) + b'abcdef')),
        ('wrong-digest', control(begin) + packet(2, struct.pack('!I', 0) + b'xxxxxx') + end),
        ('over-limit', control(begin | dict(length=32 * 1024 * 1024 + 1))),
        ('overlap', control(begin) + control(begin)),
        ('timeout', control(begin) + packet(2, struct.pack('!I', 0) + b'abc')),
    ]
    with tempfile.TemporaryDirectory(prefix='aster-snap-', dir='/tmp') as folder:
        for name, body in cases:
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
                        peer.sendall(hello + body)
                        if name != 'timeout':
                            peer.shutdown(socket.SHUT_WR)
                        assert bridge.wait(timeout=7) != 0, name
                        expected_error = {'incomplete': 'IncompleteSnapshot', 'wrong-order': 'SnapshotSequenceGap',
                                          'wrong-digest': 'SnapshotIntegrityFailure', 'over-limit': 'InvalidSnapshotLength',
                                          'overlap': 'OverlappingSnapshot', 'timeout': 'SnapshotTimeout'}[name]
                        diagnostic = bridge.stderr.read().decode()
                        assert 'error: ' + expected_error in diagnostic, (name, diagnostic)
                        peer.settimeout(1)
                        assert peer.recv(8192) == b'', (name, 'input unlocked before complete snapshot')
                        assert bridge.stdout.read() == b'', (name, 'partial screen rendered')
                finally:
                    if bridge.poll() is None:
                        bridge.terminate()
                        bridge.wait(timeout=3)
                    bridge.stdin.close()
                    bridge.stdout.close()
                    bridge.stderr.close()
            path.unlink()
    print('PASS: 6 invalid snapshot cases never rendered or unlocked input')


if __name__ == '__main__':
    main()
