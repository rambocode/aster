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
# 24 套内置主题的原始文件。首次启动由 AppPreferences 复制到 ~/.config/aster/themes，
# 用户机器上装没装 Otty 都不影响初始化；缺了这一步只会回落到代码内真值表。
cp -R "$PROJECT_DIR/Resources/themes" "$RESOURCES_DIR/themes"

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

# Sparkle 以 dynamic XCFramework 分发。SwiftPM 在非 Xcode 构建下只在链接期提供
# -F/-framework，既不会把 framework 嵌进 .app，也不会写 LC_RPATH（rpath 由
# Package.swift 的 linkerSettings 手写）。产物落点由 SwiftPM 的 artifacts 布局
# （artifacts/<package-identity>/<target>/）决定，该布局历史上变过一次，因此显式
# 探测而不写死路径；找不到即失败，绝不能打出一个"没有更新器"的分发包。
SPARKLE_XCFRAMEWORK=$(/usr/bin/find "$BUILD_DIR/artifacts" -maxdepth 3 -type d -name "Sparkle.xcframework" -print -quit)
if [[ -z "$SPARKLE_XCFRAMEWORK" ]]; then
  echo "Missing Sparkle XCFramework under $BUILD_DIR/artifacts (run 'swift build' so SwiftPM resolves the binary artifact)" >&2
  exit 1
fi

# Sparkle 的 XCFramework 只含一个 macOS slice。命中 0 个或多个都说明上游布局变了
# （例如拆出 Catalyst slice），与其猜一个不如显式失败，避免把错误架构打进签名 Bundle。
SPARKLE_SLICES=("${(@f)$(/usr/bin/find "$SPARKLE_XCFRAMEWORK" -mindepth 2 -maxdepth 2 -type d -name "Sparkle.framework")}")
if (( ${#SPARKLE_SLICES} != 1 )) || [[ -z "${SPARKLE_SLICES[1]}" ]]; then
  echo "Expected exactly one Sparkle.framework slice in $SPARKLE_XCFRAMEWORK, found ${#SPARKLE_SLICES}" >&2
  exit 1
fi
SPARKLE_FRAMEWORK="${SPARKLE_SLICES[1]}"

# 逐层签名按固定相对路径寻址 Versions/B 下的 helper。结构不符即失败，而不是签一个
# 空壳、等到用户机器上更新失败才发现。
for REQUIRED in \
  "Versions/B/Sparkle" \
  "Versions/B/Autoupdate" \
  "Versions/B/Updater.app" \
  "Versions/B/XPCServices/Installer.xpc" \
  "Versions/B/XPCServices/Downloader.xpc"; do
  if [[ ! -e "$SPARKLE_FRAMEWORK/$REQUIRED" ]]; then
    echo "Sparkle framework layout changed, missing: $REQUIRED (in $SPARKLE_FRAMEWORK)" >&2
    exit 1
  fi
done

# framework 内含符号链接（Versions/Current 以及顶层 Sparkle/Resources/XPCServices），
# codesign 对 framework 的密封依赖这套标准 Versions 布局。ditto 是 Apple 明确背书用于
# 复制签名 bundle 的工具，会连同扩展属性与权限位一并保留；build-dmg.sh 也在用它。
SPARKLE_IN_APP="$CONTENTS_DIR/Frameworks/Sparkle.framework"
mkdir -p "$CONTENTS_DIR/Frameworks"
ditto "$SPARKLE_FRAMEWORK" "$SPARKLE_IN_APP"

# 母版必须由真正保留 alpha 的矢量渲染器生成；后续尺寸均由同一母版派生，避免
# 图标在不同缩放档位出现构图漂移。
# 这里刻意不用 qlmanage -t：Quick Look 缩略图管线会把 SVG 合成到不透明白页上，
# 生成的 icns 四角是白色而不是透明；macOS 26 再给 Dock 图标套圆角遮罩，就会露出
# 一圈白框。缺少渲染器时必须硬失败，绝不静默回退成白底。
if ! command -v rsvg-convert >/dev/null 2>&1; then
  echo "缺少 rsvg-convert（应用图标母版渲染器）。请先执行：brew install librsvg" >&2
  exit 1
fi
MASTER_ICON="$ICON_PREVIEW_DIR/AsterIcon.png"
rsvg-convert -w 1024 -h 1024 -b none \
  "$PROJECT_DIR/Resources/AsterIcon.svg" -o "$MASTER_ICON"

# 白底回归是静默的（图标照常生成，只是多了一圈白），所以在这里直接验四角 alpha。
python3 - "$MASTER_ICON" <<'PYICON'
import struct, sys, zlib

path = sys.argv[1]
data = open(path, 'rb').read()
pos, idat, width, channels = 8, b'', 0, 4
while pos < len(data):
    length = struct.unpack('>I', data[pos:pos + 4])[0]
    kind = data[pos + 4:pos + 8]
    chunk = data[pos + 8:pos + 8 + length]
    if kind == b'IHDR':
        width, _, _, color = struct.unpack('>IIBB', chunk[:10])
        if color != 6:
            sys.exit('图标母版不是 RGBA，无法验证透明度：%s' % path)
    elif kind == b'IDAT':
        idat += chunk
    pos += 12 + length
raw = zlib.decompress(idat)
stride = width * channels
# 只需要第 3 行，逐行反 filter 到该行即可（Paeth 依赖上一行，不能跳过）。
prev, row = bytearray(stride), bytearray(stride)
offset = 0
for _ in range(3):
    filt = raw[offset]
    offset += 1
    row = bytearray(raw[offset:offset + stride])
    offset += stride
    for i in range(stride):
        a = row[i - channels] if i >= channels else 0
        b = prev[i]
        c = prev[i - channels] if i >= channels else 0
        if filt == 1:
            row[i] = (row[i] + a) & 255
        elif filt == 2:
            row[i] = (row[i] + b) & 255
        elif filt == 3:
            row[i] = (row[i] + (a + b) // 2) & 255
        elif filt == 4:
            p = a + b - c
            pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
            row[i] = (row[i] + (a if pa <= pb and pa <= pc else b if pb <= pc else c)) & 255
    prev = row
if row[2 * channels + 3] != 0:
    sys.exit('图标母版左上角不透明（alpha=%d），圆角外应为全透明：%s' % (row[2 * channels + 3], path))
PYICON

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
  # ad-hoc 分支刻意不加 --options runtime。开启 hardened runtime 等同开启 Library
  # Validation，而 ad-hoc 签名没有 Team ID，dyld 会拒绝加载同为 ad-hoc 的
  # Sparkle.framework，App 在启动时就崩。这条性质必须刻意维持，不要"顺手统一"两个分支。
  SIGN=(codesign --force --sign - --timestamp=none)
  SIGN_KEEP_ENTITLEMENTS=("${SIGN[@]}")
else
  # 公证要求每一个嵌套可执行文件都带 Developer ID + hardened runtime + 安全时间戳。
  SIGN=(codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY")
  # Downloader.xpc 自带 entitlements（沙箱形态下使用），重签必须原样保留。参数与其它
  # 目标不同，这正是不能用 --deep 一把梭的直接原因。
  SIGN_KEEP_ENTITLEMENTS=(codesign --force --options runtime --timestamp \
    --preserve-metadata=entitlements --sign "$SIGN_IDENTITY")
fi

# 由内向外逐层签名，顺序不可颠倒：codesign 把子项的 CDHash 密封进父层签名，先签外层
# 会在签完内层的瞬间失效。顺序与 Sparkle 官方文档一致。
#
# 这里不能用 --deep：Sparkle 出厂时 XPC services / Autoupdate / Updater.app 都是
# ad-hoc 签名，必须重签才能过公证；而 --deep 会用同一套参数覆盖所有嵌套项，吃掉
# Downloader.xpc 的 entitlements（Sparkle 文档点名这是常见错误源）。
"${SIGN[@]}"                   "$SPARKLE_IN_APP/Versions/B/XPCServices/Installer.xpc"
"${SIGN_KEEP_ENTITLEMENTS[@]}" "$SPARKLE_IN_APP/Versions/B/XPCServices/Downloader.xpc"
"${SIGN[@]}"                   "$SPARKLE_IN_APP/Versions/B/Autoupdate"
"${SIGN[@]}"                   "$SPARKLE_IN_APP/Versions/B/Updater.app"
"${SIGN[@]}"                   "$SPARKLE_IN_APP"

# Contents/MacOS 在 codesign 的默认封存规则（CodeResources rules2）里是 nested 目录，
# 主可执行文件之外的二进制不会被外层签名覆盖。aster-memory-mcp 此前是靠 --deep 顺带
# 签上的，去掉 --deep 后必须显式补签，否则 --verify --deep --strict 与公证都会失败。
"${SIGN[@]}" "$CONTENTS_DIR/MacOS/aster-memory-mcp"

# 最后签外层 App：Frameworks/ 与 MacOS/ 下已签好的嵌套代码在这一步被密封进 CodeResources。
"${SIGN[@]}" "$APP_DIR"

# 分层签名漏掉任何一层都要在打 DMG 之前暴露，而不是等到公证被拒。
# --deep 用于「校验」是正确用法，只有用于「签名」才有问题。
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

# rpath 写错或 framework 没拷进来只会在运行时崩，静态检查看不出来；这里显式断言，
# 与下面的 --verify-packaged-resources 一起构成更新器的链接冒烟测试。
if ! /usr/bin/otool -l "$CONTENTS_DIR/MacOS/Aster" | grep -q "@executable_path/../Frameworks"; then
  echo "Aster executable is missing the @executable_path/../Frameworks rpath; Sparkle will fail to load" >&2
  exit 1
fi

# 必须执行最终 App 内的真实资源加载代码。只检查目录存在或 codesign 无法发现
# `Bundle.module` 回退到构建机绝对路径这类“本机可开、新电脑崩溃”的发布缺陷。
"$CONTENTS_DIR/MacOS/Aster" --verify-packaged-resources

echo "$APP_DIR"
