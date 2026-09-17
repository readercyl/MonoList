#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/release"
STAGING_DIR="$BUILD_DIR/dmg-staging"
CODESIGN_IDENTITY="${MONOLIST_CODESIGN_IDENTITY:-}"

if [[ -z "${MONOLIST_APP_VERSION:-}" ]]; then
  echo "必须设置 MONOLIST_APP_VERSION，例如 v0.1.0。" >&2
  exit 1
fi
APP_VERSION="$MONOLIST_APP_VERSION"
if [[ ! "$APP_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "版本号必须是三段式 SemVer：$APP_VERSION" >&2
  exit 1
fi

DMG_PATH="$BUILD_DIR/MonoList-$APP_VERSION.dmg"
rm -rf "$BUILD_DIR"
mkdir -p "$STAGING_DIR"

if [[ -z "$CODESIGN_IDENTITY" ]]; then
  CODESIGN_IDENTITY="$("$ROOT_DIR/scripts/ensure-local-signing-cert.sh")"
fi

MONOLIST_APP_VERSION="$APP_VERSION" \
MONOLIST_BUILD_FLAVOR=release \
MONOLIST_CODESIGN_IDENTITY="$CODESIGN_IDENTITY" \
  "$ROOT_DIR/scripts/build-local.sh" >/dev/null

ditto "$ROOT_DIR/build/local/MonoList.app" "$STAGING_DIR/MonoList.app"
ln -s /Applications "$STAGING_DIR/Applications"

"$ROOT_DIR/scripts/check-release-signature.sh" "$STAGING_DIR/MonoList.app"
"$ROOT_DIR/scripts/check-dmg-layout.sh" "$STAGING_DIR"

hdiutil create \
  -volname "MonoList $APP_VERSION" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null
hdiutil verify "$DMG_PATH" >/dev/null
xattr -cr "$DMG_PATH" 2>/dev/null || true

echo "$DMG_PATH"
