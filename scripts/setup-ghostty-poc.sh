#!/usr/bin/env bash
# 从锁定的 Ghostty revision 构建单 Pane PoC 所需的静态 XCFramework 与资源。
# 二进制和生成资源都保持 gitignored；revision stamp 防止旧 ABI 被误当成当前工件。
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
prototype_dir="$repo_root/Prototypes/GhosttyPane"
framework_dir="$prototype_dir/GhosttyKit.xcframework"
resource_dir="$prototype_dir/Sources/GhosttyPane/Resources"
stamp_file="$prototype_dir/.ghostty-revision"
ghostty_repo="https://github.com/ghostty-org/ghostty"
ghostty_revision="4dcb09ada0c0909717d92547623b26eafa50ca8a"
zig_binary="$(brew --prefix zig@0.15 2>/dev/null || true)/bin/zig"
force_rebuild="${ASTER_GHOSTTY_FORCE_REBUILD:-0}"

if [[ "$force_rebuild" != "0" && "$force_rebuild" != "1" ]]; then
  echo "error: ASTER_GHOSTTY_FORCE_REBUILD must be 0 or 1" >&2
  exit 1
fi

if [[ "$force_rebuild" != "1" && -d "$framework_dir" && -d "$resource_dir/terminfo" && -f "$stamp_file" ]] &&
   [[ "$(<"$stamp_file")" == "$ghostty_revision" ]]; then
  echo "Ghostty PoC artifacts already match $ghostty_revision"
  exit 0
fi

if [[ ! -x "$zig_binary" ]]; then
  echo "error: Zig 0.15.2 is required; install it with: brew install zig@0.15" >&2
  exit 1
fi
if [[ "$("$zig_binary" version)" != "0.15.2" ]]; then
  echo "error: Ghostty PoC is pinned to Zig 0.15.2, found $("$zig_binary" version)" >&2
  exit 1
fi

if ! xcrun metal --version >/dev/null 2>&1; then
  echo "error: Xcode Metal Toolchain is required; install it with: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT

echo "Fetching Ghostty $ghostty_revision"
git init -q "$build_dir"
git -C "$build_dir" remote add origin "$ghostty_repo"
git -C "$build_dir" fetch -q --depth 1 origin "$ghostty_revision"
git -C "$build_dir" -c advice.detachedHead=false checkout -q FETCH_HEAD

echo "Building GhosttyKit.xcframework"
(
  cd "$build_dir"
  "$zig_binary" build \
    -Doptimize=ReleaseFast \
    -Demit-xcframework=true \
    -Dxcframework-target=native \
    -Demit-macos-app=false
)

# 先完整生成在临时目录，再替换明确的 PoC 路径。构建失败不会破坏上一次可用工件。
staging_dir="$build_dir/aster-stage"
mkdir -p "$staging_dir/Resources/ghostty"
cp -R "$build_dir/macos/GhosttyKit.xcframework" "$staging_dir/GhosttyKit.xcframework"
cp -R "$build_dir/zig-out/share/ghostty/shell-integration" "$staging_dir/Resources/ghostty/"
cp -R "$build_dir/zig-out/share/ghostty/themes" "$staging_dir/Resources/ghostty/"
cp -R "$build_dir/zig-out/share/terminfo" "$staging_dir/Resources/terminfo"

shopt -s nullglob
headers=("$staging_dir"/GhosttyKit.xcframework/macos-*/Headers/ghostty.h)
shopt -u nullglob
if [[ "${#headers[@]}" -ne 1 ]] || ! /usr/bin/grep -q 'ghostty_surface_new' "${headers[0]}"; then
  echo "error: generated GhosttyKit is missing the required surface API" >&2
  exit 1
fi
if [[ ! -d "$staging_dir/Resources/ghostty/shell-integration" ]] ||
   [[ ! -f "$staging_dir/Resources/terminfo/78/xterm-ghostty" ]]; then
  echo "error: generated Ghostty runtime resources are incomplete" >&2
  exit 1
fi

rm -rf "$framework_dir" "$resource_dir/ghostty" "$resource_dir/terminfo"
cp -R "$staging_dir/GhosttyKit.xcframework" "$framework_dir"
cp -R "$staging_dir/Resources/ghostty" "$resource_dir/ghostty"
cp -R "$staging_dir/Resources/terminfo" "$resource_dir/terminfo"
printf '%s\n' "$ghostty_revision" > "$stamp_file"

echo "Ghostty PoC artifacts ready"
