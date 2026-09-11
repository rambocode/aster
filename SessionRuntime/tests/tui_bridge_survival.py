#!/usr/bin/env python3
"""Verify that TUI control sequences (RIS, alternate screen, mouse tracking)
do NOT kill the display bridge's surface connection.

Before the fix in surface_service.zig, a transient geometry mismatch after
RIS caused the server to disconnect the surface (UnsupportedProjection).

Usage: python3 tests/tui_bridge_survival.py zig-out/bin/aster-session
"""
import base64
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from terminal_service import Client, TIMEOUT, success
from surface_service import transaction


def main(binary):
    """Run a shell, inject TUI sequences, verify surface survives."""
    with tempfile.TemporaryDirectory(prefix="aster-tui-", dir="/tmp") as parent:
        root = Path(parent)
        root.chmod(0o700)
        name = "tui-test"
        endpoint = root / name / "control.sock"
        server = subprocess.Popen(
            [binary, "server", "serve", parent, name],
            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE, start_new_session=True)
        try:
            # Connect control client
            owner = Client(endpoint, server)
            # Create a terminal running bash
            geometry = {"rows": 24, "columns": 80}
            created = success(owner.call("terminal.create", {
                "cwd": parent,
                "argv": ["/bin/bash", "--norc", "--noprofile"],
                "geometry": geometry,
            }))
            tid = created["terminalID"]
            time.sleep(0.5)

            # Attach (get write lease)
            attachment = success(owner.call("terminal.attach",
                                            {"terminalID": tid}))
            attachment_id = attachment["attachmentID"]
            lease = attachment["lease"]

            # Open surface connection and subscribe
            surface = Client(endpoint, server, client_id=owner.client_id)
            sub = success(surface.call("surface.subscribe", {
                "attachmentID": attachment_id,
                "geometry": geometry,
            }))
            stream_id = sub["streamID"]

            # Wait for initial snapshot
            seq, data, delta = transaction(surface)
            assert data, "initial snapshot empty"

            # Inject TUI control sequences (simulate crossterm/ratatui startup)
            tui_init = (
                b'\x1bc'              # RIS - Reset to Initial State
                b'\x1b[?1049h'        # switch to alternate screen
                b'\x1b[?1000h'        # enable mouse tracking
                b'\x1b[?1002h'        # button-event mouse tracking
                b'\x1b[?1003h'        # all mouse events
                b'\x1b[?1006h'        # SGR mouse mode
                b'\x1b[c'             # DA - Device Attributes query
                b'\x1b[6n'            # DSR - Cursor Position query
                b'TUI content visible\r\n'
            )
            encoded = base64.standard_b64encode(tui_init).decode()
            ctrl = success(owner.call("terminal.control", {
                "terminalID": tid,
                "action": "input",
                "data": encoded,
            }, lease))
            assert ctrl["accepted"], f"input rejected: {ctrl}"

            # Wait for server ticks to process TUI sequences
            time.sleep(2)

            # Try to get next snapshot — surface must still be alive
            try:
                seq2, data2, delta2 = transaction(surface, seq)
                alive = True
            except (EOFError, ConnectionResetError, AssertionError):
                alive = False

            assert alive, (
                "FAIL: surface disconnected after TUI sequences — "
                "bridge would have died (UnsupportedProjection bug)")

            # Inject TUI exit sequences
            tui_exit = (
                b'\x1b[?1006l'
                b'\x1b[?1003l'
                b'\x1b[?1002l'
                b'\x1b[?1000l'
                b'\x1b[?1049l'  # restore primary screen
            )
            encoded2 = base64.standard_b64encode(tui_exit).decode()
            ctrl2 = success(owner.call("terminal.control", {
                "terminalID": tid,
                "action": "input",
                "data": encoded2,
            }, lease))
            assert ctrl2["accepted"]

            time.sleep(1)
            try:
                seq3, data3, delta3 = transaction(surface, seq2)
                alive2 = True
            except (EOFError, ConnectionResetError, AssertionError):
                alive2 = False
            assert alive2, "surface died after TUI exit sequences"

            # Cleanup: surface connection mixes data frames with RPC replies,
            # so just close it directly instead of calling unsubscribe.
            surface.close()
            owner.call("terminal.release",
                        {"attachmentID": attachment_id})
            owner.call("server.stop")
            owner.close()
            assert server.wait(timeout=5) == 0, \
                f"server exit: {server.stderr.read().decode()}"

            print("PASS: TUI control sequences (RIS + alt screen + mouse) "
                  "did not kill the display bridge")
        finally:
            if server.poll() is None:
                try:
                    os.killpg(os.getpgid(server.pid), 9)
                except (OSError, ProcessLookupError):
                    pass
                server.wait(timeout=5)


if __name__ == "__main__":
    main(str(Path(sys.argv[1]).resolve()))
