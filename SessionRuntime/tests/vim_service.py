#!/usr/bin/env python3
"""Exercise an installed real TUI through snapshot/delta transport."""
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from probe import connect, send
from delta_service import transaction


def main():
    binary = str(Path(sys.argv[1]).resolve())
    vim = shutil.which('vim')
    if not vim:
        raise SystemExit('vim is required for this explicit TUI acceptance run')
    with tempfile.TemporaryDirectory(prefix='aster-vim-', dir='/tmp') as folder:
        path = Path(folder) / 'session.sock'
        document = Path(folder) / 'sample.txt'
        document.write_text('one\ntwo\n')
        server = subprocess.Popen([binary, 'probe-serve', str(path), folder, vim,
                                   '-Nu', 'NONE', '-n', '-i', 'NONE', str(document)],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
        try:
            deadline = time.monotonic() + 10
            while not path.exists():
                assert server.poll() is None
                assert time.monotonic() < deadline
                time.sleep(0.01)
            with connect(path) as client:
                client.settimeout(8)
                sequence = None
                output = bytearray()
                deltas = 0
                while b'sample.txt' not in output:
                    assert time.monotonic() < deadline
                    delta, data, sequence = transaction(client, sequence)
                    output.extend(data)
                    deltas += delta
                assert any(code in output for code in (b'\x1b[?1049h', b'\x1b[?1047h', b'\x1b[?47h')), 'Vim did not enter alternate screen'
                send(client, op='input', text='\x1b:set mouse=a\r')
                deadline = time.monotonic() + 10
                while not any(code in output for code in (b'\x1b[?1000h', b'\x1b[?1002h', b'\x1b[?1003h')):
                    assert time.monotonic() < deadline, 'Vim mouse reporting did not become active'
                    delta, data, sequence = transaction(client, sequence)
                    output.extend(data)
                    deltas += delta
                send(client, op='input', text='iHELLO\x1b:wq\r')
                deadline = time.monotonic() + 10
                while not document.read_text().startswith('HELLOone'):
                    assert time.monotonic() < deadline, 'Vim did not save the edit'
                    delta, data, sequence = transaction(client, sequence)
                    output.extend(data)
                    deltas += delta
                assert deltas > 0, 'real TUI never exercised incremental transport'
                send(client, op='terminate')
            assert server.wait(timeout=3) == 0, server.stderr.read().decode()
            print('PASS: real Vim entered alternate screen, enabled mouse, edited/saved via incremental transport')
        finally:
            if server.poll() is None:
                os.killpg(server.pid, signal.SIGTERM)
                server.wait(timeout=3)
            server.stderr.close()


if __name__ == '__main__':
    main()
