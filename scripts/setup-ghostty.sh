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

# Zig 0.15.2 自带的 clang float.h 早于 macOS 27 SDK。27 SDK 的 math.h 在启用 modules 时
# 改由 <float.h> 的 __need_infinity_nan 提供 INFINITY，而 Zig 的 float.h 在 -std=c++17 下
# 不定义它，libc++ 子编译随即报 "use of undeclared identifier 'INFINITY'"。遇到这种 SDK 时
# 改用命令行工具里的 macOS 26 SDK：只拦截 Zig 探测 SDK 的那一条 xcrun 查询，metal 等其余
# 调用仍然交给 Xcode。
zig_path_prefix=""
default_sdk="$(xcrun --sdk macosx --show-sdk-path)"
if /usr/bin/grep -q '__need_infinity_nan' "$default_sdk/usr/include/math.h"; then
  fallback_sdk=""
  for candidate in /Library/Developer/CommandLineTools/SDKs/MacOSX26*.sdk; do
    [[ -d "$candidate" ]] || continue
    /usr/bin/grep -q '__need_infinity_nan' "$candidate/usr/include/math.h" && continue
    fallback_sdk="$candidate"
  done
  if [[ -z "$fallback_sdk" ]]; then
    echo "error: Zig 0.15.2 cannot build libc++ against $(basename "$default_sdk"); install Command Line Tools with a macOS 26 SDK" >&2
    exit 1
  fi
  echo "Using $(basename "$fallback_sdk") for Zig (Zig 0.15.2 is incompatible with $(basename "$default_sdk"))"
  mkdir -p "$build_dir/xcrun-shim"
  cat > "$build_dir/xcrun-shim/xcrun" <<SHIM
#!/bin/sh
if [ "\$1" = "--sdk" ] && [ "\$2" = "macosx" ] && [ "\$3" = "--show-sdk-path" ]; then
  echo "$fallback_sdk"
  exit 0
fi
exec /usr/bin/xcrun "\$@"
SHIM
  chmod +x "$build_dir/xcrun-shim/xcrun"
  zig_path_prefix="$build_dir/xcrun-shim:"
fi

echo "Fetching Ghostty $ghostty_revision"
git init -q "$build_dir"
git -C "$build_dir" remote add origin "$ghostty_repo"
git -C "$build_dir" fetch -q --depth 1 origin "$ghostty_revision"
git -C "$build_dir" -c advice.detachedHead=false checkout -q FETCH_HEAD

echo "Applying Aster extension ABI patch $patch_digest"
# Renderer 的若干新增 hunk 使用最小上下文，避免 vendor patch 的空白 context 被 Git 当成
# 源文件尾随空格；revision 与 patch digest 已共同锁定输入，仍会严格校验已有上下文。
git -C "$build_dir" apply --check --unidiff-zero "$patch_file"
git -C "$build_dir" apply --unidiff-zero "$patch_file"

echo "Building GhosttyKit.xcframework"
(
  cd "$build_dir"
  PATH="$zig_path_prefix$PATH" "$zig_binary" build \
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
libraries=("$staging_dir"/GhosttyKit.xcframework/macos-*/libghostty-internal-fat.a)
shopt -u nullglob
if [[ "${#headers[@]}" -ne 1 ]] ||
   ! /usr/bin/grep -q 'GHOSTTY_ASTER_EXTENSION_ABI_VERSION 1u' "${headers[0]}" ||
   ! /usr/bin/grep -q 'ghostty_aster_surface_search' "${headers[0]}"; then
  echo "error: generated GhosttyKit is missing the required Aster ABI v1" >&2
  exit 1
fi
if [[ "${#libraries[@]}" -ne 1 ]]; then
  echo "error: generated GhosttyKit does not contain exactly one static library" >&2
  exit 1
fi
duplicate_members="$(/usr/bin/ar -t "${libraries[0]}" | LC_ALL=C /usr/bin/sort | /usr/bin/uniq -d)"
if [[ -n "$duplicate_members" ]]; then
  # Mach-O debug maps identify archive members by basename. Duplicate names make dsymutil
  # resolve DWARF against the wrong object and emit misleading missing-symbol warnings.
  echo "error: generated Ghostty archive contains duplicate member names:" >&2
  echo "$duplicate_members" >&2
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
