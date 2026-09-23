#!/bin/zsh
set -euo pipefail

# 独立同步 AppKit 宿主，供 SwiftPM async-main 提前退出问题的完整回归使用。
# 支持 Swift Testing 的运行参数；构建目录继续使用 ASTER_BUILD_PATH。
PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="${ASTER_BUILD_PATH:-$PROJECT_DIR/.build}"
cd "$PROJECT_DIR"
# Swift 6.4 默认的 swiftbuild 按 target 拆测试包且缺 libXCTestSwiftSupport，宿主加载不了；固定用 native。
SWIFT_BUILD_SYSTEM=(--build-system native)
swift build "${SWIFT_BUILD_SYSTEM[@]}" --build-tests --scratch-path "$BUILD_DIR" >/dev/null
BIN_DIR="$(swift build "${SWIFT_BUILD_SYSTEM[@]}" --show-bin-path --scratch-path "$BUILD_DIR")"
PLATFORM_DIR="$(xcrun --sdk macosx --show-sdk-platform-path)"
SPARKLE_FRAMEWORK=$(/usr/bin/find "$BUILD_DIR/artifacts" -maxdepth 5 -type d -name Sparkle.framework -print -quit)
if [[ -z "$SPARKLE_FRAMEWORK" ]]; then
  echo 'Missing Sparkle framework for test host' >&2
  exit 1
fi
TEST_BUNDLE="$BIN_DIR/AsterTerminalPackageTests.xctest/Contents/MacOS/AsterTerminalPackageTests"
HOST_BINARY="$BUILD_DIR/aster-appkit-test-host"
swiftc -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  -F "$PLATFORM_DIR/Developer/Library/Frameworks" -framework Testing \
  -Xlinker -rpath -Xlinker "$PLATFORM_DIR/Developer/Library/Frameworks" \
  Tests/Support/AppKitTestMain.swift -o "$HOST_BINARY"
export DYLD_FRAMEWORK_PATH="${SPARKLE_FRAMEWORK:h}:$PLATFORM_DIR/Developer/Library/Frameworks:$PLATFORM_DIR/Developer/Library/PrivateFrameworks${DYLD_FRAMEWORK_PATH:+:$DYLD_FRAMEWORK_PATH}"
USE_BATCHES="${ASTER_TEST_BATCH_SIZE:-}"
# Swift Testing 的清单模式忽略 filter；定向/重复/报告模式保留原始单宿主语义。
for argument in "$@"; do
  case "$argument" in
    --filter|--filter=*|--skip|--skip=*|--list-tests|--repetitions|--repetitions=*|--repeat-until|--repeat-until=*|--event-stream-output-path|--event-stream-output-path=*|--event-stream-version|--event-stream-version=*|--xunit-output|--xunit-output=*)
      USE_BATCHES="" ;;
  esac
done
if [[ -n "$USE_BATCHES" ]]; then
  RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
  exec python3 scripts/test-batches.py --host "$HOST_BINARY" --bundle "$TEST_BUNDLE" \
    --batch-size "$USE_BATCHES" --output "$BUILD_DIR/test-runs/$RUN_ID" -- "$@"
fi
exec "$HOST_BINARY" --test-bundle-path "$TEST_BUNDLE" "$@"
