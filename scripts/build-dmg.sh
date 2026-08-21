#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/dist/Aster.app"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$PROJECT_DIR/Resources/Info.plist")
DMG_PATH="${1:-$PROJECT_DIR/dist/Aster-$VERSION.dmg}"
# 签名身份与公证 profile 都经环境变量注入。ASTER_SIGN_IDENTITY 会传给内层
# build-app.sh——整条 DMG 流程必须带它，缺变量重跑会把已签好的 App 重签回 ad-hoc。
SIGN_IDENTITY="${ASTER_SIGN_IDENTITY:--}"
NOTARY_PROFILE="${ASTER_NOTARY_PROFILE:-}"

# 公证以 Developer ID 签名为前提；ad-hoc 构建提交公证必被 Apple 拒绝，提前拦截。
if [[ -n "$NOTARY_PROFILE" && "$SIGN_IDENTITY" == "-" ]]; then
  echo "ASTER_NOTARY_PROFILE requires ASTER_SIGN_IDENTITY (Developer ID); ad-hoc builds cannot be notarized" >&2
  exit 1
fi

"$PROJECT_DIR/scripts/build-app.sh" >/dev/null
if [[ -e "$DMG_PATH" ]]; then
  echo "Refusing to overwrite existing DMG: $DMG_PATH" >&2
  exit 1
fi

STAGING_DIR=$(mktemp -d /tmp/aster-dmg.XXXXXX)
MOUNT_DIR=$(mktemp -d /tmp/aster-mount.XXXXXX)
cleanup() {
  hdiutil detach "$MOUNT_DIR" >/dev/null 2>&1 || true
  rm -rf "$STAGING_DIR" "$MOUNT_DIR"
}
trap cleanup EXIT

ditto "$APP_DIR" "$STAGING_DIR/Aster.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create -volname "Aster $VERSION" -srcfolder "$STAGING_DIR" -format UDZO "$DMG_PATH"

# 正式分发按「签 DMG 本体 → 公证 → 装订」的顺序执行，不可颠倒：先公证后签名会改变
# DMG 哈希、让已发放的票据失效，只能整轮重来。codesign/stapler 会同步更新 UDIF
# 校验和，因此后续 hdiutil verify 仍然有效。
if [[ "$SIGN_IDENTITY" != "-" ]]; then
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG_PATH"
fi
if [[ -n "$NOTARY_PROFILE" ]]; then
  # notarytool 各版本在 Invalid 状态下的退出码不一致，按输出文本判定结果。
  # `set -e` 会让赋值语句在命令失败时当场退出，输出还没 echo 就没了——凭据丢失、
  # 网络不通这类错误因此会变成一句无来由的非零退出码。用 `|| true` 接住，先把
  # 原始输出打出来，再由下面的文本判定给出结论。
  NOTARY_OUTPUT=$(xcrun notarytool submit "$DMG_PATH" --keychain-profile "$NOTARY_PROFILE" --wait 2>&1 || true)
  echo "$NOTARY_OUTPUT"
  if [[ "$NOTARY_OUTPUT" != *"status: Accepted"* ]]; then
    echo "Notarization not accepted; inspect: xcrun notarytool log <submission-id> --keychain-profile $NOTARY_PROFILE" >&2
    exit 1
  fi
  xcrun stapler staple "$DMG_PATH"
fi

hdiutil verify "$DMG_PATH"
hdiutil attach "$DMG_PATH" -readonly -noautoopen -mountpoint "$MOUNT_DIR" >/dev/null
codesign --verify --deep --strict --verbose=2 "$MOUNT_DIR/Aster.app"
# 从只读挂载卷运行无窗口资源自检，覆盖用户把 App 从 DMG 安装到新电脑时使用的布局。
"$MOUNT_DIR/Aster.app/Contents/MacOS/Aster" --verify-packaged-resources

# 公证产物按用户下载后的真实路径做 Gatekeeper 终验，两项都必须是 Notarized Developer ID。
if [[ -n "$NOTARY_PROFILE" ]]; then
  spctl -a -t open --context context:primary-signature -v "$DMG_PATH"
  spctl -a -t exec -v "$APP_DIR"
fi

echo "$DMG_PATH"
