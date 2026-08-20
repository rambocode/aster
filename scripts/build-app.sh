#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
# 默认沿用 SwiftPM 的标准构建目录；发布验证或并行开发可显式指定隔离目录，
# 避免与正在运行的调试构建争用同一把 SwiftPM 锁。
BUILD_DIR="${ASTER_BUILD_PATH:-$PROJECT_DIR/.build}"
DIST_DIR="$PROJECT_DIR/dist"
APP_DIR="$DIST_DIR/Aster.app"
CONTENTS_DIR="$APP_DIR/Contents"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ICONSET_DIR="$BUILD_DIR/AsterIcon.iconset"
ICON_PREVIEW_DIR="$BUILD_DIR/icon-preview"

cd "$PROJECT_DIR"
"$PROJECT_DIR/scripts/setup-ghostty.sh"
swift build --scratch-path "$BUILD_DIR" -c release

# 每次从空 bundle 开始，避免删掉源码后旧资源仍残留在交付包。目标路径由项目目录
# 和固定相对路径组成。拒绝符号链接形式的 dist，避免固定文本路径实际跳转到项目外。
if [[ -L "$DIST_DIR" ]]; then
  echo "Refusing to build through symlinked dist directory: $DIST_DIR" >&2
  exit 1
fi
mkdir -p "$DIST_DIR"
if [[ "${DIST_DIR:A}" != "$PROJECT_DIR/dist" ]]; then
  echo "Refusing to build through unexpected dist directory: ${DIST_DIR:A}" >&2
  exit 1
fi
if [[ "$APP_DIR" != "$PROJECT_DIR/dist/Aster.app" ]]; then
  echo "Refusing to clean unexpected app path: $APP_DIR" >&2
  exit 1
fi
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$RESOURCES_DIR" "$ICONSET_DIR" "$ICON_PREVIEW_DIR"
cp "$BUILD_DIR/release/Aster" "$CONTENTS_DIR/MacOS/Aster"
# MCPInstallService 按「与主程序同目录」解析 aster-memory-mcp，分发包必须把这个独立可执行文件
# 一并放进 Contents/MacOS，否则用户在设置页一键安装 MCP 时会报 executableNotFound。
cp "$BUILD_DIR/release/aster-memory-mcp" "$CONTENTS_DIR/MacOS/aster-memory-mcp"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/THIRD-PARTY-NOTICES.md" "$RESOURCES_DIR/THIRD-PARTY-NOTICES.md"
cp -R "$PROJECT_DIR/Resources/shell-integration" "$RESOURCES_DIR/shell-integration"
cp -R "$PROJECT_DIR/Resources/autocomplete" "$RESOURCES_DIR/autocomplete"
cp -R "$PROJECT_DIR/Resources/agent-integration" "$RESOURCES_DIR/agent-integration"
chmod 755 "$RESOURCES_DIR/agent-integration/aster-agent-hook.sh"
cp -R "$PROJECT_DIR/Resources/fonts" "$RESOURCES_DIR/fonts"
# 设置页由签名 Bundle 内的本地网页提供；与 Shell 资源并列复制，运行时不访问网络。
cp -R "$PROJECT_DIR/Resources/settings-ui" "$RESOURCES_DIR/settings-ui"

# Aster 自有 terminfo 在构建期编译进签名 Bundle。运行时只读取资源，不生成隐藏脚本
# 或修改系统数据库；TERMINFO_DIRS 会把该目录放在系统条目前面。
# `aster` 基础条目从引擎自带的 xterm-ghostty 反编译改名生成，能力集与锁定的 Ghostty
# revision 永远一致；仓库源文件只叠加 aster-direct 的 direct-color 差异。67/78 目录
# 原样复制进来，auto 的 TERM 解析（xterm-ghostty）与用户显式配置都依赖它们存在。
GHOSTTY_TERMINFO_DIR="$PROJECT_DIR/Sources/Aster/Ghostty/Resources/terminfo"
ASTER_TERMINFO_SRC="$BUILD_DIR/aster-terminfo.src"
mkdir -p "$RESOURCES_DIR/terminfo"
TERMINFO="$GHOSTTY_TERMINFO_DIR" /usr/bin/infocmp -x xterm-ghostty \
  | sed 's/^xterm-ghostty|ghostty|Ghostty,$/aster|Aster terminal,/' \
  > "$ASTER_TERMINFO_SRC"
# 上游若改了条目头，sed 会静默不匹配；这里显式失败，避免打出没有 aster 条目的包。
if ! grep -q '^aster|Aster terminal,$' "$ASTER_TERMINFO_SRC"; then
  echo "Failed to derive aster terminfo from xterm-ghostty (upstream entry renamed?)" >&2
  exit 1
fi
cat "$PROJECT_DIR/Resources/terminfo/aster.terminfo" >> "$ASTER_TERMINFO_SRC"
/usr/bin/tic -x -o "$RESOURCES_DIR/terminfo" "$ASTER_TERMINFO_SRC"
cp -R "$GHOSTTY_TERMINFO_DIR/67" "$GHOSTTY_TERMINFO_DIR/78" "$RESOURCES_DIR/terminfo/"

# SwiftPM 为 SwiftTerm 的 Metal shader 生成独立资源 Bundle。SwiftTerm 会从标准
# `Contents/Resources` 位置探测该 Bundle；放在 .app 根目录会破坏 macOS 代码签名。
SWIFTTERM_BUNDLE="$BUILD_DIR/release/AsterTerminal_SwiftTerm.bundle"
if [[ ! -d "$SWIFTTERM_BUNDLE" ]]; then
  echo "Missing SwiftTerm resource bundle: $SWIFTTERM_BUNDLE" >&2
  exit 1
fi
cp -R "$SWIFTTERM_BUNDLE" "$RESOURCES_DIR/AsterTerminal_SwiftTerm.bundle"

# HighlighterSwift 把 highlight.js 和主题表放在独立 SwiftPM resource bundle 中。
# 缺失时 `Highlighter()` 会返回 nil，源码预览虽能退化为纯文本，但发布包不应静默
# 丢失已承诺的语法高亮，因此和 SwiftTerm bundle 一样执行强校验。
HIGHLIGHTER_BUNDLE="$BUILD_DIR/release/Highlighter_Highlighter.bundle"
if [[ ! -d "$HIGHLIGHTER_BUNDLE" ]]; then
  echo "Missing Highlighter resource bundle: $HIGHLIGHTER_BUNDLE" >&2
  exit 1
fi
cp -R "$HIGHLIGHTER_BUNDLE" "$RESOURCES_DIR/Highlighter_Highlighter.bundle"

# Aster executable target 的 SwiftPM resource bundle 承载与 XCFramework 同 revision 的
# Ghostty shell integration 和 terminfo。运行时显式从标准 `Contents/Resources` 读取；
# 禁止改放 App 根目录，否则严格代码签名会把它判定为未密封内容。
GHOSTTY_BUNDLE="$BUILD_DIR/release/AsterTerminal_Aster.bundle"
if [[ ! -d "$GHOSTTY_BUNDLE" ]]; then
  echo "Missing Ghostty resource bundle: $GHOSTTY_BUNDLE" >&2
  exit 1
fi
cp -R "$GHOSTTY_BUNDLE" "$RESOURCES_DIR/AsterTerminal_Aster.bundle"

# Quick Look 能稳定地把项目内的矢量源渲染成 1024px PNG；后续尺寸均由同一母版生成，
# 避免图标在不同缩放档位出现构图漂移。
qlmanage -t -s 1024 -o "$ICON_PREVIEW_DIR" "$PROJECT_DIR/Resources/AsterIcon.svg" >/dev/null 2>&1
MASTER_ICON="$ICON_PREVIEW_DIR/AsterIcon.svg.png"

for SPEC in \
  "16 icon_16x16.png" \
  "32 icon_16x16@2x.png" \
  "32 icon_32x32.png" \
  "64 icon_32x32@2x.png" \
  "128 icon_128x128.png" \
  "256 icon_128x128@2x.png" \
  "256 icon_256x256.png" \
  "512 icon_256x256@2x.png" \
  "512 icon_512x512.png" \
  "1024 icon_512x512@2x.png"; do
  SIZE="${SPEC%% *}"
  NAME="${SPEC#* }"
  sips -z "$SIZE" "$SIZE" "$MASTER_ICON" --out "$ICONSET_DIR/$NAME" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AsterIcon.icns"
SIGN_IDENTITY="${ASTER_SIGN_IDENTITY:--}"
if [[ "$SIGN_IDENTITY" == "-" ]]; then
  codesign --force --deep --sign - --timestamp=none "$APP_DIR"
else
  codesign --force --deep --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP_DIR"
fi

# 必须执行最终 App 内的真实资源加载代码。只检查目录存在或 codesign 无法发现
# `Bundle.module` 回退到构建机绝对路径这类“本机可开、新电脑崩溃”的发布缺陷。
"$CONTENTS_DIR/MacOS/Aster" --verify-packaged-resources

echo "$APP_DIR"
