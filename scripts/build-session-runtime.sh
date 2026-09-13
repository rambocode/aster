#!/usr/bin/env bash
# 原生构建 macOS 版 aster-session（本机后台受管终端服务），输出到 SwiftPM 的 release 目录，
# 供 build-app.sh 复制进 Contents/MacOS/。没有它，打包版的 Local 受管模式（关窗口不杀进程、
# 冷恢复、Agent 原生恢复）整个不可用。
#
# libghostty-vt（.build/vt-host）只跟锁定的 ghostty revision 与补丁集有关，构建一次长期复用；
# ASTER_SESSION_RUNTIME_REBUILD_VT=1 强制重建。
#
# 用法：scripts/build-session-runtime.sh [输出目录]   默认 .build/release
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="$PROJECT_DIR/SessionRuntime"
BUILD_DIR="${ASTER_BUILD_PATH:-$PROJECT_DIR/.build}"
OUT_DIR="${1:-$BUILD_DIR/release}"
ZIG="${ZIG:-$(brew --prefix zig@0.15 2>/dev/null || true)/bin/zig}"
if [[ ! -x "$ZIG" ]]; then ZIG="$(command -v zig || true)"; fi
if [[ -z "$ZIG" || "$("$ZIG" version)" != "0.15.2" ]]; then
  echo "error: Zig 0.15.2 is required to build aster-session (brew install zig@0.15)" >&2
  exit 1
fi

vt_prefix="$RUNTIME_DIR/.build/vt-host"
if [[ "${ASTER_SESSION_RUNTIME_REBUILD_VT:-0}" == "1" || ! -f "$vt_prefix/lib/libghostty-vt.a" ]]; then
  echo "== aster-session: building libghostty-vt (native)"
  (cd "$RUNTIME_DIR" && PATH="$(dirname "$ZIG"):$PATH" scripts/build-vt.sh native)
fi

echo "== aster-session: building native binary"
stage="$RUNTIME_DIR/.build/service-native"
rm -rf "$stage"
(cd "$RUNTIME_DIR" && "$ZIG" build -Doptimize=ReleaseSafe -Dvt-prefix="$vt_prefix" --prefix "$stage")
[[ -f "$stage/bin/aster-session" ]] || { echo "error: aster-session not produced" >&2; exit 1; }
"$stage/bin/aster-session" --version >/dev/null

mkdir -p "$OUT_DIR"
cp "$stage/bin/aster-session" "$OUT_DIR/aster-session"
chmod 755 "$OUT_DIR/aster-session"
echo "$OUT_DIR/aster-session"
