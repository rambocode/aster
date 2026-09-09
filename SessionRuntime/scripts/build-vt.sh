#!/usr/bin/env bash
# Build only the pinned headless VT library; never invoke the macOS app builder.
set -euo pipefail
runtime_dir="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$runtime_dir/.build/ghostty"
revision=4dcb09ada0c0909717d92547623b26eafa50ca8a
target="${1:-native}"
case "$target" in
  native) output="$runtime_dir/.build/vt-host" ;;
  x86_64-linux-musl) output="$runtime_dir/.build/vt-linux" ;;
  aarch64-linux-musl|aarch64-macos|x86_64-macos) output="$runtime_dir/.build/vt-$target" ;;
  *) echo 'Unsupported VT target' >&2; exit 2 ;;
esac
if [[ "$(zig version)" != 0.15.2 ]]; then
  echo 'Aster session runtime requires Zig 0.15.2' >&2
  exit 1
fi
mkdir -p "$runtime_dir/.build"
if [[ ! -d "$source_dir/.git" ]]; then
  git init -q "$source_dir"
  git -C "$source_dir" remote add origin https://github.com/ghostty-org/ghostty
fi
if ! git -C "$source_dir" cat-file -e "$revision^{commit}" 2>/dev/null; then
  git -C "$source_dir" fetch --depth 1 origin "$revision"
fi
# Verify the complete sequential patch result in an isolated Git index. This
# also permits upgrading an exactly matching earlier prefix of our patch set;
# unrelated local changes are never reset or overwritten.
patch_files=("$runtime_dir/patches/0001-formatter-cursor-order.patch" "$runtime_dir/patches/0002-screen-export.patch" "$runtime_dir/patches/0003-history-budget.patch" "$runtime_dir/patches/0004-history-pages.patch" "$runtime_dir/patches/0005-history-page-release.patch" "$runtime_dir/patches/0006-graphics-metadata-budget.patch")
if [[ -z "$(git -C "$source_dir" status --porcelain --untracked-files=no)" ]]; then
  git -C "$source_dir" -c advice.detachedHead=false checkout -q "$revision"
fi
python3 - "$source_dir" "$revision" "${patch_files[@]}" <<'PYVERIFY'
import os, subprocess, sys, tempfile
source, revision, *patches = sys.argv[1:]
def git(*args, env=None):
    return subprocess.check_output(['git', '-C', source, *args], env=env)
if git('rev-parse', 'HEAD').strip().decode() != revision:
    raise SystemExit('VT source is not at the pinned revision; preserving local changes')
actual = git('diff', '--binary', revision)
with tempfile.TemporaryDirectory(prefix='aster-vt-index-') as temporary:
    env = dict(os.environ, GIT_INDEX_FILE=os.path.join(temporary, 'index'))
    git('read-tree', revision, env=env)
    matching_prefix = 0 if not actual else None
    for index, patch in enumerate(patches, 1):
        git('apply', '--cached', patch, env=env)
        expected = git('diff', '--cached', '--binary', revision, env=env)
        if actual == expected:
            matching_prefix = index
    if matching_prefix is None:
        raise SystemExit('VT source has unexpected local changes; refusing to replace them')
for patch in patches[matching_prefix:]:
    git('apply', '--check', patch)
    git('apply', patch)
PYVERIFY
cd "$source_dir"
zig build -Demit-lib-vt=true -Demit-xcframework=false -Doptimize=ReleaseFast \
  -Dtarget="$target" --prefix "$output"
