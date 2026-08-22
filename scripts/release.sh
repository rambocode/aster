#!/bin/zsh
set -euo pipefail

# 发布一版 Aster：写版本号 → 构建/签名/公证 DMG → 发 GitHub Release → 生成并推送
# appcast.xml。整条链路有五个「顺序错了就出事」的不变量，靠人脑记必然翻车，因此全部
# 由本脚本承担：
#
#   1. SUFeedURL / SUPublicEDKey 必须在跑 generate_appcast 之前就已在 Info.plist 里。
#   2. staging 目录只能有本次发布的那一个 DMG——generate_appcast 会无条件重写本地
#      存在归档的 item 的 <enclosure>，而 download-url-prefix 含本次 tag，多放一个
#      历史 DMG 就会把老版本的下载链接改坏。
#   3. --download-url-prefix 里的 tag 必须等于实际创建的 Release tag。
#   4. 必须先 gh release create 上传 DMG，再推 appcast.xml。反了会让这段时间内检查
#      更新的用户拿到 404。
#   5. CFBundleVersion 必须严格大于 appcast 里现有的最大 sparkle:version。这是唯一
#      不可逆的错误——发出去的版本号收不回来。
#
# 用法：
#   ./scripts/release.sh --short 0.5.0 --bundle 10
#   ./scripts/release.sh --short 0.5.0-preview.1 --bundle 8 --preview

PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="${ASTER_BUILD_PATH:-$PROJECT_DIR/.build}"
REPO="rambocode/aster"

die() { echo "release: $1" >&2; exit 1 }

SHORT_VERSION=""
BUNDLE_VERSION=""
PREVIEW=0
while (( $# > 0 )); do
  case "$1" in
    --short)   SHORT_VERSION="${2:-}"; shift 2 ;;
    --bundle)  BUNDLE_VERSION="${2:-}"; shift 2 ;;
    --preview) PREVIEW=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

[[ -n "$SHORT_VERSION" ]] || die "--short <CFBundleShortVersionString> is required"
[[ -n "$BUNDLE_VERSION" ]] || die "--bundle <CFBundleVersion> is required"
# Apple 要求 CFBundleVersion 是数字点分串；带 -preview 后缀会让 codesign、
# LaunchServices 与公证的行为不确定，语义版本只放在 CFBundleShortVersionString 里。
[[ "$BUNDLE_VERSION" == <-> ]] || die "--bundle must be a plain integer, got: $BUNDLE_VERSION"

TAG="v$SHORT_VERSION"
CHANNEL=""
(( PREVIEW )) && CHANNEL="preview"

# ---------------------------------------------------------------- 阶段 0：前置校验
# 这一整段不做任何写操作。任何一项不满足都必须在动 git 和 Apple 服务之前失败。

[[ -n "${ASTER_SIGN_IDENTITY:-}" && "$ASTER_SIGN_IDENTITY" != "-" ]] \
  || die "ASTER_SIGN_IDENTITY must be a Developer ID; ad-hoc builds cannot be notarized"
# 预览版同样必须公证：Sparkle 的 SUUpdateValidator 会拒绝「旧包已签名、新包未签名」，
# 且未公证的包过不了 Gatekeeper，用户根本装不上。
# 公证凭据优先使用可复用的钥匙串 profile；CI / 非交互 Agent 无法弹钥匙串授权框时，
# 允许直接注入 App Store Connect API Key 三元组。两条路径最终都只形成 notarytool
# 参数，不把私钥内容写入仓库、日志或命令产物。
NOTARY_ARGS=()
if [[ -n "${ASTER_NOTARY_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$ASTER_NOTARY_PROFILE")
elif [[ -n "${ASTER_NOTARY_KEY:-}" && -n "${ASTER_NOTARY_KEY_ID:-}" \
  && -n "${ASTER_NOTARY_ISSUER:-}" ]]; then
  [[ -f "$ASTER_NOTARY_KEY" ]] || die "ASTER_NOTARY_KEY does not exist"
  NOTARY_ARGS=(
    --key "$ASTER_NOTARY_KEY"
    --key-id "$ASTER_NOTARY_KEY_ID"
    --issuer "$ASTER_NOTARY_ISSUER"
  )
else
  die "set ASTER_NOTARY_PROFILE or ASTER_NOTARY_KEY + ASTER_NOTARY_KEY_ID + ASTER_NOTARY_ISSUER"
fi

cd "$PROJECT_DIR"
[[ -z "$(git status --porcelain)" ]] || die "working tree is not clean"
[[ "$(git rev-parse --abbrev-ref HEAD)" == "master" ]] || die "releases must be cut from master"
git fetch --quiet origin master
[[ "$(git rev-parse HEAD)" == "$(git rev-parse origin/master)" ]] \
  || die "master is not in sync with origin/master"
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  die "tag $TAG already exists on origin"
fi

NOTES="$PROJECT_DIR/docs/release-notes/$SHORT_VERSION.md"
[[ -f "$NOTES" ]] || die "missing release notes: $NOTES"

# Sparkle 的工具随 SwiftPM artifact 分发；先确保依赖已解析。
swift build --scratch-path "$BUILD_DIR" >/dev/null
SPARKLE_BIN=$(/usr/bin/find "$BUILD_DIR/artifacts" -maxdepth 3 -type d -name "bin" -path "*Sparkle*" -print -quit)
[[ -n "$SPARKLE_BIN" && -x "$SPARKLE_BIN/generate_appcast" ]] \
  || die "Sparkle tools not found under $BUILD_DIR/artifacts"

# 公钥与本机私钥不匹配，等于在发一个所有用户都验签失败、永远装不上的更新。
PLIST_KEY=$(plutil -extract SUPublicEDKey raw "$PROJECT_DIR/Resources/Info.plist")
LOCAL_KEY=$("$SPARKLE_BIN/generate_keys" -p)
[[ "$PLIST_KEY" == "$LOCAL_KEY" ]] \
  || die "SUPublicEDKey in Info.plist does not match the signing key in this Mac's keychain"

# 版本单调性：唯一不可逆的错误，必须机器校验。首次发布时 appcast.xml 还不存在。
APPCAST="$PROJECT_DIR/appcast.xml"
MAX_IN_FEED=0
if [[ -f "$APPCAST" ]]; then
  MAX_IN_FEED=$(xmllint --xpath '//*[local-name()="version"]/text()' "$APPCAST" 2>/dev/null \
    | tr ' ' '\n' | sort -n | tail -1)
  MAX_IN_FEED="${MAX_IN_FEED:-0}"
fi
(( BUNDLE_VERSION > MAX_IN_FEED )) \
  || die "CFBundleVersion $BUNDLE_VERSION must exceed $MAX_IN_FEED already published in appcast.xml"

echo "release: $SHORT_VERSION (build $BUNDLE_VERSION)${CHANNEL:+ on the $CHANNEL channel}"

# ------------------------------------------------- 阶段 1：写版本号并推送到 master
# 必须先推，gh release create 才能把 tag 打在已经存在于远端的 commit 上。
plutil -replace CFBundleShortVersionString -string "$SHORT_VERSION" "$PROJECT_DIR/Resources/Info.plist"
plutil -replace CFBundleVersion -string "$BUNDLE_VERSION" "$PROJECT_DIR/Resources/Info.plist"
git add Resources/Info.plist docs/release-notes
git commit -q -m "chore(release): $SHORT_VERSION ($BUNDLE_VERSION)"
git push --quiet origin master
RELEASE_SHA=$(git rev-parse HEAD)

# ---------------------------------------- 阶段 2：构建 + 分层签名 + 公证 + 全套验证
# build-dmg.sh 已经串起 build-app（含 Sparkle 逐层签名）→ 签 DMG → notarytool →
# stapler → hdiutil/spctl 验证，这里不重复其中任何一步。
# build-dmg 会把 notarytool、stapler、hdiutil 和 Gatekeeper 的验收日志写到 stdout，
# 最后一行才是产物路径。直接用整个 stdout 做 DMG_PATH 会在公证全部成功后仍误报
# “did not produce a DMG”。日志继续实时转发到 stderr，只把最后一行收进变量。
DMG_PATH=$("$PROJECT_DIR/scripts/build-dmg.sh" | tee /dev/stderr | tail -n 1)
[[ -f "$DMG_PATH" ]] || die "build-dmg.sh did not produce a DMG"

# -------------------------------------------------------- 阶段 3：先发布 Release 资产
gh release create "$TAG" "$DMG_PATH" \
  --repo "$REPO" \
  --target "$RELEASE_SHA" \
  --title "Aster $SHORT_VERSION" \
  --notes-file "$NOTES" \
  ${CHANNEL:+--prerelease}

# ------------------------------------------------- 阶段 4：再生成并推送 appcast.xml
# staging 每次从空开始，只放本次的 DMG（见文件头不变量 2）。
STAGE="$PROJECT_DIR/dist/appcast-stage"
rm -rf "$STAGE" && mkdir -p "$STAGE"
cp "$DMG_PATH" "$STAGE/"
# 与归档同名、不同扩展名的 md 会被 generate_appcast 识别为该 item 的发行说明。
cp "$NOTES" "$STAGE/${DMG_PATH:t:r}.md"

"$SPARKLE_BIN/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --link "https://github.com/$REPO" \
  --full-release-notes-url "https://github.com/$REPO/releases" \
  --embed-release-notes \
  --maximum-deltas 0 \
  --maximum-versions 5 \
  ${CHANNEL:+--channel "$CHANNEL"} \
  -o "$APPCAST" \
  "$STAGE"

git add appcast.xml
git commit -q -m "chore(appcast): publish $SHORT_VERSION ($BUNDLE_VERSION)${CHANNEL:+ on the $CHANNEL channel}"
git push --quiet origin master

# ------------------------------------------------------------------ 阶段 5：自检输出
ENCLOSURE=$(xmllint --xpath 'string(//enclosure[1]/@url)' "$APPCAST")
echo "feed:     https://raw.githubusercontent.com/$REPO/master/appcast.xml"
echo "download: $ENCLOSURE"
# raw.githubusercontent 有约 5 分钟 CDN 缓存，把「几分钟后才全球生效」这件事显式
# 暴露给发布者，而不是让他以为推完就完事了。
if curl -fsI "$ENCLOSURE" >/dev/null 2>&1; then
  echo "enclosure URL reachable"
else
  echo "WARNING: enclosure URL not reachable yet (GitHub CDN may lag a few minutes)"
fi
echo "note: the appcast feed is served from raw.githubusercontent with ~5 min of CDN cache"
