#!/usr/bin/env bash
# Run the opt-in real AppKit/Ghostty integration in this worktree.
set -euo pipefail
runtime_dir="$(cd "$(dirname "$0")/.." && pwd)"
repo_dir="$(cd "$runtime_dir/.." && pwd)"
"$runtime_dir/scripts/build-vt.sh" native
cd "$runtime_dir"
zig build -Dvt-prefix=.build/vt-host
export ASTER_SESSION_PROBE_BINARY="$runtime_dir/zig-out/bin/aster-session"
cd "$repo_dir"
exec ./scripts/test.sh --no-parallel --filter remoteBridgeRendersAndReattachesInGhosttyWindow
