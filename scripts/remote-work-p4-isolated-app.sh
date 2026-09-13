#!/bin/zsh
set -euo pipefail

# 组装一个**完全隔离**的调试 Aster.app，只用于远程工作模式 P4 的真实 UI 验收。
#
# 为什么要单独一个脚本：验收要在真实运行的 App 上点击机器侧栏、看离线灰显、跑
# 「App → ssh → 远端受管终端」显示桥，但绝不能启动用户自己的 /Applications/Aster.app，
# 也不能写用户的 defaults 域 io.local.aster-terminal。所以这里换掉 CFBundleIdentifier
# （独立 defaults 域）、把产物放进忽略的 .build 目录，并要求调用方另行提供
# ASTER_CONTROL_SOCKET_PATH 指向 0700 私有目录。build-app.sh 是发布路径，不能复用。
#
# 用法：scripts/remote-work-p4-isolated-app.sh <输出目录> <bundle-id>

PROJECT_DIR="${0:A:h:h}"
OUT_DIR="${1:?usage: remote-work-p4-isolated-app.sh <out-dir> <bundle-id>}"
BUNDLE_ID="${2:?usage: remote-work-p4-isolated-app.sh <out-dir> <bundle-id>}"
BUILD_DIR="${ASTER_BUILD_PATH:-$PROJECT_DIR/.build}"
APP_DIR="$OUT_DIR/Aster.app"
CONTENTS_DIR="$APP_DIR/Contents"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$PROJECT_DIR"
# 调试构建即可：验收看的是行为，不是发布产物；release 构建会与并行开发争 SwiftPM 锁。
swift build --scratch-path "$BUILD_DIR" >/dev/null

rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$RESOURCES_DIR"
cp "$BUILD_DIR/debug/Aster" "$CONTENTS_DIR/MacOS/Aster"
cp "$BUILD_DIR/debug/aster-cli" "$CONTENTS_DIR/MacOS/aster-cli"
cp "$BUILD_DIR/debug/aster-memory-mcp" "$CONTENTS_DIR/MacOS/aster-memory-mcp" 2>/dev/null || true
# 本机受管终端服务：ManagedTerminalCoordinator 只从 Contents/MacOS/aster-session 解析 Local 端点，
# 没它就等于验收不到「关窗口不杀进程 / 冷恢复」。用 release 目录复用 build-app.sh 的产物。
"$PROJECT_DIR/scripts/build-session-runtime.sh" "$BUILD_DIR/release" >/dev/null
cp "$BUILD_DIR/release/aster-session" "$CONTENTS_DIR/MacOS/aster-session"

# Info.plist 逐字复制后只改 bundle id：其余键（最低系统版本、URL scheme、Sparkle feed）
# 保持与真实产物一致，避免因为缺键而走到与用户不同的代码路径。
/usr/bin/plutil -convert xml1 -o "$CONTENTS_DIR/Info.plist" "$PROJECT_DIR/Resources/Info.plist"
/usr/bin/plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$CONTENTS_DIR/Info.plist"
# 关掉自动更新检查：隔离实例绝不能去联网比较版本或替换用户安装。
/usr/bin/plutil -replace SUEnableAutomaticChecks -bool false "$CONTENTS_DIR/Info.plist" 2>/dev/null || \
  /usr/bin/plutil -insert SUEnableAutomaticChecks -bool false "$CONTENTS_DIR/Info.plist"

for resource in shell-integration autocomplete agent-integration fonts settings-ui themes skills; do
  [[ -d "$PROJECT_DIR/Resources/$resource" ]] && cp -R "$PROJECT_DIR/Resources/$resource" "$RESOURCES_DIR/$resource"
done
[[ -f "$RESOURCES_DIR/agent-integration/aster-agent-hook.sh" ]] && chmod 755 "$RESOURCES_DIR/agent-integration/aster-agent-hook.sh"

# SwiftPM 资源 bundle 与 Ghostty 资源：运行时从 Contents/Resources 解析，缺了就起不来。
for bundle in "$BUILD_DIR/debug"/*.bundle; do
  [[ -e "$bundle" ]] && cp -R "$bundle" "$RESOURCES_DIR/"
done
GHOSTTY_RESOURCES="$PROJECT_DIR/Sources/Aster/Ghostty/Resources"
[[ -d "$GHOSTTY_RESOURCES/terminfo" ]] && cp -R "$GHOSTTY_RESOURCES/terminfo" "$RESOURCES_DIR/terminfo"
[[ -d "$GHOSTTY_RESOURCES/shell-integration" ]] && cp -R "$GHOSTTY_RESOURCES/shell-integration" "$RESOURCES_DIR/ghostty-shell-integration"

# Sparkle 在 @executable_path/../Frameworks 上；不放进去主程序直接 dyld 失败。
SPARKLE_FRAMEWORK=$(/usr/bin/find "$BUILD_DIR/artifacts" -maxdepth 5 -type d -name Sparkle.framework -print -quit)
if [[ -n "$SPARKLE_FRAMEWORK" ]]; then
  mkdir -p "$CONTENTS_DIR/Frameworks"
  cp -R "$SPARKLE_FRAMEWORK" "$CONTENTS_DIR/Frameworks/Sparkle.framework"
fi

# ad-hoc 签名：本机运行够用，且不使用用户的发布签名身份。
/usr/bin/codesign --force --sign - --timestamp=none "$APP_DIR" >/dev/null 2>&1 || true
echo "$APP_DIR"
