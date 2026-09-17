#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/tests"
TEST_EXECUTABLE="$BUILD_DIR/AppLaunchSmoke"
APP_DIR="${1:-$ROOT_DIR/build/local/MonoList 开发版.app}"
ICON_PNG="$ROOT_DIR/build/local/AppIcon.iconset/icon_512x512@2x.png"
EXPECTED_BUNDLE_ID="${2:-com.qingcheng.monolist.dev}"
EXPECTED_HELPER_BUNDLE_ID="${3:-com.qingcheng.monolist.dev.menubar}"
EXPECTED_DISPLAY_NAME="${4:-MonoList 开发版}"

mkdir -p "$BUILD_DIR"

swiftc \
  -parse-as-library \
  "$ROOT_DIR/Tests/AppLaunchSmoke.swift" \
  -o "$TEST_EXECUTABLE"

"$TEST_EXECUTABLE" \
  "$APP_DIR" \
  "$ICON_PNG" \
  "$EXPECTED_BUNDLE_ID" \
  "$EXPECTED_HELPER_BUNDLE_ID" \
  "$EXPECTED_DISPLAY_NAME"
