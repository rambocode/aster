#!/usr/bin/env bash
# 从锁定的 Ghostty revision 生成 Aster 主程序使用的静态 XCFramework 与运行时资源。
# 所有产物先在临时目录完成并校验，再原子替换仓库内明确的 gitignored 路径。
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
framework_dir="$repo_root/Vendor/GhosttyKit.xcframework"
resource_dir="$repo_root/Sources/Aster/Ghostty/Resources"
stamp_file="$repo_root/Vendor/Ghostty/.ghostty-revision"
patch_file="$repo_root/Vendor/Ghostty/patches/0001-aster-extension-abi.patch"
ghostty_repo="https://github.com/ghostty-org/ghostty"
ghostty_revision="4dcb09ada0c0909717d92547623b26eafa50ca8a"
zig_binary="$(brew --prefix zig@0.15 2>/dev/null || true)/bin/zig"
force_rebuild="${ASTER_GHOSTTY_FORCE_REBUILD:-0}"

if [[ ! -f "$patch_file" ]]; then
  echo "error: missing Aster Ghostty extension patch: $patch_file" >&2
  exit 1
fi
patch_digest="$(/usr/bin/shasum -a 256 "$patch_file" | /usr/bin/awk '{print $1}')"
artifact_key="$ghostty_revision:$patch_digest"

if [[ "$force_rebuild" != "0" && "$force_rebuild" != "1" ]]; then
  echo "error: ASTER_GHOSTTY_FORCE_REBUILD must be 0 or 1" >&2
  exit 1
fi

if [[ "$force_rebuild" != "1" && -d "$framework_dir" && -d "$resource_dir/terminfo" && -f "$stamp_file" ]] &&
   [[ "$(<"$stamp_file")" == "$artifact_key" ]]; then
  echo "Ghostty artifacts already match $artifact_key"
  exit 0
fi

if [[ ! -x "$zig_binary" ]]; then
  echo "error: Zig 0.15.2 is required; install it with: brew install zig@0.15" >&2
  exit 1
fi
if [[ "$("$zig_binary" version)" != "0.15.2" ]]; then
  echo "error: Aster is pinned to Zig 0.15.2, found $("$zig_binary" version)" >&2
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

echo "Applying Aster extension ABI patch $patch_digest"
git -C "$build_dir" apply --check "$patch_file"
git -C "$build_dir" apply "$patch_file"

echo "Building GhosttyKit.xcframework"
(
  cd "$build_dir"
  "$zig_binary" build \
    -Doptimize=ReleaseFast \
    -Demit-xcframework=true \
    -Dxcframework-target=native \
    -Demit-macos-app=false
)

staging_dir="$build_dir/aster-stage"
mkdir -p "$staging_dir/Resources/ghostty" "$repo_root/Vendor/Ghostty"
cp -R "$build_dir/macos/GhosttyKit.xcframework" "$staging_dir/GhosttyKit.xcframework"
cp -R "$build_dir/zig-out/share/ghostty/shell-integration" "$staging_dir/Resources/ghostty/"
cp -R "$build_dir/zig-out/share/ghostty/themes" "$staging_dir/Resources/ghostty/"
cp -R "$build_dir/zig-out/share/terminfo" "$staging_dir/Resources/terminfo"

shopt -s nullglob
headers=("$staging_dir"/GhosttyKit.xcframework/macos-*/Headers/ghostty.h)
shopt -u nullglob
if [[ "${#headers[@]}" -ne 1 ]] ||
   ! /usr/bin/grep -q 'GHOSTTY_ASTER_EXTENSION_ABI_VERSION 1u' "${headers[0]}" ||
   ! /usr/bin/grep -q 'ghostty_aster_surface_search' "${headers[0]}"; then
  echo "error: generated GhosttyKit is missing the required Aster ABI v1" >&2
  exit 1
fi
if [[ ! -d "$staging_dir/Resources/ghostty/shell-integration" ]] ||
   [[ ! -f "$staging_dir/Resources/terminfo/78/xterm-ghostty" ]]; then
  echo "error: generated Ghostty runtime resources are incomplete" >&2
  exit 1
fi

rm -rf "$framework_dir" "$resource_dir/ghostty" "$resource_dir/terminfo"
mkdir -p "$resource_dir"
cp -R "$staging_dir/GhosttyKit.xcframework" "$framework_dir"
cp -R "$staging_dir/Resources/ghostty" "$resource_dir/ghostty"
cp -R "$staging_dir/Resources/terminfo" "$resource_dir/terminfo"
printf '%s\n' "$artifact_key" > "$stamp_file"

echo "Ghostty artifacts ready"
