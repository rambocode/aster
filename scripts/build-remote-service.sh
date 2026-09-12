#!/usr/bin/env bash
# 交叉构建远端 aster-session 服务产物并生成安装清单，供 App 内「添加机器 / 更新远端服务」安装。
#
# 产出目录（build-app.sh 会整体复制进 Contents/Resources/remote-service/）：
#   dist/remote-service/<platform>-<arch>/aster-session
#   dist/remote-service/<platform>-<arch>/manifest.json
#
# 清单字段与 AsterCore.RemoteReleaseManifest 一一对应。目前没有正式的发布签名基础设施，
# 因此 artifactKind 固定写 developmentBuild：App 会在安装前弹出「未签名开发产物」确认。
# 接入真实签名后把 artifactKind 改成 managedRelease 并填入 signature。
#
# 用法：scripts/build-remote-service.sh [target ...]
#   默认 target：x86_64-linux-musl aarch64-linux-musl
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
RUNTIME_DIR="$PROJECT_DIR/SessionRuntime"
OUT_ROOT="$PROJECT_DIR/dist/remote-service"
ZIG="${ZIG:-$(brew --prefix zig@0.15 2>/dev/null || true)/bin/zig}"
if [[ ! -x "$ZIG" ]]; then ZIG="$(command -v zig || true)"; fi
if [[ -z "$ZIG" || "$("$ZIG" version)" != "0.15.2" ]]; then
  echo "error: Zig 0.15.2 is required (brew install zig@0.15)" >&2
  exit 1
fi

targets=("$@")
if [[ ${#targets[@]} -eq 0 ]]; then targets=(x86_64-linux-musl aarch64-linux-musl); fi

# 版本：Info.plist 的 CFBundleShortVersionString + 短 commit，与 App 自身版本可对照。
app_version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PROJECT_DIR/Resources/Info.plist" 2>/dev/null || echo 0.0.0)"
commit="$(git -C "$PROJECT_DIR" rev-parse --short=12 HEAD 2>/dev/null || echo unknown)"
version="${app_version}+${commit}"
# 协议主/次版本来自客户端契约常量，避免手写漂移。
protocol_major="$(grep -oE 'clientProtocolMajor = [0-9]+' "$PROJECT_DIR/Sources/AsterCore/RemoteHostProbe.swift" | grep -oE '[0-9]+$')"

for target in "${targets[@]}"; do
  case "$target" in
    x86_64-linux-musl) platform=linux; arch=x86_64; vt_prefix="$RUNTIME_DIR/.build/vt-linux" ;;
    aarch64-linux-musl) platform=linux; arch=arm64; vt_prefix="$RUNTIME_DIR/.build/vt-$target" ;;
    aarch64-macos) platform=macos; arch=arm64; vt_prefix="$RUNTIME_DIR/.build/vt-$target" ;;
    x86_64-macos) platform=macos; arch=x86_64; vt_prefix="$RUNTIME_DIR/.build/vt-$target" ;;
    *) echo "error: unsupported target $target" >&2; exit 2 ;;
  esac

  # libghostty-vt 只跟锁定的 ghostty revision 与补丁集有关，构建一次可长期复用；
  # 已有产物时跳过，ASTER_REMOTE_SERVICE_REBUILD_VT=1 强制重建。
  if [[ "${ASTER_REMOTE_SERVICE_REBUILD_VT:-0}" == "1" || ! -f "$vt_prefix/lib/libghostty-vt.a" ]]; then
    echo "== $target: building libghostty-vt"
    (cd "$RUNTIME_DIR" && PATH="$(dirname "$ZIG"):$PATH" scripts/build-vt.sh "$target")
  else
    echo "== $target: reusing libghostty-vt at $vt_prefix"
  fi

  echo "== $target: building aster-session"
  build_prefix="$RUNTIME_DIR/.build/service-$target"
  rm -rf "$build_prefix"
  (cd "$RUNTIME_DIR" && "$ZIG" build -Dtarget="$target" -Doptimize=ReleaseSafe \
    -Dvt-prefix="$vt_prefix" --prefix "$build_prefix")
  binary="$build_prefix/bin/aster-session"
  [[ -f "$binary" ]] || { echo "error: $binary not produced" >&2; exit 1; }

  out_dir="$OUT_ROOT/$platform-$arch"
  rm -rf "$out_dir"
  mkdir -p "$out_dir"
  cp "$binary" "$out_dir/aster-session"
  chmod 755 "$out_dir/aster-session"
  sha256="$(/usr/bin/shasum -a 256 "$out_dir/aster-session" | awk '{print $1}')"
  size="$(stat -f %z "$out_dir/aster-session")"
  cat > "$out_dir/manifest.json" <<JSON
{
  "version": "$version",
  "platform": "$platform",
  "architecture": "$arch",
  "sha256": "$sha256",
  "sizeBytes": $size,
  "artifactKind": "developmentBuild",
  "protocolMajor": $protocol_major
}
JSON
  echo "== $target: $out_dir ($size bytes, sha256 ${sha256:0:12})"
done
echo "remote-service artifacts ready under $OUT_ROOT"
