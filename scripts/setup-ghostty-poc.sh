#!/usr/bin/env bash
# 从锁定的 Ghostty revision 构建单 Pane PoC 所需的静态 XCFramework 与资源。
# 二进制和生成资源都保持 gitignored；revision stamp 防止旧 ABI 被误当成当前工件。
set -euo pipefail

# 主程序和 PoC 必须消费同一份带 Aster 扩展 ABI 的工件，避免历史 PoC 独立构建出
# 未打 patch 的同 revision XCFramework。
"$(cd "$(dirname "$0")" && pwd)/setup-ghostty.sh"

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
prototype_dir="$repo_root/Prototypes/GhosttyPane"
framework_dir="$prototype_dir/GhosttyKit.xcframework"
resource_dir="$prototype_dir/Sources/GhosttyPane/Resources"
stamp_file="$prototype_dir/.ghostty-revision"
rm -rf "$framework_dir" "$resource_dir/ghostty" "$resource_dir/terminfo"
mkdir -p "$resource_dir"
cp -R "$repo_root/Vendor/GhosttyKit.xcframework" "$framework_dir"
cp -R "$repo_root/Sources/Aster/Ghostty/Resources/ghostty" "$resource_dir/ghostty"
cp -R "$repo_root/Sources/Aster/Ghostty/Resources/terminfo" "$resource_dir/terminfo"
cp "$repo_root/Vendor/Ghostty/.ghostty-revision" "$stamp_file"

echo "Ghostty PoC artifacts ready"
