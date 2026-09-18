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
# 版本号来自 Resources/Info.plist 的 `-dev` 开发版号：发版之间它一直带 `-dev`
# （`0.6.7-dev`），本脚本去掉后缀得到发版号，发完再把它推到下一个开发版并提交。
# 因此正常发版不需要任何参数；跳版本号（0.6.x → 0.7.0）时才显式给 --short。
#
# 用法：
#   ./scripts/release.sh                          # 发 plist 里的 -dev 版本
#   ./scripts/release.sh --dry-run                # 只算版本号并跑前置校验，不写任何东西
#   ./scripts/release.sh --short 0.7.0            # 跳版本号
#   ./scripts/release.sh --short 0.7.0-preview.1 --preview

PROJECT_DIR="${0:A:h:h}"
BUILD_DIR="${ASTER_BUILD_PATH:-$PROJECT_DIR/.build}"
REPO="rambocode/aster"

die() { echo "release: $1" >&2; exit 1 }

SHORT_VERSION=""
BUNDLE_VERSION=""
PREVIEW=0
DRY_RUN=0
while (( $# > 0 )); do
  case "$1" in
    --short)   SHORT_VERSION="${2:-}"; shift 2 ;;
    --bundle)  BUNDLE_VERSION="${2:-}"; shift 2 ;;
    --preview) PREVIEW=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) die "unknown argument: $1" ;;
  esac
done

PLIST="$PROJECT_DIR/Resources/Info.plist"
PLIST_SHORT=$(plutil -extract CFBundleShortVersionString raw "$PLIST")
PLIST_BUNDLE=$(plutil -extract CFBundleVersion raw "$PLIST")

# appcast 里已发布的最大 sparkle:version。既用于「中断重跑 vs 重复发版」的判别，
# 也用于阶段 0 末尾的单调性校验。首次发布时 appcast.xml 还不存在。
APPCAST="$PROJECT_DIR/appcast.xml"
MAX_IN_FEED=0
if [[ -f "$APPCAST" ]]; then
  MAX_IN_FEED=$(xmllint --xpath '//*[local-name()="version"]/text()' "$APPCAST" 2>/dev/null \
    | tr ' ' '\n' | sort -n | tail -1)
  MAX_IN_FEED="${MAX_IN_FEED:-0}"
fi

# 仓库里的短版本正常是 `-dev` 形态；缺省从它推出发版号与构建号。
[[ -n "$SHORT_VERSION" ]] || SHORT_VERSION="${PLIST_SHORT%-dev}"
[[ -n "$BUNDLE_VERSION" ]] || BUNDLE_VERSION="$PLIST_BUNDLE"

# 版本号已经是正式形态（没有 -dev），说明阶段 1 跑过了。这有两种情况，必须分开：
#   - 中途失败后重跑：标签、Release 与 appcast 都还没有该版本，继续跑才能把发布做完。
#     阶段 1 的提交本身是幂等的（没有改动就跳过 commit），所以直接放行。
#   - 已经发布完但收尾提交没跑成：版本号停在已发布的正式号上，再发一次就是重复发版，
#     而 appcast 的 sparkle:version 是主键、发出去的号收不回来，必须拦住。
# 判据取 appcast：它是「这个构建号有没有真的发出去」的唯一权威，比标签更靠前失败。
if [[ "$PLIST_SHORT" != *-dev ]]; then
  if (( BUNDLE_VERSION <= MAX_IN_FEED )); then
    die "$PLIST_SHORT (build $BUNDLE_VERSION) 已经发布过；上次发版的收尾提交没跑成，先把版本号改回下一个 -dev"
  fi
  echo "note: 版本号已是 $PLIST_SHORT，按中断后重跑处理（appcast 里还没有 build $BUNDLE_VERSION）"
fi

# 发出去的版本号绝不能带 -dev：它会进 appcast 的 shortVersionString、Release 标题和
# 标签，而这三样都收不回来。
[[ "$SHORT_VERSION" != *-dev ]] || die "发版号不能带 -dev 后缀，got: $SHORT_VERSION"
# Apple 要求 CFBundleVersion 是数字点分串；带 -preview 后缀会让 codesign、
# LaunchServices 与公证的行为不确定，语义版本只放在 CFBundleShortVersionString 里。
[[ "$BUNDLE_VERSION" == <-> ]] || die "--bundle must be a plain integer, got: $BUNDLE_VERSION"

# 下一个开发版：短版本末段数字加一再接 -dev（0.6.7 → 0.6.8-dev，
# 0.7.0-preview.1 → 0.7.0-preview.2-dev），构建号加一。
NEXT_SHORT=$(perl -pe 's/(\d+)$/$1+1/e' <<<"$SHORT_VERSION")-dev
NEXT_BUNDLE=$(( BUNDLE_VERSION + 1 ))

TAG="v$SHORT_VERSION"
CHANNEL=""
(( PREVIEW )) && CHANNEL="preview"

# 先报要发什么、发完推到哪，再跑校验：校验失败时也已经能核对版本号算得对不对。
echo "release: $SHORT_VERSION (build $BUNDLE_VERSION)${CHANNEL:+ on the $CHANNEL channel}"
echo "next:    $NEXT_SHORT (build $NEXT_BUNDLE)"

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
(( BUNDLE_VERSION > MAX_IN_FEED )) \
  || die "CFBundleVersion $BUNDLE_VERSION must exceed $MAX_IN_FEED already published in appcast.xml"

# --dry-run 在这里退出：阶段 0 的校验已经全部跑完（签名、公证凭据、git 状态、发行说明、
# Sparkle 密钥、版本单调性），但还没有任何写操作。发版前先跑一次确认版本号算得对。
if (( DRY_RUN )); then
  echo "dry-run: 前置校验通过，未做任何修改"
  exit 0
fi

# ------------------------------------------------- 阶段 1：写版本号并推送到 master
# 必须先推，gh release create 才能把 tag 打在已经存在于远端的 commit 上。
plutil -replace CFBundleShortVersionString -string "$SHORT_VERSION" "$PROJECT_DIR/Resources/Info.plist"
plutil -replace CFBundleVersion -string "$BUNDLE_VERSION" "$PROJECT_DIR/Resources/Info.plist"
git add Resources/Info.plist docs/release-notes
# 阶段 2 之后失败（例如公证凭据不可用）重跑时，版本号提交已经推送过；此时没有可提交的改动，
# 跳过提交而不是让 `git commit` 在 set -e 下中止整条发布。
if ! git diff --cached --quiet; then
  git commit -q -m "chore(release): $SHORT_VERSION ($BUNDLE_VERSION)"
fi
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
# 把本次构建的 dSYM 传到 Sentry，崩溃报告才能显示函数名。缺 sentry-cli 或令牌时只提示不阻断：
# 发布本身不依赖它，但没有它这一版的崩溃栈将是裸地址，所以提示要显眼。
# 令牌来源二选一：环境变量 SENTRY_AUTH_TOKEN，或 `sentry-cli login` 写入的 ~/.sentryclirc。
DSYM_PATH="$PROJECT_DIR/dist/Aster.app.dSYM"
if command -v sentry-cli >/dev/null 2>&1 && [[ -d "$DSYM_PATH" ]] \
  && { [[ -n "${SENTRY_AUTH_TOKEN:-}" ]] || grep -qs '^token=' "$HOME/.sentryclirc"; }; then
  sentry-cli debug-files upload --org dx-i1 --project aster "$DSYM_PATH" \
    || die "sentry-cli debug-files upload failed"
else
  echo "warning: dSYM not uploaded to Sentry (need sentry-cli on PATH and a token via SENTRY_AUTH_TOKEN or 'sentry-cli login'); run later:" >&2
  echo "  sentry-cli debug-files upload --org dx-i1 --project aster $DSYM_PATH" >&2
fi

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

# ------------------------------------------- 阶段 6：版本号推到下一个开发版并推送
# 这个提交不打标签、不建 Release：-dev 版本永远不发布。必须推送成功——阶段 0 要求
# 工作区干净且与 origin/master 同步，漏推会让下一次发版在第一步就失败。
plutil -replace CFBundleShortVersionString -string "$NEXT_SHORT" "$PLIST"
plutil -replace CFBundleVersion -string "$NEXT_BUNDLE" "$PLIST"
git add Resources/Info.plist
git commit -q -m "chore(release): 版本号推到下一个开发版（$NEXT_SHORT）"
git push --quiet origin master \
  || die "下一个开发版的提交没能推送；手动 git push origin master 后再发下一版"
echo "next:     $NEXT_SHORT (build $NEXT_BUNDLE) committed and pushed"
