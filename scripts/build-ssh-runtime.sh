#!/usr/bin/env bash
# 构建 aster-ssh（原生 SSH 运行时，Rust + russh），输出到 SwiftPM 的构建目录，
# 供 build-app.sh 复制进 Contents/MacOS/。开发构建（swift build）时也可以直接跑本脚本，
# 输出到 .build/debug，App 会在主程序同目录下找到它。
#
# 两个 macOS 架构都装了 Rust target 时产出通用二进制；缺哪个就只构建本机架构并提示。
#
# 用法：scripts/build-ssh-runtime.sh [输出目录]   默认 .build/release
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="$PROJECT_DIR/SshRuntime"
BUILD_DIR="${ASTER_BUILD_PATH:-$PROJECT_DIR/.build}"
OUT_DIR="${1:-$BUILD_DIR/release}"
CARGO="${CARGO:-$(command -v cargo || true)}"
if [[ -z "$CARGO" ]]; then
  echo "error: cargo is required to build aster-ssh (brew install rust 或 rustup)" >&2
  exit 1
fi

# rustup 管理的工具链才能按 target 交叉编译；Homebrew 的 rust 只有本机 target。
installed_targets=""
if command -v rustup >/dev/null 2>&1; then
  installed_targets="$(rustup target list --installed 2>/dev/null || true)"
fi
host_target="$(uname -m | sed 's/arm64/aarch64/')-apple-darwin"
targets=()
for target in aarch64-apple-darwin x86_64-apple-darwin; do
  if grep -qx "$target" <<<"$installed_targets"; then targets+=("$target"); fi
done
if [[ ${#targets[@]} -lt 2 ]]; then
  echo "note: 未同时安装两个 macOS Rust target，只构建本机架构 $host_target" >&2
  targets=("$host_target")
fi

echo "== aster-ssh: building ${targets[*]}"
built=()
for target in "${targets[@]}"; do
  if [[ "$target" == "$host_target" && ${#targets[@]} -eq 1 ]]; then
    # 单架构时不加 --target，兼容没有 rustup 的 Homebrew 工具链。
    (cd "$RUNTIME_DIR" && "$CARGO" build --release --locked)
    built+=("$RUNTIME_DIR/target/release/aster-ssh")
  else
    (cd "$RUNTIME_DIR" && "$CARGO" build --release --locked --target "$target")
    built+=("$RUNTIME_DIR/target/$target/release/aster-ssh")
  fi
done

mkdir -p "$OUT_DIR"
if [[ ${#built[@]} -gt 1 ]]; then
  lipo -create -output "$OUT_DIR/aster-ssh" "${built[@]}"
else
  cp "${built[0]}" "$OUT_DIR/aster-ssh"
fi
chmod 755 "$OUT_DIR/aster-ssh"
"$OUT_DIR/aster-ssh" --version >/dev/null
echo "$OUT_DIR/aster-ssh"
