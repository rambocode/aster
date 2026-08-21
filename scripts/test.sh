#!/bin/zsh
set -euo pipefail

# Aster 链接 Sparkle 这个动态 framework，主可执行文件的 rpath 是
# @executable_path/../Frameworks —— 对 .app 布局正确，但 xctest 宿主位于
# .build/<config>/*.xctest/Contents/MacOS/ 下，该相对路径指向一个不存在的目录，
# 测试进程会在 dyld 阶段报 "Library not loaded: @rpath/Sparkle.framework/…"。
# SwiftPM 不会像 Xcode 那样为动态 binaryTarget 注入搜索路径（swiftlang/swift-package-manager#4514），
# 因此在这里显式把 artifacts 里的 framework 目录喂给 DYLD_FRAMEWORK_PATH。
# .build 下的测试二进制没有 hardened runtime，DYLD_* 对它有效。
PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="${ASTER_BUILD_PATH:-$PROJECT_DIR/.build}"

cd "$PROJECT_DIR"
# 先解析依赖，保证首次运行时 artifacts 已经解压出来再去探测路径。
swift build --scratch-path "$BUILD_DIR" >/dev/null

SPARKLE_FRAMEWORK=$(/usr/bin/find "$BUILD_DIR/artifacts" -maxdepth 5 -type d -name "Sparkle.framework" -print -quit)
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
  echo "Missing Sparkle.framework under $BUILD_DIR/artifacts; run 'swift build' first" >&2
  exit 1
fi

DYLD_FRAMEWORK_PATH="${SPARKLE_FRAMEWORK:h}" exec swift test --scratch-path "$BUILD_DIR" "$@"
