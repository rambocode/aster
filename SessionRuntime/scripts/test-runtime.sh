#!/usr/bin/env bash
# Reproducible native P0 runtime verification; AppKit runs separately.
set -euo pipefail
runtime_dir="$(cd "$(dirname "$0")/.." && pwd)"
"$runtime_dir/scripts/build-vt.sh" native
cd "$runtime_dir"
zig build -Dvt-prefix=.build/vt-host
zig build test-reactor test-startup test-pool -Dvt-prefix=.build/vt-host --summary all
python3 tests/probe.py zig-out/bin/aster-session
python3 tests/handshake_gate.py zig-out/bin/aster-session
python3 tests/snapshot_gate.py zig-out/bin/aster-session
python3 tests/bridge_pty.py zig-out/bin/aster-session

python3 tests/graphics_service.py zig-out/bin/aster-session

python3 tests/delta_service.py zig-out/bin/aster-session
python3 tests/delta_gate.py zig-out/bin/aster-session

python3 tests/service_server.py zig-out/bin/aster-session

python3 tests/service_client.py zig-out/bin/aster-session

python3 tests/service_launch.py zig-out/bin/aster-session

python3 tests/service_stop.py zig-out/bin/aster-session
