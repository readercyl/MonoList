#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_FLAVOR="${MONOLIST_BUILD_FLAVOR:-development}"
case "$BUILD_FLAVOR" in
  development)
    APP_BUNDLE_NAME="MonoList 开发版.app"
    PRODUCT_DISPLAY_NAME="MonoList 开发版"
    BUNDLE_IDENTIFIER="com.qingcheng.monolist.dev"
    HELPER_BUNDLE_IDENTIFIER="com.qingcheng.monolist.dev.menubar"
    ;;
  release)
    APP_BUNDLE_NAME="MonoList.app"
    PRODUCT_DISPLAY_NAME="MonoList"
    BUNDLE_IDENTIFIER="com.qingcheng.monolist.mac"
    HELPER_BUNDLE_IDENTIFIER="com.qingcheng.monolist.menubar.v2"
    ;;
  *)
    echo "MONOLIST_BUILD_FLAVOR 必须是 development 或 release。" >&2
    exit 1
    ;;
esac
EXECUTABLE_NAME="MonoList"
if [[ "$BUILD_FLAVOR" == "development" ]]; then
  APP_VERSION="${MONOLIST_DEV_VERSION:-v0.1.0}"
  APP_BUILD="${MONOLIST_DEV_BUILD:-1}"
else
  APP_VERSION="${MONOLIST_APP_VERSION:-}"
  APP_BUILD="${MONOLIST_APP_BUILD:-1}"
fi
[[ "$APP_VERSION" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
  echo "版本号必须是三段式 SemVer：$APP_VERSION" >&2
  exit 1
}
BUNDLE_SHORT_VERSION="${APP_VERSION#v}"
MIN_MACOS_VERSION="14.0"
SWIFT_TARGET="arm64-apple-macosx$MIN_MACOS_VERSION"
BUILD_DIR="$ROOT_DIR/build/local"
APP_DIR="$BUILD_DIR/$APP_BUNDLE_NAME"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE="$MACOS_DIR/$EXECUTABLE_NAME"
HELPER_APP_DIR="$CONTENTS_DIR/Library/Helpers/MenuBarService.app"
HELPER_CONTENTS_DIR="$HELPER_APP_DIR/Contents"
HELPER_MACOS_DIR="$HELPER_CONTENTS_DIR/MacOS"
HELPER_EXECUTABLE="$HELPER_MACOS_DIR/MenuBarService"
CODESIGN_IDENTITY="${MONOLIST_CODESIGN_IDENTITY:-}"
ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
GENERATED_ICON="$BUILD_DIR/AppIcon.icns"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$HELPER_MACOS_DIR"

SWIFT_SOURCES=()
while IFS= read -r source_file; do
  SWIFT_SOURCES+=("$source_file")
done < <(find "$ROOT_DIR/MonoList" -name '*.swift' | sort)

swiftc \
  -O \
  -target "$SWIFT_TARGET" \
  "${SWIFT_SOURCES[@]}" \
  -o "$EXECUTABLE"

swiftc \
  -O \
  -target "$SWIFT_TARGET" \
  "$ROOT_DIR/MonoList/App/MenuBarBridgeProtocol.swift" \
  "$ROOT_DIR/MonoList/App/MenuBarIconRenderer.swift" \
  "$ROOT_DIR/MenuBarHelper/main.swift" \
  -o "$HELPER_EXECUTABLE"

rm -rf "$ICONSET_DIR" "$GENERATED_ICON"
swift "$ROOT_DIR/scripts/generate-app-icon.swift" "$ICONSET_DIR"
iconutil -c icns "$ICONSET_DIR" -o "$GENERATED_ICON"
cp "$GENERATED_ICON" "$RESOURCES_DIR/AppIcon.icns"
ICON_PLIST=$'    <key>CFBundleIconFile</key>\n    <string>AppIcon.icns</string>'

cat > "$CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh-Hans</string>
    <key>CFBundleDisplayName</key>
    <string>$PRODUCT_DISPLAY_NAME</string>
    <key>CFBundleExecutable</key>
    <string>$EXECUTABLE_NAME</string>
$ICON_PLIST
    <key>CFBundleIdentifier</key>
    <string>$BUNDLE_IDENTIFIER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>$PRODUCT_DISPLAY_NAME</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$BUNDLE_SHORT_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS_VERSION</string>
    <key>LSUIElement</key>
    <false/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"
cat > "$HELPER_CONTENTS_DIR/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>MenuBarService</string>
    <key>CFBundleExecutable</key>
    <string>MenuBarService</string>
    <key>CFBundleIdentifier</key>
    <string>$HELPER_BUNDLE_IDENTIFIER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>MenuBarService</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$BUNDLE_SHORT_VERSION</string>
    <key>CFBundleVersion</key>
    <string>$APP_BUILD</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS_VERSION</string>
    <key>LSUIElement</key>
    <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$HELPER_CONTENTS_DIR/PkgInfo"
chmod +x "$EXECUTABLE" "$HELPER_EXECUTABLE"

if [[ -n "$CODESIGN_IDENTITY" ]]; then
  codesign --force --sign "$CODESIGN_IDENTITY" "$HELPER_APP_DIR" >/dev/null
  codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_DIR" >/dev/null
else
  codesign --force --sign - "$HELPER_APP_DIR" >/dev/null
  codesign --force --deep --sign - "$APP_DIR" >/dev/null
fi

echo "$APP_DIR"
