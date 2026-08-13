#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
APP_DIR="$PROJECT_DIR/dist/Aster.app"
VERSION=$(plutil -extract CFBundleShortVersionString raw "$PROJECT_DIR/Resources/Info.plist")
DMG_PATH="${1:-$PROJECT_DIR/dist/Aster-$VERSION.dmg}"

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
hdiutil verify "$DMG_PATH"
hdiutil attach "$DMG_PATH" -readonly -noautoopen -mountpoint "$MOUNT_DIR" >/dev/null
codesign --verify --deep --strict --verbose=2 "$MOUNT_DIR/Aster.app"
# 从只读挂载卷运行无窗口资源自检，覆盖用户把 App 从 DMG 安装到新电脑时使用的布局。
"$MOUNT_DIR/Aster.app/Contents/MacOS/Aster" --verify-packaged-resources

echo "$DMG_PATH"
